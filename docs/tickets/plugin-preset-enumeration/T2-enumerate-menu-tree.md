# T2: enumerateMenuTree Recursive Walker

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-1 AC-1.1, AC-1.2, §4.1, §5 E6-E9b
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: T1

---

## 1. Objective
Implement `PluginInspector.enumerateMenuTree(probe:maxDepth:)` — async recursive walker over the Setting-menu tree. Handles: depth cap (truncated), cycle detection (visited-hash), submenu probe timeout (probeTimeout), mutation guard (E6/E6b), separator/action preservation. Output: `PluginPresetNode` tree.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-1.1/AC-1.2): Given a probe returning a 3-level tree `{A → {A1, A2}, B → {B1}, C → {}}`, enumerateMenuTree returns an identically-shaped `PluginPresetNode` tree.
- [ ] **AC-2** (AC-4.1-equiv): Given `maxDepth: 2` on a 5-level tree, depth 3+ branches return `kind: truncated, children: []`.
- [ ] **AC-3** (AC-4.2-equiv): Given two sibling items named `"Pad"`, both survive with paths `Pad[0]` and `Pad[1]`.
- [ ] **AC-4** (AC-4.3-equiv): Whitespace-only names are skipped; internal counter incremented.
- [ ] **AC-5** (AC-4.4-equiv + E8): Given probe returns nil (timeout) for a submenu, that node emits `kind: probeTimeout`; scan continues with siblings.
- [ ] **AC-6** (E9b): Given probe returns same visitedHash twice at different paths, second emits `kind: cycle`; `cycleCount++`.
- [ ] **AC-7**: Separators (probe returns `kind: separator`) preserved with `children: []`.
- [ ] **AC-8**: Actions (probe returns `kind: action`, e.g. `"Save As Default…"`) preserved with `children: []`.
- [ ] **AC-9** (E6): Between every submenu-open attempt, `mutationSinceLastCheck` is called; `true` → scan aborts with `PluginError.menuMutated`.
- [ ] **AC-10**: Between every submenu-open, `focusOK` is called; `false` → abort with `PluginError.focusLost`.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases (Tests/LogicProMCPTests/PluginInspectorEnumerateTreeTests.swift)

| # | Test Name | Type | Description |
|---|-----------|------|-------------|
| 1 | `testHappyPath3LevelTree` | Unit | 3-submenu × 3-leaf probe; assert 9 leaf nodes at correct paths |
| 2 | `testDeepTreeMaxDepthEnforcement` | Unit | 5-level chain with `maxDepth: 2` → depth 2 emits truncated |
| 3 | `testDuplicateSiblingsDisambiguated` | Unit | Probe returns `["Pad", "Pad"]` → paths `Pad[0]`, `Pad[1]` |
| 4 | `testEmptySubmenu` | Unit | Folder with `children: []` returned |
| 5 | `testWhitespaceNameSkipped` | Unit | Probe returns `["  ", "Real"]` → only `Real` emitted |
| 6 | `testSubmenuProbeTimeout` | Unit | Probe returns nil → node kind probeTimeout; sibling still processed |
| 7 | `testCycleDetected` | Unit | Probe returns same visitedHash twice → second emits cycle |
| 8 | `testSeparatorPreserved` | Unit | Item kind separator → retained with children:[] |
| 9 | `testActionPreserved` | Unit | Item kind action → retained |
| 10 | `testMutationMidScanAborts` | Unit | `mutationSinceLastCheck` returns true on 3rd call → throws menuMutated |
| 11 | `testFocusLossAborts` | Unit | `focusOK` returns false → throws focusLost |

### 3.2 Test File Location
`Tests/LogicProMCPTests/PluginInspectorEnumerateTreeTests.swift` — new file.

### 3.3 Mock/Setup
- Inject `PluginPresetProbe` with scripted closures for each scenario.
- No live AX calls — all probe-mocked.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Modify | Add `enumerateMenuTree` + recursive helper + `PluginError` enum + `maxPluginMenuDepth: Int = 10` constant |
| `Tests/LogicProMCPTests/PluginInspectorEnumerateTreeTests.swift` | Create | 11 tests |

### 4.2 Implementation Steps (Green)
1. Define `enum PluginError: Error, Equatable { case menuMutated, focusLost, probeTimeout(path: [String]) }`
2. Recursive inner function `walk(pathSegs: [String], depth: Int, visited: inout Set<Int>) async throws -> PluginPresetNode`
3. Depth check first; at cap, return `truncated` node
4. Call `probe.mutationSinceLastCheck()` → if true throw
5. Call `probe.focusOK()` → if false throw
6. Call `probe.menuItemsAt(pathSegs)` → nil → probeTimeout node
7. Compute `probe.visitedHash(pathSegs)`; if in `visited` set → cycle node + cycleCount++
8. Insert visitedHash into set
9. For each item: skip whitespace names; if `hasSubmenu`, recurse with `probe.sleep(settleMs)` before; else emit leaf/separator/action
10. Handle sibling name-duplication by appending `[i]` on matching names
11. Return `PluginPresetNode(name, path, kind, children)`

### 4.3 Refactor
- Extract path-build helper: `buildPath(segs: [String], lastName: String, dupIndex: Int?) -> String`
- Factor the dedup-with-index logic into a small helper

## 5. Edge Cases
- EC-1 (E6b): Scanner's own AXPress inside the probe triggers mutation — guard via settle window (probe responsibility; T3/T5 wire it). T2 just respects `mutationSinceLastCheck` signal.
- EC-2: Depth exactly equal to `maxDepth` → allowed; `maxDepth + 1` → truncated.

## 6. Review Checklist
- [ ] Red: 11 tests FAIL
- [ ] Green: 11 tests PASS
- [ ] Refactor: tests PASS
- [ ] `swift build` green
- [ ] Cycle count accumulates correctly across multiple cycles
