#!/bin/bash
#
# Scripts/release-qualify.sh — the live qualification gate every release script runs (#985).
#
# The suite's live qualification tests are enabled only when .build/release/LogicProMCP exists, and they drive that
# binary against a running Logic. So the release binary is built from this tree first, the gate stops unless Logic is
# running and that binary reports every macOS permission it needs, and only then does the whole suite run. Run before
# the build, those tests drove whatever binary the tree built last, or were skipped. A running Logic alone was not
# enough: the release needs a permissioned one, and how the suite behaves without the grants was never measured.
#
# Scripts/release.sh and Scripts/release-stable.sh both call this script, so the order lives in one place.
# Scripts/test_release_builds_before_live_qualification.py runs it with a stubbed `swift`, `pgrep` and release binary.
#
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
if ! pgrep -xq "Logic Pro"; then
    echo "Error: Logic Pro is not running. The live qualification tests in the suite need it (#985)." >&2
    exit 1
fi
if ! .build/release/LogicProMCP --check-permissions; then
    echo "Error: the release binary lacks a macOS permission the live qualification needs; the lines above name it (#985)." >&2
    exit 1
fi
swift test --no-parallel
