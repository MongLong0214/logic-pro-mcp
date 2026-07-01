# T2 — Three Non-Network Checks (+ System Events probe tri-state)

**Size**: M
**Depends on**: T1
**PRD ACs**: G1, G2, AC-1.1–1.6, AC-2.1–2.5, E1–E5, E12, E13
**Files**: `Sources/LogicProMCP/Utilities/SetupDoctor.swift`, `Sources/LogicProMCP/Utilities/PermissionChecker.swift`,
`Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift`, `Tests/LogicProMCPTests/PermissionCheckerTests.swift` (if exists, else add)

## Goal
Add `permissions.automation_system_events` and `system.macos_version`, and widen the
System Events probe seam so a could-not-run probe is `.notVerifiable` (not "denied").

## Design
### PermissionChecker probe tri-state (NG1 exception)
- Change the System Events probe seam from `runSystemEventsAutomationProbe: () -> Bool` to a tri-state
  result. Concretely: introduce `enum SystemEventsProbeResult { granted, denied, couldNotVerify }` (or reuse
  `CheckState`), and have `runSystemEventsAutomationProbeViaShell` map:
  - `BoundedProcessRunner.completed`, exit 0, stdout == "System Events" → `granted`
  - `.completed`, exit != 0 (TCC denial, e.g. -1743) → `denied` (→ `.notGranted`)
  - `.timedOut` / `.spawnFailed` / `.completed` with unexpected stdout → `couldNotVerify` (→ `.notVerifiable`)
- `checkSystemEventsAutomationState` returns `.granted` / `.notGranted` / `.notVerifiable` accordingly.
- `allGranted` and `--check-permissions` **exit codes unchanged** (`.notVerifiable.isGranted == false`).
  Only the `PermissionStatus.summary` text for the could-not-verify case becomes honest ("could not verify").
- Keep the Logic Pro automation probe untouched.

### doctor checks
- `permissions.automation_system_events` (category permissions): maps `systemEventsAutomationState` —
  granted→pass; notGranted→fail (system_settings "Automation → System Events"); notVerifiable→manual.
- `system.macos_version` (category installation) via `Runtime.macOSVersion: () -> OperatingSystemVersion?`:
  - nil → skipped (reason: unreadable) (E12).
  - major >= 14 → pass, evidence `version` (also future 15/26 → pass, no upper bound) (AC-2.4).
  - major < 14 → fail (AC-2.5).
- Insert checks in `generate()` in a sensible stable order; **update the `ids ==` contract test list**.
- Add `remediationAnchorsByCheckID` entries + `defaultRemediationValue` branch for System Events.

## TDD — Red first
1. `test_system_events_pass`: granted → pass.
2. `test_system_events_fail_and_remediation`: notGranted → fail + non-empty system_settings remediation.
3. `test_system_events_manual_on_notVerifiable` (AC-1.4/E1): inject `.notVerifiable` → manual.
4. `test_system_events_independent_of_logic_running` (AC-1.6/E13): logicRunning=false, systemEvents granted →
   logic.automation manual AND system_events pass (independent).
5. `test_probe_timeout_maps_to_notVerifiable`: inject a PermissionChecker runtime whose System Events probe
   times out / spawn-fails → `checkSystemEventsAutomationState == .notVerifiable`. (PermissionChecker unit test.)
6. `test_probe_denial_maps_to_notGranted`: probe completes exit!=0 → `.notGranted`.
7. `test_macos_pass_ge_14` / `test_macos_pass_future` / `test_macos_fail_lt_14` / `test_macos_skipped_unreadable`.
8. `test_check_id_list_extended`: the `ids ==` contract now includes the active new ids in their stable positions.
9. `test_allGranted_monotonicity_with_systemEvents` (AC-1.5): systemEvents notGranted → report status failed (not ok).

## Acceptance
- 13 checks (14 with `--check-updates`). All green `swift test --no-parallel`.
- `--check-permissions` exit codes unchanged (regression: existing PermissionChecker tests pass).
