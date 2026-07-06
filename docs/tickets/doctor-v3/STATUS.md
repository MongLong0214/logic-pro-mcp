# Pipeline Status: Doctor v3 — Causal-Chain Diagnostic

**PRD**: docs/prd/PRD-doctor-v3.md (v0.3, Size L)
**Size**: L
**Current Phase**: 6 (production-readiness review) — verified complete 2026-07-06; final production-readiness gate APPROVE

## Ticket Status 정의
- **Pending**: Phase 4 리뷰 대기 (미착수)
- **Todo**: 리뷰 통과, 구현 대기
- **In Progress**: 구현 중
- **In Review**: 리뷰 진행 중
- **Done**: 완료 (AC 충족 + 테스트 PASS)
- **Invalidated**: 역행으로 무효화됨 (Phase 3 역행 시)

## Tickets

| Ticket | Title | Status | Review | Notes |
|--------|-------|--------|--------|-------|
| T1 | Data-Spine — `blocked_by`/`fix_plan`/schema v3/dep-table/`DoctorTool` allowlist (D10) | Done | PASS | Implemented; direct doctor command path now fail-closed through allowlist; focused + full test PASS |
| T2 | Honesty-Spine — PostEvent (N1)/`allGranted` fold/clamp/fixture migration | Done | PASS | Implemented; focused + full test PASS |
| T3 | Logic-Chain — `LogicProSupport` consts + N2/N3/N4 | Done | PASS | Implemented; focused + full test PASS |
| T4 | Install-Chain — N7 `strings`-ranking + N8 ship-list/Formula drift | Done | PASS | Implemented; focused + full test PASS |
| T5 | MCP-Chain — N5 registration_target + N6 claude_desktop_registration | Done | PASS | Implemented; relative commands skipped, regular-file/share-dir checks covered; focused + full test PASS |
| T6 | Channels-Deps — N11 keycmd + N12 mcu_wiring_hint + click_fallback | Done | PASS | Implemented; focused + full test PASS |
| T7 | TCC-Context — N9 launch_context + N10 tcc_cross_context | Done | PASS | Implemented; ancestry-based launch context + read-only TCC mapper covered; focused + full test PASS |
| T8 | CLI-UX — `--strict` matrix + Fix Plan human render + usage text | Done | PASS | Implemented; focused + full test PASS |
| T9 | Docs + E2E — SETUP/TROUBLESHOOTING/CHANGELOG + CI-honesty + live E2E + 26-id lock | Done | PASS | Implemented; final live release E2E captured under `.omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e` |

## Implementation Evidence

