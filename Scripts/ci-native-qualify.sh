#!/usr/bin/env bash
# Qualify the exact release-runtime artifact from one same-repository PR run on the trusted Logic
# host, then post an exact-SHA commit status that the required `build` job consumes. Invoke this
# entrypoint only from a clean checkout of protected `origin/main`; the candidate checkout is a
# separate argument. Fork code is refused before anything from the candidate is executed.
set -euo pipefail

SHA="${1:-}"
RUN_ID="${2:-}"
CANDIDATE_ROOT="${3:-}"
REPO="MongLong0214/logic-pro-mcp"
CONTEXT="logic-native-e2e"
TRUSTED_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly API_SOCKET_TIMEOUT_SECONDS=120
readonly API_CALL_DEADLINE_SECONDS=600

if [ "$#" -ne 3 ] || ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]] \
    || [ ! -d "$CANDIDATE_ROOT" ]; then
  echo "Usage: $0 EXACT_CANDIDATE_SHA CI_RUN_ID /path/to/clean-candidate-worktree" >&2
  exit 1
fi
command -v python3 >/dev/null
if [ "${LOGIC_NATIVE_STATUS_TOKEN+x}" = x ] || [ "${GH_TOKEN+x}" = x ] \
    || [ "${GITHUB_TOKEN+x}" = x ]; then
  echo "Error: pass the trusted status token on stdin; token environment variables are refused." >&2
  exit 1
fi
unset status_token
if ! IFS= read -r status_token || [ -z "$status_token" ]; then
  echo "Error: a trusted status token is required on stdin (gh auth token | bash $0 ...)." >&2
  exit 1
fi
# The wrapper reads the token once and keeps it in one non-exported shell variable. Trusted API
# children receive it through stdin only; candidate code receives neither the token nor stdin.

CANDIDATE_ROOT="$(cd "$CANDIDATE_ROOT" && pwd -P)"
require_release_origin() {
  local root="$1" origin_url
  origin_url="$(git -C "$root" remote get-url origin)"
  case "$origin_url" in
    git@github.com:MongLong0214/logic-pro-mcp.git|https://github.com/MongLong0214/logic-pro-mcp.git|https://github.com/MongLong0214/logic-pro-mcp) ;;
    *)
      echo "Error: refusing repository origin '$origin_url' at $root." >&2
      exit 1
      ;;
  esac
}
require_release_origin "$TRUSTED_ROOT"
require_release_origin "$CANDIDATE_ROOT"
git -C "$TRUSTED_ROOT" fetch --quiet origin main
test "$(git -C "$TRUSTED_ROOT" rev-parse HEAD)" = \
  "$(git -C "$TRUSTED_ROOT" rev-parse origin/main)"
test -z "$(git -C "$TRUSTED_ROOT" status --porcelain)"
test "$(git -C "$CANDIDATE_ROOT" rev-parse HEAD)" = "$SHA"
test -z "$(git -C "$CANDIDATE_ROOT" status --porcelain)"

work="$(mktemp -d "${TMPDIR:-/tmp}/logic-pro-mcp-native-ci.XXXXXX")"
target_url="https://github.com/$REPO/actions/runs/$RUN_ID"
succeeded=0

trusted_api() {
  local method="$1" endpoint="$2"
  shift 2
  printf '%s\n' "$status_token" | python3 -c '
import json, math, signal, sys, urllib.error, urllib.parse, urllib.request

class StripCrossOriginAuthorization(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        redirected = super().redirect_request(request, fp, code, message, headers, new_url)
        if redirected is None:
            return None
        old = urllib.parse.urlsplit(request.full_url)
        new = urllib.parse.urlsplit(new_url)
        old_origin = (old.scheme.lower(), old.hostname, old.port)
        new_origin = (new.scheme.lower(), new.hostname, new.port)
        if old_origin != new_origin:
            redirected.remove_header("Authorization")
        return redirected

method, url, socket_timeout_text, overall_deadline_text, *fields = sys.argv[1:]
socket_timeout = float(socket_timeout_text)
overall_deadline = int(overall_deadline_text)
if not math.isfinite(socket_timeout) or socket_timeout <= 0 or overall_deadline <= 0:
    raise SystemExit("trusted GitHub API timeouts must be finite and positive")
token = sys.stdin.readline().rstrip("\n")
if not token:
    raise SystemExit("trusted GitHub API token was empty")
if len(fields) % 2:
    raise SystemExit("trusted GitHub API fields must be key/value pairs")
payload = dict(zip(fields[::2], fields[1::2]))
data = json.dumps(payload).encode("utf-8") if method == "POST" else None
request = urllib.request.Request(
    url,
    data=data,
    method=method,
    headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
    },
)
def overall_timeout(signum, frame):
    raise TimeoutError("trusted GitHub API overall deadline exceeded")

previous_handler = signal.signal(signal.SIGALRM, overall_timeout)
signal.alarm(overall_deadline)
try:
    try:
        opener = urllib.request.build_opener(StripCrossOriginAuthorization())
        with opener.open(request, timeout=socket_timeout) as response:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
    except urllib.error.HTTPError as error:
        sys.stderr.buffer.write(error.read())
        raise
finally:
    signal.alarm(0)
    signal.signal(signal.SIGALRM, previous_handler)
' "$method" "https://api.github.com/$endpoint" \
    "$API_SOCKET_TIMEOUT_SECONDS" "$API_CALL_DEADLINE_SECONDS" "$@"
}

