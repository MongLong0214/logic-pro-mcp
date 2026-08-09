# #425 — Custom-action slot open and read-only plugin discovery

Status: shipped. Plugin insertion opens the requested slot with its measured
custom action, discovers popup entries without actuating categories, and selects
only the requested plugin leaf with `AXPick`.

## Shipped design

When the target empty slot exposes the measured opener, slot-open uses the exact custom action name below. It is 70 UTF-8 bytes, has real newline characters, and has no surrounding quote characters:

```
Name:Open plug-in menu with legacy plug-ins
Target:0x0
Selector:(null)
```

The custom action's return code is not an acceptance signal. After dispatch, the
driver polls for the popup and verifies that the popup is anchored to the target
slot; those observations decide whether slot-open succeeded. On 2026-08-08, AX
action return codes were observed to disagree with the effect in both directions:
an action can report failure after opening the popup, and can report success
without the required observed effect.

Discovery is read-only: it uses no popup-search strategy or search-field writes,
recurses through the already-attached `AXMenu` child, and performs no AX action on any non-target item.
`AXPick` is dispatched only to the leaf whose name matched the request exactly, and to its preferred-format leaf. As with
the slot opener, its return code is not accepted as success by itself. The
post-insert strip inventory diff decides the leaf outcome: it detects a mount in
the requested slot, detects and rolls back a stray mount, or produces the
appropriate fail-closed result when no verified change is observed.

Read-only discovery is sufficient on the measured Logic configuration because
category submenus were already populated before any pick. Measured against the
running application, the attached child counts were:

| Category | Children before pick | Children after pick |
| --- | ---: | ---: |
| Gain | 2 | 2 |
| Compressor | 1 | 1 |
| Channel EQ | 1 | 1 |
| Tremolo | 2 | 2 |
| Flanger | 2 | 2 |
| Amps and Pedals | 4 | 4 |

Each category was therefore not lazy. This was measured on one Logic version and locale;
it records why a read-only recursive walk is sufficient for that observed version,
rather than assuming that every future version or locale behaves alike.

## Narrow coordinate compatibility path

A coordinate click survives only when the target slot does not expose the custom
action. This compatibility fallback is recorded in the trace as
`slot_popup_open_fallback_taken: true` and
`slot_popup_open_action: "coordinate_fallback"`. The custom-action path records
`slot_popup_open_fallback_taken: false` and
`slot_popup_open_action: "custom_action"`, so receipts say which path ran.

There is no feature flag or coordinate leaf-selection fallback: the exact
matching leaf and its preferred-format leaf use `AXPick`, and the observed
inventory diff remains the acceptance gate.

## Coverage

`Tests/LogicProMCPTests/PluginInsertVerifiedTests.swift` verifies that the custom
action can report failure while the observed popup permits progress, that a
success-looking action with no popup fails closed, that read-only category
discovery reaches an already-attached submenu with neither non-target AX actions
nor attribute writes, and that leaf `AXPick` is accepted only when the post-insert
inventory observation supports it. It also verifies the trace values for both the
custom-action and absent-action coordinate-fallback slot-open paths.

## What State A does not prove

These are limits of the verification, not open work items. They are written down so a reader does not
read more into a State A receipt than it carries.

**Product identity is a display string.** The leaf is chosen by exact title match and the mount is
confirmed by mapping the observed slot name back to the requested id. Two products exposing the same
AX title are indistinguishable to both steps, so State A certifies "a plug-in presenting this name is
now at the requested slot", not "this exact product is". AX exposes no stable product identifier on
these menu entries on the measured build.

**Attribution is a diff, not a transaction.** Acceptance is a pre/post inventory diff taken around
this call. If the requested plug-in arrives at the requested slot from another source inside that
window, the diff cannot tell that apart from our own pick. A wrong SLOT is caught — the observed slot
must equal the requested one and is rolled back otherwise — but a concurrent identical mount at the
same slot is not distinguishable.

**Check-and-act is not atomic.** Every guard here reads AX and then acts; macOS offers no way to hold
the tree between the two. The window is now as small as the code can make it — the slot is re-read
and required to be both still empty and still the same element immediately before actuation, and the
pop-up must be one that appeared after that actuation — but a change landing inside that remaining
window is not detectable from this process.

