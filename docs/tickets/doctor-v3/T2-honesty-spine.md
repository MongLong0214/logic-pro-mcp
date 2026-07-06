# T2: Honesty-Spine — PostEvent (N1), `allGranted` fold, clamp, fixture migration

**PRD Ref**: PRD-doctor-v3 > §4.2 (PermissionStatus/Runtime seam), §4.3 N1, §4.5 #1, §8.2 fixture migration, G3, US-3/AC-3.1, E10/E11
**Priority**: P0 (Blocker — closes the F1 false-green; establishes the permission posture T3–T7 fixtures depend on)
**Size**: M
**Status**: Todo
**Depends On**: T1

---

## 1. Objective

Close the F1 "connected-but-CGEvent-dead" false-green: add the `permissions.post_event_access` check (N1) fed by a new honest `PermissionChecker.Runtime.postEventPreflight` seam, extend `PermissionStatus` with a PostEvent field whose **honest default is denied (false)**, fold PostEvent into `allGranted` (so `clampStatusForPermissions` can never leave an `ok`-while-CGEvent-dead report), add the `--check-permissions` summary line, and migrate the test fixtures/baselines so all-pass tests stay all-pass.

## 2. Acceptance Criteria

- [ ] AC-1 (N1 check): `permissions.post_event_access` (domain `permissions`, category `permissions`) is inserted **immediately after** `permissions.automation_system_events`. `pass` iff preflight `== true`; else `fail`. evidence `{post_event_access:"granted"|"denied"}`; remediation `system_settings`; `blocked_by` none.
- [ ] AC-2 (seam + same-measurement): `PermissionChecker.Runtime` gains `postEventPreflight: @Sendable () -> Bool`, defaulted in `.production` to `{ CGPreflightPostEventAccess() }`. The **same** measurement feeds both N1 and `PermissionStatus.postEventAccessState` (one source of truth).
- [ ] AC-3 (honest default): every new `PermissionStatus` init parameter and the new `Runtime` param default to the **denied/false** posture (mirrors `systemEventsAutomationState = .notVerifiable`, PermissionChecker.swift:102). Legacy 2-/3-arg `PermissionStatus(...)` constructions keep compiling **and** never report a `granted` PostEvent they did not measure. Production `check(runtime:)` (PermissionChecker.swift:207-213) sets the **real** preflight value, not the default.
- [ ] AC-4 (fold): `allGranted` (PermissionChecker.swift:121) becomes `accessibility && automationLogicPro && automationSystemEvents && postEventAccess`. AC-3.1: PostEvent-denied ⇒ `allGranted == false` ⇒ clamp ⇒ aggregate never `ok`.
- [ ] AC-5 (summary): `PermissionStatus.summary` (:123-151) gains a PostEvent line; on denial the N1 check summary states "CGEvent-family ops (transport.stop/pause + most edit/view/track fallbacks) will fail" (RoutingTable.swift:20,29,177-217).
- [ ] AC-6 (`--check-permissions` behavior change, E11): a host with Accessibility+Automation granted but PostEvent denied now exits **1** (was 0) via `MainEntrypoint.swift:171`. Documented in T9.
- [ ] AC-7 (fixture migration, §8.2): `grantedPermissionStatus()` (SetupDoctorTests.swift:53) and `granted(...)` (SetupDoctorEnterpriseTests.swift:35-45) set `postEvent = granted`; the positive `allGranted` assertions at `ProductionReadinessTests.swift:311` and `ProcessUtilsTests.swift:289` are updated to construct a PostEvent-granted status; every `.ok`/exit-0 baseline stays green. **OBJ-C 검증-전용 스윕 (마이그레이션 불요 — 정직-기본값 하 negative/무영향 자세임을 구현 시 재확인만)**: ProductionReadinessTests.swift:314(:318 negative), CommercialReadinessTests.swift:435(:436 negative)·:442(summary-contains), SetupDoctorEnterpriseTests.swift:273(개별 체크 상태만 단언 — N1=fail이 돼도 두 단언 불변), ProcessUtilsTests.swift:297(:299 negative). 전수 근거: `grep -rn "PermissionStatus(" Tests/`.
- [ ] AC-8 (array grows +1): the exact-id array (SetupDoctorTests.swift:83-97) grows to 14 with `permissions.post_event_access` after `automation_system_events`; count assertions (SetupDoctorEnterpriseTests.swift:152,155) → 14 / 14.0.

