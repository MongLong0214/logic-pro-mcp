# Setup

Minimal install and Logic Pro integration guide for Logic Pro MCP v3.18.0.

## Requirements

- macOS 14+
- Logic Pro — **latest release prioritized (currently 12.3)**; works down to the 12.0.1 floor on a best-effort basis. Supported Mac variant: desktop **Logic Pro** (`com.apple.logic10`, `/Applications/Logic Pro.app`). Apple Creator Studio **Logic Pro Creator Studio** (`com.apple.mobilelogic`, `/Applications/Logic Pro Creator Studio.app`) is recognised, not supported; the two use different process names for System Events automation. Desktop **Logic Pro** is the only variant the release qualification matrix covers (`shipVariants = [.desktop]`), and the only one this release supports. Without `LOGIC_PRO_BUNDLE_ID` the server can still select Creator Studio: it targets the frontmost Logic; failing that a running one, then an installed one, desktop first in both. So a Creator Studio that is frontmost, or is the only Logic running, becomes the target, with no qualification evidence behind it. Set `LOGIC_PRO_BUNDLE_ID=com.apple.logic10` to keep the server on desktop Logic Pro.
- Claude Code, Claude Desktop, Cursor, or another MCP client
- Homebrew, or Xcode/Swift if building from source

## Install

Recommended:

```bash
brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
brew trust monglong0214/logic-pro-mcp   # Homebrew 6.0+ only
brew install logic-pro-mcp
```

