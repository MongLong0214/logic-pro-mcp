# T6: Channels-Deps — N11 keycmd_reference, N12 mcu_wiring_hint, dependencies.click_fallback

**PRD Ref**: PRD-doctor-v3 > §4.3 N11/N12/click_fallback, §4.4 D11 (optional-channel framing), §4.5 #3-4 (C6), US-1/AC-1.1, US-3/AC-3.3, E8/E10
**Priority**: P1 (High)
**Size**: M
**Status**: Todo
**Depends On**: T2

---

## 1. Objective

Add the channel-staging + click-path diagnostics: `channels.keycmd_reference` (N11, keycmd preset existence), `channels.mcu_wiring_hint` (N12, positive-only `strings` scan of the `.cs` preferences for our MCU port literal), and the reduced-scope `dependencies.click_fallback` (N-click, cliclick presence + PostEvent-aware escalation). All three carry optional-channel framing (D11) so an unused channel reads as an optional next-step, never a hard fault.

## 2. Acceptance Criteria

- [ ] AC-1 (N11): existence of `SetupLifecycle.keyCommandsPresetPath` (`~/Music/Audio Music Apps/Key Commands/LogicProMCP-KeyCommands.plist`, SetupLifecycle.swift:509-513). `pass` if present ("staged; MIDI-Learn is a separate manual step — proves the installer ran, not that Learn is done"); `manual` if absent (live: dir empty). Honesty: proves staging only, never the MIDI-Learn bindings. evidence `{preset_staged}`; remediation `command` (`install-keycmds.sh`) + SETUP anchor.
- [ ] AC-2 (N12, C6): positive-only `strings` scan (exec-array `strings <cs-file>`, substring match in Swift — **no shell pipe**) of `~/Library/Preferences/com.apple.logic.pro.cs` for the exact literal `LogicProMCP-MCU-Internal`. `pass` on a hit ("past binding evidence"); `manual` on a miss OR if the `.cs` file is absent ("cannot confirm — MCU-only ops verified live via health `mcu.connected`"). A miss is **not** `fail` (positive-only heuristic; live: 0 occurrences). **Never** `plutil`/structural parse (the file is FORM/IFF `MROF`). evidence `{cs_file_present, mcu_port_reference_found}`; remediation `docs`.
- [ ] AC-3 (click_fallback, reduced scope): `isExecutableFile` on `["/opt/homebrew/bin/cliclick","/usr/local/bin/cliclick"]`. `pass` by default (native CGEvent click is primary). Escalates to `warn` ("no working click path") **only** when PostEvent is denied (N1) **AND** no cliclick candidate executable. No independent `fail`. evidence `{cliclick:"present"|"absent", native_click:"available"|"denied"}`; remediation `docs`. **Do not resurrect** the #210/#211 cliclick-trust resolver (not on this branch).
- [ ] AC-4 (optional-channel framing, D11/R11): N11/N12 summaries + remediation name the dependent op family (N12: MCU-only `set_master_volume`/`set_output_volume`/`set_send`/`track.set_automation`) and state the check is **ignorable if those ops are unused**; both render under the `[manual]` fix-plan tier (T8).
- [ ] AC-5 (positions + array +3): `channels.keycmd_reference` + `channels.mcu_wiring_hint` + `dependencies.click_fallback` inserted **after** `channels.manual_validation` (and before the opt-in `updates.latest_release`). Array grows by 3; counts bumped. `dependencies.click_fallback` is the first check to actually populate the reserved `dependencies` category (category(forDomain:) SetupDoctor.swift:928-929).

## 3. TDD Spec (Red Phase)

> New fixture seams: keycmd-preset-exists `Bool` (default present), a cs-file `strings` provider (default: file present + contains the MCU literal), and cliclick candidate `isExecutableFile` (reuse the existing seam; default present). click_fallback reads N1's result via `status(of:"permissions.post_event_access",in:checks)`.
> **dead-`#expect` 금지** (R6): concrete statuses; evidence substrings via force-unwrap.

### 3.1 Test Cases

| # | Test Name | Type | Invariant fixed | Expected |
|---|-----------|------|-----------------|----------|
| 1 | `test_t6_n11_pass_preset_staged` | Unit | AC-1 | preset present ⇒ `.pass`; evidence `preset_staged=="true"` |
| 2 | `test_t6_n11_manual_absent` | Unit | AC-1 (live) | preset absent ⇒ `.manual`; remediation names `install-keycmds.sh` |
| 3 | `test_t6_n11_summary_optional_framing` | Unit | AC-4 | `manual` summary states it's ignorable if the keycmd channel is unused |
| 4 | `test_t6_n12_pass_on_hit` | Unit | AC-2 | cs `strings` contains `LogicProMCP-MCU-Internal` ⇒ `.pass`; `mcu_port_reference_found=="true"` |
| 5 | `test_t6_n12_manual_on_miss` | Unit | AC-2 (live) | cs present, literal absent ⇒ `.manual` (not `.fail`); `mcu_port_reference_found=="false"` |
| 6 | `test_t6_n12_manual_when_cs_absent` | Unit | E8 | cs file absent ⇒ `.manual` (same guidance), `cs_file_present=="false"`; never `.fail` |
| 7 | `test_t6_n12_never_plutil` | Unit | C6 | spy `runCommand`: `.cs` path is never passed to `/usr/bin/plutil`; only `/usr/bin/strings` |
| 8 | `test_t6_n12_summary_names_mcu_ops` | Unit | AC-4 | `manual` summary lists the MCU-only op family + "ignorable if unused" |
| 9 | `test_t6_click_pass_by_default` | Unit | AC-3 | PostEvent granted (native available) ⇒ `.pass` regardless of cliclick |
| 10 | `test_t6_click_pass_post_event_denied_but_cliclick_present` | Unit | AC-3 | PostEvent denied but a cliclick candidate executable ⇒ `.pass` (fallback exists) |
| 11 | `test_t6_click_warn_no_path` | Unit | E10 / AC-3.3 | PostEvent denied AND no cliclick ⇒ `.warn` "no working click path" |
| 12 | `test_t6_click_category_dependencies` | Unit | AC-5 | `dependencies.click_fallback.category == .dependencies` |
| 13 | `test_t6_array_grows_by_three_channels_deps` | Contract | AC-5 order | exact-id array places the 3 checks after `channels.manual_validation` |

