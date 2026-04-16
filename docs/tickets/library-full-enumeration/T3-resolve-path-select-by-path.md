# T3: resolvePath() + selectByPath()

**PRD Ref**: PRD-library-full-enumeration > US-2
**Priority**: P0
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T2 (enumerateTree for deep lookup), T1 (types)

---

## 1. Objective
Implement path-expression resolution (`"A/B/C"` → live click sequence) for addressing arbitrary nested presets. Re-queries live AX coordinates at click time (no stale cache).

## 2. Acceptance Criteria
- [ ] AC-2.1, AC-2.2, AC-2.4 (PRD US-2)
- [ ] AC-2.6 `resolve_path` read-only API returns `{ exists, kind, matchedPath, children }`
- [ ] AC-2.7 trailing slash tolerated
- [ ] AC-2.8 folder-typed path in `set_instrument` → error
- [ ] Disambiguator `[i]` suffix supported (duplicate siblings)
- [ ] Escape `\/` for literal slash in preset name

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testResolvePath_Depth1Leaf` | Unit | `"Bass/Sub Bass"` on mock 2-level tree | Returns (kind:leaf, matchedPath:"Bass/Sub Bass") |
| 2 | `testResolvePath_Depth3Leaf` | Unit | `"Orch/Str/Warm"` | Returns leaf |
| 3 | `testResolvePath_MissingLeaf_ReturnsNotExists` | Unit | `"Bass/Nope"` | `exists:false` |
| 4 | `testResolvePath_EscapedSlash` | Unit | `"Bass\\/Sub"` targets literal child `"Bass/Sub"` | Correct leaf |
| 5 | `testResolvePath_DisambiguatedDuplicate` | Unit | `"Synth/Pad[1]"` | Second sibling |
| 6 | `testResolvePath_TrailingSlash` | Unit | `"Bass/"` | Treated as folder lookup |
| 7 | `testResolvePath_FolderPath_KindFolder` | Unit | `"Orchestral"` on tree | `kind:folder, children populated` |
| 8 | `testResolvePath_EmptyPath_ReturnsNotExists` | Unit | `""` | `exists:false` |
| 9 | `testResolvePath_EmptySegment_Error` | Unit | `"A//C"` | throws or returns `exists:false` |
| 10 | `testSelectByPath_ClickSequence_InOrder` | Unit | `"A/B/C"` → mock records clicks | 3 clicks in order with settle between |
| 11 | `testSelectByPath_AbortOnMissingIntermediate` | Unit | `"A/MissingB/C"` | Returns false, no click emitted past A |
| 12 | `testSelectByPath_LegacyCategoryPresetStillWorks` | Unit | `selectByPath("Cat/Preset")` twin of setInstrument(category:preset:) | Same click sequence |
| 13 | `testSelectByPath_SettleDelayBetweenClicks` | Unit | Mock records inter-click delay | ≥ settleDelayMs between clicks |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/LibraryAccessorResolvePathTests.swift` (NEW)

### 3.3 Mock/Setup Required
- `LibraryAccessor.Runtime` with click-recorder
- Mock AX tree fixture builder

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Accessibility/LibraryAccessor.swift` | Modify | Add `resolvePath`, `selectByPath`, `parsePath` helpers |
| `Tests/LogicProMCPTests/LibraryAccessorResolvePathTests.swift` | Create | 13 tests per §3.1 |

### 4.2 Implementation Steps
1. `parsePath(_ s: String) -> [String]?` — split by `/`, honour `\/` escape, reject empty segments.
2. `resolvePath(_ path: String, runtime) -> PathResolution?` — **live-AX walk**: find category, then if intermediate segments, click each and wait settle, then look up next segment. Returns (kind, matchedPath, children, terminalElement).
3. `selectByPath(_ path: String, runtime, library) async -> Bool` — uses resolvePath then performs actual clicks.
4. Ensure **read-only** mode for `resolve_path` MCP (no click injected) — separate code path.
5. Tests pass.

### 4.3 Refactor Phase
- Split `resolvePath` (read-only) from `selectByPath` (click-injecting) cleanly.

## 5. Edge Cases
- EC-1: Unicode / RTL in path segment — pass through unchanged.
- EC-2: Path with only one segment, resolves to a top-level category.
- EC-3: Very long path (10+ segments) — maxDepth check; error after 12.

## 6. Review Checklist
- [ ] 13 tests Red → Green
- [ ] `resolvePath` never injects a click
- [ ] `selectByPath` injects clicks with proper settle
- [ ] Duplicate-sibling paths work via `[i]`
- [ ] Escape character handled
