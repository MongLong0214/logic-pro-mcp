#!/bin/bash
# Prove check_review_integrity.sh against its own subject matter.
#
# A checker that has never been shown to fail is exactly what it exists to catch. Two of these fixtures are
# real: `review-interleaved-damaged.txt` is the review that actually arrived with two of its own output
# streams spliced together, and `review-fenced-clean.md` is the shape that a first version of the checker
# wrongly called damaged — a fence is three backticks, so it is always odd, and every review carrying a
# reproduction command tripped it. That false alarm mattered more than most: this check's failure path is
# "discard the verdict", the same call that nearly threw away thirteen findings including a blocker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_review_integrity.sh"
FIX="$HERE/fixtures"
FAILED=0

expect() { # <expected-exit> <file> <why>
    bash "$CHECK" "$2" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$1" ]; then
        printf 'ok   %-40s %s\n' "$(basename "$2")" "$3"
    else
        printf 'FAIL %-40s expected exit %s, got %s — %s\n' "$(basename "$2")" "$1" "$got" "$3"
        FAILED=1
    fi
}

expect 0 "$FIX/review-fenced-clean.md"            "a normal review with a fenced reproduction command is intact"
expect 1 "$FIX/review-interleaved-damaged.txt"    "the real spliced review is rejected"
expect 1 "$FIX/review-missing-middle-finding.md"  "a gap in the k/N sequence is a dropped finding"
expect 2 "$FIX/review-uncheckable.md"             "no ordinals and no count is undetermined, NOT a pass"

[ "$FAILED" -eq 0 ] || { echo; echo "review-integrity checker is not doing its job"; exit 1; }
echo
echo "check_review_integrity.sh proven against 4 cases including the real damaged review"
