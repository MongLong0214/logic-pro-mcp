# T6: scanPluginPresets Handler + Actor State + Cache Persistence

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-1 AC-1.1 thru AC-1.9, AC-2.10, §4.1 actor state, §5 E6/E11/E11b/E11c/E15/E27/E28
**Priority**: P0
**Size**: L
**Status**: Todo
**Depends On**: T2, T3, T4, T5

---

## 1. Objective
Implement `AccessibilityChannel.scanPluginPresets` handler. Adds actor state: rename `scanInProgress` → `axScanInProgress`, add `pluginPresetCache`, `lastPluginWindowState`, `openedByScanner`, `nextScannerWindowID`, **`trackPluginMapping: [Int: String]`** (populates on every successful identifyPlugin; consumed by T9 zero-AX path). Cache persistence: load from `Resources/plugin-inventory.json` on init with schemaVersion + decode-failure recovery. Extends `PluginWindowRuntime` with `readInventory: (URL) throws -> Data` + `writeInventory: (Data, URL) throws -> Void` closures (test-seam for AC-2.10). If T0 picks CGEvent, extends runtime with `productionMouseClickDelegate: (CGPoint) -> Bool` closure wrapping `LibraryAccessor.productionMouseClick`.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-1.4): No trackIndex + no focused plugin window → structured error; no crash.
- [ ] **AC-2** (AC-1.5/AC-1.5b): trackIndex provided → opens window if closed → scans → restores visibility; trackIndex wins over focused window.
- [ ] **AC-3** (AC-1.9): Shared `axScanInProgress` flag — second concurrent call errors `"<op>: AX scan already in progress"`; `resolve_preset_path` exempt.
- [ ] **AC-4** (AC-5.3): Post-open bundle ID mismatch → abort + close scanner-opened window.
- [ ] **AC-5** (AC-2.10): On init, loads `plugin-inventory.json` if present + `schemaVersion==1`. Version mismatch → skip + log. Decode failure → empty cache + ERROR log + no crash.
- [ ] **AC-6** (AC-1.7): On scan success, writes cache to `plugin-inventory.json` as `PluginPresetInventory` wrapper. Gitignored (validated via T14).
- [ ] **AC-7** (E15/E23): Cache write fails → response still returned; WARN log; cachePath omitted.
- [ ] **AC-8** (E11/E11b/E11c): TCC permission checks — Accessibility hard-required; Post-Event soft (only required if T0 chose CGEvent); Automation prompt surfaces natively on first AXPress with error translation on deny.
- [ ] **AC-9** (E27/E28): Mid-scan window-close or fullscreen → abort with clear error; defer clears flag.
- [ ] **AC-10**: Renames existing `scanInProgress` actor property (single-use symbol, not line-pinned) to `axScanInProgress`; updates `library.scan_all` handler to use renamed field (no behavior change). Existing library-scan "scan already in progress" error text UNCHANGED (AC-1.9 wording applies only to new plugin ops + new shared contract — library text backward-compat).
- [ ] **AC-11** (AC-1.3 determinism): Back-to-back `scanPluginPresets` with no intervening user action produce JSON responses structurally identical on axes `{name, path, kind, sibling order, disambiguator suffixes}`; volatile fields (`scanDurationMs, generatedAt, measuredSubmenuOpenDelayMs`) excluded.
- [ ] **AC-12** (cache write atomicity): Scan completion upserts the newly-scanned `PluginPresetCache` into in-memory `pluginPresetCache[pluginIdentifier]`, then serializes the **full in-memory dict** as `PluginPresetInventory { schemaVersion: 1, generatedAt: <ISO>, plugins: pluginPresetCache }` and writes atomically. A single-plugin scan MUST NOT truncate entries for other cached plugins.
- [ ] **AC-13** (trackPluginMapping): On every successful scan, `trackPluginMapping[trackIndex] = liveBundleID` is updated. Consumed by T9 `resolvePluginPresetPath` zero-AX path.

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/AccessibilityChannelScanPluginPresetsTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `testScanNoTrackIndexNoFocusedWindow` | No window, no arg → error |
| 2 | `testScanTrackIndexOpensClosedWindow` | Window closed → open → scan → close |
| 3 | `testScanTrackIndexLeavesOpenIfOpenBefore` | Window pre-open → scan → still open (AC-5.2) |
| 4 | `testScanTrackIndexWinsOverFocused` | Different window focused → trackIndex wins |
| 5 | `testScanConcurrentCallErrorsViaFlag` | First call in flight → second errors |
| 6 | `testScanConcurrentWithLibraryScanErrorsViaSharedFlag` | library.scan_all running → plugin.scan_presets errors |
| 7 | `testScanBundleIDMismatchAbort` | Post-open identity differs → abort + close scanner-opened window |
| 8 | `testScanCacheLoadOnInitValidJSON` | Init with valid inventory file → in-memory cache populated |
| 9 | `testScanCacheLoadVersionMismatchSkipped` | Inventory has schemaVersion:99 → cache empty, WARN log |
| 10 | `testScanCacheLoadCorruptJSONRecovery` | Malformed JSON → empty cache, ERROR log, no crash |
| 11 | `testScanCacheWriteSuccessPostScan` | After scan → file written |
| 12 | `testScanCacheWriteFailureToleratedWarnLog` | Disk full mock → response still returned, cachePath omitted |
| 13 | `testScanAccessibilityPermissionMissingError` | AXIsProcessTrusted=false → early error |
| 14 | `testScanMidScanWindowCloseAborts` | Probe signals focus loss mid-scan → abort + flag cleared |
| 15 | `testScanMidScanFullscreenChangeAborts` | Mutation detector fires → abort |
| 16 | `testScanDeferClearsFlagOnError` | Error path → axScanInProgress reset |
| 17 | `testLibraryScanStillWorksAfterRename` | library.scan_all unchanged post-rename |
| 18 | `testBackToBackScansStructurallyIdentical` | Inject same probe state; call twice; decode; strip volatile; assertEqual on axes per AC-1.3 |
| 19 | `testCacheWriteUpsertsNotTruncates` | Pre-existing cache with 2 plugins; scan 3rd plugin; assert file contains 3 entries (AC-12) |
| 20 | `testTrackPluginMappingPopulated` | After scan, `trackPluginMapping[trackIndex]` equals live bundleID (AC-13) |

