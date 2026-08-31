# Setup

Minimal install and Logic Pro integration guide for Logic Pro MCP v3.15.0.

## Requirements

- macOS 14+
- Logic Pro — **latest release prioritized (currently 12.3)**; works down to the 12.0.1 floor on a best-effort basis. Supported Mac variants: desktop **Logic Pro** (`com.apple.logic10`, `/Applications/Logic Pro.app`) and Apple Creator Studio **Logic Pro Creator Studio** (`com.apple.mobilelogic`, `/Applications/Logic Pro Creator Studio.app`). They use different process names for System Events automation.
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
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.15.0/Scripts/install.sh -o install.sh
# inspect install.sh, then copy pins from the v3.15.0 release:
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

When both desktop Logic Pro and Creator Studio Logic Pro are installed, the server auto-detects the frontmost running instance, otherwise prefers the desktop install. To force a specific variant:

```bash
LOGIC_PRO_BUNDLE_ID=com.apple.mobilelogic LogicProMCP
```

Valid values: `com.apple.logic10` (desktop), `com.apple.mobilelogic` (Creator Studio).

## Logic Pro Setup

### MCU Control Surface

Required for MCU-backed mixer control.

1. Launch Logic Pro and open a project.
2. Open **Logic Pro -> Control Surfaces -> Setup...**.
3. Choose **New -> Install...**.
4. Add **Mackie Designs -> Mackie Control**.
5. Select the device card.
6. Set both input and output ports to `LogicProMCP-MCU-Internal`.
7. Close the setup window.

Expected health after registration:

```json
{ "connected": true, "registered_as_device": true, "feedback_stale": false }
```

### MIDI Key Commands

Optional. Logic 12.2+ does not reliably import the legacy `.plist`; use it only as a CC mapping reference for manual MIDI Learn.

Manual binding is only needed for remaining keycmd-only/channel-only paths:

- `edit.duplicate`
- `edit.normalize`
- `nav.goto_marker`
- `transport.capture_recording`

Most normal tool calls route through Accessibility, AppleScript, MCU, CoreMIDI, or CGEvent without manual MIDI Learn.

### Scripter

Optional legacy path for plugin parameter control. Verified plugin apply-back uses `logic_plugins` instead. Approve Scripter only after placing the bundled Scripter insert on the intended tracks.

```bash
LogicProMCP --approve-channel Scripter --approval-note "Scripter inserted on intended tracks"
```

## Verify

```bash
LogicProMCP doctor --json
swift test --filter VersionConsistencyTests
```

From your MCP client:

> Check Logic Pro MCP health and list ready channels.

Fully configured hosts should show Accessibility, AppleScript, CoreMIDI, MCU, MIDIKeyCommands, Scripter, and CGEvent as available. Skipping Key Commands or Scripter is valid when you do not need those paths.

<a id="setup-doctor"></a>
## Doctor (`logic_pro_mcp_doctor.v4`)

`doctor` is read-only and safe to run before starting the server.

```bash
LogicProMCP doctor [--json] [--profile core|mixer|keycmd|legacy-scripter|full] [--client claude-code|claude-desktop|cursor|vscode|terminal|custom] [--strict] [--check-updates] [--verbose|--quiet]
```

Flags:

| Flag | Effect |
|------|--------|
| (none) | Human report: a "next action" headline, a `summary:` counts line, and one line per check. |
| `--verbose` | Adds each check's evidence and `duration_ms`. |
| `--quiet` | Headline + summary + failing/non-pass checks only. |
| `--json` | Machine report. Identical bytes regardless of `--verbose`/`--quiet`/color. |
| `--profile core\|mixer\|keycmd\|legacy-scripter\|full` | Selects the intent-aware readiness profile. Omit to infer from launch context and manual-validation approvals. |
| `--client claude-code\|claude-desktop\|cursor\|vscode\|terminal\|custom` | Selects the MCP client profile for registration checks. Omit to infer from launch context/config. |
| `--check-updates` | Opt-in: adds an `updates.latest_release` check (unauthenticated GitHub releases read). The default run never touches the network. |
| `--strict` | Scripted exit codes: `ok=0`, `failed=1`, `manual_action_required=2`, `degraded=3`. |

