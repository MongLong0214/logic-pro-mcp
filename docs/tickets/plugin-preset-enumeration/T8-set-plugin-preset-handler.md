# T8: setPluginPreset Handler + AC-3.0 Identity Gate

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-3 AC-3.0-3.7, E12, E16-E20, E32
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: T3, T4, T5, T6

---

## 1. Objective
Implement `AccessibilityChannel.setPluginPreset`. Contract: `{ trackIndex, path }` → navigate cached tree + click leaf. AC-3.0 gate: lock acquired before identifyPlugin; cache-miss or path-unresolved → structured error without clicking.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-3.0 step d): `pluginPresetCache[liveBundleID]` missing → error, no click.
- [ ] **AC-2** (AC-3.0 step e): Path not found in cached tree → error, no click.
- [ ] **AC-3** (AC-3.1): Happy path — open window, click Setting dropdown, traverse submenus, click leaf.
- [ ] **AC-4** (AC-3.2): Path does not resolve to leaf → error.
- [ ] **AC-5** (AC-3.3): Path resolves to folder/separator/action → error (explicit kind check).
- [ ] **AC-6** (AC-3.4): Path escape `\/` and `\\` decoded correctly (uses T3 parsePath).
- [ ] **AC-7** (AC-3.5): Track out of range → error before any AX call.
- [ ] **AC-8** (AC-3.6): Track has no instrument → error.
- [ ] **AC-9** (AC-3.7): Window visibility restored post-call (closed if was closed; open if was open).
- [ ] **AC-10** (E12): Reject any param other than `trackIndex` + `path`.
- [ ] **AC-11** (E16/E18): AX errors mid-navigation wrapped; partial state tolerated (does not throw mid-sequence).
- [ ] **AC-12** (AC-1.9): Lock acquired before first AX read (identifyPlugin); concurrent calls error.

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/AccessibilityChannelSetPluginPresetTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `testHappyPathFullNavigation` | Cache + path valid → pressMenuItem called for each hop + leaf |
| 2 | `testCacheMissOnLiveBundleIDError` | No cache for liveBundleID → error matches §7.2 row |
| 3 | `testPathNotInCachedTreeError` | Cache present but path unresolved → error |
| 4 | `testPathResolvesToFolderError` | Path points to folder node → error (AC-3.3) |
| 5 | `testPathResolvesToSeparatorError` | Path points to separator → error |
| 6 | `testPathResolvesToActionError` | Path points to "Save As Default…" action → error (never auto-click) |
| 7 | `testEscapedSlashHandled` | Path `"Bass\\/Sub/Warm"` resolves to leaf "Warm" under folder "Bass/Sub" |
| 8 | `testTrackOutOfRangeError` | Index 999 on 5-track project → error before AX |
| 9 | `testTrackNoInstrumentError` | Audio track → "no instrument plugin loaded" |
| 10 | `testWindowClosedBeforeClosedAfter` | Pre-state closed → post-state closed |
| 11 | `testWindowOpenBeforeStaysOpen` | Pre-state open → post-state open |
| 12 | `testRejectsExtraParams` | Payload with `{ trackIndex, path, extra: 1 }` → error |
| 13 | `testLockAcquiredBeforeIdentifyPlugin` | Assert lock flag set before stub runtime.identifyPlugin called (order-recording spy) |
| 14 | `testConcurrentSetPresetErrorsViaFlag` | During scan → error |

### 3.2 Setup
- Order-recording spy for AX calls to verify AC-12 lock-before-identify

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Add `case "plugin.set_preset"` with 3-phase AC-3.0 gate |
| `Tests/LogicProMCPTests/AccessibilityChannelSetPluginPresetTests.swift` | Create | 14 tests |

### 4.2 Implementation Steps
1. Param validation: exact `{trackIndex: Int, path: String}` shape
2. Acquire axScanInProgress (defer clear)
3. Track-index validation (pre-AX)
4. Resolve window (open if closed; record pre-state for restore)
5. identifyPlugin → liveBundleID
6. Cache lookup; if miss → error path
7. `resolveMenuPath(path, in: cache.root)`; if nil → "Preset not found at path: <path>"
8. Check leaf node's `kind`; if `folder|separator|action` → "Path resolves to menu <kind>"
9. Open Setting dropdown via `probe.pressMenuItem([])` (empty path = dropdown itself)
10. `selectMenuPath(hops, probe:)` — traverse + click leaf
11. Restore window visibility per AC-3.7
12. Return response

### 4.3 Refactor
- Extract `resolveWindowForTrack(_ trackIndex: Int) -> (window: AXUIElementSendable, wasOpen: Bool)` helper shared with T6

## 5. Edge Cases
- EC-1 (E18): Mid-navigation window close → propagate error; best-effort window-visibility restore (no throw from restore)
- EC-2 (E24): Empty segment in path → error via parsePath (T3)

## 6. Review Checklist
- [ ] Red: 14 tests FAIL
- [ ] Green: 14 tests PASS
- [ ] Action/separator paths never click (verified by spy assertion)
- [ ] Lock-before-identify order verified (test 13)
