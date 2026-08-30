# T4: `record_sequence verify_notes`

**PRD Ref**: `PRD-midi-readback-vNext` §7
**Priority**: P1
**Status**: Todo
**Depends On**: a release-constructible `authoredIntent` proof. NOT T3 — see below.

## Objective

Add optional note-level verification to `record_sequence` without changing the default import behavior.

## Acceptance Criteria

- [ ] `verify_notes` defaults to false and keeps current response behavior unchanged.
- [ ] When true, `record_sequence` captures pre-state, creates/imports a region, deterministically selects the created region, reads it back through a readback surface, and compares against the AUTHORED notes — the `[SMFWriter.NoteEvent]` parsed from the caller's request before anything was written.
- [ ] Selection failure returns State B before export attempt.
- [ ] Note mismatch returns State C with expected/observed summary.
- [ ] Previous selection/playhead restoration is attempted and reported.

## Red Tests

- `recordSequenceVerifyNotesDefaultFalseIsBackwardCompatible`
- `recordSequenceVerifyNotesStateAOnExactReadback`
- `recordSequenceVerifyNotesStateBWhenCreatedRegionNotSelectable`
- `recordSequenceVerifyNotesStateCOnMismatch`
- `recordSequenceVerifyNotesRestoresPreviousSelectionBestEffort`

## Why this is not behind T3 (2026-08-30)

The AC used to say "exports/reads it through the T3 surface", and that sentence is what created
the dependency. It named an implementation, and the implementation it named is the one blocked.

What T4 needs is an expected sequence that cannot agree with the write by sharing its mistake, and
it already has one. `record_sequence` parses the caller's `notes` into `[SMFWriter.NoteEvent]`
BEFORE it writes anything; that value is fixed before the read and never re-encoded from
observation, which is the PRD's write-oracle verbatim — `IndependentExpectedRoot.authoredIntent`,
whose own comment names `record_sequence`.

T3 is a different class. `read_selection_notes` returns notes nobody just wrote, so there is no
authored intent behind them and its expected must come from a second observation surface. That is
what T0/T1/T2 are for, and T3 still waits on them.

The observed side needs a readback surface, not a public operation. `EventListReadbackCollector`
is one and is measured reading a real note table (#293 / #712): ten checks clean on a Korean Logic,
both recorded notes returned, eight columns bound.

### What actually blocks T4

`IndependentExpectedSeam` is inside `#if QUALIFICATION_FAULT_SEAM`, so a release build's
`independentPayload` is always nil and `verifyRegion` can only answer `incompleteCannotVerify`.
For `authoredIntent`, R2's "live-ingestion boundary" is a release-reachable constructor plus the
guards that already exist — not a file route.

That constructor is the one thing this ticket has to earn, and it has to earn it without
reopening the hole R1 closed: an `O→E` copy must still be refused, which criterion 4 of the PRD
calls the load-bearing strict case.

## Implementation Boundary

Likely files:

- `Sources/LogicProMCP/Dispatchers/TrackDispatcher+RecordSequence.swift`
- `Sources/LogicProMCP/MIDIReadback/MIDINoteIndependentVerification.swift` (the release-reachable
  `authoredIntent` constructor)
- `Sources/LogicProMCP/MIDIReadback/EventListReadbackCollector.swift` as the observed surface
- focused dispatcher tests and one live E2E case

## Manual QA Gate

Fresh scratch project, `verify_notes:true` happy path, then deliberate note mismatch fixture.
