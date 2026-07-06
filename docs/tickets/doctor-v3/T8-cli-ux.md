# T8: CLI-UX — `--strict` exit matrix, Fix Plan human render (3-tier tags, all modes), usage text

**PRD Ref**: PRD-doctor-v3 > §4.3 (Fix Plan rendering R8/R11 + CLI `--strict` M4 + exit conventions R14), §4.4 D11, US-5/AC-5.1..5.4, US-1/AC-1.3, E1 §1 (usage gap)
**Priority**: P1 (High)
**Size**: M
**Status**: Todo
**Depends On**: T1 (consumes `report.fixPlan`; final render validated once T3–T7 checks exist)

---

## 1. Objective

Make the report scriptable and legible: add `--strict` mapping the aggregate to distinct exit codes without changing any output byte; render the `Fix plan:` section (numbered, 3-tier `[fail]/[warn]/[manual]` status tags, remediation-deduped) in **all three human modes** honoring color and never touching `--json`; and fix the `--help` usage text (`[--strict]` + the omitted `lifecycle` verb).

## 2. Acceptance Criteria

- [ ] AC-1 (`--strict` matrix, AC-5.1): `doctor --strict` exits `0/1/2/3` for aggregate `ok/failed/manualActionRequired/degraded` respectively (mapping in the `doctor` branch, MainEntrypoint.swift:82).
- [ ] AC-2 (default unchanged, AC-5.2/C10): without `--strict`, exit semantics are exactly v2 — `failed`→1, everything else→0.
- [ ] AC-3 (`--json` byte-identical, AC-5.3): `--json` bytes are identical regardless of `--strict`/`--verbose`/`--quiet`/color; `--strict` changes **only** the process exit code, not output.
- [ ] AC-4 (Fix Plan render, R8/R11/D11, OBJ-A amended): `renderHuman` (SetupDoctor.swift:288-321) appends a `Fix plan:` numbered list consuming `report.fixPlan` **in its given order** (T1 already ordered it **2-tier: error tier → warning tier, declared order within** — 3-tier 철회, PRD v0.3 §4.3; T8 does **not** re-sort). Each line carries a **status tag** `1. [fail] …`, `2. [warn] …`, `3. [manual] …` (looked up per id from `report.checks`); repeated remediation strings are de-duplicated. Renders in **default + `--verbose` + `--quiet`** (content is entirely non-`pass`, stays relevant under `--quiet`), honors `useColor` (gated like SetupDoctor.swift:340-347), and is **human-only** — it never affects `--json` bytes.
- [ ] AC-5 (usage text, AC-5.4/E1): `usageText` (MainEntrypoint.swift:226-245) `doctor` line gains `[--strict]`, and the previously-omitted `lifecycle <install|update|uninstall> [--json]` verb form is added.
- [ ] AC-6 (exit-code conventions doc-input, R14): the codes `2`/`3` are status codes, not usage errors, and sit below the `sysexits.h` 64–78 range — **the SETUP.md prose/CI-snippet for this lands in T9**; T8 implements the exit mapping such that those conventions are true (non-zero for a boolean; distinct 2/3).

## 3. TDD Spec (Red Phase)

