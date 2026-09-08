#!/usr/bin/env bash
# Prove Scripts/commitlore-capture.sh reads the OUTCOME, not the exit code.
#
# The case that carries this: `commitlore capture` reports `staged`, `empty` and `rejected` and all
# three exit 0. A wrapper that checks `$?` records a rejected draft as a success. That is the false
# green this helper exists to prevent, so it is the first thing tested — with a stub CLI, because
# provoking a real rejection needs a draft the verifier disbelieves and that is not reproducible.
set -uo pipefail
cd "$(dirname "$0")/.."
HELPER="Scripts/commitlore-capture.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

STUB=$(mktemp -d) || { echo "CANNOT-TEST(2): mktemp"; exit 2; }
trap 'rm -rf "$STUB"' EXIT
mkdir -p "$STUB/bin"
make_stub() {   # $1 = outcome word the fake CLI reports, always exiting 0
    cat > "$STUB/bin/commitlore" <<EOF
#!/bin/sh
printf '{"outcome":"%s","staged":%s,"nonce":null,"prompt":"p"}' "$1" "$( [ "$1" = staged ] && echo true || echo false )"
exit 0
EOF
    chmod +x "$STUB/bin/commitlore"
}
echo '{"draft":"x"}' > "$STUB/draft.json"
printf 'line\n' > "$STUB/t.jsonl"

for outcome in staged empty; do
    make_stub "$outcome"
    PATH="$STUB/bin:$PATH" bash "$HELPER" stage "$STUB/draft.json" "$STUB/t.jsonl" >/dev/null 2>&1
    [ $? -eq 0 ] && ok "$outcome is a pass" || no "$outcome should pass"
done

# THE ONE THAT MATTERS. The CLI exits 0; the helper must not.
make_stub rejected
PATH="$STUB/bin:$PATH" bash "$HELPER" stage "$STUB/draft.json" "$STUB/t.jsonl" >/dev/null 2>&1
[ $? -eq 1 ] && ok "rejected FAILS even though the CLI exits 0" || no "a rejected record was read as success"

# An unknown outcome is not silently a pass either: a new word from a future CLI must stop the
# caller rather than fall through whichever branch happens to be last.
make_stub something_new
PATH="$STUB/bin:$PATH" bash "$HELPER" stage "$STUB/draft.json" "$STUB/t.jsonl" >/dev/null 2>&1
[ $? -eq 2 ] && ok "an unrecognised outcome is cannot-tell, not a pass" || no "an unknown outcome did not stop the caller"

# No JSON at all is a failure, not an empty success.
cat > "$STUB/bin/commitlore" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUB/bin/commitlore"
PATH="$STUB/bin:$PATH" bash "$HELPER" stage "$STUB/draft.json" "$STUB/t.jsonl" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no JSON is refused rather than treated as empty" || no "silence was read as an outcome"

# The slice must be BOUNDED — the whole point of the wrapper (commitlore#873).
make_stub empty
seq 1 5000 > "$STUB/big.jsonl"
OUT=$(PATH="$STUB/bin:$PATH" LPM_CAPTURE_WINDOW=10 bash "$HELPER" prompt "$STUB/big.jsonl" 2>/dev/null)
printf '%s' "$OUT" | grep -q "last 10 lines" && ok "the prompt declares the window it used" \
    || no "the prompt did not say it was a slice"

echo
if [ "$FAIL" -ne 0 ]; then echo "FAIL: the capture wrapper does not do what it claims ($FAIL of $((PASS+FAIL)))"; exit 1; fi
echo "OK: $PASS case(s) — the outcome decides, never the exit code"
