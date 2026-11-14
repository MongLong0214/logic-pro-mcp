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

if [ "$#" -ne 3 ] || ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]] \
    || [ ! -d "$CANDIDATE_ROOT" ]; then
  echo "Usage: $0 EXACT_CANDIDATE_SHA CI_RUN_ID /path/to/clean-candidate-worktree" >&2
  exit 1
fi
command -v gh >/dev/null
status_token="${LOGIC_NATIVE_STATUS_TOKEN:-}"
if [ -z "$status_token" ]; then
  echo "Error: LOGIC_NATIVE_STATUS_TOKEN is required for the trusted status publisher." >&2
  exit 1
fi
# The candidate process never inherits a GitHub credential from this wrapper. Keep the only copy
# as a non-exported shell variable and give each trusted gh invocation a fresh empty config root.
unset LOGIC_NATIVE_STATUS_TOKEN GH_TOKEN GITHUB_TOKEN

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
mkdir "$work/status-gh"

trusted_gh() {
  GH_TOKEN="$status_token" GH_CONFIG_DIR="$work/status-gh" gh "$@"
}

trusted_gh auth status >/dev/null

post_status() {
  local state="$1" description="$2"
  trusted_gh api --method POST "repos/$REPO/statuses/$SHA" \
    -f state="$state" -f context="$CONTEXT" -f description="$description" \
    -f target_url="$target_url" >/dev/null
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

trusted_gh api "repos/$REPO/actions/runs/$RUN_ID" > "$work/run.json"
python3 - "$work/run.json" "$SHA" "$RUN_ID" "$REPO" "$work/run-attempt.txt" \
  "$CANDIDATE_ROOT" <<'PY'
import json, subprocess, sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
expected_sha, expected_id, expected_repo = sys.argv[2], int(sys.argv[3]), sys.argv[4]
if run.get("id") != expected_id:
    raise SystemExit("CI run id mismatch")
if (run.get("repository") or {}).get("full_name") != expected_repo:
    raise SystemExit("CI run repository mismatch")
if run.get("event") != "pull_request":
    raise SystemExit("native CI qualification requires a pull_request run")
run_attempt = run.get("run_attempt")
if isinstance(run_attempt, bool) or not isinstance(run_attempt, int) or run_attempt < 1:
    raise SystemExit("CI run attempt is not a positive integer")
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

trusted_gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=100" \
  > "$work/artifacts.json"
python3 - "$work/artifacts.json" "$RUN_ID" "$work/artifact.json" <<'PY'
import json, re, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
name = f"release-runtime-{sys.argv[2]}"
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
with open(sys.argv[3], "w", encoding="utf-8") as output:
    json.dump({"id": artifact_id, "digest": digest}, output, sort_keys=True)
PY

run_attempt="$(cat "$work/run-attempt.txt")"
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
trusted_gh api "repos/$REPO/actions/artifacts/$artifact_id/zip" > "$work/runtime.zip"
test "$(shasum -a 256 "$work/runtime.zip" | awk '{print $1}')" = "$artifact_hash"
ditto -x -k "$work/runtime.zip" "$work/runtime"
test "$(cat "$work/runtime/candidate-sha.txt")" = "$SHA"
chmod 0755 "$work/runtime/LogicProMCP"

# Control flow comes from protected main. The candidate tree supplies the implementation/tests but
# receives neither the status token nor the gh config used by this publisher.
env -u GH_TOKEN -u GITHUB_TOKEN -u LOGIC_NATIVE_STATUS_TOKEN \
  GH_CONFIG_DIR="$work/candidate-gh-empty" \
  bash "$TRUSTED_ROOT/Scripts/release-qualify.sh" \
    "$work/runtime/LogicProMCP" "$CANDIDATE_ROOT"
test "$(cat "$work/runtime/candidate-sha.txt")" = "$SHA"
test "$(shasum -a 256 "$work/runtime.zip" | awk '{print $1}')" = "$artifact_hash"
post_status success "$receipt"
succeeded=1
trap - EXIT INT TERM
rm -rf "$work"
echo "Native Logic qualification passed and exact-SHA status was published."
