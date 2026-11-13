#!/bin/bash
#
# Scripts/release-qualify.sh — standalone live qualification test runner (#985).
#
# Ordinary tests must not drive Logic merely because a release executable exists.
# This runner builds the current tree, requires running Logic and its permissions,
# then runs every real-server test in a fresh test process before the ordinary full
# suite. The process boundary matters: production CoreMIDI endpoint ownership is
# intentionally held for a process lifetime, so an earlier unit test in the same
# test process must not contaminate the release binary's live ownership check.
# A missing process or permission still stops before testing; no live success is
# inferred, and the final suite remains unfiltered.
#
# Release entrypoints consume staged final artifacts; this runner does not publish.
# The release contract tests cover the build-before-live ordering without replacing the runtime.
#
set -euo pipefail

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
test -d "$DEVELOPER_DIR"

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
live_tests=(
    "realReleaseBinaryExecutesEveryOperationWithIndependentReadback"
    "runnerIgnoresPartialStateFaultEnvOnRealServer"
    "runnerRejectsPartialStateObservedFromRealServer"
)
test_inventory="$(swift test list)"
for live_test in "${live_tests[@]}"; do
    match_count="$(
        printf '%s\n' "$test_inventory" | awk -v suffix="/${live_test}()" '
            length($0) >= length(suffix) &&
                substr($0, length($0) - length(suffix) + 1) == suffix { matches += 1 }
            END { print matches + 0 }
        '
    )"
    if [[ "$match_count" -ne 1 ]]; then
        echo "Error: live qualification filter '$live_test' matched $match_count tests; expected exactly one." >&2
        exit 1
    fi
done
for live_test in "${live_tests[@]}"; do
    LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --filter "$live_test"
done
swift test --no-parallel
