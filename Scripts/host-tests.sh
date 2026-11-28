#!/bin/bash
#
# Scripts/host-tests.sh NOT_RUN_JSON [RESULTS_PARENT] — run the tests that execute only where Logic is
# installed, and require each of them to have executed and passed.
#
# Hosted CI has no Logic, so it reports these tests as not run (Tests/not-run-on-hosted.json, class
# logic_host); this Mac is the only place their bodies execute. The tests come from the candidate's
# list, by full test ID, through an anchored and escaped filter. The result comes from the xUnit
# file of the run, never from console text: for each listed ID it must be present, executed and
# free of failure or error, and a testcase that is not on the list fails too. This script drives
# no Logic and needs no live-QA flag; it runs from the directory of the checkout to qualify.
#
# The results go to a fresh directory this script creates with mktemp under RESULTS_PARENT
# (default .build/host-tests). Nothing the caller already has is deleted, replaced or reused, and
# the list is validated before the filesystem is touched.
#
# HOST_TESTS_NO_BUILD=1 reuses an existing build (for running this step on its own).
set -euo pipefail

NOT_RUN="${1:-}"
PARENT="${2:-.build/host-tests}"
if [ -z "$NOT_RUN" ] || [ ! -f "$NOT_RUN" ]; then
    echo "Usage: $0 /path/to/not-run-on-hosted.json [results-parent-directory]" >&2
    exit 1
fi
HELPER="$(cd "$(dirname "$0")" && pwd -P)/ci-test-shard-manifest.py"

filter="$(python3 "$HELPER" host-filter --not-run "$NOT_RUN")"
mkdir -p "$PARENT"
OUTPUT="$(mktemp -d "$PARENT/run.XXXXXX")"

args=(test --no-parallel --xunit-output "$OUTPUT/results.xml" --filter "$filter")
if [ "${HOST_TESTS_NO_BUILD:-}" = 1 ]; then
    args+=(--skip-build)
fi
swift_status=0
swift ${args[@]+"${args[@]}"} || swift_status=$?
python3 "$HELPER" verify-host --not-run "$NOT_RUN" --xunit-directory "$OUTPUT"
if [ "$swift_status" -ne 0 ]; then
    echo "Error: the host tests exited $swift_status." >&2
    exit "$swift_status"
fi
echo "Host tests: every logic_host test in $NOT_RUN executed and passed."