Color and unicode symbols are emitted only when stdout is a TTY and `NO_COLOR` is unset; otherwise output is plain ASCII (`[pass]`-style), so pipes and CI logs stay clean.

The `v4` report is a **field-superset** of `v1`/`v2`/`v3`: every prior key keeps its name, semantics, and value. Additive fields include top-level `fix_plan`, `doctor_profile`, `doctor_profile_basis`, `client_profile`, `client_profile_basis`, `capabilities`, per-check `optional`, optional per-check `blocked_by`, optional per-check `skip_reason`, and per-check/report timing (`duration_ms`). Consumers should prefix-match `logic_pro_mcp_doctor.`, not exact-equal a version. Default exit code is unchanged: `failed` → 1, otherwise 0.

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
| Exact 13-check arrays | Switch to ID-based lookup; Doctor v4 emits 26 base checks and 27 with `--check-updates`. |
| Strict schema validators | Allow additive top-level `fix_plan`, profile/client/capability fields, per-check `optional` / `blocked_by` / `skip_reason`, and timing. |
| Skipped-count alarms | Expect a higher baseline; v4 reports diagnostic-capability gaps instead of hiding them. Optional skips do not imply degraded status. |
| UIs unaware of `fix_plan` | Continue rendering checks normally; `fix_plan` only orders the next actions. |
| Readiness dashboards | Prefer `capabilities.<id>.status` for profile-aware readiness over hand-rolled check groups. |

## Doctor Remediation Anchors

These anchors are intentionally compact because `doctor --json` links to them.

<a id="doctor-binarypath"></a>
### `binary.path`
Install with Homebrew, copy the release binary into PATH, or invoke the source build by absolute path.

<a id="doctor-binaryexecutable"></a>
### `binary.executable`
Run `chmod +x '/path/to/LogicProMCP'`. Quote the path if it contains spaces or shell metacharacters.

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
Reinstall from the pinned release artifact, or ad-hoc sign a local source build with `codesign --force --sign - /path/to/LogicProMCP`.

<a id="doctor-releasequarantine"></a>
### `release.quarantine`
After verifying SHA256 and signature, remove quarantine with `xattr -d com.apple.quarantine '/path/to/LogicProMCP'`. Quote the path if it contains spaces or shell metacharacters.

<a id="doctor-mcpclaude-code-registration"></a>
### `mcp.claude_code_registration`
Register with `claude mcp add --scope user logic-pro -- LogicProMCP`. If config parsing fails, fix `~/.claude.json` and rerun doctor.

<a id="doctor-mcpregistration-target"></a>
### `mcp.registration_target`
Refresh the Claude Code MCP registration when its command is missing, relative, not executable, or stale.

<a id="doctor-mcpclaude-desktop-registration"></a>
### `mcp.claude_desktop_registration`
Optional Claude Desktop registration. An absent config is an optional skip and does not degrade strict status. If configured but unregistered, edit `claude_desktop_config.json`.

<a id="doctor-permissionsaccessibility"></a>
### `permissions.accessibility`
Grant Accessibility to the launcher app in System Settings.

<a id="doctor-permissionsautomation-logic-pro"></a>
### `permissions.automation_logic_pro`
Grant Automation access for Logic Pro. If status is `not_verifiable`, launch Logic Pro once and rerun doctor.

