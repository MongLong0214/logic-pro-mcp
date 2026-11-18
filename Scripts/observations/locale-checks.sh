#!/bin/bash
# Every check the canon-locales CI job runs, in its order, as ONE command. Exit 0 only if all pass.
#
#   Scripts/observations/locale-checks.sh            run them all, print one line per check
#   Scripts/observations/locale-checks.sh --list     print the commands and run nothing
#
# test_logic_canon.py is not in the list: its AXHelp case reads an ARCHIVED Logic 12.3 source named by
# LPM_HISTORICAL_LOGIC_APP and fails by design without one, which no unattended run can supply.
#
# This is the list a locale campaign must leave green BEFORE it commits. It lives here, once, and the
# campaign script and the drift agent call it; .github/workflows/ci.yml carries the same list for CI
# and Scripts/test_locale_campaign_script.py fails if the two ever differ.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO" || exit 2
CHECKS=(
  "python3 Scripts/logic_canon.py status"
  "python3 Scripts/check-canon-drift.py"
  "python3 Scripts/check-canon-citations.py"
  "python3 Scripts/check-canon-prose-numbers.py"
  "python3 Scripts/check-policy-literals-against-canon.py"
  "python3 Scripts/check-labelsets-are-derived.py"
  "python3 Scripts/check-new-labelsets-name-a-row.py"
  "python3 Scripts/check-labelset-census-only-shrinks.py"
  "python3 Scripts/check-locale-detection-is-derived.py"
  "python3 Scripts/check-locale-policy-coverage.py"
  "python3 Scripts/locale_labels.py --check"
  "python3 Scripts/check-locale-labels-json.py"
  "python3 Scripts/check-observation-records.py"
  "python3 Scripts/check-observation-ratchets.py"
  "python3 Scripts/test_canon_citation_diagnostics.py"
  "python3 Scripts/test_canon_citations_guard.py"
  "python3 Scripts/test_canon_corrections.py"
  "python3 Scripts/test_canon_drift.py"
  "python3 Scripts/test_canon_presence.py"
  "python3 Scripts/test_canon_prose_numbers.py"
  "python3 Scripts/test_labelsets_are_derived.py"
  "python3 Scripts/test_new_labelsets_name_a_row.py"
  "python3 Scripts/test_locale_detection_is_derived.py"
  "python3 Scripts/test_locale_campaign.py"
  "python3 Scripts/test_locale_census.py"
  "python3 Scripts/test_locale_rules.py"
  "python3 Scripts/test_locale_campaign_script.py"
  "python3 Scripts/test_locale_labels_json.py"
  "python3 Scripts/test_locale_version_axis.py"
  "python3 Scripts/test_policy_literals_against_canon.py"
  "python3 Scripts/test_observation_records.py"
  "python3 Scripts/test_observation_ratchets.py"
)
if [ "${1:-}" = "--list" ]; then printf '%s\n' "${CHECKS[@]}"; exit 0; fi
failed=0
for c in "${CHECKS[@]}"; do
  start=$SECONDS
  if out=$($c 2>&1); then echo "PASS  $c  ($((SECONDS-start))s)"; else echo "FAIL  $c  ($((SECONDS-start))s)"; printf '%s\n' "$out" | tail -15 | sed 's/^/        /'; failed=$((failed+1)); fi
done
echo "CHECKS failed=$failed total=${#CHECKS[@]}"
[ "$failed" -eq 0 ]