## 3. TDD Spec (Red Phase)

> Fixture reuse: `granted(...)` builder (SetupDoctorEnterpriseTests.swift:35-45) — add a `postEvent:` parameter. Drive N1 via `permission: granted(postEvent:false)`.
> **dead-`#expect` 금지** (PRD R6): force-unwrap / 구체형만. e.g. assert `c.status == .fail`, not `#expect((c.status == .fail) == true)`.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t2_post_event_pass` | Unit | N1 pass path | `granted(postEvent:true)` ⇒ `check(report,"permissions.post_event_access").status == .pass`; evidence `post_event_access == "granted"` |
| 2 | `test_t2_post_event_fail` | Unit | N1 fail path | `granted(postEvent:false)` ⇒ `.fail`; evidence `== "denied"`; summary contains `"CGEvent"` |
| 3 | `test_t2_post_event_category_permissions` | Unit | taxonomy | check `.category == .permissions`, `.severity == .error` on fail |
| 4 | `test_t2_all_granted_includes_post_event` | Unit | AC-4 fold | `granted(postEvent:false).allGranted == false`; `granted(postEvent:true).allGranted` holds (force-unwrap style) |
| 5 | `test_t2_honest_default_is_denied` | Unit | AC-3 honest default | a `PermissionStatus` built by the legacy init (no postEvent arg) reports `postEventAccess == false`; the derived N1 check is `.fail`, **never** `.pass` |
| 6 | `test_t2_clamp_off_ok_when_post_event_denied` | Unit | AC-4 clamp | full report with all else granted but `postEvent:false` ⇒ `report.status != .ok` (extends SetupDoctorEnterpriseTests.swift:540-549 intent) |
| 7 | `test_t2_seam_feeds_both_check_and_all_granted` | Unit | AC-2 one source | inject `postEventPreflight: { false }` in `PermissionChecker.Runtime`; `PermissionChecker.check(runtime:)` yields `postEventAccess == false` AND N1 `.fail` from the same value |
| 8 | `test_t2_check_permissions_exit_1_on_post_event_denied` | Integration | AC-6 / E11 | `runEntrypoint(["LogicProMCP","--check-permissions"], permission: granted(postEvent:false))` returns exit `1`; granted ⇒ `0` |
| 9 | `test_t2_summary_line_mentions_post_event` | Unit | AC-5 | `granted(postEvent:false).summary` contains a PostEvent line |
| 10 | `test_t2_array_grows_post_event_after_system_events` | Contract | AC-8 order | exact-id array now 14; `post_event_access` immediately follows `automation_system_events` |
| 11 | `test_t2_count_invariant_14` | Contract | AC-8 count | `report.checks.count == 14`; `total == sum == checks.count` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–7, 9, 10, 11 (+ extend `granted` builder with `postEvent:` param).
- `Tests/LogicProMCPTests/PermissionCheckerTriStateTests.swift` (or `PermissionCheckerTests.swift`) — case 7 (seam wiring against a fake `postEventPreflight`).
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — case 8 uses the `runEntrypoint`-style path; update the exact-13→14 array (:83-97) and `grantedPermissionStatus` (:53).
- `Tests/LogicProMCPTests/ProductionReadinessTests.swift` (:311) + `ProcessUtilsTests.swift` (:289) — migrate positive `allGranted` constructions.

### 3.3 Mock / Setup Required
- Extend `granted(...)` (SetupDoctorEnterpriseTests.swift:35-45) with `postEvent: Bool = true` → maps to the new `PermissionStatus` field (default true in *test* builders so healthy baselines stay `.ok`; the **production**/library default stays denied per AC-3).
- Extend `doctorRuntime`/`enterpriseRuntime` **PermissionChecker.Runtime** usage where needed; for N1 the value flows through `PermissionStatus`, so most doctor tests only need the `granted(postEvent:)` knob. The `postEventPreflight` seam is exercised directly in case 7.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Utilities/PermissionChecker.swift` | Modify | `Runtime` +`postEventPreflight` seam (init :60-74, `.production` :76-85 → `{ CGPreflightPostEventAccess() }`); `PermissionStatus` +`postEventAccessState`/`postEventAccess` (honest default denied), extend `allGranted` (:121) + `summary` (:123-151); `check(runtime:)` (:207-213) sets real preflight |
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | add `postEventAccessCheck(_:)` producing N1; insert `checks.append(timed { … })` after the system-events append (generate :252) |
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `remediationAnchorsByCheckID` (:203-217) +`permissions.post_event_access` → `docs/SETUP.md#doctor-permissionspost-event-access` |
| Tests (5 files above) | Modify | fixture migration + N1 tests + array/count bump |

