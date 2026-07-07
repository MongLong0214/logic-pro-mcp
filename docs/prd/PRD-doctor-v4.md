# PRD: Doctor v4 — Intent-Aware, Source-Aware Readiness Platform

**Version**: 0.2
**Author**: CEO/CTO planning rail (draft: Codex GPT-5.5 xhigh; final review/revision: CTO Fable)
**Date**: 2026-07-07
**Status**: CTO-reviewed v0.2 — final for ticket execution
**Size**: XL

**Changelog**
- v0.2 (2026-07-07, CTO Fable): schema decision made (v4 bump, §5.0); profile-scoped aggregate calculus added (§5.1.1); capability status vocabulary corrected to fail-closed 4-state + derivation table added (§5.3); client detection precedence + resolution-basis honesty caveat (§5.2, §5.10); share-dir manifest / renderer v4 / marker sequencing sections added (§5.8–5.10); all Open Questions decided (§10).
- v0.1 (2026-07-07, Codex draft): initial.

## 1. Problem Statement

Doctor v3 is implemented and production-reviewed: all nine tickets are Done, the focused and full test suites passed, the live E2E passed, and the final gate approved (`docs/tickets/doctor-v3/STATUS.md:17`, `docs/tickets/doctor-v3/STATUS.md:27`, `docs/tickets/doctor-v3/STATUS.md:31`, `docs/tickets/doctor-v3/STATUS.md:32`, `docs/tickets/doctor-v3/STATUS.md:33`, `docs/tickets/doctor-v3/STATUS.md:44`).

v3 solved causal diagnostics, but it still compresses different user intents into one readiness headline. A source-build terminal user, a Cursor user, a Claude Desktop user, a mixer-only user, and a full legacy Scripter user can all see the same aggregate class even though their required setup differs. v4 must answer: "ready for what, from which client, from which install source, using which capability?"

## 2. Current v3 Baseline

v3 already provides:

- schema `logic_pro_mcp_doctor.v3`, `blocked_by`, `fix_plan`, optional checks, and strict exits (`Sources/LogicProMCP/Utilities/SetupDoctor.swift:66`, `Sources/LogicProMCP/Utilities/SetupDoctor.swift:122`, `Sources/LogicProMCP/Utilities/SetupDoctor.swift:279`, `Sources/LogicProMCP/Utilities/SetupDoctor+Rendering.swift:121`).
- PostEvent folded into permission readiness (`Sources/LogicProMCP/Utilities/PermissionChecker.swift:55`, `Sources/LogicProMCP/Utilities/PermissionChecker.swift:88`, `Sources/LogicProMCP/Utilities/PermissionChecker.swift:135`).
- DoctorTool allowlist and typed production command outcomes (`Sources/LogicProMCP/Utilities/DoctorTool.swift:1`, `Sources/LogicProMCP/Utilities/DoctorTool.swift:14`, `Sources/LogicProMCP/Utilities/SetupDoctor+ProductionSupport.swift:30`, `Sources/LogicProMCP/Utilities/SetupDoctor+ProductionSupport.swift:41`).
- Manual validation approvals for MIDI Key Commands and Scripter (`Sources/LogicProMCP/Utilities/ManualValidationStore.swift:4`, `Sources/LogicProMCP/Utilities/ManualValidationStore.swift:37`, `Sources/LogicProMCP/Utilities/ManualValidationStore.swift:95`).
- Existing human renderer and aggregate logic where non-optional skipped checks degrade readiness (`Sources/LogicProMCP/Utilities/SetupDoctor+Rendering.swift:10`, `Sources/LogicProMCP/Utilities/SetupDoctor+Rendering.swift:130`, `Sources/LogicProMCP/Utilities/SetupDoctor+Rendering.swift:137`).

## 3. Goals

