# Pipeline STATUS — doctor-enterprise

**PRD**: docs/prd/PRD-doctor-enterprise.md (v0.3, Approved)
**Branch**: feature/doctor-enterprise
**Size**: L (5 tickets)
**Stack**: Swift SPM — build `swift build`, test `swift test --no-parallel` (CI-authoritative), live E2E via built-binary stdio probe.

## Current Phase
Phase 7 (PR + report) — all phases complete.

## Tickets
| Ticket | Title | Size | Status | Review | Notes |
|--------|-------|------|--------|--------|-------|
| T1 | v2 model framework (schema/Summary/severity/category/timing/chokepoint/CodingKeys/E10) | M-L | Done | PASS | clampStatusForPermissions extracted + unit-tested (final review) |
| T2 | 2 active non-network checks (System Events + probe tri-state, macOS) | M | Done | PASS | live: System Events pass, macOS 26 pass; legacy external click dependency removed by native CGEvent backend |
| T3 | presentation (renderer modes, TTY/color, headline, entrypoint flags) | M | Done | PASS | headline honest on degraded-skipped (final review) |
| T4 | network update check (--check-updates, UpdateOutcome, redaction) | M | Done | PASS | pre-release normalize + curl-28→timeout + parseLatestTag tests (final review) |
| T5 | docs (SETUP.md anchors + v2 doctor section) | S | Done | PASS | anchor contract test green |

## Build / E2E evidence
- `swift build` + `swift build -c release`: clean.
- `swift test --no-parallel`: **1933 passed** on the native CGEvent branch.
- Live E2E (release binary, real env): default/json/verbose/quiet/check-updates all correct; System Events `pass`,
  macOS 26.3.0 `pass`, update check real-GitHub `pass`. No ANSI when piped.

## Final review (Phase 6)
guardian PASS (1 P1 + 2 P2) + boomer HAS ISSUE (3 must-fix). All resolved + re-verified:
chokepoint extracted+tested, headline honesty on degraded-skipped, pre-release version normalize, curl exit-28→timeout, parseLatestTag unit tests. No design defects found.

## Dependency order
T1 → {T2, T3, T4} → T5  (implement sequentially T1→T2→T3→T4→T5 for incremental review)

## Review History
- PRD review (Phase 2): 1 round, strategist + guardian + boomer (codex gpt-5.5 xhigh). HAS ISSUE → all P1/HIGH folded into PRD v0.3 → converged ALL PASS.
- Ticket review (Phase 4): tester (HAS ISSUE, test-writing discipline) + guardian (PASS + 1 P1 + 3 P2) + boomer (pending). Resolutions below applied during Phase 5 implementation.