Source build:

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
```

Pinned shell installer:

```bash
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.18.0/Scripts/install.sh -o install.sh
# inspect install.sh, then copy pins from the v3.18.0 release:
LOGIC_PRO_MCP_SHA256=<sha256 for LogicProMCP-macOS-universal.tar.gz entry> LOGIC_PRO_MCP_TEAM_ID=<team_id> bash install.sh
```

The installer trust model is in [SECURITY.md](../SECURITY.md#installer-trust-model).

## Register MCP Client

Claude Code:

```bash
claude mcp add --scope user logic-pro -- LogicProMCP
```

Source build:

```bash
claude mcp add --scope user logic-pro -- /absolute/path/to/.build/release/LogicProMCP
```

### Multiple server launches

Claude Desktop can launch the same configured MCP server separately for chat and Code/Cowork. Only one process reserves the virtual MIDI port group (CoreMIDI, MCU, Key Commands and Scripter); other processes keep MIDI channels degraded instead of taking a subset of the ports. Check `logic_system health` for ownership failures. A process that did not acquire the group does not automatically take over later: stop competing launches and restart the intended server. Normal CoreMIDI startup/census failures can still degrade the owner. No additional Logic control surface or permission change is needed to resolve a duplicate launch. See [Troubleshooting](TROUBLESHOOTING.md#duplicate-server-launches-and-midi-ownership).

## macOS Permissions

Open **System Settings -> Privacy & Security**:

1. **Accessibility**: enable the app that launches `LogicProMCP` (Claude Code, Terminal, Cursor, or Claude Desktop).
2. **Automation**: allow that app to control **Logic Pro** and **System Events**.

If you use **Apple Creator Studio** Logic Pro (`com.apple.mobilelogic`), grant Automation separately from desktop Logic Pro (`com.apple.logic10`). macOS treats them as distinct apps even though both appear as "Logic Pro".

`--check-permissions` and doctor readiness cover Accessibility, Automation for Logic Pro, Automation for System Events, and trusted PostEvent access. PostEvent is granted through the same launcher-app Accessibility control, but is reported separately because CGEvent fallback paths need it.

Verify:

```bash
LogicProMCP --check-permissions
LogicProMCP doctor
```

### Forcing a Logic Pro variant

Without an override the server targets the frontmost Logic; failing that a running one, then an installed one, desktop first in both, so a frontmost or only-running Creator Studio becomes the target. To pin the desktop variant:

```bash
LOGIC_PRO_BUNDLE_ID=com.apple.logic10 LogicProMCP
```

Valid values: `com.apple.logic10` (desktop) and `com.apple.mobilelogic` (Creator Studio). Only desktop Logic Pro is qualified for this release. Forcing `com.apple.mobilelogic` points the server at Creator Studio anyway, with no qualification evidence behind it, and on a machine where Creator Studio is the only Logic installed, `LogicProMCP doctor` fails `logic.installation` with reason `unshipped_variant_only`.

## Logic Pro Setup

### MCU Control Surface

Required for MCU-backed mixer control. Until this is done Logic DISCARDS every MCU message the
server sends, and `system health` still reports the MCU channel ready — that flag is set by any
inbound traffic rather than by a handshake, so a missing control surface looks like a working one
until an operation fails with `channels_exhausted`.

The server can do it for you, once per machine:

```
logic_system { "command": "setup_control_surface", "params": { "consent": "true" } }
```

It refuses without `consent` because it writes to your Logic configuration. It declines rather than
replaces if some OTHER control surface is already installed, and it reports success only after Logic
has actually sent MCU feedback back — the port fields reading the right name is not proof.

The binding lives in Logic's configuration, not in the server: it survives the server stopping and
starting, so this is one-time rather than per-session.

Expected health after registration:

```json
{ "connected": true, "registered_as_device": true, "feedback_stale": false }
```

### MIDI Key Commands

Reference only. Logic 12.2+ does not reliably import the legacy `.plist`, and the server cannot
establish or read back the corresponding Logic bindings programmatically.

The following mapped keycmd-only/channel-only paths therefore report `unattended_unavailable`:

- `edit.delete`
- `edit.duplicate`
- `edit.normalize`
- `nav.goto_marker`
- `transport.capture_recording`
- `view.toggle_inspector`
- `view.toggle_step_editor`

`edit.delete`, `view.toggle_inspector` and `view.toggle_step_editor` are here because Apple's U.S.
key-command preset binds no key to their functions, so the CGEvent fallback does not guess one.
`edit.quantize` instead uses the Region inspector's Accessibility grid pop-up. Show the inspector
and select the intended regions. Q and MIDI Learn are not fallbacks: they apply Logic's current
grid rather than carrying the requested value. An unreadable selection aggregate or incomplete
region census is refused without opening the pop-up; live availability of this stricter path
and all-locale qualification remain unverified.

Most normal tool calls route through Accessibility, AppleScript, MCU, CoreMIDI, or CGEvent. Raw
MIDI bypass calls may still use the virtual port when its transport is ready; mapped Logic commands
do not route through this unverified path.

### Scripter

The bundled file is retained as a legacy reference. Verified plugin apply-back uses `logic_plugins`
instead. Because insert setup and parameter outcomes have no programmatic readback, the Scripter
mapped channel reports `unattended_unavailable`; a stored operator assertion cannot make it ready.

## Verify

```bash
LogicProMCP doctor --json
swift test --filter VersionConsistencyTests
```

From your MCP client:

> Check Logic Pro MCP health and list ready channels.

Fully configured hosts should show Accessibility, AppleScript, CoreMIDI, MCU, MIDIKeyCommands, Scripter, and CGEvent as available. Skipping Key Commands or Scripter is valid when you do not need those paths.

<a id="setup-doctor"></a>
## Doctor (`logic_pro_mcp_doctor.v5`)

`doctor` is read-only and safe to run before starting the server.

```bash
LogicProMCP doctor [--json] [--profile core|mixer|keycmd|legacy-scripter|full] [--client claude-code|claude-desktop|cursor|vscode|terminal|custom] [--strict] [--check-updates] [--verbose|--quiet]
```

Flags:

| Flag | Effect |
|------|--------|
| (none) | Human report: an outcome headline, a `summary:` counts line, and one line per check. |
| `--verbose` | Adds each check's evidence and `duration_ms`. |
| `--quiet` | Headline + summary + failing/non-pass checks only. |
| `--json` | Machine report. Identical bytes regardless of `--verbose`/`--quiet`/color. |
| `--profile core\|mixer\|keycmd\|legacy-scripter\|full` | Selects the intent-aware readiness profile. Omit to infer the core profile from launch context; legacy manual-channel records never expand it. |
| `--client claude-code\|claude-desktop\|cursor\|vscode\|terminal\|custom` | Selects the MCP client profile for registration checks. Omit to infer from launch context/config. |
| `--check-updates` | Opt-in: adds an `updates.latest_release` check (unauthenticated GitHub releases read). The default run never touches the network. |
| `--strict` | Scripted exit codes: `ok=0`, `failed=1`, `manual_action_required=2`, `degraded=3`. |

Color and unicode symbols are emitted only when stdout is a TTY and `NO_COLOR` is unset; otherwise output is plain ASCII (`[pass]`-style), so pipes and CI logs stay clean.

The `v5` report retains all `v4` fields. It changes one operation-readiness enum value: `capabilities.<id>.operations[].readiness` now emits `prerequisite_unavailable` instead of `manual_setup_required` when a route has no autonomous prerequisite-acquisition path. This is a semantic enum migration, so strict-enum consumers must accept the v5 token before decoding v5 reports. Older v1/v2/v3 field subsets still decode because their fields and values are unchanged. Consumers should prefix-match `logic_pro_mcp_doctor.`, then dispatch on the parsed version for enum migrations. Default exit code is unchanged: `failed` → 1, otherwise 0.

Strict exit codes `2` and `3` are doctor status codes, not usage errors, and intentionally sit below the `sysexits.h` 64-78 range. Required capability-gap skips still degrade to code `3`; optional skips such as an absent non-selected client config remain counted as skipped but do not degrade the aggregate status. For a boolean gate, test non-zero; for routing, branch on the exact code. With `set -e`, capture the code before branching:

```bash
set +e
LogicProMCP doctor --strict --json > doctor.json
rc=$?
set -e

