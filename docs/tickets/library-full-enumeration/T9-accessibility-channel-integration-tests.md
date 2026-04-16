# T9: AccessibilityChannel Integration Tests (setTrackInstrument Branch Coverage)

**PRD Ref**: PRD-library-full-enumeration > §8.2
**Priority**: P1
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T4, T5, T6, T7

---

## 1. Objective
Drive `AccessibilityChannel.setTrackInstrument` to 100 % branch coverage. Cover the full PRD §8.2 branch list (13 setTrackInstrument branches + 11 scanLibraryAll branches). Tests from T4-T7 feed into this; T9 fills gaps.

## 2. Acceptance Criteria
- [ ] 100 % branch coverage on `setTrackInstrument` (via `llvm-cov`)
- [ ] 100 % branch coverage on `scanLibraryAll` (via `llvm-cov`)
- [ ] All 24 branches in PRD §8.2 have a dedicated test

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases (gaps not covered by T4-T7)

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testSetInstrument_IndexAbsent_LegacyPath` | Integration | `{ category, preset }`, no index | Legacy path executes without track select |
| 2 | `testSetInstrument_IndexPresent_HeaderFound_PosValueBranch` | Integration | posValue available | CGEvent click path |
| 3 | `testSetInstrument_IndexPresent_HeaderFound_PosValueNil_FallbackPress` | Integration | posValue=nil | Falls back to kAXPressAction |
| 4 | `testSetInstrument_IndexPresent_HeaderNotFound` | Integration | findTrackHeader returns nil | Error, no lib click |
| 5 | `testScanLibraryAll_FocusLoss_AbortsRestore` | Integration | Mock kAXFocusedApplicationAttribute mid-scan → different app | Aborts, restore attempted |
| 6 | `testScanLibraryAll_AXMutationMidScan_Aborts` | Integration | Scanner's own click excluded; external mutation simulated | Aborts with E5 error |
| 7 | `testScanLibraryAll_CacheWriteFailure_Tolerated` | Integration | Mock Resources write throws | Scan response still returned |
| 8 | `testScanLibraryAll_LibraryRootJSON_SchemaCompliance` | Integration | Decode response as LibraryRoot | All fields present |
| 9 | `testScanLibraryAll_FlattenPolicy_Depth3Actually` | Integration | Deep mock tree | presetsByCategory contains nested-depth leaves |
| 10 | `testSetInstrument_PostEventProbe_RunsOnce` | Integration | Second call in same session | Probe invoked exactly once (cached) |
| 11 | `testSetInstrument_LegacyShape_AC2_3_ResponseJSON` | Integration | Call with `{ category, preset }` legacy shape | Response JSON contains `"category"`, `"preset"`, `"path"` (path = `"category/preset"`) |
| 12 | `testSystemPermissions_IncludesPostEventCapability` | Integration | Call `system.permissions` MCP tool after T5 lands | Response enumerates both Accessibility + Post-Event capabilities |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AccessibilityChannelBranchCoverageTests.swift` (NEW)

### 3.3 Mock/Setup Required
- Composition of all mocks from T4-T7
- Filesystem mock for Resources write (EC-7)

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Tests/LogicProMCPTests/AccessibilityChannelBranchCoverageTests.swift` | Create | 12 tests |

### 4.2 Implementation Steps
1. Write tests per §3.1.
2. Run coverage; identify uncovered branches.
3. Add additional targeted tests until `scanLibraryAll` and `setTrackInstrument` show 100 % branches covered.

### 4.3 Refactor Phase
- None.

## 5. Edge Cases
Covered across all tests.

## 6. Review Checklist
- [ ] All tests Red → Green
- [ ] `llvm-cov` shows 100 % branch on both functions
- [ ] Total project tests ≥ 550 after T8+T9
