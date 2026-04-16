# T1: Implement `nav.goto_bar` on a live channel

**Priority**: P1
**Size**: S
**Status**: Ready

## Problem

`ChannelRouter.v2RoutingTable` routes `nav.goto_bar` to
`[.mcu, .cgEvent]`, but neither channel has a matching case:

- `MCUChannel.swift:64-99` — no `nav.goto_bar` → falls to `default`
  `.error("Unknown MCU operation")`.
- `CGEventChannel.swift:108-109` — `cgEventMapping` includes
  `nav.create_marker` and `nav.zoom_to_fit` only.

So every call to `NavigateDispatcher` command `goto_bar` fails with
a per-channel "not implemented" error string today.

## Proposed implementation

The natural code-based path is **CoreMIDI MMC locate**, which Logic Pro
already honours for `transport.goto_position`. Options:

1. **Preferred — delegate in the dispatcher**: rewrite
   `NavigateDispatcher` `goto_bar` to route `transport.goto_position`
   with `"{bar}.1.1.1"` (`MMCCommands.locate` behind the scenes).
   Remove the dead `nav.goto_bar` routing row.
2. **Alternative — add a real `nav.goto_bar` case in `CoreMIDIChannel`**
   that computes SMPTE from `{bar, beatsPerBar, tempo}` and emits
   `MMCCommands.locate`. More flexible but requires the dispatcher to
   also supply tempo/meter from the cache.

Pick (1) unless we find a scenario where `transport.goto_position`
isn't authoritative.

## Acceptance Criteria

- [ ] `logic_navigate.goto_bar { bar: 17 }` succeeds on a live Logic Pro session and repositions the playhead.
- [ ] A dispatcher unit test registers a mock CoreMIDI channel and asserts the expected `transport.goto_position` params `{ "position": "17.1.1.1" }`.
- [ ] The `nav.goto_bar` entry in `ChannelRouter.v2RoutingTable` is removed (or repointed) so the router no longer advertises a dead route.
- [ ] `docs/API.md` drops the "gap" callout for `goto_bar` and shows the new channel.
- [ ] `README.md` drops the matching callout.

## Out of scope

- Populating the marker cache (→ T2)
- Restructuring `NavigateDispatcher` into smaller units (leave as-is)
