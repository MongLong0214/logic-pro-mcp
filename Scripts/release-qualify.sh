#!/bin/bash
#
# Scripts/release-qualify.sh — standalone live qualification test runner (#985).
#
# Ordinary tests must not drive Logic merely because a release executable exists.
# This runner prepares the debug tests, stages an already-built release candidate,
# requires running Logic and its permissions, then runs every real-server test in a
# fresh test process before the ordinary full
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

CANDIDATE="${1:-}"
if [ "$#" -ne 1 ] || [ ! -f "$CANDIDATE" ] || [ ! -x "$CANDIDATE" ]; then
    echo "Usage: $0 /path/to/executable/LogicProMCP" >&2
    exit 1
fi
CANDIDATE="$(cd "$(dirname "$CANDIDATE")" && pwd -P)/$(basename "$CANDIDATE")"
candidate_hash="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
test -n "$candidate_hash"

release_live_tests=(
    "realReleaseBinaryExecutesEveryOperationWithIndependentReadback"
    "runnerIgnoresPartialStateFaultEnvOnRealServer"
)
debug_live_tests=(
    "runnerRejectsPartialStateObservedFromRealServer"
)
test_inventory="$(swift test list)"
for live_test in "${release_live_tests[@]}" "${debug_live_tests[@]}"; do
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

mkdir -p .build/release
rm -f .build/release/LogicProMCP
cp "$CANDIDATE" .build/release/LogicProMCP
chmod 0755 .build/release/LogicProMCP

verify_candidate_bytes() {
    local candidate_now staged_now
    candidate_now="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
    staged_now="$(shasum -a 256 .build/release/LogicProMCP | awk '{print $1}')"
    if [ "$candidate_now" != "$candidate_hash" ] || [ "$staged_now" != "$candidate_hash" ]; then
        echo "Error: release candidate bytes changed during qualification." >&2
        return 1
    fi
}
verify_candidate_bytes
trap verify_candidate_bytes EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! pgrep -xq "Logic Pro"; then
    echo "Error: Logic Pro is not running. The live qualification tests in the suite need it (#985)." >&2
    exit 1
fi
if ! .build/release/LogicProMCP --check-permissions; then
    echo "Error: the release binary lacks a macOS permission the live qualification needs; the lines above name it (#985)." >&2
    exit 1
fi
for live_test in "${release_live_tests[@]}"; do
    LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --filter "$live_test"
    verify_candidate_bytes
done
if [ ! -x .build/debug/LogicProMCP ]; then
    echo "Error: the debug LogicProMCP executable required by the fault-negative live test is missing." >&2
    exit 1
fi
for live_test in "${debug_live_tests[@]}"; do
    LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --filter "$live_test"
    verify_candidate_bytes
done
swift test --no-parallel
verify_candidate_bytes
trap - EXIT INT TERM
