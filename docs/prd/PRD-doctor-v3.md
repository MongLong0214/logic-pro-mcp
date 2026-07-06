# PRD: Doctor v3 — Causal-Chain Diagnostic

**Version**: 0.3
**Author**: strategist (dev-pipeline)
**Date**: 2026-07-06
**Status**: Approved
**Size**: L

**Changelog**
- v0.3 (2026-07-06): Phase-4 ticket-gate amendments — **OBJ-A**: Fix-Plan ordering 3-tier→**2-tier severity** (3-tier broke the headline coupling; counterexample documented in §4.3 Ordering; status tags retained as the noise device); **OBJ-B**: `blockedByDependencies` typed `[String: [String]]` (ordered cause list; expresses blocking_dialog's running-first two-cause precedence). D11 table row + prose amended accordingly.
- v0.2 approved (2026-07-06): Phase 2 gate closed — R1–R15 applied, boomer converged over 3 rounds, `file`-tool mention removed. Orchestrator verdict ALL PASS (guardian/strategist R1–R9 reflected + boomer convergence).
- v0.2 (2026-07-06): Round-1 review reflected (R1–R15). fix_plan/headline invariant restated (id-embedded `==`, single canonical definition in §4.3) + coupling invariant; PostEvent honest-default (denied) + `PermissionChecker.Runtime` postEvent seam + §8.2 fixture-migration subsection; TCC.db `?immutable=1` mandatory; malformed-input branch matrix (N2/N5/N6/N7/N8) + §5 edits; N10 `principal_not_found`; CI-honesty fixture permission posture + AC-5.5 scope; `strings` ranking algorithm; Fix-Plan human-render modes; new decisions **D10** (typed-tool allowlist, structural E4 guard) + **D11** (3-tier fix-plan sort/status-tags); §7 subprocess-budget table; §9.1 consumer-compat matrix; `--strict` exit conventions; §10.2 R2 → Med + 3-way TCC skipped reasons; §12 OQ sign-off recorded.
- v0.2 (micro, 2026-07-06): Removed `file` from the executable metadata-tool mentions (§4.3 N7, §4.5 read-only contract) — arch discrimination is `lipo -archs` only; `file` is not in the D10 allowlist (boomer consistency fix).
- v0.1 (2026-07-06): Initial draft.

> Binding requirements input: `scratchpad/doctor-v3-requirements-decision.md` (Orchestrator, 2026-07-06).
> Evidence sources cited inline as `E1..E4 §x` (the four exploration reports) and as `file:line` verified against the checked-out worktree on `feature/doctor-v3`.
> Deviations from the binding decision are enumerated in **§12.1** (none change the decision unilaterally — clarifications/proposals only).

---

## 1. Problem Statement

### 1.1 Background

`LogicProMCP doctor` shipped its enterprise **v2** in PR #209 (schema `logic_pro_mcp_doctor.v2`, 13 checks, per-check `category`/`severity`/`duration_ms`, top-level `summary`+`headline`, honesty chokepoint `clampStatusForPermissions`). It is read-only and safe to run before the server starts (`SetupDoctor.swift:201`, `docs/SETUP.md:125-139`).

Four targeted explorations of the *actual user failure surface* (E1 doctor surface, E2 channel/deps, E3 TCC map, E4 install/registration) — all corroborated against this Mac's real state — found that v2 is honest about what it checks but **blind to the most common "connected but nothing moves" failure class**. Concretely, on this exact machine, live measurement showed:

- An **installed 3.5.0 binary shadowing the 3.8.0 repo** with *zero* signal from doctor — `binary.version` "cannot detect a stale/mismatched install... never fails" by its own admission (`SetupDoctor.swift:449-453`; E4 §B9 headline).
- **`post_event_access` is health-only, absent from doctor** (`SystemDispatcher.swift:212` vs. grep-confirmed absent in `SetupDoctor`/`PermissionChecker`). An Accessibility-granted-but-PostEvent-denied host passes doctor yet fails every CGEvent keystroke (transport.stop/pause primary + most edit/view/track fallbacks — `RoutingTable.swift:20,29,177-217`). This is the F1 false-green (E2 §5, §7.1).
- **doctor never checks Logic's version** — only macOS (E2 §7.2). SETUP prose says 12.3 prioritized / 12.0.1 floor best-effort (`docs/SETUP.md:8`) but no code constant exists (grep-confirmed absent in `Sources/`).
- **No share-dir / keycmd-staging / MCU-wiring checks** — on this Mac the installed pkgshare is missing 4 python helpers, Key Commands dir is empty, and the CS file has 0 references to our MCU port (E4 §A1, §B8; E2 §2, §3).
- **doctor's live permission probes are only authoritative in the same launch context as the server** — a terminal-run doctor measures the terminal's TCC principal, which can be a *different* app than the one that spawns the server (E3 §C7). Doctor never states this, so a "granted" can be false for the Claude-Desktop-spawned server and vice-versa.

### 1.2 Problem Definition

Doctor v2 reports a green/degraded state that does not correspond to whether the user's Logic Pro can actually be driven: it cannot see stale installs, the PostEvent permission, Logic's version, channel-staging artifacts, or cross-context TCC — so it neither **accurately reports current state** nor **precisely points at what is broken**, which is the entire purpose Isaac set for it.

### 1.3 Impact of Not Solving

- **False-green wastes the user's time and ours**: users file "connected but not moving" issues (the #105-#112, #186-#222 triage clusters are dominated by this class) that a precise doctor would have self-diagnosed. Each becomes a manual live-triage session.
- **Silent stale installs** (E4 headline: 3.5.0 vs 3.8.0, 3 minors, zero registration to notice) mean users run months-old behavior while reading current docs — the single highest-leverage undiagnosed failure.
- **Cross-context permission blindness** produces "I granted Accessibility but it still fails" confusion that is currently unanswerable without expert knowledge of TCC responsible-process attribution.

---

## 2. Goals & Non-Goals

### 2.1 Goals

- [ ] **G1 — Diagnose the full causal chain.** Add checks spanning Install → Registration → Permissions(TCC) → Logic → Channels so doctor sees every precondition of actuation, not just the binary + 3 permissions. (13 → **26** base checks, 27 with `--check-updates`.)
- [ ] **G2 — Root-cause collapse.** A `blocked_by` field + a top-level **Fix Plan** collapse derived failures into their one root cause; the check id embedded in `headline` equals `fix_plan[0]` (canonical invariant defined once in §4.3 "Fix Plan"). The user sees *one* thing to fix first, not a wall of red.
- [ ] **G3 — Zero false-green.** Nothing the tool cannot verify is ever reported `pass`. Unverifiable ⇒ `manual`/`skipped` with an enumerated `reason`. `fail` means "confirmed broken" only. Extend `allGranted`/`clampStatusForPermissions` to include PostEvent so no `ok`-while-CGEvent-dead state exists.
- [ ] **G4 — Zero false-red.** Environmental absence (no FDA, no brew, source build, Logic not running) degrades to `skipped`/`manual`, never `fail`; the TCC.db enrichment is layered on the live probes and can never be a denial source.
- [ ] **G5 — Strict superset wire contract.** Schema `logic_pro_mcp_doctor.v3` keeps every v2 key's name/semantics/value; additions only (`blocked_by` optional, top-level `fix_plan`). Every v2 consumer keeps working via prefix-match.
- [ ] **G6 — Scriptable exit semantics.** `--strict` maps aggregate → exit `{ok:0, failed:1, manual_action_required:2, degraded:3}`; default exit unchanged (`failed`→1, else 0).
- [ ] **G7 — Live acceptance on this Mac** (§7 of the decision) reproduced exactly by a fresh release build: the known non-pass set surfaces, the Fix Plan orders it by severity, and nothing spuriously fails.
- [ ] **G8 — Provable honesty.** Unit coverage for every new status path, `blocked_by` cascade, Fix Plan sort/dedup, v3-superset decode, `--strict` matrix, and a CI-honesty scenario; `swift test --no-parallel` + `swift build -c release` green; docs-anchor lint green.

### 2.2 Non-Goals (§8 of the decision — verbatim scope)

- **NG1**: No `system.health` resource changes. The `logic.blocking_dialog` health-parity is recorded as a follow-up issue only.
- **NG2**: No auto-fix execution (`--fix` does not exist); no change to bootstrap/lifecycle *execution* paths.
- **NG3**: No server runtime (channel/dispatcher/routing) behavior change.
- **NG4**: No MCU `.cs` structural parse, no `.logikcs` parse, no `$PATH` full walk.
- **NG5**: No folding of doctor into `golden_capture.py` (keep targeted assertions; follow-up).
- **NG6**: No network beyond the existing opt-in `--check-updates` (C9).
- **NG7**: **Never execute any on-disk binary other than self** (C4; E4 incident). Version discovery is static `strings` sniff only.

---

## 3. User Stories & Acceptance Criteria

### US-1: New-install user ("I just installed it, is it set up right?")
**As a** first-time user, **I want** doctor to tell me exactly which setup step I still owe, **so that** I don't guess.

**Acceptance Criteria:**
- [ ] AC-1.1: Given Logic Pro is installed and running but no channel staging is done, when I run `doctor`, then `logic.installation`/`logic.version_support`/`logic.application_state` are `pass` and `channels.keycmd_reference`/`channels.mcu_wiring_hint` are `manual` with remediation pointing at `install-keycmds.sh` / the SETUP MCU section.
- [ ] AC-1.2: Given the binary was source-built (`.build/release`), when I run `doctor`, then `install.binary_inventory` is `pass` with evidence noting zero canonical candidates and `install.share_dir` is `skipped` (`reason: share_dir_unresolved`) — never `fail`.
- [ ] AC-1.3: The Fix Plan lists only actionable, non-blocked items (status ∈ {fail, warn, manual}), ordered `fail → warn → manual` then declared order, remediation-deduplicated, numbered with per-item status tags; the check id embedded in `headline` equals `fix_plan[0]` (canonical definition in §4.3 "Fix Plan").

### US-2: Upgrade user ("I upgraded — am I actually running the new one?")
**As a** returning user, **I want** doctor to catch a stale/shadowing install, **so that** I'm not running months-old behavior.

**Acceptance Criteria:**
- [ ] AC-2.1: Given a canonical path (`/opt/homebrew/bin` or `/usr/local/bin`) holds a LogicProMCP whose *static* version sniff differs from the running doctor's compiled version, when I run `doctor`, then `install.binary_inventory` is `warn` with evidence `{running_version, candidates:"…:3.5.0 | …:3.8.0"}` and a `brew upgrade`/reinstall remediation. (Live-proven: E4 §B9.)
- [ ] AC-2.2: Given the resolved share dir is missing files vs. the expected ship-list (V2), when I run `doctor`, then `install.share_dir` is `warn` listing the missing basenames (live-proven: 4 python helpers). No binary is ever executed to determine version (C4/NG7).
- [ ] AC-2.3: Given a registered command points at a binary whose static version ≠ running version, when I run `doctor`, then `mcp.registration_target` is `warn` ("stale registered binary").

### US-3: "Connected but nothing moves" user
**As a** user whose client shows the server connected but Logic doesn't respond, **I want** doctor to name the exact broken precondition, **so that** I stop guessing.

**Acceptance Criteria:**
- [ ] AC-3.1: Given PostEvent is denied (Accessibility may be granted), when I run `doctor`, then `permissions.post_event_access` is `fail`, the summary states CGEvent-family ops are dead, `allGranted==false`, and the aggregate is never `ok`.
- [ ] AC-3.2: Given Logic is running with a blocking modal, when I run `doctor` with Accessibility granted, then `logic.blocking_dialog` is `warn` with `{dialog_title, buttons, recovery_action}`; if Accessibility is denied or Logic isn't running, it is `skipped` with `blocked_by` set to the single deterministic root (see §4.3).
- [ ] AC-3.3: Given cliclick is absent AND PostEvent is denied, when I run `doctor`, then `dependencies.click_fallback` is `warn` ("no working click path"); otherwise it is `pass`.

### US-4: Claude Desktop user
**As a** Claude Desktop user, **I want** doctor to check the Desktop registration and to warn me when it measured a *different* launch context than the one that will spawn the server.

**Acceptance Criteria:**
- [ ] AC-4.1: Given `claude_desktop_config.json` is absent, when I run `doctor`, then `mcp.claude_desktop_registration` is `skipped` (`reason: config_absent`) with summary "Claude Desktop not configured (optional)" — never `warn`/`manual`/`pass`.
- [ ] AC-4.2: Given the config exists and registers LogicProMCP, when I run `doctor`, then it is `pass`; existing-but-unregistered ⇒ `warn` with a manual-JSON-edit remediation (no CLI equivalent).
- [ ] AC-4.3: `permissions.launch_context` is always `pass` and its summary names the measured context (`terminal|claude_code|claude_desktop|unknown`) and states that a server spawned by a *different* app must be re-verified under that app.
- [ ] AC-4.4: Given FDA is available, when `permissions.tcc_cross_context` runs and finds a known MCP-host principal explicitly denied a required service, then it is `warn`; grant confirmed ⇒ `pass`; **no matching principal row ⇒ `skipped` `reason: principal_not_found` (never `pass`, R5)**; TCC.db unopenable/unqueryable ⇒ `skipped` with the matching 3-way reason (`full_disk_access_unavailable` / `tcc_query_unavailable` / `tcc_schema_mismatch`, R15), noting live probes remain authoritative.

### US-5: CI / scripting user
**As a** CI or scripting user, **I want** distinct exit codes per outcome, **so that** I can branch on them.

**Acceptance Criteria:**
- [ ] AC-5.1: `doctor --strict` exits `0/1/2/3` for aggregate `ok/failed/manual_action_required/degraded` respectively.
- [ ] AC-5.2: `doctor` without `--strict` preserves v2 exit semantics exactly: `failed`→1, everything else→0.
- [ ] AC-5.3: `doctor --json` bytes are identical regardless of `--strict`/`--verbose`/`--quiet`/color; `--strict` changes only the process exit code, not output.
- [ ] AC-5.4: `--help` usage text documents `doctor [--strict] …` and the previously-omitted `lifecycle <install|update|uninstall> [--json]` verb (E1 §1 gap).
- [ ] AC-5.5: In the CI-honesty *fixture* (subject present + `accessibility`/`automation`×2/`postEvent` all granted, but no Logic *running*, no TCC.db, no FDA, no brew, no sqlite3), **no new check `fail`s on account of absent diagnostic capability**, and the aggregate is a truthful `degraded`/`manual_action_required`, never a spurious `failed`. Scope (R6): this claims correctness of diagnostic-capability absence *under a satisfied subject/permission posture* — a real bare runner with Accessibility denied honestly reports `failed` (D7; `doctor` is not a CI gate). See §4.4 D7 and §8.4 for the exact fixture contract.

---

## 4. Technical Design

### 4.1 Architecture Overview

Doctor v3 keeps v2's single-pass, sequential, non-throwing pipeline (`SetupDoctor.generate`, `SetupDoctor.swift:219-260`) and its single check-construction chokepoint (`check(...)`, `SetupDoctor.swift:892-916`, derives `category`+`severity`). Two mechanisms are layered on top:

```
                     ┌──────────────── generate(arguments, permissionStatus, approvals, runtime) ─────────────────┐
 INSTALL   binary.path → binary.executable → binary.version → install.source → install.binary_inventory[N7] →
                         install.share_dir[N8] → release.signature → release.quarantine
 REGISTER  mcp.claude_code_registration → mcp.registration_target[N5] → mcp.claude_desktop_registration[N6]
 PERMISS.  permissions.accessibility → …automation_logic_pro → …automation_system_events →
                         …post_event_access[N1] → …launch_context[N9] → …tcc_cross_context[N10]
 SYSTEM    system.macos_version
 LOGIC     logic.installation[N2] → logic.version_support[N3] → logic.application_state → logic.blocking_dialog[N4]
 CHANNELS  channels.manual_validation → channels.keycmd_reference[N11] → channels.mcu_wiring_hint[N12]
 DEPS      dependencies.click_fallback[+]
 (opt-in)  updates.latest_release           ← appended only with --check-updates, always last
                         └────────────── aggregateStatus → clampStatusForPermissions → Fix Plan ──────────────────┘
```

- **Root-cause collapsing** — a compile-time dependency table (cause check id → derived check ids) drives each derived check to emit `skipped`/`manual` + `blocked_by=<cause id>` instead of its natural status when the cause is non-`pass`. Derived checks always appear *after* their cause in the declared order, so `generate` can read the already-computed cause status from the running `checks` array (helper `status(of:in:)`).
- **Honesty** — unverifiable inputs never yield `pass`; environmental-capability gaps yield `skipped`/`manual` with an enumerated `reason`; the TCC.db layer is enrichment over the live probes and is structurally incapable of producing a denial (§4.4 D5).

Runtime seams follow the v2 additive pattern (`Runtime` default-valued `var`s, `SetupDoctor.swift:154-162`) so every existing `Runtime(...)` construction keeps compiling (M7).

### 4.2 Data Model Changes

**Wire schema — `logic_pro_mcp_doctor.v3` (strict superset of v2).** Rename/removal forbidden (C1). `docs/SETUP.md:139` already instructs consumers to prefix-match `logic_pro_mcp_doctor.`.

| Field | Location | Change | Compat |
|---|---|---|---|
| `schema` | top-level | `"…v2"` → `"…v3"` (`SetupDoctor.swift:201`) | prefix-match unchanged |
| `blocked_by` | per-`Check` | **NEW** `Check.blockedBy: String?`; wire key **omitted when nil** by relying on the **synthesized Codable's `encodeIfPresent`** (no custom `encode(to:)` — verified: `Check`/`Report` carry no hand-written `encode(to:)`/`init(from:)`, `SetupDoctor.swift:53–81`) so v2/v1 decoders never see an unknown key | additive |
| `fix_plan` | top-level | **NEW** `[String]` of check ids (the root-cause-collapsed, severity-ordered actionable set) | additive |
| `summary` | top-level | shape unchanged (`total/passed/failed/warnings/manual/skipped/duration_ms`); counts now over 26/27; invariant `total == passed+failed+warnings+manual+skipped == checks.count` holds (M6) | value-compatible |
| `headline` | top-level | logic unchanged (still a full sentence); the check id **embedded** in `headline` equals `fix_plan[0]` when a fix plan exists (M3; canonical invariant §4.3 "Fix Plan") | value-compatible |
| per-check `evidence` | per-`Check` | **stays `[String: String]`** — lists are serialized to compact delimited strings (see below), NOT nested JSON, so the FrozenV1/V2 `[String:String]` decode contract is preserved | preserved |

**Evidence serialization rule (wire-compat).** `Check.evidence` remains `[String: String]` (`SetupDoctor.swift:897`). List-valued evidence is serialized deterministically: `missing_files: "logic_bounce.py,logic_ui_jxa.py"`; `candidates: "~/…/opt/homebrew/bin:arm64:3.5.0 | .build/release:universal:3.8.0"`. Redaction (C7) is applied *before* serialization.

**New source constants (V1/V2), colocated near `ServerConfig` (`Sources/LogicProMCP/Server/ServerConfig.swift`):**
- **V1 `LogicProSupport`**: `minimumSupportedLogicVersion = "12.0.1"`, `latestValidatedLogicVersion = "12.3"`. A `VersionConsistencyTests` case (pattern: `Tests/LogicProMCPTests/VersionConsistencyTests.swift:23-44`) pins `minimumSupportedLogicVersion == manifest.json.min_logic_pro_version` (`manifest.json:13` = `"12.0.1"`).
- **V2 expected share ship-list**: the basenames the Formula's `pkgshare.install` ships (`Formula/logic-pro-mcp.rb:28-48`): `SETUP.md`, `install-keycmds.sh`, `uninstall-keycmds.sh`, `keycmd-preset.plist`, `LogicProMCP-Scripter.js`, and the four conditionally-shipped python helpers (`logic_bounce.py`, `logic_bounce_ui.py`, `logic_ui_jxa.py`, `logic_input_source.py`). A drift test greps `Formula/logic-pro-mcp.rb` text (reusing the release-verify grep idiom, `Scripts/release-verify-formula-install-paths.sh`) so the constant can't silently diverge from the Formula.

**`PermissionChecker.PermissionStatus` extension (N1).** Add `postEventAccessState` (a `Bool`-backed field), a computed `postEventAccess`, and extend `allGranted` to `accessibility && automationLogicPro && automationSystemEvents && postEventAccess` (`PermissionChecker.swift:121`; the only two `allGranted` consumers are `MainEntrypoint.swift:171` `--check-permissions` exit and `SetupDoctor.swift:267` clamp — NG1-safe, health computes PostEvent independently at `SystemDispatcher.swift:212`).

- **Honest default = denied (false).** Any new initializer parameter defaults to the **denied/false** posture — mirroring the `systemEventsAutomationState = .notVerifiable` honest-default precedent (`PermissionChecker.swift:102`) — so legacy 2-/3-arg `PermissionStatus(...)` construction keeps compiling **and** never silently reports a `granted` PostEvent it did not measure. A `granted` default would re-introduce exactly the F1 false-green this feature closes (G3). The production `check(runtime:)` (`PermissionChecker.swift:207-213`) MUST set the real preflight value (not the default).
- **New `PermissionChecker.Runtime` seam.** Add a `postEventPreflight: @Sendable () -> Bool` closure to `Runtime` (init `:60-74`, `.production` `:76-85`), defaulted in `.production` to `{ CGPreflightPostEventAccess() }` — consistent with the existing all-seamed pattern (`checkAccessibility`/`runAutomationProbe`/`runSystemEventsAutomationProbe`), keeping production hermetic and giving tests an injectable fake. Give the new init parameter a default so every existing `Runtime(...)` construction compiles unchanged (M7).

### 4.3 New-Check Inventory (the implementer contract)

**The 13 existing checks are immutable** — ids, order (relative to each other), semantics, and status logic are unchanged (C2). New checks are *inserted* at causally-sensible positions; the existing 13 keep their relative order (verified below). Category is derived from `domain` by the existing map (`category(forDomain:)`, `SetupDoctor.swift:918-…`): `binary/install/release/system→installation`, `mcp/channels→configuration`, `permissions→permissions`, `dependencies→dependencies` (reserved slot, now used), `logic/default→runtime`, `updates→updates`. Severity is derived from status: `fail→error`, `warn|manual→warning`, `skipped|pass→info`.

**Final declared order (the updated exact-id array, 26 base; 27th appended only with `--check-updates`).** `✓`=existing (unchanged), `+`=new:

| # | id | new? | domain | category |
|---|---|---|---|---|
| 1 | `binary.path` | ✓ | binary | installation |
| 2 | `binary.executable` | ✓ | binary | installation |
| 3 | `binary.version` | ✓ | binary | installation |
| 4 | `install.source` | ✓ | install | installation |
| 5 | `install.binary_inventory` | + N7 | install | installation |
| 6 | `install.share_dir` | + N8 | install | installation |
| 7 | `release.signature` | ✓ | release | installation |
| 8 | `release.quarantine` | ✓ | release | installation |
| 9 | `mcp.claude_code_registration` | ✓ | mcp | configuration |
| 10 | `mcp.registration_target` | + N5 | mcp | configuration |
| 11 | `mcp.claude_desktop_registration` | + N6 | mcp | configuration |
| 12 | `permissions.accessibility` | ✓ | permissions | permissions |
| 13 | `permissions.automation_logic_pro` | ✓ | permissions | permissions |
| 14 | `permissions.automation_system_events` | ✓ | permissions | permissions |
| 15 | `permissions.post_event_access` | + N1 | permissions | permissions |
| 16 | `permissions.launch_context` | + N9 | permissions | permissions |
| 17 | `permissions.tcc_cross_context` | + N10 | permissions | permissions |
| 18 | `system.macos_version` | ✓ | system | installation |
| 19 | `logic.installation` | + N2 | logic | runtime |
| 20 | `logic.version_support` | + N3 | logic | runtime |
| 21 | `logic.application_state` | ✓ | logic | runtime |
| 22 | `logic.blocking_dialog` | + N4 | logic | runtime |
| 23 | `channels.manual_validation` | ✓ | channels | configuration |
| 24 | `channels.keycmd_reference` | + N11 | channels | configuration |
| 25 | `channels.mcu_wiring_hint` | + N12 | channels | configuration |
| 26 | `dependencies.click_fallback` | + | dependencies | dependencies |
| (27) | `updates.latest_release` | ✓ | updates | updates |

Existing-13 relative order preserved: positions `1,2,3,4,7,8,9,12,13,14,18,21,23` are strictly increasing — matches the v2 array (`SetupDoctorTests.swift:83-97`).

**Per-check specification.** Status column lists the *exact* condition → status. `bb` = `blocked_by`; environmental gates use `reason` (not `bb`) because `blocked_by` is reserved for cross-*check* derivation.

#### N1 `permissions.post_event_access` — permissions/permissions
- **Source/API**: `CGPreflightPostEventAccess()` obtained via the `PermissionChecker.Runtime.postEventPreflight` seam (§4.2) — pure read-only preflight, no prompt, no side effect (E2 §5, E3 §A2; `SystemDispatcher.swift:212` parity). The seam value also feeds `PermissionStatus.postEventAccessState`, so this check and `allGranted`/clamp read the *same* measurement.
- **Status**: `pass` iff preflight `== true`; else `fail`. (Honest default is `denied`/false, §4.2 — an unset fixture never reports `granted`.)
- **Honesty coupling**: fed into `PermissionStatus.postEventAccessState`; `allGranted` extended (§4.2); the `--check-permissions` summary gains a PostEvent line (M6/N1). Because `allGranted` now includes PostEvent, `clampStatusForPermissions` (`SetupDoctor.swift:391-393`) covers the F1 ok-while-CGEvent-dead gap.
- **evidence**: `{post_event_access: "granted"|"denied"}`. **remediation**: `system_settings` (Accessibility pane grants PostEvent for terminal/host apps). **bb**: none.
- **Summary on fail**: must state "CGEvent-family ops (transport.stop/pause + most edit/view/track fallbacks) will fail" (`RoutingTable.swift:20,29,177-217`).

#### N2 `logic.installation` — logic/runtime
- **Source**: direct `Info.plist` read at `/Applications/Logic Pro.app` and `~/Applications/Logic Pro.app` — `CFBundleShortVersionString` + `CFBundleIdentifier` (E4 recipe (a); live: `/Applications/Logic Pro.app` = `com.apple.logic10`, `12.3`). Independent of `ProcessUtils.logicProVersion()`. Zero side effects.
- **Status (3-way, R4):** **`pass`** if ≥1 copy is found *and* its version reads (evidence names both if dual); **`skipped` `reason: bundle_unreadable`** if a `.app` exists at either path but its `Info.plist` is unreadable / `CFBundleShortVersionString` is absent — a present-but-unreadable install must never be reported as "not installed" (false-red guard); **`fail`** only if *neither* path holds a `.app` bundle (genuine non-install — chain root).
- **evidence**: `{version, bundle_id, path:"~/…"|"/Applications/…", second_copy:"present"|<omitted>, reason:"bundle_unreadable"|<omitted>}`. **remediation**: `docs`. **bb**: none.

#### N3 `logic.version_support` — logic/runtime
- **Compare** detected version (from N2) to V1 constants.
- **Derivation rule (single; matches the `blocked_by` table exactly, R4):** **if `logic.installation` (N2) is `!= pass`, N3 is *unconditionally* `skipped` + `bb: logic.installation`.** There is no separate reason-propagation branch — the version-unreadable case makes N2 itself `skipped(bundle_unreadable)` (which is `!= pass`), so it is absorbed by this one rule and N3 never has to interpret a nil/absent version.
- **Status (only when N2 == `pass`):** `fail` if `< minimumSupportedLogicVersion` (12.0.1 floor); `warn` if `floor ≤ v < latestValidated` ("supported best-effort"); `pass` if `== latestValidated`; `warn` if `> latestValidated` ("newer than validated; AX tree may differ" — #234 precedent, `AXLogicProElements.swift:167-170`).
- **evidence**: `{detected_version, minimum_supported, latest_validated}`. **remediation**: `docs`. **bb**: `logic.installation` (when derived).

#### N4 `logic.blocking_dialog` — logic/runtime
- **Source**: reuse `AXLogicProElements.blockingDialogInfo(runtime:)` (E2 §8, `AXLogicProElements.swift:99-125`) — pure read-only AX traversal; blocking = subrole `AXDialog`/`AXSystemDialog` excluding keyboard-overlay + plugin-editor (`:158-165,195-210`).
- **Gate (v0.3, table-driven per OBJ-B)**: both ordered causes must be `pass` — `logic.application_state == pass` (running **with a visible window**; the `warn` running-no-window state also blocks — conservative: with zero detectable windows an AX dialog probe is moot) **AND** `permissions.accessibility == pass`. First non-`pass` cause in table order becomes `blocked_by`.
- **Status**: `warn` if a blocking dialog is present; `pass` if none; **`skipped`** if gated — `bb` chosen by deterministic precedence: **if Logic not running → `bb: logic.application_state`; else if Accessibility not granted → `bb: permissions.accessibility`** (running-first: a non-running app cannot present a dialog, so "start Logic" is the more-root action).
- **evidence** (when present): `{dialog_present:"true", dialog_title, role, buttons:"OK,Cancel", recovery_action}`. **remediation**: `manual` (dismiss the modal). **bb**: per precedence above.

#### N5 `mcp.registration_target` — mcp/configuration
- **Precondition**: `mcp.claude_code_registration == pass`; else **`skipped` `bb: mcp.claude_code_registration`** (live: this Mac is `.notRegistered` → this check is skipped; E4 §B5).
- **When registered**: registered `command` path exists + is executable; args/env sanity (if `LOGIC_PRO_MCP_SHARE_DIR` present in registered env, its dir exists); **static** version sniff of the registered binary vs. the running doctor version.
- **Malformed-input guards (R4):** if the registered `command` is a **relative path or a bare PATH-dependent name** (not absolute), it is excluded from `fileExists`/version comparison (a CWD-relative resolve would false-`warn`; NG4 forbids a `$PATH` walk) and evidence carries `reason: relative_command`. The candidate must be `isRegularFile` (a directory at the path is not a binary — #211 precedent); if the resolved binary is **non-Mach-O** (a wrapper script, so `lipo`/`strings` yield no semver), the version is treated as **indeterminate** — no version-mismatch `warn`.
- **Status**: `pass` if command resolves + executable + env sane + version matches (or is honestly indeterminate); `warn` if any of {command missing, not executable, env dir missing, version mismatch ("stale registered binary")}.
- **Never executes the registered binary (C4/NG7).**
- **evidence**: `{command_path:"~/…", executable, share_dir:"present"|"missing"|<omitted>, registered_version, running_version, version_match, reason:"relative_command"|<omitted>}`. **remediation**: `command` (`claude mcp add …`). **bb**: `mcp.claude_code_registration` (when derived).

#### N6 `mcp.claude_desktop_registration` — mcp/configuration
- **Source**: `~/Library/Application Support/Claude/claude_desktop_config.json`, same predicate as the Claude Code reader (name contains `logic-pro` AND command contains `LogicProMCP`; `SetupDoctor.swift:1131-1179`), second config URL.
- **Status**: **`skipped` `reason: config_absent`** + summary "Claude Desktop not configured (optional)" when the file is missing (live: missing, E4 §B6) — explicitly **not** `manual`/`warn`/`pass`; **`skipped` `reason: config_unreadable`** (R4) when the file exists but is not valid JSON / cannot be parsed — a malformed config must not false-`warn` "unregistered"; `pass` if present + parseable + registered; `warn` if present + parseable + unregistered.
- **evidence**: `{config_present, registered:"true"|"false"|<omitted>, reason:"config_absent"|"config_unreadable"|<omitted>}`. **remediation**: `manual` (hand-edit `claude_desktop_config.json`; no CLI equivalent). **bb**: none.

#### N7 `install.binary_inventory` — install/installation
- **Candidates from FIXED canonical paths only** (NG4, no `$PATH` walk — launchd PATH is untrusted, E4 §A4): `/opt/homebrew/bin/LogicProMCP`, `/usr/local/bin/LogicProMCP`, and the absolute `command` path from the Claude Code registration (deduped, self excluded from the "differs" comparison). A candidate must be `isRegularFile` (a directory is not a binary — #211 precedent); a relative/PATH-dependent registered command is excluded (R4, as in N5).
- **Per candidate**: `arch` via `lipo -archs` (bounded, metadata-only); **static** version via the `strings` tool run as an **exec-array** (`strings -a <path>` — never a shell pipe). All filtering/ranking is done in **Swift** over `strings`' stdout (no `| grep`), per the exact algorithm below.
- **`strings` version ranking (exact, deterministic — R7 / extends E7):**
  1. Collect **all** lines matching the anchored regex `^[0-9]+\.[0-9]+\.[0-9]+$` (Swift regex over captured stdout).
  2. **Drop `major == 0`** matches (kills the `0.0.0`-class false positives — E4 §B9: naive first-match returns `0.0.0` before `3.5.0`).
  3. **Dedup** the survivors.
  4. **Exactly one** distinct semver remains → adopt it as the candidate version.
  5. **≥ 2 distinct** semvers remain (e.g. a dependency's version embedded alongside the binary's own; `strings` emits in file-offset order so "first match" is arbitrary) → **`indeterminate`**: emit **no** version-mismatch `warn`; evidence lists all survivors.
  6. **Zero** remain → `indeterminate` (non-Mach-O wrapper / stripped binary — R4).
- **Status**: `warn` if any candidate's **determinate** static version ≠ running version (live-proven 3.5.0 vs 3.8.0); `pass` if consistent, indeterminate, or zero candidates (source build — evidence notes it). Indeterminate never produces a false `warn` (keeps false-red at 0).
- **Never executes any candidate (C4/NG7).** `lipo`/`strings`/`codesign`/`xattr` via `BoundedProcessRunner` (timeout 1.5s) are metadata-only and safe (E4 §A4). Arch discrimination is `lipo -archs` alone (no `file` tool — not in the D10 allowlist).
- **evidence**: `{running_version, candidates:"path:arch:version | …", stale:"true"|<omitted>, indeterminate:"path,…"|<omitted>}`. **remediation**: `command` (`brew upgrade`/reinstall). **bb**: none.

#### N8 `install.share_dir` — install/installation
- **Resolution order**: registered env `LOGIC_PRO_MCP_SHARE_DIR` → brew `pkgshare` (both prefixes `/opt/homebrew`, `/usr/local`). Compare directory contents to the V2 ship-list.
- **Status**: `warn` if files are missing (stale-keg signal; live-proven 4 python helpers, E4 §A1/§B9); `pass` if complete; **`skipped` `reason: share_dir_unresolved`** if neither resolves (source build); **`skipped` `reason: share_dir_invalid`** (R4) if a resolved path exists but is **not a directory** (`isDirectory` forced — a file at that path would make `contentsOfDirectory` fail and false-`warn` "everything missing").
- **evidence**: `{resolved_dir:"~/…"|<omitted>, source:"registered_env"|"brew_pkgshare"|<omitted>, missing_files:"a,b"|<omitted>, reason:"share_dir_unresolved"|"share_dir_invalid"|<omitted>}`. **remediation**: `command` (`brew reinstall`). **bb**: none.
- **Note**: `LOGIC_PRO_MCP_SHARE_DIR` is a *bounce-feature* precondition, not a startup requirement (E2 §9) — this check must not imply the server won't start without it.

#### N9 `permissions.launch_context` — permissions/permissions
- **Detect** the doctor process's own launch context: ancestor-process walk (`sysctl`/`proc_pidpath`, read-only, no TCC) + env heuristics (`TERM_PROGRAM`, `__CFBundleIdentifier`, node/claude ancestry — E3 §B5 ancestry example `tmux → claude → zsh`). Classify `terminal|claude_code|claude_desktop|unknown`.
- **Classification precedence (deterministic — R9):** **ancestry bundle-id > `__CFBundleIdentifier` > `TERM_PROGRAM` > `unknown`.** The first signal that resolves to a known host wins, so two hosts never classify inconsistently. Always-`pass`, so the only observable effect is summary wording — but the order is pinned by a unit test (§8.1 classifier).
- **Status**: **always `pass`** (informational, `binary.version` precedent).
- **Summary**: "This report measures the TCC principal of `<context>`; if a different app spawns the server, re-verify under that app" (E3 §C7 — a terminal-run doctor measures a different TCC principal than a Desktop-spawned server).
- **evidence**: `{launch_context, responsible_hint}` (bundle id, or basename-only when path-attributed; C7). **remediation**: `none`. **bb**: none.

#### N10 `permissions.tcc_cross_context` — permissions/permissions (FDA-gated ENRICHMENT; **default-on**, §4.4 D6)
- **Source**: `/usr/bin/sqlite3` **read-only** SELECT over the user (`~/Library/Application Support/com.apple.TCC/TCC.db`) and system (`/Library/Application Support/com.apple.TCC/TCC.db`) databases (E3 §B4 schema) for `service IN (kTCCServiceAccessibility, kTCCServiceAppleEvents, kTCCServicePostEvent)`, with `indirect_object_identifier IN (com.apple.logic10, com.apple.systemevents)` for AppleEvents.
- **Open contract (R3 — mandatory):** open via the **`file:<path>?immutable=1` URI** — this is **required**, *not* a bare `-readonly` equivalent. A WAL-mode DB opened bare-`-readonly` can still create/touch `-shm`/`-wal` sidecars in the (writable) `~/Library/.../com.apple.TCC/` directory → violates "system state never mutated" (Honesty Contract #4 / C3). `immutable=1` reads only the main DB file and creates no sidecar. The implementer ticket **must verify `/usr/bin/sqlite3` recognizes the URI filename** (if not, it treats the string as a literal path → open fails → natural `skipped`, which is safe); the live E2E asserts **no `-wal`/`-shm`/`-journal` file is created** by the call. Bounded via `BoundedProcessRunner`.
- **Query shape (R9):** **fixed literal SQL** — `service`/`indirect_object_identifier` values are compile-time constants and column-addressed (never `SELECT *`); the MCP-host-principal match is **Swift post-processing over returned rows**, never a dynamic `WHERE`. No SQL-injection surface.
- **Status**:
  - `warn` if a known MCP-host principal (claude-related bundle id, plus the principal inferred from the registered command) is explicitly denied (`auth_value == 0`) a required service → "the app that spawns the server is explicitly denied `<service>`";
  - `pass` if a grant (`auth_value == 2`) is confirmed with evidence;
  - **`skipped` `reason: principal_not_found`** (R5) if the DB is readable and the query runs but **no grant/deny row exists** for any relevant principal (undetermined — must **never** fall through to `pass`; G3);
  - **`skipped`** with a **3-way capability reason (R15)** when the layer cannot answer: `full_disk_access_unavailable` (DB cannot be opened — FDA absent) / `tcc_query_unavailable` (`sqlite3` binary absent or URI filename not recognized) / `tcc_schema_mismatch` (DB opens but an addressed column is absent — macOS schema drift). In every skipped case the summary states the live probes (N1 + existing permissions) remain authoritative.
- **Hard rules**: never replaces the live probe; **structurally incapable of false-red** — a "denied" row only ever downgrades to `warn`, never `fail` (§4.4 D5); redaction per C7 (bundle id/enum/bool only — never csreq/`indirect_object_code_identity` blobs, full paths, other apps' human names, `auth_reason`, or pids).
- **evidence**: `{tcc_db_readable, full_disk_access, findings:"accessibility=granted,appleevents:logic10=denied", reason:"principal_not_found"|"full_disk_access_unavailable"|"tcc_query_unavailable"|"tcc_schema_mismatch"|<omitted>}`. **remediation**: `system_settings`. **bb**: none (FDA/capability gate via `reason`).

#### N11 `channels.keycmd_reference` — channels/configuration
- **Source**: existence of `SetupLifecycle.keyCommandsPresetPath` (`SetupLifecycle.swift:509-513` → `~/Music/Audio Music Apps/Key Commands/LogicProMCP-KeyCommands.plist`).
- **Status**: `pass` if present ("staged; MIDI-Learn is a separate manual step — this proves the installer ran, not that Learn is done"); `manual` if absent (live: dir empty, E4 §B8).
- **Honesty**: proves staging only, never the MIDI-Learn bindings (`.logikcs` proprietary binary, never parsed; Logic 12.2+ refuses import — E2 §2).
- **Optional-channel framing (R11/D11):** summary + remediation state which op family relies on the keycmd channel and that this check is **ignorable if those ops are unused** — so a `manual` here reads as an optional next-step, not a hard fault (and, per D11, renders under the `[manual]` fix-plan tier).
- **evidence**: `{preset_staged}`. **remediation**: `command` (`install-keycmds.sh`) + SETUP anchor. **bb**: none.

#### N12 `channels.mcu_wiring_hint` — channels/configuration
- **Source**: positive-only `strings` scan (run as an **exec-array** — `strings <cs-file>`; substring match done in Swift, no shell pipe — R9) of `~/Library/Preferences/com.apple.logic.pro.cs` for the exact literal `LogicProMCP-MCU-Internal` (C6 — the file is FORM/IFF `MROF`, **never** `plutil`/structural parse; E4 §B8).
- **Status**: `pass` on a hit ("past binding evidence"); `manual` on a miss ("cannot confirm — MCU-only ops set_master_volume/set_output_volume/set_send/track.set_automation are verified live via health `mcu.connected`"; `RoutingTable.swift:70,84,88-89`); `manual` (same guidance) if the cs file is absent. A miss is **not** `fail` (positive-only heuristic; live: 0 occurrences here).
- **Optional-channel framing (R11/D11):** the `manual` summary + remediation already name the dependent op family (MCU-only, listed above) and state the check is **ignorable if those ops are unused**; it renders under the `[manual]` fix-plan tier.
- **evidence**: `{cs_file_present, mcu_port_reference_found}`. **remediation**: `docs` (SETUP MCU section). **bb**: none.

#### `dependencies.click_fallback` — dependencies/dependencies (reduced scope)
- **Source**: `isExecutableFile` on the two canonical cliclick candidates `["/opt/homebrew/bin/cliclick","/usr/local/bin/cliclick"]` (E2 §6; `LibraryAccessor.swift:1368-1389`).
- **Status**: `pass` by default (fallback-of-a-fallback; native CGEvent click is primary, E2 §6). Escalates to `warn` ("no working click path") **only** when PostEvent is denied (N1) **AND** no cliclick candidate is executable. No independent `fail`.
- **evidence**: `{cliclick:"present"|"absent", native_click:"available"|"denied"}`. **remediation**: `docs` (optional). **bb**: none.
- **Note**: the richer `#210/#211` cliclick-trust resolver is **not on this branch** (replaced by the native CGEvent backend; only the 2-candidate probe remains — E2 §6). Do not resurrect the trust path here.

**`blocked_by` dependency table (compile-time constant, M1):**

| Cause check | Derived check(s) | Derived status when cause ≠ pass |
|---|---|---|
| `mcp.claude_code_registration` | `mcp.registration_target` | `skipped`, `bb=mcp.claude_code_registration` |
| `logic.installation` | `logic.version_support` | `skipped`, `bb=logic.installation` |
| `logic.application_state` **then** `permissions.accessibility` | `logic.blocking_dialog` | `skipped`, `bb=` first failing (running-first precedence) |

**Table type (Phase-4 gate OBJ-B):** the compile-time table is `[String: [String]]` — derived check id → **ordered cause list** (array order = precedence). Single-cause rows hold one element; `logic.blocking_dialog` holds `["logic.application_state", "permissions.accessibility"]` (running-first). Check bodies consume the table (first non-`pass` cause in order wins as `bb`) rather than hardcoding their own precedence.

Checks whose failure is *environmental* (N7/N8/N10/N11/N12/click_fallback) use `reason`/natural `manual`/`skipped`, never `blocked_by`.

**`check()` factory `blockedBy` injection (M1, R9).** `blockedBy` enters through the single construction chokepoint: add a `blockedBy: String? = nil` parameter to `check(...)` (`SetupDoctor.swift:892-916`), threaded into `Check.blockedBy`. The defaulted param keeps all existing call sites compiling unchanged; no post-construction mutation.

**Fix Plan — canonical definition (M2/M3; R1 + R11 unified). This is the single source of truth for both the Fix Plan and the headline coupling — G2, AC-1.3, §4.2 (headline row), and §8.1 reference this and MUST NOT restate the rule.**

- **Membership.** A check is in the Fix Plan **iff (a) `status != pass` AND (b) `blocked_by == nil` (derived failures collapsed into their root) AND (c) `severity ∈ {error, warning}`** — i.e. `status ∈ {fail, warn, manual}` (recall the derivation `fail→error`, `warn|manual→warning`, `skipped|pass→info`, `SetupDoctor.swift:941-950`). `skipped` and `pass` (both `info`) are excluded. **`manual` IS a member** (it is `warning` severity) — so a standalone `manual` check (N11/N12/`manual_validation`) appears under the `[manual]` tier below. This is why R1's "severity ∈ {error, warning}" and R11's `fail → warn → manual` ordering are **consistent, not contradictory**: `manual` lives inside the `warning` severity band.
- **Ordering (R11-amended by Phase-4 gate OBJ-A — 2-tier by *severity*, declared order within):** **`error` tier (`fail`) → `warning` tier (`warn` and `manual`, co-equal)**, then **declared order** (§4.3 array) within a tier. ~~3-tier `fail→warn→manual`~~ was **withdrawn**: it breaks the headline coupling — `computeHeadline` tie-breaks the `warning` band by declared order, so a `manual` declared earlier than a `warn` (e.g. `mcp.claude_code_registration`=manual #9 vs `mcp.claude_desktop_registration`=warn #11) would headline `#9` while a 3-tier plan led with `#11`, violating `lead.id == fix_plan[0]`. With 2-tier ordering the Fix-Plan selection rule is **constructionally identical** to the headline's lead selection (same filter modulo blocked/info, same order), so the coupling holds by construction. D11's noise-management intent is preserved by the **status tags** (`[fail]/[warn]/[manual]`) and the optional-channel framing — and declared order *is* the causal-chain order, which is exactly the diagnosis priority this PRD is built on.
- **Rendering.** JSON adds top-level `fix_plan: [check_id, …]` in that exact order. `renderHuman` appends a numbered `Fix plan:` list in the same order, each line carrying a **status tag** — `1. [fail] …`, `2. [warn] …`, `3. [manual] …` (R11) — so hard breakage vs. optional next-step is visually distinct; remediation strings are de-duplicated.
- **Human-render modes (R8).** The `Fix plan:` section renders in **all three human modes — default, `--verbose`, and `--quiet`** (its content is entirely non-`pass`, which stays relevant even when `--quiet` suppresses `pass` lines, `SetupDoctor.swift:306`). It **honors `useColor`** (color-optional; gated as at `:79,:340-347`) and is **human-only — it never affects `--json` bytes**, preserving AC-5.3 (`--json` byte-identical across `--strict`/`--verbose`/`--quiet`/color). A per-mode render test covers all three (§8.1).
- **Headline coupling (R1 — the load-bearing invariant).** `headline` keeps v2 logic verbatim (`computeHeadline`, `SetupDoctor.swift:967-990`) and stays a **full sentence** (`"Next action [<id>]: …"`, `:989`). The invariant is: **the check id *embedded* in `headline` (`lead.id`) equals `fix_plan[0]`** — NOT literal string equality (a sentence is never `==` a bare id; a literal `==` test would be dead/false, colliding with the repo dead-`#expect` footgun). When the Fix Plan is empty, `headline` is the healthy/usable message (v2 logic).
- **Why the coupling holds — invariant to preserve.** `computeHeadline` picks the min-severity non-`pass` check but excludes `info` (`guard lead.severity != .info`, `:980`) and does **not** currently exclude `blocked_by`-derived checks. It aligns with the Fix Plan *only because every `blocked_by`-derived check is `skipped` (`info`)* — thus excluded from the headline by the `info` guard **and** from the Fix Plan by the `blocked_by` filter. **Invariant: no `blocked_by`-derived check may ever carry a `warn`/`manual` status.** If a future derived check needed `manual`/`warn`, the headline could name a check the Fix Plan omits (or vice-versa) → this coupling must be re-examined (and `computeHeadline` taught to also exclude `blocked_by`) before doing so. Standalone `manual` checks (N11/N12) are **not** `blocked_by`-derived, so they legitimately appear in both when they are the lead.

**CLI (`--strict`, M4).** New `--strict` flag. Exit mapping in the `doctor` branch (`MainEntrypoint.swift:82`):

| aggregate | default exit (unchanged, C10) | `--strict` exit |
|---|---|---|
| `ok` | 0 | 0 |
| `failed` | 1 | 1 |
| `manualActionRequired` | 0 | 2 |
| `degraded` | 0 | 3 |

`--json` bytes are identical with/without `--strict` (only the process exit code differs). `usageText` (`MainEntrypoint.swift:226-245`) gains `[--strict]` on the `doctor` line **and** the missing `lifecycle <install|update|uninstall> [--json]` verb form (E1 §1 gap).

**Exit-code conventions (R14 — prose + CI snippet land in `docs/SETUP.md` §Doctor, tracked in §8.5).** Codes `2`/`3` are **status codes, not usage errors**, and deliberately sit **below** the `sysexits.h` 64–78 range (no collision with `EX_USAGE=64` etc.). Guidance to document: (a) a caller needing only a boolean should test **non-zero** (`if ! doctor --strict; then …`), not equality to `1`; (b) under `set -e`, a non-`ok` `--strict` run aborts the script — wrap it (`doctor --strict || rc=$?`) when the exit is meant to be *inspected*, not fatal; (c) a copy-paste CI snippet branching on `0/1/2/3` is included in §8.5.

### 4.4 Key Technical Decisions

| # | Decision | Options considered | Chosen | Rationale |
|---|---|---|---|---|
| D1 | Logic version source of truth | (a) hardcode constant (b) parse `docs/SETUP.md:8` prose (c) `manifest.json` only | **(a) `LogicProSupport` constants + consistency test** | Prose parse is fragile; manifest has only the floor. Constant + `VersionConsistencyTests` pin (`:23-44`) prevents silent drift (E4 §A2). |
| D2 | Stale-install version discovery | (a) run `<candidate> --version` (b) static `strings` sniff | **(b) static sniff w/ ranking filter** | (a) is the E4 incident — an old binary spins up the full server (~1.7s CoreMIDI/AX/MCU) before any timeout fires (C4/NG7). `strings` returns `0.0.0` + real version → rank/filter. |
| D3 | Candidate discovery | (a) `$PATH` walk (b) fixed canonical paths + registered command | **(b)** | launchd PATH lacks `/opt/homebrew/bin`; Terminal sees login-shell PATH — `$PATH` is unreliable and non-reproducible (E4 §A4). |
| D4 | CoreMIDI verification | (a) `MIDIClientCreate` probe (b) `MIDIGetNumberOfDevices` proxy (c) keep manual | **(c) keep manual** | (a) is a real side effect (registers a client, fires setup-changed to other apps) — violates C3/C5; (b) is low-confidence. Honest boundary (E2 §1). |
| D5 | TCC.db role | (a) authoritative replacement for probes (b) enrichment layered on probes | **(b) enrichment only** | Live probes are authoritative for the *current* process; TCC.db adds cross-identity/Logic-closed/PostEvent reach but must never be a denial source (E3 deliverable (ii)). A "deny" row → `warn`, never `fail` — false-red is structurally impossible. |
| D6 | `permissions.tcc_cross_context` default | (a) default-on (b) opt-in flag | **(a) default-on** (orchestrator leaning) | The cross-context blind spot is the answer to the "I granted it but it fails" class; gating it behind a flag hides the most valuable enrichment. Read-only, redacted, self-degrading when FDA absent. Boomer may argue opt-in on privacy grounds → orchestrator escalation, not a unilateral change. **Trade-off**: reads TCC.db (other apps' grant rows) — mitigated by C7 redaction (bundle id/enum/bool only) and read-only/immutable open. See §6.3. |
| D7 | `logic.installation` when Logic absent | (a) `fail` (chain root) (b) `manual`/`warn` | **(a) `fail`** per N2 | A user with no Logic Pro genuinely has a broken setup; `fail` + a clear remediation is the honest answer. C8 (CI non-fail) is satisfied because `doctor` is **not** a CI pass/fail gate (verified: no `doctor` in `.github/workflows/`; Formula test uses `--check-permissions` tolerating `exit=[01]`) and the hermetic CI-honesty test injects subject-present seams (§8.4). Flagged as OQ-1 for orchestrator confirmation. |
| D8 | `evidence` value type | (a) widen to `[String: Any]`/nested JSON (b) keep `[String: String]`, serialize lists | **(b)** | Widening breaks the FrozenV1/V2 `[String:String]` decode superset guarantee (C1/G5). Delimited-string serialization keeps the contract. |
| D9 | `blocked_by` wire encoding | (a) always-present nullable key (b) omit key when nil | **(b) omit when nil** | A v2/v1 decoder never sees an unknown key when there's no dependency; strict superset preserved (M1). |
| D10 | Prevent arbitrary-binary execution (E4 incident) structurally | (a) prose prohibition only (b) typed-tool allowlist + fail-closed + lint test | **(b) structural enforcement** | Prose ("never execute a candidate") is not load-bearing against a future edit. A typed `DoctorTool` allowlist → fixed absolute paths, production `runCommand` fail-closed rejects anything else (nil), pinned by unit + source-grep lint. Detail below; Honesty Contract #3. (R10) |
| D11 | Fix Plan sort granularity + optional-channel noise | (a) 2-tier severity (error→warning) + status tags + optional-channel framing (b) 3-tier status (fail→warn→manual) + same | **(a) 2-tier** (amended by Phase-4 gate OBJ-A; was (b)) | 3-tier broke the headline coupling (counterexample: manual #9 vs warn #11 — headline picks declared-order, a 3-tier plan picks the warn). 2-tier makes fix_plan selection constructionally identical to `computeHeadline`'s lead pick; the noise-management burden moves entirely to the `[fail]/[warn]/[manual]` tags + "ignorable if unused" framing, which are retained. Detail below; §4.3 Fix Plan. (R11/OBJ-A) |

**D10 — Structural guard against arbitrary-binary execution (R10 ← boomer OBJ-7; the E4 incident's most important lesson).** The "never execute any on-disk binary other than self" rule (C4/NG7, Honesty Contract #3) is elevated from prose to **structure**:
1. **Typed-tool allowlist.** Production `runCommand` routes every subprocess through a typed allowlist — `enum DoctorTool { case codesign, xattr, lipo, strings, sqlite3, plutil, which, brew, osascript, curl, gh }` — each mapped to a **fixed absolute path** (`/usr/bin/codesign`, `/usr/bin/strings`, `/usr/bin/sqlite3`, …). The production implementation **fail-closed rejects** (returns nil, spawns nothing) any executable not in the allowlist; this rejection is **pinned by a unit test**. The `Runtime` seam signature stays `(String, [String]) -> …` for fixture compatibility — enforcement lives **inside the production implementation**, not in the seam type.
2. **Lint test.** A source-grep test asserts `SetupDoctor.swift` (and any new doctor source file) contains **no direct `Process`/`posix_spawn` use outside `BoundedProcessRunner`**, so a future edit cannot silently reintroduce an unbounded/arbitrary spawn.

This closes the E4 incident structurally: an old `/opt/homebrew/bin/LogicProMCP` can never be handed to `runCommand` as an executable (it is not a `DoctorTool`); the only versioning path remains the static `strings` sniff (D2).

**D11 — Fix Plan legibility + optional-channel noise (R11 ← boomer OBJ-4; ordering amended by Phase-4 gate OBJ-A).** No check is removed — each earned its place (on this Mac N5/N7/N8/N11/N12 are all non-`pass` live). Instead the plan is made legible: (1) **ordering is 2-tier severity** (`error` → `warning`, declared order within — canonical rule in §4.3 Fix Plan; the original 3-tier sort was withdrawn because it breaks the headline coupling, see §4.3 Ordering); (2) **per-line status tags** `[fail]/[warn]/[manual]` — these, not the sort, carry the hard-fault-vs-operator-choice distinction; (3) **optional-channel framing** — N11/N12 (and, as a wording-only touch that does **not** alter its status logic per C2, `channels.manual_validation`) name the dependent op family (e.g. MCU-only: `set_master_volume`/`set_output_volume`/`set_send`/`track.set_automation`) and state "ignorable if those ops are unused", so an unused optional channel never reads as a hard fault. Consistency with R1: `manual` is `warning`-severity, hence a Fix-Plan member — tags operate *within* the membership set §4.3 defines.

### 4.5 Honesty Contract (first-class design principle)

1. **False-green = 0.** No check reports `pass` for something it did not verify. Every "cannot verify" path emits `manual` or `skipped` **plus an enumerated `reason`** from the closed set: `config_absent` / `config_unreadable` / `bundle_unreadable` / `share_dir_unresolved` / `share_dir_invalid` / `relative_command` / `full_disk_access_unavailable` / `tcc_query_unavailable` / `tcc_schema_mismatch` / `principal_not_found`. The `binary.version` self-admission ("never fails", `SetupDoctor.swift:449-453`) is the anti-pattern this PRD closes with `install.binary_inventory`.
2. **False-red = 0.** `fail` is reserved for "confirmed broken" (missing binary, denied Accessibility/PostEvent, Logic not installed, macOS < 14). Environmental capability gaps (no FDA, no brew, source build, Logic not running) degrade to `skipped`/`manual`, mirroring the existing `system.macos_version` unreadable→`skipped` template (`SetupDoctorEnterpriseTests.swift:553-560`).
3. **Never execute arbitrary on-disk binaries (C4/NG7) — enforced structurally, not by prose (D10).** The E4 incident (running `/opt/homebrew/bin/LogicProMCP --version` on a v3.5.0 binary started the full 7-channel server for ~1.7s and touched `com.apple.logic.pro.cs` mtime; no lasting binding — 0 MCU-port occurrences) is the concrete reason. Version discovery is static `strings` only. **Enforcement (D10):** production `runCommand` routes through the typed `DoctorTool` allowlist (fixed absolute paths; fail-closed nil on anything else, pinned by a unit test) **plus** a source-grep lint test forbidding `Process`/`posix_spawn` outside `BoundedProcessRunner`.
4. **Read-only contract, precisely (C3).** Doctor never spawns another LogicProMCP/MCP session, never creates a CoreMIDI client/port, and never mutates system state. It runs only well-known Apple metadata tools bounded (`codesign`/`xattr`/`lipo`/`strings`/`plutil`/`sqlite3` read-only SELECT) via `BoundedProcessRunner` (timeouts 1.0–3.5s). TCC.db is opened with the **`file:…?immutable=1` URI (mandatory, R3)** so no `-wal`/`-shm` sidecar is ever created. `com.apple.logic.pro.cs` is **never** parsed with `plutil` (FORM/IFF binary, C6) — positive-only `strings` scan.
5. **Evidence egress (C7).** Only bundle ids / enums / bools / version strings leave the process. Full paths under `$HOME` are `~`-abbreviated; TCC blobs, `auth_reason`, other apps' human names, and user document paths are never emitted.
6. **Live-probe authority.** The TCC.db layer is explicitly labeled enrichment; where it and a live probe could disagree, the summary states the live probe (same-context) is authoritative (E3 §C7, deliverable (ii)).

---

## 5. Edge Cases & Error Handling

| # | Scenario | Expected behavior | Severity |
|---|---|---|---|
| E1 | Two Logic Pro copies (`/Applications` + `~/Applications`) | `logic.installation` = `pass`, evidence names both; `logic.version_support` compares the `/Applications` copy (documented tie-break) | info |
| E2 | Logic installed but not running | `logic.installation`/`version_support` evaluate normally; `logic.application_state` = `manual` (existing); `logic.blocking_dialog` = `skipped` `bb=logic.application_state` | manual |
| E3 | Logic running, Accessibility denied | `logic.blocking_dialog` = `skipped` `bb=permissions.accessibility`; `permissions.accessibility` = `fail` | error |
| E4 | FDA unavailable (no TCC.db read) | `permissions.tcc_cross_context` = `skipped` `reason=full_disk_access_unavailable`; live probes still reported; never `fail` | info |
| E5 | Source build (`.build/release`) | `install.binary_inventory` = `pass` (0 canonical candidates); `install.share_dir` = `skipped` `reason=share_dir_unresolved`; `install.source` = `sourceBuild` (existing) | info |
| E6 | Registered command path missing/renamed | `mcp.registration_target` = `warn` (path missing) — never executes it | warning |
| E7 | `strings` sniff returns only `0.0.0`-class | ranking filter drops it → treat as "version indeterminate" in evidence, no false version-mismatch `warn` | info |
| E8 | `com.apple.logic.pro.cs` absent | `channels.mcu_wiring_hint` = `manual` (same guidance as a miss) — never `fail` | manual |
| E9 | `sqlite3` binary absent / URI unrecognized / TCC schema drift | `permissions.tcc_cross_context` = `skipped` with the matching 3-way reason (R15): `tcc_query_unavailable` (sqlite3 absent or URI filename not recognized) / `tcc_schema_mismatch` (opens but an addressed column is absent) / `full_disk_access_unavailable` (cannot open); bounded-runner `spawnFailed`/`timedOut` never throws | info |
| E10 | PostEvent denied but Accessibility granted | `permissions.post_event_access` = `fail`; `allGranted=false`; aggregate clamped off `ok`; `dependencies.click_fallback` may escalate to `warn` if cliclick also absent | error |
| E11 | `--check-permissions` after PostEvent folded into `allGranted` | a host granted Accessibility+Automation but denied PostEvent now exits **1** (was 0) — a corrected false-green, documented in §9.1 | warning |
| E12 | Blocking dialog with empty/foreign-locale title | `logic.blocking_dialog` = `warn`; evidence carries whatever `blockingDialogInfo` returns; no crash on nil fields | warning |
| E13 | Logic `.app` present but `Info.plist` unreadable / no `CFBundleShortVersionString` (R4) | `logic.installation` = `skipped` `reason=bundle_unreadable` (never a false-`fail` "not installed"); `logic.version_support` = `skipped` `bb=logic.installation` | info |
| E14 | `claude_desktop_config.json` present but not valid JSON (R4) | `mcp.claude_desktop_registration` = `skipped` `reason=config_unreadable` (never a false-`warn` "unregistered") | info |
| E15 | Registered `command` is a relative path / bare PATH-name (R4) | excluded from resolve + version compare; evidence `reason=relative_command`; no CWD-relative false-`warn` (NG4) | info |
| E16 | `LOGIC_PRO_MCP_SHARE_DIR` (or pkgshare) resolves to a **file**, not a dir (R4) | `install.share_dir` = `skipped` `reason=share_dir_invalid` (`isDirectory` forced; no "everything missing" false-`warn`) | info |
| E17 | Candidate binary is non-Mach-O (wrapper script) (R4/R7) | `lipo`/`strings` yield no semver → version **indeterminate**; no version-mismatch `warn` | info |
| E18 | TCC.db readable but no matching-principal row (R5) | `permissions.tcc_cross_context` = `skipped` `reason=principal_not_found`, never `pass` | info |

---

## 6. Security & Permissions

### 6.1 Authentication
N/A — local CLI, no network except opt-in `--check-updates` (unauth GitHub releases, C9/NG6).

### 6.2 Authorization
N/A — doctor performs no privileged mutation. It **reads** local files (Info.plist, `~/.claude.json`, `claude_desktop_config.json`, share dirs, `com.apple.logic.pro.cs`, TCC.db) and runs bounded read-only metadata tools. It writes nothing (contrast: `--approve/--revoke-channel` write the approvals file — those are separate branches, unchanged).

### 6.3 Data Protection

- **TCC.db privacy defense (N10).** Reading `com.apple.TCC/TCC.db` surfaces *other apps'* grant rows. Defense: (1) **local + read-only, `file:…?immutable=1` open (mandatory, R3)** — no `-wal`/`-shm` sidecar is ever created; (2) **redacted egress** — only `{service, principal_hint(bundle id|basename), state}` for the small closed set of MCP-relevant principals leave the process; never csreq/`indirect_object_code_identity` blobs, full paths, `auth_reason`, pids, or other apps' human names (C7, E3 §iii); (3) **self-limiting** — absent FDA / unreadable / schema-drift ⇒ `skipped` (R15 3-way reason), no partial leakage. The check answers only "does the host principal have `<service>`", not a dump of the table.
- **No arbitrary execution (C4/NG7) — structural (D10).** The only executables invoked are the fixed `DoctorTool` allowlist entries (absolute paths); production `runCommand` fail-closed rejects anything else, and a source-grep lint forbids `Process`/`posix_spawn` outside `BoundedProcessRunner`. No code path takes an on-disk candidate path as an executable to run.
- **Evidence redaction is a centralized default-deny allowlist (R9).** Egress is default-**deny**: only the explicitly-allowlisted field shapes (bundle id / enum / bool / semver, with `~`-abbreviated `$HOME` paths) cross the `evidence`-assembly boundary; everything else is dropped, so no per-check author can accidentally leak a full path. In particular, **raw subprocess `stderr` and the `BoundedProcessRunner.spawnFailed(String)` message are never placed in `evidence`** (they can carry absolute paths / environment detail) — a check maps them to a fixed enumerated `reason` instead.

---

## 7. Performance & Monitoring

**Targets (R12).** *Typical* p50 **≤ 2 s**, p95 **≤ 5 s** on a healthy machine (Logic installed+running, FDA present), measured as the sum of per-check `duration_ms` (already stamped, `SetupDoctor.swift:231-238`). These are the operative targets. **Separately**, the **worst-case pathological tail** — *every* bounded subprocess hitting its timeout ceiling at once — is *bounded* (not expected) at **≈ 30 s** (table below). That is a timeout-driven ceiling, never a latency the user should see, since a real machine does not have all metadata tools hang simultaneously.

**Subprocess budget — worst-case enumeration (each call reuses the proven `BoundedProcessRunner` envelope; `.timedOut` returns no partial output).**

| Tool | Max calls | Per-call ceiling | Consuming checks | Σ worst-case |
|---|---|---|---|---|
| `codesign` | 1 | ≤3.5 s | `release.signature` | 3.5 s |
| `xattr` | 1 | ≤1.0 s | `release.quarantine` | 1.0 s |
| `brew` | ≤2 | ≤3.5 s | `install.source`, `install.share_dir` (pkgshare, 2 prefixes) | 7.0 s |
| `which` | ≤1 | ≤1.0 s | dependency resolution | 1.0 s |
| `osascript` | 2 | ≤1.0 s | automation probes (Logic Pro + System Events) | 2.0 s |
| `lipo` | ≤3 | ≤1.5 s | N7 `install.binary_inventory` (per candidate) | 4.5 s |
| `strings` | ≤4 | ≤1.5 s | N7 (≤3 candidates) + N12 `mcu_wiring_hint` (cs file) | 6.0 s |
| `sqlite3` | 2 | ≤1.5 s | N10 `tcc_cross_context` (user + system DB) | 3.0 s |
| `plutil` | ≤2 | ≤1.0 s | plist metadata reads | 2.0 s |
| `CGPreflightPostEventAccess` | 1 | in-proc (~0) | N1 `post_event_access` | ~0 |
| **Base total (26 checks)** | | | | **≈ 30 s ceiling** |
| (`--check-updates`) `curl`/`gh` | 1 | network-bounded | `updates.latest_release` | + network |

- **`--json` byte stability**: deterministic across runs — whole-ms `duration_ms` rounding (`:234-237`) + sorted keys.

**Rationale (R12c).** Checks run **sequentially** (no concurrency, `SetupDoctor.swift:228-229`) and non-throwing — a **deliberate inheritance of v2's single-pass simplicity**, not an oversight. Dominant *typical* cost remains the two `osascript` probes (≤1.0 s each) and `brew` when present; the `sqlite3` SELECTs are indexed single-table reads over a small DB. **Parallelization is a measured-need follow-up, out of scope here.** A one-time real `strings -a` timing on the 3.5.0 universal binary is recommended during T4 to confirm the ≤1.5 s ceiling is comfortable (it scans the whole Mach-O; strategist-P3-E).

### 7.1 Monitoring & Alerting
Doctor is a one-shot CLI (no runtime telemetry). The observable signal is the report itself; the live-acceptance E2E (§8.4) is the regression sensor. `system.health`'s `post_event_access` remains the runtime counterpart (NG1 keeps them separate; parity follow-up recorded).

---

## 8. Testing Strategy

### 8.1 Unit Tests (T1)
- **Per-check status matrix**: every new check, every status path — N2 **3-way** (fail = both `.app` absent / `skipped(bundle_unreadable)` = present-but-unreadable / pass); N3 **single derivation** (`N2 != pass ⇒ skipped bb=logic.installation`) plus the four in-support branches when N2==pass (floor `fail`, best-effort `warn`, `pass`, `>latestValidated warn`); N6 absent→`skipped(config_absent)` / broken-JSON→`skipped(config_unreadable)` / present±registered; N7 stale vs consistent vs zero-candidate vs **indeterminate (≥2 distinct semver)**; N8 missing vs complete vs unresolved vs **`share_dir_invalid`**; N10 warn / pass / **`principal_not_found`** / 3-way capability `skipped` (`full_disk_access_unavailable` / `tcc_query_unavailable` / `tcc_schema_mismatch`); N12 hit/miss/absent.
- **`blocked_by` cascade**: cause `≠ pass` ⇒ derived `skipped` + correct `bb`; `logic.blocking_dialog` precedence (running-first) covered both ways.
- **Fix Plan (R1/R11)**: **3-tier status ordering `fail → warn → manual`**, declared-order tiebreak within a tier, remediation dedup, blocked-item exclusion, **`manual` inclusion** (a standalone `manual` N11/N12 appears under the `[manual]` tier), status-tag rendering (`[fail]/[warn]/[manual]`); empty fix plan ⇒ healthy headline. **Headline coupling asserted by id-extraction, NOT string equality**: `#expect(report.headline.contains("[\(report.fixPlan[0])]"))` (or compare `lead.id`) — a literal `headline == fixPlan[0]` is forbidden (always false → a dead test, colliding with the repo dead-`#expect` footgun, R6).
- **Fix Plan human-render modes (R8)**: the `Fix plan:` section renders in default + `--verbose` + `--quiet`, honors `useColor`, and leaves `--json` bytes unchanged (AC-5.3) — per-mode render test.
- **Honesty chokepoint**: extend `clampStatusForPermissions` test (`SetupDoctorEnterpriseTests.swift:540-551`) for PostEvent-denied ⇒ `allGranted=false` ⇒ not `ok`; assert the **honest default** — an unset `postEventAccessState` reads `denied`, never `granted` (R2).
- **Typed-tool allowlist + lint (D10/R10)**: unit test that production `runCommand` **fail-closed rejects** (returns nil, spawns nothing) an executable outside the `DoctorTool` allowlist; source-grep lint test asserting **no `Process`/`posix_spawn` outside `BoundedProcessRunner`** in `SetupDoctor.swift` (+ any new doctor source file).
- **Pure parsers**: `strings`-version ranking (collect `^\d+\.\d+\.\d+$` → drop `major==0` → dedup → exactly-one⇒adopt / ≥2⇒indeterminate); launch-context classifier **precedence** (ancestry bundle-id > `__CFBundleIdentifier` > `TERM_PROGRAM` > unknown); TCC-row → `{service,principal,state}` mapper (incl. no-matching-row ⇒ `principal_not_found`); share-dir diff — all pure functions, table-tested.
- **`--strict` matrix**: 4 aggregates × exit code (AC-5.1), and default-mode invariance (AC-5.2).

### 8.2 Integration / Contract Tests (T2 — extend the v2 contract)
- **Exact-id array** (`SetupDoctorTests.swift:83-97`): update to the 26-id order in §4.3; 27 with `--check-updates`.
- **Schema string**: `logic_pro_mcp_doctor.v2` → `…v3` everywhere it's asserted.
- **Frozen-decode superset**: keep the `FrozenV1Report` test (`SetupDoctorEnterpriseTests.swift:189-247`) — its 11 v1 ids must still decode from v3 (update the `schema ==` assertion to `…v3`); **add** a new `FrozenV2Report` decode test proving v3 output decodes into a frozen v2-shaped struct (v2's `summary`/`category`/`severity`/`duration_ms` all survive) — the E1 §5 FrozenV1 pattern extended.
- **Anchor lint** (`SetupDoctorTests.swift:203-213`): `remediationAnchorsByCheckID` gains 13 entries; `docs/SETUP.md` gains 13 `<a id>` anchors (slugs in §8.5). Test asserts every anchor id exists.
- **Summary invariant**: `total == sum == checks.count` for 26 and 27 (extend `SetupDoctorEnterpriseTests.swift` count test).
- **Version consistency**: new V1 constant vs `manifest.json:13`; V2 ship-list vs Formula text.

**Fixture / baseline migration (R2 — mandatory; without it dozens of all-pass baselines flip to `degraded`/`manualActionRequired`).** This is about *baseline status*, not compilation (legacy-init compilation is already covered by the defaulted params in §4.2/§4.3).
- **(i) Enumerate every new seam and give it a fixture default.** New `PermissionChecker.Runtime` / `SetupDoctor.Runtime` / `PermissionStatus` seams introduced by v3: Logic `Info.plist` reader (N2), canonical-path enumerator (N7), share-dir reader (N8), keycmd-path exists (N11), cs-file `strings` (N12), TCC `sqlite3` runner (N10), launch-context detector (N9), and `postEventPreflight` / `CGPreflightPostEventAccess` (N1).
- **(ii) Extend the default fixture builders to a hermetic-*good* baseline** so all-pass tests stay all-pass: `doctorRuntime`/`enterpriseRuntime` seams default to subject-present/complete (Logic present @ `latestValidated`, canonical binary matches running version, share-dir complete, keycmd staged, cs-file MCU hit, TCC grant confirmed, launch-context known), and `grantedPermissionStatus()` (`SetupDoctorTests.swift:53`) sets **`postEvent = granted`** — otherwise the extended `allGranted` (§4.2) flips false → clamp → `degraded`, breaking every `.ok`/exit-0 baseline (e.g. `SetupDoctorTests.swift:169`).
- **(iii) Update the enumerated call sites**: `grantedPermissionStatus()` (`SetupDoctorTests.swift:53`), the positive `allGranted` assertions at `ProductionReadinessTests.swift:311` and `ProcessUtilsTests.swift:289`, and the **count/duration magic values `13 → 26`** at `SetupDoctorEnterpriseTests.swift:152,155` (`count == 13` and `durationMs == 13.0` — 1 ms/check × 13 — become 26).

### 8.3 Edge-Case Tests (T2/T3)
Cover §5 E1–E12; especially E5 (source build all-honest), E10/E11 (PostEvent fold), E7 (`0.0.0` filter).

### 8.4 CI-Honesty Test (T3, C8)
A hermetic `Runtime`+`PermissionStatus` fixture modeling the runner's **diagnostic-capability absence** — TCC.db unreadable, FDA absent, brew absent, `sqlite3` absent, Logic **not running** — with the *subject present* (fileExists(Logic.app)=true, binary resolves). **Fixture permission posture (R6):** `accessibility` + `automation_logic_pro` + `automation_system_events` + `postEvent` are **all fixed `granted`**, so the test isolates *diagnostic-capability* absence and no existing permission check reds the aggregate. Assert: no new check is `fail` **on account of absent diagnostic capability**; the infrastructure-gated checks are `skipped`/`manual`/`pass`; the aggregate is `degraded`/`manual_action_required`, **never a spurious `failed`**. This is exactly the C8 guarantee (a new check never fails for lack of capability) and is consistent with D7: a *real* bare runner has Accessibility denied → an honest `failed`, which is fine because `doctor` is **not** a CI gate (verified). Add a *separate* honest test: Logic **absent** ⇒ `logic.installation=fail` + `version_support` `skipped bb=logic.installation` + `blocking_dialog` `skipped` + aggregate `failed` (correct, not a C8 violation — see D7/OQ-1).

### 8.5 Docs (M8)
`docs/SETUP.md` §Doctor: bump v2→v3 prose (line 139 superset note gains `blocked_by`+`fix_plan`), document `--strict` + the exit matrix **plus the exit-code conventions (R14): `2`/`3` are status codes, not usage errors, and sit below the `sysexits.h` 64–78 range; test non-zero for a boolean; note the `set -e` caveat; include a copy-paste CI snippet branching on `0/1/2/3`**, and add these `<a id>` anchors + `### check.id` headings — `doctor-installbinary-inventory`, `doctor-installshare-dir`, `doctor-mcpregistration-target`, `doctor-mcpclaude-desktop-registration`, `doctor-permissionspost-event-access`, `doctor-permissionslaunch-context`, `doctor-permissionstcc-cross-context`, `doctor-logicinstallation`, `doctor-logicversion-support`, `doctor-logicblocking-dialog`, `doctor-channelskeycmd-reference`, `doctor-channelsmcu-wiring-hint`, `doctor-dependenciesclick-fallback`. `TROUBLESHOOTING.md`: add the PostEvent + stale-install + cross-context triage entries.

### 8.6 Live E2E (T4/T5)
Fresh `.build/release` binary run on this Mac reproduces §7-of-decision exactly (§11). `swift test --no-parallel` full green + `swift build -c release` green (T5). Live technique: drive the freshly-built binary directly (it inherits Accessibility via the trusted-terminal parent) — no MCP session needed for the CLI path.
- **Release gate — N10 non-`skipped` (R15).** On an **FDA-present dev Mac**, the release live E2E asserts `permissions.tcc_cross_context` is **non-`skipped`** (it actually queried TCC.db), so a macOS-update-driven schema drift surfaces at the release gate rather than degrading silently in the field.
- **Read-only proof (R3).** The same run asserts **no `-wal`/`-shm`/`-journal` sidecar** was created next to either TCC.db by the `immutable=1` open.

---

## 9. Rollout Plan

### 9.1 Migration Strategy (consumer compatibility)
- **v2 → v3 is additive** (G5). Consumers prefix-matching `logic_pro_mcp_doctor.` (per `docs/SETUP.md:139`) are unaffected; `blocked_by` is omitted when nil; `fix_plan` is a new optional top-level key. No data migration (read-only tool).

**Consumer compatibility matrix (R13).**

| Consumer type | v3 impact | Action |
|---|---|---|
| **Exact-13-id array assertion** (repo-internal tests only — no external consumer) | Breaks (now 26/27) | Updated in-repo to the §4.3 order (§8.2); no external action |
| **Strict unknown-key-rejecting validator** | Would reject `blocked_by`/`fix_plan` if configured strict | Docs already forecast additive keys (`SETUP.md:139`) — restate "ignore unknown keys"; v3 adds only optional keys (no rename/removal), so a spec-compliant additive consumer is unaffected |
| **`skipped`-count alarm/threshold consumer** | `skipped` baseline **rises** in v3 (N6 `config_absent`, N10 capability reasons, N8 source-build) | CHANGELOG behavior note: a higher `skipped` count is expected, not a regression |
| **`blocked_by`/`fix_plan`-unaware UI** | None (additive) | Harmless — extra keys ignored; existing rendering unchanged |

- **One documented behavior change**: `--check-permissions` now folds PostEvent into `allGranted`, so a host with Accessibility+Automation granted but PostEvent denied now exits **1** (was 0). This corrects a false-green (E11). Called out in `docs/SETUP.md` + `TROUBLESHOOTING.md`. Doctor's own default exit is unchanged (C10). **The Formula `test do` comment** ("exit 0 when Accessibility+Automation granted") is now stale post-fold and is updated alongside (R9).

### 9.2 Feature Flag
None. `--strict` is opt-in and additive; `permissions.tcc_cross_context` is default-on (D6) with `skipped` self-degradation, so it needs no flag. (If the orchestrator overrides D6 to opt-in, it becomes a `--check-tcc`-style flag — OQ-2.)

### 9.3 Rollback Plan
Single behavior-additive PR on `feature/doctor-v3`. Rollback = `git revert` of the merge; no persisted state, no schema migration to undo. The v2 contract tests remain as the safety net (any accidental v2 break fails CI before merge).

---

## 10. Dependencies & Risks

### 10.1 Dependencies
| Dependency | Owner | Status | Risk if delayed |
|---|---|---|---|
| `AXLogicProElements.blockingDialogInfo` (N4 reuse) | existing (`AXLogicProElements.swift:99-125`) | present | none — read-only reuse |
| `CGPreflightPostEventAccess` (N1) | Apple SDK | present (used in health, `SystemDispatcher.swift:212`) | none |
| `manifest.json` floor for V1 pin | repo (`manifest.json:13`) | present | consistency test can't be authored |
| Formula ship-list for V2 pin | repo (`Formula/logic-pro-mcp.rb:28-48`) | present | drift test weaker |
| Live Mac + Logic 12.3 for T4 | Isaac | available (§7) | live acceptance deferred |

### 10.2 Risks
| Risk | Prob. | Impact | Mitigation |
|---|---|---|---|
| **R1** — `strings` version sniff mis-ranks a real version (multi-version binary, odd embed) → false `warn`/missed stale | Med | Med | Ranking filter (drop `0.0.0`-class, prefer tag-like); "indeterminate ⇒ no version-mismatch warn" (E7); unit table incl. the live `0.0.0`+`3.5.0` case |
| **R2** — TCC schema drift across macOS releases breaks the SELECT (macOS 26.3 schema in E3 §B4) | Med | **Med** (R15, ↑ from Low) | (a) **3-way `skipped` reason** — `full_disk_access_unavailable` / `tcc_query_unavailable` / `tcc_schema_mismatch` — so drift is *identifiable in the report*, not silent; (b) **release live E2E on an FDA-present dev Mac asserts N10 is non-`skipped`** (§8.6), catching macOS-update drift at the release gate; (c) column-addressed SELECT (not `SELECT *`) + natural degrade on any failure ⇒ `skipped`, never `fail` (D5 — false-red impossible); pure-mapper test on frozen row fixtures |
| **R3** — N10 default-on privacy pushback (reads other apps' TCC rows) | Med | Med | C7 redaction + read-only/immutable open + self-degrade; D6 documents the trade-off; boomer opt-in proposal routes to orchestrator (OQ-2) |
| **R4** — C8 vs N2 misread ⇒ someone downgrades `logic.installation` to non-fail, weakening the diagnostic | Low | High | D7 + OQ-1 resolve it explicitly; §8.4 fixture contract pins both the honesty test (subject present) and the honest-fail test (subject absent) |
| **R5** — Bash-capable review subagents mutate the shared worktree / switch branch mid-review (recurring: PR #209, #211) | Med | High | Re-audit `git status`/`git branch`/`git diff` after every review-agent spawn, before commit; **never** `git checkout/switch/stash` on `feature/doctor-v3` |
| **R6** — dead `#expect` masking a false-green in new negative assertions | Med | High | Force/concrete forms only (`#expect(x!)`, `!expr`); never `#expect(optBool == true/false)`/`?? false`/`== .some(true)` (repo footgun, issue #92) |
| **R7** — exact-26-id array churn from a reorder disagreement | Low | Med | §4.3 fixes the canonical order + proves existing-13 relative order preserved |

---

## 11. Success Metrics

| Metric | Baseline (v2, this Mac) | Target (v3, this Mac) | Method |
|---|---|---|---|
| Stale-install detection | undetected (3.5.0 shadow silent) | `install.binary_inventory=warn` naming both versions | live E2E |
| PostEvent false-green | possible (`ok` while CGEvent dead) | impossible (folded into `allGranted`/clamp) | unit + live |
| Live-acceptance set (§7 of decision) | N/A | exact match: `logic.installation=pass(12.3)`, `version_support=pass`, `application_state=pass`; `mcp.claude_code_registration=warn` + `registration_target=skipped(bb)`; `install.binary_inventory=warn(3.5.0≠running)`; `install.share_dir=warn(4 missing)` (or brew-pkgshare fallback if unregistered); `keycmd_reference=manual`; `mcu_wiring_hint=manual`; permissions honest + `launch_context` stated; Fix Plan status-ordered (`fail → warn → manual`, `[status]`-tagged) with the id embedded in `headline` `== fix_plan[0]` | live E2E on release build |
| False-green / false-red count | — | **0 / 0** | unit matrix + live |
| Test suite | 2077 (`swift test --no-parallel`) | green, materially higher (all new checks + contract) | CI |
| Docs-anchor lint | 13 anchors | 26 anchors, green | contract test |

---

## 12. Open Questions

> **All four resolved** by orchestrator sign-off (2026-07-06, round-1 review disposition, R9). Retained as a decision record; no longer blocking.

- [x] **OQ-1** — D7 confirmed: `logic.installation` **stays `fail`** on Logic-absent (honest chain root); C8 satisfied via hermetic tests since `doctor` is not a CI gate (verified). **Signed off: fail-retained.**
- [x] **OQ-2** — D6 confirmed: `permissions.tcc_cross_context` **default-on** (read-only, redacted, self-degrading). A boomer opt-in proposal would route to orchestrator escalation — none requested. **Signed off: default-on.**
- [x] **OQ-3** — `logic.blocking_dialog` `blocked_by` precedence confirmed **running-first** (Logic-not-running → `bb=logic.application_state`, else AX-denied → `bb=permissions.accessibility`). **Signed off: running-first.**
- [x] **OQ-4** — Dual-Logic-copy version tie-break confirmed: compare the **`/Applications`** copy for `logic.version_support` (evidence still names both). **Signed off: /Applications.**

### 12.1 Deviations from the binding decision
**None.** No new check, constant, mechanic, or constraint departs from `doctor-v3-requirements-decision.md`. The four items above (D7/OQ-1, D6/OQ-2, OQ-3, OQ-4) are **clarifications of under-specified points**, now signed off. The `evidence`-serialization (D8) and `blocked_by`-omit-when-nil (D9) decisions are implementation realizations of the decision's "v2 strict superset" (C1/M1). The v0.2 round-1 reflections (R1–R15), including new decisions **D10** (typed-tool allowlist) and **D11** (Fix-Plan legibility; ordering amended to 2-tier by the Phase-4 gate, OBJ-A), are **spec/contract hardening within the decision's scope** — no check added or removed, no constraint relaxed — not departures.

---
<!-- Sections 4.1–12 complete (L size). -->
