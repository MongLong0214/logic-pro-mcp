# T4: Live Logic 12.3 E2E Replay + Evidence (Release Gate)

**PRD Ref**: PRD-issue-234-mixer-strip-selection-12-3 > §8.4, US-1/2/4 live ACs (AC-1.5, AC-2.2, AC-2.3, AC-4.3, AC-4.5)
**Priority**: P0 (Blocker — release gate)
**Size**: S (< 2h)
**Status**: Todo
**Depends On**: T1, T2, T3

---

## 1. Objective

Prove the fix against the real Logic Pro 12.3 with the same probes that reproduced the defect, on a **fresh audio track** (reporter parity; avoids the NG2 instrument-slot contamination — boomer R1-#6), and keep the strict live suite green.

## 2. Acceptance Criteria

- [ ] AC-1: Preflight — `logic_system health` healthy; scratch project (`Untitled 54.logicx` or fresh bootstrap) frontmost; **audio track created** (`logic_tracks create_audio`); mixer revealed; mixer in "Tracks" view asserted via the 12.3 toolbar radio group (NG6 guard; assert-only, no product code).
- [ ] AC-2 (PRD AC-1.5): `get_inventory {track: <audio>}` → State A, ≥1 slot, all `read_status:"empty"` on the fresh strip. The §1.1 false verified-empty is gone.
- [ ] AC-3 (PRD AC-2.2/2.3): `insert_verified {insert:0, plugin:"Gain", …}` → State A with post-insert readback; follow-up `get_inventory` shows Gain occupied at insert 0 (`plugin_id: logic.stock.effect.gain`). **CORRECTED (live 2026-07-05, `axstrip234-after-gain.out`):** a filled strip does NOT expose a full-height trailing empty row — the append affordance is a ~9px stub excluded by the pre-existing 12.2-era rule (NG1), so a same-session 2nd insert on a filled strip fails honest State C "out of range (1 slots)". The reported bug (0 slots / verified-empty) is fixed; multi-insert stacking is a documented follow-up.
- [ ] AC-4: Legacy `logic_mixer insert_plugin` no longer errors `visible_slots: 0` (either succeeds on an empty slot or fails honestly for a legitimate reason — record verbatim).
- [ ] AC-5 (PRD AC-4.3/AC-4.5-live): With a plugin editor window open (Gain, opened via the slot's own open control or during set_param flow): `project.save` succeeds, `logic_system health` reports no blocking dialog; close editor; with a REAL modal (Cmd+W save sheet on a dirtied doc, per #186-190 sweep technique) ops still refuse and `blockingDialogInfo` reports it; Escape restores.
- [ ] AC-6: `set_param_verified` on Compressor `threshold` (the catalog-supported verified param) reaches slot addressing and beyond — insert Compressor first via insert_verified; record the full verified write/readback result.
- [ ] AC-7: Strict live suite `Scripts/live-e2e-test.py` — 352/352 baseline preserved. **Harden `plugin_inventory_result_ok` (line ~689)**: it currently accepts `plugins: []` (`isinstance(env.get("plugins"), list)`), which is why the strict suite stayed green while #234 was live — add `len(plugins) >= 1` (guaranteed post-fix by the State A floor) so the suite can catch this bug class forever after. Audit for other stale pins (`blocking_dialog` checks at ~650/1356 must still pass with T3 semantics — they use REAL modals, verify).
- [ ] AC-8: Instrument-strip inventory recorded (NOT asserted) as NG2 follow-up evidence. All transcripts saved as PR-body evidence.

## 3. TDD Spec (Red Phase)

N/A in unit terms — this is the live verification ticket (PRD D5). "Red" = the §1.1 reproduction transcript on v3.7.4 (already captured, 2026-07-04); "Green" = the same calls passing post-fix. Scripted, not manual:

| # | Step | Tooling | Expected |
|---|------|---------|----------|
| 1 | probe replay (repro → success) | scratchpad `probe234*.py` pattern against fresh `.build/release/LogicProMCP` | AC-2/3/4 |
| 2 | dialog live checks | `axdialog234.swift` pattern + probe `project.save` | AC-5 |
| 3 | strict suite | `Scripts/live-e2e-test.sh` (repo-standard invocation) | AC-7 |

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change Type | Description |
|------|------------|-------------|
| `Scripts/live-e2e-test.py` | Modify (only if pins exist) | Update pinned expectations to honest post-fix shapes |
| (scratchpad probes) | Create | Not committed; transcripts land in PR body |

### 4.2 Steps
1. Rebuild release binary on the fix branch.
2. Run AC-1..AC-6 sequence; save transcripts.
3. Audit live-e2e-test.py for stale pins; update; run strict suite.
4. Attach evidence to PR; note NG2/NG6 follow-up issue drafts.

## 5. Edge Cases
- Logic must be frontmost for AX keystroke paths (`reference_live_test_footguns`): drive via trusted-terminal parent; no `timeout` cmd on this Mac.
- Do not touch any non-scratch user project; scratch = `Untitled 54.logicx` (created by this pipeline's bootstrap 2026-07-04) or a fresh bootstrap.

## 6. Review Checklist
- [ ] 모든 AC 트랜스크립트 확보 (verbatim)
- [ ] 라이브 352/352 유지
- [ ] false positive 0 (모든 성공은 readback-verified)
- [ ] 에비던스가 PR 본문에 포함됨
