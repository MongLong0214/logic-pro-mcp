# T1: LibraryNode / LibraryRoot Data Types + JSON Codable

**PRD Ref**: PRD-library-full-enumeration > §4.2
**Priority**: P0
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: None (T0 result informs design but doesn't block type creation)

---

## 1. Objective
Introduce the new `LibraryNodeKind`, `LibraryNode`, and `LibraryRoot` types in `LibraryAccessor.swift`. Round-trip through `JSONEncoder`/`JSONDecoder`. **No persisted screen-coordinate data.**

## 2. Acceptance Criteria
- [ ] AC-1.1: `LibraryNodeKind` enum has cases `folder`, `leaf`, `truncated`, `probeTimeout`, `cycle`.
- [ ] AC-1.2: `LibraryNode` has fields `name`, `path`, `kind`, `children`. **No `position` field.**
- [ ] AC-1.3: `LibraryRoot` has fields `generatedAt`, `scanDurationMs`, `measuredSettleDelayMs`, `selectionRestored`, `truncatedBranches`, `probeTimeouts`, `cycleCount`, `nodeCount`, `leafCount`, `folderCount`, `root`, `categories`, `presetsByCategory`.
- [ ] AC-1.4: Both types are `Codable`, `Sendable`, `Equatable`.
- [ ] AC-1.5: JSON round-trip produces equal structure.
- [ ] AC-1.6: A 5-level test tree encodes to valid UTF-8 JSON and decodes back.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testLibraryNodeKindRawValues` | Unit | All 5 kinds have correct rawValue | Enum members stable |
| 2 | `testLibraryNodeLeafEncodesCorrectly` | Unit | Encode a leaf → JSON has name/path/kind/children | Fields present |
| 3 | `testLibraryNodeFolderWithChildren` | Unit | Folder with 3 leaf children encodes | Encodes recursively |
| 4 | `testLibraryNodeNoPositionField` | Unit | JSON output contains no "position" key at any depth | assertFalse contains "position" |
| 5 | `testLibraryRoot_AllFields` | Unit | Build a root, encode, assert all 13 fields present | Fields present |
| 6 | `testLibraryRoot_JSONRoundTrip5Levels` | Unit | 5-level nested tree → encode → decode → equal | Equatable passes |
| 7 | `testLibraryRoot_DecodesFromMinimalJSON` | Unit | Hand-written minimal JSON → decode succeeds | No throw |
| 8 | `testLibraryRoot_DecodeRejectsMalformed` | Unit | Missing required field → throws | Throws DecodingError |
| 9 | `testLibraryRoot_CycleCountSerializesCorrectly` | Unit | Build root with `cycleCount: 3` → encode → decode | Round-trip equal, JSON key present |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/LibraryAccessorTypesTests.swift` (NEW)

### 3.3 Mock/Setup Required
- `swift-testing` framework (already in Package.swift)
- No AX mocking needed (pure types test)

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Accessibility/LibraryAccessor.swift` | Modify | Add enum + two structs near top of file, alongside existing `Inventory` |
| `Tests/LogicProMCPTests/LibraryAccessorTypesTests.swift` | Create | 8 tests per §3.1 |

### 4.2 Implementation Steps (Green Phase)
1. Add `LibraryNodeKind` enum (5 cases, String-backed).
2. Add `LibraryNode` struct (4 fields, no position).
3. Add `LibraryRoot` struct (13 fields).
4. Make all three Codable/Sendable/Equatable (compiler-synthesized).
5. Run tests → PASS.

### 4.3 Refactor Phase
- Consolidate common field docstrings if needed.

## 5. Edge Cases
- EC-1: Empty categories array → `LibraryRoot` still encodes/decodes.
- EC-2: Children array with one element → still arrays, not flattened.

## 6. Review Checklist
- [ ] Red: 8 tests FAILED before implementation
- [ ] Green: 8 tests PASS
- [ ] No `position` field in `LibraryNode`
- [ ] All types Sendable + Codable + Equatable
- [ ] Existing `Inventory` type untouched