### 3.2 Setup
- Inject fake `PluginInspector.Runtime` + `PluginWindowRuntime`.
- Inject fake file I/O closure for cache read/write testing.
- Use Swift Testing.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Rename `scanInProgress` → `axScanInProgress`; add new actor state; new case `plugin.scan_presets`; cache-load init path |
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Modify | Expose `scanLive(runtime:probeFactory:settleMs:)` top-level entry that wraps `enumerateMenuTree` |
| `Tests/LogicProMCPTests/AccessibilityChannelScanPluginPresetsTests.swift` | Create | 17 tests |

### 4.2 Implementation Steps
1. Rename `scanInProgress` → `axScanInProgress` across file; update library scan test if any
2. Add actor state fields per §4.1
3. Add `init` override that attempts to read + decode `plugin-inventory.json`; on failure log + empty cache
4. Implement `case "plugin.scan_presets"`:
   - Atomic flag check-and-set
   - Defer clear
   - Resolve window per AC-1.4/1.5/1.5b
   - Call `findSettingDropdown` + open menu via `probe.pressMenuItem([])`
   - Build `PluginPresetProbe` with live closures that wrap AX reads + AXPress (or CGEvent fallback per T0)
   - Call `PluginInspector.scanLive(...)` → `PluginPresetNode`
   - Wrap in `PluginPresetCache` (compute contentHash via xxhash64 helper)
   - Persist to cache + file (errors tolerated)
   - Encode response
5. ACaddress E11c: Wrap AXPress calls; map `.apiDisabled` error to user-friendly Automation-permission text

### 4.3 Refactor
- Extract `writeInventoryFile(_:)` helper
- Extract `computeContentHash(_: PluginPresetNode) -> String` helper (xxhash64 of serialized `{name}\0{kind}\0{path}\n` tree)

## 5. Edge Cases
- EC-1 (E11b): If T0 picks CGEvent fallback, check `CGPreflightPostEventAccess()` before first scan; error early
- EC-2: Concurrent `plugin.resolve_preset_path` during scan → proceeds (cache-only, exempt)

## 6. Review Checklist
- [ ] Red: 17 tests FAIL
- [ ] Green: 17 tests PASS
- [ ] `scanInProgress` rename does not break existing library tests
- [ ] Cache file is valid JSON post-scan
