#!/usr/bin/env bash
# The Formula's sha256 must be the hash of the release its own version names.
#
# #775: v3.15.0 shipped with the v3.14.0 hash still in the Formula, so every `brew install
# logic-pro-mcp` failed on the install path the README documents. `version` and `sha256` are one
# edit and only one of them was mechanically required — `Scripts/release-verify-formula-install-
# paths.sh` verifies this same file, but it checks the install PATHS and never looks at the hash.
#
# This is a CI step rather than a `check-*.py` on purpose. `run-repo-guards.py` states its contract
# as "plain Python needing neither Xcode nor a network", and the only way to know a hash is right is
# to ask the release what it published. So the network lives here, where CI already has it.
#
# Usage:
#   ci-verify-formula-sha.sh                       # fetch the named release from GitHub
#   ci-verify-formula-sha.sh <SHA256SUMS.txt>      # compare against a local file (used by the test)
#
# `LPM_FORMULA_PATH` overrides which Formula is read; the self-test uses it.
#
# Exit 0 clean, 1 on mismatch, 2 if the Formula could not be parsed. A network failure against a
# release that EXISTS is not a pass: it exits 1 and says the check could not be made, because "could
# not ask" and "the answer was yes" are the confusion this whole class of defect is made of. The one
# deliberate exception is a version whose release is not published yet — see below.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# A named test seam rather than an argument, so the two things a caller passes stay "which sums" and
# nothing else. The self-test needs to point the rule at a Formula it wrote, and a guard that cannot
# be aimed at a fixture cannot be shown to fail.
FORMULA="${LPM_FORMULA_PATH:-$ROOT/Formula/logic-pro-mcp.rb}"
ASSET="LogicProMCP-macOS-universal.tar.gz"
LOCAL_SUMS="${1:-}"

[ -f "$FORMULA" ] || { echo "no Formula at $FORMULA"; exit 2; }

VERSION=$(grep -m1 -E '^[[:space:]]*version[[:space:]]+"' "$FORMULA" | sed -E 's/.*"([^"]+)".*/\1/')

# One artifact, one hash. Today the Formula ships a single universal tarball, and reading only the
# first `sha256` would be exactly right and would go on looking right if someone added an arm64
# block underneath — the second hash would never be compared to anything, silently, which is the
# same shape as the defect this guard exists for. Refuse instead of checking half.
SHA_LINES=$(grep -cE '^[[:space:]]*sha256[[:space:]]+"' "$FORMULA")
if [ "$SHA_LINES" -gt 1 ]; then
  echo "the Formula carries $SHA_LINES sha256 lines; this rule only understands one artifact."
  echo "Teach it which url each hash belongs to before adding another, or it will check one and"
  echo "ignore the rest."
  exit 2
fi

PINNED=$(grep -m1 -E '^[[:space:]]*sha256[[:space:]]+"' "$FORMULA" | sed -E 's/.*"([0-9a-f]{64})".*/\1/')

[ -n "$VERSION" ] || { echo "could not read version from the Formula"; exit 2; }
printf '%s' "$PINNED" | grep -qE '^[0-9a-f]{64}$' || { echo "could not read a sha256 from the Formula"; exit 2; }

if [ -n "$LOCAL_SUMS" ]; then
  [ -f "$LOCAL_SUMS" ] || { echo "no such sums file: $LOCAL_SUMS"; exit 2; }
  SUMS=$(cat "$LOCAL_SUMS")
else
  command -v gh >/dev/null 2>&1 || { echo "gh is not available, so the Formula's hash could not be checked"; exit 1; }

  # A version bumped BEFORE its release is tagged is the normal release-prep state, not a defect, and
  # failing it would block the very pull request that prepares a release. So "no such release yet" is
  # a pass with a loud line, while a release that EXISTS and disagrees is a failure — which is the
  # shape #775 actually had: v3.15.0 was published and the Formula still pinned v3.14.0's hash.
  if ! gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "v$VERSION is not published yet, so there is nothing to compare the Formula against."
    echo "This check becomes meaningful once the release exists; it is NOT confirmation that the"
    echo "pinned hash is right."
    exit 0
  fi

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  if ! gh release download "v$VERSION" -p 'SHA256SUMS.txt' -O "$TMP/sums.txt" --clobber >/dev/null 2>&1; then
    echo "v$VERSION exists but its SHA256SUMS.txt could not be downloaded, so the Formula's hash"
    echo "could not be checked. That is a failure rather than a pass: the release is there and the"
    echo "check could not be made."
    exit 1
  fi
  SUMS=$(cat "$TMP/sums.txt")
fi

PUBLISHED=$(printf '%s\n' "$SUMS" | awk -v a="$ASSET" '$2 == a || $2 == "*" a {print $1}' | head -1)

if [ -z "$PUBLISHED" ]; then
  echo "v$VERSION publishes no $ASSET, so the Formula names an artifact that is not there"
  exit 1
fi

if [ "$PINNED" != "$PUBLISHED" ]; then
  echo "Formula/logic-pro-mcp.rb pins a hash that is not v$VERSION's $ASSET:"
  echo "  Formula pins  $PINNED"
  echo "  v$VERSION has $PUBLISHED"
  echo
  echo "brew install fails for everyone until these agree. Copy the published hash into the Formula,"
  echo "or bump the version to the release the hash belongs to."
  exit 1
fi

echo "Formula sha256 matches v$VERSION's $ASSET"
exit 0
