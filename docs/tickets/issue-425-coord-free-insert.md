# #425 — Custom-action slot open and `AXPick` plugin selection

Status: shipped. Plugin insertion opens the requested slot with its measured
custom action and selects popup categories and leaves with `AXPick`.

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

Popup navigation uses `AXPick` for category and leaf selection. Picking a category
reveals its already-attached submenu without hover. Picking the exact plugin leaf
(or its preferred format leaf) likewise ignores the AX action return code. The
post-insert strip inventory diff decides the leaf outcome: it detects a mount in
the requested slot, detects and rolls back a stray mount, or produces the
appropriate fail-closed result when no verified change is observed.

## Narrow coordinate compatibility path

A coordinate click survives only when the target slot does not expose the custom
action. This compatibility fallback is recorded in the trace as
`slot_popup_open_fallback_taken: true` and
`slot_popup_open_action: "coordinate_fallback"`. The custom-action path records
`slot_popup_open_fallback_taken: false` and
`slot_popup_open_action: "custom_action"`, so receipts say which path ran.

There is no feature flag or coordinate leaf-selection fallback: category and leaf
selection are `AXPick` actions, and the observed inventory diff remains the
acceptance gate.

## Coverage

`Tests/LogicProMCPTests/PluginInsertVerifiedTests.swift` verifies that the custom
action can report failure while the observed popup permits progress, that a
success-looking action with no popup fails closed, that category `AXPick` reveals
the submenu without hover, and that leaf `AXPick` is accepted only when the
post-insert inventory observation supports it. It also verifies the trace values
for both the custom-action and absent-action coordinate-fallback slot-open paths.
