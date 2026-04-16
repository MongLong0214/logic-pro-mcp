# Navigate redesign — Status

**Opened**: 2026-04-16 (carved out of the v2.2 census-cleanup review)
**Priority**: P1
**Size**: M
**Status**: Done
**Depends On**: None

## Scope

Make `logic_navigate` honour its documented surface end-to-end, so
natural-language agents can drive Logic Pro's navigation without
discovering dead routes at runtime.

## Tickets

| Ticket | Status | Notes |
|--------|--------|-------|
| T1 — goto_bar via transport.goto_position | Done | Dispatcher delegates to AX bar-slider; dead `nav.goto_bar` route removed |
| T2 — marker cache population | Done | AX marker enumeration + StatePoller `pollMarkers()` wired |
| T3 — contract alignment | Done | docs/API.md + README.md gap callouts removed; tool description verified |

## Changes

- `NavigateDispatcher.swift`: `goto_bar` routes `transport.goto_position` with `"{bar}.1.1.1"`
- `ChannelRouter.swift`: removed dead `nav.goto_bar` routing entry
- `AccessibilityChannel.swift`: `nav.get_markers` delegates to `runtime.markers()` closure
- `AXLogicProElements.swift`: new `enumerateMarkers(in:runtime:)` reads marker ruler
- `StatePoller.swift`: new `pollMarkers()` on same cadence as other polls
- `docs/API.md`: gap callouts removed, channel column updated
- `README.md`: warning block removed, `goto_bar` example added
- Tests: +5 new (2 goto_bar dispatcher, 3 marker poller)
