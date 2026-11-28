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
# candidate (the union of every test-shards shard), and each test it reports as not run must be named
# in Tests/not-run-on-hosted.json. This Mac is where those tests execute. The live ones are
# selected from that file's `live` entries (each names its lane, release or debug), one fresh test
# process per test, by exact anchored ID, and the `logic_host` ones run afterwards the same way
# (Scripts/host-tests.sh). For every one of them the xUnit output of the run must show the test
# present, executed and unfailed, so a test that reports itself as not run fails the step. The `operator`
# entries exempt a test from running, so they come from the trusted checkout's copy of the file:
# a candidate cannot add one.
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

HELPER="$TRUSTED_ROOT/Scripts/ci-test-shard-manifest.py"
NOT_RUN=Tests/not-run-on-hosted.json
# An `operator` entry runs the test nowhere, so a candidate may carry only the ones the trusted
# copy of the file already has. Before the file first reaches main there is no trusted copy and the
# helper accepts exactly its one built-in ID (BOOTSTRAP_OPERATOR_IDS) and nothing else.
python3 "$HELPER" verify-trusted --not-run "$NOT_RUN" --trusted "$TRUSTED_ROOT/$NOT_RUN"
# The live tests are the file's `live` entries: no list of names lives in this script.
python3 "$HELPER" list-ids --not-run "$NOT_RUN" --class live > /dev/null
test_inventory="$(swift test list)"
# Each listed ID must name exactly one listed test before any live test executes.
printf '%s\n' "$test_inventory" | python3 "$HELPER" verify-inventory --inventory /dev/stdin --not-run "$NOT_RUN"

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
# One live lane: each test of the lane in a fresh process, selected by its exact anchored ID, and
# judged from that process's xUnit output (present, executed, unfailed), whatever the exit status.
run_live_lane() {
    local lane="$1" ids id results filter live_status
    ids="$(python3 "$HELPER" list-ids --not-run "$NOT_RUN" --class live --lane "$lane")"
    if [ -z "$ids" ]; then
        return 0
    fi
    mkdir -p .build/live-tests
    while IFS= read -r id; do
        results="$(mktemp -d ".build/live-tests/$lane.XXXXXX")"
        filter="$(python3 "$HELPER" host-filter --not-run "$NOT_RUN" --class live --lane "$lane" --id "$id")"
        live_status=0
        LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel --xunit-output "$results/results.xml" \
            --filter "$filter" || live_status=$?
        python3 "$HELPER" verify-host --not-run "$NOT_RUN" --class live --lane "$lane" --id "$id" \
            --xunit-directory "$results"
        if [ "$live_status" -ne 0 ]; then
            echo "Error: the live test $id exited $live_status." >&2
            exit "$live_status"
        fi
        verify_candidate_bytes
    done <<< "$ids"
}
run_live_lane release
if [ ! -x .build/debug/LogicProMCP ]; then
    echo "Error: the debug LogicProMCP executable required by the fault-negative live test is missing." >&2
    exit 1
fi
run_live_lane debug
# The logic_host tests need Logic installed, not Logic driven, so they carry no
# LOGIC_PRO_MCP_RUN_LIVE_QA. The qualifier is the trusted script; the list is the candidate's, so a
# pull request that adds such a test is enforced by its own native run. A test that did not execute
# would be absence reported as success, so host-tests.sh fails unless every listed test passed.
bash "$TRUSTED_ROOT/Scripts/host-tests.sh" Tests/not-run-on-hosted.json .build/host-tests
verify_candidate_bytes
trap - EXIT INT TERM
