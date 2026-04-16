# T3: resolveMenuPath + selectMenuPath

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-3 AC-3.1/3.2/3.4, §4.2 MenuHop
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: T1, T2

---

## 1. Objective
Implement (a) `resolveMenuPath(_: String, in: PluginPresetNode) -> [MenuHop]?` (cache-only path → hop sequence) and (b) `selectMenuPath(_: [MenuHop], probe:)` (async hop-by-hop AXPress via probe). Path parse handles `\/` and `\\` escapes and `[i]` duplicate-disambiguator suffix.

## 2. Acceptance Criteria
- [ ] **AC-1**: `parsePath("A/B/C")` → `["A", "B", "C"]`
- [ ] **AC-2**: `parsePath("Bass\\/Sub/Synth")` → `["Bass/Sub", "Synth"]` (decode `\/` → `/`)
- [ ] **AC-3**: `parsePath("Path\\\\One/X")` → `["Path\\One", "X"]` (decode `\\` → `\`; 2-pass order: `\\` first then `\/`)
- [ ] **AC-4**: `parsePath("A//C")` → throws `PluginError.invalidPath("empty segment")` (E24)
- [ ] **AC-5**: `parsePath("Bass/")` — trailing slash stripped → `["Bass"]`
- [ ] **AC-6**: `resolveMenuPath("A/B", in: root)` — where root contains `A → B (leaf)` — returns `[MenuHop(0, "A"), MenuHop(0, "B")]`
- [ ] **AC-7**: `resolveMenuPath("A/Nope", in: root)` — missing → returns nil
- [ ] **AC-8**: `resolveMenuPath("Synth/Pad[1]", in: root)` — when Synth has two "Pad" siblings, picks index 1
- [ ] **AC-9**: `selectMenuPath(hops, probe:)` calls `probe.pressMenuItem([path])` for each hop in order, waiting `probe.sleep(settleMs)` between
- [ ] **AC-10**: `selectMenuPath` aborts on first `pressMenuItem` returning false; throws `PluginError.pressFailedAt(path: [String])`
- [ ] **AC-11**: `encodePath(["Bass/Sub", "Synth"])` → `"Bass\\/Sub/Synth"` (encode order: `\` → `\\` first, then `/` → `\/`)

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases (Tests/LogicProMCPTests/PluginInspectorPathTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `testParsePathSimple` | `"A/B/C"` → 3 segments |
| 2 | `testParsePathEscapedSlash` | `"Bass\\/Sub/Synth"` → `["Bass/Sub", "Synth"]` |
| 3 | `testParsePathEscapedBackslash` | `"Path\\\\One/X"` → `["Path\\One", "X"]` |
| 4 | `testParsePathEmptySegmentThrows` | `"A//C"` throws |
| 5 | `testParsePathTrailingSlashStripped` | `"Bass/"` → `["Bass"]` |
| 6 | `testResolveLeafDepth1` | `"A"` → `[hop(0, A)]` |
| 7 | `testResolveLeafDepth3` | `"A/B/C"` with nested tree → 3 hops |
| 8 | `testResolveMissingReturnsNil` | `"A/Nope"` → nil |
| 9 | `testResolveDuplicateDisambiguated` | `"Synth/Pad[1]"` picks 2nd Pad |
| 10 | `testResolveEmptyPath` | `""` → nil (empty path has no leaf) |
| 11 | `testEncodePathRoundTrip` | Encode `["Bass/Sub", "Synth"]` → decode same → equal |
| 12 | `testSelectCallsPressInOrder` | Spy probe records call order — assert `[A, A/B, A/B/C]` |
| 13 | `testSelectAbortsOnPressFailure` | Probe returns false on 2nd press → throws `pressFailedAt(["A", "B"])` |
| 14 | `testSelectSettleDelayApplied` | Spy sleep closure → 2 calls between 3 presses |

### 3.2 Test File Location
`Tests/LogicProMCPTests/PluginInspectorPathTests.swift`

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Modify | Add `parsePath`, `encodePath`, `resolveMenuPath`, `selectMenuPath`; extend `PluginError` with `invalidPath(reason:)` and `pressFailedAt(path: [String])` |
| `Tests/LogicProMCPTests/PluginInspectorPathTests.swift` | Create | 14 tests |

### 4.2 Implementation Steps
1. `parsePath(_:)` — 2-pass: replace `\\` with placeholder \u{0}, split on `/`, replace `\/` with `/`, restore placeholder → `\`. Validate no empty segments.
2. `encodePath(_:)` — reverse: escape `\` first, then `/`.
3. `resolveMenuPath(_: String, in: PluginPresetNode)` — parse path, walk tree matching names; for `Name[i]` suffix, parse index and select i-th sibling with that base name.
4. `selectMenuPath(_: [MenuHop], probe:)` — for each hop (cumulative path), `await probe.pressMenuItem(cumulativePath)`; on false throw; sleep between hops.

### 4.3 Refactor
- Keep path-build and dup-index helpers shared with T2

## 5. Edge Cases
- EC-1 (AC-2.7 library-analogue): trailing slash stripped before parse
- EC-2: `"[0]"` literal (not disambig) — corner case; treat as name if no matching multi-sibling base exists. Document + test.

## 6. Review Checklist
- [ ] Red: 14 tests FAIL
- [ ] Green: 14 tests PASS
- [ ] Refactor: PASS
- [ ] encode/decode are true inverses (test 11)
