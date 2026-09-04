#!/bin/bash
# Run one locale campaign: switch Logic's UI language, relaunch on the DISPOSABLE fixture, prove
# the locale from the menu bar, census the navigation-free surfaces, file records + evidence, and
# print provenance proposals for a person to confirm. ADR-019 D4.
#
#   Scripts/observations/locale-campaign.sh ja-JP [--apply]
#
# It refuses unless the open document is the fixture. Authorisation to switch Logic's language is
# not authorisation to save, close or overwrite anyone's project, and the only way to restart Logic
# without a save prompt over someone's work is to never have their work open.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
LOCALE="${1:-}"; APPLY="${2:-}"
FIXTURE="$REPO/Fixtures/locale/campaign.logicx"
[ -n "$LOCALE" ] || { echo "usage: $0 <en-US|ko-KR|ja-JP> [--apply]"; exit 2; }
[ -d "$FIXTURE" ] || { echo "PRECONDITION: fixture $FIXTURE does not exist — create it (File > New, empty project, Save As there)"; exit 2; }
case "$LOCALE" in
  en-US) LANG_ID=en;; ko-KR) LANG_ID=ko;; ja-JP) LANG_ID=ja;;
  *) echo "unsupported locale $LOCALE"; exit 2;;
esac

# 1. Only the fixture may be open. A document that is not the fixture is somebody's work.
DOC=$(osascript -e 'tell application "System Events" to tell process "Logic Pro" to get value of attribute "AXDocument" of window 1' 2>/dev/null || true)
if pgrep -xq "Logic Pro"; then
  case "$DOC" in
    *campaign.logicx*) ;;
    *) echo "PRECONDITION: Logic has $DOC open, which is not the fixture. Close it yourself; this script will not."; exit 2;;
  esac
fi

# 2. Switch, relaunch on the fixture, and PROVE the locale rather than assume it.
defaults write com.apple.logic10 AppleLanguages -array "$LANG_ID"
if pgrep -xq "Logic Pro"; then
  osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1
  for _ in $(seq 1 30); do pgrep -xq "Logic Pro" || break; sleep 1; done
  pgrep -xq "Logic Pro" && { echo "Logic did not quit (a dialog?) — refusing to force it"; exit 2; }
fi
open -a "Logic Pro" "$FIXTURE"
for _ in $(seq 1 60); do
  osascript -e 'tell application "System Events" to tell process "Logic Pro" to get count of windows' 2>/dev/null | grep -qE '^[1-9]' && break
  sleep 2
done
sleep 4
BIN="${TMPDIR:-/tmp}/lpm-locale-census-$$"; CENSUS="$REPO/docs/observations/evidence/$(date +%F)-$LOCALE-navigation-free.census.json"
trap 'rm -f "$BIN"' EXIT
swiftc -O "$HERE/locale-census.swift" -o "$BIN" 2>/dev/null || { echo "cannot compile the census probe"; exit 2; }
mkdir -p "$(dirname "$CENSUS")"
"$BIN" > "$CENSUS" || { echo "census failed"; exit 2; }
GOT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['host']['locale'])" "$CENSUS")
[ "$GOT" = "$LOCALE" ] || { echo "PRECONDITION: Logic came up in $GOT, not $LOCALE — the AppleLanguages override did not take"; rm -f "$CENSUS"; exit 2; }
echo "Logic is running in $LOCALE on the fixture; census written to ${CENSUS#$REPO/}"

# 3. Records, then proposals.
python3 "$HERE/locale_campaign_records.py" "$CENSUS" "$REPO" --write
python3 "$HERE/locale-propose.py" "$CENSUS" "$REPO/docs/locale/ui-labels.json" $APPLY
