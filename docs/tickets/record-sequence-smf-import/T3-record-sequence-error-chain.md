# T3: record_sequence Fail-Fast Error Chain

**PRD Ref**: PRD-record-sequence-smf-import > US-3 (AC-3.1, AC-3.2, AC-3.3)
**Priority**: P1
**Size**: S
**Status**: Todo
**Depends On**: None

---

## 1. Objective

Refactor the current `record_sequence` to propagate all intermediate errors immediately instead of swallowing them with `_ = await router.route(...)`. This is a prerequisite for the full SMF rewrite (T6) and fixes H-4 independently.

## 2. Acceptance Criteria

- [ ] AC-1: If `track.select` fails, error returned immediately — no further steps.
- [ ] AC-2: If `track.set_arm` (disarm) fails on a specific track, continue disarming others but report failures.
- [ ] AC-3: If `transport.goto_position` fails, error returned — no recording attempt.
- [ ] AC-4: If `transport.record` fails, error returned — no play_sequence attempt.
- [ ] AC-5: All errors include the operation that failed and the channel error message.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testRecordSequenceFailsOnSelectError` | Unit | Mock: select fails | Error returned, no record/play ops |
| 2 | `testRecordSequenceFailsOnArmError` | Unit | Mock: arm fails | Error returned |
| 3 | `testRecordSequenceFailsOnGotoError` | Unit | Mock: goto_position fails | Error, no record started |
| 4 | `testRecordSequenceFailsOnRecordError` | Unit | Mock: transport.record fails | Error, no play_sequence |
| 5 | `testRecordSequenceHasDocumentGuard` | Unit | Cache hasDocument=false | Error "No project open" |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/DispatcherTests.swift`

### 3.3 Mock/Setup Required
- Selective `FailingExecuteChannel` per operation

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Modify | Add error checks to record_sequence |
| `Tests/LogicProMCPTests/DispatcherTests.swift` | Modify | Add fail-fast tests |

### 4.2 Implementation Steps (Green Phase)
1. Add `hasDocument` guard at top of record_sequence
2. Replace `_ = await router.route(...)` with `let result = await ...` + `.isSuccess` check
3. On error, return immediately with descriptive message

## 5. Edge Cases
- EC-1: Partial disarm failure → still attempt arm + record (warn in response)
- EC-2: No project open → error before any router calls

## 6. Review Checklist
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Existing record_sequence tests updated
- [ ] No transport state left dirty on early exit