- Add `DoctorProfile`: `auto`, `core`, `mixer`, `keycmd`, `legacy-scripter`, `full`.
- Add `ClientProfile`: `auto`, `claude-code`, `claude-desktop`, `cursor`, `vscode`, `terminal`, `custom`.
- Add source-aware remediation: `homebrew`, `source_build`, `release_binary`, `unknown`.
- Add top-level capability readiness: `core_transport`, `track_management`, `midi_import`, `mixer_ax`, `mixer_mcu`, `project_lifecycle`, `keycmd_only_ops`, `legacy_scripter`, `verified_plugin_applyback`.
- Add `skip_reason` so every skipped check is explained by `skip_reason` or `blocked_by`.
- Separate "approved" from "intentionally skipped" in manual validation decisions.
- **Schema (DECIDED)**: bump to `logic_pro_mcp_doctor.v4` as a **strict field-superset of v3** — every v3 key keeps its name/semantics/value; `skip_reason` (per-check, omit-when-nil like `blocked_by`), `capabilities`, and the profile/client block are additive. Consumers already prefix-match `logic_pro_mcp_doctor.` per `docs/SETUP.md`, so the bump is the honest signal with zero breakage; keeping the v3 string while changing aggregate semantics would be a silent contract change and is rejected. A `FrozenV3Report` decode test (extending the shipped FrozenV1/V2 pattern) pins the superset.

## 4. Non-Goals

- No auto-fix execution.
- No removal of v3 checks.
- No change to server runtime/channel routing behavior outside doctor/readiness.
- No hiding of failed required checks through profiles. Profiles may downgrade optionality only when a capability is explicitly out of scope.
- No raw stderr, token, env secret, or unrestricted absolute-path evidence in JSON.

## 5. v4 Model

### 5.1 DoctorProfile

| Profile | Required capability groups | Optional/skipped by design |
|---------|-----------------------------|-----------------------------|
| `core` | core transport, track management, project lifecycle basics | Scripter, MIDI Key Commands, MCU-only paths |
| `mixer` | core + mixer AX + verified plugin apply-back | Scripter, keycmd-only ops unless explicitly requested |
| `keycmd` | core + keycmd-only ops | Scripter, MCU-only paths |
| `legacy-scripter` | core + legacy Scripter | Key Commands unless needed |
| `full` | all shipped capabilities | none by profile |
| `auto` | infer from client/config/manual store, otherwise `core` | profile inference recorded |

#### 5.1.1 Profile-Scoped Aggregate Calculus (normative — the honesty contract under profiles)

1. The aggregate (`ok`/`degraded`/`manual_action_required`/`failed`) is computed **only over the checks the selected profile requires**. The shipped v3 aggregate rule (fail → failed; manual → manual_action_required; warn or non-optional-skipped → degraded; `Sources/LogicProMCP/Utilities/SetupDoctor+Rendering.swift:130-140`) applies unchanged *within* that scope, including the permission clamp.
2. Profile-excluded checks **still run and still appear in the report** with `skip_reason:profile_not_required` (or their natural status tagged not-in-profile) — they are never hidden, never counted. Default human render summarizes them in one line; verbose lists them fully.
3. `full` profile ≡ v3 semantics (superset compatibility: a v3 consumer running `doctor --profile full` — or no flag before profile inference lands — sees v3-equivalent aggregate behavior).
4. **Invariant (CI-honesty per profile)**: within any profile, `ok` ⇒ every profile-required check verified honest (false-green 0 inside the declared scope). A hermetic test per profile pins this.
5. `intentionally_skipped` (operator decision, T5 store) and `profile_not_required` are distinct `skip_reason` values — an operator decision is never silently conflated with profile scoping.

### 5.2 ClientProfile

Client profile controls MCP registration checks. A Cursor or custom MCP user should not see missing Claude Code registration as a required warning. Existing Claude Code and Claude Desktop registration checks remain available, but profile optionality changes their aggregate effect.

**Auto-detection precedence (normative)**: explicit `--client` flag > launch-context ancestry bundle id (shipped classifier, extended host set) > registration-config presence heuristics (`~/.claude.json` logic entry ⇒ claude-code; `claude_desktop_config.json` entry ⇒ claude-desktop) > `custom`/generic. When detection lands on `custom`, **all client-specific registration checks become informational** with `skip_reason:client_not_selected`, and the report states which client was assumed and how to override. Detection basis is recorded in evidence.

### 5.3 Capability Readiness

Top-level JSON adds:

