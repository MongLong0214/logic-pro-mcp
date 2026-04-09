# T3: NSAppleScript In-Process for save/close/probes

**PRD Ref**: PRD-first-song-journey > US-1, US-2
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: None

## 1. Objective
Replace osascript child process execution with in-process NSAppleScript for AppleScript commands that ARE in Logic Pro's dictionary (save, close, count of documents, name). Use main thread via existing `ProcessUtils.runAppKit` pattern.

## 2. Acceptance Criteria
- [ ] AC-1: `AppleScriptChannel.executeAppleScript()` uses NSAppleScript via `ProcessUtils.runAppKit` (main thread) with 30s timeout. After T1+T2 remove project.new/save_as, ALL remaining AppleScript commands (save, close, probe, count) are short — single-path NSAppleScript, no dual-path complexity.
- [ ] AC-2: 30s timeout via DispatchWorkItem cancel + secondary watchdog. If timeout, channel marked degraded.
- [ ] AC-3: ObjC exception defense: Objective-C shim file (`Sources/LogicProMCP/Utilities/ObjCExceptionBridge.m` + bridging header) wraps `NSAppleScript.executeAndReturnError` in `@try/@catch`, converts ObjC exceptions to NSError. This prevents server crash from malformed scripts.
- [ ] AC-4: `ProjectDispatcher.executeAppleScript()` (launch/quit path at line 177-179) calls `AppleScriptChannel.executeAppleScript()` instead of spawning osascript directly.
- [ ] AC-5: `project.close` routing updated to `[.appleScript, .cgEvent]` — CGEvent Cmd+W (key 13) as fallback. Already in keyMap.
- [ ] AC-5: All 369 existing tests pass
- [ ] AC-6: New integration test verifies NSAppleScript path with a real `tell application "Logic Pro" to return name` probe

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testNSAppleScriptProbeSucceeds` | Unit | Short script returns result |
| 2 | `testNSAppleScriptTimeoutReturnsError` | Unit | 5s timeout → error |
| 3 | `testObjCExceptionBridgeDoesNotCrash` | Unit | Bad script → error, not crash |
| 4 | `testOsascriptFallbackForLongScripts` | Unit | Long script uses Process path |
| 5 | `testProjectDispatcherUsesSharedExecution` | Unit | launch/quit go through same path |

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/Channels/AppleScriptChannel.swift` | Dual-path: NSAppleScript (short) / osascript (long) |
| `Sources/LogicProMCP/Dispatchers/ProjectDispatcher.swift` | Migrate `executeAppleScript` to use channel |
| `Sources/LogicProMCP/Utilities/ProcessUtils.swift` | Add `runNSAppleScript(source:timeout:)` helper |

### Steps
1. Add `ProcessUtils.runNSAppleScript(source:timeout:)` using `runAppKit` pattern
2. Add ObjC bridge shim for exception safety
3. In `AppleScriptChannel.executeAppleScript`, detect script complexity → route to NSAppleScript or osascript
4. Migrate `ProjectDispatcher.executeAppleScript` to use `AppleScriptChannel.executeAppleScript`
5. Add tests
