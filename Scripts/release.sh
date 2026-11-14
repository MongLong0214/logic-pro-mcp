#!/usr/bin/env bash
# Qualify one immutable candidate built from exact main, then submit its annotated tag.
set -euo pipefail

VERSION="${1:-}"
RUN_ID="${2:-}"
REPO="MongLong0214/logic-pro-mcp"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DRY_RUN="${DRY_RUN:-0}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

if [ "$#" -ne 2 ] || ! [[ "$VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?$ ]] || ! [[ "$RUN_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH[-prerelease] CANDIDATE_RUN_ID" >&2
  exit 1
fi
test -d "$DEVELOPER_DIR"
command -v gh >/dev/null
gh auth status >/dev/null
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$GITHUB_REPOSITORY" != "$REPO" ]; then
  echo "Error: refusing release from repository identity '$GITHUB_REPOSITORY'." >&2
  exit 1
fi
cd "$REPO_ROOT"
origin_url="$(git remote get-url origin)"
case "$origin_url" in
  git@github.com:MongLong0214/logic-pro-mcp.git|https://github.com/MongLong0214/logic-pro-mcp.git|https://github.com/MongLong0214/logic-pro-mcp) ;;
  *)
    echo "Error: origin is not the exact release repository: $origin_url" >&2
    exit 1
    ;;
esac

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/logic-pro-mcp-release.XXXXXX")"
CANDIDATE_DIR="$TEMP_DIR/candidate"
EVIDENCE_DIR="$TEMP_DIR/evidence"
mkdir -p "$EVIDENCE_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

require_clean_main() {
  if [ "$(git branch --show-current)" != main ]; then
    echo "Error: releases must be tagged from the main branch." >&2
    exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working tree is not clean." >&2
    exit 1
  fi
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Error: HEAD must match origin/main before publishing a release tag." >&2
    exit 1
  fi
}

assert_remote_tag_absent() {
  local remote_result remote_error
  remote_error="$TEMP_DIR/ls-remote.err"
  if ! remote_result="$(git ls-remote --tags origin "refs/tags/$VERSION" 2>"$remote_error")"; then
    echo "Error: remote tag lookup failed; absence was not established." >&2
    cat "$remote_error" >&2
    exit 1
  fi
  if [ -n "$remote_result" ]; then
    echo "Error: tag already exists on origin." >&2
    exit 1
  fi
}

inspect_local_tag_target() {
  local lookup_status object_type peeled
  if git show-ref --verify --quiet "refs/tags/$VERSION"; then
    LOCAL_TAG_PRESENT=1
  else
    lookup_status="$?"
    if [ "$lookup_status" -ne 1 ]; then
      echo "Error: local tag lookup failed; absence was not established." >&2
      exit 1
    fi
    LOCAL_TAG_PRESENT=0
    return
  fi
  object_type="$(git cat-file -t "refs/tags/$VERSION")"
  if [ "$object_type" != tag ]; then
    echo "Error: existing local release tag is lightweight, not annotated." >&2
    exit 1
  fi
  peeled="$(git rev-parse "refs/tags/$VERSION^{}")"
  if [ "$peeled" != "$QUALIFIED" ]; then
    echo "Error: existing local release tag targets a different commit." >&2
    exit 1
  fi
}

verify_local_tag_binding() {
  git for-each-ref --format='%(contents)' "refs/tags/$VERSION" > "$EVIDENCE_DIR/tag-message.txt"
  python3 Scripts/release-verify-candidate.py tag \
    --message-file "$EVIDENCE_DIR/tag-message.txt" --version "$VERSION" \
    --object-type "$(git cat-file -t "refs/tags/$VERSION")" \
    --peeled-sha "$(git rev-parse "refs/tags/$VERSION^{}")" \
    --expected-run-id "$RUN_ID" --expected-run-attempt "$RUN_ATTEMPT" \
    --expected-artifact-id "$ARTIFACT_ID" --expected-artifact-digest "$ARTIFACT_DIGEST" \
    --expected-source-sha "$QUALIFIED" --expected-manifest-sha256 "$MANIFEST_SHA" >/dev/null
}

fetch_candidate_evidence() {
  local suffix="$1"
  gh api "repos/$REPO/actions/workflows/release.yml" > "$EVIDENCE_DIR/workflow-$suffix.json"
  gh api "repos/$REPO/actions/runs/$RUN_ID" > "$EVIDENCE_DIR/run-$suffix.json"
  local api_attempt
  api_attempt="$(python3 - "$EVIDENCE_DIR/run-$suffix.json" <<'PY'
import json, sys
attempt = json.load(open(sys.argv[1], encoding="utf-8")).get("run_attempt")
if isinstance(attempt, bool) or not isinstance(attempt, int) or attempt < 1:
    raise SystemExit("candidate run_attempt is not a positive integer")
print(attempt)
PY
)"
  gh api --paginate --slurp \
    "repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=100" > "$EVIDENCE_DIR/artifacts-$suffix.json"
  gh api --paginate --slurp \
    "repos/$REPO/actions/runs/$RUN_ID/attempts/$api_attempt/jobs?per_page=100" > "$EVIDENCE_DIR/jobs-$suffix.json"
  local attempt_args=()
  if [ -n "$RUN_ATTEMPT" ]; then
    attempt_args=(--expected-attempt "$RUN_ATTEMPT")
  fi
  python3 Scripts/release-verify-candidate.py run \
    --workflow-json "$EVIDENCE_DIR/workflow-$suffix.json" \
    --run-json "$EVIDENCE_DIR/run-$suffix.json" \
    --artifacts-json "$EVIDENCE_DIR/artifacts-$suffix.json" \
    --jobs-json "$EVIDENCE_DIR/jobs-$suffix.json" \
    --repository "$REPO" --source-sha "$QUALIFIED" --run-id "$RUN_ID" \
    "${attempt_args[@]}" > "$EVIDENCE_DIR/binding-$suffix.json"
}

