# T4: `record_sequence verify_notes`

**PRD Ref**: `PRD-midi-readback-vNext` §7
**Priority**: P1 after T3
**Status**: Blocked
**Depends On**: T3

## Objective

Add optional note-level verification to `record_sequence` without changing the default import behavior.

## Acceptance Criteria

- [ ] `verify_notes` defaults to false and keeps current response behavior unchanged.
- [ ] When true, `record_sequence` captures pre-state, creates/imports a region, deterministically selects the created region, exports/reads it through the T3 surface, and compares notes.
- [ ] Selection failure returns State B before export attempt.
- [ ] Note mismatch returns State C with expected/observed summary.
- [ ] Previous selection/playhead restoration is attempted and reported.

## Red Tests

- `recordSequenceVerifyNotesDefaultFalseIsBackwardCompatible`
- `recordSequenceVerifyNotesStateAOnExactReadback`
- `recordSequenceVerifyNotesStateBWhenCreatedRegionNotSelectable`
- `recordSequenceVerifyNotesStateCOnMismatch`
- `recordSequenceVerifyNotesRestoresPreviousSelectionBestEffort`

## Implementation Boundary

Likely files:

- `Sources/LogicProMCP/Dispatchers/TrackDispatcher+RecordSequence.swift`
- selected-region helper from T3
- focused dispatcher tests and one live E2E case

## Manual QA Gate

Fresh scratch project, `verify_notes:true` happy path, then deliberate note mismatch fixture.