### 3.2 Test File Location
- `Tests/LogicProMCPTests/SetupDoctorEnterpriseTests.swift` — cases 1–12.
- `Tests/LogicProMCPTests/SetupDoctorTests.swift` — array update (case 13).

### 3.3 Mock / Setup Required
- `SetupDoctor.Runtime` seams (default-valued `var`): `keycmdPresetExists: () -> Bool` (default true; `.production` = `fileExists(SetupLifecycle keyCommandsPresetPath)` — note the path helper is `private static` in SetupLifecycle.swift:509, so expose a small accessor or replicate the path constant in the seam wiring), `csFileStrings: () -> (present: Bool, output: String)?` (default present + contains literal; `.production` = `strings <cs-path>` via `runCommand`). cliclick reuse `isExecutableFile`.
- click_fallback reads N1 via `status(of:"permissions.post_event_access",in:checks)` — N1 precedes it (added T2, position 15 vs click at 26).

## 4. Implementation Guide

### 4.1 Files to Modify
| File | Change | Description |
|------|--------|-------------|
| `Sources/LogicProMCP/Utilities/SetupLifecycle.swift` | Modify (minimal) | expose `keyCommandsPresetPath(home:)` (currently `private static` :509) as `static` (internal) so the doctor seam can resolve it without duplicating the literal — OR add a tiny public path constant. Prefer the smaller change. |
| `Sources/LogicProMCP/Utilities/SetupDoctor.swift` | Modify | `Runtime` +seams; `keycmdReferenceCheck`, `mcuWiringHintCheck`, `clickFallbackCheck`; insert 3 `timed { }` appends after `manualValidationCheck` (generate :255); +3 anchors |
| Tests (2 files) | Modify | N11/N12/click + array/count |

### 4.2 Implementation Steps (Green Phase)
1. Surface the keycmd preset path (SetupLifecycle) with the minimal visibility change; wire the `keycmdPresetExists` seam in `.production`.
2. `keycmdReferenceCheck` (N11): `pass`/`manual` per AC-1; optional-channel framing in summary.
3. `mcuWiringHintCheck` (N12): call `runtime.csFileStrings()`; if `nil`/absent ⇒ `manual` (cs absent guidance); else Swift `.contains("LogicProMCP-MCU-Internal")` ⇒ `pass`/`manual`. **No `plutil`.** Summary names the MCU-only op family + "ignorable if unused".
4. `clickFallbackCheck` (N-click): `cliclickPresent = isExecutableFile("/opt/homebrew/bin/cliclick") || isExecutableFile("/usr/local/bin/cliclick")`; `postEventDenied = status(of:"permissions.post_event_access",in:checks) == .fail`; `warn` iff `postEventDenied && !cliclickPresent` else `pass`. domain `dependencies`.
5. Insert 3 appends after `manualValidationCheck` (:255). Add anchors, bump array + count.

### 4.3 Refactor Phase
- If both N7 (T4) and N12 use `strings`, ensure both go through the `DoctorTool`-allowlisted `/usr/bin/strings` path (T1) — no second spawn path.

## 5. Edge Cases
- E8 cs file absent ⇒ N12 `manual` (case 6); E10 PostEvent denied + no cliclick ⇒ click `warn` (case 11).

## 6. Review Checklist
- [ ] Red → Green → Refactor green
- [ ] N12 miss is `manual`, never `fail` (positive-only heuristic)
- [ ] `.cs` never `plutil`-parsed (C6, case 7)
- [ ] click_fallback has no independent `fail`; escalates only on the two-condition AND
- [ ] optional-channel framing present on N11/N12 (D11)
- [ ] `dependencies` category now reachable (case 12)
- [ ] array/count +3; no dead-`#expect`

## 7. Out of Scope (explicit)
- **cliclick-trust resolver (#210/#211)** — explicitly NOT resurrected (native CGEvent backend replaced it on this branch).
- **`.logikcs` / MCU `.cs` structural parse** — NG4/C6. Positive-only `strings` only.
- **health `mcu.connected`** — that live signal is the runtime counterpart; doctor does not probe it (NG1/NG3).
- **`permissions.post_event_access` (N1)** is **T2**; click_fallback only reads its computed status.
