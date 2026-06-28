# Setup

Minimal install and Logic Pro integration guide for Logic Pro MCP v3.7.2.

## Requirements

- macOS 14+
- Logic Pro 12.0.1+
- Claude Code, Claude Desktop, Cursor, or another MCP client
- `cliclick` (`brew install cliclick`) for the bundled bounce/export helper
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
brew install cliclick
swift build -c release
```

Pinned shell installer:

```bash
brew install cliclick
curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v3.7.2/Scripts/install.sh -o install.sh
# inspect install.sh, then copy pins from the v3.7.2 release:
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
2. **Automation**: allow that app to control **Logic Pro**.

Verify:

```bash
LogicProMCP --check-permissions
LogicProMCP doctor
```

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
- `edit.toggle_step_input`
- `nav.goto_marker`
- `nav.delete_marker`
- `project.bounce`
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

## Doctor Remediation Anchors

These anchors are intentionally compact because `doctor --json` links to them.

<a id="doctor-binarypath"></a>
### `binary.path`
Install with Homebrew, copy the release binary into PATH, or invoke the source build by absolute path.

<a id="doctor-binaryexecutable"></a>
### `binary.executable`
Run `chmod +x /path/to/LogicProMCP`.

<a id="doctor-installsource"></a>
### `install.source`
Prefer the Homebrew install. For source builds, launch `.build/release/LogicProMCP` by absolute path.

<a id="doctor-releasesignature"></a>
### `release.signature`
Reinstall from the pinned release artifact, or ad-hoc sign a local source build with `codesign --force --sign - /path/to/LogicProMCP`.

<a id="doctor-releasequarantine"></a>
### `release.quarantine`
After verifying SHA256 and signature, remove quarantine with `xattr -d com.apple.quarantine /path/to/LogicProMCP`.

<a id="doctor-mcpclaude-code-registration"></a>
### `mcp.claude_code_registration`
Register with `claude mcp add --scope user logic-pro -- LogicProMCP`. If config parsing fails, fix `~/.claude.json` and rerun doctor.

<a id="doctor-permissionsaccessibility"></a>
### `permissions.accessibility`
Grant Accessibility to the launcher app in System Settings.

<a id="doctor-permissionsautomation-logic-pro"></a>
### `permissions.automation_logic_pro`
Grant Automation access for Logic Pro. If status is `not_verifiable`, launch Logic Pro once and rerun doctor.

<a id="doctor-logicapplication-state"></a>
### `logic.application_state`
Launch Logic Pro and open or create a project.

<a id="doctor-channelsmanual-validation"></a>
### `channels.manual_validation`
Approve MIDIKeyCommands or Scripter only after completing the matching Logic-side setup.

## Lifecycle Anchors

`LogicProMCP lifecycle ... --json` is read-only. These anchors are stable remediation targets.

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
