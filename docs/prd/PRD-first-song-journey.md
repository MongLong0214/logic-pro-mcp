# PRD: First-Song Journey — Core User Flow Fix

**Version**: 0.2
**Date**: 2026-04-09
**Status**: Draft
**Size**: XL

---

## 1. Problem Statement

### 1.1 Background
QA/E2E testing revealed that while individual channels (MCU, Accessibility, CoreMIDI) work when a valid Logic Pro session is already open, the **core user flow from cold start to first song** is completely broken. The 5 critical blockers prevent any real-world use of the MCP server.

### 1.2 Problem Definition
The MCP server cannot complete the "first-song journey": launch Logic Pro → create project → add tracks → input MIDI → save. This makes it unusable as a production MCP server despite passing 369 unit tests.

### 1.3 Impact of Not Solving
- The product cannot be shipped as a functional MCP server
- Users cannot create, open, or save projects
- Track creation reports success but is a no-op
- State readback is unreliable
- "Developer demo" level, not "user-trustable" level

## 2. Goals & Non-Goals

### 2.1 Goals
- [x] G1: `project.new` creates a real Logic Pro document from cold start
- [x] G2: `project.open` truthfully opens a project and verifies it
- [x] G3: `project.save_as` produces a real `.logicx` file
- [x] G4: `tracks.create_instrument` actually creates a track (verified by state readback)
- [x] G5: State readback (`logic://project/info`, `logic://tracks/*`) reflects reality
- [x] G6: Server detects and handles windowless/ghost Logic Pro sessions
- [x] G7: First-song journey completes end-to-end: new → track → MIDI → play → save

### 2.2 Non-Goals
- NG1: No new MCP tools or API changes
- NG2: No changes to MCU, CoreMIDI, or MIDI channels (these work)
- NG3: No installer/release workflow changes
- NG4: No architecture refactoring

## 3. User Stories & Acceptance Criteria

### US-1: Reliable AppleScript Execution
**As a** server operator, **I want** AppleScript commands to execute with proper Automation permissions, **so that** project lifecycle operations work regardless of how the MCP server is launched.

