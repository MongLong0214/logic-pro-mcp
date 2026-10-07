#!/usr/bin/env bash
# Owner-staged ADHOC release consumption. Qualification must already bind these
# final signed bytes. This script freezes/verifies/packages them, then tags only;
# release.yml is the sole publisher, after its same-byte and install checks.
# The trusted verifier/anchor are operator inputs outside the candidate bundle.
set -euo pipefail
VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DRY_RUN="${DRY_RUN:-0}"
if [ "$#" != 4 ] || ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH[-prerelease] FINAL_CANDIDATE PRIVATE_BUNDLE TRUSTED_VERIFIER" >&2
  exit 1
fi
cd "$REPO_ROOT"
if [ "$(git branch --show-current)" != main ]; then
  echo "Error: stable releases must be tagged from the main branch." >&2; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean." >&2; exit 1
fi
git fetch --quiet origin main --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Error: HEAD must match origin/main before publishing a release tag." >&2; exit 1
fi
if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "Error: tag already exists locally." >&2; exit 1
fi
REMOTE_TAGS=$(git ls-remote --tags origin "$VERSION")
if printf '%s\n' "$REMOTE_TAGS" | grep -q "refs/tags/$VERSION"; then
  echo "Error: tag already exists on origin." >&2; exit 1
fi
QUALIFIED=$(git rev-parse HEAD)
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
bash Scripts/release-consume-final.sh stage "${VERSION#v}" "$QUALIFIED" \
  "$2" "$3" "$4" "$STAGE_DIR/public"
BINARY_SHA=$(shasum -a 256 "$STAGE_DIR/public/LogicProMCP" | awk '{print $1}')
MANIFEST_SHA=$(cat "$STAGE_DIR/public/qualification-manifest.sha256")
if [ "$DRY_RUN" = 1 ]; then
  echo "DRY_RUN: verified staged bytes; no tag, push or release publication."
  exit 0
fi
git tag "$VERSION" -m "Release $VERSION" -m "Live-qualified: $QUALIFIED" \
  -m "Final-candidate-SHA256: $BINARY_SHA" -m "Qualification-manifest-SHA256: $MANIFEST_SHA"
git push origin "$VERSION"
echo "Tag submitted. Hosted same-byte verification and install validation must pass before publication."
