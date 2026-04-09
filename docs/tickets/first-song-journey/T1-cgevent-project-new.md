# T1: CGEvent project.new (Cmd+N) + AX Verification

**PRD Ref**: PRD-first-song-journey > US-1, US-6
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: None

## 1. Objective
Replace broken AppleScript `make new document` with CGEvent `Cmd+N` for project creation. Verify via AX that a new document was actually created.

## 2. Acceptance Criteria
- [ ] AC-1: `project.new` activates Logic Pro and sends CGEvent `Cmd+N` (key code 45)
- [ ] AC-2: After Cmd+N, poll AX for document count increase (max 5s, 10 retries × 500ms)
- [ ] AC-3: If Logic Pro shows a template dialog, the operation waits for a document to appear
- [ ] AC-4: Returns error if no document appears within timeout
- [ ] AC-5: Routing table updated: `"project.new": [.cgEvent]` (AppleScript removed — `make new document` is not in Logic Pro's dictionary)

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testProjectNewRoutesCGEvent` | Unit | Router sends to CGEvent channel |
| 2 | `testProjectNewCGEventSendsCommandN` | Unit | CGEvent sends key code 45 with Cmd modifier |
| 3 | `testProjectNewVerifiesDocumentCreated` | Unit | Post-creation AX check runs |
| 4 | `testProjectNewReturnsErrorOnTimeout` | Unit | Error after 5s with no document |

Test files: `Tests/LogicProMCPTests/CGEventChannelTests.swift`, `Tests/LogicProMCPTests/ChannelRouterTests.swift`

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/Channels/CGEventChannel.swift` | Add `project.new` → Cmd+N to keyMap; add post-creation AX verification |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | `"project.new": [.cgEvent, .appleScript]` (CGEvent primary) |
| `Sources/LogicProMCP/Channels/AppleScriptChannel.swift` | Remove `project.new` case (no longer routed here) |

### Steps
1. Add `"project.new": .cmd(45)` to CGEventChannel keyMap (Cmd+N, key code 45 = N)
2. In CGEventChannel.execute, add special handling for `project.new`: after key event, poll AX document count
3. Update ChannelRouter: `"project.new": [.cgEvent, .appleScript]`
4. Add tests

## 5. Edge Cases
- E1: Logic Pro not running → error before sending key event
- E2: Template picker dialog appears → AX wait handles this (document appears after user/auto selection)
- E3: Logic Pro already has a document open → Cmd+N creates additional document (acceptable)
