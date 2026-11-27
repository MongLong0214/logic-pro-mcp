#!/bin/bash
# Run one locale campaign end to end, unattended. ONE command per locale.
#
#   Scripts/observations/locale-campaign.sh <locale> [--dry-run] [--no-push] [--navigate] [--branch NAME]
#
# It does everything `locale_campaign.py` documents -- pre-checks, the live-run lock, the language switch
# (never a click), the census with its canon confirm, the canon build, a rebind exactly when a record was
# replaced, the rule-only apply (exact canon match only; everything else a recorded HOLD), the ratchet, every
# canon-locales check, the commit and the push -- and its LAST LINE is always
#
#     RESULT: PASS|HOLD|FAIL {one line of JSON}
#
# Exit status: 0 PASS, 10 HOLD, 1 FAIL. If the engine dies without printing a RESULT line this wrapper
# prints a FAIL one, so a caller that reads only the last line is never left without an answer.
# Run it from the Aqua session that owns Logic (the tmux gate), because the census needs the
# Accessibility grant of that session. The runbook for a person (or a small model) is
# docs/locale/CAMPAIGN-RUNBOOK.md.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOCALE="${1:-}"
LOG=$(mktemp "${TMPDIR:-/tmp}/lpm-campaign.XXXXXX")
trap 'rm -f "$LOG"' EXIT
python3 "$HERE/locale_campaign.py" "$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
LAST=$(tail -n 1 "$LOG")
case "$LAST" in
  "RESULT: PASS {"*"}"|"RESULT: HOLD {"*"}"|"RESULT: FAIL {"*"}") exit "$rc" ;;
esac
printf 'RESULT: FAIL {"locale":"%s","reason":"the campaign engine ended without a RESULT line (exit %s)","result":"FAIL"}\n' "$LOCALE" "$rc"
exit 1