```json
{
  "capabilities": {
    "core_transport": {"status":"ready|not_ready|unknown_live_verify_required|not_in_profile", "checks":["..."]},
    "...": {"status":"...", "checks":["..."]}
  }
}
```

**Status vocabulary (DECIDED — fail-closed 4-state, replaces the draft's `ready|blocked|manual|skipped`):**
- `ready` — every required check for the capability is `pass`.
- `not_ready` — at least one required check is `fail` (or `warn` on a check the derivation marks hard-required).
- `unknown_live_verify_required` — no `fail`, but at least one required check is `manual`/`skipped`(unverified) — the doctor *cannot* prove readiness pre-start; the entry names the live verification (e.g. `logic://system/health mcu.connected`). **A capability is never `ready` on hint-grade evidence.**
- `not_in_profile` — excluded by the selected profile (still listed; never counted).

**Derivation table (normative — implementer contract; check ids are the shipped v3 26-check ids):**

| Capability | Required checks | Notes |
|---|---|---|
| `core_transport` | binary.path/executable, permissions.accessibility/post_event_access, logic.installation/version_support/application_state | CGEvent transport primaries |
| `track_management` | core_transport set + permissions.automation_logic_pro, logic.blocking_dialog(non-warn) | AX track ops |
| `midi_import` | core_transport set + permissions.automation_system_events | #188 lineage |
| `mixer_ax` | track_management set | AX-primary mixer ops |
| `mixer_mcu` | core_transport set + channels.mcu_wiring_hint | **hint-grade → capped at `unknown_live_verify_required`** (N12 is positive-only; doctor cannot prove live MCU feedback) |
| `project_lifecycle` | core_transport set + permissions.automation_logic_pro + automation_system_events | AppleScript save/open paths |
| `keycmd_only_ops` | core_transport set + channels.keycmd_reference + manual decision(keycmd) | profile/keycmd |
| `legacy_scripter` | core_transport set + manual decision(scripter) | approval or intentional skip |
| `verified_plugin_applyback` | mixer_ax set + logic.blocking_dialog pass | HC v2 verified path |

The table lives as **data** (in the T7 capability model, migrated verbatim into the T8 registry definitions) so the registry refactor absorbs it without rework. Optional-by-profile skips do not degrade the aggregate (§5.1.1).

### 5.4 skip_reason

Every skipped check must have exactly one of:

- `blocked_by`: caused by another check.
- `skip_reason`: environmental/profile reason such as `profile_not_required`, `client_not_selected`, `path_dependent_unresolved`, `capability_absent`, `source_build_no_share_dir`, `config_absent_optional`.

### 5.5 Source-Aware Remediation

Remediation must reflect install source:

- Homebrew: `brew upgrade logic-pro-mcp` or tap-specific reinstall.
- Source build: `git pull`, `swift build -c release`, and explicit path selection.
- Release binary: download/replace pinned asset.
- Unknown: conservative docs link, no wrong package-manager command.

All command snippets quote paths.

### 5.6 Typed Command Results

Replace nil-only command failure with:

- `completed`
- `timed_out`
- `spawn_failed`
- `not_allowlisted`

Preserve stdout/stderr truncation metadata and never leak raw secrets.

### 5.7 Evidence Builder

Evidence values are typed before serialization:

- `bool`, `int`, `version`, `enum`, `path`, `basename`, `sensitive`.
- Path policy: home-relative, basename-only, or hidden.
- Raw stderr/env/token values are forbidden unless explicitly redacted.

### 5.8 Share-Dir Manifest (required/optional split)

The v3 single ship-list becomes a two-tier manifest: **required** entries (SETUP.md, keycmd scripts/preset, Scripter JS — their absence is the stale-keg `warn` signal) vs **optional** entries (the bounce `.py` helpers — absence downgrades only the bounce capability note, never the install-chain warn). The manifest stays pinned to the Formula by the shipped drift test.

### 5.9 Renderer v4

Default human output is **end-user next-action centric**: headline, fix plan, capability summary, and profile/client line — schema string, header block, and per-check listing move to `--verbose`. `--quiet` keeps the v3 non-pass-only contract. `--json` remains byte-independent of every renderer option (shipped AC-5.3 contract inherited). The human output is explicitly documented as non-contractual (JSON is the machine contract) so this re-layout is not a breaking change; SETUP gains one migration note for header-grepping scripts.

### 5.10 Registered-Command Resolution Honesty (T3 caveat, normative)

`path_resolved` results MUST carry `resolution_basis:"doctor_path"` evidence and a summary caveat that the doctor resolved the bare command **in its own environment — the MCP client's spawn PATH may differ** (launchd-spawned clients historically lack `/opt/homebrew/bin`). Resolution probes fixed canonical paths first (`/opt/homebrew/bin`, `/usr/local/bin`), then the doctor's PATH via the allowlisted `which`. A resolved-and-validated target never upgrades the check beyond what an absolute registration would report.

### 5.11 Static Version Marker Sequencing (T10 honesty)

The marker exists only in binaries built at/after the marker release; the shipped `strings`-ranking sniff **remains as fallback** for older on-disk binaries, and "marker absent + ambiguous strings" stays `indeterminate` (never a mismatch warn). The PRD explicitly records that marker-based detection becomes effective one release after landing.

## 6. v3 Inheritance / Replacement Map

| v3 asset | v4 treatment |
|----------|--------------|
| T1 data spine (`blocked_by`, `fix_plan`, schema v3, DoctorTool allowlist) | Inherit; add `skip_reason`, typed check registry, typed command result refinements |
| T2 PostEvent/allGranted/clamp | Inherit unchanged; profile must not hide required PostEvent for CGEvent capabilities |
| T3 Logic chain | Inherit; add profile/capability mapping for Logic-running and version support |
| T4 install chain | Inherit; replace remediation text with source-aware remediation and static marker/semver |
| T5 MCP chain | Redefine optionality through ClientProfile; relative command resolution becomes 3-state path resolution |
| T6 channels/deps | Redefine through DoctorProfile and intentional skip decisions |
| T7 launch/TCC context | Extend host classification to Cursor, VS Code, Windsurf, Zed, custom |
| T8 CLI UX | Extend renderer to v4 next-action mode; JSON independent from renderer |
| T9 docs/E2E | Extend docs with profile/client/capability examples and v4 live E2E |

## 7. Ticket Board

Execution tickets live under `docs/tickets/doctor-v4/`:

- T1: Safety/remediation quick fix.
- T2: `skip_reason` additive field.
- T3: relative/path-dependent registration resolver.
- T4: profile-aware manual channel checks.
- T5: manual validation decision store.
- T6: client profile and generic MCP client readiness.
- T7: capability readiness JSON.
- T8: typed check registry.
- T9: evidence builder/privacy hardening.
- T10: static version marker and SemanticVersion parser.

## 8. Testing Strategy

Every ticket starts red:

- Unit tests for new pure models.
- Contract tests for JSON additivity.
- Renderer tests for human/JSON independence.
- Privacy tests scanning doctor JSON for raw temp paths, env keys, tokens, and unredacted stderr.
- Live E2E at the end with at least `core`, `full`, and one non-Claude client profile.

## 9. Rollout

Land as sequential PRs. T1 can land first because it is low-risk remediation correctness. T2/T8/T9 are foundation. T3/T4/T5/T6/T7/T10 build on the foundation. Final release gate is full `swift test --no-parallel`, release build, and live doctor v4 E2E.

## 10. Open Questions — all DECIDED (CTO, 2026-07-07)

- ~~`auto` profile default~~ → **infer, else `core`** (conservative: never claim broader readiness than detected intent; inference basis recorded in evidence).
- ~~`custom` client config path~~ → **optional `--client-config <path>` flag**; without it, `custom` runs generic guidance (registration checks informational with `skip_reason:client_not_selected`) — never a hard requirement.
- ~~intentional skip expiry~~ → **persist until revoked**, stored with timestamp + optional note (`--revoke-channel` covers both decision kinds, T5); no silent expiry — an expiring decision would re-surface noise the operator already dismissed.
- ~~schema string~~ → **bump to `logic_pro_mcp_doctor.v4`**, strict v3-superset (§3, decided with rationale).