post_status() {
  local state="$1" description="$2"
  trusted_api POST "repos/$REPO/statuses/$SHA" \
    state "$state" context "$CONTEXT" description "$description" \
    target_url "$target_url" >/dev/null
}

finish() {
  local status="$?"
  if [ "$succeeded" -ne 1 ]; then
    post_status failure "Exact artifact failed native Logic qualification" || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

validate_run() {
  python3 - "$1" "$SHA" "$RUN_ID" "$REPO" "$2" "$CANDIDATE_ROOT" "${3:-}" <<'PY'
import json, subprocess, sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
expected_sha, expected_id, expected_repo = sys.argv[2], int(sys.argv[3]), sys.argv[4]
if run.get("id") != expected_id:
    raise SystemExit("CI run id mismatch")
if (run.get("repository") or {}).get("full_name") != expected_repo:
    raise SystemExit("CI run repository mismatch")
if run.get("event") != "pull_request":
    raise SystemExit("native CI qualification requires a pull_request run")
if run.get("path") != ".github/workflows/ci.yml":
    raise SystemExit("native CI qualification requires the exact ci.yml workflow")
if run.get("status") != "in_progress" or run.get("conclusion") is not None:
    raise SystemExit("native CI qualification requires an active non-cancelled run")
run_attempt = run.get("run_attempt")
if isinstance(run_attempt, bool) or not isinstance(run_attempt, int) or run_attempt < 1:
    raise SystemExit("CI run attempt is not a positive integer")
if sys.argv[7] and run_attempt != int(sys.argv[7]):
    raise SystemExit("CI run attempt changed during native qualification")
pull_requests = run.get("pull_requests") or []
if len(pull_requests) != 1:
    raise SystemExit("native CI qualification requires exactly one pull request identity")
pull_request = pull_requests[0]
head_sha = (pull_request.get("head") or {}).get("sha")
base_sha = (pull_request.get("base") or {}).get("sha")
expected_repo_url = f"https://api.github.com/repos/{expected_repo}"
if (pull_request.get("head") or {}).get("repo", {}).get("url") != expected_repo_url:
    raise SystemExit("fork pull requests cannot execute on the trusted Logic host")
if (pull_request.get("base") or {}).get("repo", {}).get("url") != expected_repo_url:
    raise SystemExit("pull request base repository identity mismatch")
if (pull_request.get("base") or {}).get("ref") != "main":
    raise SystemExit("native CI qualification requires pull request base main")
if run.get("head_sha") != head_sha:
    raise SystemExit("CI run head SHA differs from its pull request head")
if not all(isinstance(value, str) and len(value) == 40 for value in (head_sha, base_sha)):
    raise SystemExit("CI run lacks exact pull request head/base SHAs")

# For pull_request workflows GitHub checks out the synthetic merge candidate while the Actions
# run API exposes the source branch as `head_sha`. Bind both identities instead of pretending they
# are equal: the artifact/status SHA must be the exact checkout, whose ordered parents are the
# base and head recorded by this run. A source-only SHA or a merge made from another base fails.
parents = subprocess.check_output(
    ["git", "-C", sys.argv[6], "show", "-s", "--format=%P", expected_sha], text=True
).strip().split()
if parents != [base_sha, head_sha]:
    raise SystemExit(
        "candidate SHA is not the exact pull request merge of this run's base and head")
with open(sys.argv[5], "w", encoding="utf-8") as output:
    print(run_attempt, file=output)
PY
}

trusted_api GET "repos/$REPO/actions/runs/$RUN_ID" > "$work/run.json"
validate_run "$work/run.json" "$work/run-attempt.txt"

trusted_api GET "repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=100" \
  > "$work/artifacts.json"
run_attempt="$(cat "$work/run-attempt.txt")"
validate_artifacts() {
  python3 - "$1" "$RUN_ID" "$run_attempt" "$2" <<'PY'
import json, re, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
name = f"release-runtime-{sys.argv[2]}-{sys.argv[3]}"
matches = [row for row in body.get("artifacts", []) if row.get("name") == name]
if len(matches) != 1:
    raise SystemExit(f"expected one current {name!r} artifact, found {len(matches)}")
artifact = matches[0]
if artifact.get("expired") is not False:
    raise SystemExit("release runtime artifact is expired or has unknown expiry state")
artifact_id = artifact.get("id")
digest = artifact.get("digest")
if isinstance(artifact_id, bool) or not isinstance(artifact_id, int) or artifact_id < 1:
    raise SystemExit("release runtime artifact id is not a positive integer")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("release runtime artifact has no canonical SHA-256 digest")
with open(sys.argv[4], "w", encoding="utf-8") as output:
    json.dump({"id": artifact_id, "digest": digest}, output, sort_keys=True)
PY
}
validate_artifacts "$work/artifacts.json" "$work/artifact.json"

artifact_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
  "$work/artifact.json")"
