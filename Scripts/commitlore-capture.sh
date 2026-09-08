#!/usr/bin/env bash
# Drive CommitLore's capture pipeline for the commit that is about to be made, and report the
# STRUCTURED outcome rather than an exit code.
#
# WHY THIS EXISTS. The practice is "record decision context the diff cannot show". Measured
# 2026-09-08 in this repository: `commitlore stale` reported ONE record in a thousand commits, while
# a single session had produced about twenty commits carrying exactly that kind of context — a
# dropped alternative, a measurement that contradicted the plan, a warning for whoever edits next.
# Permission was never the obstacle: `.commitlore-policy.json` already says
# {"mode":"auto","unattended":true}. What was missing is a TRIGGER. The installed hooks consume a
# transaction that something else must start, and nothing started one.
#
# TWO THINGS MAKE THE NAIVE VERSION OF THIS WRONG.
#
# 1. THE EXIT CODE IS NOT THE OUTCOME. `capture` reports `staged`, `empty` and `rejected`, and all
#    three exit 0. A wrapper that checks `$?` records a rejected draft as a success — the exact
#    shape of false green this repository keeps finding elsewhere. So this reads `--json` and
#    branches on `outcome`.
#
# 2. THE PROMPT IS THE WHOLE TRANSCRIPT. Measured the same day: a 67,981,436-byte session produced a
#    67,468,122-byte prompt, which no model can consume, and `capture` reports that as
#    `outcome: "empty"` with exit 0. Filed as commitlore#873. Until it is bounded upstream, this
#    slices the transcript to a tail window and SAYS SO in its output, because a caller who cannot
#    tell a slice from a session cannot judge the record that comes out of it.
#
# Usage:
#   Scripts/commitlore-capture.sh prompt [<transcript>]   write the bounded prompt to stdout
#   Scripts/commitlore-capture.sh stage <draft.json> [<transcript>]   verify + stage that draft
#   Scripts/commitlore-capture.sh outcome [<transcript>]  print just the outcome word
set -uo pipefail

WINDOW="${LPM_CAPTURE_WINDOW:-400}"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repository" >&2; exit 2; }
cd "$REPO" || exit 2

find_transcript() {
    [ -n "${1:-}" ] && { printf '%s' "$1"; return; }
    [ -n "${LPM_TRANSCRIPT:-}" ] && { printf '%s' "$LPM_TRANSCRIPT"; return; }
    local dir="$HOME/.claude/projects/$(printf '%s' "$REPO" | tr '/.' '--')"
    ls -t "$dir"/*.jsonl 2>/dev/null | head -1
}

slice_of() {
    local src="$1" out
    [ -f "$src" ] || { echo "no transcript at $src" >&2; return 2; }
    out=$(mktemp -t commitlore-slice) || return 2
    tail -n "$WINDOW" "$src" > "$out" || return 2
    printf '%s' "$out"
}

command -v commitlore >/dev/null 2>&1 || { echo "commitlore CLI not on PATH" >&2; exit 2; }

CMD="${1:?usage: $0 prompt|stage|outcome [...]}"
shift

case "$CMD" in
  prompt|outcome)
      SRC=$(find_transcript "${1:-}") || exit 2
      SLICE=$(slice_of "$SRC") || exit 2
      trap 'rm -f "$SLICE"' EXIT
      RAW=$(commitlore capture --json --unattended --transcript "$SLICE" 2>/dev/null) || true
      [ -n "$RAW" ] || { echo "capture produced no JSON" >&2; exit 2; }
      if [ "$CMD" = "outcome" ]; then
          printf '%s' "$RAW" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("outcome","<none>"))'
      else
          # The window is reported alongside the prompt so a reader knows what it is looking at.
          printf '%s' "$RAW" | WINDOW="$WINDOW" SRC="$SRC" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
print("# transcript slice: last {} lines of {}".format(os.environ["WINDOW"], os.environ["SRC"]))
print("# capture outcome without a draft: {}".format(d.get("outcome")))
print(d.get("prompt") or "")'
      fi
      ;;
  stage)
      DRAFT="${1:?usage: $0 stage <draft.json> [<transcript>]}"
      [ -f "$DRAFT" ] || { echo "no draft at $DRAFT" >&2; exit 2; }
      SRC=$(find_transcript "${2:-}") || exit 2
      SLICE=$(slice_of "$SRC") || exit 2
      trap 'rm -f "$SLICE"' EXIT
      RAW=$(commitlore capture --json --unattended --transcript "$SLICE" --draft "$DRAFT" 2>/dev/null) || true
      [ -n "$RAW" ] || { echo "capture produced no JSON" >&2; exit 2; }
      printf '%s' "$RAW" | python3 -c '
import json, sys
d = json.load(sys.stdin)
outcome = d.get("outcome")
print("outcome={} staged={} nonce={}".format(outcome, d.get("staged"), d.get("nonce")))
# staged is a success; empty is an honest "nothing to record"; rejected is a FAILURE that exits 0
# from the CLI and must not be read as either of the other two.
sys.exit({"staged": 0, "empty": 0, "rejected": 1}.get(outcome, 2))'
      ;;
  *) echo "usage: $0 prompt|stage|outcome [...]" >&2; exit 2 ;;
esac
