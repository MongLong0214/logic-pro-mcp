# PRD: Logic Pro 12.3 Mixer Strip Selection & Insert-Slot Enumeration Recovery (Issue #234)

**Version**: 0.2 (post boomer R1)
**Author**: Fable 5 (orchestrator) — implementation by codex gpt-5.5 xhigh
**Date**: 2026-07-04
**Status**: In Review
**Size**: L
**Issue**: https://github.com/MongLong0214/logic-pro-mcp/issues/234 (thomas-doesburg)

---

## 1. Problem Statement

### 1.1 Background

Issue #234: on **Logic Pro 12.3**, insert-slot AX enumeration returns **0 slots for every track**, blocking the entire `logic_plugins.*` verified apply-back surface (`get_inventory`, `insert_verified`, `set_param_verified`) and legacy `logic_mixer insert_plugin`. Track-header volume/pan AX writes are unaffected. Reported on v3.7.4, Logic 12.3 (English UI), macOS 14.

**Live reproduction (2026-07-04, local Logic Pro 12.3 / macOS 26.3, v3.7.4 binary, scratch project `Untitled 54.logicx`, 1 instrument track + Stereo Out + Master):**

| Call | Observed (verbatim) |
|---|---|
| `logic_plugins get_inventory {track:0}` | `state:"A", success:true, verified:true, plugins:[], complete:true` |
| `logic_mixer insert_plugin {track:0, slot:0, plugin_name:"Gain", confirmed:true}` | `error:"element_not_found", hint:"plugin slot out of range for visible mixer strip", visible_slots:0` |
| `logic_plugins insert_verified {track:0, insert:0, plugin:"Gain", mode:"duplicate_applyback", project_expected_path:<front doc>}` | `state:"C", error:"invalid_params", what_was_observed:"slot 0 is out of range (0 slots)", write_attempted:false` |

All three match the reporter's transcript byte-for-byte in the load-bearing fields.

### 1.2 Problem Definition (root cause — live-confirmed)

Logic Pro 12.3 restructured the mixer AX tree. A production-faithful replica of `AXLogicProElements.getMixerArea` ranking, run against live 12.3, shows **four** mixer-named candidates and the wrong winner:

```
[0] strips=8 kids=8  path=/AXWindow[9]/AXGroup[0]/AXGroup      ← WINNER (WRONG): mixer TOOLBAR
     AXGroup desc='Mixer' (603,405 1317x37)   children: Leave Folder button, Edit/Options/View
     segments, "Sends on Faders:" text+checkbox+popup, Single/Tracks/All radio group,
     strip-type filter group, Narrow/Wide radio group
[1] strips=3 kids=3  path=/AXWindow[9]/AXGroup[1]/AXLayoutArea ← REAL strips container
     AXLayoutArea desc='Mixer' (603,442 1317x638), 3 × AXLayoutItem channel strips
[2] strips=2 inspectorAncestor=true            ← inspector two-strip mixer (correctly excluded)
[3] strips=2 path=/AXWindow[9]/AXGroup         ← outer wrapper AXGroup desc='Mixer' kids=2
```

Two 12.2 assumptions broke:

1. **12.3 exposes the mixer header toolbar as `AXGroup desc='Mixer'`** — a sibling of the strips container, both under a new outer wrapper `AXGroup desc='Mixer'` (12.2 shape per code comment: `AXGroup(desc:'믹서') → AXLayoutArea(desc:'믹서') → AXLayoutItem strips`, no named toolbar sibling).
2. `mixerChannelStrips(in:)` falls back to **all children** when a container has no `AXLayoutItem` children. The toolbar therefore reports `stripCount = 8` (8 toolbar widgets), and `getMixerArea`'s ranking (`stripCount` desc, then `totalChildCount` desc) lets the toolbar **outrank the real container** whenever visible strips ≤ 8. At exactly 8 visible strips the tie also breaks toward the toolbar (DFS collection order). The reporter's 6-track project (6 + Stereo Out + Master = 8 strips) and our 1-track scratch (3 strips) both lose to the toolbar's constant 8.

