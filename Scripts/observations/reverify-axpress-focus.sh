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
HEADER_PREFIX=$(python3 -c "
import sys; sys.path.insert(0, 'Scripts/livekit')
import evidence as E
E.REPO = '.'
labels = E.label_set('trackHeaderHelpPrefix')
print(labels[0] if labels else 'Track header')
" 2>/dev/null) || HEADER_PREFIX="Track header"
[ -n "${HEADER_PREFIX:-}" ] || HEADER_PREFIX="Track header"

"$WORK/probe" --track-header-help-prefix "$HEADER_PREFIX" --mute-labels "${LABEL_ARGS[@]}" > "$WORK/out.txt" 2>&1
RC=$?
cat "$WORK/out.txt"
# Exit 4 is "the probe could not put the project back". It is checked FIRST and on its own, because
# every other verdict below is a statement about a measurement, and this one is a statement about
# the user's project being left edited.
[ "$RC" -eq 4 ] && { echo "REVERIFY FAIL: the probe left a track MUTED and could not restore it — fix the project before re-running"; exit 1; }
[ "$RC" -eq 2 ] && { echo "REVERIFY INCONCLUSIVE: the probe could not aim (see above)"; exit 1; }
[ "$RC" -eq 0 ] || { echo "REVERIFY FAIL: the probe exited $RC"; exit 1; }

field() { awk -F': ' -v k="$1" '$1 == k {print $2}' "$WORK/out.txt"; }
MUTES=$(field "mute buttons")
HEADER_MUTES=$(field "mute buttons under a track header")
UNFOCUSED=$(field "unfocused press actuated")
FOCUS_TOOK=$(field "focus took")
FOCUSED=$(field "focused press actuated")
RESTORED=$(field "restored")

# RESTORED is read before anything else can exit, so no verdict is reached while the project is
# still edited. The probe exits 4 in that case, but a missing field must not read as success either.
[ "${RESTORED:-}" = "1" ] || {
  echo "REVERIFY FAIL: the run did not confirm the subject was restored (restored='${RESTORED:-<missing>}')"; exit 1; }

# The instrument has to have been AIMED: 19 was measured, and a near-zero count means Logic is not
# showing a project, so the absence below would be silence rather than a reading.
[ -n "${MUTES:-}" ] && [ "$MUTES" -ge 4 ] || {
  echo "REVERIFY INCONCLUSIVE: only ${MUTES:-0} track-header Mute button(s) — Logic is probably not showing a project"; exit 1; }
[ -n "${HEADER_MUTES:-}" ] && [ "$HEADER_MUTES" -ge 4 ] || {
  echo "REVERIFY INCONCLUSIVE: only ${HEADER_MUTES:-0} Mute button(s) under a track header — the subject would not be the element class this record is about"; exit 1; }

[ "${FOCUS_TOOK:-0}" = "1" ] || {
  echo "REVERIFY INCONCLUSIVE: AXFocused would not take, so neither half of the claim was tested"; exit 1; }

if [ "${FOCUSED:-0}" != "1" ]; then
  echo "REVERIFY INCONCLUSIVE: the CONTROL failed — a focused press actuated nothing, so the"
  echo "  unfocused zero above is the instrument's silence and not a fact about focus"
  exit 1
fi

# `${UNFOCUSED:-0}` would have defaulted a MISSING field to 0 — which is this check's SUCCESS
# value, so a probe that stopped printing this line would have passed. Absence is required to be
# absence, not agreement.
[ -n "${UNFOCUSED:-}" ] || { echo "REVERIFY FAIL: the probe did not report 'unfocused press actuated' at all"; exit 1; }
if [ "$UNFOCUSED" != "0" ]; then
  echo "REVERIFY FAIL: an UNFOCUSED press actuated. Focus is no longer the precondition this record"
  echo "  describes — a better world, and the record must be superseded rather than kept."
  exit 1
fi

echo "REVERIFY PASS — $MUTES Mute buttons; unfocused press actuated nothing, focused press actuated, state restored"
