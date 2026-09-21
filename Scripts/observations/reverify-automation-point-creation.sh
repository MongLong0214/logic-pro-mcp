#!/bin/bash
# Re-run the measurement behind
# docs/observations/2026-09-21-the-parameter-popup-help-reports-automation-data.json.
#
# The script tests the Edit-menu label that Logic registers after it drives the submenu leaf. That
# label identifies an operation by its shipped name; it does not read automation data or prove a
# count, position, or value.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)


# The UI STRINGS are resolved from Logic's own shipped data rather than typed here -- a typed one
# is a guess, and a guess that is one character off makes an element unfindable while the ledger
# reads it as coverage. The REFERENCES that name them are literal, for the reason below.
resolve() {
  python3 "$REPO/Scripts/logic_canon.py" resolve "$1" 2>/dev/null | head -1
}
# The references below are LITERAL and Korean, because the record behind this script is Korean
# and says so in its limits. They were written out rather than assembled from a locale variable so
# that `check-canon-citations.py` can resolve each one: a reference built by string interpolation
# is not checkable, and a script that hides its references from the checker by splitting the
# scheme is worse than one that has none. Extending this to another locale means adding that
# locale's five references here, where they will be checked too.
#
# `Mix%23mti` -- the key is literally `Mix#mti`, and the inner `#` is encoded because an
# unencoded one would be read as the start of the field selector and resolve nothing.
#
# resolves to: 트랙 오토메이션 생성
PARENT=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Create%20Track%20Automation#value")
# resolves to: 리전 경계에 2개의 오토메이션 포인트 생성
LEAF=$(resolve "logic-canon://quickhelp/QuickHelp/ko/GMM_007_2AutoPointRegionBorders#Title")
# resolves to: MIDI 리전. MIDI 노트 및 컨트롤러 이벤트를 포함합니다. 가운데를 드래그하여 이동하고, 하단 가장자리를 드래그하여 크기를 조정하며, 상단 오른쪽 모서리를 드래그하여 루핑합니다. 도구를 사용하여 그 외의 편집을 수행합니다.
MIDI_REGION_HELP=$(resolve "logic-canon://quickhelp/QuickHelp/ko/ARR_021_MidiRegion#composed")
# resolves to: Mix
MIX=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Mix%23mti#value")
# resolves to: 편집
EDIT=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Edit#value")
# resolves to: 리전 경계에 2개의 트랙 오토메이션 포인트 생성
UNDO_NAME=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Create%202%20Track%20Automation%20Points%20at%20Region%20Borders%23und#value")
for pair in "PARENT:$PARENT" "LEAF:$LEAF" "MIDI_REGION_HELP:$MIDI_REGION_HELP" "MIX:$MIX" "EDIT:$EDIT" "UNDO_NAME:$UNDO_NAME"; do
  if [ -z "${pair#*:}" ]; then
    echo "cannot resolve ${pair%%:*} from the pinned canon"; exit 2
  fi
done
# This reads the user's AppleLanguages preference. It does not read the running Logic process, so
# it is only a guard against a known preference mismatch; the resolved menu reads remain the test.
PREFERRED_LOCALE=$(python3 - "$REPO" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "Scripts"))
from observation_host import measured_locale
print(measured_locale())
PY
)
if [ "$PREFERRED_LOCALE" != "ko-KR" ]; then
  echo "AppleLanguages reports $PREFERRED_LOCALE; this script carries ko-KR references only."
  echo "Add that locale's references beside the Korean ones and run it again."
  exit 2
fi

undo_label() {
  osascript - "$EDIT" <<'AS' 2>/dev/null
on run argv
  set editName to item 1 of argv
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.logic10")
      try
        click menu bar item editName of menu bar 1
      end try
      delay 0.35
      set lbl to name of menu item 1 of menu 1 of menu bar item editName of menu bar 1
      key code 53
      delay 0.2
      return lbl
    end tell
  end tell
end run
AS
}

drive_leaf() {
  osascript - "$MIX" "$PARENT" "$LEAF" <<'AS' 2>/dev/null
on run argv
  set mixName to item 1 of argv
  set parentName to item 2 of argv
  set leafName to item 3 of argv
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.logic10")
      try
        click menu bar item mixName of menu bar 1
      end try
      delay 0.35
      set parentItem to menu item parentName of menu 1 of menu bar item mixName of menu bar 1
      try
        click parentItem
      end try
      delay 0.35
      click menu item leafName of menu 1 of parentItem
      delay 0.5
      return (count of (every menu bar item of menu bar 1 whose selected is true))
    end tell
  end tell
end run
AS
}

