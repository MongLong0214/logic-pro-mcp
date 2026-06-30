# PRD: Enterprise-Grade Setup Doctor

**Version**: 0.3
**Author**: dev-pipeline (orchestrator)
**Date**: 2026-06-30
**Status**: Approved
**Size**: L (implemented as 4 independently-revertable tickets — see §App-A)

> Reference model: [`code-yeongyu/lazycodex`](https://github.com/code-yeongyu/lazycodex) `doctor` command
> (`plugins/omo/dist/cli/doctor/**`, `skills/lcx-doctor/SKILL.md`). We adopt its
> *structured, timed, severity-graded, multi-mode, evidence-bound* diagnostic model
> and adapt it to this project's Swift/macOS/Logic-Pro surface and its existing
> read-only / run-before-startup Honest Contract.
>
> v0.2 folds in Phase-2 team review (strategist + guardian + boomer). Each P1/top-3
> resolution is tracked in §App-B.

---

## 1. Problem Statement

### 1.1 Background
`LogicProMCP doctor` (`Sources/LogicProMCP/Utilities/SetupDoctor.swift`, 691 lines, 27 tests)
already emits a `logic_pro_mcp_doctor.v1` report with 11 checks, evidence dicts, and per-check
remediation. It is honest and read-only. But measured against a mature reference doctor
(lazycodex), it is missing the operational affordances enterprise operators expect:

- **No timing.** Operators cannot see which check is slow or how long a run took.
- **No summary block.** The output is a flat list; there is no `passed/failed/warn` roll-up that a
  human or a monitoring scraper can read at a glance.
- **One output shape for humans.** Only `[pass] id - summary` + a single-mode JSON. No verbose
  (evidence-inline) mode, no quiet (failures-only) mode, no color/symbols, no "next action" headline.
- **Severity is implicit.** Every non-pass is rendered the same; there is no error-vs-warning grading
  and no "fix this first" ordering.
- **Coverage gaps in checks** that map to real, already-known failure modes:
  - `permissions.automation_system_events` — System Events automation is collected in
    `PermissionChecker.PermissionStatus.systemEventsAutomationState` and is part of `allGranted`
    (a *hard* requirement: MIDI import / tempo-dialog drive `tell application "System Events"`, issue #188),
    yet the doctor surfaces only Logic Pro automation (`SetupDoctor.swift:153`) and silently drops it.
  - `dependencies.cliclick` — `cliclick` is a real runtime dependency of the bounce/export helper
    (`bounce_helper_dependency_missing: cliclick`); a missing install was a prior release blocker, yet
    the doctor never checks it. The runtime accepts it only via `ProjectExportExecutor.resolveTrustedCliclick`
    (strict: 3 canonical paths + `LOGIC_PRO_MCP_CLICLICK` override + non-group/other-writable parent).
  - `system.macos_version` — the package requires macOS 14+ (`Package.swift: platforms: [.macOS(.v14)]`);
    the doctor never validates the OS.
  - `updates.latest_release` — no way to learn the installed version is behind the latest release.

### 1.2 Problem Definition
The doctor reports *what it checks* honestly, but (a) omits several already-required checks, and
(b) lacks the structured timing/summary/severity/output-mode affordances that make a doctor usable as
an enterprise support and CI gate tool.

### 1.3 Impact of Not Solving
- Operators hit `bounce_helper_dependency_missing: cliclick` or a denied System Events target (#188)
  at *runtime* even though `doctor` reported "ok" — eroding trust in the doctor.
- Support cannot ask a user to "paste the doctor summary"; there is no summary.
- CI/monitoring cannot scrape a counts roll-up or per-check timing.

## 2. Goals & Non-Goals

### 2.1 Goals
- [ ] G1: Surface every permission the runtime treats as required — add
      `permissions.automation_system_events` fed by the already-collected `systemEventsAutomationState`.
      **The report status must never be `ok` when `permissionStatus.allGranted == false`**, enforced by a
      single explicit chokepoint (not an emergent consequence) — see §4.2.
- [ ] G2: Add coverage checks for real dependencies/environment: `dependencies.cliclick` (reusing the
      runtime's own `resolveTrustedCliclick`), `system.macos_version`, and an opt-in `updates.latest_release`.
- [ ] G3: Add a structured `summary` roll-up (`total/passed/failed/warnings/manual/skipped` +
      total `duration_ms`) and per-check `duration_ms`, surfaced in both human and JSON output.
- [ ] G4: Add severity grading (`error`/`warning`/`info`) and a `category` per check; render a
      "next action" headline that names the single most important remediation first.
- [ ] G5: Add human output modes — default, `--verbose` (evidence inline), `--quiet` (status line +
      failures only) — plus TTY/`NO_COLOR`-aware symbols & color. `--json` stays the machine contract.
- [ ] G6: Evolve the report schema to `logic_pro_mcp_doctor.v2` as a **field-superset** of v1: every v1
      key keeps its **name, semantics, and value**; new keys are additive; field *order* is not part of
      the contract (`JSONHelper` encodes with `.sortedKeys`). The `schema` string is the **one** field
      that intentionally changes (`v1`→`v2`); consumers MUST prefix-match `logic_pro_mcp_doctor.`,
      never exact-equal `...v1`.
- [ ] G7: Preserve the read-only / run-before-startup Honest Contract: no CoreMIDI ports, no AX
      pollers, no spawning the registered server. Network is touched only under explicit `--check-updates`.

### 2.2 Non-Goals
- NG1: No change to `--check-permissions` / `install` / `uninstall` / `--approve-channel` behavior or
      exit codes. **One narrowly-scoped exception (review-driven):** the System Events probe seam in
      `PermissionChecker` is widened from `() -> Bool` to a tri-state so a probe that *could not run*
      (timeout / spawn failure / unexpected output) maps to `.notVerifiable` instead of being collapsed to
      `.notGranted` ("denied"). This is required for doctor honesty (a hung osascript must not be reported
      as a permission denial) and is the whole point of the System Events coverage gap (#188). `allGranted`
      and `--check-permissions` **exit codes are unchanged** (`.notVerifiable.isGranted == false`); only the
      human summary text becomes honest ("could not verify" vs "denied").
- NG2: No live mutation/repair ("doctor --fix"). Doctor diagnoses; it never changes the user's
      install, config, or permissions.
- NG3: No new permission *probing* mechanism — `permissions.automation_system_events` consumes the
      `PermissionStatus` the entrypoint already gathers; it does not add a new TCC prompt.
- NG4: No network in the default run. `updates.latest_release` is opt-in and degrades to `skipped`
      when offline / source unavailable / parse failure / timeout.
- NG5: No removal/renaming of v1 field **names**, check IDs, or `domain` values. (`domain` stays a free
      string for back-compat; the new `category` enum is an additive parallel taxonomy — see §4.2.)
- NG6: Not porting lazycodex's "drift vs latest source checkout" git-clone comparison.
- NG7: No `critical` field. (Dropped after review: redundant with `severity == .error` + the existing
      stable check order; exit code stays `status == .failed → 1`.)

## 3. User Stories & Acceptance Criteria

### US-1: Complete required-permission coverage
**As an** operator, **I want** the doctor to report the System Events automation permission,
**so that** a "doctor passes" run can never hide the #188 denied-System-Events failure mode.

**Acceptance Criteria:**
- [ ] AC-1.1: Given `systemEventsAutomationState == .granted`, then check
      `permissions.automation_system_events` exists with status `pass`.
- [ ] AC-1.2: Given `.notGranted`, then status is `fail` with a `system_settings` remediation pointing
      at "Automation → System Events".
- [ ] AC-1.3 (exit code): Given `.notGranted`, when doctor runs, then the aggregate report status is
      `failed` and the process exit code is `1` (`MainEntrypoint` integration).
- [ ] AC-1.4: Given the probe could not run (osascript timeout / spawn failure / unexpected output),
      `systemEventsAutomationState` is `.notVerifiable` and the check status is `manual` (the doctor must
      never report `fail`/"denied" for a state it could not verify). With the NG1 probe-seam widening,
      this is a **live-reachable** path, exercised in production and tested via an injected timed-out /
      spawn-failed probe. (TCC denial — osascript ran and returned non-zero/wrong output for an
      *allowed-to-run-but-denied* target — still maps to `.notGranted` → `fail`.)
- [ ] AC-1.5 (monotonicity, enforced): For **every** `PermissionStatus` with `allGranted == false`
      (accessibility false, OR automationLogicPro not-granted, OR automationSystemEvents not-granted),
      the report status is **not** `ok`. This is enforced by the §4.2 chokepoint and tested by feeding
      each of the three inputs false independently.
- [ ] AC-1.6 (independence): The System Events verdict does not inherit Logic Pro's not-running state —
      with Logic Pro closed, `permissions.automation_logic_pro` may be `manual` while
      `permissions.automation_system_events` is independently `pass`/`fail`.

### US-2: Dependency & environment coverage
**As an** operator, **I want** doctor to verify `cliclick` and the macOS version,
**so that** runtime dependency failures surface at diagnosis time, not mid-operation.

**Acceptance Criteria:**
- [ ] AC-2.1: `dependencies.cliclick` resolves cliclick **through the same resolver the runtime uses**
      (`ProjectExportExecutor.resolveTrustedCliclick`): a trusted path (one of `/opt/homebrew/bin`,
      `/usr/local/bin`, `/usr/bin` cliclick, or the `LOGIC_PRO_MCP_CLICLICK` override) whose parent dir is
      not group/other-writable → `pass`, with the resolved path in evidence.
- [ ] AC-2.2: Given cliclick is **not** resolvable by `resolveTrustedCliclick` but `commandExists("cliclick")`
      is true (present on PATH only, or parent dir writable, or non-canonical path), then status is `warn`
      with summary "present but not at a trusted path / parent dir is writable" and evidence noting the
      distinction. (Not `pass` — it would fabricate a green the runtime won't honor.)
- [ ] AC-2.3: Given cliclick absent everywhere, then `warn` (not `fail` — it gates only bounce/export)
      with a `command` remediation `brew install cliclick`.
- [ ] AC-2.4: Given macOS major version ≥ 14, then `system.macos_version` is `pass` with the version
      string in evidence. A well-formed future version (e.g. 15, 26) also passes (no upper bound, major-only).
- [ ] AC-2.5: Given macOS major version < 14, then `system.macos_version` is `fail`.

### US-3: Structured summary & timing
**As a** support engineer / CI gate, **I want** a counts roll-up and per-check timing,
**so that** I can read health at a glance and spot slow checks.

**Acceptance Criteria:**
- [ ] AC-3.1: The JSON report contains a `summary` object with integer fields `total`, `passed`,
      `failed`, `warnings`, `manual`, `skipped`, and a numeric `duration_ms`, where
      `passed + failed + warnings + manual + skipped == total == checks.count`.
- [ ] AC-3.2: Each check carries a non-negative numeric `duration_ms`.
- [ ] AC-3.3: The human output prints a summary line, e.g. `summary: 9 passed, 1 failed, 1 warning (1234ms)`.
- [ ] AC-3.4: Checks run **sequentially** and are **non-throwing**; timing uses an injected **monotonic**
      clock. `summary.duration_ms` equals the sum of per-check durations and is therefore ≥ the max
      single-check duration and ≥ 0. (Deterministic injected clock makes tests stable.)
- [ ] AC-3.5 (status↔counts formula): When `status == degraded`, then `(warnings > 0 || skipped > 0)`
      and `failed == 0 && manual == 0`. When `status == ok`, then `warnings == 0 && skipped == 0 &&
      failed == 0 && manual == 0`. (Documents the existing `aggregateStatus` precedence against the new counts.)
      A `skipped` update check (offline `--check-updates`) therefore degrades the aggregate to `degraded` —
      consistent with v1 skipped semantics (`aggregateStatus` already treats `warn||skipped`→`degraded`); this
      honestly means "could not fully verify", not "broken install". `aggregateStatus` is **not** modified.

### US-4: Severity, category, and "next action"
**As an** operator, **I want** the most important fix named first, with severity and category,
**so that** I know what to do before reading every line.

**Acceptance Criteria:**
- [ ] AC-4.1: Each check has a `category` from {installation, configuration, permissions, dependencies,
      runtime, updates} and a `severity` from {error, warning, info}. The status→severity mapping is total:
      `fail→error`; `warn→warning`; `manual→warning`; `skipped→info`; `pass→info`.
- [ ] AC-4.2: When ≥1 check is non-pass, the human output begins with a one-line headline naming the
      single highest-priority remediation, ordered by severity (`error` before `warning`; `info` never
      headlined) and, within a severity, by the stable check order.
- [ ] AC-4.3: When all checks pass, the headline states the install is healthy.

### US-5: Output modes & color
**As a** human in a terminal, **I want** readable, optionally-verbose output,
**so that** I can scan or dig in as needed without parsing JSON.

**Acceptance Criteria:**
- [ ] AC-5.1: `doctor` (default) prints headline + summary + one line per check (symbol + id + summary),
      and a `→ remediation` line only for non-pass checks.
- [ ] AC-5.2: `doctor --verbose` additionally prints each check's evidence key/values and `duration_ms`.
- [ ] AC-5.3: `doctor --quiet` prints only the headline, the summary line, and the non-pass checks.
- [ ] AC-5.4: Color/symbols are emitted only when stdout is a TTY (`isatty(STDOUT_FILENO)`) and `NO_COLOR`
      is unset; otherwise output is plain ASCII (`[pass]`-style). TTY/`NO_COLOR` detection is injected into
      the entrypoint so tests pin both branches.
- [ ] AC-5.5: `--json` takes precedence over `--verbose`/`--quiet`/color; the JSON bytes are identical
      regardless of those flags (machine contract is stable).

### US-6: Opt-in update check
**As an** operator, **I want** `doctor --check-updates` to tell me if I'm behind,
**so that** I can decide to upgrade — without the default run ever touching the network.

**Acceptance Criteria:**
- [ ] AC-6.1: Without `--check-updates`, no `updates.latest_release` check is emitted and no network call is made.
- [ ] AC-6.2: With `--check-updates` and a reachable source, `updates.latest_release` is `pass` when
      installed == latest, `warn` when behind (remediation: upgrade command), with both versions in evidence.
- [ ] AC-6.3: With `--check-updates` but offline / source unavailable / parse failure / timeout, the check is
      `skipped` — never `fail`, never a fabricated "up to date".
- [ ] AC-6.4 (secret redaction): On `--check-updates` failure, `evidence["reason"]` is one of a fixed
      enumerated set `{offline, source_unavailable, parse_error, http_error, timeout}` and the evidence
      NEVER contains process stderr verbatim, environment values, a URL with query/token, or header contents.
      The update source is an **unauthenticated** read (no `Authorization` header, no token), so no secret
      is in scope to leak.

## 4. Technical Design

### 4.1 Architecture Overview
All work stays inside the doctor subsystem and its entrypoint:
- `Sources/LogicProMCP/Utilities/SetupDoctor.swift` — extend the model (additive fields + `Summary` +
  `headline`), add the new check functions, add per-check monotonic timing, summary computation,
  severity/category derivation, the §4.2 monotonicity chokepoint, and the 3-mode + color renderer.
- `Sources/LogicProMCP/MainEntrypoint.swift` — parse `--verbose`/`--quiet`/`--check-updates`, choose the
  renderer + verbosity, and pass TTY/`NO_COLOR` detection (injectable) in. `--json` precedence preserved.
- `docs/SETUP.md` / `docs/API.md` — remediation anchors for new check IDs + v2 field docs.
- `Tests/LogicProMCPTests/` — TDD; add `SetupDoctorEnterpriseTests.swift` (new) for the v2 surface to
  keep `SetupDoctorTests.swift` focused; update the v1 contract test for the new ID list + schema string.

Execution is **sequential**: each check closure runs in declared order, wrapped by a monotonic-clock
delta to populate `duration_ms`; checks are non-throwing so no exception isolation is required (E9).

The `Runtime` injection seam is extended with: `cliclickPath: () -> String?` (→ `resolveTrustedCliclick`),
`cliclickPresentOnPath: () -> Bool` (→ `commandExists("cliclick")`), `macOSVersion: () -> OperatingSystemVersion?`
(nil ⇒ unreadable → `skipped`, E12), `monotonicNowMs: () -> Double`, and a **typed** update-lookup seam
`latestReleaseLookup: (() -> UpdateOutcome)?` (nil ⇒ update check not run; non-nil only when `--check-updates`
is passed). `UpdateOutcome` is an enum `.found(version: String) | .offline | .sourceUnavailable | .parseError
| .httpError | .timeout` so the check body can write an accurate enumerated `reason` (AC-6.3/6.4) instead of
collapsing every failure to `nil`. `.production` wires real implementations (`resolveTrustedCliclick`,
`ProcessInfo`, `DispatchTime`, the curl→gh lookup); tests inject fakes. No new external frameworks.

### 4.2 Data Model Changes
Schema bumps to `logic_pro_mcp_doctor.v2`. **`Check` gains an explicit `CodingKeys` enum that enumerates
ALL keys** — the existing six (`id`, `domain`, `status`, `summary`, `evidence`, `remediation`) PLUS the new
ones — so adding coding keys can never silently rename a v1 key. A new `Summary` struct is added to `Report`.

```
enum Category: String, Codable { installation, configuration, permissions, dependencies, runtime, updates }
enum Severity: String, Codable { error, warning, info }

struct Check (v2):                              // explicit CodingKeys lists every key
  id, domain, status, summary, evidence, remediation   // v1 — names/semantics/values unchanged
  + category: Category        // key "category"
  + severity: Severity        // key "severity"  (derived from status; total mapping AC-4.1)
  + durationMs: Double        // key "duration_ms"

struct Summary (new):
  total, passed, failed, warnings, manual, skipped: Int   // keys as named
  durationMs: Double                                       // key "duration_ms"

struct Report (v2):
  schema (= "logic_pro_mcp_doctor.v2"), status, version, installSource, checks   // v1 — unchanged names/semantics
  + summary: Summary          // key "summary"
  + headline: String          // key "headline" — human-prose advisory; NOT a machine-stable field
```

**Monotonicity chokepoint (G1/AC-1.5):** `generate()` computes `aggregateStatus(checks)` (unchanged v1
precedence: fail→failed > manual→manual_action_required > warn|skipped→degraded > ok) and then applies a
single explicit guard:

```
var status = aggregateStatus(checks)
// Honesty chokepoint: the report can never claim ok while a required permission is ungranted.
// This OWNS AC-1.5 directly rather than relying on the System Events / accessibility checks each
// happening to be non-pass. allGranted == accessibility && automationLogicPro && automationSystemEvents.
if !permissionStatus.allGranted && status == .ok { status = .degraded }
```

`headline` is computed from the highest-severity non-pass check (AC-4.2) or the healthy message (AC-4.3).
It is present in JSON (additive) but documented as advisory prose — consumers parse `summary`/`checks`, not `headline`.

`domain` vs `category`: `domain` is the v1 free-string (retained, NG5); `category` is the additive closed
enum. Their values often coincide (e.g. domain "permissions" ↔ category `permissions`); `category` exists to
give a stable typed taxonomy and the `dependencies`/`updates` buckets that have no v1 domain. The mapping is
deterministic and centralized in one function.

### 4.3 API Design
CLI surface (no HTTP API):

| Command | Description |
|---------|-------------|
| `LogicProMCP doctor` | default human report (headline + summary + per-check) |
| `LogicProMCP doctor --verbose` | adds evidence + per-check `duration_ms` to human output |
| `LogicProMCP doctor --quiet` | headline + summary + non-pass checks only |
| `LogicProMCP doctor --json` | machine report (v2 field-superset; identical regardless of verbosity/color) |
| `LogicProMCP doctor --check-updates` | additionally runs the opt-in `updates.latest_release` check |

Exit codes (unchanged semantics): aggregate `failed` → 1; `ok`/`degraded`/`manual_action_required` → 0.
Exit codes are verbosity-independent.

### 4.4 Key Technical Decisions

| Decision | Options Considered | Chosen | Rationale |
|----------|-------------------|--------|-----------|
| Schema evolution | mutate v1 / v2 superset / parallel endpoint | **v2 field-superset** | Additive keys keep v1 readers working; one schema; mirrors lazycodex's single rich model. Schema string is the one intended change (prefix-match guidance, G6). |
| System Events data source | new TCC probe / reuse `PermissionStatus` | **reuse** | Already gathered by `permissionCheck()`; no second TCC prompt (NG3). |
| System Events `.notVerifiable` | drop AC / doctor-only total mapping / widen the probe seam | **widen probe seam to tri-state (NG1 exception)** | Collapsing a hung/spawn-failed osascript to `.notGranted` reports "denied" for an un-runnable probe — a false-RED that violates the Honest Contract. Tri-state (`denial→notGranted`, `could-not-run→notVerifiable`) makes `→manual` honest and live-reachable. Exit codes unchanged. |
| cliclick check | re-implement path search / reuse `resolveTrustedCliclick` | **reuse the runtime resolver** | Re-implementing a looser search is exactly how doctor/runtime drift produces false-greens (#1.3). Reuse = honest. |
| cliclick severity | fail / warn | **warn** | cliclick gates only bounce/export, not core MCP; `fail` over-states. `warn`→`degraded`→exit 0. |
| `critical` field | keep / drop | **drop (NG7)** | Redundant with `severity == .error` + stable order; no AC needs it; exit stays `failed→1`. |
| Timing clock | wall-clock `Date()` / monotonic | **injected monotonic** (`DispatchTime`-based) | Wall-clock can step backward (NTP) → negative duration; monotonic guarantees AC-3.2/3.4. |
| Update source | `gh` primary / `curl` primary | **unauthenticated `curl` to `api.github.com/.../releases/latest` primary, `gh release view` fallback** | End-users (Homebrew/release-binary) won't have `gh`; `gh`-first ⇒ skipped for nearly everyone. Unauthenticated ⇒ no token in scope (AC-6.4). Both degrade to `skipped`. |
| Update timeout | unspecified / explicit | **`BoundedProcessRunner` timeout 3.0s** (vs 1.5s local) | Bounds the only network call; timeout → `skipped` (AC-6.3, E11). |
| Color/symbols | always / TTY-gated | **TTY + `NO_COLOR` gated, plain ASCII fallback** | Keeps pipes/CI clean; non-TTY fallback preserves a v1-compatible human shape. |

## 5. Edge Cases & Error Handling

| # | Scenario | Expected Behavior | Severity |
|---|----------|-------------------|----------|
| E1 | System Events check supplied `.notVerifiable` (forward-compat / injected) | `manual`, not `pass`/`fail` (AC-1.4) | High |
| E2 | cliclick present only on PATH (not a trusted canonical path) | `warn` "present but not trusted", NOT `pass` (AC-2.2) | High |
| E3 | cliclick at a trusted path but parent dir group/other-writable | `resolveTrustedCliclick` rejects → `warn` (AC-2.2) | Med |
| E4 | cliclick absent everywhere | `warn` + `brew install cliclick` (AC-2.3) | Med |
| E5 | macOS version reads major-only (e.g. "14") or future ("15"/"26") | `pass` (major ≥ 14, no upper bound) (AC-2.4) | Low |
| E6 | `--check-updates` offline / source unavailable | `skipped` w/ enumerated reason (AC-6.3/6.4) | Med |
| E7 | `--check-updates` malformed/parse failure | `skipped` w/ `parse_error` (never `fail`) | Low |
| E8 | stdout not a TTY (piped/redirected) | plain ASCII, no escape codes, even without `--quiet` (AC-5.4) | High |
| E9 | `--quiet` and `--verbose` both passed | `--verbose` wins (more info); documented; no crash | Low |
| E10 | v1 JSON consumer reads v2 output | all v1 key **names** present & identical values; new keys ignored; `schema` is `...v2` | High |
| E11 | `--check-updates` with a hung/slow `gh`/`curl` | bounded runner 3.0s timeout → `skipped` (timeout), no hang | Med |
| E12 | macOS `operatingSystemVersion` unreadable (hypothetical on macOS) | `skipped` w/ reason (never fabricate `pass`) | Low |
| E13 | Logic Pro not running | `permissions.automation_logic_pro` = `manual`; `permissions.automation_system_events` independently `pass`/`fail` (AC-1.6) | Med |
| E14 | `--json` + `--verbose` together | `--json` wins; JSON bytes identical to plain `--json` (AC-5.5) | Med |

## 6. Security & Permissions

### 6.1 Authentication
N/A — local CLI diagnostic.

### 6.2 Authorization
N/A — no roles. Doctor is strictly read-only (NG2): no config/install/permission mutation.

### 6.3 Data Protection
Evidence dicts must not leak secrets. The update check is an **unauthenticated** public-release read
(no token in scope); on failure, evidence carries only an enumerated reason (AC-6.4), never raw stderr,
env, tokened URLs, or headers. Claude-config reading remains the existing read-only parse (no change).

## 7. Performance & Monitoring

| Metric | Target | Measurement |
|--------|--------|-------------|
| Default `doctor` wall time | typically ≤ ~3s (no network) — **empirical, not a hard bound**; checks run serially and worst-case = sum of bounded timeouts (codesign+xattr+brew dominate; the 3 new local checks add ~0: `sw_vers` is instant, cliclick is a path probe, System Events is already in the permission path) | `summary.duration_ms` |
| Per local external command | bounded by `BoundedProcessRunner` (≤1.5s) | per-check `duration_ms` |
| `--check-updates` added latency | bounded network call (≤3.0s), opt-in only | `updates.latest_release.duration_ms` |

### 7.1 Monitoring & Alerting
The `summary` block + per-check `duration_ms` + stable check IDs are the scrapeable surface. No runtime telemetry added.

## 8. Testing Strategy

### 8.1 Unit Tests (TDD — Red first for every ticket)
- New checks: System Events (pass/fail/manual + AC-1.5 monotonicity with each input false independently +
  AC-1.6 independence), cliclick (trusted→pass / PATH-only→warn / writable-parent→warn / absent→warn,
  via injected `resolveTrustedCliclick` + `commandExists`), macOS (≥14 pass / future pass / <14 fail / unreadable skipped),
  update check (up-to-date pass / behind warn / offline|parse|timeout skipped + AC-6.4 redaction).
- Model/contract: v2 schema string exactly `logic_pro_mcp_doctor.v2`; summary counts invariant
  (Σ == total == checks.count); each check has category/severity/duration_ms; severity↔status total mapping;
  status↔counts formula (AC-3.5).
- Timing: injected monotonic clock yields deterministic, non-negative `duration_ms`; `summary == sum ≥ max`.
- Renderers: default/verbose/quiet line shapes; TTY-on emits symbols/color, TTY-off/`NO_COLOR` emits plain
  ASCII; headline names highest-severity remediation.

### 8.2 Integration Tests (`MainEntrypoint`)
- Flag routing: `--verbose`/`--quiet`/`--check-updates` select the right behavior; `--json` precedence over
  verbosity (AC-5.5/E14); doctor still does not start the server; exit codes preserved (AC-1.3).

### 8.3 Edge Case + Backward-Compat Tests
- Each §5 row (E1–E14) has a dedicated test.
- **E10 superset guard (two-pronged, boomer #2 + guardian):**
  (a) assert the raw v2 JSON contains the literal v1 key strings `"id"`, `"domain"`, `"status"`, `"summary"`,
  `"evidence"`, `"remediation"` (per check) and `"schema"`, `"status"`, `"version"`, `"install_source"`,
  `"checks"` (top level) — catches an accidental rename that a decode-to-model test would miss;
  (b) decode the v2 JSON with a **frozen v1 `Codable` struct** (exact v1 `Report`/`Check`/`Remediation` shape)
  and assert it decodes without error and exposes every v1 check `id`;
  (c) assert `schema == "logic_pro_mcp_doctor.v2"` (the one intended change).

## 9. Rollout Plan

### 9.1 Migration Strategy
No data migration. Schema `v1`→`v2` is a field-superset; document new fields in `docs/API.md`/`docs/SETUP.md`.

### 9.2 Feature Flag
None. New behaviors are additive (summary/timing/severity/category always present in v2) or opt-in flags.

### 9.3 Rollback Plan
3-ticket split (§App-A) keeps the high-risk schema/data change (T1) independently revertable from the
renderer (T2) and the network check (T3). Reverting the PR restores v1 exactly.

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if Delayed |
|-----------|-------|--------|-----------------|
| `PermissionChecker.systemEventsAutomationState` | existing | present | none |
| `ProjectExportExecutor.resolveTrustedCliclick` / `commandExists` | existing | present (internal static) | none |
| `BoundedProcessRunner` | existing | present | none |
| `gh`/network for `--check-updates` | external, opt-in | optional | none (skipped) |

### 10.2 Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| `Check` CodingKeys added carelessly → silent v1 key rename | Med | High | Explicit CodingKeys lists ALL keys; E10(a) literal-key + E10(b) frozen-struct tests |
| Schema-gating consumer breaks on `...v2` | Low | Low | Prefix-match guidance (G6); zero external scrapers found in repo |
| Color codes leak into CI logs | Med | Low | TTY+`NO_COLOR` gating + non-TTY plain fallback (AC-5.4, E8) |
| Timing flakiness | Med | Low | Injected monotonic clock (decision §4.4) |
| Update check hangs | Low | Med | Bounded 3.0s; opt-in; timeout→skipped (E11) |
| Over-engineering | Med | Med | `critical` dropped; every field maps 1:1 to lazycodex + a real gap; boomer gate |

## 11. Success Metrics

| Metric | Baseline | Target | Measurement |
|--------|----------|--------|-------------|
| Required-permission coverage | Logic Pro only | + System Events | new check present & AC-1.5 monotone |
| Checks count | 11 | 14 (+System Events,+cliclick,+macOS) (+updates opt-in = 15) | `summary.total` |
| Doctor test count | 27 | 27 + new TDD specs | `swift test --no-parallel` |
| v1 consumer breakage | n/a | 0 | E10 (a)+(b)+(c) |

## 12. Open Questions / Follow-ups

- [x] OQ-1 (update source): **Resolved** — unauthenticated `curl` to GitHub releases API primary, `gh` fallback (§4.4).
- [x] OQ-2 (exit code under `--quiet`): **Resolved** — exit codes are verbosity-independent (§4.3).
- [x] FOLLOW-UP-1: `PermissionChecker` System Events probe collapsing timeout/spawn-failure to "denied" —
      **now in scope** (T1, NG1 exception): probe seam widened to tri-state so an un-runnable probe maps to
      `.notVerifiable`, not `.notGranted`.
- [ ] FOLLOW-UP-2 (declined for now, YAGNI): a `--json-v1` compatibility flag emitting the v1 schema string.
      Declined: strategist found **zero** external schema-gating consumers in `Scripts/`, `.github/`, `tools/`;
      the prefix-match guidance (G6) + repo test updates suffice. Revisit only if a real strict consumer appears.

---

## App-A: Ticket Split (strategist P1-2)

- **T1 — Data layer (highest risk):** schema v2 superset + explicit `Check` CodingKeys + `Summary` +
  `Category`/`Severity`/`duration_ms` + monotonic timing + monotonicity chokepoint + the 3 non-network
  checks (System Events, cliclick, macOS) + the NG1 `PermissionChecker` System Events probe-seam tri-state
  widening (denial vs could-not-run). Owns E10, schema-version, AC-1.x, AC-3.x.
- **T2 — Presentation layer:** 3 renderer modes + TTY/`NO_COLOR` + headline + `--verbose`/`--quiet`/`--json`
  precedence wiring in `MainEntrypoint`. Owns US-4, US-5, E8/E9/E14.
- **T3 — Network (isolated side effect):** `updates.latest_release` + `--check-updates` + bounded runner +
  redaction. Owns US-6, E6/E7/E11, AC-6.x.
- **T4 — Docs & evidence:** `docs/SETUP.md` anchors + `docs/API.md` v2 fields + remediation-anchor map entries.

## App-B: Phase-2 Review Resolutions

| Source | Issue | Resolution |
|--------|-------|------------|
| boomer #1 | System Events `.notVerifiable` unreachable in production → AC dead | AC-1.4 reworded: total honest mapping, documented production yields pass/fail only, manual branch via injected state; §12 follow-up |
| boomer #2 | `Check` has no CodingKeys; adding `duration_ms` risks renaming v1 keys | Explicit CodingKeys lists ALL keys (§4.2) + E10(a) literal-key + E10(b) frozen-struct tests |
| boomer #3 / strategist P2-2 | `critical: Bool` redundant | Dropped (NG7) |
| guardian P1-1 / strategist P2-6 | cliclick must reuse `resolveTrustedCliclick`, not a looser PATH search | AC-2.1/2.2 mandate the runtime resolver; "or PATH" downgraded to `warn` |
| guardian P1-2 | `allGranted` monotonicity emergent, not enforced | §4.2 explicit chokepoint guard + AC-1.5 per-input tests |
| strategist P1-1 | schema string change breaks exact-equal consumers | G6 prefix-match guidance + v2-exact assertion test |
| strategist P1-2 | split L into independently-revertable tickets | §App-A 4-ticket split |
| strategist P2-1 | "order/position" guarantee unenforceable under `.sortedKeys` | G6 reworded: names+semantics+values, order not contractual |
| strategist P2-3 | monotonic clock not wall-clock | §4.4 injected monotonic |
| strategist P2-4 | reverse update source (curl primary) | §4.4 curl primary, gh fallback |
| strategist P2-5 | `skipped→info` not warning | AC-4.1 total mapping `skipped→info` |
| guardian P2 / boomer | exit-code standalone AC; status↔counts; --json precedence; E11/E12/E13 | AC-1.3, AC-3.5, AC-5.5/E14, E11/E12/E13 added |
| guardian P2 (AC-6.4) | secret-leak guard for update check | AC-6.4 enumerated reasons + unauthenticated source |
| boomer codex #1 (HIGH) | System Events `.notVerifiable` unreachable → false-RED on probe timeout | Probe seam widened to tri-state (NG1 exception, T1); AC-1.4 now live-reachable |
| boomer codex #2 (HIGH) | v2 schema string is a real observable change for strict consumers | G6 documents it as observable + prefix-match; `--json-v1` declined (FOLLOW-UP-2, zero consumers) |
| boomer codex #3 (HIGH) | `(()→String?)?` update seam collapses offline/parse/timeout → loses AC-6.3 reason | Typed `UpdateOutcome` enum seam (§4.1) carries enumerated reason |
| boomer codex (MED) | opt-in `skipped` update degrades aggregate; not documented | AC-3.5 documents (consistent v1 semantics; `aggregateStatus` untouched) |
| boomer codex (MED) | `--verbose` surfaces existing `evidence["command"]` (user's own local path, not a secret) | No new sensitive field introduced; verbose renders only existing non-credential evidence; AC-6.4 covers the one network field |
| boomer codex (S3) | 3s default is not a hard bound under serial execution | §7 restated as empirical/typical, not a bound |
<!-- Sections not applicable to a local CLI diagnostic are marked N/A inline. -->