case "$rc" in
  0) echo "doctor ok" ;;
  1) echo "doctor failed"; exit 1 ;;
  2) echo "manual action required"; exit 1 ;;
  3) echo "doctor degraded"; exit 1 ;;
  *) echo "unexpected doctor exit: $rc"; exit "$rc" ;;
esac
```

Consumer compatibility notes:

| Consumer type | Upgrade note |
|---------------|--------------|
| Strict v4 operation-readiness enums | Add `prerequisite_unavailable`, remove assumptions that `manual_setup_required` asks a person to act, and select that decoder for `logic_pro_mcp_doctor.v5`. |
| Exact 13-check arrays | Switch to ID-based lookup; Doctor v4 emits 26 base checks and 27 with `--check-updates`. |
| Strict schema validators | Allow additive top-level `fix_plan`, profile/client/capability fields, per-check `optional` / `blocked_by` / `skip_reason`, and timing. |
| Skipped-count alarms | Expect a higher baseline; v4 reports diagnostic-capability gaps instead of hiding them. Optional skips do not imply degraded status. |
| UIs unaware of `fix_plan` | Continue rendering checks normally; `fix_plan` only orders the next actions. |
| Readiness dashboards | Prefer `capabilities.<id>.status` for profile-aware readiness over hand-rolled check groups. |

`fix_plan` contains only non-pass checks that have a concrete remediation. Terminal and unresolved checks without a concrete remediation are excluded from that action list but remain visible in `headline` and `checks`. A `fail` without remediation uses `Terminal outcome`; a `warn` or `manual` result without remediation uses `Unresolved outcome`. `Next action` is reserved for a result whose remediation can actually be carried out.

## Doctor Remediation Anchors

These anchors are intentionally compact because `doctor --json` links to them.

<a id="doctor-binarypath"></a>
### `binary.path`
Reports whether the running process resolved its binary from `argv0` or PATH. An unresolved binary is a terminal unavailable state for this read-only inspection; doctor emits no mutation or retry request.

<a id="doctor-binaryexecutable"></a>
### `binary.executable`
Reports whether the resolved LogicProMCP binary is executable. A resolved binary without executable permission is a terminal unavailable state for this read-only inspection; doctor emits no mutation or retry request.

<a id="doctor-installsource"></a>
### `install.source`
Prefer the Homebrew install. For source builds, launch `.build/release/LogicProMCP` by absolute path.

<a id="doctor-installbinary-inventory"></a>
### `install.binary_inventory`
Reinstall or upgrade when a canonical installed binary has a stale static version. Homebrew installs use `brew upgrade logic-pro-mcp`; source builds use `git pull && swift build -c release`.

<a id="doctor-installshare-dir"></a>
### `install.share_dir`
When helper assets are missing, Homebrew installs use `brew reinstall logic-pro-mcp`; source builds restore the checkout and rebuild; release installs replace the pinned package. Unknown/custom installs should follow this section rather than a package-manager command.

<a id="doctor-releasesignature"></a>
### `release.signature`
Reports whether the resolved LogicProMCP binary's signature verifies. A failed or unavailable verification is a terminal unavailable state for this read-only inspection; doctor emits no mutation or retry request.

<a id="doctor-releasequarantine"></a>
### `release.quarantine`
Reports the observed quarantine state of the resolved LogicProMCP binary. A present quarantine attribute is a terminal unavailable state for this read-only inspection; doctor emits no mutation or retry request.

<a id="doctor-mcpclaude-code-registration"></a>
### `mcp.claude_code_registration`
Reports whether the selected Claude Code client already has an exact LogicProMCP registration. Missing, partial, mismatched, or unreadable registration is a terminal unavailable state for this read-only run; doctor emits no command, config-edit, or retry request.

<a id="doctor-mcpregistration-target"></a>
### `mcp.registration_target`
Reports whether the selected registration target resolves to a present regular executable. When a share directory is configured, doctor checks that it exists; when the installed version is readable, doctor compares it with the running version. A detected invalid target, missing configured share directory, or readable version mismatch is a terminal unavailable state for this read-only run; doctor emits no remediation action or continuation.

<a id="doctor-mcpclaude-desktop-registration"></a>
### `mcp.claude_desktop_registration`
This check is skipped when Claude Desktop is not the selected client. When Claude Desktop is selected, an absent, unreadable, partial, mismatched, or missing registration is a terminal unavailable state; doctor emits no config-edit or retry request.

<a id="doctor-permissionsaccessibility"></a>
### `permissions.accessibility`
Reports the launcher app's current Accessibility authorization. A non-pass result is a terminal observation for this unattended run; doctor emits no remediation for this check.

<a id="doctor-permissionsautomation-logic-pro"></a>
### `permissions.automation_logic_pro`
Reports the responsible process's current Automation authorization for Logic Pro. Denied, consent-required, and unverifiable results are terminal observations for this unattended run and carry no remediation.

<a id="doctor-permissionsautomation-system-events"></a>
### `permissions.automation_system_events`
Reports the responsible process's current Automation authorization for **System Events**. This is a separate TCC target from Logic Pro automation and is required by MIDI import / tempo-dialog / project-state paths (#188). Denied, consent-required, and unverifiable results are terminal observations for this unattended run and carry no remediation.

<a id="doctor-permissionspost-event-access"></a>
### `permissions.post_event_access`
Reports whether the responsible launcher can use the native PostEvent path required by CGEvent operations. A non-pass result is a terminal observation for this unattended run; doctor emits no remediation for this check.

<a id="doctor-permissionslaunch-context"></a>
### `permissions.launch_context`
Identifies which responsible process context the permission observations describe. Unknown context remains an informational observation and does not create a continuation action.

<a id="doctor-permissionstcc-cross-context"></a>
### `permissions.tcc_cross_context`
Cross-context TCC enrichment. If unavailable, the live permission probes remain authoritative; a non-pass enrichment result does not create a continuation action.

<a id="doctor-systemmacos-version"></a>
### `system.macos_version`
Logic Pro MCP requires macOS 14 or newer. A detected version below that floor is a terminal unavailable state: the check reports the measured version without requesting an upgrade or adding a continuation to `fix_plan`. An unreadable OS version remains a skipped diagnostic.

<a id="doctor-updateslatest-release"></a>
### `updates.latest_release`
Shown only with `doctor --check-updates`. If a newer release exists, Homebrew installs use `brew upgrade logic-pro-mcp`, source builds pull and rebuild, and release installs replace the pinned asset. Unknown/custom installs receive this docs link instead of a package-manager command. A `skipped` status means the check could not reach the release source (offline / unavailable) — it never blocks.

<a id="doctor-logicapplication-state"></a>
### `logic.application_state`
A stopped application or missing visible project window is a terminal unavailable state for this
read-only check. It reports zero human-intervention requests and does not ask for a launch, focus,
project creation, or retry.

<a id="doctor-logicinstallation"></a>
### `logic.installation`
No supported Logic Pro installation, or a Creator-Studio-only installation this release does not ship for, is a terminal unavailable state. The check preserves the observed path and variant reason without requesting an installation or adding an action to `fix_plan`. An existing bundle whose version cannot be read remains a skipped diagnostic.

<a id="doctor-logicversion-support"></a>
### `logic.version_support`
A detected Logic Pro version below the 12.0.1 support floor is a terminal unavailable state: the check preserves the measured version without requesting a version change or adding a continuation to `fix_plan`. Logic Pro 12.3 is the latest validated target; other versions at or above the floor remain informational warnings.

<a id="doctor-logicblocking-dialog"></a>
### `logic.blocking_dialog`
A measured blocking modal is a terminal unavailable state for this read-only check. The diagnostic
retains bounded dialog identity but suppresses the observed dismissal instruction and exposes no
operator action in `fix_plan`.

<a id="doctor-channelsmanual-validation"></a>
### `channels.manual_validation`
Required send-only mapped channels terminate as unavailable because setup and outcome readback are
not programmatically verified. Legacy assertion/skip records do not qualify readiness and no
operator action appears in `fix_plan`.

<a id="doctor-channelskeycmd-reference"></a>
### `channels.keycmd_reference`
The bundled mapping may be present as a reference, but its presence or absence cannot qualify
mapped Logic execution. A missing reference is reported without a staging command.

<a id="doctor-channelsmcu-wiring-hint"></a>
### `channels.mcu_wiring_hint`
The doctor passes this check only when the controller-assignment data confirms the LogicProMCP MCU
port. A missing reference or unreadable assignment file is a terminal unsuccessful outcome for the
full profile: MCU-only operations remain unavailable, no setup is inferred, and no operator action is
placed in `fix_plan`.

<a id="doctor-dependenciesclick-fallback"></a>
### `dependencies.click_fallback`
The server's only synthetic-click path is the native CGEvent post. When PostEvent access is denied,
this check is a terminal unsuccessful outcome and adds no operator action to `fix_plan`. The external
`cliclick` fallback remains retired; a present tool is reported as informational evidence only and
cannot turn the check into a pass.

## Lifecycle Anchors

`LogicProMCP lifecycle <install|update|uninstall> [--json]` prints a read-only lifecycle plan and exits without starting the server — e.g. `LogicProMCP lifecycle install --json`. (The bare `LogicProMCP install --dry-run --json` form produces the same plan.) These anchors are stable remediation targets.

<a id="lifecycle-binaryinstall"></a>
### `binary.install`
Install using Homebrew or the pinned release installer.

<a id="lifecycle-binaryupdate"></a>
### `binary.update`
Use `brew update && brew upgrade logic-pro-mcp`, or reinstall from the target release.

<a id="lifecycle-binaryremove"></a>
### `binary.remove`
Use `brew uninstall logic-pro-mcp`, or remove the manually installed binary.

<a id="lifecycle-mcpregister"></a>
### `mcp.register`
The installer owns requested Claude registration. A missing CLI or failed registration terminates
the installer unsuccessfully without a manual fallback.

<a id="lifecycle-mcpunregister"></a>
### `mcp.unregister`
Remove the `logic-pro` server entry from your MCP client config.

<a id="lifecycle-keycmdsstage"></a>
### `keycmds.stage`
The bundled key command asset is reference-only and cannot qualify mapped Logic execution.

<a id="lifecycle-keycmdsremove"></a>
### `keycmds.remove`
The filesystem reference can be removed automatically; Logic-side binding state is not claimed.

<a id="lifecycle-scripterinsert"></a>
### `scripter.insert`
Scripter insert setup is `unattended_unavailable`; the lifecycle plan exposes no operator action.

<a id="lifecycle-scripterremove"></a>
### `scripter.remove`
Scripter removal cannot be programmatically verified and remains an explicit terminal residual.

<a id="lifecycle-launchagentinstall"></a>
### `launch_agent.install`
Install a launch agent only when your MCP client requires one; normal stdio use does not.

<a id="lifecycle-launchagentremove"></a>
### `launch_agent.remove`
The source-checkout uninstaller probes the exact current-user service
`gui/$UID/com.logicpro.mcp`, boots out only that service, verifies its absence with a bounded
readback, removes only `~/Library/LaunchAgents/com.logicpro.mcp.plist`, and verifies the path is
absent. It terminates before deleting the binary or plist when service ownership or removal cannot
be established; it never uses process-wide termination. The current release archive and Homebrew
pkgshare do not ship `uninstall.sh` with its required `install-common.sh`, so installed-distribution
uninstall ownership remains unavailable.

<a id="lifecycle-approvalsremove"></a>
### `approvals.remove`
The uninstaller removes the legacy compatibility-record store and its `.lock` sidecar. Removing or
recreating these records does not change unattended readiness.

## Community

Stuck on setup? Join the official Logic Pro MCP Discord for real-time help: [https://discord.gg/4M3s79DBzz](https://discord.gg/4M3s79DBzz). For reproducible bugs, open a [GitHub Issue](https://github.com/MongLong0214/logic-pro-mcp/issues).
