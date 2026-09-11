#!/bin/bash
# Reverify 2026-09-12-the-undo-entry-is-identified-by-its-shortcut-not-its-wording.
#
# READ-ONLY. The census opens the Edit menu, reads every entry and closes it again; nothing is
# pressed, so Logic's undo stack is not touched and the operator's project is not changed. That
# matters here more than usual: the subject IS the undo stack, and a reverify that popped it to
# look at it would be changing what it measures.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_edit_stack_menu_census.swift -o "$WORK/census" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the census did not compile"; cat "$WORK/build.err"; exit 1; }

"$WORK/census" > "$WORK/out.json" 2>&1
RC=$?
cat "$WORK/out.json"

if [ "$RC" -ne 0 ]; then
  echo "REVERIFY INCONCLUSIVE: the census could not read Logic's Edit menu (exit $RC)"
  exit 3
fi

# Exit-code-only checks were rejected: the census exits 0 whenever it READ something, which is not
# the same as the reading agreeing with the record. Each field is asserted by name.
#
# The parse lives in its own file rather than in a heredoc inside $( ). A nested heredoc passes
# `bash -n` and mangles at run time -- this script hit exactly that on its first run and reported
# it as "the Edit menu did not open", which is a false statement about Logic produced by a shell
# quoting bug.
cat > "$WORK/parse.py" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("rows_matching_cmd_z_no_modifier"),
      d.get("rows_matching_shift_cmd_z"),
      d.get("titles_containing_undo"),
      "true" if d.get("menu_opened") is True else "false")
PYEOF
read -r ZMOD0 ZMOD1 CONTAINS OPENED < <(python3 "$WORK/parse.py" "$WORK/out.json")
echo "parsed: cmdZ=$ZMOD0 shiftCmdZ=$ZMOD1 titlesWithUndo=$CONTAINS opened=$OPENED"

FAIL=0
# The finding: the SHORTCUT is unique where the wording is not.
[ "$ZMOD0" = "1" ] || { echo "REVERIFY FAIL: cmd-Z with no modifier matched $ZMOD0 rows, expected exactly 1"; FAIL=1; }
[ "$ZMOD1" = "1" ] || { echo "REVERIFY FAIL: shift-cmd-Z matched $ZMOD1 rows, expected exactly 1"; FAIL=1; }
# And the counterexample the finding rests on: matching by wording is AMBIGUOUS. A run where only
# one title carries the word would not establish the finding, so it is a failure, not a weaker pass.
[ "${CONTAINS:-0}" -ge 2 ] 2>/dev/null || { echo "REVERIFY FAIL: only ${CONTAINS:-?} title(s) carry the undo word — the ambiguity this record is about is absent, so this run cannot confirm it"; FAIL=1; }
[ "$OPENED" = "true" ] || { echo "REVERIFY FAIL: the Edit menu did not open, so the entries above are not a menu reading"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "REVERIFY PASS: the undo/redo rows are uniquely identified by their shortcut while $CONTAINS titles share the word"
exit "$FAIL"
