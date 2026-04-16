# T2: Populate the marker cache from a live source

**Priority**: P1
**Size**: M
**Status**: Ready (parallelisable with T1)

## Problem

`NavigateDispatcher` `goto_marker { name: ... }` and
`delete_marker { name: ... }` look markers up via
`StateCache.getMarkers()`. The cache exposes
`updateMarkers(_:)` (`StateCache.swift:106`) but **no producer ever
calls it** — `StatePoller` only polls transport, tracks, project
metadata, and mixer. `AccessibilityChannel.swift:311` returns
`"Marker reading not yet implemented via AX"` when the router asks.

So every by-name marker navigation request fails with an
"empty cache" response, even when Logic has markers.

## Proposed implementation

Two stages:

1. **AX enumeration of markers.** Extend `AXLogicProElements` with a
   `findMarkerStrip()` that reads the arrange-area marker row, and
   turn the stub at `AccessibilityChannel.swift:311` into a real
   implementation that returns `[MarkerState]` as JSON.

2. **Poller wiring.** Add `pollMarkers()` to `StatePoller` on the
   same cadence as `pollProjectInfo` (3 s), calling
   `AccessibilityChannel.execute("nav.get_markers")` and pushing the
   parsed result into `cache.updateMarkers(_:)`. Respect the
   `!hasDocument` short-circuit so closed projects clear markers
   through `clearProjectState` (already does `markers = []`).

## Acceptance Criteria

- [ ] Live test with markers in a Logic project: `logic://project/info` (or a new `logic://markers`) surfaces the marker list.
- [ ] `logic_navigate.goto_marker { name: "Hook" }` succeeds when the cache is populated.
- [ ] `AccessibilityChannel` `nav.get_markers` returns a parseable JSON array on live Logic.
- [ ] `StatePoller` has a dedicated test that mocks the AX channel and asserts `cache.getMarkers()` is populated.
- [ ] No stale markers remain after `clearProjectState` (regression test).

## Out of scope

- Creating a new resource URI `logic://markers` (optional stretch; fine to fold into `logic://project/info`)
- MCU-based marker enumeration (MCU doesn't expose marker names)
