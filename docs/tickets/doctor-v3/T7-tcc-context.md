# T7: TCC-Context — N9 launch_context, N10 tcc_cross_context (FDA-gated enrichment)

**PRD Ref**: PRD-doctor-v3 > §4.3 N9/N10, §4.4 D5/D6, §4.5 #3-6, §6.3 (Data Protection), US-4/AC-4.3/4.4, E4/E9/E18, OQ-2, R3/R5/R9/R15
**Priority**: P1 (High)
**Size**: M
**Status**: Todo
**Depends On**: T1 (semantically independent of T2's PostEvent — see note; sequence after T2 to inherit fixture posture)

---

## 1. Objective

Answer the "I granted it but it still fails" class: `permissions.launch_context` (N9) names the TCC principal this doctor process measured and warns that a differently-spawned server must be re-verified (always `pass`, informational); `permissions.tcc_cross_context` (N10) is a **default-on, FDA-gated, read-only** enrichment that queries the TCC databases for MCP-host principals, structurally incapable of false-red, self-degrading to `skipped` with an enumerated reason when it cannot answer.

## 2. Acceptance Criteria

- [ ] AC-1 (N9 classify, R9): detect the doctor process's launch context via ancestor-process walk (`sysctl`/`proc_pidpath`, read-only, no TCC) + env heuristics (`TERM_PROGRAM`, `__CFBundleIdentifier`, node/claude ancestry). Classify `terminal|claude_code|claude_desktop|unknown` with **deterministic precedence: ancestry bundle-id > `__CFBundleIdentifier` > `TERM_PROGRAM` > unknown** (first known-host signal wins). Precedence pinned by a unit test.
- [ ] AC-2 (N9 always pass, AC-4.3): status **always `pass`** (informational). Summary names the measured context and states a server spawned by a *different* app must be re-verified under that app. evidence `{launch_context, responsible_hint}` (bundle id, or basename-only when path-attributed, C7); remediation `none`; `blocked_by` none.
- [ ] AC-3 (N10 open contract, R3 mandatory): open TCC.db via the **`file:<path>?immutable=1` URI** (required, not a bare `-readonly`) so **no `-wal`/`-shm`/`-journal` sidecar** is ever created. The implementer MUST verify `/usr/bin/sqlite3` recognizes the URI filename (if not, treat as literal path ⇒ open fails ⇒ natural `skipped`, safe). Read-only SELECT over user + system TCC.db for `service IN (kTCCServiceAccessibility, kTCCServiceAppleEvents, kTCCServicePostEvent)` with `indirect_object_identifier IN (com.apple.logic10, com.apple.systemevents)` for AppleEvents. Bounded (`BoundedProcessRunner`, ≤1.5s, 2 calls).
- [ ] AC-4 (N10 query shape, R9): **fixed literal SQL** — service/identifier values are compile-time constants, column-addressed (never `SELECT *`); principal matching is **Swift post-processing over returned rows**, never a dynamic `WHERE`. No SQL-injection surface.
- [ ] AC-5 (N10 status): `warn` if a known MCP-host principal (claude-related bundle id + the principal inferred from the registered command) is explicitly denied (`auth_value == 0`) a required service; `pass` if a grant (`auth_value == 2`) is confirmed; **`skipped reason=principal_not_found` (R5/E18)** if the DB reads + query runs but **no** grant/deny row exists for any relevant principal (**never** falls through to `pass`); **`skipped`** with a 3-way capability reason (R15): `full_disk_access_unavailable` (DB unopenable) / `tcc_query_unavailable` (sqlite3 absent or URI unrecognized) / `tcc_schema_mismatch` (opens but an addressed column absent). Every skipped case's summary states live probes (N1 + existing permissions) remain authoritative.
- [ ] AC-6 (N10 hard rules, D5/§6.3): never replaces the live probe; **structurally incapable of false-red** — a "denied" row only ever downgrades to `warn`, never `fail`. Redaction per C7: only `{service, principal_hint(bundle id|basename), state}` egress; **never** csreq/`indirect_object_code_identity` blobs, full paths, other apps' human names, `auth_reason`, or pids. Raw subprocess `stderr` / `spawnFailed(String)` never enters `evidence` — mapped to a fixed `reason`. evidence `{tcc_db_readable, full_disk_access, findings:"accessibility=granted,appleevents:logic10=denied", reason?}`; remediation `system_settings`.
- [ ] AC-7 (positions + array +2): `permissions.launch_context` + `permissions.tcc_cross_context` inserted **after** `permissions.post_event_access` (N1) and **before** `system.macos_version`. Array grows by 2; counts bumped.

## 3. TDD Spec (Red Phase)

> New fixture seams: a launch-context detector (`() -> (context: String, hint: String)`) and a TCC query runner (`() -> TCCQueryOutcome`) — an enum modeling readable-rows / no-matching-row / the 3 capability failures. Reuse `BoundedProcessRunner`-shaped fakes. The **pure mappers** (row→`{service,principal,state}`; TCC outcome→status/reason; classifier precedence) are table-tested on frozen fixtures (no live sqlite3).
> **dead-`#expect` 금지** (R6): assert concrete `.skipped` + `reason` values; never `#expect(optString == "x" ?? "y")`.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t7_n9_always_pass` | Unit | AC-2 | any context ⇒ `.pass`; evidence `launch_context` populated |
| 2 | `test_t7_n9_classifier_precedence` | Unit | AC-1 (R9) | ancestry bundle-id present + conflicting `TERM_PROGRAM` ⇒ ancestry wins; full precedence table (ancestry > `__CFBundleIdentifier` > `TERM_PROGRAM` > unknown) |
| 3 | `test_t7_n9_summary_names_context_and_reverify` | Unit | AC-4.3 | summary contains the measured context + the re-verify-under-spawning-app caveat |
| 4 | `test_t7_n10_warn_principal_denied` | Unit | AC-5 | a known claude principal has `auth_value==0` for a required service ⇒ `.warn`; findings names the service |
| 5 | `test_t7_n10_pass_grant_confirmed` | Unit | AC-5 | `auth_value==2` grant present ⇒ `.pass` |
| 6 | `test_t7_n10_skipped_principal_not_found` | Unit | R5/E18 | DB readable, query runs, no matching-principal row ⇒ `.skipped reason=principal_not_found` (**never** `.pass`) |
| 7 | `test_t7_n10_skipped_fda_unavailable` | Unit | E4/R15 | DB unopenable ⇒ `.skipped reason=full_disk_access_unavailable`; live probes still reported; never `.fail` |
| 8 | `test_t7_n10_skipped_query_unavailable` | Unit | E9/R15 | sqlite3 absent / URI unrecognized ⇒ `.skipped reason=tcc_query_unavailable` |
| 9 | `test_t7_n10_skipped_schema_mismatch` | Unit | E9/R15 | opens but addressed column absent ⇒ `.skipped reason=tcc_schema_mismatch` |
| 10 | `test_t7_n10_never_fail_on_denied_row` | Unit | D5 false-red-impossible | even a denied row never yields `.fail` (max downgrade is `.warn`) |
| 11 | `test_t7_n10_redaction_egress` | Unit | C7/§6.3 | given a raw row with csreq blob / auth_reason / foreign human name / full path, the emitted `findings`/evidence contains **none** of them — only `{service, principal_hint, state}` |
| 12 | `test_t7_n10_stderr_never_in_evidence` | Unit | §6.3 | a `spawnFailed("… /Users/…")` maps to a fixed `reason`, and the absolute path never appears in `evidence` |
| 13 | `test_t7_tcc_row_mapper_pure_fn` | Unit | AC-4 pure mapper | table-test row→`{service,principal,state}`; no-matching-row ⇒ `principal_not_found` |
| 14 | `test_t7_array_grows_by_two_tcc_context` | Contract | AC-7 order | exact-id array places `permissions.launch_context`,`permissions.tcc_cross_context` between `permissions.post_event_access` and `system.macos_version` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–12, 14.
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — case 13 (pure mapper) + array update. Consider a dedicated `Tests/LogicProMCPTests/TCCCrossContextTests.swift` for the mapper/redaction table (cases 11–13) if it keeps the enterprise file lean.

### 3.3 Mock / Setup Required
- `SetupDoctor.Runtime` seams: `launchContext: () -> (context: String, hint: String)` (default `("terminal","…")`), `tccQuery: () -> TCCQueryOutcome` (default: a grant-confirmed outcome so healthy baselines stay `.ok`/`pass`). `.production` wires the ancestor-walk + the `immutable=1` sqlite3 SELECT via `runCommand("/usr/bin/sqlite3", …)` (allowlisted, T1).
- The row-mapper + redaction + classifier are **pure functions** taking fixture inputs — no live TCC.db in unit tests.

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `Runtime` +2 seams; `launchContextCheck` (N9), `tccCrossContextCheck` (N10); `TCCQueryOutcome` enum; pure `mapTCCRows(...)`, `redactPrincipal(...)`, `classifyLaunchContext(...)`; insert 2 `timed { }` appends after `postEventAccessCheck` (T2) and before `macOSVersionCheck` (generate :253); +2 anchors |
| Tests | Modify/Create | N9/N10 + pure mappers + redaction + array/count |

### 4.2 Implementation Steps (Green Phase)
1. `classifyLaunchContext`: pure fn over `(ancestryBundleIds, cfBundleIdentifier, termProgram)` applying the R9 precedence. Table-test it (case 2).
2. `launchContextCheck` (N9): always `pass`; summary + evidence per AC-2 (basename-only redaction on path-attributed hints, C7).
3. Define `TCCQueryOutcome` (e.g. `.rows([TCCRow])`, `.dbUnopenable`, `.toolUnavailable`, `.schemaMismatch`). `.production` builds the `file:…?immutable=1` URI, runs the fixed literal SELECT (column-addressed) via `runCommand("/usr/bin/sqlite3", …)` for both user + system DBs, and classifies the outcome. Verify URI-filename recognition; on non-recognition ⇒ `.toolUnavailable` ⇒ `skipped tcc_query_unavailable`.
4. `mapTCCRows`: pure — reduce returned rows to `{service, principal_hint, state}` for the closed MCP-principal set; **redact** everything else. No matching row ⇒ signal `principal_not_found`.
5. `tccCrossContextCheck` (N10): map `TCCQueryOutcome`→status/reason per AC-5/AC-6. Never `.fail`. Summary always states live-probe authority.
6. Insert 2 appends after the N1 append (T2) and before `macOSVersionCheck` (:253). Add anchors, bump array + count.

### 4.3 Refactor Phase
- Keep the SELECT column list + service/identifier constants in one place so a schema-drift fix touches a single site; the `tcc_schema_mismatch` reason fires when a named column is absent.

## 5. Edge Cases
- E4 FDA absent (case 7); E9 sqlite3 absent / URI unrecognized / schema drift (cases 8/9); E18 no matching principal (case 6).

## 6. Review Checklist
- [ ] Red → Green → Refactor green
- [ ] N10 **never** `.fail` — max downgrade `.warn` (D5, case 10)
- [ ] `immutable=1` URI open; live/release E2E (T9) asserts no `-wal`/`-shm`/`-journal` sidecar
- [ ] Redaction is default-deny — only `{service, principal_hint, state}` egress (cases 11/12)
- [ ] Fixed literal SQL, column-addressed, Swift-side principal match (no dynamic WHERE)
- [ ] N9 always `pass` (never degrades the aggregate)
- [ ] array/count +2; no dead-`#expect`

## 7. Out of Scope (explicit)
- **N10 default-on vs opt-in**: signed off **default-on** (D6/OQ-2). A boomer opt-in proposal routes to orchestrator escalation — **do not** unilaterally add a `--check-tcc` flag.
- **No live TCC.db in unit tests** — pure mappers on frozen fixtures; the real `immutable=1` open is validated in T9's live/release E2E.
- **N10 never replaces the live probe** — enrichment only (D5).
- **No server runtime / health change** (NG3/NG1). **`blocked_by` table + resolver** are **T1** (N9/N10 use `reason`, not `blocked_by` — environmental gates).
- **T2's PostEvent** is a semantic no-dep for N9's launch_context; sequence after T2 only to inherit the fixture posture (avoid count/fixture churn).
