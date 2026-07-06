# T1: Data-Spine — `blocked_by`, `fix_plan`, schema v3, dependency table, `DoctorTool` allowlist (D10)

**PRD Ref**: PRD-doctor-v3 > §4.2 (Data Model), §4.3 (Fix Plan canonical + `blocked_by` table + `check()` factory), §4.4 D9/D10, §4.5 #3, G2/G5, AC-1.3
**Priority**: P0 (Blocker — foundation for T2–T9)
**Size**: M
**Status**: Todo
**Depends On**: None

---

## 1. Objective

Lay the v3 wire/logic foundation that every later ticket builds on: add `Check.blockedBy` (omit-when-nil) and top-level `fix_plan`, bump the schema to `…v3`, define the compile-time `blocked_by` dependency table + `status(of:in:)` resolver + dependency-check-id constants, thread a `blockedBy:` parameter through the single `check(...)` factory, compute the root-cause-collapsed severity-ordered `fix_plan` array, and enforce the arbitrary-binary-execution guard structurally via a typed `DoctorTool` allowlist (fail-closed `runCommand` + source-grep lint). **`computeHeadline` logic is unchanged** — only its id/`fix_plan[0]` coupling is newly asserted.

No new *checks* are added here (they arrive in T2–T7). This ticket ships the mechanism and proves it against the existing 13-check report.

## 2. Acceptance Criteria