- `swift test --no-parallel --filter 'DoctorV3ProductionReadiness|SetupDoctor|DoctorTool|PermissionChecker|VersionConsistency'` — PASS, 136 tests; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/focused-swift-test.log`.
- `swift test --no-parallel` — PASS, 2103 tests; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/full-swift-test.log`.
- `Scripts/doctor-v3-live-e2e.sh .omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e` — PASS; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e`.
- `swift build -c release` — PASS inside live E2E evidence (`.omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e/swift-build-release.log`).
- `.build/release/LogicProMCP doctor --json` — exit 0, schema `logic_pro_mcp_doctor.v3`, 26 checks, local status `manual_action_required`; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/direct-doctor.json`.
- `.build/release/LogicProMCP doctor --strict --json` — exit 2 for the same local manual-action report; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/direct-doctor-strict.json` and `.omo/evidence/doctor-v3-final-20260706T074353Z/direct-doctor-assertions.log`.
- `install.binary_inventory` live regression — PASS: stale Homebrew binary `3.5.0` now reports `warn` with `stale=true`, not `pass/indeterminate`; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e/doctor.json`.
- Share-dir privacy regression — PASS: `install.share_dir` evidence reports source/label only and no raw `LOGIC_PRO_MCP_SHARE_DIR`, `/tmp/share`, or local absolute share-dir path; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/privacy-scan.log`, `.omo/evidence/doctor-v3-final-20260706T074353Z/direct-doctor-assertions.log`, and `Tests/LogicProMCPTests/DoctorV3ProductionReadinessTests.swift`.
- TCC read-only evidence — PASS: sidecar snapshots are label-only and before/after identical; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e/tcc-sidecars-before.json` and `.omo/evidence/doctor-v3-final-20260706T074353Z/live-e2e/tcc-sidecars-after.json`.
- `git diff --check` — PASS; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/git-diff-check.log`.
- `bash -n Scripts/doctor-v3-live-e2e.sh` — PASS; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/doctor-v3-live-e2e-bash-n.log`.
- `ruby -c Formula/logic-pro-mcp.rb` — PASS; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/formula-ruby-c.log`.
- `SetupDoctor.swift` size cleanup — PASS: reduced to 590 total lines / 470 nonblank non-`//` lines, with the largest Doctor extension at 171 nonblank non-`//` lines after domain/support split; evidence: `.omo/evidence/doctor-v3-final-20260706T074353Z/setupdoctor-wc-l.log` and `.omo/evidence/doctor-v3-final-20260706T074353Z/setupdoctor-pure-loc.log`.
- Final review lanes — APPROVE: code quality CLEAR, security/privacy APPROVE with residual WATCH only, QA PASS, docs/status PASS, and final gate APPROVE; evidence: `.omo/evidence/doctor-v3-final-security-privacy-code-review.md` and `.omo/evidence/doctor-v3-production-readiness-final-gate-review.md`.

## Dependency Graph & Execution Order

```
T1 (foundation)
 └─ T2 (honesty-spine)
     ├─ T3  ┐
     ├─ T4  │  semantically independent (each depends on T2; distinct check inserts,
     ├─ T5  │  stable insertion anchors → converge to §4.3 26-id order)
     ├─ T6  │  **랜딩은 순차 필수 (OBJ-E)**: exact-id 배열 리터럴·count 단언·SetupDoctor.swift
     └─ T7  ┘  동일 지점을 매 티켓이 편집 → 병렬 랜딩 시 충돌 확정. (T7은 T2 이후: 픽스처 자세 상속)
           └─ T8 (renders T1 fix_plan; final render validated once T3–T7 land)
                 └─ T9 (docs + CI-honesty + live E2E + final 26/27 id lock)
```

- **Growing array**: each check ticket updates the exact-id array + count assertions by its own additions (T2 +1, T3 +3, T4 +2, T5 +2, T6 +3, T7 +2 = 13 new); **T9 pins the final 26** (27 with `--check-updates`).
- **Insertion anchors** (stable, order-independent): T2 after `automation_system_events`; T7 after `post_event_access` before `system.macos_version`; T3 `installation`/`version_support` before `application_state`, `blocking_dialog` after it; T4 after `install.source`; T5 after `mcp.claude_code_registration`; T6 after `channels.manual_validation`.
- **Shared invariants owned by T1** (consumed later): `blockedByDependencies` table + `status(of:in:)`; `check(...,blockedBy:)`; `computeFixPlan` (ordered array); `DoctorTool` allowlist + `Process`-lint.

## Review History

| Phase | Round | Verdict | P0 | P1 | P2 | Notes |
|-------|-------|---------|----|----|-----|-------|
| 4     | 1     | HAS ISSUE→CONVERGED | 0  | 1  | 3   | TR1-TR4 + OBJ-A~E (orchestrator direct gate; boomer=codex 401·opus killed → 연속성 지침) — 전건 반영, review-tickets-boomer-sub.md |
| 6     | 1     | FAIL    | 0  | 5  | 1   | production-readiness review found T5 relative/regular/share-dir gaps, T7 launch/TCC privacy gaps, T9 docs/live-E2E gaps, and stale status evidence |
| 6     | 2     | APPROVE | 0  | 0  | 0   | blocker fixes verified with final evidence under `.omo/evidence/doctor-v3-final-20260706T074353Z`; code-quality/security/QA/docs/final-gate all approved |
