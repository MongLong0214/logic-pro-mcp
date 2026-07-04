# T1: 12.3 Mixer Strips-Container Selection Fix + Dual-Generation Fixtures

**PRD Ref**: PRD-issue-234-mixer-strip-selection-12-3 > US-1, US-2 (AC-1.1~1.4, AC-2.1)
**Priority**: P0 (Blocker)
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: None

---

## 1. Objective

Make `getMixerArea` select the real channel-strips container on Logic 12.3 (toolbar `AXGroup desc='Mixer'` and outer wrapper must never win) while preserving 12.2 trees, the legacy `AXIdentifier=="Mixer"` path, and every existing fixture.

## 2. Acceptance Criteria

- [ ] AC-1: On the 12.3-shaped fixture (outer wrapper `AXGroup desc='Mixer'` containing [toolbar `AXGroup desc='Mixer'` with 8 non-AXLayoutItem widgets, unnamed `AXGroup` containing `AXLayoutArea desc='Mixer'` with N `AXLayoutItem` strips]), `getMixerArea` returns the `AXLayoutArea` for N ∈ {1, 3, 8, 9, 12}.
- [ ] AC-2: When only the toolbar exists (strips container absent), `getMixerArea` returns nil (flows into the existing reveal / State B path) — never the toolbar.
- [ ] AC-3: 12.2-shaped fixture (no toolbar sibling) and Korean-locale variant (`desc='믹서'`) still select the strips container.
- [ ] AC-4: Legacy `AXIdentifier=="Mixer"` short-circuit untouched; `mixerChannelStrips` keeps its all-children fallback for that path (existing fixtures across the suite stay green, incl. `AXLogicProElementsTests` id-based trees and `PluginGetInventoryTests.makeMixerFixture`).
- [ ] AC-5: Inspector layout-area exclusion behavior unchanged (12.3 inspector fixture under an inspector-marked ancestor is never selected).

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `test123MixerSelectsStripsContainerNotToolbar` | Unit | Full 12.3 window fixture (§4.2 shape), 3 strips | Winner is the layout area (verify via `CFEqual` against the fixture element) |
| 2 | `test123MixerSelectionIndependentOfStripCount` | Unit (parametrized N ∈ {1,3,8,9,12}) | Same fixture, N strips | Layout area wins for every N (kills ≤8-strip dependence) |
| 3 | `test123ToolbarAloneYieldsNoMixer` | Unit | 12.3 fixture with toolbar but no strips container | `getMixerArea == nil` |
| 4 | `test122ShapeStillSelected` | Unit | 12.2 shape: window → `AXGroup desc='Mixer'` → `AXLayoutArea desc='Mixer'` → strips | Layout area wins |
| 5 | `test123KoreanLocaleSelection` | Unit | #1 with `desc='믹서'` everywhere | Layout area wins |
| 6 | `test123InspectorAreaStillExcluded` | Unit | 12.3 fixture + inspector-marked ancestor containing a 2-strip layout area, main mixer hidden | `getMixerArea == nil` (not the inspector area) |
| 7 | `test123EnumerationEndToEnd` | Integration | Fixture #1 where strip children mirror the live dump (name field, mute/solo, fader, pan, automation group, group popup, output/send buttons, empty `audio plug-in` row + occupied group + `MIDI plug-in` row + EQ/meters/setting). **Drives the full chain**: `getMixerArea` → `mixerChannelStrips` → `audioPluginInsertSlots(strips[0])` (boomer R2b-#1: enumerating the fixture strip directly would pass on main — the classifiers are healthy; the red color comes from selection) | Chain returns exactly [occupied, empty] with physical indices (proves NG1: classifiers untouched and correct on 12.3) |

Red-phase requirement (boomer R2-#4 corrected): #1, #2, #3, **#5**, #7 must FAIL against current `main` (the Korean 12.3 fixture hits the same fallback-ranking bug — `mixerNamedElement` matches '믹서' and the toolbar still wins); #4 (12.2 shape) and #6 (inspector exclusion — existing coverage at `AXLogicProElementsTests.swift:307` extends to the 12.3 variant) must PASS already and serve as regression pins.

### 3.2 Test File Location
- `Tests/LogicProMCPTests/Mixer123SelectionTests.swift` (new; fixture builders shared via file-private helpers modeled on the live dumps in the PRD §1.2 — transcribe roles/descriptions/frames from `axdump234b.out`)

### 3.3 Mock/Setup Required
- `FakeAXRuntimeBuilder` (existing). Frames via `axPoint/axSize` helpers as in `AXPluginInsertSlotsDriftTests.swift`. No new mocking infrastructure.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift` | Modify | Candidate strip-ness = AXLayoutItem-only (D1/D2) |
| `Tests/LogicProMCPTests/Mixer123SelectionTests.swift` | Create | §3.1 tests + 12.3/12.2 fixture builders |

### 4.2 Implementation Steps (Green Phase)

1. Add private helper `channelStripLayoutItems(in:runtime:) -> [AXUIElement]` = children filtered to `kAXLayoutItemRole`.
2. `hasDirectChannelStripChildren` (line ~776) → `!channelStripLayoutItems(...).isEmpty` (toolbar/wrapper stop qualifying as candidates).
3. `collectMixerAreaCandidates` (line ~720): `stripCount` = `channelStripLayoutItems(...).count` (ranking can no longer be inflated by non-strip children).
4. `mixerChannelStrips` (line ~783): **unchanged** — its all-children fallback remains for the legacy `AXIdentifier=="Mixer"` short-circuit path; name-based winners now always contain ≥ 1 `AXLayoutItem`, so the fallback is unreachable for them by construction.
5. Update the 12.2 structure comment at `getMixerArea` (line ~632) to document both generations (12.3: outer wrapper + toolbar sibling + nested layout area).

### 4.3 Refactor Phase
- None planned (minimal change). Do NOT add deeper strip signatures (fader/name probes) — PRD D1 rejected option (c); honesty gate (T2) is the drift backstop.

## 5. Edge Cases
- EC-1 (PRD E1): strip counts 1..12 parametrized.
- EC-2 (PRD E3): 12.2 regression fixture.
- EC-3 (PRD E4): Korean locale fixture.
- EC-4 (PRD E5): inspector exclusion fixture.

## 6. Review Checklist
- [ ] Red: 신규 테스트 #1/#2/#3/#5/#7 FAILED on main 확인; #4/#6 PASS (pins)
- [ ] Green: 전체 신규 테스트 PASSED
- [ ] Refactor: N/A
- [ ] AC 전부 충족
- [ ] 기존 테스트 (1931+) 깨지지 않음 (`swift test --no-parallel`)
- [ ] 코드 스타일 준수 (기존 주석 밀도/네이밍)
- [ ] 불필요한 변경 없음 (선택 로직 외 무변경)
