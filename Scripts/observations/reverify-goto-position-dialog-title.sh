#!/bin/bash
# What the Go To Position dialog is CALLED on the Logic that is running, in whatever language it is
# in. `AXLocalePolicy.goToPositionDialogTitle` matches that title with `.exactStrict`, so a spelling
# it does not carry makes the product report `dialog_unidentified_new_window` — the menu leaf fires,
# the window opens, and nothing can name it. That is exactly how the German gap was found.
#
# It opens the dialog and closes it again with Escape. Nothing is submitted, so the playhead does
# not move. The menu path is walked by trying each measured spelling in turn rather than by
# translating one — a locale probe that hard-codes a language has the bug it is looking for.
#
#   Scripts/observations/reverify-goto-position-dialog-title.sh
#   -> e.g.  Zu Position|AXFloatingWindow;
#
# Expected on de-DE Logic Pro 12.3 (6674): `Zu Position`. A different string means the label set
# wants re-reading, not that the probe failed.
osascript <<'AS'
tell application "Logic Pro" to activate
delay 1
tell application "System Events" to tell process "Logic Pro"
  set barNames to {"Navigate", "탐색", "移動", "Navigieren"}
  set goNames to {"Go To", "이동", "移動", "Gehe zu"}
  set posNames to {"Position…", "위치…", "位置…", "Position …"}
  set bar to missing value
  repeat with n in barNames
    try
      set bar to menu bar item (n as string) of menu bar 1
      exit repeat
    end try
  end repeat
  click bar
  delay 0.6
  set g to missing value
  repeat with n in goNames
    try
      set g to menu item (n as string) of menu 1 of bar
      exit repeat
    end try
  end repeat
  click g
  delay 0.6
  repeat with n in posNames
    try
      click menu item (n as string) of menu 1 of g
      exit repeat
    end try
  end repeat
  delay 1.5
  set out to ""
  repeat with w in windows
    if (value of attribute "AXSubrole" of w) is not "AXStandardWindow" then
      set out to out & (name of w) & "|" & (value of attribute "AXSubrole" of w) & ";"
    end if
  end repeat
  key code 53
  delay 0.5
  return out
end tell
AS