<a id="doctor-permissionsautomation-system-events"></a>
### `permissions.automation_system_events`
Grant Automation access for **System Events** (System Settings > Privacy & Security > Automation → System Events). This is a separate TCC target from Logic Pro automation and is required by MIDI import / tempo-dialog / project-state paths (#188). If status is `manual` (`not_verifiable`), the probe could not run — rerun doctor.

<a id="doctor-permissionspost-event-access"></a>
### `permissions.post_event_access`
Grant Accessibility/PostEvent access to the app that launches LogicProMCP; CGEvent fallback operations need it.

<a id="doctor-permissionslaunch-context"></a>
### `permissions.launch_context`
Informational. If the launch context is unknown, re-run doctor from the same app that will launch the server when cross-context TCC is in doubt.

<a id="doctor-permissionstcc-cross-context"></a>
### `permissions.tcc_cross_context`
Cross-context TCC enrichment. If skipped, live permission probes remain authoritative.

<a id="doctor-systemmacos-version"></a>
### `system.macos_version`
Logic Pro MCP requires macOS 14 or newer. Upgrade macOS if this check fails.

<a id="doctor-updateslatest-release"></a>
### `updates.latest_release`
Shown only with `doctor --check-updates`. If a newer release exists, Homebrew installs use `brew upgrade logic-pro-mcp`, source builds pull and rebuild, and release installs replace the pinned asset. Unknown/custom installs receive this docs link instead of a package-manager command. A `skipped` status means the check could not reach the release source (offline / unavailable) — it never blocks.

<a id="doctor-logicapplication-state"></a>
### `logic.application_state`
Launch Logic Pro and open or create a project.

<a id="doctor-logicinstallation"></a>
### `logic.installation`
Install Logic Pro in `/Applications` or `~/Applications`.

<a id="doctor-logicversion-support"></a>
### `logic.version_support`
Use Logic Pro 12.0.1 or newer; 12.3 is the latest validated target.

<a id="doctor-logicblocking-dialog"></a>
### `logic.blocking_dialog`
Dismiss blocking Logic Pro modal dialogs before retrying.

<a id="doctor-channelsmanual-validation"></a>
### `channels.manual_validation`
Approve MIDIKeyCommands or Scripter only after completing the matching Logic-side setup.

<a id="doctor-channelskeycmd-reference"></a>
### `channels.keycmd_reference`
Run `install-keycmds.sh` if you use MIDIKeyCommands-only operations.

<a id="doctor-channelsmcu-wiring-hint"></a>
### `channels.mcu_wiring_hint`
Wire the LogicProMCP MCU port in Logic Pro Control Surfaces if you use MCU-only operations.

<a id="doctor-dependenciesclick-fallback"></a>
### `dependencies.click_fallback`
The server's only synthetic-click path is the native CGEvent post, which requires PostEvent access — grant it in System Settings ▸ Privacy & Security ▸ Accessibility. The external `cliclick` fallback was retired (a present tool is no longer used by the server and is reported as informational evidence only).

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
Run `claude mcp add --scope user logic-pro -- LogicProMCP`.

<a id="lifecycle-mcpunregister"></a>
### `mcp.unregister`
Remove the `logic-pro` server entry from your MCP client config.

<a id="lifecycle-keycmdsstage"></a>
### `keycmds.stage`
Use bundled key command assets as manual MIDI Learn references only.

<a id="lifecycle-keycmdsremove"></a>
### `keycmds.remove`
Remove manual MIDI Learn bindings in Logic Pro if you no longer need keycmd-only paths.

<a id="lifecycle-scripterinsert"></a>
### `scripter.insert`
Insert the bundled Scripter script only on tracks that need legacy parameter writes.

<a id="lifecycle-scripterremove"></a>
### `scripter.remove`
Remove the Scripter insert from the affected Logic tracks.

<a id="lifecycle-launchagentinstall"></a>
### `launch_agent.install`
Install a launch agent only when your MCP client requires one; normal stdio use does not.

<a id="lifecycle-launchagentremove"></a>
### `launch_agent.remove`
Unload and remove the launch agent plist, then verify no stale process remains.

<a id="lifecycle-approvalsremove"></a>
### `approvals.remove`
Delete the manual-validation approval store and its `.lock` sidecar only when you intentionally want to re-approve channels.

## Community

Stuck on setup? Join the official Logic Pro MCP Discord for real-time help: [https://discord.gg/4M3s79DBzz](https://discord.gg/4M3s79DBzz). For reproducible bugs, open a [GitHub Issue](https://github.com/MongLong0214/logic-pro-mcp/issues).
