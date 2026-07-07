# T1: Logic Project/Package Event-Reader Spike

**PRD Ref**: `PRD-midi-readback-vNext` §6.4
**Priority**: P1
**Status**: Todo
**Depends On**: None

## Objective

Determine whether saved `.logicx` project/package data can expose MIDI note events for a known sentinel region without invoking Logic's export panel.

## Acceptance Criteria

- [ ] Create a scratch project with a single known MIDI sentinel region.
- [ ] Save a copy and inspect only that scratch package.
- [ ] Document whether note events, region identity, tempo map, and track mapping are recoverable.
- [ ] If recoverable, define a read-only parser boundary with no partial-result success.
- [ ] If not recoverable, record why the package surface is opaque or too unstable.

## Red Tests

- `logicProjectReaderRejectsUnknownChunk`
- `logicProjectReaderDoesNotReturnPartialNotes`
- `logicProjectReaderRequiresRegionIdentity`

## Implementation Boundary

Read-only spike and optional parser prototype. Do not alter production `LogicProjectFileReader` until evidence proves a stable format.

## Manual QA Gate

Evidence must include before/after package diff inventory and the exact parsed sentinel comparison.