**Acceptance Criteria:**
- [ ] AC-1.1: Short AppleScript probes (health check, document count, save, close) use in-process `NSAppleScript` via `ProcessUtils.runAppKit` (main thread). Long-running scripts use osascript with `Process.terminate()` after 30s timeout.
- [ ] AC-1.2: `project.new` uses CGEvent `Cmd+N` after activating Logic Pro — no AppleScript. Verified by AX document count increase.
- [ ] AC-1.3: `project.save_as` uses CGEvent `Cmd+Shift+S` to trigger Save As dialog, then AX to enter filename and click Save. Verified by file existence on disk.
- [ ] AC-1.4: `project.close` uses NSAppleScript `close front document` (in Logic Pro's dictionary). Fallback: CGEvent `Cmd+W`.
- [ ] AC-1.5: All existing 369 tests pass. New integration test verifies NSAppleScript execution path with a real Logic Pro probe.
- [ ] AC-1.6: osascript-based scripts timeout at 30s via `Process.terminate()`. NSAppleScript probes have 5s timeout via `DispatchQueue.main.asyncAfter` watchdog. ObjC exception defense: NSAppleScript wrapped in `@objc` try/catch bridge.

### US-2: Truthful Project Open
**As a** user, **I want** `project.open` to truthfully report whether a project was opened, **so that** I can trust the MCP response.

**Acceptance Criteria:**
- [ ] AC-2.1: `project.open` via NSWorkspace succeeds (already works)
- [ ] AC-2.2: Post-open verification uses in-process `NSAppleScript` (not osascript child)
- [ ] AC-2.3: If verification fails (document not found after 5s), return error — not false positive
- [ ] AC-2.4: Invalid/corrupt `.logicx` files are detected and reported as errors

### US-3: Track Creation with Verification
**As a** user, **I want** `tracks.create_instrument` to actually create a track, **so that** the response matches reality.

**Acceptance Criteria:**
- [ ] AC-3.1: Primary route: AX menu click `트랙 > 새로운 소프트웨어 악기 트랙` (deterministic, locale-independent via AX, no preset dependency)
- [ ] AC-3.2: Post-creation: AX track count check — before count vs after count, 3 retries × 1s. Error if no increase.
- [ ] AC-3.3: Applies to ALL create_* commands (audio, instrument, drummer, external_midi) in TrackDispatcher
- [ ] AC-3.4: Fallback chain: `.accessibility` → `.midiKeyCommands` → `.cgEvent` (updated routing table)

### US-4: Reliable State Readback
**As an** automation client, **I want** state resources to reflect actual Logic Pro state, **so that** I can verify my commands worked.

**Acceptance Criteria:**
- [ ] AC-4.1: `logic://project/info` returns error/empty when no document is open (not stale data)
- [ ] AC-4.2: `logic://tracks/{index}` returns error when Logic Pro has no visible window
- [ ] AC-4.3: StateCache is invalidated when Logic Pro transitions to windowless state
- [ ] AC-4.4: StatePoller detects and handles no-window condition

### US-5: Session State Detection
**As a** server, **I want** to detect when Logic Pro is in a windowless/ghost state, **so that** I can report accurate health and prevent false successes.

**Acceptance Criteria:**
- [ ] AC-5.1: `ProcessUtils` adds `hasVisibleWindow()` using `CGWindowListCopyWindowInfo` filtered to on-screen, non-zero-area windows. During startup (first 10s after process detection), retries before reporting windowless.
- [ ] AC-5.2: `ChannelHealth` reports degraded state when process exists but no window
- [ ] AC-5.3: `logic_system.health` includes `logic_pro_has_document: true/false`
- [ ] AC-5.4: AppleScript operations return clear error when no document exists

### US-6: End-to-End First-Song Journey
**As a** user, **I want** to complete the entire flow from launch to save, **so that** the MCP server is actually usable.

**Acceptance Criteria:**
- [ ] AC-6.1: Cold start: Logic Pro running, no document → `project.new` → document exists
- [ ] AC-6.2: `tracks.create_instrument` → track count increases by 1
- [ ] AC-6.3: MIDI input via CoreMIDI → notes appear on armed track
- [ ] AC-6.4: `transport.play` / `transport.stop` → transport state changes
- [ ] AC-6.5: `project.save_as` → `.logicx` file exists on disk
- [ ] AC-6.6: Full journey completes without manual intervention

## 4. Technical Design

### 4.1 Root Causes (Corrected after Phase 2 Review)

**Three distinct root causes, NOT one:**

**RC-1: Logic Pro AppleScript dictionary gaps**
`make new document` and `save front document in <file>` are NOT in Logic Pro's scripting dictionary. These commands fail regardless of permission or execution method. Fix: use CGEvent/AX instead of AppleScript for `project.new` and `project.save_as`.

**RC-2: osascript child process permission inheritance**
`AppleScriptChannel.executeAppleScript()` spawns `/bin/zsh -lc osascript` — child process lacks TCC Automation permission. Affects commands that DO work in Logic Pro's dictionary (`save`, `close`, `count of documents`). Fix: use in-process `NSAppleScript` via main thread dispatch (existing `ProcessUtils.runAppKit` pattern).

**RC-3: No session state verification**
`isLogicProRunning` only checks process existence, not window/document state. Track creation reports success without verifying. State readback depends on MCU feedback with no AX fallback. Fix: add window checks, post-mutation verification, expanded AX polling.

### 4.2 Key Technical Decisions

| Decision | Options | Chosen | Rationale |
|----------|---------|--------|-----------|
| project.new | (a) AppleScript (b) CGEvent Cmd+N (c) AX menu click | (b) CGEvent Cmd+N | Logic Pro doesn't support `make new document`. Cmd+N is deterministic |
| project.save_as | (a) AppleScript (b) CGEvent Cmd+Shift+S + AX dialog (c) AX menu File>Save As | (b) CGEvent + AX | Logic Pro doesn't support `save in <file>`. Need AX for filename entry |
| project.open verify | (a) osascript polling (b) AX window check | (b) AX window check | Avoids permission issues; path normalization via `resolveSymlinks` |
| AppleScript (save/close) | (a) NSAppleScript main thread (b) Keep osascript | (a) NSAppleScript | Uses existing `ProcessUtils.runAppKit` pattern; killable via Process as fallback |
| NSAppleScript thread | (a) Main thread via runAppKit (b) Task.detached | (a) Main thread | NSAppleScript requires NSRunLoop; `runAppKit` already handles this |
| NSAppleScript timeout | (a) Task race (b) Process.terminate fallback | (b) Hybrid | Short probes: NSAppleScript (main thread). Long ops (save/close): osascript (killable via Process.terminate after 30s) |
| Track creation | (a) MIDI Key Cmd (b) CGEvent (c) AX menu click | (c) AX menu | Deterministic; no preset dependency; works in Korean locale |
| Track verification | (a) AX count (b) Cache | (a) AX count | Direct count before/after, 3 retries × 1s |
| State invalidation | (a) Timer (b) On-access (c) hasDocument flag | (c) Flag + expanded poll | `StateCache.hasDocument` flag; AX transport/track poll when MCU disconnected |
| Ghost session | (a) CGWindowList (b) AX kAXWindowsAttribute | (a) CGWindowList | No extra permissions needed; filter on-screen, non-zero area |

### 4.3 Files to Modify

```
Sources/LogicProMCP/Channels/AppleScriptChannel.swift  ← RC-2: NSAppleScript via runAppKit for save/close; remove project.new/save_as AppleScript paths
Sources/LogicProMCP/Channels/CGEventChannel.swift      ← RC-1: Add Cmd+N (project.new), Cmd+Shift+S (save_as dialog trigger)
Sources/LogicProMCP/Channels/AccessibilityChannel.swift ← RC-1: Add save_as dialog AX interaction, AX menu click for create_instrument
Sources/LogicProMCP/Channels/ChannelRouter.swift       ← Update routing: project.new → [.cgEvent], save_as → [.cgEvent+.accessibility], create_instrument → [.accessibility, .midiKeyCommands, .cgEvent]
Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift   ← RC-3: Post-creation AX verification for all create_* commands
Sources/LogicProMCP/Dispatchers/ProjectDispatcher.swift ← RC-2: Migrate executeAppleScript to shared channel; add post-open AX verification
Sources/LogicProMCP/Utilities/ProcessUtils.swift        ← RC-3: Add hasVisibleWindow() via CGWindowListCopyWindowInfo
Sources/LogicProMCP/State/StatePoller.swift             ← RC-3: Expanded AX polling for transport/tracks when MCU disconnected
Sources/LogicProMCP/State/StateCache.swift              ← RC-3: Add hasDocument flag, clearProjectState()
Sources/LogicProMCP/Resources/ResourceHandlers.swift    ← RC-3: Return error when hasDocument=false
Sources/LogicProMCP/Dispatchers/SystemDispatcher.swift  ← RC-3: Add has_document + has_window to health
Tests/LogicProMCPTests/*.swift                          ← Update tests for new routing and verification
```

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | Logic Pro not running + project.new | Error: "Logic Pro is not running" | P0 |
| E2 | Logic Pro running but no window + project.save | Error: "No document open" | P0 |
| E3 | project.open with corrupt .logicx | Error: "Failed to open: invalid project" | P1 |
| E4 | create_instrument in windowless state | Error: "No document open for track creation" | P0 |
| E5 | NSAppleScript hangs (Logic Pro dialog) | Timeout after 30s with clear error | P1 |
| E6 | Track creation succeeds but AX can't read it yet | Retry AX check up to 3 times with 1s delay | P2 |
| E7 | Multiple rapid project.new calls | Second call returns "Document already open" | P2 |

## 6. Security & Permissions

### 6.1 Permission Model Change
- REMOVED: `osascript` child process dependency (source of -1743)
- ADDED: `NSAppleScript` in-process execution (uses binary's own TCC permission)
- NO CHANGE: Accessibility, MCU, CoreMIDI permissions

### 6.2 Risk
- NSAppleScript runs on main thread via `runAppKit` — short probes only (5s timeout)
- Long-running scripts keep osascript (killable via `Process.terminate()` after 30s)
- NSAppleScript ObjC exceptions can crash the process — wrapped in `@objc` try/catch bridge shim
- String interpolation injection in AppleScript: all paths validated via `AppleScriptSafety.isValidProjectPath` before interpolation; `project.new` and `save_as` no longer use AppleScript string interpolation at all (CGEvent+AX)
- No new permission requirements for users

## 7. Testing Strategy

### 7.1 Unit Tests
- NSAppleScript execution wrapper tests (mock via Runtime DI)
- ProcessUtils.hasVisibleWindow tests
- Track creation verification tests
- StateCache invalidation tests
- ResourceHandler no-document error tests

### 7.2 E2E Test (Manual)
- Full first-song journey: new → track → MIDI → play → save → reopen

## 8. Risks

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| NSAppleScript blocks cooperative thread | High if done wrong | High | Task.detached mandatory |
| NSAppleScript hangs on modal dialog | Medium | High | Configurable timeout (30s) |
| AX track count check is slow | Low | Low | Max 3 retries × 1s |
| Korean Logic Pro has different menu structure | Medium | Medium | Verify key codes on Korean locale |

## 9. Open Questions
- None — root causes are identified, fixes are clear

---
