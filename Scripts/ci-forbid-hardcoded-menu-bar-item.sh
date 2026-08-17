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
# the property this scanner aims at: not merely "these ten sites", but making a literal menu-bar name
# hard to reintroduce, so the same silent gap does not reopen at an eleventh site next week.
#
# It is a text scanner, not a parser, and the difference matters — an adversarial review defeated the
# first version three ways: an extra space after the keyword, a line continuation between keyword and
# literal, and (worst) a Swift SINGLE-LINE string, where the inner quotes are escaped so the bytes read
# `menu bar item \"File\"` and a fixed-string grep never matches. The pattern below covers all three.
# It still cannot see a name built by concatenation or held in a variable. Treat it as a tripwire that
# catches the shapes people actually write, not as a proof that none exists.
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

# Positive control. Without this the script prints OK from any directory that has no Sources/ — grep
# fails, the error is swallowed, zero hits look like a clean tree. "Clean" and "never looked" have to be
# distinguishable, which is the whole discipline this guard exists to serve.
# Exit codes are deliberately DISTINCT for the two ways this can fail to scan. If both returned the same
# code, a future CI rule that tolerates one ("this repo has no Sources, skip") would silently tolerate the
# other ("Sources vanished, something is broken") — and the second is exactly the state this guard exists
# to never pass over.
#   2 = misinvoked: no Sources/ at this root
#   3 = unexpected: Sources/ exists but nothing readable in it
if [ ! -d Sources ]; then
    echo "CANNOT-SCAN(2): no Sources/ under $ROOT — refusing to report a clean result for a tree this did not scan"
    exit 2
fi
SCANNED=$(grep -rlE '' Sources 2>/dev/null | wc -l | tr -d ' ')
if [ "${SCANNED:-0}" -eq 0 ]; then
    echo "CANNOT-SCAN(3): Sources/ under $ROOT exists but contains no readable files — nothing was scanned"
    exit 3
fi

hits=()
while IFS= read -r line; do
    [ -n "$line" ] && hits+=("$line")
# -E: `menu bar item` then optional whitespace/line-continuation, then either a bare `"` or an escaped
# `\"` (Swift single-line string). Also matches across a `¬` continuation by allowing it before the quote.
# Two patterns, because one cannot cover both shapes:
#   A  the keyword, at least one separator, then a bare or backslash-escaped quote. The separator is
#      REQUIRED so `elementKeyword: "menu bar item"` — the generator naming the keyword itself — is not
#      a hit; there the quote closes the string with no space before it.
#   B  a line ending in the keyword with an AppleScript continuation, where the literal sits on the next
#      line and a line-oriented scanner cannot see it. Flag the continuation itself.
done < <( { grep -rnE 'menu bar item[[:space:]]+(¬[[:space:]]*)?\\?"' Sources 2>/dev/null;
            grep -rnE 'menu bar item[[:space:]]*¬[[:space:]]*$' Sources 2>/dev/null; } | sort -u || true)

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
echo "OK: no hard-coded literal menu-bar item names in $SCANNED scanned file(s) under Sources/ (#519)"
