# T2: CGEvent save_as (Cmd+Shift+S) + AX Dialog Interaction

**PRD Ref**: PRD-first-song-journey > US-1, US-6
**Priority**: P0
**Size**: L
**Status**: Todo
**Depends On**: None

## 1. Objective
Replace broken AppleScript `save front document in (POSIX file)` with CGEvent `Cmd+Shift+S` to trigger native Save As dialog, then use AX to enter the filename and click Save.

## 2. Acceptance Criteria
- [ ] AC-1: `project.save_as` sends CGEvent `Cmd+Shift+S` to trigger Save As dialog
- [ ] AC-2: AX locates the Save As dialog's filename text field and sets the path
- [ ] AC-3: AX clicks the Save button in the dialog
- [ ] AC-4: Post-save verification: check file exists on disk at specified path
- [ ] AC-5: Returns error if dialog doesn't appear or file doesn't exist after save
- [ ] AC-6: Routing: `"project.save_as": [.cgEvent]` primary, `.appleScript` fallback removed

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testSaveAsRoutesCGEvent` | Unit | Router sends to CGEvent |
| 2 | `testSaveAsCGEventSendsShiftCmdS` | Unit | CGEvent sends key code 1 with Cmd+Shift |
| 3 | `testSaveAsAXFillsFilename` | Unit | AX interaction sets filename |
| 4 | `testSaveAsVerifiesFileExists` | Unit | Post-save file check |
| 5 | `testSaveAsReturnsErrorOnDialogTimeout` | Unit | Error when dialog doesn't appear |

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/Channels/CGEventChannel.swift` | Add save_as key combo + AX dialog handler |
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Add `savePanelInteraction(path:)` method |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Update routing |
| `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift` | Add save dialog element locators |

### Steps
1. Add `"project.save_as"` handling in CGEventChannel: send Cmd+Shift+S (key 1 + shift + cmd). Already in keyMap as `.cmdShift(1)`.
2. After key event, poll AX for save dialog — locate as `kAXSheetRole` child of main window (standard NSSavePanel), retry up to 3s.
3. In save dialog: find `kAXTextFieldRole` (filename input), set `kAXValueAttribute` to target filename. Find `kAXButtonRole` with title containing "저장" or "Save", call `kAXPressAction`.
4. Poll for file existence at target path (max 10s)
5. Update routing table: `"project.save_as": [.cgEvent]` (remove `.appleScript`)
6. Remove `saveProjectAsScript()` from AppleScriptChannel (no longer routed)
