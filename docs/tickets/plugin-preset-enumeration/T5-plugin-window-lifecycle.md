# T5: Plugin Window Lifecycle — openPluginWindow + closePluginWindow + CGWindowID

**PRD Ref**: PRD-plugin-preset-enumeration v0.5 > US-5 AC-5.1-5.6, §4.2 ScannerWindowRecord, AC-2.8
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: T1, T4

---

## 1. Objective
Implement `openPluginWindow(for trackIndex: Int) async throws -> (AXUIElementSendable, CGWindowID)` and `closePluginWindow(_: AXUIElementSendable) async -> Bool`. Open: double-click instrument slot → wait for AX-visible plugin window within 2000 ms → capture CGWindowID. Close: AXPress the close button.

## 2. Acceptance Criteria
- [ ] **AC-1** (AC-5.4): Open waits ≤ 2000 ms for window; timeout → throws `PluginError.openTimeout(trackIndex:)`.
- [ ] **AC-2** (AC-2.8): On open, captures `CGWindowID` via `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` filtered by `kCGWindowOwnerPID == Logic.pid` + `kCGWindowLayer == 0`, matched against window's `AXWindowID`.
- [ ] **AC-3** (AC-5.3): Post-open, caller verifies bundle ID matches expected — this method returns the window+CGWindowID pair; identity check is the caller's responsibility (T6/T7).
- [ ] **AC-4**: Close calls AXPress on window's close button (`AXCloseButton` subrole). Returns true on success, false if AXPress fails.
- [ ] **AC-5**: Open uses injected monotonic `nowMs` clock for timeout (AC-5.4 test determinism).
- [ ] **AC-6**: If `CGWindowID` unavailable after open (rare), method returns `cgWindowID: 0` — caller's ledger stores it and falls back to (bundleID, windowTitle) at close time.

## 3. TDD Spec

### 3.1 Tests (Tests/LogicProMCPTests/PluginWindowLifecycleTests.swift)

| # | Test | Description |
|---|------|-------------|
| 1 | `testOpenWindowSucceedsWithinTimeout` | Stub runtime: appears after 200 ms → returns element + cgWindowID; nowMs clock advanced 300 ms total |
| 2 | `testOpenWindowTimeoutAt2000ms` | Stub never returns window; nowMs advances to 2001 → throws openTimeout |
| 3 | `testOpenCapturesCGWindowID` | Stub runtime provides CGWindowID 42 → returned pair has cgWindowID:42 |
| 4 | `testOpenCGWindowIDUnavailableReturnsZero` | Stub provides nil cgWindowID → returned 0, no throw |
| 5 | `testCloseSuccessful` | Stub AXPress returns true → method returns true |
| 6 | `testCloseFailedAXPressReturnsFalse` | Stub AXPress returns false → method returns false; no throw |
| 7 | `testOpenUsesMonotonicClock` | Inject clock that goes backward; assert method uses subtract correctly (no negative intervals) |
| 8 | `testCloseOfAlreadyClosedWindow` | Stub returns .apiDisabled on AXPress → returns false, no throw |
| 9 | `testOpenRetriesNullRuntimeGracefully` | Inject runtime where `openWindow` throws → propagates |

### 3.2 Mock Setup
- `PluginWindowRuntime` closures fully scripted.
- `nowMs` clock injected as monotonic increasing `Int`.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Type | Description |
|------|------|-------------|
| `Sources/LogicProMCP/Accessibility/PluginInspector.swift` | Modify | Add `openPluginWindow`, `closePluginWindow`, helper `captureCGWindowID`; extend `PluginError` with `openTimeout(trackIndex: Int)` |
| `Tests/LogicProMCPTests/PluginWindowLifecycleTests.swift` | Create | 9 tests |

### 4.2 Implementation Steps
1. `openPluginWindow(for trackIndex: Int) async throws -> (AXUIElementSendable, CGWindowID)`:
   - Record `startMs = nowMs()`
   - Issue open (runtime's `openWindow(trackIndex)`)
   - Poll loop: every 100 ms call `runtime.findWindow(trackIndex)`; if non-nil, capture CGWindowID via `captureCGWindowID(for: window)`; return
   - If `nowMs() - startMs > 2000` throw
2. `captureCGWindowID(for window:)` — query `CGWindowListCopyWindowInfo` via runtime closure (new field `cgWindowList: @Sendable () -> [[String: Any]]`), filter by Logic's PID, match by AXWindowID
3. `closePluginWindow(_:)` — runtime's `closeWindow` closure handles the AXPress; this method is essentially a passthrough + WARN log on failure

### 4.3 Refactor
- Extract 100 ms poll loop as reusable `pollUntil(timeoutMs:)`

## 5. Edge Cases
- EC-1: Logic moves focus during open → `focusOK` check may fire; treated as timeout (not an error) — log INFO
- EC-2: CGWindowID lookup returns multiple matches for same PID → pick the one whose AXWindowID matches the window we have

## 6. Review Checklist
- [ ] Red: 9 tests FAIL
- [ ] Green: 9 tests PASS
- [ ] Monotonic clock verified — negative intervals impossible
- [ ] Timeout tested at exactly 2000 ms boundary
