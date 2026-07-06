# T3: Logic-Chain — `LogicProSupport` constants, N2 installation, N3 version_support, N4 blocking_dialog

**PRD Ref**: PRD-doctor-v3 > §4.2 (V1 constants), §4.3 N2/N3/N4 + `blocked_by` table, §4.4 D1/D7, US-1/AC-1.1, US-3/AC-3.2, E1/E2/E3/E12/E13, OQ-1/OQ-3/OQ-4
**Priority**: P1 (High)
**Size**: M
**Status**: Todo
**Depends On**: T2

---

## 1. Objective

Add the Logic-precondition chain: the `LogicProSupport` version constants (V1) + a consistency test pinning them to `manifest.json`, and three checks — `logic.installation` (N2, direct `Info.plist` read, 3-way status), `logic.version_support` (N3, compares to V1, `blocked_by`-derived from N2), and `logic.blocking_dialog` (N4, reuses `AXLogicProElements.blockingDialogInfo`, `blocked_by`-derived with running-first precedence). This is the first ticket to **consume** the T1 `blocked_by` mechanism.

## 2. Acceptance Criteria

- [ ] AC-1 (V1 constants): `LogicProSupport` with `minimumSupportedLogicVersion = "12.0.1"`, `latestValidatedLogicVersion = "12.3"`, colocated near `ServerConfig` (`Sources/LogicProMCP/Server/ServerConfig.swift`). A `VersionConsistencyTests` case pins `minimumSupportedLogicVersion == manifest.json.min_logic_pro_version` (manifest.json:13 = `"12.0.1"`).
- [ ] AC-2 (N2 3-way, D7/R4): `logic.installation` reads `CFBundleShortVersionString`+`CFBundleIdentifier` from `/Applications/Logic Pro.app` and `~/Applications/Logic Pro.app`. **`pass`** if ≥1 copy found and version reads; **`skipped` `reason:bundle_unreadable`** if a `.app` exists but plist unreadable / version absent (false-red guard); **`fail`** only if neither path holds a `.app` (chain root). Independent of `ProcessUtils.logicProVersion()`; zero side effects.
- [ ] AC-3 (N3 single derivation, R4): if `logic.installation != pass`, `logic.version_support` is **unconditionally** `skipped` + `blocked_by:logic.installation`. When N2 `== pass`: `fail` if `< 12.0.1`; `warn` if `12.0.1 ≤ v < 12.3`; `pass` if `== 12.3`; `warn` if `> 12.3` ("newer than validated; AX tree may differ"). evidence `{detected_version, minimum_supported, latest_validated}`.
- [ ] AC-4 (N4 gated + precedence, OQ-3/OBJ-B): `logic.blocking_dialog` gate = **table-driven** — `blockedByDependencies["logic.blocking_dialog"] == ["logic.application_state", "permissions.accessibility"]`의 첫 non-`pass` 원인이 `blocked_by`가 됨 ⇒ `skipped`. 즉 application_state가 `manual`(미실행)뿐 아니라 `warn`(실행·창 미감지)이어도 block — 보수적·정직(창이 0개면 AX 다이얼로그 프로브 무의미, PRD v0.3 N4 Gate). 게이트 통과 시: `warn` if a blocking dialog present; `pass` if none. evidence (when present) `{dialog_present:"true",dialog_title,role,buttons,recovery_action}`; remediation `manual`.
- [ ] AC-5 (dual-copy tie-break, OQ-4/E1): two copies ⇒ N2 `pass`, evidence `second_copy:"present"`; N3 compares the `/Applications` copy.
- [ ] AC-6 (positions + array +3): `logic.installation` + `logic.version_support` inserted **before** `logic.application_state`; `logic.blocking_dialog` inserted **after** `logic.application_state` and **before** `channels.manual_validation`. Array grows by 3; count assertions bumped accordingly.

## 3. TDD Spec (Red Phase)

