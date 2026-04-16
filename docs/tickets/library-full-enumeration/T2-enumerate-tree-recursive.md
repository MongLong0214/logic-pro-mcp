# T2: enumerateTree() Recursive Walker

**PRD Ref**: PRD-library-full-enumeration > §4.1, US-1, US-4
**Priority**: P0
**Size**: L (4-8h)
**Status**: Todo
**Depends On**: T1 (types), T0 (design decision — if GO-PASSIVE, T2 is re-scoped)

---

## 1. Objective
Implement `LibraryAccessor.enumerateTree(maxDepth:settleDelayMs:runtime:library:)` — the deep recursive walker that clicks through every folder node and produces a full `LibraryRoot`. Includes maxDepth, visited-set cycle detection, `probeTimeout` handling, `truncated` markers. Uses **`Task.sleep`** (async).

## 2. Acceptance Criteria
- [ ] AC-1.1, AC-1.2, AC-1.3, AC-1.5 (PRD US-1)
- [ ] AC-1.4 exact error text: `"Library panel not found. Open Library (⌘L) in Logic Pro."` when `findLibraryBrowser` returns nil — **owned by this ticket**
- [ ] AC-4.1 maxDepth backstop produces `truncated` markers
- [ ] AC-4.2 duplicate siblings disambiguated with `[i]` suffix
- [ ] AC-4.3 whitespace-only names skipped
- [ ] AC-4.4 probeTimeout after 800 ms (4 polls × 200 ms)
- [ ] AC-1.8 uses `Task.sleep`, not `Thread.sleep`
- [ ] E8b visited-set cycle detection via `Set<AXUIElementHash>`
- [ ] §4.1 flatten policy: `presetsByCategory` gets all leaf descendants depth-first
- [ ] **E5b** `scannerClickInFlight` guard — spans `postMouseClick` → `currentPresets` read (i.e. `settleDelayMs + 50 ms` dynamic window); scanner's own clicks do NOT trigger mutation-abort
- [ ] **E5c** focus-loss abort — before every click, check `kAXFocusedApplicationAttribute`; if focus left Logic Pro, return error `"Library scan aborted: Logic Pro lost focus"`
- [ ] **E5** external AX-mutation abort — between scanner clicks (outside the guard window), if a new AXUIElement appears or an existing one disappears that was not caused by the scanner's click, abort with `"Library tree changed during scan"`

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testEnumerateTree_HappyPath_2Level` | Unit | Mock runtime: 3 categories × 2 leaves | 6 leaf nodes at depth 2 |
| 2 | `testEnumerateTree_Deep6Level` | Unit | Mock single-branch chain depth 6 | Tree depth 6, no truncation |
| 3 | `testEnumerateTree_MaxDepthTruncation` | Unit | Mock depth-5 tree, maxDepth=2 | Depth-2 branches have kind:truncated |
| 4 | `testEnumerateTree_DuplicateSiblings` | Unit | Two children named "Pad" | Paths "…/Pad[0]", "…/Pad[1]" |
| 5 | `testEnumerateTree_EmptyCategory` | Unit | Category with 0 children after click | `kind:folder, children:[]` |
| 6 | `testEnumerateTree_WhitespaceOnlyName_Skipped` | Unit | Mock one category with `"   "` name | Not included in output |
| 7 | `testEnumerateTree_ProbeTimeout` | Unit | Mock: click doesn't populate column | `kind:probeTimeout` marker |
| 8 | `testEnumerateTree_CycleSafety_VisitedSet` | Unit | Mock: click returns same element at new path | `kind:cycle` marker, no infinite loop |
| 9 | `testEnumerateTree_UsesTaskSleep` | Unit | Mock that records sleep type | Task.sleep calls recorded, no Thread.sleep |
| 10 | `testEnumerateTree_FlattenPolicy_Depth3Tree` | Unit | 3-level tree → flatten via LibraryRoot helper | All leaf descendants in presetsByCategory |
| 11 | `testEnumerateTree_PanelClosed_ReturnsNil` | Unit | findLibraryBrowser returns nil | enumerateTree returns nil |
| 12 | `testEnumerateTree_StableOrdering` | Unit | Same mock tree, two runs | Structurally identical (name+path+kind) |
| 13 | `testEnumerateTree_E5b_ScannerSelfClickGuard` | Unit | Mock that asserts mutation callback suppressed during `settleDelayMs+50ms` window after emit | Guard active; no abort |
| 14 | `testEnumerateTree_E5c_FocusLoss_Abort` | Unit | Mock kAXFocusedApplicationAttribute returns different app mid-scan | Returns error; scan halts |
| 15 | `testEnumerateTree_E5_ExternalMutation_Abort` | Unit | Inject mutation outside guard window | Returns error `"Library tree changed during scan"` |
| 16 | `testEnumerateTree_PanelClosed_ExactErrorText` | Unit | findLibraryBrowser nil | Returns `.error("Library panel not found. Open Library (⌘L) in Logic Pro.")` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/LibraryAccessorEnumerateTreeTests.swift` (NEW)

