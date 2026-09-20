#!/bin/bash
# Re-run the measurement behind
# docs/observations/2026-09-21-two-automation-points-are-created-by-a-submenu-leaf.json.
#
# The recorded finding is that `Mix > Create Track Automation` is a submenu PARENT and its LEAF
# creates automation points, which the earlier reading missed by actuating the parent. So this
# drives the leaf and asks Logic's own undo stack what it thinks it did -- a return code from a
# menu click says nothing, and the previous record was written from one.
#
# The bracket is the point of the script, not a decoration. Logic's undo stack is walked OFF this
# operation first and that is checked, so a run cannot pass on a label an EARLIER run wrote. A
# bare before/after comparison cannot make that distinction, and the first version of this script
# failed exactly that way -- it read a working leaf as dead because the label was already there.
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
# The UNDO name has its OWN key (`...%23und`) and is NOT the menu leaf's title: the leaf says
# `오토메이션 포인트`, the undo entry says `트랙 오토메이션 포인트`. Deriving one from the other
# would have been a guess, and it would have read as a failure.
# resolves to: 트랙 오토메이션 생성
PARENT=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Create%20Track%20Automation#value")
# resolves to: 리전 경계에 2개의 오토메이션 포인트 생성
LEAF=$(resolve "logic-canon://quickhelp/QuickHelp/ko/GMM_007_2AutoPointRegionBorders#Title")
# resolves to: Mix
MIX=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Mix%23mti#value")
# resolves to: 편집
EDIT=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Edit#value")
# resolves to: 리전 경계에 2개의 트랙 오토메이션 포인트 생성
UNDO_NAME=$(resolve "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/ko/Create%202%20Track%20Automation%20Points%20at%20Region%20Borders%23und#value")
for pair in "PARENT:$PARENT" "LEAF:$LEAF" "MIX:$MIX" "EDIT:$EDIT" "UNDO_NAME:$UNDO_NAME"; do
  if [ -z "${pair#*:}" ]; then
    echo "cannot resolve ${pair%%:*} from the pinned canon"; exit 2
  fi
done
# The interface Logic is actually in. A Korean reference resolving says nothing about the Logic on
# screen, so a run against another language stops here instead of hunting for menus by the wrong
# name and reporting the miss as a finding.
RUNNING_LOCALE=$(python3 - "$REPO" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "Scripts"))
from observation_host import measured_locale
print(measured_locale())
PY
)
if [ "$RUNNING_LOCALE" != "ko-KR" ]; then
  echo "Logic's interface is $RUNNING_LOCALE; this script carries ko-KR references only."
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

pgrep -x "Logic Pro" >/dev/null || { echo "Logic Pro is not running"; exit 2; }

undo_once() {
  osascript - "$EDIT" <<'AS' 2>/dev/null
on run argv
  tell application "System Events"
    tell (first process whose bundle identifier is "com.apple.logic10")
      keystroke "z" using command down
      delay 0.4
    end tell
  end tell
end run
AS
}

# Comparing the undo label's TEXT cannot tell "nothing happened" from "the same operation happened
# again": a second run of this leaf writes the identical label, so a bare before/after comparison
# reads a working leaf as a dead one. That false negative was produced by the first version of this
# script. So the run is bracketed by Logic's own undo instead -- the stack is walked OFF this
# operation first, which is checked, and only then is the leaf driven.
BEFORE=$(undo_label)
[ -n "$BEFORE" ] || { echo "cannot read the undo label; is Logic frontmost and unblocked?"; exit 2; }
CLEARED=$BEFORE
# The menu entry is COMPOSED -- the operation name inside a wrapper whose word order differs by
# locale (`Undo <op>` in English, `<op> 실행 취소` in Korean). So the test is containment of the
# shipped operation name, never equality with the whole label.
names_the_op() { case "$1" in *"$UNDO_NAME"*) return 0 ;; *) return 1 ;; esac; }
if names_the_op "$BEFORE"; then
  undo_once
  CLEARED=$(undo_label)
  if names_the_op "$CLEARED"; then
    echo "undo_before:   $BEFORE"
    echo "PRECONDITION: the stack still names this operation after one undo; cannot get a clean start."
    exit 2
  fi
fi
OPEN=$(drive_leaf)
AFTER=$(undo_label)

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
  echo "The undo stack did not move. Either the leaf did nothing, or its precondition is missing:"
  echo "the region-borders leaves need a region on the selected track. Record one with"
  echo "  logic_tracks record_sequence {notes: '60,0,1000,90'}"
  echo "and run this again. A run with no region is the state this record's OWN control used, and"
  echo "it is not evidence against the leaf."
  exit 2
fi
if ! names_the_op "$AFTER"; then
  echo
  echo "DISAGREES with the record: the stack moved, but to '$AFTER' rather than to the name Logic"
  echo "ships for this operation. Something other than this leaf ran, or the undo string changed."
  exit 1
fi
echo
echo "AGREES with the record: the stack was walked off this operation and the leaf put it back,"
echo "so Logic performed the operation it names during THIS run."
echo "The record does NOT claim more than this -- no position or value of either point was read,"
echo "because no surface measured there vends one."
