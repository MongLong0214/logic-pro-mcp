#!/usr/bin/env bash
# The coverage gate: locate THIS run's test binary and profile, build the report, enforce the
# thresholds. Everything except actually running the tests.
#
# It was 90 lines inline in `.github/workflows/ci.yml`, which is the same reason
# `ci-verify-formula-sha.sh` exists: a gate that only runs inside a workflow can only be tested by
# pushing, and the states worth testing are the ones where it should REFUSE. Every refusal below
# has a case in `Scripts/test_ci_coverage_gate.py`, driven against a fake `llvm-cov`.
#
# Usage:
#   ci-coverage-gate.sh                 # read .build, report to coverage-report.txt
#
# Environment, all with defaults, all named so the self-test can aim this at a fixture:
#   LPM_COVERAGE_BUILD_DIR   where to look for the test binary and profdata   (.build)
#   LPM_COVERAGE_SOURCES     the directory whose .swift files are measured    (Sources/LogicProMCP)
#   LPM_COVERAGE_REPORT      where the report is written                      (coverage-report.txt)
#   LPM_LLVM_COV             the report command                              (xcrun llvm-cov)
#   LPM_COVERAGE_MIN_REGION  hard floor, percent                             (70)
#   LPM_COVERAGE_MIN_LINE    hard floor, percent                             (78)
#   LPM_COVERAGE_TARGET      a notice, not a gate                            (90)
#
# Exit 0 clean, 1 on anything it cannot resolve or a threshold missed. There is deliberately no
# exit code for "could not tell": a coverage gate that cannot measure has not passed.
set -euo pipefail

BUILD_DIR="${LPM_COVERAGE_BUILD_DIR:-.build}"
SOURCES="${LPM_COVERAGE_SOURCES:-Sources/LogicProMCP}"
REPORT="${LPM_COVERAGE_REPORT:-coverage-report.txt}"
LLVM_COV="${LPM_LLVM_COV:-xcrun llvm-cov}"
MIN_REGION="${LPM_COVERAGE_MIN_REGION:-70}"
MIN_LINE="${LPM_COVERAGE_MIN_LINE:-78}"
TARGET="${LPM_COVERAGE_TARGET:-90}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# EXACTLY one of each. `find | head -1` took whichever the filesystem listed first, so a tree
# holding two architectures' builds -- or a stale one beside a fresh one -- resolved silently and
# the report could be about a binary these tests did not produce. Two matches is a state this gate
# may not settle by picking.
find "$BUILD_DIR" -type f -path '*/debug/LogicProMCPPackageTests.xctest/Contents/MacOS/LogicProMCPPackageTests' > "$WORK/bins.txt" 2>/dev/null || true
find "$BUILD_DIR" -type f -path '*/debug/codecov/default.profdata' > "$WORK/profs.txt" 2>/dev/null || true
BIN_COUNT=$(grep -c . "$WORK/bins.txt" || true)
PROF_COUNT=$(grep -c . "$WORK/profs.txt" || true)

if [ "$BIN_COUNT" != "1" ] || [ "$PROF_COUNT" != "1" ]; then
  echo "::error::Expected exactly one test binary and one profdata; found $BIN_COUNT and $PROF_COUNT."
  echo "binaries:"; cat "$WORK/bins.txt"
  echo "profdata:"; cat "$WORK/profs.txt"
  find "$BUILD_DIR" -maxdepth 4 -type d 2>/dev/null | head -30
  exit 1
fi

BIN=$(cat "$WORK/bins.txt")
PROFDATA=$(cat "$WORK/profs.txt")
echo "Test binary: $BIN"
echo "Profdata:    $PROFDATA"

find "$SOURCES" -name '*.swift' | sort > "$WORK/sources.txt"
if ! [ -s "$WORK/sources.txt" ]; then
  echo "::error::No .swift files under $SOURCES, so the report would measure nothing."
  exit 1
fi

# shellcheck disable=SC2086
xargs $LLVM_COV report "$BIN" -instr-profile "$PROFDATA" < "$WORK/sources.txt" > "$REPORT"

if ! [ -s "$REPORT" ]; then
  echo "::error::The coverage report is empty."
  exit 1
fi

# One TOTAL line, not "at least one". Two of them make `$TOTAL_LINE` two lines, `awk` print two
# fields, and the shape check below fail for a reason that reads as a column-order change rather
# than as a report this gate cannot parse. Say which it is.
TOTAL_COUNT=$(grep -cE "^TOTAL" "$REPORT" || true)
if [ "$TOTAL_COUNT" != "1" ]; then
  echo "::error::The coverage report has $TOTAL_COUNT TOTAL lines; this gate reads one."
  tail -5 "$REPORT"
  exit 1
fi

