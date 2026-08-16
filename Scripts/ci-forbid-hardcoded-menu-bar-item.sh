#!/bin/bash
# CI lint (#519): forbid a hard-coded literal name right after `menu bar item` in the
# AppleScript this repo generates.
#
# Why this guard exists: AXLocalePolicy already recorded every locale variant Logic's
# top-level menu titles are known to use — e.g. `fileMenuBar` lists "File", "파일", AND
# "ファイル" — but the AppleScript-generating call sites hard-coded only one or two of those
# names inline (`menu bar item "File" of menu bar 1`, `menu bar item "파일" of menu bar 1`, ...).
# The Japanese variant was already IN the table and UNREACHABLE from any call site: the data
# claimed support the code could not deliver, and the failure was silent (the operation just
# refused on a non-EN/KO Logic; nothing else signalled that the two were out of sync). That is
# the property this scanner enforces — not merely "these ten sites", but "a literal menu-bar
# name can no longer be written at all", so the same silent gap cannot reopen at an eleventh
# site next week.
#
# The fix is `AppleScriptMenuResolution` (Sources/LogicProMCP/Utilities/AppleScriptMenuResolution.swift):
# every menu-drive site resolves its bar name from an `AXLocalePolicy.LabelSet` at AppleScript-
# generation time (trying canonical, then each variant, and using whichever `exists`) and
# interpolates the RESOLVED VARIABLE into the specifier — `menu bar item barName of menu bar 1` —
# never a literal string. Do that instead of writing a literal here:
#
#   let barResolution = AppleScriptMenuResolution.menuBarItem(
#       AXLocalePolicy.someMenuBar, variableName: "barName", notFoundError: "SOME_MENU_BAR_NOT_FOUND"
#   )
#   // ... interpolate `\(barResolution)`, then use `menu bar item barName of menu bar 1`.
#
# If the menu bar you need has no LabelSet yet, add one to AXLocalePolicy (measured labels only —
# do not invent a translation) and resolve through it the same way.
#
# Scope: Sources/ only. Test fixtures (e.g. FakeAXRuntimeBuilder menu titles, or a hand-built
# JSON/AppleScript-result string a test feeds back into a channel) are not generated AppleScript
# and legitimately contain literal menu names, so Tests/ is not scanned and would produce false
# positives if it were.
#
# Deliberately narrow: this only catches the top-level `menu bar item "literal"` shape (the
# defect #519 fixed). It does not catch a hard-coded `menu item "literal"` (a submenu leaf) sitting
# under an already-resolved bar variable — that is a real gap, not an oversight; broadening the
# pattern to bare `menu item "` produced false positives against other legitimate one-off literal
# AppleScript (e.g. dialog button titles) outside this issue's scope. Revisit if #519-style bugs
# start appearing one level deeper.
#
# Exit 1 (fail CI) on any hard-coded `menu bar item "literal"` found under Sources/.
set -uo pipefail
ROOT="${1:-.}"
cd "$ROOT" || { echo "FATAL: bad root $ROOT"; exit 2; }

hits=()
while IFS= read -r line; do
    [ -n "$line" ] && hits+=("$line")
done < <(grep -rn 'menu bar item "' Sources 2>/dev/null || true)

if [ "${#hits[@]}" -gt 0 ]; then
    echo "::error::Hard-coded literal menu-bar item name(s) found under Sources/ (#519)."
    echo "A literal cannot reach locale variants AXLocalePolicy already records for that menu"
    echo "(e.g. fileMenuBar's Japanese \"ファイル\") the way a resolved LabelSet does."
    echo "Resolve the name instead: AppleScriptMenuResolution.menuBarItem(AXLocalePolicy.<set>, ...)"
    echo "and interpolate the resolved variable (menu bar item barName of menu bar 1), not a literal."
    for h in "${hits[@]}"; do
        echo "$h"
    done
    echo "COUNT: ${#hits[@]}"
    exit 1
fi
echo "OK: no hard-coded literal menu-bar item names in Sources/ (#519 locale-routing guard)"