### 3.3 Mock/Setup Required
- Extend `AXLogicProElements.Runtime` and `LibraryAccessor.Runtime` with injectable click + read operations.
- Build mock runtime that returns pre-scripted tree on clicks (no live AX).

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Accessibility/LibraryAccessor.swift` | Modify | Add `enumerateTree(...) async -> LibraryRoot?` + private recursion helper |
| `Tests/LogicProMCPTests/LibraryAccessorEnumerateTreeTests.swift` | Create | 16 tests per §3.1 |

### 4.2 Implementation Steps (Green Phase)
1. Add `LibraryAccessor.Runtime` extension: `postMouseClick` already exists; no change.
2. Helper `axElementHash(_: AXUIElement) -> Int` using `CFHash`.
3. Recursive core: `private static func enumerateNode(element, path, currentDepth, maxDepth, visited: inout Set<Int>, ...)` → `LibraryNode`.
4. On folder node: click → `await Task.sleep(.milliseconds(settleDelayMs))` → read new column → recurse.
5. Top-level: `enumerateTree` walks the initial categories, calls `enumerateNode` for each, collects results into a synthetic root.
6. Build `LibraryRoot` with metadata counters.
7. Add `flatten(_ root: LibraryNode) -> [String: [String]]` helper per §4.1 policy.
8. Tests pass.

### 4.2.1 E5/E5b/E5c Guard/Mutation/Focus Mechanics (addresses boomer Round 2 P2-A)

**Goal**: Distinguish scanner-induced AX changes from external (user/app) changes; detect Logic Pro focus loss; emit clean abort errors on either.

Step-by-step implementation:

**(a) scannerClickInFlight dynamic guard window (E5b)**
- Add actor-free `private var inFlightClick: (start: Date, windowMs: Int)?` OR pass via `inout` into recursion.
- Before each click: `inFlightClick = (Date(), settleDelayMs + 50)`.
- After `currentPresets` read completes: `inFlightClick = nil`.
- Mutation observer checks `if let w = inFlightClick, Date().timeIntervalSince(w.start) * 1000 < Double(w.windowMs) { return /* ignore, is scanner's own */ }`.

**(b) External-mutation detection (E5)**
- At start of each recursion step, snapshot `axElementHash(currentColumn)` + child count.
- After `Task.sleep(settleDelayMs)`, re-read. If `inFlightClick == nil` AND (element set differs unexpectedly), return `.error("Library tree changed during scan")`.
- Partial tree is **not** emitted on abort — caller receives error, cache untouched.

**(c) Focus-loss detection (E5c)**
- Before every click: read `kAXFocusedApplicationAttribute` on system-wide AX element.
- If returned app PID ≠ Logic Pro PID captured at scan start, return `.error("Library scan aborted: Logic Pro lost focus")`.
- Do this cheaply — one AX call per iteration, not per element.

**(d) Cleanup semantics**
- Abort paths all return before writing JSON cache.
- `self.lastScan` in T4's AccessibilityChannel is NOT updated on abort.
- Tier-A selection restoration (AC-1.7) is STILL attempted in the abort path's `defer`, best-effort.

### 4.3 Refactor Phase
- Extract column-read logic into `readColumn(_ element) -> [LibraryNode]` if helpful.
- Ensure duplicate-sibling disambiguation uses a stable counter.

## 5. Edge Cases
- EC-1: Logic Pro window minimized → scanner should still work (AX is frame-less).
- EC-2: Library browser role localized ("Library" vs "라이브러리") — reuse `findLibraryBrowser` which already handles both.
- EC-3: maxDepth=0 → return empty root.

## 6. Review Checklist
- [ ] Red: 16 tests FAILED before implementation
- [ ] Green: 16 tests PASS
- [ ] No `Thread.sleep` inside enumerateTree or its helpers
- [ ] visited-set capped at 10 000 entries (sanity, §7 metric)
- [ ] Existing `enumerateAll` untouched
- [ ] No `position` persisted