- [ ] AC-1: `Check` gains `blockedBy: String?` with wire key `blocked_by`, **omitted when nil** via the synthesized Codable `encodeIfPresent` (no hand-written `encode(to:)`). A v1/v2 decoder never sees the key when there is no dependency (D9).
- [ ] AC-2: `Report` gains top-level `fix_plan: [String]` (ordered check ids). `SetupDoctor.schema == "logic_pro_mcp_doctor.v3"`.
- [ ] AC-3 (OBJ-A amended): `computeFixPlan(checks:)` returns exactly the checks where `status != .pass` **AND** `blockedBy == nil` **AND** `severity ∈ {error, warning}` (i.e. `status ∈ {fail, warn, manual}`), ordered **2-tier: `error` tier → `warning` tier (`warn`·`manual` co-equal)**, declared order within a tier; `skipped`/`pass` (`info`) excluded; `manual` **included**. ~~3-tier fail→warn→manual~~ 철회 — headline(warning 밴드 선언순 tie-break)과의 커플링을 깨는 반례(manual #9 vs warn #11) 존재. 2-tier면 fix_plan 선택이 computeHeadline lead 선택과 구성상 동일 → AC-4가 구성적으로 성립 (PRD §4.3 Ordering, v0.3).
- [ ] AC-4: The check id **embedded** in `headline` (`lead.id`) equals `fix_plan[0]` when the plan is non-empty — asserted by id-extraction (`headline.contains("[\(fixPlan[0])]")`), **never** literal `headline == fixPlan[0]` (§4.3 R1/R6). Empty plan ⇒ v2 healthy/usable headline unchanged.
- [ ] AC-5: `check(...)` factory accepts `blockedBy: String? = nil` (defaulted) threaded into `Check.blockedBy`; the compile-time `blockedByDependencies` table + `status(of:in:)` resolver exist and are unit-covered (even though no check consumes them until T3/T5).
- [ ] AC-6 (D10): Production `runCommand` routes through a typed `DoctorTool` allowlist of fixed absolute paths and **fail-closed returns `nil` (spawns nothing)** for any executable not in the allowlist; a source-grep lint test asserts **no `Process(`/`posix_spawn` outside `BoundedProcessRunner`** in the doctor source file(s). The allowlist accepts **both** brew prefixes (`/opt/homebrew/bin/brew`, `/usr/local/bin/brew`) so `detectInstallSource` (SetupDoctor.swift:856) does not regress.
- [ ] AC-7: v3 output still decodes into a frozen **v1** struct (existing test, schema assertion updated) **and** a new frozen **v2** struct (summary/category/severity/duration_ms survive; `fix_plan`/`blocked_by` ignored).

## 3. TDD Spec (Red Phase)

> Fixture reuse: `enterpriseRuntime()` / `makeReport(runtime:permission:approvals:)` / `check(_:_:)` (SetupDoctorEnterpriseTests.swift:7-68), `granted(...)` (:35-45). Force statuses on existing checks (e.g. `permission: granted(accessibility:false)` ⇒ `permissions.accessibility` = `fail`; `macOSVersion: nil` ⇒ `system.macos_version` = `skipped`) to drive `fix_plan`.
> **dead-`#expect` 금지**: `#expect(optBool == true/false)`, `?? false`, `== .some(true)` 형태 금지 (항상 통과 = dead). force-unwrap (`#expect(x!)`) / 구체형 비교 / `try #require` 만 사용 (repo footgun, issue #92, PRD R6).

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t1v3_schema_is_v3` | Unit | schema bumped | `report.schema == "logic_pro_mcp_doctor.v3"` |
| 2 | `test_t1v3_blocked_by_omitted_when_nil` | Contract | D9 omit-when-nil | encode `makeReport()` JSON → no per-check object contains key `blocked_by` |
| 3 | `test_t1v3_blocked_by_present_when_set` | Contract | wire key emitted | build a `Check` via `check(...,blockedBy:"x")` → its JSON contains `"blocked_by":"x"` |
| 4 | `test_t1v3_fix_plan_membership_excludes_pass_and_skipped` | Unit | AC-3 membership | all-good report ⇒ `fix_plan == []`; `macOSVersion:nil` (skipped/info) alone ⇒ still `[]` |
| 5 | `test_t1v3_fix_plan_includes_fail_warn_manual` | Unit | AC-3 manual-inclusion | force one `fail` + one `manual` (e.g. accessibility fail + manual_validation manual) ⇒ both ids in `fix_plan` |
| 6 | `test_t1v3_fix_plan_order_two_tier_and_headline_agree` | Unit | 2-tier order (OBJ-A) | fixture with `fail`,`warn`,`manual` present ⇒ fail-ids first, then warn/manual ids **in declared order (co-equal)**; PLUS the OBJ-A counterexample fixture (manual declared before warn, no fail) ⇒ `fix_plan[0]` == the earlier-declared manual AND headline embeds the same id |
| 7 | `test_t1v3_headline_id_equals_fix_plan_first` | Unit | AC-4 coupling (id-extraction) | non-empty plan ⇒ `#expect(report.headline.contains("[\(report.fixPlan[0])]"))` |
| 8 | `test_t1v3_headline_healthy_when_fix_plan_empty` | Unit | empty-plan headline unchanged | all-good ⇒ `fix_plan == []` **and** `headline == "Logic Pro MCP install is healthy."` |
| 9 | `test_t1v3_check_factory_threads_blocked_by` | Unit | AC-5 factory param | `check(id:…, blockedBy:"cause")` produces `Check.blockedBy == "cause"`; default omitted ⇒ `nil` |
| 10 | `test_t1v3_dependency_table_and_status_resolver` | Unit | AC-5 table + resolver (OBJ-B) | table typed `[String: [String]]` — `blockedByDependencies["mcp.registration_target"] == ["mcp.claude_code_registration"]`, `["logic.blocking_dialog"] == ["logic.application_state", "permissions.accessibility"]` (order = precedence); `status(of:in:)` returns the cause's status from a checks array; missing id ⇒ `nil` |
| 11 | `test_t1v3_doctor_tool_allowlist_rejects_arbitrary_binary` | Unit | AC-6 fail-closed | `SetupDoctor.Runtime.production.runCommand("/bin/echo", ["harmless"]) == nil` (existing-but-non-allowlisted, side-effect-free) AND nonexistent `/tmp/nonexistent-doctor-tool` ⇒ `nil`. **TR1 규칙: 실제 LogicProMCP 경로(설치본 `/opt/homebrew/bin/LogicProMCP`·빌드본 `.build/**`)를 production `runCommand`의 executable 인자로 쓰는 테스트 금지 — red 단계(allowlist 구현 전)에는 그대로 spawn되어 E4 인시던트(stale 서버 실기동)를 재연한다** |
| 12 | `test_t1v3_doctor_tool_allowlist_accepts_known_tools` | Unit | AC-6 both brew prefixes | `DoctorTool.resolve("/opt/homebrew/bin/brew")` and `resolve("/usr/local/bin/brew")` and `resolve("/usr/bin/codesign")` are non-nil (mapping exists) |
| 13 | `test_t1v3_lint_no_raw_process_outside_bounded_runner` | Unit(lint) | AC-6 source-grep | read doctor source file(s); assert no line matches `Process(` / `posix_spawn` outside `BoundedProcessRunner.swift` |
| 14 | `test_t1v3_frozen_v1_still_decodes_from_v3` | Contract | G5 v1 superset | extend FrozenV1 test (SetupDoctorEnterpriseTests.swift:189-247): update `schema == "…v3"`; 11 v1 ids still decode |
| 15 | `test_t1v3_frozen_v2_decodes_from_v3` | Contract | AC-7 v2 superset | new `FrozenV2Report` struct (schema,status,version,install_source,checks[{id,domain,status,summary,evidence,remediation,category,severity,duration_ms}],summary,headline) decodes v3 output; `fix_plan`/`blocked_by` absent from the struct and ignored |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–10, 14, 15 (extend existing FrozenV1 block; add `FrozenV2Report`).
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — update the schema assertion in the exact-id array test (:78) to `…v3`; **the 13-id array itself is unchanged in T1** (checks grow in T3–T7).
- New file `Tests/LogicProMCPTests/DoctorToolAllowlistTests.swift` — cases 11–13 (allowlist + lint).

### 3.3 Mock / Setup Required
- Reuse `enterpriseRuntime`/`makeReport`/`granted`/`check` helpers. No new fixture seams needed (T1 adds no checks).
- Case 13 (lint) reads source via the `repositoryRootURL()`/`readRepoFile()` idiom (VersionConsistencyTests.swift:5-17) or the `issue26RepositoryRootURL()` idiom (SetupDoctorTests.swift:63-68).
- Cases 11–12 exercise `SetupDoctor.Runtime.production.runCommand` and/or a pure `DoctorTool.resolve(_:)` helper directly.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `Check` (+`blockedBy`, +CodingKey `blocked_by`, :53-81); `Report` (+`fixPlan`, +CodingKey `fix_plan`, :104-123); `schema` v2→v3 (:201); `check(...)` (+`blockedBy:` param, :892-916); `generate` compute+pass `fixPlan` (:271-279); new `computeFixPlan(checks:)`, `blockedByDependencies` constant, `status(of:in:)` resolver; `DoctorTool` enum + fail-closed production `runCommand` (:180-182) |
| `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` | Modify | FrozenV1 schema assertion → v3; add `FrozenV2Report` decode; fix_plan / factory / table tests |
| `Tests/LogicProMCPTests/SetupDoctorTests.swift` | Modify | schema assertion → v3 |
| `Tests/LogicProMCPTests/DoctorToolAllowlistTests.swift` | Create | allowlist fail-closed + accepts-known + source-grep lint |

### 4.2 Implementation Steps (Green Phase)
1. `Check`: add `var blockedBy: String?` (nil default at construction) + `case blockedBy = "blocked_by"` in `CodingKeys`. Synthesized `Codable` uses `encodeIfPresent` for optionals ⇒ omit-when-nil for free (verified: no hand-written `encode/init` on `Check`/`Report`, :53-81). Keep the six v1 keys' exact wire names.
2. `Report`: add `let fixPlan: [String]` + `case fixPlan = "fix_plan"`.
3. `schema` (:201) → `"logic_pro_mcp_doctor.v3"`.
4. `check(...)` factory (:892-916): add `blockedBy: String? = nil` param, set `Check.blockedBy = blockedBy`. Default keeps all existing call sites compiling.
5. Add `static let blockedByDependencies: [String: [String]]` (OBJ-B — ordered cause list, array order = precedence): `"mcp.registration_target": ["mcp.claude_code_registration"]`, `"logic.version_support": ["logic.installation"]`, `"logic.blocking_dialog": ["logic.application_state", "permissions.accessibility"]` (running-first). Check bodies (T3/T5) consume the table — first non-`pass` cause in order wins as `bb`; no body-local precedence hardcoding. Add `static func status(of id: String, in checks: [Check]) -> CheckStatus?`.
6. Add `static func computeFixPlan(_ checks: [Check]) -> [String]` (OBJ-A — 2-tier): filter (`status != .pass && blockedBy == nil && severity != .info`), then stable-sort by **severity tier only** (`error=0, warning=1`) preserving declared order within a tier, map to ids. Selection is constructionally identical to `computeHeadline`'s lead pick. **This is the ordered array — T8 renders it, does not re-sort.**
7. `generate` (:271-279): compute `let fixPlan = computeFixPlan(checks)` and pass to `Report(...)`. `computeHeadline` call unchanged.
8. `DoctorTool` (D10): `enum DoctorTool: CaseIterable { case codesign, xattr, lipo, strings, sqlite3, plutil, which, brew, brewAlt, osascript, curl, gh }` (or a struct holding the allowlisted absolute-path set). Provide `static func resolve(_ executable: String) -> DoctorTool?` matching the **exact** fixed absolute paths the doctor uses today (`/usr/bin/codesign`, `/usr/bin/xattr`, `/usr/bin/lipo`, `/usr/bin/strings`, `/usr/bin/sqlite3`, `/usr/bin/plutil`, `/usr/bin/which`, **`/opt/homebrew/bin/brew` AND `/usr/local/bin/brew`**, `/usr/bin/osascript`, `/usr/bin/curl`, and `gh`'s resolved path). Rewrite the `.production` `runCommand` closure (:180-182) to `guard DoctorTool.resolve(executable) != nil else { return nil }` **before** calling `runProductionCommand` — fail-closed, spawns nothing on a miss. Seam signature stays `(String, [String]) -> CommandOutput?` (fixture compat).
9. FrozenV1 test: change `schema == "…v3"`. Add `FrozenV2Report`/`FrozenV2Check` structs (v2 shape) + decode test.

### 4.3 Refactor Phase
- Keep `computeFixPlan` a pure static (table-testable). Consider colocating `DoctorTool` in a small `Sources/LogicProMCP/Utilities/DoctorTool.swift`; **if a new source file is added, add it to the lint test's scanned-file list** (case 13).

## 5. Edge Cases
- EC (empty plan): all-pass ⇒ `fix_plan == []`, healthy headline (case 8).
- EC (skipped-only): a `skipped`/`info` check degrades the aggregate but is **not** in `fix_plan` (case 4) — mirrors the existing `test_t3_headline_not_healthy_when_degraded_skipped_only` (SetupDoctorEnterpriseTests.swift:551-557).
- EC (both brew prefixes): allowlist must accept both or `install.source` regresses (case 12).

## 6. Review Checklist
- [ ] Red: new tests FAIL before implementation
- [ ] Green: all tests PASS after implementation
- [ ] `swift build -c release` + `swift test --no-parallel` green
- [ ] `computeHeadline` body unchanged (diff shows only the new coupling *test*, not logic)
- [ ] No hand-written `encode(to:)`/`init(from:)` added to `Check`/`Report` (omit-when-nil stays synthesized)
- [ ] No `Process(`/`posix_spawn` introduced outside `BoundedProcessRunner`
- [ ] 기존 테스트 깨지지 않음 (제외: 의도된 schema v2→v3 어서션 갱신)
- [ ] No dead-`#expect` (§3 note)

## 7. Out of Scope (explicit)
- **No new checks** — N1–N12 + click_fallback arrive in T2–T7.
- **No human rendering of the fix plan** — the numbered/status-tagged `Fix plan:` section, color, and per-mode render are **T8**. T1 ships only the ordered `fix_plan` JSON array + the computation.
- **No `--strict`** (T8).
- **No server runtime / `system.health` change** (NG1/NG3). `system.health` computes its own `post_event_access` at `SystemDispatcher.swift:212` — untouched.
- **`binary.version` stays always-`pass`** (immutable, SetupDoctor.swift:448-459).
