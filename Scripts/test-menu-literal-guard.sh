#!/bin/bash
# Self-test for ci-forbid-hardcoded-menu-bar-item.sh (#519).
#
# A guard nobody has watched fail is decoration. An adversarial review defeated the first version of that
# scanner three ways, all of them ordinary things a Swift author writes, and the scanner also printed OK
# from a directory with no Sources/ at all. This locks both halves: each evasion must be CAUGHT, the
# legitimate tree must PASS, and a tree the guard cannot examine must not be reported as clean.
#
# Run: bash Scripts/test-menu-literal-guard.sh [repo-root]
set -uo pipefail
ROOT="${1:-.}"
GUARD="$ROOT/Scripts/ci-forbid-hardcoded-menu-bar-item.sh"
[ -x "$GUARD" ] || [ -f "$GUARD" ] || { echo "FAIL: no guard at $GUARD"; exit 2; }
FAIL=0

run_fixture () { # name, expected_exit, file-content
    local name="$1" expect="$2" content="$3"
    local dir; dir=$(mktemp -d)
    mkdir -p "$dir/Sources"
    printf '%b' "$content" > "$dir/Sources/fixture.swift"
    bash "$GUARD" "$dir" >/dev/null 2>&1
    local got=$?
    rm -rf "$dir"
    if [ "$got" -eq "$expect" ]; then
        printf '  ok   %-34s exit %s\n' "$name" "$got"
    else
        printf '  FAIL %-34s exit %s, expected %s\n' "$name" "$got" "$expect"; FAIL=1
    fi
}

echo "== evasions that MUST be caught (exit 1) =="
run_fixture "plain literal"          1 'click menu bar item "File" of menu bar 1\n'
run_fixture "extra space"            1 'click menu bar item  "File" of menu bar 1\n'
run_fixture "swift escaped quotes"   1 'let s = "click menu bar item \\"File\\" of menu bar 1"\n'
run_fixture "line continuation"      1 'click menu bar item \xc2\xac\n    "File" of menu bar 1\n'

echo "== legitimate code that must NOT be flagged (exit 0) =="
run_fixture "keyword as a value"     0 'let elementKeyword: String = "menu bar item"\n'
run_fixture "resolved variable"      0 'click menu bar item barName of menu bar 1\n'

echo "== trees the guard cannot examine must not report clean =="
EMPTY=$(mktemp -d); bash "$GUARD" "$EMPTY" >/dev/null 2>&1
[ $? -eq 2 ] && echo "  ok   no Sources/                     exit 2" || { echo "  FAIL no Sources/ did not exit 2"; FAIL=1; }
rm -rf "$EMPTY"
ONLYDIR=$(mktemp -d); mkdir -p "$ONLYDIR/Sources"; bash "$GUARD" "$ONLYDIR" >/dev/null 2>&1
[ $? -eq 3 ] && echo "  ok   empty Sources/                  exit 3" || { echo "  FAIL empty Sources/ did not exit 3"; FAIL=1; }
rm -rf "$ONLYDIR"

echo
if [ "$FAIL" -eq 0 ]; then echo "OK: the menu-literal guard catches what it claims and refuses what it cannot see"; exit 0; fi
echo "FAIL: the guard's own detection regressed"; exit 1
