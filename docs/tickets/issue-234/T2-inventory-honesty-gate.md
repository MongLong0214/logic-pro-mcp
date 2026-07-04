# T2: get_inventory Zero-Slot Honesty Gate (No False Verified-Empty)

**PRD Ref**: PRD-issue-234-mixer-strip-selection-12-3 > US-3 (AC-3.1~3.3)
**Priority**: P0 (Blocker)
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: T1

---

## 1. Objective

Make State A structurally require ≥ 1 enumerated slot in `logic_plugins.get_inventory`: zero slots ⇒ State B `readback_unavailable` with `plugins_unknown_reason:"insert_section_not_enumerable"`. A visible insert section always exposes at least the empty append row, so verified-empty (`state:"A", plugins:[]`) becomes impossible — future AX drift degrades honestly instead of lying.

## 2. Acceptance Criteria

- [ ] AC-1: Fixture strip with zero recognizable slot children (e.g. Master-strip shape: name field + mute + fader + automation group + group popup only) → `get_inventory` returns State B `readback_unavailable`, `plugins_unknown_reason == "insert_section_not_enumerable"`, `safe_to_retry: true`, `track` echoed, `what_was_observed` states that 0 insert-slot elements were enumerable on the located strip, and `recovery_hint` names both likely causes (mixer AX-layout drift; strip type without an insert section, e.g. Master/VCA).
- [ ] AC-2: Fixture strip with exactly one empty slot → State A, `plugins.count == 1`, `read_status == "empty"` (the ≥1-slot State A floor).
- [ ] AC-3: Existing State A/B behaviors unchanged: mixed occupied/empty/unreadable chains (existing `PluginGetInventoryTests`), `mixer_not_visible` State B, `ax_subtree_unreadable` (track index ≥ strip count) State B — all green without modification.
- [ ] AC-4: State B zero-slot response carries the same reveal diagnostics fields State A carries (`mixer_reveal_attempted`, `mixer_reveal_strategies`) so operators can distinguish "revealed then blind" from "already visible then blind".
- [ ] AC-5 (PRD AC-3.4, boomer R1-#3, R2-#2): the slot-addressing guards in the **write paths** distinguish zero-slot from index-beyond-chain — still State C (writes never soften to State B), but when `slots.isEmpty` the failure carries `insert_section_not_enumerable` semantics: `what_was_observed` says the strip exposed no enumerable insert slots (not "slot N is out of range (0 slots)") and includes the AC-1 recovery hint. Implement the zero-slot detail once (shared helper) and use it at: `defaultInsertVerified` (~1021), `performVerifiedParamWrite` (~631), legacy `insert_plugin` (`AccessibilityChannel.swift` ~2204: keep `visible_slots: 0` field, add the distinct hint). `liveInsertSlot` (~1588, mid-flight re-resolution) inherits the wording via the shared helper but gets **no dedicated unit AC** — its zero-slot branch means slots vanished mid-operation, which the static FakeAX tree cannot simulate without contrived mutation hooks; the shared-helper construction plus the three tested sites pin the wording (boomer R2-#2 disposition). Non-zero-slot out-of-range errors unchanged.
- [ ] AC-6 (OQ-2 resolution, documentation-only): `fullStripInventory` needs **no** parallel gate — State A on writes already requires post-insert observed readback of the requested plugin (structurally impossible to false-succeed on a blind tree); record this rationale in the PR body.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testGetInventoryZeroSlotsIsStateBNotVerifiedEmpty` | Integration | Master-shaped strip fixture through `defaultGetPluginInventory` | State B per AC-1 (FAILS on main: currently State A `plugins:[]`) |
| 2 | `testGetInventoryZeroSlotsCarriesRevealDiagnostics` | Integration | Same, mixer pre-visible | `mixer_reveal_attempted == false`, strategies `[]`, reason `insert_section_not_enumerable` |
| 3 | `testGetInventorySingleEmptySlotIsStateA` | Integration | One `audio plug-in`-labeled empty row | State A, 1 item, `read_status:"empty"` |
| 4 | `testGetInventoryStateAImpliesNonEmptyPlugins` | Unit | Guard-level: the State A encode path for get_inventory is unreachable with `slots.isEmpty` | Compile-time/shape assertion via fixture sweep (0-slot → B; 1..3-slot → A) |
| 5 | `testInsertVerifiedZeroSlotsStateCDistinctDiagnostics` | Integration | Zero-slot strip through `defaultInsertVerified` (post identity gates) | State C, `write_attempted:false`, `what_was_observed` carries insert-section-not-enumerable wording + recovery hint (FAILS on main: bare "(0 slots)") |
| 6 | `testLegacyInsertPluginZeroSlotsHint` | Integration | Zero-slot strip through legacy insert path | `visible_slots: 0` retained + distinct hint |
| 7 | `testSetParamVerifiedZeroSlotsStateCDistinctDiagnostics` (boomer R2-#2) | Integration | Zero-slot strip through `performVerifiedParamWrite`'s addressing guard, in the live-path fixture suite idiom (`PluginSetParamVerifiedLiveTests.swift` builds full desc-Mixer fixtures; plain `PluginSetParamVerifiedTests` stops before live AX) | State C with the shared zero-slot wording (FAILS on main) |
| 8 | `testGetInventoryOverFull123WindowFixture` (PRD AC-1.2, boomer R2-#3) | Integration | Full 12.3 window fixture (outer wrapper + toolbar + nested layout area; strips with [occupied "Gain", empty] rows) driven through `defaultGetPluginInventory` with `revealMixer` injected as `{ rt in (AXLogicProElements.getMixerArea(runtime: rt), .alreadyVisible) }` so real selection runs | State A listing both slots with correct indices/read_status/name (FAILS on main: toolbar wins → 0 slots → post-T2 State B, pre-T2 false-A empty) |
| 9 | `testGetInventoryToolbarSelectedFlowsToStateB` (PRD AC-3.3, boomer R2-#3) | Integration | `revealMixer` injected to return the TOOLBAR element as the mixer (simulating the old wrong selection against the 12.3 fixture) | State B `insert_section_not_enumerable` — the pre-fix blind path can never again encode State A |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/PluginGetInventoryTests.swift` (extend — reuse `makeMixerFixture`; #8/#9 build the full 12.3 window via T1's shared fixture builders); write-path cases per `Tests/LogicProMCPTests/PluginInsertVerifiedTests.swift` / `PluginSetParamVerifiedLiveTests.swift` conventions

### 3.3 Mock/Setup Required
- Existing `FakeAXRuntimeBuilder` + `makeMixerFixture(stripChildren:)`. Master-strip children builder added file-privately.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Channels/AccessibilityChannel+VerifiedPlugins.swift` | Modify | Zero-slot State B branch in `defaultGetPluginInventory` (~167); zero-slot-distinct State C wording in `defaultInsertVerified` (~1021), `performVerifiedParamWrite` (~631), `liveInsertSlot` (~1588) |
| `Sources/LogicProMCP/Channels/AccessibilityChannel.swift` | Modify | Legacy insert path zero-slot hint (~2204) |
| `Tests/LogicProMCPTests/PluginGetInventoryTests.swift` | Modify | §3.1 tests #1-#4, #8, #9 |
| `Tests/LogicProMCPTests/PluginInsertVerifiedTests.swift` | Modify | §3.1 tests #5-#6 (or sibling file per conventions) |
| `Tests/LogicProMCPTests/PluginSetParamVerifiedLiveTests.swift` | Modify | §3.1 test #7 (zero-slot set_param addressing — boomer R2b-#2) |

### 4.2 Implementation Steps (Green Phase)

1. After `let slots = …audioPluginInsertSlots(…)`: `guard !slots.isEmpty else { return .success(HonestContract.encodeV2StateB(reason: .readbackUnavailable, extras: […]))}` mirroring the existing State B extras conventions in this function (operation/track/plugins_source/plugins_fetched_at/plugins_unknown_reason/what_was_attempted/what_was_observed/recovery_hint/safe_to_retry + reveal diagnostics per AC-4).
2. Wire the exact reason string `insert_section_not_enumerable` (new enumerated value documented in the tool description if other `plugins_unknown_reason` values are listed there — check `PluginsDispatcher.swift` description and docs).
3. CHANGELOG entry (behavior change, honest direction; non-breaking).

### 4.3 Refactor Phase
- None.

## 5. Edge Cases
- EC-1 (PRD E2): Master/VCA strip → State B (test #1).
- EC-2 (PRD E10): future drift → State B honesty (the whole point of this ticket).

## 6. Review Checklist
- [ ] Red: 테스트 #1/#2/#5/#6/#7/#9 FAILED on this branch(post-T1) 확인; #3/#4 PASS (State A floor 픽스처 핀), #8 PASS (T1 회귀 핀 — T1이 먼저 선택을 고치므로 red 불가; boomer R2b-#2 disposition)
- [ ] Green: PASSED
- [ ] AC 전부 충족 (AC-5는 PR 본문 문서화로 충족)
- [ ] 기존 테스트 깨지지 않음
- [ ] HC v2 State B 인코딩 컨벤션 준수 (`HonestContractV2Tests` 패턴)
- [ ] 불필요한 변경 없음
