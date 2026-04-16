# T6: Track Header Visibility Check (AC-3.2)

**PRD Ref**: PRD-library-full-enumeration > US-3 (AC-3.2), §5 E13
**Priority**: P1
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: T5

---

## 1. Objective
When `set_instrument` target track is scrolled off-screen (header Y above tracklist top or below its bottom), return explicit error without clicking. No auto-scroll.

## 2. Acceptance Criteria
- [ ] AC-3.2 (PRD US-3)
- [ ] E13: off-screen → `"Track not visible; scroll tracklist to bring track N into view"`
- [ ] No Library click occurs when track invisible

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testSetInstrument_HeaderOnScreen_Clicks` | Unit | Mock header Y within tracklist bounds | Click injected |
| 2 | `testSetInstrument_HeaderAboveViewport_Error` | Unit | Mock header Y < tracklist top | Error, no Library click |
| 3 | `testSetInstrument_HeaderBelowViewport_Error` | Unit | Header Y > tracklist bottom | Error, no Library click |
| 4 | `testSetInstrument_HeaderVisibilityEdge_BarelyVisible` | Unit | Y = tracklist top exactly | Treated as visible |
| 5 | `testSetInstrument_NoAutoScroll_Attempted` | Unit | Runtime records no scroll gestures | Zero scroll events emitted |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AccessibilityChannelTrackVisibilityTests.swift` (NEW)

### 3.3 Mock/Setup Required
- Mock that returns tracklist bounds + header position independently

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | In `setTrackInstrument` — after `findTrackHeader`, compute header rect, compare against tracklist rect |
| `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift` | Modify | Add `getTracklistBounds(runtime) -> CGRect?` helper reading the tracklist scroll area |
| `Tests/LogicProMCPTests/AccessibilityChannelTrackVisibilityTests.swift` | Create | 5 tests |

### 4.2 Implementation Steps
1. `getTracklistBounds` — read the AXScrollArea or AXList containing track headers, get position+size.
2. In `setTrackInstrument`, after resolving header: compute header center Y, compare with tracklist bounds.
3. If out-of-range, return error before any Library interaction.
4. Tests pass.

### 4.3 Refactor Phase
- Consider a reusable `isVisibleWithin(_ element, parent)` helper.

## 5. Edge Cases
- EC-1: Tracklist bounds unavailable → fall through to click (fail-open, documented).
- EC-2: Header half-visible (partially cut off by scrolling) → treat as visible if center Y is within bounds.

## 6. Review Checklist
- [ ] 5 tests Red → Green
- [ ] No auto-scroll code path
- [ ] Fall-open behaviour documented for EC-1
