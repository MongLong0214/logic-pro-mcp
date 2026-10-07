#!/usr/bin/env bash
# Stable tags use the same final-artifact consumer and hosted sole publisher.
set -euo pipefail
if [ "$#" != 4 ] || ! [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH FINAL_CANDIDATE PRIVATE_BUNDLE TRUSTED_VERIFIER" >&2
  exit 1
fi
REPO="${GITHUB_REPOSITORY:-MongLong0214/logic-pro-mcp}"
gh auth status >/dev/null
if gh release view "$1" --repo "$REPO" >/dev/null 2>&1; then
  echo "Error: GitHub Release already exists." >&2
  exit 1
fi
exec bash "$(dirname "$0")/release.sh" "$@"
