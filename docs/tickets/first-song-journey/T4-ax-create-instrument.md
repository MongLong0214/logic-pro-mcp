# T4: AX Menu Click for create_instrument + Verification

**PRD Ref**: PRD-first-song-journey > US-3
**Priority**: P0
**Size**: M
**Status**: Todo
**Depends On**: None

## 1. Objective
Add AX menu click as primary route for track creation (deterministic, no preset dependency). Verify track count increases after creation.

## 2. Acceptance Criteria
- [ ] AC-1: `create_instrument` primary route: AX clicks `트랙 > 새로운 소프트웨어 악기 트랙` menu
- [ ] AC-2: Post-creation: AX track count before vs after, 3 retries × 1s
- [ ] AC-3: Returns error if track count doesn't increase
- [ ] AC-4: Applies to all create_* commands (audio, instrument, drummer, external_midi)
- [ ] AC-5: Routing: `[.accessibility, .midiKeyCommands, .cgEvent]` (AX first)

## 3. TDD Spec

| # | Test Name | Type | Expected |
|---|-----------|------|----------|
| 1 | `testCreateInstrumentRoutesAXFirst` | Unit | Router sends to Accessibility channel first |
| 2 | `testAXMenuClickTriggersTrackCreation` | Unit | AX clicks correct menu item |
| 3 | `testPostCreationVerifiesTrackCount` | Unit | Track count comparison runs |
| 4 | `testCreateInstrumentErrorOnNoCountIncrease` | Unit | Error returned on verification failure |

## 4. Implementation Guide

### Files to Modify
| File | Change |
|------|--------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Add `track.create_*` handlers with AX menu click |
| `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift` | No new helper needed — use existing `menuItem(path:)` + `AXHelpers.performAction(element, kAXPressAction)` |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Update routing for create_* |
| `Sources/LogicProMCP/Dispatchers/TrackDispatcher.swift` | Add post-creation AX track count verification |

### Steps
1. Add `AXLogicProElements.clickMenuItem(path:)` — navigates menu hierarchy via AX
2. In AccessibilityChannel, handle `track.create_instrument` → click menu item
3. In TrackDispatcher, wrap all `create_*` commands: capture count before → route → verify count after
4. Update routing table: `.accessibility` first in chain
