#!/bin/bash
# Reverify 2026-09-11-axpress-actuates-only-a-focused-element.
#
# The claim has two halves and BOTH must hold for the record to stand: an unfocused press does
# nothing, and the same element actuates once AXFocused is set. The second half is the positive
# control -- without it, "the unfocused press did nothing" is also satisfied by an instrument that
# could not press anything at all, which is how this repository previously recorded a working
# toggle as inert.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

swiftc -O Scripts/livekit/ax_press_focus_probe.swift -o "$WORK/probe" 2>"$WORK/build.err" || {
  echo "REVERIFY FAIL: the probe did not compile"; cat "$WORK/build.err"; exit 1; }
# The Mute spelling comes from AXLocalePolicy, parsed the way the live harnesses parse it, so this
# probe is not blind on a Logic that is not in English.
LABELS=$(python3 -c "
import sys; sys.path.insert(0, 'Scripts/livekit')
import evidence as E
E.REPO = '.'
print('\n'.join(E.label_set('trackMuteButton')))
" 2>"$WORK/labels.err")
[ -n "${LABELS:-}" ] || { echo "REVERIFY FAIL: could not read AXLocalePolicy.trackMuteButton"; cat "$WORK/labels.err"; exit 1; }
IFS=$'\n' read -r -d '' -a LABEL_ARGS <<< "$LABELS" || true
"$WORK/probe" "${LABEL_ARGS[@]}" > "$WORK/out.txt" 2>&1
RC=$?
cat "$WORK/out.txt"
[ "$RC" -eq 2 ] && { echo "REVERIFY INCONCLUSIVE: the probe could not aim (see above)"; exit 1; }
[ "$RC" -eq 0 ] || { echo "REVERIFY FAIL: the probe exited $RC"; exit 1; }

field() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$WORK/out.txt"; }
MUTES=$(field "mute buttons")
UNFOCUSED=$(field "unfocused press actuated")
FOCUS_TOOK=$(field "focus took")
FOCUSED=$(field "focused press actuated")
RESTORED=$(field "restored")

# The instrument has to have been AIMED: 19 was measured, and a near-zero count means Logic is not
# showing a project, so the absence below would be silence rather than a reading.
[ -n "${MUTES:-}" ] && [ "$MUTES" -ge 4 ] || {
  echo "REVERIFY INCONCLUSIVE: only ${MUTES:-0} track-header Mute button(s) — Logic is probably not showing a project"; exit 1; }

[ "${FOCUS_TOOK:-0}" = "1" ] || {
  echo "REVERIFY INCONCLUSIVE: AXFocused would not take, so neither half of the claim was tested"; exit 1; }

if [ "${FOCUSED:-0}" != "1" ]; then
  echo "REVERIFY INCONCLUSIVE: the CONTROL failed — a focused press actuated nothing, so the"
  echo "  unfocused zero above is the instrument's silence and not a fact about focus"
  exit 1
fi

if [ "${UNFOCUSED:-0}" != "0" ]; then
  echo "REVERIFY FAIL: an UNFOCUSED press actuated. Focus is no longer the precondition this record"
  echo "  describes — a better world, and the record must be superseded rather than kept."
  exit 1
fi

[ "${RESTORED:-0}" = "1" ] || { echo "REVERIFY FAIL: the probe left the project mutated"; exit 1; }
echo "REVERIFY PASS — $MUTES Mute buttons; unfocused press actuated nothing, focused press actuated, state restored"
