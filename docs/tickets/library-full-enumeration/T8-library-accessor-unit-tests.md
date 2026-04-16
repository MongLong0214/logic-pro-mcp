# T8: LibraryAccessor Comprehensive Unit Tests

**PRD Ref**: PRD-library-full-enumeration > §8.1, AC-5.1
**Priority**: P0
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: T1-T3 (types, enumerateTree, resolvePath) — tests written alongside but this is the "polish to ≥ 90% coverage" ticket

---

## 1. Objective
Drive `LibraryAccessor.swift` to ≥ 90 % line coverage and ≥ 85 % branch coverage via Swift Testing unit tests. Tests from T1-T3 are included, this ticket adds the remaining coverage for helpers (`position(of:)`, `findLibraryBrowser`, `productionMouseClick`, `detectSelectedText`, `currentPresets`) and edge cases.

## 2. Acceptance Criteria
- [ ] AC-5.1: `LibraryAccessor.swift` ≥ 90 % line, ≥ 85 % branch coverage (`llvm-cov report`)
- [ ] AC-5.2: ≥ 40 tests total for this feature across all test files
- [ ] AC-5.3: Total project tests ≥ 540

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases (new, not in T1-T3)

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testCurrentPresets_2ColumnSnapshot_ReturnsColumn2` | Unit | Mock: column 1 + column 2 | Returns column 2 items |
| 2 | `testCurrentPresets_1ColumnOnly_ReturnsEmpty` | Unit | Mock single column | Empty array |
| 3 | `testCurrentPresets_3Columns_ReturnsDeepest` | Unit | Mock 3-column snapshot | Returns column 3 |
| 4 | `testPositionOf_HappyPath_ComputesCenter` | Unit | Mock element with pos(10,20) size(4,6) | Returns (12, 23) |
| 5 | `testPositionOf_MissingAttribute_ReturnsNil` | Unit | Mock without kAXPositionAttribute | Returns nil |
| 6 | `testPositionOf_AsQuestionGuard_NoCrash` | Unit | Mock returns non-AXValue object | Returns nil gracefully |
| 7 | `testFindLibraryBrowser_KoreanDescription` | Unit | Mock browser described "라이브러리" | Found |
| 8 | `testFindLibraryBrowser_EnglishDescription` | Unit | Mock described "Library" | Found |
| 9 | `testFindLibraryBrowser_NoBrowsers_ReturnsNil` | Unit | Zero AXBrowser in window | nil |
| 10 | `testFindLibraryBrowser_Fallback_FirstBrowser` | Unit | Multiple browsers, none matching names | Returns first |
| 11 | `testProductionMouseClick_EventSourceSuccess_PostsBoth` | Unit | Inject `postMouseClick` recorder | Down + Up posted, returns true |
| 12 | `testProductionMouseClick_EventSourceNil_ReturnsFalse` | Unit | Stub source = nil | Returns false |
| 13 | `testDetectSelectedText_ReturnsNil_Always` | Unit | Confirms current AX limitation | nil regardless of input |
| 14 | `testEnumerate_LegacyShallow_NoClicks` | Unit | Call enumerate() with click-recorder runtime | Zero clicks posted |
| 15 | `testEnumerateAll_Legacy_OnlyTopLevel` | Unit | Call enumerateAll() with depth-2 mock | Only depth-1 presets enumerated |
| 16 | `testInventoryFlatten_Depth3Tree_AllLeaves` | Unit | Build LibraryNode, invoke flatten | presetsByCategory contains all leaves from all depths |
| 17 | `testInventoryFlatten_FolderExcluded` | Unit | Same as 16 | Folder names NOT in arrays |
| 18 | `testVisitedSet_Capacity10k_NoPanic` | Unit | Insert 10 000 hashes | Completes, no assertion |
| 19 | `testEnumerateTree_Perf_100Folders_UnderBudget` | Perf | Mock 100-folder × 30-leaf tree, `settleDelayMs=0` (virtual), `leafReadMs=0`, measure wall time of pure traversal overhead | < 2 s on M-series — regression guard for O(N²) sneak-ins. Live p95 AC-1.5 (15 s/300 s with real settle) verified manually via `Scripts/live-e2e-test.sh`. |
| 20 | `testEnumerateTree_Perf_ScalesLinearly_NotQuadratic` | Perf | Measure 50-folder vs 100-folder vs 200-folder; assert ratio ≤ 2.5× between doubling | Linear scaling proof |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/LibraryAccessorHelpersTests.swift` (NEW, 20 tests)
- Coverage added across T1/T2/T3 test files counts toward G4

### 3.3 Mock/Setup Required
- Extend `AXHelpers.Runtime` mock with programmable attribute returns
- `LibraryAccessor.Runtime` click recorder

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Tests/LogicProMCPTests/LibraryAccessorHelpersTests.swift` | Create | 20 tests |
| `Sources/LogicProMCP/Accessibility/LibraryAccessor.swift` | Modify (minimal) | Expose `flatten(_ root)` as internal if needed for test |

### 4.2 Implementation Steps
1. Write 20 tests per §3.1.
2. Run `swift test --enable-code-coverage`.
3. `xcrun llvm-cov report .build/debug/LogicProMCPPackageTests.xctest/... -instr-profile .build/debug/codecov/default.profdata` to verify coverage ≥ 90 %.
4. Add more tests if under target.

### 4.3 Refactor Phase
- None (test code only).

## 5. Edge Cases
Covered in tests #6, #12 (defensive), #13 (known limitation).

## 6. Review Checklist
- [ ] 20 tests Red → Green
- [ ] Coverage report ≥ 90 % / 85 %
- [ ] Total tests ≥ 540
