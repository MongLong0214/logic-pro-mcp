#!/usr/bin/env bash
# Stable tags use the same CLT qualification and hosted sole publisher.
set -euo pipefail
if [ "$#" != 1 ] || ! [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2
  exit 1
fi
REPO="${GITHUB_REPOSITORY:-MongLong0214/logic-pro-mcp}"
gh auth status >/dev/null
if gh release view "$1" --repo "$REPO" >/dev/null 2>&1; then
  echo "Error: GitHub Release already exists." >&2
  exit 1
fi
exec bash "$(dirname "$0")/release.sh" "$@"