Every insert consumer resolves strips through this chokepoint (`getMixerArea` → `mixerChannelStrips` → `strips[track]` → `audioPluginInsertSlots`), so each "strip" is actually a toolbar widget with zero recognizable slot children → **0 slots on every track**. Track-header volume/pan use `findTrackHeader*` and never touch `getMixerArea` — exactly the reporter's contrast. With ≥ 9 visible strips the real container would win and the bug would vanish — an insidious track-count dependence.

**Enumeration primitives themselves still work on 12.3.** The real strips contain, as direct children (live dump):

- empty Audio FX slot: `AXButton desc='audio plug-in' help='Audio Effect slot. Insert an audio effect. …' (58x18)` — matched by `audioPluginSlotLabel` ("audio effect" via help) and by the language-neutral frame cluster rule;
- occupied slot shape: `AXGroup` containing `AXCheckBox desc='bypass'` + `AXButton desc='open'` + `AXButton desc='list'` (observed on the instrument slot group `desc='E-Piano'`, same chrome as occupied audio inserts);
- non-slot rows correctly skipped by existing predicates (`MIDI plug-in`, `EQ`, `send button`, `Stereo Output`, `group` popup, automation group, `setting`, meters).

So the fix is **container selection + honesty**, not a rewrite of slot classification.

### 1.3 Impact of Not Solving