# This is a read-only AX precondition check. It counts selected AXLayoutItems whose AXHelp contains
# the composed QuickHelp text for a MIDI region, rather than treating a region elsewhere in the
# project as sufficient. This recognises MIDI regions only: an audio region is reported absent and
# exits 2, a conservative refusal until an audio-region help key is measured.
selected_region_count() {
  osascript - "$MIDI_REGION_HELP" <<'AS' 2>/dev/null
on selectedRegionCount(containerElement, midiRegionHelp, depth)
  using terms from application "System Events"
    if depth > 24 then return -1
    try
      set childElements to UI elements of containerElement
    on error
      return -1
    end try
    set resultCount to 0
    repeat with childReference in childElements
      set childElement to contents of childReference
      try
        if role of childElement is "AXLayoutItem" then
          set childHelp to help of childElement
          if childHelp contains midiRegionHelp then
            if selected of childElement then set resultCount to resultCount + 1
          end if
        end if
        set descendantCount to selectedRegionCount(childElement, midiRegionHelp, depth + 1)
        if descendantCount is -1 then return -1
        set resultCount to resultCount + descendantCount
      on error
        return -1
      end try
    end repeat
    return resultCount
  end using terms from
end selectedRegionCount

on run argv
  set midiRegionHelp to item 1 of argv
  tell application "System Events"
    try
      set logicProcess to first process whose bundle identifier is "com.apple.logic10"
      set resultCount to 0
      repeat with windowReference in every window of logicProcess
        set windowCount to my selectedRegionCount(contents of windowReference, midiRegionHelp, 0)
        if windowCount is -1 then return -1
        set resultCount to resultCount + windowCount
      end repeat
      return resultCount
    on error
      return -1
    end try
  end tell
end run
AS
}

pgrep -x "Logic Pro" >/dev/null || { echo "Logic Pro is not running"; exit 2; }

undo_once() {
  osascript - "$EDIT" <<'AS' 2>/dev/null
on run argv
  set editName to item 1 of argv
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.logic10")
      click menu bar item editName of menu bar 1
      delay 0.35
      set undoItem to menu item 1 of menu 1 of menu bar item editName of menu bar 1
      if enabled of undoItem then
        click undoItem
        delay 0.4
        return "clicked"
      end if
      key code 53
      delay 0.2
      return "disabled"
    end tell
  end tell
end run
AS
}

BEFORE=$(undo_label)
[ -n "$BEFORE" ] || { echo "INSTRUMENT FAILURE: cannot read the undo label; is Logic frontmost and unblocked?"; exit 3; }
CLEARED=$BEFORE
# The menu entry is COMPOSED, and Logic ships the composition itself as a format string, so the
# wrapper is resolved rather than typed. Typing `실행 취소` here would have hard-coded one
# language's word order into a test whose whole subject is a localized label; the template puts
# `%@` where the operation name goes, which is a suffix in Korean and a prefix in English.
# Equality against the composed label rejects a different command that merely contains the name.
# The key is literally `Undo %@`; the space and the `%` are percent-encoded so the reference
# parses, and the resolved value keeps the placeholder.
# resolves to: %@ 실행 취소
UNDO_TEMPLATE=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Undo%20%25%40#value")
[ -n "$UNDO_TEMPLATE" ] || { echo "cannot resolve UNDO_TEMPLATE from the pinned canon"; exit 2; }
case "$UNDO_TEMPLATE" in
  *"%@"*) ;;
  *) echo "the shipped undo template carries no %@ placeholder: $UNDO_TEMPLATE"; exit 2 ;;
esac
UNDO_LABEL=${UNDO_TEMPLATE/"%@"/"$UNDO_NAME"}
names_the_op() { [ "$1" = "$UNDO_LABEL" ]; }
if names_the_op "$BEFORE"; then
  UNDO_RESULT=$(undo_once)
  case "$UNDO_RESULT" in
    clicked) ;;
    disabled)
      echo "PRECONDITION: the undo menu item is disabled; cannot get a clean start."
      exit 2
      ;;
    *)
      echo "INSTRUMENT FAILURE: cannot click Logic's undo menu item."
      exit 3
      ;;
  esac
  CLEARED=$(undo_label)
  [ -n "$CLEARED" ] || { echo "INSTRUMENT FAILURE: cannot read the undo label after clicking Undo."; exit 3; }
  if names_the_op "$CLEARED"; then
    echo "undo_before:   $BEFORE"
    echo "PRECONDITION: the stack still names this operation after one undo; cannot get a clean start."
    exit 2
  fi
fi
REGION_COUNT=$(selected_region_count)
case "$REGION_COUNT" in
  ''|*[!0-9]*)
    echo "INSTRUMENT FAILURE: cannot read selected AX regions."
    exit 3
    ;;
esac
if [ "$REGION_COUNT" -eq 0 ]; then
  echo "PRECONDITION: no selected region was found. Select a region on the selected track and run again."
  exit 2
fi
OPEN=$(drive_leaf)
AFTER=$(undo_label)

[ -n "$OPEN" ] || { echo "INSTRUMENT FAILURE: cannot read whether a menu remained open."; exit 3; }
[ -n "$AFTER" ] || { echo "INSTRUMENT FAILURE: cannot read the undo label after driving the leaf."; exit 3; }

echo "leaf:          $LEAF"
echo "undo_name:     $UNDO_NAME"
echo "undo_at_start: $BEFORE"
echo "undo_cleared:  $CLEARED"
echo "undo_after:    $AFTER"
echo "menus_open:    ${OPEN:-unread}"

if [ "${OPEN:-1}" != "0" ]; then
  echo; echo "PRECONDITION: a menu was left open; the run did not reach a clean state."
  exit 2
fi
if [ "$AFTER" = "$CLEARED" ]; then
  echo
  echo "DISAGREES with the record: the precondition was present, but the undo label did not move."
  exit 1
fi
if ! names_the_op "$AFTER"; then
  echo
  echo "DISAGREES with the record: the stack moved, but to '$AFTER' rather than to the name Logic"
  echo "ships for this operation. Something other than this leaf ran, or the undo string changed."
  exit 1
fi
echo
echo "AGREES with the record: this run registered the shipped undo operation name after driving the leaf."
echo "This does not establish an automation-data count, position, or value."
