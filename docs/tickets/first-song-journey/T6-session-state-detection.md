# T6: Session State Detection (hasVisibleWindow + hasDocument)

**PRD Ref**: PRD-first-song-journey > US-5
**Priority**: P1
**Size**: M
**Status**: Todo
**Depends On**: None

## 1. Objective
Detect windowless/ghost Logic Pro sessions. Add `hasVisibleWindow()` and `hasDocument` flag so health checks and operations report accurate state.

## 2. Acceptance Criteria
- [ ] AC-1: `ProcessUtils.hasVisibleWindow()` uses CGWindowListCopyWindowInfo, filters on-screen non-zero-area
- [ ] AC-2: During startup (first 10s), retries before reporting windowless
- [ ] AC-3: `StateCache.hasDocument` flag, set by StatePoller
- [ ] AC-4: Health response includes `logic_pro_has_document` and `logic_pro_has_window`
- [ ] AC-5: AppleScript/AX operations check hasDocument before attempting

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testHasVisibleWindowDetectsWindows` | Unit | Returns true when windows exist |
| 2 | `testHasVisibleWindowReturnsFalseNoWindows` | Unit | Returns false for windowless |
| 3 | `testHealthIncludesDocumentStatus` | Unit | JSON has has_document field |
| 4 | `testOperationsFailWhenNoDocument` | Unit | Error returned for no-doc state |

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/Utilities/ProcessUtils.swift` | Add `hasVisibleWindow()` via CGWindowListCopyWindowInfo |
| `Sources/LogicProMCP/State/StateCache.swift` | Add `hasDocument: Bool` flag + `clearProjectState()` |
| `Sources/LogicProMCP/State/StatePoller.swift` | Set hasDocument flag based on AX poll result |
| `Sources/LogicProMCP/Dispatchers/SystemDispatcher.swift` | Include has_document/has_window in health |
