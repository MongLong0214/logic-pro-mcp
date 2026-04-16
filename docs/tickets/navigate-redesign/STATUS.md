# Navigate redesign — Status

**Opened**: 2026-04-16 (carved out of the v2.2 census-cleanup review)
**Priority**: P1
**Size**: M
**Status**: Ready to spec
**Depends On**: None (can start immediately)

## Scope

Make `logic_navigate` honour its documented surface end-to-end, so
natural-language agents can drive Logic Pro's navigation without
discovering dead routes at runtime.

## Open tickets

- `T1-goto-bar-implementation.md` — pick a real channel (CoreMIDI MMC locate? AX field?) and wire it up
- `T2-marker-cache-population.md` — give the state poller an AX/MCU path that actually fills `StateCache.updateMarkers`
- `T3-navigate-contract-alignment.md` — after T1+T2, update README + docs/API.md and remove the "known gap" callouts

## References

- `Sources/LogicProMCP/Dispatchers/NavigateDispatcher.swift:29`
- `Sources/LogicProMCP/Channels/AccessibilityChannel.swift:311` (`nav.get_markers` returns "not yet implemented")
- `Sources/LogicProMCP/State/StatePoller.swift:94` — pollers don't call `updateMarkers`
- `Sources/LogicProMCP/State/StateCache.swift:106` — `updateMarkers` is defined but no producer
- census review: `[H-3]` finding