### 4.2 Implementation Steps (Green Phase)
1. `PermissionChecker.Runtime`: add `let postEventPreflight: @Sendable () -> Bool`; give the init a default (`= { false }` honest-denied) so existing constructions compile; `.production` overrides to `{ CGPreflightPostEventAccess() }`. (Note: `import CoreGraphics`/`ApplicationServices` already available — `CGPreflightPostEventAccess` used in SystemDispatcher.swift:212.)
2. `PermissionStatus`: add stored `postEventAccessState: Bool` (or a `CheckState`; a `Bool` matches the preflight's shape). Add both inits' new param **defaulting to false/denied**. Add computed `postEventAccess`. Extend `allGranted` (:121) to `&& postEventAccess`. Append a PostEvent line in `summary`.
3. `PermissionChecker.check(runtime:)` (:207-213): pass `postEventAccess: runtime.postEventPreflight()` into the constructed `PermissionStatus` — the **real** measurement (AC-3 caveat).
4. `SetupDoctor`: add `postEventAccessCheck(_ status:)` → `check(id:"permissions.post_event_access", domain:"permissions", status: status.postEventAccess ? .pass : .fail, summary: …CGEvent…, evidence:["post_event_access": status.postEventAccess ? "granted" : "denied"], remediationType: .systemSettings)`. Insert its `timed { }` append right after `systemEventsAutomationCheck` (generate :252).
5. Add the anchor map entry.
6. **Fixture migration**: `grantedPermissionStatus()` (SetupDoctorTests.swift:53) → include `postEvent: granted`. `granted(...)` builder → `postEvent: Bool = true`. `ProductionReadinessTests.swift:311` + `ProcessUtilsTests.swift:289` positive assertions → construct with PostEvent granted; the negative assertions (:318,:299) stay valid (still not-allGranted for their reasons). Bump exact-id array (14) + count (14 / 14.0).

### 4.3 Refactor Phase
- If `PermissionStatus` uses a `Bool` for PostEvent, keep the summary label consistent with the tri-state ones (plain "granted"/"NOT GRANTED") to match existing `summaryLabel` style.

## 5. Edge Cases
- E10: PostEvent denied + Accessibility granted ⇒ N1 `fail`, `allGranted=false`, aggregate clamped off `ok` (case 6). `dependencies.click_fallback` escalation is **T6** (consumes N1's result).
- E11: `--check-permissions` now exits 1 for Accessibility+Automation-granted-but-PostEvent-denied (case 8) — a corrected false-green; T9 documents it (+ updates the Formula `test do` comment).

## 6. Review Checklist
- [ ] Red → Green → Refactor all green (`swift test --no-parallel` + `swift build -c release`)
- [ ] Legacy `PermissionStatus(...)` / `PermissionChecker.Runtime(...)` construction sites compile unchanged (defaults)
- [ ] Honest default verified: an unset PostEvent reads `denied` (case 5) — no `granted` a production run didn't measure
- [ ] `system.health` PostEvent path (SystemDispatcher.swift:212) untouched (NG1)
- [ ] All prior `.ok`/exit-0 baselines still green after fixture migration
- [ ] No dead-`#expect`

## 7. Out of Scope (explicit)
- **`dependencies.click_fallback`** (its `warn` escalation when PostEvent denied + no cliclick) is **T6**.
- **`system.health` / `SystemDispatcher` change** — NG1. Health keeps computing PostEvent independently.
- **No server runtime change** (NG3); no CGEvent posting — preflight is read-only, no prompt, no side effect.
- **Docs prose / TROUBLESHOOTING entries / Formula comment update** for the E11 behavior change are authored in **T9** (this ticket only makes the behavior true + leaves a `// R9` note at MainEntrypoint.swift:171 if helpful).
