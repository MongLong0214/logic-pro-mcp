#!/bin/bash
#
# Scripts/release-qualify.sh — standalone live qualification test runner (#985).
#
# Ordinary tests must not drive Logic merely because a release executable exists.
# This runner prepares the debug tests, stages an already-built release candidate,
# requires running Logic and its permissions, then runs every real-server test in a
# fresh test process. The process boundary matters: production CoreMIDI endpoint ownership is
# intentionally held for a process lifetime, so an earlier unit test in the same
# test process must not contaminate the release binary's live ownership check.
# A missing process or permission still stops before testing; no live success is
# inferred. The general suite is not re-run here: hosted CI runs every test of the same
# candidate (the union of every test-shards shard), EXCEPT the tests that switch on only where
# Logic is installed. A hosted runner has no Logic and reports those as not run, which
# `verify-xunit` counts as run, so this Mac is the only place their bodies execute: after the live
# tests it runs exactly the host-gated, non-live tests below and fails unless every one passed.
#
# Release entrypoints consume staged final artifacts; this runner does not publish.
# The release contract tests cover the build-before-live ordering without replacing the runtime.
#
set -euo pipefail

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
test -d "$DEVELOPER_DIR"

TRUSTED_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
QUALIFICATION_ROOT="${2:-$TRUSTED_ROOT}"

CANDIDATE="${1:-}"
if { [ "$#" -ne 1 ] && [ "$#" -ne 2 ]; } || [ ! -d "$QUALIFICATION_ROOT" ] \
    || [ ! -f "$CANDIDATE" ] || [ ! -x "$CANDIDATE" ]; then
    echo "Usage: $0 /path/to/executable/LogicProMCP [/path/to/candidate-worktree]" >&2
    exit 1
fi
QUALIFICATION_ROOT="$(cd "$QUALIFICATION_ROOT" && pwd -P)"
cd "$QUALIFICATION_ROOT"
CANDIDATE="$(cd "$(dirname "$CANDIDATE")" && pwd -P)/$(basename "$CANDIDATE")"
candidate_hash="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
test -n "$candidate_hash"

# The live gate and the Apple corpus must describe the same installed Logic. These are not
# headless substitutes for the runtime below: they stop stale/tampered extraction, broken
# citations and incomplete locale maps before any UI write is attempted, while `status` compares
# the committed pin with this host's actual Logic build.
python3 Scripts/logic_canon.py status
python3 Scripts/check-canon-drift.py
python3 Scripts/check-canon-citations.py
python3 Scripts/check-policy-literals-against-canon.py
python3 Scripts/check-labelsets-are-derived.py
python3 Scripts/locale_labels.py --check

release_live_tests=(
    "realReleaseBinaryExecutesEveryOperationWithIndependentReadback"
    "runnerIgnoresPartialStateFaultEnvOnRealServer"
)
debug_live_tests=(
    "runnerRejectsPartialStateObservedFromRealServer"
)
# Every test marked `.requiresLogicHost` (Tests/LogicProMCPTests/SharedTestHelpers.swift). Keep this
# list equal to that set: HostGatedTestsContractTests fails when they differ, and when a host
# condition is written without the marker.
host_gated_tests=(
    "scanLocalFactoryLibraryReportsFullCoverage"
    "installedLibraryEmitsOnlyPanelCategories"
    "testProcessUtilsBundleURLResolvesWithoutAppKitRunloop"
    "testProcessUtilsLogicProVersionResolvesOffMain"
    "hostFactorySettingsFoldersAreAccountedFor"
)
test_inventory="$(swift test list)"
for live_test in ${release_live_tests[@]+"${release_live_tests[@]}"} ${debug_live_tests[@]+"${debug_live_tests[@]}"} \
        ${host_gated_tests[@]+"${host_gated_tests[@]}"}; do
    # A test method lists as `Module.Suite/name()`, a free function as `Module.name()`.
    match_count="$(
        printf '%s\n' "$test_inventory" | awk -v method="/${live_test}()" -v free="." -v name="${live_test}()" '
            {
                n = length(name)
                if (length($0) >= length(method) && substr($0, length($0) - length(method) + 1) == method) matches += 1
                else if (length($0) > n && substr($0, length($0) - n + 1) == name \
                         && substr($0, length($0) - n, 1) == free) matches += 1
            }
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
for live_test in ${release_live_tests[@]+"${release_live_tests[@]}"}; do
    LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --filter "$live_test"
    verify_candidate_bytes
done
if [ ! -x .build/debug/LogicProMCP ]; then
    echo "Error: the debug LogicProMCP executable required by the fault-negative live test is missing." >&2
    exit 1
fi
for live_test in ${debug_live_tests[@]+"${debug_live_tests[@]}"}; do
    LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --filter "$live_test"
    verify_candidate_bytes
done
# The host-gated, non-live tests, in one filtered run. They need Logic installed, not Logic driven,
# so they carry no LOGIC_PRO_MCP_RUN_LIVE_QA. A test that did not run would be absence reported as
# success, so a run in which fewer than all of them passed fails.
host_gated_log=".build/host-gated-tests.log"
host_gated_filters=()
for host_test in ${host_gated_tests[@]+"${host_gated_tests[@]}"}; do
    host_gated_filters+=(--filter "${host_test}\\(\\)")
done
swift test --no-parallel ${host_gated_filters[@]+"${host_gated_filters[@]}"} 2>&1 | tee "$host_gated_log"
verify_candidate_bytes
host_gated_passed="$(grep -cE '^✔ Test .* passed after' "$host_gated_log" || true)"
if [ "$host_gated_passed" -ne "${#host_gated_tests[@]}" ]; then
    echo "Error: ${#host_gated_tests[@]} host-gated tests must each pass on this host; $host_gated_passed passed (see $host_gated_log)." >&2
    exit 1
fi
verify_candidate_bytes
trap - EXIT INT TERM
