# Issue #234 — Live Evidence Map (Logic Pro 12.3, macOS 26.3)

Each acceptance criterion maps to a committed transcript. All live runs use the freshly-built `.build/release/LogicProMCP` on branch `fix/234-mixer-strip-selection-12-3`, driven over stdio by a trusted-parent probe (AX TCC inherited). "v3.7.4" rows are the pre-fix reproduction.

## Chronology (why there are several transcripts)

The fix landed in stages and **live E2E found two classifier gaps that unit fixtures could not** — this is the record, not a contradiction:

1. `probe234e-initial-run-prefix-gaps.txt` — FIRST run, **before** the two plugin-editor classifier fixes. Shows: get_inventory recovered (AC-1.5/2.2/2.3 green), but (a) a 2nd insert on an already-filled strip fails honest State C, and (b) `project.save` still refused with the editor open. Kept as the gap-finding evidence.
2. Gap A fix (`53bde72`): Compare chrome is preset-state-dependent — a fresh Gain editor has only link+bypass. Signature → bypass + close-attr + (compare|link).
3. Gap B fix (`1e7539e`): editor toggle chrome role-flaps `AXCheckBox`↔`AXButton` with window focus (`axwhy234b.out`). Matcher → AXCheckBox|AXButton.
4. `probe234f-compressor-setparam-green.txt` — Compressor insert + verified `set_param_verified threshold` both **State A** on a fresh strip (AC-6).
5. `probe234-final-green-transcript.txt` — FINAL consolidated run after both fixes: AC-1.5/2.2/2.3 green **and** `project.save` with the auto-opened Gain editor **succeeds** (AC-4.3), health reports no blocking dialog.
6. `probe234k2-real-modal-blocks-e8.txt` — a REAL Save sheet (File ▸ Close Project on a dirty doc) still blocks `track.select` with an identified dialog (E8 / fail-closed regression).

## AC map

| AC | Claim | Evidence (committed) | Result |
|----|-------|----------------------|--------|
| Repro | v3.7.4: get_inventory `plugins:[]` verified-empty; insert "(0 slots)" | PRD §1.1 + `axdump234b.out` (toolbar wins ranking) | reproduced |
| AC-1.5 | 12.3 fresh audio strip → ≥1 empty slot (not `[]`) | `probe234-final-green-transcript.txt` (get_inventory track 3 → 1 slot `read_status:"empty"`) | **PASS** |
| AC-2.2 | insert_verified Gain@0 → State A verified | `probe234-final-green-transcript.txt` (`state:"A"`, `observed_plugin_name:"Gain"@0`, slot-popup anchored) | **PASS** |
| AC-2.3 | post-insert inventory shows Gain occupied@0 | `probe234-final-green-transcript.txt` (Gain `read_status:"ok"`@0) | **PASS** |
| AC-6 | insert_verified Compressor + set_param_verified threshold → State A | `probe234f-compressor-setparam-green.txt` (Compressor@0 State A; threshold `observed_normalized:0.5` ax_plugin_window write+readback State A) | **PASS** |
| AC-4.3 | save with plugin editor open succeeds; health no blocking dialog | `probe234-final-green-transcript.txt` (project.save `success:true` file_mtime verified WITH Gain editor open; health `blocking_dialog_present` absent) | **PASS** |
| E8 | a real modal still blocks + is identified | `probe234k2-real-modal-blocks-e8.txt` (track.select refused, `dialog_role:"AXDialog"`, `recovery_action` present) | **PASS** |
| AC-3 (amended) | after first insert, strip exposes the occupied row; the append affordance is a **9px stub** excluded by the pre-existing rule (NG1), so a same-session 2nd insert on a filled strip fails honest State C — NOT "occupied + trailing empty row" | `axstrip234-after-gain.out` (`AXButton 'audio plug-in' 58x9` stub + `AXGroup 'Gain' 58x16`); `probe234-final-green-transcript.txt` (insert@1 → State C "slot 1 is out of range (1 slots)") | **AMENDED + honest** |
| Strict suite | 369 passed / 1 skipped (#220 popen-only) / 370, hardened non-empty predicate | Phase 6 strict live run (STATUS.md) | **PASS** |

## Honest limitation (follow-up, not the reported bug)

The reported defect — "0 slots for every track; get_inventory returns `[]` on tracks that contain plugins" — is fixed: strips enumerate their real occupied + full-height-empty rows, and the first verified insert works end-to-end. Stacking a **second** new insert onto an already-filled strip in the same session is not addressable through enumeration, because Logic renders the post-fill append affordance as a ~9px stub that the 12.2-era rule intentionally excludes (clicking it mounts into a different real slot). This fails closed with a clear State C message. Candidate follow-up: make the append stub addressable for multi-insert, tracked separately from #234.