TOTAL_LINE=$(grep -E "^TOTAL" "$REPORT")
# llvm-cov column order: regions, missed, cover%, functions, missed, cover%, lines, missed, cover%.
# A future version that prepends a column would silently grab a different field, so the shape is
# checked before the number is compared.
# THE COLUMN NAMES, in order, from the report's own header.
#
# The first version of this check counted fields and demanded ten. That was wrong about the shape
# and it broke the gate: real llvm-cov on the runner emits THIRTEEN, because it appends
# `Branches Missed-Branches Cover` after the line group --
#
#   TOTAL  24107  4929  79.55%  6698  1199  82.10%  74463  9266  87.56%  0  0  -
#
# -- and appending does not move fields 4 and 10, which are still region cover and line cover. The
# harmful change is an INSERTION before or between the groups this gate reads, and a field count
# cannot tell the two apart: both produce thirteen.
#
# The header can. `Regions` must be the first group and `Lines` must be the third, so the third
# and ninth data columns are the covers this gate compares. A group appearing before `Lines` that
# is not `Regions` or `Functions` has shifted them.
HEADER=$(head -1 "$REPORT")
case "$HEADER" in
  *Regions*Functions*Lines*) : ;;
  *)
    echo "::error::the report's header does not name Regions, then Functions, then Lines."
    echo "::error::header was: $HEADER"
    echo "::error::This gate reads region cover from field 4 and line cover from field 10, which"
    echo "::error::is only true while those three groups come first and in that order."
    exit 1 ;;
esac
BEFORE_LINES=${HEADER%%Lines*}
case "$BEFORE_LINES" in
  *Branches*|*Instantiations*)
    echo "::error::a column group appears before Lines that this gate does not account for."
    echo "::error::header was: $HEADER"
    echo "::error::Region and line cover are read positionally, so a group inserted ahead of them"
    echo "::error::makes both numbers name a different measurement while still looking like one."
    exit 1 ;;
esac
# And the line must still be long enough to HOLD field 10. A truncated report would otherwise
# reach the pattern check with an empty field, which reads as a format change rather than as a
# report that stops early.
TOTAL_FIELDS=$(echo "$TOTAL_LINE" | awk '{print NF}')
if [ "$TOTAL_FIELDS" -lt 10 ]; then
  echo "::error::the TOTAL line has $TOTAL_FIELDS fields; field 10 is the line coverage."
  echo "::error::TOTAL line was: $TOTAL_LINE"
  exit 1
fi
REGION_RAW=$(echo "$TOTAL_LINE" | awk '{print $4}')
LINE_RAW=$(echo "$TOTAL_LINE" | awk '{print $10}')
for pair in "region:$REGION_RAW" "line:$LINE_RAW"; do
  name="${pair%%:*}"; raw="${pair#*:}"
  if ! echo "$raw" | grep -qE '^[0-9]+\.[0-9]+%$'; then
    echo "::error::$name coverage field '$raw' did not match <float>% pattern."
    echo "::error::TOTAL line was: $TOTAL_LINE"
    echo "::error::This usually means llvm-cov column order changed; review the awk extraction."
    exit 1
  fi
done
REGION_PCT="${REGION_RAW%\%}"
LINE_PCT="${LINE_RAW%\%}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Coverage report"
    echo ""
    echo '```'
    echo "$TOTAL_LINE"
    echo '```'
    echo ""
    echo "Hard thresholds: region >= $MIN_REGION%, line >= $MIN_LINE%."
    echo "Coverage target: line >= $TARGET%."
  } >> "$GITHUB_STEP_SUMMARY"
fi

FAIL=0
# Bash arithmetic does not handle floats; awk does the comparison.
REGION_OK=$(awk -v r="$REGION_PCT" -v m="$MIN_REGION" 'BEGIN { print (r+0 >= m+0) ? 1 : 0 }')
LINE_OK=$(awk -v l="$LINE_PCT" -v m="$MIN_LINE" 'BEGIN { print (l+0 >= m+0) ? 1 : 0 }')
if [ "$REGION_OK" != "1" ]; then
  echo "::error::Region coverage $REGION_PCT% below threshold $MIN_REGION%."
  FAIL=1
fi
if [ "$LINE_OK" != "1" ]; then
  echo "::error::Line coverage $LINE_PCT% below threshold $MIN_LINE%."
  FAIL=1
fi
[ "$FAIL" = "1" ] && exit 1

TARGET_OK=$(awk -v l="$LINE_PCT" -v m="$TARGET" 'BEGIN { print (l+0 >= m+0) ? 1 : 0 }')
if [ "$TARGET_OK" != "1" ]; then
  echo "::notice::Line coverage $LINE_PCT% is below the $TARGET% target; the hard gate remains $MIN_LINE%."
fi
echo "Coverage gate passed: region $REGION_PCT% / line $LINE_PCT%."
