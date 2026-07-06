# T9: Docs + E2E — SETUP anchors/prose, TROUBLESHOOTING, CHANGELOG, CI-honesty test, live E2E, final 26-id lock

**PRD Ref**: PRD-doctor-v3 > §8.4 (CI-honesty), §8.5 (Docs M8), §8.6 (Live E2E R3/R15), §9.1 (migration + behavior change), §11 (success metrics), §4.3 (final 26-id array), R14 (exit conventions)
**Priority**: P1 (High) — release gate; depends on all check tickets
**Size**: M
**Status**: Todo
**Depends On**: T1, T2, T3, T4, T5, T6, T7, T8

---

## 1. Objective

Close the feature: land the docs (SETUP.md v3 prose + 13 new anchors + exit-code conventions/CI snippet, TROUBLESHOOTING triage entries, CHANGELOG behavior notes + the stale Formula comment fix), the hermetic CI-honesty test (+ the honest Logic-absent companion), and the live E2E on this Mac reproducing the §11 acceptance set — plus the **final lock** of the exact-26-id array (27 with `--check-updates`) and the anchor-lint at 26 entries.

## 2. Acceptance Criteria

- [ ] AC-1 (SETUP anchors, M8): `docs/SETUP.md` §Doctor gains the **13** new `<a id>` anchors + `### check.id` headings (slugs below); the anchor-lint test (SetupDoctorTests.swift:203-213) passes at **26** entries in `remediationAnchorsByCheckID`.
- [ ] AC-2 (SETUP prose, M8): bump v2→v3 (line ~139 superset note gains `blocked_by` + `fix_plan`); document `--strict` + the exit matrix; add the **exit-code conventions (R14)**: `2`/`3` are status codes not usage errors and sit below `sysexits.h` 64–78; test non-zero for a boolean; `set -e` caveat (`doctor --strict || rc=$?`); a copy-paste CI snippet branching on `0/1/2/3`. **OBJ-D: PRD §9.1의 4행 소비자 호환성 매트릭스(exact-13-array/strict validator/skipped-count alarm/fix_plan-미인지 UI)를 SETUP §Doctor 호환 노트에 수록.**
- [ ] AC-3 (TROUBLESHOOTING): add the **PostEvent** (CGEvent-dead), **stale-install**, and **cross-context** (I-granted-it-but-it-fails) triage entries.
- [ ] AC-4 (CHANGELOG + migration, §9.1): behavior notes — higher `skipped` baseline is expected (not a regression); the **one documented behavior change**: `--check-permissions` now folds PostEvent into `allGranted` (Accessibility+Automation-granted-but-PostEvent-denied host now exits 1, was 0). Update the stale **Formula `test do` comment** ("exit 0 when Accessibility+Automation granted") post-fold.
- [ ] AC-5 (CI-honesty test, §8.4/C8): a hermetic `Runtime`+`PermissionStatus` fixture modeling **diagnostic-capability absence** (TCC.db unreadable, FDA absent, brew absent, sqlite3 absent, Logic **not running**) with **subject present** (Logic.app fileExists=true, binary resolves) and **all four permissions fixed `granted`** (`accessibility`+`automation_logic_pro`+`automation_system_events`+`postEvent`). Assert: **no new check `fail`s on account of absent diagnostic capability**; infra-gated checks are `skipped`/`manual`/`pass`; aggregate is `degraded`/`manual_action_required`, **never a spurious `failed`**.
- [ ] AC-6 (honest companion, D7/OQ-1): a **separate** test — Logic **absent** ⇒ `logic.installation=fail` + `logic.version_support=skipped bb=logic.installation` + `logic.blocking_dialog=skipped` + aggregate `failed` (correct, not a C8 violation).
- [ ] AC-7 (final id lock): exact-id array test pinned to the **26** ids in §4.3 order; **27** with `--check-updates`; summary count invariant holds for 26 and 27; schema `…v3`; FrozenV1 (11 ids) + FrozenV2 decode still green.
- [ ] AC-8 (live E2E, §8.6/§11): a fresh `.build/release` run on this Mac reproduces the §11 acceptance set (stale-install `warn` naming both versions, share-dir `warn`, PostEvent honest, `launch_context` stated, keycmd/mcu `manual`, Fix Plan status-ordered with the headline id `== fix_plan[0]`). **Release gate (R15):** on an FDA-present dev Mac assert `permissions.tcc_cross_context` is **non-`skipped`**. **Read-only proof (R3):** assert **no `-wal`/`-shm`/`-journal` sidecar** created next to either TCC.db.

