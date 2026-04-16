# T6: record_sequence SMF-Import Rewrite

**PRD Ref**: PRD-record-sequence-smf-import > US-1, US-2, US-3
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: T1 (SMFWriter), T3 (error chain), T4 (import handler)

---

## 1. Objective

Rewrite `TrackDispatcher.record_sequence` to use server-side SMF generation + file import instead of real-time CoreMIDI recording. This eliminates timing jitter and multi-track drift.

## 2. Acceptance Criteria

- [ ] AC-1: `record_sequence` generates a .mid file via SMFWriter, imports via `midi.import_file`, and returns success.
- [ ] AC-2: The response includes `recorded_to_track`, `bar`, `note_count`, `method: "smf_import"`.
- [ ] AC-3: Temp .mid file is cleaned up via `defer` on both success and failure.
- [ ] AC-4: `hasDocument` guard returns error if no project open.
- [ ] AC-5: Each intermediate step (select, generate, write, import) propagates errors.
- [ ] AC-6: Uses tempo from cache (or override param) for ms→tick conversion.
- [ ] AC-7: Old real-time recording path (sleep + play_sequence) is removed.
- [ ] AC-8: Notes parsed from the same `"pitch,offsetMs,durMs[,vel[,ch]];..."` format.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testRecordSequenceSMFImportHappyPath` | Integration | Full flow with mock channels | Success with note_count and method |
| 2 | `testRecordSequenceSMFImportCleansUpOnSuccess` | Unit | Check temp file removed | No .mid files in /tmp/LogicProMCP/ |
| 3 | `testRecordSequenceSMFImportCleansUpOnError` | Unit | Import fails | Temp file still cleaned up |
| 4 | `testRecordSequenceUsesTempoFromCache` | Unit | Cache tempo=140 | SMFWriter called with 140 |
| 5 | `testRecordSequenceUsesTempoOverride` | Unit | params tempo=90 | SMFWriter called with 90 |
| 6 | `testRecordSequenceOldPathRemoved` | Unit | No play_sequence routing | No midi.play_sequence in router ops |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/DispatcherTests.swift`

### 3.3 Mock/Setup Required
- MockChannel for all channels
- Mock SMFWriter (or use real one since it's pure data)
- Temp directory management for cleanup assertions

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Modify | Rewrite record_sequence case |

### 4.2 Implementation Steps (Green Phase)
1. Guard `hasDocument` from cache
2. Parse notes spec → validate
3. Get tempo from cache (or params override)
4. Convert notes to SMFWriter.NoteEvent via msToTicks
5. Call SMFWriter.generate with bar + events → Data
6. Write to `/tmp/LogicProMCP/{uuid}.mid` with `defer { cleanup }`
7. Select track (fail-fast)
8. Route `midi.import_file` with path
9. Return result JSON
10. Remove old play_sequence + sleep + record path

## 5. Edge Cases
- EC-1: Tempo in cache is 0 or very low → use 120 default
- EC-2: Time signature not in cache → default 4/4
- EC-3: /tmp/LogicProMCP/ doesn't exist → create it

## 6. Review Checklist
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Old real-time path completely removed
- [ ] No timing-dependent code (no sleep, no play_sequence)
- [ ] Temp files cleaned up in all paths
