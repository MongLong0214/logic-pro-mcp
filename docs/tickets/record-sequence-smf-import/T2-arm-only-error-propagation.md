# T2: arm_only Error Propagation Fix

**PRD Ref**: PRD-record-sequence-smf-import > US-4 (AC-4.1, AC-4.2)
**Priority**: P1
**Size**: S
**Status**: Todo
**Depends On**: None

---

## 1. Objective

Fix `arm_only` to report partial disarm failures and reflect actual arm success in the response, while maintaining backward compatibility with existing callers.

## 2. Acceptance Criteria

- [ ] AC-1: Response includes `armedSuccess: true/false` reflecting `armResult.isSuccess`.
- [ ] AC-2: Response includes `failedDisarm: [Int]` listing track indices where disarm failed.
- [ ] AC-3: `armed` field kept as int (track index) for backward compat.
- [ ] AC-4: If armResult fails, `armedSuccess` is false and `detail` contains the error message.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testArmOnlyReportsPartialDisarmFailure` | Unit | Mock: disarm track 2 fails, track 3 succeeds | `failedDisarm: [2]`, `disarmed: [3]` |
| 2 | `testArmOnlyReportsArmFailure` | Unit | Mock: arm target fails | `armedSuccess: false` |
| 3 | `testArmOnlySuccessPath` | Unit | All operations succeed | `armedSuccess: true`, `failedDisarm: []` |
| 4 | `testArmOnlyBackwardCompatArmedField` | Unit | Success path | `armed` is still the track index int |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/DispatcherTests.swift` (existing MARK: TrackDispatcher section)

### 3.3 Mock/Setup Required
- `MockChannel` (existing) + `FailingExecuteChannel` (existing) for selective failures

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Modify | Rewrite arm_only response |
| `Tests/LogicProMCPTests/DispatcherTests.swift` | Modify | Add arm_only tests |

### 4.2 Implementation Steps (Green Phase)
1. Track `failedDisarm` array alongside existing `disarmed` array
2. Check `armResult.isSuccess` for the `armedSuccess` field
3. Build response JSON with all fields

### 4.3 Refactor Phase
- None expected

## 5. Edge Cases
- EC-1: No tracks to disarm (target is only armed track) → `disarmed: [], failedDisarm: []`
- EC-2: Target track doesn't exist in cache → arm_only should still attempt arm

## 6. Review Checklist
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Refactor: tests run → PASSED maintained
- [ ] AC-1 through AC-4 satisfied
- [ ] Existing tests still pass