artifact_digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' \
  "$work/artifact.json")"
artifact_hash="${artifact_digest#sha256:}"
target_url="https://github.com/$REPO/actions/runs/$RUN_ID/attempts/$run_attempt"
receipt="Native PASS a=$run_attempt id=$artifact_id d=$artifact_hash"
test "${#receipt}" -le 140
post_status pending "Native RUN a=$run_attempt id=$artifact_id d=$artifact_hash"

mkdir "$work/runtime"
trusted_api GET "repos/$REPO/actions/artifacts/$artifact_id/zip" > "$work/runtime.zip"
test "$(shasum -a 256 "$work/runtime.zip" | awk '{print $1}')" = "$artifact_hash"
python3 - "$work/runtime.zip" "$work/runtime" <<'PY'
import os, shutil, stat, sys, zipfile

archive_path, destination = sys.argv[1], os.path.realpath(sys.argv[2])
expected = {"LogicProMCP", "candidate-sha.txt"}
limits = {"LogicProMCP": 256 * 1024 * 1024, "candidate-sha.txt": 128}
if not os.path.isdir(destination) or os.listdir(destination):
    raise SystemExit("runtime extraction directory is not a fresh empty directory")

with zipfile.ZipFile(archive_path, "r") as archive:
    members = archive.infolist()
    names = [member.filename for member in members]
    if len(members) != 2 or len(set(names)) != 2 or set(names) != expected:
        raise SystemExit("release runtime archive must contain exactly the two expected files")
    for member in members:
        name = member.filename
        mode = member.external_attr >> 16
        file_type = stat.S_IFMT(mode)
        if (member.is_dir() or name.startswith("/") or "\\" in name
                or member.external_attr & 0x10
                or any(part in ("", ".", "..") for part in name.split("/"))):
            raise SystemExit(f"unsafe release runtime member path: {name!r}")
        if member.flag_bits & 0x1:
            raise SystemExit(f"encrypted release runtime member: {name!r}")
        if file_type not in (0, stat.S_IFREG):
            raise SystemExit(f"non-regular release runtime member: {name!r}")
        if member.file_size < 1 or member.file_size > limits[name]:
            raise SystemExit(f"release runtime member has invalid size: {name!r}")
    bad_member = archive.testzip()
    if bad_member is not None:
        raise SystemExit(f"release runtime member failed CRC validation: {bad_member!r}")
    for member in members:
        destination_path = os.path.join(destination, member.filename)
        descriptor = os.open(
            destination_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with archive.open(member, "r") as source, os.fdopen(descriptor, "wb") as output:
            shutil.copyfileobj(source, output)
PY
test "$(cat "$work/runtime/candidate-sha.txt")" = "$SHA"
chmod 0755 "$work/runtime/LogicProMCP"

# Control flow comes from protected main. The candidate tree supplies the implementation/tests but
# receives neither the status token nor the gh config used by this publisher.
env -u GH_TOKEN -u GITHUB_TOKEN -u LOGIC_NATIVE_STATUS_TOKEN -u status_token \
  GH_CONFIG_DIR="$work/candidate-gh-empty" \
  bash "$TRUSTED_ROOT/Scripts/release-qualify.sh" \
    "$work/runtime/LogicProMCP" "$CANDIDATE_ROOT" < /dev/null
test "$(cat "$work/runtime/candidate-sha.txt")" = "$SHA"
test "$(shasum -a 256 "$work/runtime.zip" | awk '{print $1}')" = "$artifact_hash"
test "$(git -C "$TRUSTED_ROOT" rev-parse HEAD)" = \
  "$(git -C "$TRUSTED_ROOT" rev-parse origin/main)"
test -z "$(git -C "$TRUSTED_ROOT" status --porcelain)"
test "$(git -C "$CANDIDATE_ROOT" rev-parse HEAD)" = "$SHA"
test -z "$(git -C "$CANDIDATE_ROOT" status --porcelain)"
trusted_api GET "repos/$REPO/actions/runs/$RUN_ID" > "$work/run-success.json"
validate_run "$work/run-success.json" "$work/run-success-attempt.txt" "$run_attempt"
trusted_api GET "repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=100" \
  > "$work/artifacts-success.json"
validate_artifacts "$work/artifacts-success.json" "$work/artifact-success.json"
cmp -s "$work/artifact.json" "$work/artifact-success.json"
post_status success "$receipt"
succeeded=1
trap - EXIT INT TERM
rm -rf "$work"
echo "Native Logic qualification passed and exact-SHA status was published."