git fetch --quiet origin main --tags
require_clean_main
QUALIFIED="$(git rev-parse HEAD)"
assert_remote_tag_absent
inspect_local_tag_target
RUN_ATTEMPT=""
fetch_candidate_evidence before
RUN_ATTEMPT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_attempt"])' "$EVIDENCE_DIR/binding-before.json")"
ARTIFACT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact_id"])' "$EVIDENCE_DIR/binding-before.json")"
ARTIFACT_DIGEST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact_digest"])' "$EVIDENCE_DIR/binding-before.json")"
ARTIFACT_NAME="release-candidate-${RUN_ID}-${RUN_ATTEMPT}"

ARTIFACT_ZIP="$TEMP_DIR/$ARTIFACT_NAME.zip"
gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$ARTIFACT_ZIP"
python3 Scripts/release-verify-candidate.py extract \
  --zip "$ARTIFACT_ZIP" --directory "$CANDIDATE_DIR" \
  --expected-digest "$ARTIFACT_DIGEST"
chmod 0755 "$CANDIDATE_DIR/LogicProMCP"
python3 Scripts/release-verify-candidate.py package \
  --directory "$CANDIDATE_DIR" --version "$VERSION" --source-sha "$QUALIFIED" \
  > "$EVIDENCE_DIR/package-before.json"
MANIFEST_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_sha256"])' "$EVIDENCE_DIR/package-before.json")"
CANDIDATE_SHA="$(shasum -a 256 "$CANDIDATE_DIR/LogicProMCP" | awk '{print $1}')"

bash Scripts/release-qualify.sh "$CANDIDATE_DIR/LogicProMCP"
git diff --exit-code Package.resolved
test "$CANDIDATE_SHA" = "$(shasum -a 256 "$CANDIDATE_DIR/LogicProMCP" | awk '{print $1}')"
python3 Scripts/release-verify-candidate.py package \
  --directory "$CANDIDATE_DIR" --version "$VERSION" --source-sha "$QUALIFIED" \
  --expected-manifest-sha "$MANIFEST_SHA" > "$EVIDENCE_DIR/package-after.json"

git fetch --quiet origin main --tags
require_clean_main
assert_remote_tag_absent
test "$(git rev-parse HEAD)" = "$QUALIFIED"
inspect_local_tag_target
fetch_candidate_evidence after
cmp "$EVIDENCE_DIR/binding-before.json" "$EVIDENCE_DIR/binding-after.json"
python3 Scripts/release-verify-candidate.py package \
  --directory "$CANDIDATE_DIR" --version "$VERSION" --source-sha "$QUALIFIED" \
  --expected-manifest-sha "$MANIFEST_SHA" >/dev/null

if [ "$LOCAL_TAG_PRESENT" = 1 ]; then
  verify_local_tag_binding
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY_RUN: exact candidate and native qualification passed; no tag was created."
  exit 0
fi

if [ "$LOCAL_TAG_PRESENT" = 0 ]; then
  git tag --no-sign -a "$VERSION" "$QUALIFIED" \
    -m "Release $VERSION" \
    -m "Native-qualified: $QUALIFIED" \
    -m "Candidate-run-id: $RUN_ID" \
    -m "Candidate-run-attempt: $RUN_ATTEMPT" \
    -m "Candidate-artifact-id: $ARTIFACT_ID" \
    -m "Candidate-artifact-digest: $ARTIFACT_DIGEST" \
    -m "Candidate-source: $QUALIFIED" \
    -m "Candidate-manifest-sha256: $MANIFEST_SHA"
else
  echo "Reusing the exact canonical local tag after requalification."
fi
verify_local_tag_binding
git push origin "$VERSION"
echo "Tag submitted. Hosted exact-artifact install and publication checks are now running."
