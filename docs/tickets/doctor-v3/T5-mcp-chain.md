# T5: MCP-Chain — N5 registration_target, N6 claude_desktop_registration

**PRD Ref**: PRD-doctor-v3 > §4.3 N5/N6 + `blocked_by` table, §4.4 D2 (static sniff reuse), US-2/AC-2.3, US-4/AC-4.1/4.2, E6/E14/E15
**Priority**: P1 (High)
**Size**: M
**Status**: Todo
**Depends On**: T2

---

## 1. Objective

Complete the registration leg of the causal chain: `mcp.registration_target` (N5) validates the Claude Code registered command (resolve + executable + env sanity + **static** version match), `blocked_by`-derived from `mcp.claude_code_registration`; `mcp.claude_desktop_registration` (N6) reads the Claude Desktop config via a second `configURL`, with honest `skipped` reasons for absent/unreadable.

## 2. Acceptance Criteria

- [ ] AC-1 (N5 precondition): if `mcp.claude_code_registration != pass` ⇒ `skipped` `blocked_by:mcp.claude_code_registration` (live: this Mac is `.notRegistered` ⇒ skipped).
- [ ] AC-2 (N5 when registered): registered `command` path exists + is executable; args/env sanity (if registered env has `LOGIC_PRO_MCP_SHARE_DIR`, its dir exists); **static** version sniff of the registered binary vs running doctor version. `pass` if command resolves + executable + env sane + version matches (or honestly indeterminate); `warn` if any of {command missing, not executable, env dir missing, version mismatch = "stale registered binary"} (AC-2.3). Never executes the registered binary (C4/NG7).
- [ ] AC-3 (N5 malformed-input, R4/TR3): a **relative / bare PATH-dependent** registered command (예: Formula caveats의 권장 등록 `LogicProMCP` — 실유저 최빈 케이스, E4 §A1/§B5) ⇒ N5는 **`skipped` `reason:relative_command`** — **`pass` 금지** (PATH-종속 등록은 스폰 컨텍스트마다 해석이 달라 정적 검증 불가; pass는 "타깃 검증 완료" 주장 = false-green/G3 위반). summary는 "정본 경로 staleness는 `install.binary_inventory`(N7)가 커버"를 명시. Candidate must be `isRegularFile` (#211). A **non-Mach-O** resolved binary ⇒ version **indeterminate** (no mismatch warn). evidence `{command_path, executable, share_dir?, registered_version, running_version, version_match, reason?}`; remediation `command` (`claude mcp add …`).
- [ ] AC-4 (N6 states, R4): reads `~/Library/Application Support/Claude/claude_desktop_config.json` with the **same predicate** as the Claude Code reader (name contains `logic-pro` AND command contains `LogicProMCP`). `skipped reason=config_absent` + summary "Claude Desktop not configured (optional)" when missing (live: missing) — explicitly **not** `manual`/`warn`/`pass` (AC-4.1); `skipped reason=config_unreadable` (E14) when present-but-not-valid-JSON; `pass` if present+parseable+registered; `warn` if present+parseable+unregistered (manual-JSON-edit remediation — no CLI equivalent, AC-4.2). evidence `{config_present, registered?, reason?}`; remediation `manual`.
- [ ] AC-5 (positions + array +2): `mcp.registration_target` + `mcp.claude_desktop_registration` inserted **after** `mcp.claude_code_registration` and **before** `permissions.accessibility`. Array grows by 2; counts bumped.

## 3. TDD Spec (Red Phase)

> N5 reuses the static `strings`-ranking sniff (defined pure in T4). If T4 has not landed at implementation time, N5 may inline a minimal sniff and reconcile at integration — but prefer consuming T4's `rankStringsVersions`. N6 reuses the config-reader predicate (readProductionClaudeRegistration, SetupDoctor.swift:1131-1179) with a second `configURL`.
> **dead-`#expect` 금지** (R6): concrete status + evidence assertions.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t5_n5_skipped_when_not_registered` | Unit | AC-1 (live) | registration `.notRegistered` ⇒ N5 `.skipped` `blocked_by=="mcp.claude_code_registration"` |
| 2 | `test_t5_n5_pass_command_ok_version_match` | Unit | AC-2 pass | registered abs command exists+executable, static version == running ⇒ `.pass`; `version_match=="true"` |
| 3 | `test_t5_n5_warn_command_missing` | Unit | E6 | registered command path does not exist ⇒ `.warn` (never executed) |
| 4 | `test_t5_n5_warn_version_mismatch` | Unit | AC-2.3 | registered binary sniffs `3.5.0` vs running `3.8.0` ⇒ `.warn` "stale registered binary" |
| 5 | `test_t5_n5_warn_env_share_dir_missing` | Unit | AC-2 env sanity | registered env `LOGIC_PRO_MCP_SHARE_DIR` dir absent ⇒ `.warn`; evidence `share_dir=="missing"` |
| 6 | `test_t5_n5_relative_command_excluded` | Unit | AC-3 / E15 / TR3 | relative/bare registered command ⇒ `.skipped`, evidence `reason=="relative_command"`, summary contains `install.binary_inventory` 참조; never `.pass`/`.warn` |
| 7 | `test_t5_n5_non_macho_indeterminate` | Unit | AC-3 / E17 | resolved binary yields no semver ⇒ version indeterminate; no mismatch warn |
| 8 | `test_t5_n5_never_executes_registered_binary` | Unit | C4/NG7 | spy `runCommand`: registered LogicProMCP path is never an executable arg |
| 9 | `test_t5_n6_skipped_config_absent` | Unit | AC-4.1 (live) | desktop config missing ⇒ `.skipped reason=config_absent`; summary contains "optional" |
| 10 | `test_t5_n6_skipped_config_unreadable` | Unit | E14 | desktop config exists but invalid JSON ⇒ `.skipped reason=config_unreadable` (not warn) |
| 11 | `test_t5_n6_pass_when_registered` | Unit | AC-4 | desktop config present+parseable+registered ⇒ `.pass` |
| 12 | `test_t5_n6_warn_when_unregistered` | Unit | AC-4.2 | present+parseable+unregistered ⇒ `.warn`, manual remediation |
| 13 | `test_t5_array_grows_by_two_mcp_chain` | Contract | AC-5 order | exact-id array places `mcp.registration_target`,`mcp.claude_desktop_registration` between `mcp.claude_code_registration` and `permissions.accessibility` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–13 (extend `enterpriseRuntime` with the desktop-config reader seam + registered-command file seams).
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — array update; N6 may reuse the `readClaudeRegistrationForTesting`-style temp-file pattern (SetupDoctor.swift:1193-1196) for real JSON fixtures.

### 3.3 Mock / Setup Required
- `SetupDoctor.Runtime` seams: `readClaudeDesktopRegistration: () -> ClaudeRegistration` (default `.production` = `readProductionClaudeRegistration(configURL: <desktop path>)` reusing the existing reader with the second URL); the registered-command file checks reuse the existing `fileExists`/`isExecutableFile`/`isRegularFile` seams + `runCommand` for `strings`/`lipo`.
- N5's version sniff consumes T4's `rankStringsVersions` (pure fn).

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `readProductionClaudeRegistration` (:1131) — parameterize/reuse for the desktop `configURL` (`~/Library/Application Support/Claude/claude_desktop_config.json`); add `Runtime.readClaudeDesktopRegistration` seam; `registrationTargetCheck` (N5), `claudeDesktopRegistrationCheck` (N6); insert 2 `timed { }` appends after `claudeRegistrationCheck` (generate :249); +2 anchors; N5 consumes `blockedByDependencies` (T1) |
| Tests (2 files) | Modify | N5/N6 + array/count |

### 4.2 Implementation Steps (Green Phase)
1. N6 reader: the existing `readProductionClaudeRegistration(configURL:)` already takes a URL param (:1131-1134) and yields the 3-way `ClaudeRegistration` (registered/notRegistered/configUnavailable). Add a `.production` seam pointing it at the desktop config path. Map: `.configUnavailable(absent)` ⇒ `skipped config_absent`; `.configUnavailable(not-JSON/unreadable)` ⇒ `skipped config_unreadable`; `.registered` ⇒ `pass`; `.notRegistered` ⇒ `warn` (manual remediation). **Distinguish absent vs unreadable** — the reason string from `configUnavailable` already encodes which (see :1136 "not found" vs :1142 "could not be read" vs :1148 "not valid JSON").
2. `registrationTargetCheck` (N5): if `status(of:"mcp.claude_code_registration",in:checks) != .pass` ⇒ `skipped blockedBy:"mcp.claude_code_registration"`. Else parse the registered `command`: absolute? (else `reason:relative_command`, exclude); `isRegularFile` + `isExecutableFile`; env `LOGIC_PRO_MCP_SHARE_DIR` dir exists (if present); static version via `rankStringsVersions(strings(command))`. Status per AC-2.
3. Insert appends after `claudeRegistrationCheck` (:249), before `accessibilityPermissionCheck`. Add anchors, bump array + count.

### 4.3 Refactor Phase
- Extract the "resolve + isRegularFile + isExecutable + static-version-sniff of a candidate path" logic shared by N5 and N7 (T4) into one helper if both have landed — reduces the two "never execute" implementations to one.

## 5. Edge Cases
- E6 registered command missing (case 3); E14 desktop config bad JSON (case 10); E15 relative command (case 6); E17 non-Mach-O (case 7).

## 6. Review Checklist
- [ ] Red → Green → Refactor green
- [ ] N5 `blocked_by` carries only `skipped` (never `warn`/`manual`) — coupling invariant safe
- [ ] N6 absent ⇒ `skipped config_absent` (never `manual`/`warn`/`pass`)
- [ ] Registered binary never executed (case 8)
- [ ] Desktop reader reuses the Claude Code predicate (no divergent match logic)
- [ ] array/count +2; no dead-`#expect`

## 7. Out of Scope (explicit)
- **`install.binary_inventory` (N7)** and the `rankStringsVersions` pure fn are **T4**; T5 consumes the pure fn.
- **No writing of any config** — doctor is read-only (§6.2).
- **No server runtime / health change** (NG3/NG1).
- **`blocked_by` table + resolver** are **T1**.