> New fixture seams (extend `enterpriseRuntime`/`doctorRuntime`, hermetic-good defaults per §8.2): a Logic `Info.plist` reader (returns `{version, bundleId}?` per path) and a blocking-dialog probe seam (returns `BlockingDialogInfo?`). Defaults: Logic present @ `12.3`, no blocking dialog.
> **dead-`#expect` 금지** (R6): compare concrete statuses / force-unwrap evidence; never `#expect(optBool == true)`.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t3_version_consistency_min_vs_manifest` | Contract | AC-1 | `LogicProSupport.minimumSupportedLogicVersion == "12.0.1"` and `manifest.json` `min_logic_pro_version` equals it (readRepoFile idiom) |
| 2 | `test_t3_n2_pass_single_copy` | Unit | N2 pass | Logic @ `/Applications` reads `12.3` ⇒ `.pass`; evidence `version==12.3`, `bundle_id==com.apple.logic10` |
| 3 | `test_t3_n2_fail_when_neither_path` | Unit | N2 chain root (D7) | no `.app` at either path ⇒ `.fail` (aggregate `failed`) |
| 4 | `test_t3_n2_skipped_bundle_unreadable` | Unit | N2 false-red guard (E13) | `.app` present but plist unreadable / no `CFBundleShortVersionString` ⇒ `.skipped` `reason=bundle_unreadable`, never `.fail` |
| 5 | `test_t3_n2_dual_copy_present` | Unit | AC-5 / E1 | both paths present ⇒ `.pass`, evidence `second_copy=="present"` |
| 6 | `test_t3_n3_skipped_when_n2_not_pass` | Unit | N3 derivation (AC-3) | N2 `fail` or `skipped` ⇒ N3 `.skipped` `blocked_by=="logic.installation"` (both ways) |
| 7 | `test_t3_n3_floor_fail` | Unit | N3 floor | detected `12.0.0` ⇒ `.fail` (`< 12.0.1`) |
| 8 | `test_t3_n3_best_effort_warn` | Unit | N3 mid-band | detected `12.1` ⇒ `.warn` (`12.0.1 ≤ v < 12.3`) |
| 9 | `test_t3_n3_pass_at_latest` | Unit | N3 exact | detected `12.3` ⇒ `.pass` |
| 10 | `test_t3_n3_newer_than_validated_warn` | Unit | N3 upper-band | detected `12.4` ⇒ `.warn` ("newer than validated") |
| 11 | `test_t3_n4_warn_when_dialog_present` | Unit | N4 present | running+AX-granted, probe returns a dialog ⇒ `.warn`; evidence `dialog_present=="true"`, `dialog_title`/`buttons`/`recovery_action` populated |
| 12 | `test_t3_n4_pass_when_no_dialog` | Unit | N4 clear | running+AX-granted, probe nil ⇒ `.pass` |
| 13 | `test_t3_n4_skipped_bb_application_state_when_not_running` | Unit | N4 running-first (OQ-3) | Logic not running (AX denied too) ⇒ `.skipped` `blocked_by=="logic.application_state"`; ALSO running-but-no-window (`application_state==.warn`) ⇒ same `bb` (table-driven conservative gate, OBJ-B) |
| 14 | `test_t3_n4_skipped_bb_accessibility_when_running_ax_denied` | Unit | N4 precedence | running + AX denied ⇒ `.skipped` `blocked_by=="permissions.accessibility"` |
| 15 | `test_t3_n4_dialog_empty_title_no_crash` | Unit | E12 | dialog with empty/foreign title ⇒ `.warn`, no crash on nil fields |
| 16 | `test_t3_array_grows_by_three_logic_chain` | Contract | AC-6 order | exact-id array places `logic.installation`,`logic.version_support` before `logic.application_state` and `logic.blocking_dialog` after it |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 2–16 (extend `enterpriseRuntime` with the two new seams).
- `Tests/LogicProMCPTests/VersionConsistencyTests.swift` — case 1 (reuse `readRepoFile`, VersionConsistencyTests.swift:12-17).
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — exact-id array update (:83-97).

### 3.3 Mock / Setup Required
- Add to `SetupDoctor.Runtime` (default-valued `var` seams, additive pattern per :154-162): `logicInfoPlist: (String) -> (version: String, bundleId: String)?` keyed by path, and `blockingDialogProbe: () -> AXLogicProElements.BlockingDialogInfo?`. `.production` wires the real `Info.plist` read + `AXLogicProElements.blockingDialogInfo(runtime:)` (AXLogicProElements.swift:99-125). Fixture defaults: Logic present @ 12.3 at `/Applications`, `nil` dialog.
- N4 gate reads the already-computed `logic.application_state` + `permissions.accessibility` statuses via T1's `status(of:in:)` resolver (both precede N4 in declared order).

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Server/ServerConfig.swift` | Modify | add `enum LogicProSupport { static let minimumSupportedLogicVersion = "12.0.1"; static let latestValidatedLogicVersion = "12.3" }` |
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `Runtime` +2 seams; `logicInstallationCheck`/`logicVersionSupportCheck`/`logicBlockingDialogCheck`; insert 3 `timed { }` appends around `logicApplicationStateCheck` (generate :254); `remediationAnchorsByCheckID` +3 entries; extend `blockedByDependencies` usage for N3/N4 (table constant already in T1) |
| `Tests/LogicProMCPTests/VersionConsistencyTests.swift` | Modify | manifest pin |
| `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` | Modify | N2/N3/N4 tests + seam defaults |
| `Tests/LogicProMCPTests/SetupDoctorTests.swift` | Modify | array update |

