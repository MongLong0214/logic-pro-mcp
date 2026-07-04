# T3: Plugin-Editor Window ≠ Blocking Modal (Distinct Classification)

**PRD Ref**: PRD-issue-234-mixer-strip-selection-12-3 > US-4 (AC-4.1~4.5), D4/D7
**Priority**: P1 (High)
**Size**: M (2-4h)
**Status**: Todo
**Depends On**: None (parallel to T1/T2; merged in the same PR)

---

## 1. Objective

Stop classifying Logic 12.3 plugin-editor windows (`AXWindow subrole=AXDialog`, title = track name, plugin chrome) as blocking modal dialogs, so unrelated ops (`project.save`, `track.select`) proceed while an editor is open — restoring the pre-12.3 baseline for BOTH consumers of `dialogPresent` (dispatcher modal guard AND StatePoller cache lifecycle), while true modals stay blocking (fail-closed).

## 2. Acceptance Criteria

- [ ] AC-1 (PRD AC-4.1, D4 normative signature — boomer R2-#1): Plugin-editor fixture window (subrole `AXDialog` AND window exposes `kAXCloseButtonAttribute` AND direct-children chrome: bypass-labeled `AXCheckBox` AND compare-labeled `AXCheckBox`) → `dialogPresent()` false, `blockingDialogInfo()` nil — asserted through these **public** surfaces (boomer R2-#5: `isBlockingDialogWindow` is private; do not widen visibility unless unavoidable, and then only to `internal` with rationale).
- [ ] AC-2 (PRD AC-4.2): True-modal fixtures stay blocking: (a) save sheet (`AXDialog`, buttons Save/Don't Save/Cancel, no close-button attribute, no plugin chrome); (b) `AXSystemDialog`; (c) titled dialog with OK/Cancel.
- [ ] AC-3 (PRD AC-4.4): Partial chrome stays blocking: bypass without compare; compare without bypass; bypass+compare but **no `kAXCloseButtonAttribute`**; right labels on non-checkbox roles.
- [ ] AC-4: Keyboard-layout overlay exception unchanged (existing tests green).
- [ ] AC-5 (PRD AC-4.5): StatePoller-level pin: with the plugin-editor fixture wired into a fake runtime, `dialogPresent` reports false → cache lifecycle proceeds (12.2 baseline restored; D7 rationale in PRD).
- [ ] AC-6: New LabelSet(s) follow AXLocalePolicy conventions (canonical English + verified variants only; Korean `compare` variant deferred to OQ-1 — unverified locales conservatively remain blocking). Reuse `pluginBypassControl` for bypass matching.
- [ ] AC-7 (live, in T4): with a real editor open on 12.3, `project.save` succeeds and `logic_system health` reports no blocking dialog; with a real save sheet open, ops still refuse.

## 3. TDD Spec (Red Phase)

### 3.1 Test Cases

| # | Test Name | Type | Description | Expected |
|---|-----------|------|-------------|----------|
| 1 | `testDialogPresentFalseWithOnlyPluginEditorOpen` | Unit | App fixture: standard window + editor window per Appendix A (AXDialog subrole, `kAXCloseButtonAttribute` set on the window, bypass+compare checkboxes, sample body children) | `dialogPresent() == false` (FAILS on main) |
| 2 | `testBlockingDialogInfoNilWithPluginEditor` | Unit | Same | `blockingDialogInfo() == nil` (FAILS on main) |
| 3 | `testSaveSheetStillBlocking` | Unit | AXDialog + Save/Cancel buttons, no close attribute, no chrome | blocking (PASSES on main — regression pin) |
| 4 | `testSystemDialogStillBlocking` | Unit | AXSystemDialog subrole | blocking (pin) |
| 5 | `testPartialChromeStaysBlocking` | Unit (4 variants — boomer R2-#1) | bypass-only / compare-only / bypass+compare without close attribute / labels on non-checkbox roles | blocking (pins + fail-closed proof for new code) |
| 6 | `testEditorPlusRealDialogStillReportsDialog` | Unit | Editor window AND save sheet both present | `dialogPresent() == true`, info reports the sheet |
| 7 | `testStatePollerCacheLifecycleWithEditorOpen` | Unit | StatePoller runtime with `dialogPresent` wired through the real classifier over the editor fixture | cache clear/poll proceeds (AC-5) |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/AXLogicProElementsDialogFilterTests.swift` (extend — existing dialog-filter suite)
- StatePoller case: `Tests/LogicProMCPTests/StatePoller*` conventions (locate existing suite; add there)

### 3.3 Mock/Setup Required
- `FakeAXRuntimeBuilder`. Editor fixture transcribed from `axdialog234.out` / PRD Appendix A.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Sources/LogicProMCP/Accessibility/AXLogicProElements.swift` | Modify | `isPluginEditorWindow(_:runtime:)` helper + exclusion in `isBlockingDialogWindow` (~158), following the `isKeyboardLayoutOverlayWindow` exception precedent |
| `Sources/LogicProMCP/Accessibility/AXLocalePolicy.swift` | Modify | `pluginWindowCompareControl` LabelSet (canonical "compare", variants: [] until locale-verified per OQ-1, rationale documented) |
| `Tests/LogicProMCPTests/AXLogicProElementsDialogFilterTests.swift` | Modify | §3.1 tests |

### 4.2 Implementation Steps (Green Phase)

1. `isPluginEditorWindow`: window subrole == AXDialog AND window exposes `kAXCloseButtonAttribute` AND among **direct children**: ≥1 `AXCheckBox` whose search text matches `pluginBypassControl` AND ≥1 `AXCheckBox` matching `pluginWindowCompareControl`. Conjunctive; any miss → not an editor (stays blocking). Close conjunct uses the ATTRIBUTE (locale-neutral; live-evidenced by `axdialog234.out` closing the window through it), never the child's `desc='close'` text.
2. `isBlockingDialogWindow` (~163): `return !isKeyboardLayoutOverlayWindow(…) && !isPluginEditorWindow(…)`. Keep helpers private; tests assert via `dialogPresent()`/`blockingDialogInfo()` (boomer R2-#5).
3. No signature change to `dialogPresent`/`blockingDialogInfo`/StatePoller wiring — the classifier fix heals `DispatcherSupport.swift:161`, `StatePoller.swift:51`, `LogicProServer.swift:330` consumers automatically (D7).

### 4.3 Refactor Phase
- None. Do NOT add title-based (track-name) matching — D4 rejected option (a).

## 5. Edge Cases
- EC-1 (PRD E7/E8/E9): editor open during ops; true modal; partial chrome.
- EC-2: editor + real modal simultaneously (test #6).
- EC-3: unverified locale → conservative blocking (AC-6).

## 6. Review Checklist
- [ ] Red: 테스트 #1/#2/#7 FAILED on this branch 확인 (#7은 main에서 editor가 blocking으로 분류되어 StatePoller가 캐시 갱신을 억제하므로 red); #3/#4/#5/#6 PASS (pins — boomer R2b-#3 corrected)
- [ ] Green: 전부 PASSED
- [ ] AC 전부 충족
- [ ] 기존 dialog-filter/StatePoller/#190 진단 테스트 무손상
- [ ] 불필요한 변경 없음 (guard 소비자 시그니처 무변경)
