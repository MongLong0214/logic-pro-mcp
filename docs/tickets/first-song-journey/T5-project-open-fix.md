# T5: project.open Path Normalization + AX Verification

**PRD Ref**: PRD-first-song-journey > US-2
**Priority**: P0
**Size**: S
**Status**: Todo
**Depends On**: T3

## 1. Objective
Fix false positive in project.open by normalizing paths (resolve symlinks) and switching verification from osascript to AX-based document check.

## 2. Acceptance Criteria
- [ ] AC-1: Path normalization: both input path and Logic Pro's reported path use `URL.resolvingSymlinksInPath()`
- [ ] AC-2: Verification uses AX window title check instead of osascript polling
- [ ] AC-3: Invalid/corrupt .logicx files: improve error message (not just "timeout")
- [ ] AC-4: NSWorkspace.open continues to be used for the actual open (no AppleScript)

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testOpenPathNormalization` | Unit | `/Users/` and `/private/Users/` treated as equal |
| 2 | `testOpenVerifiesViaAX` | Unit | AX window title checked, not osascript |
| 3 | `testOpenCorruptFileReportsError` | Unit | Clear error, not timeout |

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/Channels/AppleScriptChannel.swift` | Replace `verifyOpenedProjectScript` with AX-based check |
| `Sources/LogicProMCP/Utilities/AppleScriptSafety.swift` | Add path normalization to `isValidProjectPath` |
