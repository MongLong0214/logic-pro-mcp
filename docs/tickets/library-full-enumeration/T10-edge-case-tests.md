# T10: Edge-Case Tests E1-E22

**PRD Ref**: PRD-library-full-enumeration > §8.3, §5 E1-E22
**Priority**: P1
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T1-T9

---

## 1. Objective
Every row E1-E22 in PRD §5 gets a dedicated test. Produces ≥ 22 new tests.

## 2. Acceptance Criteria
- [ ] ≥ 22 edge-case tests
- [ ] Each test references its PRD edge ID in the test docstring/name
- [ ] All edge cases in §5 have at least one test

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name (maps to PRD E#) | Type |
|---|---------------------------|------|
| 1 | `testE1_LibraryPanelClosed` | Integration |
| 2 | `testE2_CategoryWith0Presets` | Integration |
| 3 | `testE3_DuplicateSiblings_PathDisambiguated` | Unit |
| 4 | `testE4_PresetNameWithSlash_EscapedCorrectly` | Unit |
| 5 | `testE5_AXTreeMutatesMidScan_ScannerAborts` | Integration |
| 6 | `testE5b_ScannerSelfClick_DoesNotTriggerAbort` | Integration |
| 7 | `testE5c_FocusLoss_AbortAndRestore` | Integration |
| 8 | `testE6_UnicodeRTLCategoryNames_Preserved` | Unit |
| 9 | `testE7_ColumnNeverPopulates_ProbeTimeout` | Unit |
| 10 | `testE8_DepthExceeds12_TruncatedMarker` | Unit |
| 11 | `testE8b_CycleDetection_VisitedSet` | Unit |
| 12 | `testE9_LogicPro_NotRunning` | Integration |
| 13 | `testE10_NoAccessibilityPermission_EarlyError` | Integration |
| 14 | `testE10b_NoPostEventAccess_EarlyError` | Integration |
| 15 | `testE11_BothPathAndCategoryPresetParams_PathWins` | Integration |
| 16 | `testE12_NoPathNoCategoryPreset_Error` | Integration |
| 17 | `testE13_OffScreenTrackHeader_Error` | Integration |
| 18 | `testE14_ZeroSoundLibraryInstalled_EmptyResult` | Integration |
| 19 | `testE15_ConcurrentScans_SecondErrors` | Integration |
| 20 | `testE16_AXErrorCode_WrappedInError` | Unit |
| 21 | `testE17_CacheWriteFailure_ScanStillSucceeds` | Integration |
| 22 | `testE18_LogicWindowMissing_Error` | Integration |
| 23 | `testE19_AXValueForceUnwrapReplacedWithGuard` | Unit |
| 24 | `testE20_EmptyPathSegment_Error` | Unit |
| 25 | `testE21_TrackIndexDriftAfterDeletion_Documented` | Integration |
| 26 | `testE22_MultipleLibraryPanels_FirstUsed` | Integration |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/LibraryAccessorEdgeCaseTests.swift` (NEW, 26 tests)

### 3.3 Mock/Setup Required
- Programmable mocks capable of each scenario

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Tests/LogicProMCPTests/LibraryAccessorEdgeCaseTests.swift` | Create | 26 tests |

### 4.2 Implementation Steps
1. Write 26 targeted tests.
2. Each test asserts the behaviour documented in PRD §5 row.
3. Tests pass.

### 4.3 Refactor Phase
- None.

## 5. Edge Cases
This ticket IS the edge-case coverage.

## 6. Review Checklist
- [ ] 26 tests Red → Green
- [ ] Each test name contains `testE{N}_`
- [ ] All PRD §5 rows have coverage
