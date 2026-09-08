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

# A rejection has to say WHY. The helper printed only `outcome=rejected staged=False` for a while,
# which is indistinguishable from a malformed draft, a bad transcript, or a policy refusal — the
# caller had to re-run the CLI by hand to learn that one trailer key lacked evidence.
cat > "$STUB/bin/commitlore" <<'EOF'
#!/bin/sh
printf '{"outcome":"rejected","staged":false,"nonce":null,"rejected":[{"index":0,"rule":"evidence-gap","detail":"no evidence cites Warn"}]}'
exit 0
EOF
chmod +x "$STUB/bin/commitlore"
OUT=$(PATH="$STUB/bin:$PATH" bash "$HELPER" stage "$STUB/draft.json" "$STUB/t.jsonl" 2>&1)
case "$OUT" in
    *evidence-gap*"no evidence cites Warn"*) ok "a rejection carries the rule and the detail" ;;
    *) no "a rejection said nothing about why: $OUT" ;;
esac

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

# THE WINDOW MUST BE THE ONE UPSTREAM ACTUALLY USED. commitlore#873 was fixed in v1.2.3: capture
# bounds the prompt itself and reports `transcript_window`. The wrapper stopped slicing when that
# landed — two windows would mean the reported one is not the used one — so what is tested now is
# that it REPORTS upstream's numbers rather than any of its own.
cat > "$STUB/bin/commitlore" <<'EOF'
#!/bin/sh
printf '{"outcome":"empty","staged":false,"nonce":null,"prompt":"p","transcript_window":{"first_line":91,"last_line":100,"total_lines":100,"window_bytes":123,"truncated":true}}'
exit 0
EOF
chmod +x "$STUB/bin/commitlore"
seq 1 5000 > "$STUB/big.jsonl"
OUT=$(PATH="$STUB/bin:$PATH" bash "$HELPER" prompt "$STUB/big.jsonl" 2>/dev/null)
printf '%s' "$OUT" | grep -q "lines 91-100 of 100" && ok "the prompt reports upstream's window verbatim" \
    || no "the reported window is not the one capture used"
printf '%s' "$OUT" | grep -q "truncated=True" && ok "truncation is reported, not hidden" \
    || no "a truncated window did not say so"

echo
if [ "$FAIL" -ne 0 ]; then echo "FAIL: the capture wrapper does not do what it claims ($FAIL of $((PASS+FAIL)))"; exit 1; fi
echo "OK: $PASS case(s) — the outcome decides, never the exit code"
