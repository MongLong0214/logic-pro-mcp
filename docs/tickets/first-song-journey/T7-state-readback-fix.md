# T7: State Readback — Expanded AX Polling + Invalidation

**PRD Ref**: PRD-first-song-journey > US-4
**Priority**: P1
**Size**: M
**Status**: Todo
**Depends On**: T6

## 1. Objective
Make state resources reflect actual Logic Pro state by expanding AX polling beyond window title and invalidating cache when Logic Pro has no document.

## 2. Acceptance Criteria
- [ ] AC-1: `logic://project/info` returns error when hasDocument=false
- [ ] AC-2: StatePoller polls transport state via AX when MCU is disconnected
- [ ] AC-3: StatePoller polls track list via AX (count + names)
- [ ] AC-4: Post-mutation refresh: tool dispatch triggers immediate AX poll
- [ ] AC-5: `StateCache.clearProjectState()` called when hasDocument transitions false

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testProjectInfoErrorWhenNoDocument` | Unit | Resource returns error |
| 2 | `testStatePollerPollsTransportViaAX` | Unit | AX transport poll runs when MCU disconnected |
| 3 | `testMutationTriggersImmediatePoll` | Unit | Tool call → poll triggered |
| 4 | `testCacheClearedOnNoDocument` | Unit | hasDocument false → state cleared |

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/State/StatePoller.swift` | Add AX transport/track polling; post-mutation refresh signal |
| `Sources/LogicProMCP/State/StateCache.swift` | Add clearProjectState(); honor hasDocument |
| `Sources/LogicProMCP/Resources/ResourceHandlers.swift` | Check hasDocument before returning data |
