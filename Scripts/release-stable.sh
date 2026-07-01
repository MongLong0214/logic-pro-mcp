#!/bin/bash
#
# Scripts/release-stable.sh — guarded stable ADHOC release tag publisher.
#
# Stable tags trigger .github/workflows/release.yml. Apple Developer ID is
# optional: if notarization secrets are absent, the workflow publishes the
# historical ADHOC artifact with SHA256 + codesign verification metadata.
# This script keeps the stable tag gate on clean main, duplicate tag/release
# checks, and deterministic local build/test gates before pushing the tag.
#
# Usage:
#   Scripts/release-stable.sh v3.4.6
#   DRY_RUN=1 Scripts/release-stable.sh v3.4.6
#
set -euo pipefail

VERSION="${1:-}"
REPO="${GITHUB_REPOSITORY:-MongLong0214/logic-pro-mcp}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"

usage() {
    echo "Usage: $0 vMAJOR.MINOR.PATCH"
}

run() {
    echo "→ $*"
    if [ "$DRY_RUN" != "1" ]; then
        "$@"
    fi
}

if [ -z "$VERSION" ]; then
    usage
    exit 1
fi

if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: stable VERSION '$VERSION' must be strict SemVer, e.g. v3.4.6"
    echo "       Use Scripts/release.sh vX.Y.Z-rcN for ADHOC prereleases."
    exit 1
fi

cd "$REPO_ROOT"

echo ""
echo "  Logic Pro MCP — stable ADHOC release preflight"
echo "  version: $VERSION"
echo "  repo:    $REPO"
echo "  dry-run: $DRY_RUN"
echo ""

if [ "$(git branch --show-current)" != "main" ]; then
    echo "Error: stable releases must be tagged from the main branch."
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working tree is not clean. Commit or stash first."
    git status --short
    exit 1
fi

run git fetch --quiet origin main --tags

if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "Error: HEAD must match origin/main before publishing a stable tag."
    echo "       Push or pull main first, then rerun this script."
    exit 1
fi

if git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "Error: tag $VERSION already exists locally."
    exit 1
fi

REMOTE_TAGS=$(git ls-remote --tags origin "$VERSION") || {
    echo "Error: could not verify remote tag availability for $VERSION."
    echo "       Refusing to continue because a duplicate stable tag cannot be fixed safely."
    exit 1
}
if printf '%s\n' "$REMOTE_TAGS" | grep -q "refs/tags/$VERSION"; then
    echo "Error: tag $VERSION already exists on origin."
    exit 1
fi

gh auth status >/dev/null

if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "Error: GitHub Release $VERSION already exists."
    exit 1
fi

run python3 -m py_compile Scripts/live-e2e-test.py Scripts/logic_bounce.py Scripts/logic_bounce_test.py Scripts/logic_bounce_main_test.py Scripts/logic_bounce_support_test.py Scripts/logic_bounce_ui.py Scripts/logic_bounce_ui_test.py Scripts/logic_input_source.py Scripts/logic_session_bootstrap.py Scripts/logic_session_bootstrap_test.py Scripts/logic_session_bootstrap_action_test.py Scripts/logic_ui_jxa.py Scripts/logic_ui_jxa_test.py Scripts/logic_free_tempo_modal.py Scripts/logic_free_tempo_modal_test.py Scripts/logic_controller_learn_mode.py Scripts/logic_controller_learn_mode_test.py Scripts/logic_key_event_test.py
run python3 Scripts/logic_bounce_test.py
run python3 Scripts/logic_session_bootstrap_test.py
run python3 Scripts/logic_session_bootstrap_action_test.py
run python3 Scripts/logic_ui_jxa_test.py
run python3 Scripts/logic_free_tempo_modal_test.py
run python3 Scripts/logic_controller_learn_mode_test.py
run python3 Scripts/logic_key_event_test.py
run swiftc -typecheck Scripts/logic_key_event.swift
run swiftc -typecheck Scripts/logic_ui_snapshot.swift
run swiftc -typecheck Scripts/logic_ax_button_press.swift
run swift test --no-parallel
run swift build -c release

run git tag "$VERSION" -m "Release $VERSION"
run git push origin "$VERSION"

echo ""
echo "  Stable tag published: $VERSION"
echo "  GitHub Actions release workflow will build, ADHOC-sign if Developer ID"
echo "  secrets are absent, publish artifacts, then run install validation on"
echo "  macos-14 and macos-15."
echo ""
