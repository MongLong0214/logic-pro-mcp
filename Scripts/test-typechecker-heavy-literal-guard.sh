#!/usr/bin/env bash
# Fixture self-test for check-typechecker-heavy-literals.py (#749).
#
# The guard must refuse a single dangerous value, while allowing ordinary dictionary literals
# whose unrelated values each contain only one concatenation. Fixtures make both outcomes real:
# a test that only scans this clean tree cannot prove the guard can fail.
#
# Run: bash Scripts/test-typechecker-heavy-literal-guard.sh [repo-root]
set -uo pipefail

ROOT="${1:-.}"
GUARD="$ROOT/Scripts/check-typechecker-heavy-literals.py"
[ -f "$GUARD" ] || { echo "FAIL: no guard at $GUARD"; exit 2; }

FAIL=0

run_fixture () { # name, expected_exit, Swift source
    local name="$1" expect="$2" content="$3"
    local dir got
    dir=$(mktemp -d)
    mkdir -p "$dir/Sources"
    printf '%b' "$content" > "$dir/Sources/fixture.swift"
    python3 "$GUARD" "$dir" >/dev/null 2>&1
    got=$?
    rm -rf "$dir"
    if [ "$got" -eq "$expect" ]; then
        printf '  ok   %-38s exit %s\n' "$name" "$got"
    else
        printf '  FAIL %-38s exit %s, expected %s\n' "$name" "$got" "$expect"
        FAIL=1
    fi
}

echo "== dangerous values that MUST be refused (exit 1) =="
run_fixture "flat merging value with three chains" 1 '\
extras.merging(["hint": "https://example.test" + "/one" + "/two" + "/three"]) { _, new in new }\n'

echo "== ordinary literals that must be accepted (exit 0) =="
run_fixture "three unrelated one-chain values" 0 '\
report(["a": "one" + "!", "b": "two" + "!", "c": "three" + "!"])\n'
run_fixture "commented-out example" 0 '\
// Example only, not compiled:\n\
//   report(["hint": "a" + "b" + "c" + "d"])\n\
report(["hint": staticHint])\n'
run_fixture "block-commented example" 0 '\
/* report(["hint": "a" + "b" + "c" + "d"]) */\n\
report(["hint": staticHint])\n'
run_fixture "plain literal" 0 'report(["hint": staticHint])\n'

echo
if [ "$FAIL" -eq 0 ]; then
    echo "OK: the typechecker-heavy-literal guard catches its fixture and accepts ordinary literals"
    exit 0
fi
echo "FAIL: the typechecker-heavy-literal guard's fixture behavior regressed"
exit 1
