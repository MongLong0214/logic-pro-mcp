# T3: `logic_midi.read_selection_notes`

**PRD Ref**: `PRD-midi-readback-vNext` §7
**Priority**: P0 after any evidence gate PASS
**Status**: Blocked
**Depends On**: T0 or T1 or T2 PASS

## Objective

Implement the public selected-region note read-back command only after a controlled export/read surface is proven.

## Acceptance Criteria

- [ ] Add `logic_midi.read_selection_notes` with Accessibility routing.
- [ ] Return HC State A only when controlled file, parse, note equality, and identity gates pass.
- [ ] **Note-equality rule pinned (CTO)**: equality = pitch + velocity + onset + duration per note after PPQ/tempo normalization only (tick-resolution scaling between the sentinel spec and the exported SMF division). **No tolerance on note identity** — normalization affects tick math, never which notes exist. The exact normalization mapping is written into this ticket's red tests from the winning T0/T1/T2 evidence artifact before implementation starts.
- [ ] Return typed State B/C for no selection, non-MIDI selection, identity unavailable, modal recovery, parse failure, and note mismatch.
- [ ] Include `notes`, `selection_identity`, `smf_summary`, and `readback_source` in the response.
- [ ] Update docs/API and CHANGELOG only after live PASS evidence exists.

## Red Tests

- `readSelectionNotesStateAWhenSurfaceGatePasses`
- `readSelectionNotesStateBWhenIdentityUnavailable`
- `readSelectionNotesStateCWhenNoMidiSelection`
- `readSelectionNotesStateCWhenControlledFileMissing`
- `readSelectionNotesDoesNotClaimStateAOnParseFailure`

## Implementation Boundary

Likely files:

- `Sources/LogicProMCP/Dispatchers/MIDIDispatcher.swift`
- `Sources/LogicProMCP/Channels/RoutingTable.swift`
- new Accessibility helper for the proven surface
- `Tests/LogicProMCPTests/MIDIReadSelectionTests.swift`

## Manual QA Gate

Scratch project with known sentinel region, happy path plus no-selection failure.
