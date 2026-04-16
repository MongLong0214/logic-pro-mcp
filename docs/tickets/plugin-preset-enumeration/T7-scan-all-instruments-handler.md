# T7: scanAllInstruments Batch Handler + Reconciliation Ledger

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-2 AC-2.1-2.10, AC-5.5/5.6, E21
**Priority**: P0
**Size**: L
**Status**: Todo
**Depends On**: T6

---

## 1. Objective
Implement `AccessibilityChannel.scanAllInstruments` batch handler with `openedByScanner` ledger (AC-2.8) and reconciliation-cleanup phase. Iterates every instrument track; opens plugin window if needed; scans; closes (unless pre-open); records per-track entries; writes aggregate inventory.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-2.1): Project with N tracks, K instrument — returns K entries with `{ trackIndex, pluginName, pluginIdentifier, pluginVersion?, presetRoot, scanDurationMs, cached, error? }`. Audio/MIDI/Aux/Bus silently skipped.
- [ ] **AC-2** (AC-2.2): `onlyTracks: [0, 3, 5]` filter — only those scanned.
- [ ] **AC-3** (AC-2.3): `skipAlreadyCached: true` + non-nil version match → cached entry returned, no AX.
- [ ] **AC-4** (AC-2.4/E21): Single-track scan error → track entry gets `error`; batch continues; scanner-opened window closed before next.
- [ ] **AC-5** (AC-2.5): Post-batch, no scanner-opened windows remain.
- [ ] **AC-6** (AC-2.6/AC-1.9): Second concurrent call errors via shared flag.
- [ ] **AC-7** (AC-2.7): Aggregate written as `PluginPresetInventory` to `plugin-inventory.json`.
- [ ] **AC-8** (AC-2.8): `openedByScanner: [Int: ScannerWindowRecord]` ledger tracks scanner-opened windows; close uses `cgWindowID` primary key.
- [ ] **AC-9** (AC-2.9/AC-5.6): Reconciliation close failure → `reconciliationWarnings: [{trackIndex, pluginName, error}]`; batch does not error.
- [ ] **AC-10** (AC-5.5): Windows open before batch remain open; pre/post delta on scanner-opened = 0.
- [ ] **AC-11**: AC-2.3 nil-version: always force rescan — no circular contentHash skip.

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/AccessibilityChannelScanAllInstrumentsTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `test3Instr2AudioTracks` | 5 tracks (3 instr, 2 audio) → 3 entries |
| 2 | `testOnlyTracksFilter` | `[0, 3]` → 2 entries |
| 3 | `testSkipAlreadyCachedWithMatchingVersion` | Cache hit → cached:true, no AX |
| 4 | `testSkipAlreadyCachedVersionNilForcesRescan` | Cache hit, nil version → rescan (AC-2.3 + E22) |
| 5 | `testSkipAlreadyCachedVersionMismatchRescans` | Cache hit, wrong version → rescan |
| 6 | `testPerTrackErrorBatchContinues` | Track 1 errors, tracks 2-3 succeed → 3 entries, 1 with error |
| 7 | `testScannerOpenedWindowClosedBeforeNextTrack` | After per-track error, that window is closed before track 2 |
| 8 | `testPostBatchNoLingeringWindows` | Ledger iterated, all scanner-opened closed |
| 9 | `testPreOpenWindowStaysOpen` | Window open before batch → still open after |
| 10 | `testCloseFailureProducesReconciliationWarning` | closePluginWindow returns false → warning in response |
| 11 | `testConcurrentBatchErrorsViaFlag` | Second batch call errors |
| 12 | `testConcurrentSinglePluginScanErrorsViaFlag` | plugin.scan_presets during batch errors |
| 13 | `testAggregateInventoryWrittenPostBatch` | Aggregate JSON contains all scanned plugins keyed by bundle ID |
| 14 | `testLedgerKeyedByCGWindowID` | ScannerWindowRecord close-path uses cgWindowID |
| 15 | `testLedgerFallbackBundleIDTuple` | cgWindowID=0 → fallback to (bundleID, windowTitle) |

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Add `case "plugin.scan_all_instruments"` handler with ledger-driven reconciliation |
| `Tests/LogicProMCPTests/AccessibilityChannelScanAllInstrumentsTests.swift` | Create | 15 tests |

### 4.2 Implementation Steps
1. Validate + parse params; enforce axScanInProgress
2. List instrument tracks via existing track-inspection helpers; apply `onlyTracks` filter
3. `openedByScanner: [Int: ScannerWindowRecord] = [:]`; `nextScannerWindowID = 0`
4. `reconciliationWarnings: [ReconWarn] = []`
5. For each track:
   - Identify plugin → check cache per AC-2.3
   - If cache hit with valid version → entry with `cached:true`, no AX
   - Else open window (if not pre-open); record in ledger with new ID
   - Scan via `PluginInspector.scanLive`
   - Append entry
   - If scanner opened this window, close it; on failure add warning
   - On per-track error: close scanner-opened window (warning on failure), append error entry, continue
6. Post-loop reconciliation: iterate `openedByScanner` for any still-open windows (belt-and-braces); close with warning on failure
7. Build aggregate `PluginPresetInventory`; write to file
8. Return response

### 4.3 Refactor
- Extract `BatchScanContext` actor-local struct holding ledger + warnings

## 5. Edge Cases
- EC-1: User deletes track mid-batch (E30) — entry for index N fails with `error: "Track N no longer exists"`; batch continues
- EC-2: Plugin window opened during scan by user (not scanner) — not in ledger; untouched

## 6. Review Checklist
- [ ] Red: 15 tests FAIL
- [ ] Green: 15 tests PASS
- [ ] Post-batch ledger empty in happy path
