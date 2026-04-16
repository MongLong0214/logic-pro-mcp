# T4: midi.import_file AppleScript Handler

**PRD Ref**: PRD-record-sequence-smf-import > §4.3
**Priority**: P1
**Size**: M
**Status**: Todo (BLOCKED by OQ-1)
**Depends On**: None (but OQ-1 probe must complete first)

---

## 1. Objective

Implement the `midi.import_file` operation in AppleScriptChannel as the primary import path. Uses NSWorkspace.open (Launch Services) for injection safety. Must detect if Logic Pro opens a new project instead of importing.

## 2. Acceptance Criteria

- [ ] AC-1: `AppleScriptChannel.execute("midi.import_file", ["path": "/tmp/test.mid"])` attempts to open the file in Logic Pro.
- [ ] AC-2: Uses `NSWorkspace.open` (same path as `project.open`), NOT string interpolation.
- [ ] AC-3: Returns `.success` if file is imported into existing project.
- [ ] AC-4: Returns `.error` if file doesn't exist.
- [ ] AC-5: If Logic opens a new project (detected via document count change), returns `.error("Import created new project instead of importing into current")`.
- [ ] AC-6: Routing table entry `"midi.import_file": [.appleScript, .accessibility]` added.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testAppleScriptImportFileRoutes` | Unit | Route midi.import_file → appleScript | Channel receives operation |
| 2 | `testAppleScriptImportFileRequiresPath` | Unit | No path param | Error "requires path" |
| 3 | `testAppleScriptImportFileRejectsNonexistent` | Unit | Path doesn't exist | Error with path |
| 4 | `testRoutingTableIncludesImportFile` | Unit | Check v2RoutingTable | Entry exists |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/DispatcherTests.swift` (routing)
- `Tests/LogicProMCPTests/ChannelRouterTests.swift` (routing table)

### 3.3 Mock/Setup Required
- Mock AppleScript execution (existing pattern)
- Temp .mid file for path existence tests

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AppleScriptChannel.swift` | Modify | Add midi.import_file case |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Modify | Add routing entry |
| `Tests/LogicProMCPTests/ChannelRouterTests.swift` | Modify | Routing table test |

### 4.2 Implementation Steps (Green Phase)
1. Add `"midi.import_file": [.appleScript, .accessibility]` to routing table
2. Add `case "midi.import_file":` in AppleScriptChannel.execute()
3. Validate `path` param exists and file exists on disk
4. Call `AppleScriptSafety.openFile(at: path)` (same as project.open)
5. Optionally verify project count didn't change (if OQ-1 reveals new-project behavior)

## 5. Edge Cases
- EC-1: File exists but is not a valid .mid → Logic Pro may show error dialog
- EC-2: Logic Pro not running → health check fails before execute
- EC-3: Path with spaces → NSWorkspace handles URL encoding

## 6. Review Checklist
- [ ] OQ-1 resolved before implementation
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Injection-safe (NSWorkspace, no string interpolation)