### 4.2 Implementation Steps (Green Phase)
1. Add `LogicProSupport` constants to `ServerConfig.swift`; author the manifest-pin test.
2. Add the two `Runtime` seams (default-valued `var`, matching :156-162) + `.production` wiring. `Info.plist` read: `Bundle(path:)`/`CFBundleShortVersionString` or a direct plist parse — **static read, no `NSWorkspace` launch, no subprocess**.
3. `logicInstallationCheck` (N2): probe `/Applications/Logic Pro.app` then `~/Applications/Logic Pro.app`. 3-way per AC-2; evidence `{version,bundle_id,path,second_copy?,reason?}`; `remediationType: .docs`.
4. `logicVersionSupportCheck` (N3): if `status(of:"logic.installation",in:checks) != .pass` ⇒ `skipped` + `blockedBy:"logic.installation"` (via `check(...,blockedBy:)`). Else numeric-compare detected vs `LogicProSupport` (reuse the existing numeric version-compare helper the update check uses; PRD notes prerelease-strip already exists). evidence `{detected_version,minimum_supported,latest_validated}`; `.docs`.
5. `logicBlockingDialogCheck` (N4): gate = derive `bb` from **T1's `blockedByDependencies["logic.blocking_dialog"]`** (`["logic.application_state", "permissions.accessibility"]`, OBJ-B) — walk the ordered cause list, first cause whose `status(of:in:) != .pass` wins as `blockedBy` ⇒ `skipped` (no body-local precedence hardcoding; the table IS the running-first rule). If no cause blocks: call `runtime.blockingDialogProbe()`; `warn` if non-nil (populate evidence, `recovery_action` from `BlockingDialogInfo.recoveryAction`), else `pass`. remediation `manual`. Note: `logic.application_state`는 `manual`(미실행)·`warn`(창 없음)이 non-pass이므로 "Logic 실행 중이나 창 미감지(warn)"에서도 N4가 blocked됨 — 보수적·정직한 게이트로 의도된 동작.
6. Insert appends: `logic.installation`, `logic.version_support` **before** the existing `logicApplicationStateCheck` append (:254); `logic.blocking_dialog` **after** it, before `manualValidationCheck` (:255). Add 3 anchor entries. Bump array + count.

### 4.3 Refactor Phase
- Factor the `Info.plist` dual-path probe into a small pure helper returning both copies so N2 evidence + N3's `/Applications`-tie-break share one read.

## 5. Edge Cases
- E1 dual copy (case 5); E2 Logic not running ⇒ N4 `skipped bb=logic.application_state` (case 13); E3 AX denied ⇒ N4 `skipped bb=permissions.accessibility` + accessibility `fail` (case 14); E12 empty/foreign title (case 15); E13 unreadable plist ⇒ N2 `skipped bundle_unreadable` (case 4).

## 6. Review Checklist
- [ ] Red → Green → Refactor green (`swift test --no-parallel` + `swift build -c release`)
- [ ] N2 never false-`fail`s a present-but-unreadable install (D7/E13)
- [ ] N3 has **one** derivation branch (no separate version-nil path — absorbed by N2 `skipped`)
- [ ] N4 `blocked_by` never carries `warn`/`manual` (only `skipped`) — preserves the headline/fix_plan coupling invariant (§4.3 R1)
- [ ] `blockingDialogInfo` reuse is read-only (no AX mutation)
- [ ] array/count bumped by exactly 3; no dead-`#expect`

## 7. Out of Scope (explicit)
- **No `ProcessUtils.logicProVersion()` change** — N2 reads `Info.plist` directly, independent of the running-Logic version path.
- **No `.logikcs` / MCU parse** (NG4) — that lineage is channels (T6).
- **No server runtime / health change** (NG1/NG3).
- **`blocked_by` table constant + `status(of:in:)` resolver** are defined in **T1**; T3 only consumes them for N3/N4.
