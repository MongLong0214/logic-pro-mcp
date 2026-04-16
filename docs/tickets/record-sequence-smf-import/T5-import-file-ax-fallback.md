# T5: midi.import_file AX Menu Fallback

**PRD Ref**: PRD-record-sequence-smf-import > §4.3 (AX fallback)
**Priority**: P2
**Size**: L
**Status**: Todo
**Depends On**: T4 (primary path must be tried first)

---

## 1. Objective

Implement the AX fallback for `midi.import_file` in AccessibilityChannel. Navigates File → Import → MIDI File... menu, then enters the file path in the open panel dialog.

## 2. Acceptance Criteria

- [ ] AC-1: `AccessibilityChannel.execute("midi.import_file", ["path": "/tmp/test.mid"])` navigates the menu path.
- [ ] AC-2: Supports both KR (`파일 → 가져오기 → MIDI 파일...`) and EN (`File → Import → MIDI File...`) locale.
- [ ] AC-3: Uses Cmd+Shift+G in open panel to enter the path directly (no folder navigation).
- [ ] AC-4: Returns `.error` if menu path not found.
- [ ] AC-5: Returns `.error` if open panel doesn't appear within timeout.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testAXImportFileRequiresPath` | Unit | No path param | Error "requires path" |
| 2 | `testAXImportFileMenuNavigation` | Integration | Mock AX tree with menu | Menu items clicked in order |
| 3 | `testAXImportFileRejectsNoMenu` | Unit | Menu item not found | Error with menu path |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AccessibilityChannelTests.swift`

### 3.3 Mock/Setup Required
- FakeAXRuntimeBuilder (existing) with menu bar + import menu items

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Add midi.import_file case |
| `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift` | Modify | Add importMIDIFileMenu helper |

### 4.2 Implementation Steps (Green Phase)
1. Add menu path finder: `AXLogicProElements.findImportMIDIFileMenuItem()`
   - Search for "Import" / "가져오기" in File menu children
   - Then "MIDI File" / "MIDI 파일" in submenu
2. Add open panel path entry:
   - Wait for open panel (AXSheet or AXDialog)
   - Press Cmd+Shift+G via CGEvent
   - Type the file path
   - Press Enter
3. Wire into AccessibilityChannel execute

## 5. Edge Cases
- EC-1: Import menu disabled (no project open) → menu click fails
- EC-2: Open panel title differs by locale
- EC-3: Cmd+Shift+G not available in all panel modes

## 6. Review Checklist
- [ ] OQ-2 resolved (menu path confirmed)
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Works with both KR and EN locale
