#!/usr/bin/env bash
# Qualify one exact main commit, then submit an unsigned release tag.
# GitHub Actions builds the universal archive, verifies its checksum and install,
# and publishes the release only after those checks pass.
set -euo pipefail

VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DRY_RUN="${DRY_RUN:-0}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

if [ "$#" -ne 1 ] || ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH[-prerelease]" >&2
  exit 1
fi
test -d "$DEVELOPER_DIR"
cd "$REPO_ROOT"

if [ "$(git branch --show-current)" != main ]; then
  echo "Error: releases must be tagged from the main branch." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean." >&2
  exit 1
fi
git fetch --quiet origin main --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Error: HEAD must match origin/main before publishing a release tag." >&2
  exit 1
fi
if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "Error: tag already exists locally." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "Error: tag already exists on origin." >&2
  exit 1
fi

bash Scripts/release-qualify.sh
git diff --exit-code Package.resolved

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY_RUN: source and native qualification passed; no tag was created."
  exit 0
fi

QUALIFIED="$(git rev-parse HEAD)"
git tag "$VERSION" -m "Release $VERSION" -m "Native-qualified: $QUALIFIED"
git push origin "$VERSION"
echo "Tag submitted. Hosted CLT build, checksum, install and publication checks are now running."
