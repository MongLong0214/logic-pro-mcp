# T7: resolve_path MCP Command (Read-Only)

**PRD Ref**: PRD-library-full-enumeration > §4.3, AC-2.6
**Priority**: P1
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: T4 (owns `lastScan` cache) — changed from T3 per Phase 4 boomer P2 finding

---

## 1. Objective
Expose `resolve_path` via TrackDispatcher + ChannelRouter + AccessibilityChannel — a **cache-backed** read-only lookup against the most recent `scanLibraryAll` result. Returns `{ exists, kind, matchedPath, children? }`. **Injects zero AX clicks**. If no scan cache exists yet, returns `{ exists: false, reason: "No cached library scan; call scan_library first" }`.

## 2. Acceptance Criteria
- [ ] AC-2.6 (PRD US-2)
- [ ] New MCP command `logic_tracks resolve_path { path: String }`
- [ ] Routes via `library.resolve_path` operation → AccessibilityChannel
- [ ] **Never injects a click** (read-only assertion via mock-recorder test)
- [ ] Tool description updated in TrackDispatcher

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testResolvePathCommand_ExistingLeaf_FromCache` | Integration | Pre-populate `lastScan` with LibraryRoot; query `"Bass/Sub"` | `{ exists:true, kind:"leaf", matchedPath:"Bass/Sub" }` |
| 2 | `testResolvePathCommand_ExistingFolder_IncludesChildren` | Integration | `path: "Orchestral"` | `{ exists:true, kind:"folder", children:[...] }` |
| 3 | `testResolvePathCommand_MissingPath` | Integration | `path: "Foo/Bar"` | `{ exists:false, kind:null }` |
| 4 | `testResolvePathCommand_NoClicksInjected` | Integration | Mock recorder; run resolve_path | **Zero** postMouseClick calls |
| 5 | `testResolvePathCommand_EmptyPath_Error` | Integration | `path: ""` | isError or `{ exists:false }` |
| 6 | `testResolvePathCommand_MissingPathParam_Error` | Integration | no path provided | isError, "Missing path" |
| 7 | `testResolvePathCommand_NoCacheYet_ReturnsReason` | Integration | `lastScan` nil | `{ exists:false, reason:"No cached library scan; call scan_library first" }` |
| 8 | `testResolvePathCommand_DisambiguatedDuplicate_FromCache` | Integration | Cache with duplicate siblings; query `"Synth/Pad[1]"` | Correct leaf |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AccessibilityChannelResolvePathTests.swift` (NEW)

### 3.3 Mock/Setup Required
- Reuse mocks from T3
- MCP dispatcher unit tests pattern from existing DispatcherTests.swift

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Modify | Add `resolve_path` case + description |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Modify | Add `"library.resolve_path": [.accessibility]` |
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Add `library.resolve_path` case calling new `private static func resolveLibraryPath(...)` |
| `Tests/LogicProMCPTests/AccessibilityChannelResolvePathTests.swift` | Create | 8 tests |

### 4.2 Implementation Steps
1. Wire router entry `library.resolve_path → [.accessibility]`.
2. AccessibilityChannel new case: read `self.lastScan` (actor state). If nil → return `reason:"No cached…"` response. Else, walk the cached `LibraryRoot.root` tree by path segments — pure in-memory traversal, **never touches AX**.
3. Path parsing reuses `LibraryAccessor.parsePath` (from T3) — honours `\/` escape and `[i]` disambiguator.
4. Dispatcher: `case "resolve_path":` maps `params.path` to operation.
5. Tool description: add `resolve_path` to `tool.description`.
6. Tests pass.

### 4.3 Refactor Phase
- Shared JSON encoding helper for `PathResolution` → JSON if needed elsewhere.

## 5. Edge Cases
- EC-1: Library panel closed → resolve_path still works? No — AX is unavailable. Return `{ exists:false, reason:"Library panel not open" }` or error. Choose: **error**, consistent with scan.
- EC-2: Path with folder → include children.

## 6. Review Checklist
- [ ] 8 tests Red → Green
- [ ] Zero clicks in resolve_path path (proven by mock recorder)
- [ ] Tool description lists new command
