# Pipeline Status: Doctor v3 — Causal-Chain Diagnostic

**PRD**: docs/prd/PRD-doctor-v3.md (v0.2, Size L)
**Size**: L
**Current Phase**: 4 (ticket review)

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
| T1 | Data-Spine — `blocked_by`/`fix_plan`/schema v3/dep-table/`DoctorTool` allowlist (D10) | Pending | - | Size M · Depends: None · foundation for all |
| T2 | Honesty-Spine — PostEvent (N1)/`allGranted` fold/clamp/fixture migration | Pending | - | Size M · Depends: T1 · closes F1 false-green |
| T3 | Logic-Chain — `LogicProSupport` consts + N2/N3/N4 | Pending | - | Size M · Depends: T2 · array +3 |
| T4 | Install-Chain — N7 `strings`-ranking + N8 ship-list/Formula drift | Pending | - | Size M · Depends: T2 · array +2 · highest-leverage |
| T5 | MCP-Chain — N5 registration_target + N6 claude_desktop_registration | Pending | - | Size M · Depends: T2 · array +2 |
| T6 | Channels-Deps — N11 keycmd + N12 mcu_wiring_hint + click_fallback | Pending | - | Size M · Depends: T2 · array +3 |
| T7 | TCC-Context — N9 launch_context + N10 tcc_cross_context | Pending | - | Size M · Depends: T1 (T2 posture) · array +2 |
| T8 | CLI-UX — `--strict` matrix + Fix Plan human render + usage text | Pending | - | Size M · Depends: T1 (final render after T3–T7) |
| T9 | Docs + E2E — SETUP/TROUBLESHOOTING/CHANGELOG + CI-honesty + live E2E + 26-id lock | Pending | - | Size M · Depends: T1–T8 · release gate |

## Dependency Graph & Execution Order

```
T1 (foundation)
 └─ T2 (honesty-spine)
     ├─ T3  ┐
     ├─ T4  │  parallel-capable (each depends on T2; distinct check inserts,
     ├─ T5  │  stable insertion anchors → converge to §4.3 26-id order)
     ├─ T6  │
     └─ T7  ┘  (T7 semantically T2-independent; sequenced for fixture posture)
           └─ T8 (renders T1 fix_plan; final render validated once T3–T7 land)
                 └─ T9 (docs + CI-honesty + live E2E + final 26/27 id lock)
```

- **Growing array**: each check ticket updates the exact-id array + count assertions by its own additions (T2 +1, T3 +3, T4 +2, T5 +2, T6 +3, T7 +2 = 13 new); **T9 pins the final 26** (27 with `--check-updates`).
- **Insertion anchors** (stable, order-independent): T2 after `automation_system_events`; T7 after `post_event_access` before `system.macos_version`; T3 `installation`/`version_support` before `application_state`, `blocking_dialog` after it; T4 after `install.source`; T5 after `mcp.claude_code_registration`; T6 after `channels.manual_validation`.
- **Shared invariants owned by T1** (consumed later): `blockedByDependencies` table + `status(of:in:)`; `check(...,blockedBy:)`; `computeFixPlan` (ordered array); `DoctorTool` allowlist + `Process`-lint.

## Review History

| Phase | Round | Verdict | P0 | P1 | P2 | Notes |
|-------|-------|---------|----|----|-----|-------|
| 4     | 1     |         |    |    |     | ticket review (pending) |
| 6     | 1     |         |    |    |     | code review (pending) |