> Reuse `runEntrypoint(_:permission:runtime:isTTY:env:)` (SetupDoctorEnterpriseTests.swift:369-398) for exit-code + byte-identity tests, and `SetupDoctor.renderHuman(report, mode:useColor:)` directly for render-mode tests. Force aggregates via fixtures (e.g. `permission: granted(accessibility:false)` ⇒ `failed`; `macOSVersion:nil` ⇒ `degraded`; a `manual` check ⇒ `manualActionRequired`).
> **dead-`#expect` 금지** (R6): assert exact exit ints + concrete substrings. The headline coupling test stays in T1 (id-extraction).

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t8_strict_exit_ok_zero` | Integration | AC-1 | all-good + `--strict` ⇒ exit `0` |
| 2 | `test_t8_strict_exit_failed_one` | Integration | AC-1 | aggregate `failed` + `--strict` ⇒ exit `1` |
| 3 | `test_t8_strict_exit_manual_two` | Integration | AC-1 | aggregate `manualActionRequired` + `--strict` ⇒ exit `2` |
| 4 | `test_t8_strict_exit_degraded_three` | Integration | AC-1 | aggregate `degraded` + `--strict` ⇒ exit `3` |
| 5 | `test_t8_default_exit_unchanged_matrix` | Integration | AC-2 | without `--strict`: `failed`→1; `ok`/`degraded`/`manual`→0 (4 sub-assertions) |
| 6 | `test_t8_json_byte_identical_with_strict` | Integration | AC-3 | `doctor --json` == `doctor --json --strict` (string equality); also vs `--verbose`/`--quiet` |
| 7 | `test_t8_fix_plan_rendered_numbered_with_tags` | Unit | AC-4 tags | fixture with fail+warn+manual ⇒ human output contains `Fix plan:` then numbered lines each carrying its `[fail]`/`[warn]`/`[manual]` tag; **order = report.fixPlan (2-tier: fail 먼저, warn·manual은 선언순 혼재 가능)** — 태그 순서가 아니라 fixPlan 순서를 단언 |
| 8 | `test_t8_fix_plan_order_matches_report_fixplan` | Unit | AC-4 no-re-sort | rendered id order == `report.fixPlan` order (consumes, doesn't re-sort) |
| 9 | `test_t8_fix_plan_remediation_deduped` | Unit | AC-4 dedup | two checks sharing a remediation string ⇒ that string rendered once |
| 10 | `test_t8_fix_plan_renders_in_all_three_modes` | Unit | R8 | `Fix plan:` present in default, `.verbose`, `.quiet` |
| 11 | `test_t8_fix_plan_honors_color` | Unit | R8 | `useColor:true` ⇒ ANSI in the fix-plan lines; `useColor:false` ⇒ none |
| 12 | `test_t8_fix_plan_absent_when_empty` | Unit | AC-4 | all-good ⇒ no `Fix plan:` section |
| 13 | `test_t8_fix_plan_not_in_json` | Contract | AC-4 human-only | `--json` bytes contain the `fix_plan` array key but **no** `"Fix plan:"` human string |
| 14 | `test_t8_usage_has_strict_and_lifecycle` | Unit | AC-5 | `MainEntrypoint.usageText` contains `[--strict]` on the doctor line AND `lifecycle <install|update|uninstall> [--json]`. **TR4 폴백**: `usageText`가 private이면 심볼 직접 단언 대신 `runEntrypoint(["LogicProMCP","--help"])` stdout 단언으로 대체 |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–13 (reuse `runEntrypoint` + `renderHuman`).
- `Tests/LogicProMCPTests/MainEntrypointTests.swift` — case 14 (usage text) + the `--strict` routing if entrypoint-level.

### 3.3 Mock / Setup Required
- `runEntrypoint` already threads `arguments`; add `--strict` in the args array. To exercise all four aggregates, drive fixtures: `failed` (accessibility fail), `degraded` (macOSVersion nil ⇒ skipped), `manualActionRequired` (a `manual` check with no fail/never higher-ranked). Note `manual` outranks `warn` in `aggregateStatus` (SetupDoctor.swift:378-379) — pick fixtures accordingly.
- Render-mode tests call `SetupDoctor.renderHuman(report, mode: .default/.verbose/.quiet, useColor: true/false)` directly.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/MainEntrypoint.swift` | Modify | `doctor` branch (:82) — if `--strict`, map `report.status` → `{ok:0, failed:1, manualActionRequired:2, degraded:3}`; else keep `shouldExitWithFailure` (:370-372). `usageText` (:233 doctor line + add lifecycle verb) |
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `renderHuman` (:288-321) — append the `Fix plan:` section after the per-check loop, consuming `report.fixPlan`, with `[status]` tags (look up each id's status in `report.checks`), remediation dedup, color-gated, in all modes |
| Tests (2 files) | Modify | `--strict` matrix + render modes + usage |

### 4.2 Implementation Steps (Green Phase)
1. `renderHuman`: after the existing check loop (:319), if `!report.fixPlan.isEmpty`, append `""` + `"Fix plan:"` + numbered lines. For each `id` in `report.fixPlan`, find its `Check` (status→tag), build `"\(n). [\(status)] \(summary)"` (+ optional remediation line, deduped against a `Set<String>` of already-shown remediation values). Color via the existing `colorSymbol`/reset idiom (:345-347) when `useColor`. **Do not** re-sort — `fixPlan` is already ordered by T1.
2. `MainEntrypoint` doctor branch: add a `--strict` exit map. Keep `--json` write path byte-identical (the exit change is after `writeStdout`, so bytes are untouched — AC-3).
3. `usageText`: append `[--strict]` to the `doctor` line (:233) and add the `lifecycle <install|update|uninstall> [--json]` line (mirror the existing `<install|update|uninstall> --dry-run` line at :235).

### 4.3 Refactor Phase
- Optionally extract `strictExitCode(for: ReportStatus) -> Int32` as a pure fn on `SetupDoctor` (like `shouldExitWithFailure`) so the mapping is unit-testable without the entrypoint. If added, unit-test it directly.

## 5. Edge Cases
- Empty fix plan ⇒ no section (case 12) — consistent with the healthy headline (T1).
- `--strict` + `--json`: only the exit code differs, bytes identical (case 6/13).
- `manual` outranks `warn` in the aggregate (SetupDoctor.swift:378-379) — a report with only `warn`+`manual` is `manualActionRequired` (exit 2 under `--strict`), which is correct.

## 6. Review Checklist
- [ ] Red → Green → Refactor green
- [ ] `--json` bytes byte-identical across `--strict`/`--verbose`/`--quiet`/color (AC-3, cases 6/13)
- [ ] Fix plan is **consumed in order**, not re-sorted (case 8)
- [ ] Fix plan renders in all 3 modes + honors color (cases 10/11)
- [ ] Default exit semantics unchanged (case 5)
- [ ] usage text has both fixes (case 14)
- [ ] no dead-`#expect`

## 7. Out of Scope (explicit)
- **`fix_plan` computation + ordering** are **T1** (T8 renders the already-ordered array).
- **`headline` coupling** is **T1** (id-extraction test lives there).
- **SETUP.md exit-code prose + CI snippet (R14)** are **T9** (T8 only makes the mapping true).
- **No new checks**; **no server runtime / health change** (NG3/NG1).
