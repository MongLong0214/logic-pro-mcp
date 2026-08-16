#!/bin/bash
# Verify a blind-review output was not damaged in transit.
#
# On 2026-08-16 a review arrived with two of its own output streams interleaved. Its first 506 lines were
# unrecoverable; the remaining 270 were intact and held 14 findings including a BLOCKER. Two lessons are
# built in here:
#
#   * The ENVELOPE and the CONTENTS fail separately. "These are all the findings" is a property of the
#     envelope and dies with it. An individual finding carrying file:line citations and a reproduction
#     path verifies against the repo on its own terms and survives.
#   * It was caught only because the corruption fell mid-word. At a paragraph boundary the result is
#     grammatical, complete-looking, and silently missing a finding.
#
# Exit codes are distinct because "damaged" and "cannot be checked" are different answers:
#   0  intact
#   1  damage detected — discard the verdict; individual findings may still be verified on their own
#   2  integrity CANNOT be determined — the check did not run, which is not the same as passing
#
# Usage: check_review_integrity.sh <review-output-file>
set -uo pipefail
F="${1:?usage: check_review_integrity.sh <review-output>}"
DAMAGED=0
fail() { echo "-> REVIEW INTEGRITY FAIL: $1"; DAMAGED=1; }
# "cannot be checked" only stands when nothing else already answered the question. A spliced file usually
# loses its count line as well, and exiting 2 there would report an open question about a file whose damage
# has already been seen.
undetermined() {
    echo "-> REVIEW INTEGRITY UNDETERMINED: $1"
    [ "$DAMAGED" -eq 0 ] || return 0
    exit 2
}

[ -s "$F" ] || undetermined "empty output — nothing to check"

# --- splice markers first: what interleaving leaves that prose never does ---------------------------
# These run BEFORE the count checks on purpose. A spliced file often loses its count line too, and
# reporting "integrity undetermined" for a file whose damage is visible understates what is known.
# Observed damage outranks an unanswerable question.
MIDHASH=$(grep -cE '.+###' "$F")
[ "$MIDHASH" -eq 0 ] || fail "$MIDHASH line(s) carry '###' inside the line — a heading was spliced into other text"
# Fenced blocks are skipped, fence lines included: a fence is three backticks, so it is ALWAYS odd, and
# code legitimately contains unpaired backticks. Without this every review carrying a reproduction command
# was called damaged — and this check's failure path is "discard the verdict", the same decision that
# nearly threw away thirteen findings including a blocker. A false alarm here costs as much as a miss.
#
# Known blind spot, stated rather than papered over: interleaving that falls entirely inside a fenced
# block is invisible to this signal. The mid-line `###` check and the ordinal sequence cover that case.
ODD=$(awk '
  /^[[:space:]]*```/ { infence = !infence; next }
  !infence           { n = gsub(/`/, "`"); if (n % 2 == 1) c++ }
  END                { print c+0 }
' "$F")
[ "$ODD" -eq 0 ] || fail "$ODD line(s) have an unbalanced code span — text was cut mid-token"

# --- ordinals: the primary count, because they survive a lost tail ---------------------------------
# Each finding heading carries `[k/N]`. A missing middle finding shows as a gap (1,2,4) and a lost tail
# still leaves N known, so "I have 9 of 14" is countable. A single trailing FINDINGS line cannot do that.
ORDINALS=$(grep -oE '^(#{2,3}|\*\*) *\[[0-9]+/[0-9]+\]' "$F" | grep -oE '[0-9]+/[0-9]+' || true)
# Reviewers write findings as `### MAJOR — …` or `**MAJOR — …**`; both count. Missing the second
# spelling made this checker report 0 headings on a perfectly good review — a false alarm is as useless
# as a missed one.
HEADINGS=$(grep -cE '^(#{2,3} *(\[[0-9]+/[0-9]+\] *)?|\*\*)(BLOCKER|MAJOR|MINOR)' "$F")

if [ -n "$ORDINALS" ]; then
    TOTAL=$(printf '%s\n' "$ORDINALS" | cut -d/ -f2 | sort -u)
    [ "$(printf '%s\n' "$TOTAL" | wc -l | tr -d ' ')" = "1" ] \
        || fail "findings disagree about the total ($(echo $TOTAL | tr '\n' ' ')) — two outputs were spliced"
    SEEN=$(printf '%s\n' "$ORDINALS" | cut -d/ -f1 | sort -n | uniq | tr '\n' ' ')
    COUNT=$(printf '%s\n' "$ORDINALS" | cut -d/ -f1 | sort -nu | wc -l | tr -d ' ')
    [ "$COUNT" = "$(echo $TOTAL | head -1)" ] \
        || fail "have findings [$SEEN] of $TOTAL — $(( $(echo $TOTAL|head -1) - COUNT )) missing"
else
    DECLARED=$(grep -oE '^FINDINGS: *[0-9]+' "$F" | tail -1 | grep -oE '[0-9]+' || true)
    [ -n "$DECLARED" ] || undetermined "no [k/N] ordinals and no 'FINDINGS: N' line — a dropped finding cannot be detected"
    [ "$DECLARED" = "$HEADINGS" ] || fail "declared $DECLARED findings, found $HEADINGS headings"
fi

VERDICTS=$(grep -cE '^`?VERDICT: (MERGE|DO NOT MERGE)' "$F")
[ "$VERDICTS" = "1" ] || fail "expected exactly one VERDICT line, found $VERDICTS"

# --- splice markers: what interleaving leaves that prose never does --------------------------------
# Measured on the real pair, same minute and flags: corrupted 12 mid-line '###' and 142/488 odd-backtick
# lines; its clean sibling 0 and 0.

[ "$DAMAGED" -eq 0 ] || {
    echo
    echo "The VERDICT is discarded. Individual findings that carry file:line and a reproduction path may"
    echo "still be verified against the repo — damage to the envelope does not refute its contents."
    exit 1
}
echo "review integrity ok — $HEADINGS findings, one verdict, no splice markers"
