# T1: Add Controller Assignments Learn Mode Guard For Live MIDI QA

**PRD Ref**: PRD-issue-175-controller-learn-mode-guard > US-1
**Priority**: P0 (Blocker)
**Size**: S (< 2h)
**Status**: Done
**Depends On**: None

---

## 1. Objective
Prevent live-e2e MIDI playback and transport record calls from running while Logic Controller Assignments Learn Mode or assignment prompts are active.

## 2. Acceptance Criteria
- [x] AC-1: Assignment prompts block with `assignment_prompt_present`.
- [x] AC-2: Enabled Learn Mode controls block with `learn_mode_enabled`.
- [x] AC-3: Inactive snapshots return clear.
- [x] AC-4: live-e2e guarded call sites return gate payloads instead of calling live MIDI/record when the guard is not clear.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `test_assignment_prompt_blocks` | Unit | Assignment prompt labels present | Blocked diagnostic |
| 2 | `test_enabled_learn_mode_checkbox_blocks` | Unit | Learn Mode checkbox truthy | Blocked diagnostic |
| 3 | `test_inactive_snapshot_is_clear` | Unit | No marker/control evidence | Clear |
| 4 | `test_detect_error_returns_error_with_policy_id` | Unit | Detector error | Error diagnostic |

### 3.2 Test File Location
- `Scripts/test_logic_controller_learn_mode.py`

### 3.3 Mock/Setup Required
- Fake runner returning static UI snapshots.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Scripts/logic_controller_learn_mode.py` | Add | Pure classifier plus JXA runner |
| `Scripts/test_logic_controller_learn_mode.py` | Add | Regression tests |
| `Scripts/live-e2e-test.py` | Modify | Gate live MIDI/record call sites |
| `Scripts/release-stable.sh` | Modify | Include helper/test in release script validation |

### 4.2 Implementation Steps (Green Phase)
1. Add failing unit tests for clear, prompt, active Learn Mode, and detector error.
2. Implement the pure classifier and injectable System Events runner.
3. Add helper functions in live-e2e to gate guarded live calls before side effects.
4. Run Python unit tests, py_compile, and targeted text checks.

## 5. Edge Cases
- Detector error must not allow guarded live MIDI calls to run.
- Non-strict live-e2e can skip guarded operations with a clear reason.
- Strict live-e2e fails the guard test when Learn Mode is active or detector errors.

## 6. Review Checklist
- [x] Red: 테스트 실행 → FAILED 확인됨
- [x] Green: 테스트 실행 → PASSED 확인됨
- [x] Refactor: 테스트 실행 → PASSED 유지 확인됨
- [x] AC 전부 충족
- [x] 기존 테스트 깨지지 않음
- [x] 코드 스타일 준수
- [x] 불필요한 변경 없음
