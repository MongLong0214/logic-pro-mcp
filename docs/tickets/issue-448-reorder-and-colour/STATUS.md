# #448's two remaining halves, and what each of them is actually waiting on

Size: **S for colour** (the measurement is done; what is left is a decision and a two-line change),
**M-or-refusal for reorder** (the route may not exist, and finding out costs a measurement this
ticket names).

## 1. Colour — measured, and it is a wall on this surface

`docs/observations/2026-09-09-no-attribute-value-anywhere-carries-a-track-colour.json`:

    attributes of CGColor type            0   of 1406 elements, depth 16, every window
    values naming a colour                0   palette closed
                                          2   palette open — both the palette WINDOW's own title
    child lists genuinely unreadable      0

The colour palette was the route the 2026-09-08 record left unswept; it is swept now and no swatch
exposes a value.

**The decision this leaves.** `TrackState.color` is populated by nothing, and
`AccessibilityChannel+Tracks.swift:2171` joins it into the track fingerprint with `|`. So the
fingerprint carries a component that is always empty, and a colour change cannot move it — a
consumer comparing fingerprints will not see a recoloured track, and nothing says so.

Two honest options, and the ticket picks the second:

    remove `color` from the fingerprint   smallest, but the field stays in the model, still always
                                          nil, and the next reader will ask the same question again
    keep it and say what it means         the fingerprint gains a comment naming the record, and the
                                          model field gains one — the component stays so that a
                                          future colour reader lights it up without a schema change,
                                          and the always-empty state stops being silent

**Not in scope:** reading the `.logicx` package. That is the one route the record does not close,
and it is a different surface with its own trust question.

## 2. Reorder — the route may not exist, and that is not yet measured

The row says anchor-based reorder is drag-only. Drag means screen coordinates, which this project
does not do.

**Measured 2026-09-09, en:**

    Track menu           `Sort Tracks by` and nothing else that moves a track
    Edit > Move          `To Playhead`, `To Recorded Position`, `To Beat`,
                         `First Transient to Nearest Beat`, `To Focused Track`,
                         `Shuffle Left`, `Shuffle Right` — all REGION operations, not tracks

**NOT measured, and it is the next step:** whether Logic exposes a *key command* for moving a track
up or down. Two routes to the Key Commands window were tried and neither opened it — the
`Logic Pro > Key Commands` item reports `missing value` for its submenu and clicking it does
nothing through AX, and Option+K produced no window. So the key-command surface is unread, not
absent, and this ticket must not record it as absent.

**The decision, once that is measured.** If a key command exists, reorder is implementable the way
everything else here is — drive the command, verify the effect against a caller-supplied order,
exactly as `sort_verified` already does. If it does not, the honest outcome is an explicit refusal
that names why: the only route Logic offers is a drag, and a drag is a screen coordinate.

## 3. What this ticket does NOT establish

That colour is unobservable anywhere — only that it is unobservable through the accessibility tree,
which is what the product reads. And that no key command exists for reorder — only that two ways of
opening the window to look did not work.


## The issue's own harness cannot run on the current fixture

`live_448_track_stack_readback` fails two PRECONDITIONS here, before it tests anything:

    448/precondition-the-project-has-exactly-one-track-stack
        arrows: 2, value: 0, owner: 'Absolute Zero'
    448/precondition-logic-offers-a-disclosure-command-that-is-not-a-structural-one
        accepted={} rejected={} — every Track-menu item classified structural

The `lpm-locale-campaign` fixture has grown a second disclosure arrow, so the harness's "exactly one
track stack" no longer holds. That is a fixture fact, not a regression in the code under test, and
it means this issue's own live proof is currently unrunnable — which is worth knowing before anyone
reads its silence as a pass.

Closing #448 will need either a fixture with exactly one stack, or a harness whose precondition is
stated in terms it can establish itself.