## 3. TDD Spec (Red Phase)

> The docs-anchor + exact-id + count tests are **contract tests** that go red the moment the anchors/ids are incomplete; author them to the final 26 so they gate the whole feature. The CI-honesty tests reuse the hermetic builders. The live E2E is a **script + procedure**, not a `swift test` unit — it runs the release binary directly (inherits Accessibility via the trusted-terminal parent; no MCP session needed for the CLI path).
> **dead-`#expect` 금지** (R6): concrete statuses; the CI-honesty test asserts `report.status != .failed` (force form), not `#expect((status == .failed) == false)`.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t9_setup_contains_every_remediation_anchor_26` | Contract | AC-1 | extends SetupDoctorTests.swift:203-213 — all 26 `remediationAnchorsByCheckID` slugs exist as `id="…"` in SETUP.md |
| 2 | `test_t9_exact_26_id_order` | Contract | AC-7 | exact-id array == the §4.3 26-id order |
| 3 | `test_t9_27_ids_with_check_updates` | Contract | AC-7 | with `--check-updates`, `updates.latest_release` appended last ⇒ 27 |
| 4 | `test_t9_summary_count_invariant_26_and_27` | Contract | AC-7 | `total == sum == checks.count` for 26 and 27 |
| 5 | `test_t9_schema_and_frozen_decode_still_green` | Contract | AC-7 | schema `…v3`; FrozenV1 (11 ids) + FrozenV2 decode pass |
| 6 | `test_t9_ci_honesty_no_spurious_failed` | Unit | AC-5 / C8 | capability-absent + subject-present + all-perms-granted fixture ⇒ no new check `.fail` for absent capability; aggregate `degraded`/`manualActionRequired`, **never** `.failed` |
| 7 | `test_t9_ci_honesty_infra_checks_skipped_or_manual` | Unit | AC-5 | N8/N10/N11/N12 etc. are `skipped`/`manual`/`pass` in that fixture (none `fail` for capability) |
| 8 | `test_t9_honest_logic_absent_is_failed` | Unit | AC-6 / D7 | Logic-absent fixture ⇒ `logic.installation=.fail`, `version_support=.skipped bb=logic.installation`, `blocking_dialog=.skipped`, aggregate `.failed` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — cases 1–3 (anchor lint + exact-id lock).
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 4–8 (count invariant + frozen decode + CI-honesty + honest companion).
- `Scripts/` — live E2E driver (see §4).

### 3.3 Mock / Setup Required
- CI-honesty fixture: an `enterpriseRuntime`-style builder with **all** new seams set to capability-absent (Logic not running, TCC unopenable, brew/sqlite3 absent, share unresolved) while `fileExists(Logic.app)=true` + binary resolves, paired with `granted(postEvent:true, …)` (all four permissions granted). This isolates diagnostic-capability absence.
- Honest companion: same but `fileExists(Logic.app)=false` and Accessibility can be denied (a real bare runner) — asserts the honest `failed`.
- Live E2E: `swift build -c release` then run `.build/release/LogicProMCP doctor --json` (+ `--strict`, `--check-updates`) and assert on the JSON; capture a green transcript for the release evidence.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `docs/SETUP.md` | Modify | §Doctor: v2→v3 prose + superset note (`blocked_by`/`fix_plan`); `--strict` + exit matrix + R14 conventions + CI snippet; **13** new `<a id>` anchors + `### check.id` headings |
| `docs/TROUBLESHOOTING.md` | Modify | PostEvent / stale-install / cross-context triage entries |
| `CHANGELOG.md` | Modify | v3 behavior notes (higher `skipped` baseline; the `--check-permissions` PostEvent-fold behavior change) |
| `Formula/logic-pro-mcp.rb` | Modify (comment only) | update the stale `test do` comment re: PostEvent fold |
| `Tests/LogicProMCPTests/SetupDoctorTests.swift` | Modify | final 26/27 id lock + anchor-26 lint |
| `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` | Modify | count invariant 26/27 + CI-honesty + honest companion |
| `Scripts/doctor-v3-live-e2e.*` | Create | live driver + assertions for the §11 acceptance set, N10 non-skipped (FDA-present), and the no-sidecar proof |

