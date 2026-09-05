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
# Outside the repository on purpose. Fixtures/ holds small JSON (44K in total) and .gitignore
# already keeps `.logicx` bundles out of the tree; a 900K binary directory does not belong beside
# them. The operator supplies a DISPOSABLE project — the script relaunches Logic, and the only way
# to do that without a save prompt over somebody's work is to never have their work open.
FIXTURE="${LPM_LOCALE_FIXTURE:-$HOME/Music/Logic/lpm-locale-campaign.logicx}"
[ -n "$LOCALE" ] || { echo "usage: $0 <en-US|ko-KR|ja-JP> [--apply]"; exit 2; }
[ -d "$FIXTURE" ] || { echo "PRECONDITION: fixture $FIXTURE does not exist. Create a throwaway project there (File > New, empty, Save As), or point LPM_LOCALE_FIXTURE at one. It gets relaunched repeatedly and must be nobody's work."; exit 2; }
case "$LOCALE" in
  en-US) LANG_ID=en;; ko-KR) LANG_ID=ko;; ja-JP) LANG_ID=ja;;
  *) echo "unsupported locale $LOCALE"; exit 2;;
esac

# 1. Only the fixture may be open. A document that is not the fixture is somebody's work.
# Every window's document, not window 1's. Window 1 is whatever is frontmost, and after a failed
# run that is a leftover modal with no document behind it — which read as "some other project is
# open" and blocked the next run for the opposite of the real reason.
if pgrep -xq "Logic Pro"; then
  DOCS=$(osascript <<'AS' 2>/dev/null || true
tell application "System Events" to tell process "Logic Pro"
  set out to ""
  repeat with w in windows
    try
      set out to out & (value of attribute "AXDocument" of w as string) & linefeed
    end try
  end repeat
  set dlg to (count of (windows whose subrole is "AXDialog"))
  return out & "DIALOGS=" & dlg
end tell
AS
)
  FIXTURE_NAME=$(basename "$FIXTURE")
  # `missing value` is what AXDocument yields for a window that has none — a palette, an inspector,
  # a modal. AppleScript stringifies it rather than erroring, so it arrives looking like a path and
  # was counted as somebody else's project.
  OTHERS=$(printf '%s' "$DOCS" | grep -v '^DIALOGS=' | grep -v "$FIXTURE_NAME" \
           | grep -v '^missing value$' | grep -v '^$' || true)
  if [ -n "$OTHERS" ]; then
    echo "PRECONDITION: Logic has $(printf '%s' "$OTHERS" | head -1) open, which is not $FIXTURE_NAME. Close it yourself; this script will not."
    exit 2
  fi
  # No other document. Either the fixture is up, or nothing is — and a modal with nothing behind it
  # is a leftover from a previous run, which the quit step below discards. There is no work to lose
  # in either case, which is the only thing this check exists to protect.
fi

# 2. Switch, relaunch on the fixture, and PROVE the locale rather than assume it.
defaults write com.apple.logic10 AppleLanguages -array "$LANG_ID"
if pgrep -xq "Logic Pro"; then
  osascript -e 'tell application "Logic Pro" to quit' >/dev/null 2>&1
  for _ in $(seq 1 30); do pgrep -xq "Logic Pro" || break; sleep 1; done

  # Quitting with the fixture open raises "save the changes to <fixture>?", and this script quits
  # every run, so it appears on the second campaign and every one after. The fixture is disposable
  # by contract — that is the whole reason this refuses to run against anything else — so the
  # answer is always don't save.
  #
  # Chosen STRUCTURALLY, not by label: the sheet offers Save / Don't Save / Cancel, and the one
  # that is neither the default button nor the cancel button is the discard. Matching a localised
  # word here would be a locale tool with a locale bug, and this runs in three languages by design.
  if pgrep -xq "Logic Pro"; then
    DISCARD=$(osascript <<'AS' 2>/dev/null || true
tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  set skip to {}
  try
    set end of skip to name of (value of attribute "AXDefaultButton" of d) as string
  end try
  try
    set end of skip to name of (value of attribute "AXCancelButton" of d) as string
  end try
  if (count of skip) is not 2 then return ""
  repeat with b in (every button of d)
    set n to name of b as string
    if n is not in skip then
      click b
      return n
    end if
  end repeat
  return ""
end tell
AS
)
    [ -n "$DISCARD" ] && echo "discarded the fixture's unsaved changes by pressing “${DISCARD}”"
    for _ in $(seq 1 30); do pgrep -xq "Logic Pro" || break; sleep 1; done
  fi
  pgrep -xq "Logic Pro" && { echo "Logic did not quit (a dialog?) — refusing to force it"; exit 2; }
fi
open -a "Logic Pro" "$FIXTURE"
for _ in $(seq 1 60); do
  osascript -e 'tell application "System Events" to tell process "Logic Pro" to get count of windows' 2>/dev/null | grep -qE '^[1-9]' && break
  sleep 2
done
sleep 4

# Logic offers the AUTOSAVED version when a project was open at the last quit, and this script
# quits Logic every run — so the prompt appears on the second campaign and every one after it.
# Left standing it is a modal with no document behind it: the census reads an empty application and
# the run fails for a reason that has nothing to do with the locale.
#
# EITHER version is fine, which is what makes this safe to automate: the census reads the
# application's chrome — menu bar, window controls — not the document's content, and both versions
# are the same disposable fixture. So the sheet is dismissed with its DEFAULT button rather than by
# matching a localised label, and the label that was pressed is read back and printed.
#
# An earlier cut tried to identify the manual-save button as "the one whose name the message does
# not contain". In Japanese the message says 自動保存されたバージョン and the buttons are
# 自動保存バージョン and 保存 — so the substring test marks 保存 as contained and picks the autosave,
# the exact opposite. Matching localised prose to localised labels is how a locale tool acquires a
# locale bug.
AUTOSAVE_PICK=$(osascript <<'AS' 2>/dev/null || true
tell application "System Events" to tell process "Logic Pro"
  if (count of (windows whose subrole is "AXDialog")) is 0 then return ""
  set d to first window whose subrole is "AXDialog"
  try
    set b to value of attribute "AXDefaultButton" of d
    set n to name of b as string
    click b
    return n
  end try
  return ""
end tell
AS
)
[ -n "$AUTOSAVE_PICK" ] && { echo "dismissed the autosave-recovery sheet by pressing its default button “${AUTOSAVE_PICK}”"; sleep 5; }
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