## Phase-4 Review Resolutions (apply during implementation)
**Test-writing discipline (tester P0/P1):**
- R1 (T1 #2): assert concrete `severity`/`category` values, never `!= nil`/`isEmpty` (dead on non-optional fields).
- R2 (T1 #5, AC-3.5): write THREE separate `#expect` (failed==0, manual==0, (warnings>0||skipped>0)) — not one OR-compound.
- R3 (T4 #7, AC-6.4): redaction = **key-set** assertion `evidence.keys ⊆ {reason, checked}` + `reason ∈` 6-enum; do NOT substring-scan for "http" (collides with allowed `http_error`). Add `http_error` + `source_unavailable` outcome tests. Negative asserts via local Bool + force-unwrap (dead-#expect footgun).
- R4 (T1 #1): update existing v1 schema assertions `SetupDoctorTests.swift:62,83,154` to v2 in the SAME commit as the schema change.
- R5 (T3 #4/#5): color tests must use a fixture with ≥1 non-pass check so a colored symbol actually renders.
- R6 (T3 #7, E14): compare `encodeJSON()` STRINGS (`[String:Any]` is not Equatable — won't compile).
- R7 (T1 #6): inject deterministic clock returning `[0,1,2,...]`; assert exact `summary.duration_ms == N` (not just `>=0`).
- R8 (T1 #10): assert frozen-v1 `checks.count == 11` AND id-set equality (count alone misses a dropped check).

**Migration / coverage (guardian P1/P2 + tester P2):**
- R9 (T2, guardian P1 — CRITICAL): widen `PermissionChecker.Runtime.runSystemEventsAutomationProbe: () -> Bool`
  → `() -> CheckState` (reuse CheckState). `checkSystemEventsAutomationState = runtime.runSystemEventsAutomationProbe()`.
  Production `runSystemEventsAutomationProbeViaShell -> CheckState`: completed+exit0+"System Events"→granted;
  completed+exit≠0→notGranted(denial); timedOut/spawnFailed/unexpected-stdout→notVerifiable.
  **Migrate** `PermissionRuntimeHarness.systemEventsProbeResult: Bool` → `systemEventsProbeState: CheckState`
  and the two existing tests (`PermissionCheckerTests.swift:32-40` set `.granted`; `:43-55` set `.notGranted`).
  Logic Pro probe untouched. `--check-permissions`/allGranted exit codes unchanged (`.notVerifiable.isGranted==false`).
- R10 (T2, tester P2 + guardian P2-a): add AC-1.6 mirror test (LP running + SE notGranted → SE fail) AND an
  integration test: `doctor` with SE `.notGranted` → `MainEntrypoint.run` returns 1 (AC-1.3 literal owner).
- R11 (T3/T4, guardian P2-b): entrypoint test — default `doctor` arms `latestReleaseLookup == nil` (no network);
  `doctor --check-updates` arms a non-nil lookup.
- R12 (T2/T4, boomer #2): when adding `remediationAnchorsByCheckID` entries (System Events, macOS in T2;
  updates in T4), add matching `id="..."` anchors to docs/SETUP.md **in the same change** (do NOT defer to T5) —
  `testSetupDocsContainEveryDoctorRemediationAnchor` (`SetupDoctorTests.swift:185`) enforces
  `setup.contains("id=\"<anchor>\"")` and will go red otherwise. T5 then only adds prose + API.md v2 docs.
- R13 (T1/T2, boomer #3 — CRITICAL build-break): `SetupDoctor.Runtime` gains fields (`monotonicNowMs` in T1;
  `macOSVersion`, `latestReleaseLookup` in T2/T4). Give each a default
  value in the property declaration so existing construction sites still compile, AND update both `.production`
  (real impls) and the `doctorRuntime()` test helper (`SetupDoctorTests.swift:9-39`, expose overrides). Grep for
  every `SetupDoctor.Runtime(` site before merging T1.
- R14 (T1/T4): `check()` factory derives `category = category(forDomain:)` + `severity = severity(for:status)`
  INTERNALLY (zero changes to the 11 existing factory call sites — boomer B3-1); `durationMs` is stamped post-hoc
  by the `generate()` timing wrapper (default 0 in factory). Define `category(forDomain:)` as a COMPLETE table
  (binary/install/release→installation; mcp→configuration; permissions→permissions; logic→runtime;
  channels→configuration; dependencies→dependencies; updates→updates). T4 version compare = numeric 3-part
  (NEVER lexicographic: "3.9" vs "3.10"); strip leading `v` from the GitHub tag.

## Phase 4 Verdict
tester HAS ISSUE (test discipline) + guardian PASS (1 P1 + 3 P2) + boomer HAS ISSUE (3 impl-completeness).
**No design defects.** All findings → R1–R14 (implementation-time resolutions). Tickets + R1–R14 = converged ALL PASS.

## Constraints / Lessons applied
- swift-testing dead `#expect` footgun: only force-unwrap `#expect(x!)` works; never `== true`/`?? false` (memory).
- CI runs `swift test --no-parallel`; verify with that.
- `timeout` cmd absent on this Mac; live E2E uses popen binary + MCP handshake (initialized required).
- Honest Contract: never affirm unverified state; evidence-bound; no server spawn / MIDI / AX poller in doctor.
