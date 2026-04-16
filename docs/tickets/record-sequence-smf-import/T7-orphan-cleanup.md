# T7: Orphan .mid Cleanup on Server Startup

**PRD Ref**: PRD-record-sequence-smf-import > §6.3
**Priority**: P3
**Size**: S
**Status**: Todo
**Depends On**: T6

---

## 1. Objective

Add a startup sweep that cleans up any orphan .mid files in `/tmp/LogicProMCP/` from previous crashed sessions.

## 2. Acceptance Criteria

- [ ] AC-1: On server start, delete any `.mid` files in `/tmp/LogicProMCP/` older than 5 minutes.
- [ ] AC-2: Don't delete files less than 5 minutes old (may be from a concurrent import).
- [ ] AC-3: If directory doesn't exist, skip silently.
- [ ] AC-4: Cleanup failure logged but doesn't block server startup.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testStartupSweepDeletesOldMidFiles` | Unit | Create old .mid in temp dir | File deleted |
| 2 | `testStartupSweepKeepsRecentFiles` | Unit | Create recent .mid | File preserved |
| 3 | `testStartupSweepHandlesMissingDir` | Unit | Dir doesn't exist | No error |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/LogicProServerTransportTests.swift` or dedicated file

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Modify | Add cleanup call in start() |
| `Sources/LogicProMCP/MIDI/SMFWriter.swift` | Modify | Add static cleanup method |

### 4.2 Implementation Steps (Green Phase)
1. Add `SMFWriter.cleanupOrphanFiles(olderThan: TimeInterval = 300)` static method
2. Call it in `LogicProServer.start()` before channel startup
3. List files in `/tmp/LogicProMCP/`, filter by modification date, delete old .mid files

## 5. Edge Cases
- EC-1: Permission denied on delete → log warning, continue

## 6. Review Checklist
- [ ] Red: tests run → FAILED
- [ ] Green: tests run → PASSED
- [ ] Server startup not blocked by cleanup errors