### 4.2 Implementation Steps (Green Phase)
1. **13 SETUP anchor slugs** (must match `remediationAnchorsByCheckID` values added across T2–T7): `doctor-installbinary-inventory`, `doctor-installshare-dir`, `doctor-mcpregistration-target`, `doctor-mcpclaude-desktop-registration`, `doctor-permissionspost-event-access`, `doctor-permissionslaunch-context`, `doctor-permissionstcc-cross-context`, `doctor-logicinstallation`, `doctor-logicversion-support`, `doctor-logicblocking-dialog`, `doctor-channelskeycmd-reference`, `doctor-channelsmcu-wiring-hint`, `doctor-dependenciesclick-fallback`. Add each as `<a id="…"></a>` + `### <check.id>` heading with prose.
2. SETUP v3 prose + exit conventions + CI snippet (branch on `0/1/2/3`; `set -e` caveat; non-zero-for-boolean guidance).
3. TROUBLESHOOTING + CHANGELOG entries; Formula comment fix.
4. Author the CI-honesty + honest-companion tests; the final 26/27 id-lock + count-invariant + anchor-26 tests.
5. Live E2E: build release, run doctor, assert the §11 set + N10 non-skipped (FDA-present dev Mac) + no `-wal`/`-shm`/`-journal` sidecar next to either TCC.db. Capture a **green transcript** committed as release evidence.
6. **Full-suite gate:** `swift test --no-parallel` all green + `swift build -c release` green + docs-anchor lint green (§11 metrics).

### 4.3 Refactor Phase
- Fold the live-E2E assertions into a small reusable script so the release choreography can re-run it (evidence-sync). Do **not** fold doctor into `golden_capture.py` (NG5) — keep targeted assertions.

## 5. Edge Cases
- §8.4 fixture contract: the CI-honesty test claims correctness of diagnostic-capability absence **under a satisfied subject/permission posture** — it is **not** a claim that a bare Accessibility-denied runner passes (that honestly `fail`s; `doctor` is not a CI gate — verified: no `doctor` in `.github/workflows/`).
- Consumer-compat matrix (§9.1): note that a `skipped`-count-alarm consumer should expect a higher baseline (CHANGELOG).

## 6. Review Checklist
- [ ] `swift test --no-parallel` full green + `swift build -c release` green + anchor-lint green
- [ ] Exactly 26 base ids / 27 with `--check-updates`, in §4.3 order
- [ ] 13 SETUP anchors present + `remediationAnchorsByCheckID` at 26
- [ ] CI-honesty: no spurious `failed`; honest companion: Logic-absent `failed` (both green)
- [ ] Live E2E reproduces §11 set; N10 non-`skipped` on FDA Mac; **no TCC sidecar created**
- [ ] Behavior change (`--check-permissions` PostEvent fold) documented; Formula comment fixed
- [ ] no dead-`#expect`

## 7. Out of Scope (explicit)
- **No `system.health` parity for `logic.blocking_dialog`** — recorded as a follow-up issue only (NG1).
- **No fold into `golden_capture.py`** (NG5).
- **No network** beyond the existing opt-in `--check-updates` (NG6).
- **No server runtime change** (NG3).
- **Check logic itself** lives in T2–T7; T9 only pins the final contract, docs, and E2E.