- The flagship verified apply-back surface (shipped for Thomas's `apply_moves` workflow) is 100% dead on Logic 12.3 for any project with ≤ 8 visible mixer strips — i.e., almost every real session while Apple's current release is 12.3.
- `logic_plugins get_inventory` returns `state A / verified:true / plugins:[]` on tracks that visibly contain plugins — a **false verified-empty read**. This violates the Honest Contract's core promise (never claim verified knowledge that contradicts reality) even though all *write* paths honestly fail closed.
- Any consumer keying automation off inventory (drift detection, apply-back planning) silently plans against an empty chain.

## 2. Goals & Non-Goals

### 2.1 Goals

- [ ] G1: `getMixerArea`/`mixerChannelStrips` select the true strips container on Logic 12.3 **and** 12.2 shapes, independent of visible strip count (1 through 100+), locale-neutrally (structural, not label-based).
- [ ] G2: `logic_plugins get_inventory` on 12.3 returns the real insert chain (empty rows as `read_status:"empty"` items; occupied rows with names) — reproduction script flips from the §1.1 failures to successes.
- [ ] G3: **Honesty gate**: `get_inventory` can never return State A with zero enumerated slots. Zero slots ⇒ State B `readback_unavailable` with a distinct `plugins_unknown_reason` (e.g. `insert_section_not_enumerable`) and a recovery hint. A healthy strip with a visible Audio FX section always exposes ≥ 1 slot item (the empty append row), so `plugins:[]` under State A becomes structurally impossible.
- [ ] G4: `logic_mixer insert_plugin`, `logic_plugins insert_verified`, `logic_plugins set_param_verified` reach slot addressing on 12.3 (their pre-existing gates unchanged); live E2E inserts Gain on the scratch project and reads it back verified.
- [ ] G5 (secondary, from issue): a plugin editor window (live 12.3 evidence: `AXWindow subrole=AXDialog`, title = track name, chrome incl. close-button attribute + `bypass`/`compare` checkboxes) is recognized as a plugin editor **internally** and excluded from blocking-dialog classification, so unrelated ops (`project.save`, `track.select`) are no longer refused while a plugin window is open. Public behavior (boomer R2b-#4): `dialogPresent()` → false, `blockingDialogInfo()` → nil, health reports no blocking dialog — no wire-shape addition. Unknown/unmatched window shapes keep the current fail-closed "blocking" classification.
- [ ] G6: Regression fixtures for both tree shapes (12.2-style and 12.3-style, built on `FakeAXRuntimeBuilder`) lock the selection, enumeration, honesty-gate, and dialog-classification behaviors; full suite + live 12.3 E2E green.

### 2.2 Non-Goals

- NG1: Reworking slot *classification* predicates (`isOccupiedPluginSlotElement`, `isEmptyAudioPluginSlot`, language-neutral cluster rules) — live evidence shows they work on 12.3 once the right container is selected.
- NG2: Fixing the **pre-existing** instrument-slot misreport (an instrument strip's instrument slot group, e.g. `E-Piano`, has occupied-slot chrome and is counted as an audio insert; audio tracks — the reporter's case — are unaffected). Documented as a follow-up issue; out of scope to keep this fix honest and reviewable.
- NG3: Localizing the new plugin-window chrome labels beyond the AXLocalePolicy pattern's known variants (English canonical + verified Korean where known). Unmatched locales conservatively remain "blocking" — no behavior regression.
- NG4: Any new MCP tool/command surface or wire-shape breaking change. (`plugins_unknown_reason` gains one new enumerated value; State A payload shape unchanged.)
- NG5: Logic ≤ 12.1 support beyond the existing legacy `AXIdentifier=="Mixer"` short-circuit (kept intact for fake trees / older builds).
- NG6 (boomer R1-#1): Mixer **view-mode/filter index fidelity** (Single view or strip-type filters can make visible strip index diverge from project track index). This is a **pre-existing** property of `strips[track]` addressing on 12.2 and every prior release — not introduced or worsened by this fix. Out of scope; filed as a follow-up issue post-merge. Mitigation here: the live E2E preflight asserts the mixer is in "Tracks" view (12.3 exposes the toolbar radio group) so the release gate itself can't be silently mis-indexed.
- NG7 (boomer R1-#2): Scanning a **detached mixer window** (Window > Open Mixer on another display). Pre-existing scope: `getMixerArea` searches `mainWindow()` only; when the in-window mixer pane is hidden the existing reveal path opens it via View > Show Mixer, restoring function regardless of a detached mixer's presence. Unchanged behavior; documented; follow-up only if user demand appears.

## 3. User Stories & Acceptance Criteria

### US-1: Truthful inventory on 12.3
**As a** verified apply-back consumer (Thomas's `apply_moves`), **I want** `get_inventory` to see the real insert chain on Logic 12.3, **so that** apply-back plans against reality.

- [ ] AC-1.1: Given the 12.3 fixture tree (toolbar + wrapper + layout area, 3 strips), when `getMixerArea` runs, then it returns the `AXLayoutArea` strips container (never the toolbar, never the outer wrapper, never the inspector area).
- [ ] AC-1.2: Given the 12.3 fixture strip with `[…, empty audio plug-in row, occupied group "Gain", …]`, when `get_inventory` runs, then State A lists both slots with correct `insert` indices, `read_status`, `occupied`, `name`.
- [ ] AC-1.3: Given a 12.2-shaped fixture (no toolbar sibling; layout area direct child), the same assertions as AC-1.1/1.2 hold (regression).
- [ ] AC-1.4: Given a 12.3 fixture with 9+ strips and given one with 1 strip, selection picks the real container in both (kills the track-count dependence).
- [ ] AC-1.5: Live on Logic 12.3: the §1.1 reproduction script's `get_inventory` returns ≥ 1 slot item for track 0 (the empty Audio FX row) instead of `plugins:[]`.

### US-2: Verified writes reach slot addressing
**As an** MCP client, **I want** `insert_verified` / `set_param_verified` / legacy `insert_plugin` to address real slots on 12.3, **so that** the verified write path works end-to-end.

- [ ] AC-2.1: Given the 12.3 fixture, `insert_plugin {slot:0}` no longer fails `element_not_found/visible_slots:0`; slot resolution finds the empty row (write path beyond resolution exercised live, not in unit fixtures).
- [ ] AC-2.2: Live on 12.3 (scratch project): `insert_verified {track:0, insert:0, plugin:"Gain", mode:"duplicate_applyback", project_expected_path:<path>}` returns State A with post-insert readback showing Gain at insert 0.
- [ ] AC-2.3: Live on 12.3 after AC-2.2: `get_inventory` shows `Gain` occupied at insert 0. (CORRECTED 2026-07-05: a filled strip exposes only its occupied row — the append affordance is a ~9px stub excluded by the pre-existing rule, NG1; a same-session second insert fails honest State C. Evidence `axstrip234-after-gain.out`.)

### US-3: No more false verified-empty (honesty gate)
**As a** Honest Contract consumer, **I want** zero-slot enumerations to be State B, **so that** future AX-tree drift can never again masquerade as a verified empty chain.

- [ ] AC-3.1: Given any strip whose enumeration yields 0 slots, when `get_inventory` runs, then response is State B `readback_unavailable` with `plugins_unknown_reason:"insert_section_not_enumerable"`, `safe_to_retry:true`, and a recovery hint naming the likely causes (mixer layout drift / strip type without inserts, e.g. Master).
- [ ] AC-3.2: State A with `plugins:[]` is asserted impossible at the unit level (the State A encoder path for get_inventory requires ≥ 1 slot).
- [ ] AC-3.3: The toolbar-selected-as-mixer scenario (12.3 tree + OLD selection behavior forced in a fixture) would flow into State B, not State A — proven by a fixture that feeds a zero-slot "strip" through the get_inventory path.
- [ ] AC-3.4 (boomer R1-#3): The slot-addressing guards of the **write paths** (`insert_verified` ~line 1021, `set_param_verified` ~line 631, `liveInsertSlot` ~line 1588, legacy `insert_plugin` visible-slots error) distinguish **zero enumerable slots** from **index beyond a non-empty chain**: zero-slot failures stay State C (writes never soften to B) but carry `what_was_observed` naming `insert_section_not_enumerable` semantics plus the same recovery hint as AC-3.1, instead of the bare "slot N is out of range (0 slots)". `fullStripInventory` needs no gate: insert/param State A already requires post-write observed readback of the requested plugin at the requested slot, so a blind tree cannot false-succeed (OQ-2 resolved — rationale locked here).

### US-4: Plugin editor window ≠ blocking modal (secondary, issue's "Secondary observation")
**As a** user who leaves plugin editor windows open, **I want** unrelated ops to proceed, **so that** the v3.7.2 modal guard only blocks on true modals.

- [ ] AC-4.1: Given fixture windows `subrole=AXDialog` with the normative plugin-window chrome (D4 amended: `kAXCloseButtonAttribute` present + bypass checkbox + compare-OR-link checkbox — both live shapes: the Deluxe editor with compare, and the fresh Gain editor with link only), `blockingDialogInfo`/`dialogPresent` classify them non-blocking — asserted through these public surfaces.
- [ ] AC-4.2: Given fixture windows for true modals (save sheet: AXDialog with OK/Cancel-style buttons and no plugin chrome; System Events dialog), classification remains **blocking** (regression).
- [ ] AC-4.3: Live on 12.3: with a plugin editor window open, `project.save` succeeds; with it closed, behavior unchanged. (Reference evidence: live dump 2026-07-04 — editor window is `AXDialog`, title 'Deluxe Classic' = track name.)
- [ ] AC-4.4: A window matching *some but not all* of the plugin-chrome signature stays blocking (fail-closed conservatism) — variants: bypass without compare-or-link, link/compare without bypass, full checkbox chrome but **no close-button attribute**, right labels on non-checkbox roles.
- [ ] AC-4.5 (boomer R1-#4): `StatePoller` semantics are explicit and test-pinned: with a plugin-editor fixture window present, `dialogPresent()` reports **false** (cache lifecycle proceeds normally). Rationale for not splitting "blocking" from "occlusion": plugin editor windows predate 12.3 and were **never** AXDialog-classified before 12.3 (the v3.7.2 guard shipped against 12.2 where editors are plain windows — this is why the reporter hit the false-block only on 12.3). Excluding them from `dialogPresent` for *both* consumers restores the 12.2 baseline exactly; keeping them cache-occluding would *introduce* a new 12.3-only behavior divergence, not preserve one.

## 4. Technical Design

### 4.1 Architecture Overview (chokepoint chain)

```
getMixerArea (AXLogicProElements.swift:616)
  ├─ legacy short-circuit: AXIdentifier=="Mixer" (KEEP — fake trees/old builds)
  └─ mixerAreaCandidates → collectMixerAreaCandidates (depth ≤ 12)
       gate: isMixerNamedElement + isMixerContainerRole + hasDirectChannelStripChildren
       rank: stripCount desc, totalChildCount desc          ← BUG LIVES HERE
  → mixerChannelStrips (AXLayoutItem filter, ELSE all-children fallback)  ← AND HERE
  → strips[track] → audioPluginInsertSlots / findVolumeFader / findPanControl
Consumers: defaultGetPluginInventory, performVerifiedParamWrite, defaultInsertVerified,
liveInsertSlot, fullStripInventory (+VerifiedPlugins.swift 150/627/1007/1586/1981),
AccessibilityChannel.swift 2061/2094/2195/2276, findFader/findPanKnob.
One fix point heals all consumers.
```

### 4.2 Data Model Changes

None on disk. Wire: `plugins_unknown_reason` gains value `insert_section_not_enumerable` (State B). Plugin-editor recognition is **internal only** (boomer R2b-#4): editors simply stop appearing as blockers — `dialogPresent()` false, `blockingDialogInfo()` nil, no new wire field. No State A shape change.

### 4.3 API Design

N/A — no new endpoints/commands. Behavior deltas only (G2/G3/G5), all in the honest direction.

### 4.4 Key Technical Decisions

| Decision | Options Considered | Chosen | Rationale |
|----------|-------------------|--------|-----------|
| D1: Strip-ness for candidate ranking | (a) exclude toolbar by widget labels; (b) prefer AXLayoutArea role; (c) require a deep strip signature (fader/name-field descendants); (d) count only **`AXLayoutItem` children** for candidate eligibility + `stripCount` ranking | (d) | (a) locale-fragile whack-a-mole; (b) insufficient alone (inspector is also an AXLayoutArea); (c) breaks existing minimal fixtures that model strips as bare `AXLayoutItem`s (`Tests/…/PluginGetInventoryTests.swift makeMixerFixture`) and adds cost without need; (d) is locale-neutral, zero fixture breakage, and per live 12.3 dumps the toolbar and outer wrapper have **zero** `AXLayoutItem` children while every real strips container (12.2, 12.3, inspector) is `AXLayoutItem`-parented. Future exotic drift is backstopped by D3's honesty gate, not by deeper heuristics |
| D2: `mixerChannelStrips` all-children fallback | (a) delete fallback; (b) keep globally; (c) keep ONLY for the legacy `AXIdentifier=="Mixer"` path (and thus fake trees/old builds), never for name-based candidate discovery/ranking | (c) | Fake test trees and pre-12.2 builds rely on the identifier path; name-based candidate discovery is where the fallback lies about strip count (toolbar widgets counted as 8 "strips") |
| D3: Honesty gate location | (a) inside `audioPluginInsertSlots`; (b) in `defaultGetPluginInventory` (and slot-addressing gates) where State is encoded | (b) | The enumerator legitimately returns [] for non-strip elements; only the op layer knows "this was supposed to be a track strip" and owns HC state encoding |
| D4: Plugin-editor detection (amended 2026-07-05 after T4 live) | (a) window title == track name (needs track lookup, ambiguous); (b) chrome signature: AXDialog subrole + window exposes `kAXCloseButtonAttribute` (locale-neutral structural conjunct; live-evidenced — the 2026-07-04 probe closed the editor via exactly this attribute) + bypass-labeled toggle + **compare-OR-link**-labeled toggle, where a toggle is an `AXCheckBox` **or** `AXButton` direct child (LabelSets, conjunctive; T4 live evidence: `axwhy234.out` — a freshly-inserted Gain editor exposes only link+bypass, Compare being preset-state-dependent chrome; `axwhy234b.out` — the SAME window's toggles role-flap `AXCheckBox`↔`AXButton` with window key/focus state, so a checkbox-only role filter missed unfocused editors and live `project.save` was refused twice before this final form); (c) treat all AXDialogs with sliders as editors | (b) | (a) races renames and duplicates; (c) over-broad (a real modal could host a slider). (b) is Logic's own plugin-window chrome, stable across plugins, fail-closed on partial match, extensible per-locale via AXLocalePolicy. The close conjunct is the ATTRIBUTE, not the child button's localized `desc='close'` text (locale-fragile); true modal sheets do not expose a close button, adding a structural discriminator on top of the two checkbox labels |
| D5: Where E2E truth comes from | (a) unit fixtures only; (b) fixtures + live 12.3 probe replay (same script as reproduction) — **on a fresh audio track** (boomer R1-#6: the scratch instrument strip's instrument slot has occupied-slot chrome and would contaminate Gain readback assertions; the reporter's setup is audio tracks) | (b) | This bug class (Apple AX drift) is exactly what fixtures can't discover — the repro script doubles as the verification harness, per repo live-verify practice |
| D6: Zero-slot reason granularity (boomer R1-#5) | (a) split reasons (`insert_section_hidden` / `strip_has_no_inserts` / drift) with `safe_to_retry:false` for permanent strip types; (b) single `insert_section_not_enumerable` + `safe_to_retry:true` + hint naming both causes | (b) | (a) requires *distinguishing* Master-type strips from label/role drift — but the only distinguishing markers (audio plug-in / MIDI plug-in / EQ rows) are exactly the things drift destroys, and strip names are locale-dependent and user-renamable. Claiming `strip_has_no_inserts` on evidence we cannot verify would be a new false-confidence channel — the opposite of this PRD's honesty goal. Retry after revealing/reconfiguring is legitimately possible; retry on Master is a harmless no-op |
| D7: Plugin-editor exclusion breadth (boomer R1-#4) | (a) non-blocking for dispatcher guard, still occluding for StatePoller; (b) excluded from `dialogPresent` for both consumers | (b) | Restores the pre-12.3 baseline (editors were plain windows on 12.2, never dialog-classified); (a) would introduce a novel 12.3-only cache behavior with no 12.2 precedent. AC-4.5 pins it with a StatePoller-level test |

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | Visible strips ≤ 8 (reporter: 8; local: 3) vs ≥ 9 on 12.3 | Same correct container selected (AC-1.4) | P0 |
| E2 | Master/VCA strip addressed (no insert section at all — live dump: Master has 7 children, no audio plug-in row) | `get_inventory` → State B `insert_section_not_enumerable` (never State A empty) | P1 |
| E3 | 12.2-shaped tree (no toolbar sibling) | Selection + enumeration unchanged (AC-1.3) | P0 |
| E4 | Korean UI (`desc='믹서'`, `'오디오 플러그인'`) | Selection is structural (role-based) → locale-immune; slot labels already in LabelSets | P1 |
| E5 | Inspector dual-strip mixer visible while main mixer hidden | Inspector still excluded (existing `mixerInspectorContext` ancestry check unchanged); if no non-inspector candidate: existing `mixer_not_visible` State B reveal path | P1 |
| E6 | Narrow vs wide strip mode (58px vs 67-69px rows live) | Frame-based rules unchanged; both ≥ 44px min width | P2 |
| E7 | Plugin editor open during `get_inventory`/verified writes | Existing `hideAllPluginWindows` step unchanged; with G5 the editor no longer false-blocks unrelated ops | P1 |
| E8 | True modal (save sheet / System Events) while G5 active | Still blocking (AC-4.2, fail-closed) | P0 |
| E9 | Window matching partial plugin chrome (e.g. AXDialog with bypass but no compare) | Blocking (AC-4.4) | P1 |
| E10 | Future Apple drift makes enumeration blind again | Honesty gate: State B with diagnostics, never false State A (US-3) | P0 |
| E11 | Mixer in Single view / strip-type filters off (boomer R1-#1) | Pre-existing index-fidelity limitation (NG6): unchanged by this fix; live E2E preflight asserts Tracks view; follow-up issue filed post-merge | P2 (this PR) |
| E12 | Detached mixer window on second display (boomer R1-#2) | Pre-existing scope (NG7): pane-reveal path restores function; unchanged; documented | P2 (this PR) |

## 6. Security & Permissions

N/A (no auth surface). Risk-adjacent: G5 *relaxes* a guard. Mitigations: conjunctive signature, fail-closed default, AC-4.2/4.4 regression fixtures for true-modal shapes.

## 7. Performance & Monitoring

| Metric | Target | Measurement |
|--------|--------|-------------|
| `get_inventory` p95 latency | No regression vs v3.7.4 (± noise) | live probe timing before/after |
| Candidate walk cost | Strip-signature probes only on mixer-named candidates' direct children, bounded depth ≤ 4 | code review + fixture perf sanity |

Monitoring: State B `insert_section_not_enumerable` occurrences in the wild signal future drift (diagnostics carry reveal strategies + strip census).

## 8. Testing Strategy

### 8.1 Unit Tests (FakeAXRuntimeBuilder fixtures)
- 12.3 window fixture: outer wrapper `AXGroup desc='Mixer'` → [toolbar `AXGroup desc='Mixer'` (8 widgets incl. segments/checkbox/popup), unnamed group → `AXLayoutArea desc='Mixer'` (N AXLayoutItem strips with fader/name/slot rows)] + inspector layout area under an inspector-marked ancestor. Parametrized N ∈ {1, 3, 8, 9, 12}.
- 12.2 window fixture (existing shape) — regression.
- Selection tests: winner assertions per AC-1.1/1.3/1.4; toolbar/wrapper/inspector never win.
- Enumeration tests: slot lists per AC-1.2 incl. drift-safe indices (existing `AXPluginInsertSlotsDriftTests` untouched and green).
- Honesty gate: AC-3.1/3.2/3.3.
- Dialog classification: AC-4.1/4.2/4.4 fixtures (plugin chrome / save sheet / partial chrome).

### 8.2 Integration Tests
- `defaultGetPluginInventory` end-to-end against fixtures (State A with slots; State B zero-slot; State B mixer-hidden unchanged).
- Slot-addressing errors for `insert_verified` (`invalid_params` out-of-range unchanged when slots exist but index too high — with real `available` count now).

### 8.3 Edge Case Tests
Each row of §5 maps to at least one test (E1-E5, E8-E10 unit; E6-E7 live).

### 8.4 Live E2E (Logic 12.3, scratch project — release gate)
On a **fresh audio track** in the scratch project (boomer R1-#6; reporter parity — the instrument strip's instrument-slot chrome would contaminate readback assertions): preflight asserts mixer "Tracks" view via the 12.3 toolbar radio group (NG6 guard) → replay reproduction script post-fix: get_inventory (≥1 slot, all `read_status:"empty"`) → insert_verified Gain State A → get_inventory shows Gain occupied at insert 0 → set_param path reaches slot addressing → plugin window open + `project.save` OK and `dialogPresent` false (G5/AC-4.5) → strict live suite (`Scripts/live-e2e-test.py`) 352/352 baseline preserved (updating any pinned expectations that assert the old dishonest shapes). Instrument-strip inventory is additionally *recorded* (not asserted) as evidence for the NG2 follow-up issue.

## 9. Rollout Plan

### 9.1 Migration Strategy
None. Patch release v3.7.5 (non-breaking; State-B-instead-of-false-A is a bug fix in the honest direction, CHANGELOG-noted).

### 9.2 Feature Flag
None — deterministic structural fix; fixtures cover both tree generations.

### 9.3 Rollback Plan
Single revert of the PR restores v3.7.4 behavior. No data/state to unwind.

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if Delayed |
|-----------|-------|--------|-----------------|
| Live Logic 12.3 session for E2E gate | local (already running) | Ready | Can't certify G2/G4/G5 live |
| codex gpt-5.5 xhigh (implementation) | pipeline | Ready | — |

### 10.2 Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Another 12.3 sub-layout variant in the wild (e.g. Single-view, hidden sections) | Medium | Slot ops degrade | Honesty gate → State B + diagnostics (never false A); reporter offered AX dumps for exotic setups |
| G5 misclassifies a real modal as plugin editor | Low | Guard bypass → op fails mid-dialog | Conjunctive chrome signature + AC-4.2/4.4 + live save-sheet check |
| Fixture drift from reality | Low | False green | Fixtures transcribed from live dumps (this PRD §1.2); live E2E is the release gate |
| Strip-signature probe cost on huge sessions | Low | Latency | Probes bounded to named candidates' direct children, depth-capped |

## 11. Success Metrics

| Metric | Baseline (v3.7.4 on 12.3) | Target | Measurement Method |
|--------|----------|--------|--------------------|
| §1.1 repro script | 3/3 fail (1 falsely-verified) | 3/3 succeed (or honest State C for genuinely invalid asks) | probe replay |
| False verified-empty inventory | Possible (observed) | Structurally impossible | AC-3.2 unit lock |
| Full test suite | 1931+ green | All green + new fixtures | `swift test --no-parallel` |
| Live strict E2E | 352/352 | 352/352 (+ new checks) | `Scripts/live-e2e-test.py` |
| Issue #234 | Open | Closed by PR, reporter-confirmable | GitHub |

## 12. Open Questions

- [ ] OQ-1: Korean/localized label for the plugin-window `compare` checkbox (English UI confirmed live; other locales unverified). Conservative fallback (stay blocking) until confirmed — tracked in the dialog ticket.
- [x] OQ-2: **Resolved** (boomer R1-#3 → AC-3.4): write-path slot-addressing guards gain zero-slot-distinct State C diagnostics in this PR; `fullStripInventory` unchanged (post-write observed-readback already makes false success impossible on a blind tree).
- [ ] OQ-3: File follow-up issues after merge: (a) instrument-slot misreport (NG2), (b) mixer view-mode/filter index fidelity (NG6).

## 13. Review History

| Round | Reviewer | Verdict | Disposition |
|-------|----------|---------|-------------|
| R1 | boomer (codex gpt-5.5 xhigh, read-only) | HAS_ISSUES (4×P1, 3×P2) | #3→AC-3.4 accepted; #4→AC-4.5/D7 (both-consumer exclusion, 12.2-baseline rationale); #6→§8.4 audio-track gate; #7→`axdialog234.out` artifact + Appendix A; #1→NG6/E11 (pre-existing, follow-up); #2→NG7/E12 (pre-existing, documented); #5→D6 (split rejected: indistinguishable without a new false-confidence channel) |

## Appendix A — Plugin-editor window live evidence (boomer R1-#7; `axdialog234.out`, 2026-07-04, Logic 12.3)

```
AXPress open -> success
### WINDOWS AFTER OPEN
AXWindow/AXDialog title='Deluxe Classic' desc='' kids=52 | dialogSubrole=true   ← plugin editor; title = TRACK name
AXWindow/AXStandardWindow title='Untitled 54 - Tracks' desc='' kids=10 | dialogSubrole=false
### PLUGIN-WINDOW CANDIDATE SUBTREE (depth 3, first 60 nodes)
AXWindow/AXDialog title='Deluxe Classic' desc='' kids=52
  AXButton  desc='close'          ← window chrome
  AXButton  desc='toolbar'
  AXCheckBox desc='link'
  AXMenuButton title='100%' desc='view'
  AXCheckBox title=' ' desc='bypass'          ← signature 1
  AXCheckBox title='Compare' desc='compare'   ← signature 2
  AXGroup [AXButton/AXSegment desc='previous' | desc='next']
  AXGroup [Copy | Paste]  AXGroup [Undo | Redo]
  … (plugin body: AXSliders/AXTextFields — 52 children total)
close pressed -> success
```

Fresh-editor variant (T4 live, 2026-07-05, `axwhy234.out` — auto-opened by insert_verified Gain; note NO compare checkbox):

```
WINDOW 'Audio 1' subrole=AXDialog
  kAXCloseButtonAttribute: PRESENT
  direct children: 9
  [0] AXButton desc='close'   [1] AXButton desc='toolbar'   [2] AXCheckBox desc='link'
  [3] AXMenuButton desc='view' title='51%'   [4] AXCheckBox desc='bypass'
  [5] AXPopUpButton   [6] AXGroup   [7][8] AXStaticText
  checkbox descs: ["link", "bypass"]
```

Role-flap variant (`axwhy234b.out`, same 'Audio 1' window minutes later, unfocused): `[4] AXButton desc='bypass' title=' '` — checkbox list shrinks to ["link"]. Toggle roles depend on window key state.

---

**Live evidence artifacts** (scratchpad, 2026-07-04): `axdump234.out` (window census + toolbar dump), `axdump234b.out` (production-replica ranking + full real-container dump), `axdialog234.out` (plugin-editor window chrome), probe outputs (§1.1 table). Baseline: `swift test --no-parallel` → **1955 tests passed** on main (2026-07-04).
