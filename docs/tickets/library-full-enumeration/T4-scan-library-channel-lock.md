# T4: AccessibilityChannel scanLibraryAll + Concurrent Lock + Tier-A Restoration

**PRD Ref**: PRD-library-full-enumeration > US-1 (AC-1.4, AC-1.7 Tier A, AC-1.8), §5 E15
**Priority**: P0
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: T2 (enumerateTree), T3 (path helpers)

---

## 1. Objective
Rewrite `AccessibilityChannel.scanLibraryAll` to use `enumerateTree` (deep) with actor-state concurrent-scan lock, Tier-A selection cache, and `Task.sleep` throughout. `execute` branch is `async`. **Also owns**: persisting `LibraryRoot` to `Resources/library-inventory.json` (AC-1.6), tolerating cache-write failures (E17), and caching the most recent `LibraryRoot` in actor state for downstream T7 `resolve_path` cache-backed lookup.

## 2. Acceptance Criteria
- [ ] AC-1.1, AC-1.4, AC-1.6, AC-1.7 (Tier A), AC-1.8
- [ ] E15: Second concurrent `library.scan_all` returns `"Library scan already in progress"`; first succeeds
- [ ] E17: If `Resources/library-inventory.json` write fails (read-only FS, disk full), scan **response is still returned to caller** (log WARN, omit `cachePath` from response); scan does NOT error out
- [ ] AccessibilityChannel gains actor state: `scanInProgress: Bool`, `lastRoutedCategory/Preset: String?`, `lastScan: LibraryRoot?` (the in-memory cache consumed by T7)
- [ ] `selectionRestored: true` iff `lastRoutedCategory` + `lastRoutedPreset` non-nil at scan start
- [ ] `defer` clears `scanInProgress`

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testScanLibraryAll_HappyPath_JSON` | Integration | Mock tree, scan, decode LibraryRoot | All 13 fields present |
| 2 | `testScanLibraryAll_PanelClosed_Error` | Integration | Mock: findLibraryBrowser→nil | isError:true, "Library panel not found" |
| 3 | `testScanLibraryAll_ConcurrentScan_SecondErrors` | Integration | Fire two routes in parallel via actor | Exactly one succeeds, other errors "already in progress" |
| 4 | `testScanLibraryAll_TierA_CacheHit_RestoresSelection` | Integration | Pre-populate lastRoutedCategory/Preset; scan; assert restore click | selectionRestored:true, final selectCategory+selectPreset recorded |
| 5 | `testScanLibraryAll_TierA_CacheMiss_FalseFlag` | Integration | No prior selectCategory call | selectionRestored:false |
| 6 | `testScanLibraryAll_DeferClearsFlag` | Integration | Force error mid-scan; second scan succeeds | Second scan not blocked |
| 7 | `testScanLibraryAll_UsesTaskSleep_NoThreadBlock` | Integration | Parallel unrelated AX route during scan | Other route can progress (not fully blocked) |
| 8 | `testScanLibraryAll_RespondsIncludesStructuralFields` | Integration | JSON has nodeCount/leafCount/folderCount/scanDurationMs | All present, positive |
| 9 | `testScanLibraryAll_AC1_6_JSONWrittenToResources` | Integration | Mock filesystem write success | File written, response includes `cachePath` |
| 10 | `testScanLibraryAll_E17_WriteFailure_Tolerated` | Integration | Mock filesystem write throws | Scan response still returned, no error, `cachePath` omitted |
| 11 | `testScanLibraryAll_LastScanCachedInActor` | Integration | Scan succeeds, later `resolve_path` query | `lastScan` actor state non-nil |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AccessibilityChannelScanLibraryTests.swift` (NEW)

### 3.3 Mock/Setup Required
- Injectable `LibraryAccessor.Runtime` stub
- Injectable `AXLogicProElements.Runtime` returning mock browser
- Channel tests already use `ChannelResult` assertions (reuse pattern)

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Convert `scanLibraryAll` to actor method (remove `static`), add state, swap to `enumerateTree`, add Tier-A cache |
| `Tests/LogicProMCPTests/AccessibilityChannelScanLibraryTests.swift` | Create | 11 tests per §3.1 |

### 4.2 Implementation Steps
1. Add actor state: `private var scanInProgress: Bool = false`, `private var lastRoutedCategory: String?`, `private var lastRoutedPreset: String?`, `private var lastScan: LibraryRoot? = nil`.
2. In `execute` `case "library.scan_all"`: check-and-set flag BEFORE any `await` (atomic within actor step), then call scan helper in `defer { scanInProgress = false }` scope.
3. Scan helper: snapshot cached last-routed selection → call `LibraryAccessor.enumerateTree(...)` → on finish, if snapshot non-nil, re-call `selectCategory`+`selectPreset`; set `selectionRestored`.
4. Update selectCategory/setTrackInstrument paths to update `lastRoutedCategory`/`lastRoutedPreset` actor state so Tier-A cache is populated by prior calls.
5. **JSON persistence (AC-1.6)**: encode `LibraryRoot` via `JSONEncoder().outputFormatting = [.prettyPrinted, .sortedKeys]`, write to `Resources/library-inventory.json`. Include path in response `cachePath` field on success.
6. **Write-failure tolerance (E17)**: wrap the write in `do/catch`; on failure log at WARN with `subsystem:"library"`, omit `cachePath` from response, do NOT return `.error`.
7. **In-memory cache**: set `self.lastScan = result` AFTER successful scan (before returning). This is the cache consumed by T7's `resolve_path`. On abort (E5/E5c) do NOT update `lastScan`.
8. Tests pass.

### 4.3 Refactor Phase
- Consider extracting `TierACache` struct if it grows.

## 5. Edge Cases
- EC-1: Scan throws mid-run → `defer` ensures flag cleared.
- EC-2: `enumerateTree` returns nil → error returned, flag cleared.
- EC-3: First-ever call (no cached selection) → `selectionRestored:false`, not an error.

## 6. Review Checklist
- [ ] 11 tests Red → Green
- [ ] `scanInProgress` is actor-isolated, `defer`-cleared
- [ ] Tier-A cache populated by selectCategory / setTrackInstrument
- [ ] No `Thread.sleep` on this path
- [ ] JSON response conforms to `LibraryRoot`
