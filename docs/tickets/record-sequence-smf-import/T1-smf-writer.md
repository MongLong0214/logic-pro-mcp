# T1: SMFWriter — Type 0 Standard MIDI File Generator

**PRD Ref**: PRD-record-sequence-smf-import > US-1 (AC-1.1, AC-1.2)
**Priority**: P1
**Size**: M
**Status**: Todo
**Depends On**: None

---

## 1. Objective

Implement a pure-data `SMFWriter` struct that generates Type 0 Standard MIDI Files from a note spec, with correct tempo/time-signature meta-events and bar-position-aware tick offsets.

## 2. Acceptance Criteria

- [ ] AC-1: `SMFWriter.generate(events:bar:tempo:timeSignature:)` returns valid SMF Type 0 `Data` that can be written to a `.mid` file.
- [ ] AC-2: Generated file starts with `MThd` header (format 0, 1 track, 480 ticks/quarter).
- [ ] AC-3: Track contains tempo meta-event matching input BPM.
- [ ] AC-4: Track contains time-signature meta-event.
- [ ] AC-5: Note-on/off events at correct tick positions (ms → ticks with round-half-up).
- [ ] AC-6: Events offset by `(bar - 1) * ticksPerBar` ticks for bar positioning.
- [ ] AC-7: `msToTicks()` conversion produces correct results for common tempos (120, 90, 137 BPM).
- [ ] AC-8: Empty events array throws an error.
- [ ] AC-9: Notes with pitch > 127 are rejected.
- [ ] AC-10: Up to 1024 notes accepted.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testSMFWriterGeneratesValidHeader` | Unit | Check MThd bytes | First 14 bytes match SMF header |
| 2 | `testSMFWriterTempoMetaEvent` | Unit | 120 BPM → 500000 μs/quarter | FF 51 03 07 A1 20 |
| 3 | `testSMFWriterTimeSignatureMetaEvent` | Unit | 4/4 → FF 58 04 04 02 18 08 | Correct bytes |
| 4 | `testSMFWriterNoteEventsAtCorrectTicks` | Unit | 3 quarter notes at 120 BPM, ms offsets 0/500/1000 | Ticks at 0/240/480 |
| 5 | `testSMFWriterBarOffset` | Unit | Bar 5, 4/4 at 480 tpq → offset 4*4*480=7680 ticks | First note at tick 7680 |
| 6 | `testSMFWriterMsToTicksRoundHalfUp` | Unit | 83ms at 137 BPM → 90.77 → 91 ticks | Returns 91 |
| 7 | `testSMFWriterRejectsEmptyEvents` | Unit | Empty array | Throws error |
| 8 | `testSMFWriterRejectsInvalidPitch` | Unit | Pitch 128 | Throws error |
| 9 | `testSMFWriterAccepts1024Notes` | Unit | 1024 notes | No error |
| 10 | `testSMFWriterEndOfTrack` | Unit | Last bytes | FF 2F 00 |
| 11 | `testSMFWriterVariableLengthEncoding` | Unit | Delta time > 127 | Correct VLQ encoding |
| 12 | `testSMFWriterChordEvents` | Unit | 3 notes at same offset | 3 note-ons at delta 0 |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SMFWriterTests.swift`

### 3.3 Mock/Setup Required
- No mocks needed — pure data transformation.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/MIDI/SMFWriter.swift` | Create | SMF generator struct |
| `Tests/LogicProMCPTests/SMFWriterTests.swift` | Create | Unit tests |

### 4.2 Implementation Steps (Green Phase)
1. Implement variable-length quantity encoding (`encodeVLQ`)
2. Implement `msToTicks()` conversion with round-half-up
3. Implement `generate()`:
   a. Build MThd header (14 bytes)
   b. Build tempo meta-event
   c. Build time-signature meta-event
   d. Calculate bar offset: `(bar - 1) * numerator * ticksPerQuarter`
   e. Sort events by offsetTicks, build note-on/off with delta times
   f. Append end-of-track meta-event
   g. Wrap track data in MTrk chunk with length prefix
   h. Return header + track

### 4.3 Refactor Phase
- Extract binary helpers if repeated (UInt16BE, UInt32BE, etc.)

## 5. Edge Cases
- EC-1: Delta time requires multi-byte VLQ (>= 128 ticks between events)
- EC-2: Chord (multiple notes at same tick) — delta 0 for second+ notes
- EC-3: Bar 1 → offset = 0 ticks (no shift)
- EC-4: Very fast tempo (240 BPM) with short notes — tick resolution sufficient at 480 tpq

## 6. Review Checklist
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Refactor: tests run → PASSED maintained
- [ ] AC-1 through AC-10 satisfied
- [ ] Existing 668 tests still pass
- [ ] No unnecessary changes
