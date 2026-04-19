# Setup Guide

Complete installation, Logic Pro integration, and verification. Should take ~10 minutes on a fresh machine.

## Requirements

- macOS 14+ (Sonoma, Sequoia)
- Logic Pro 12.0.1+
- Apple Silicon (arm64) — Intel users should build from source
- Claude Code or Claude Desktop

---

## 1. Install the Binary

### Option A — One-line installer (recommended)

```bash
LOGIC_PRO_MCP_SHA256=0ee51d21196ed8ca13091f8d73076288d698e1916d3b5aced179beaaaf0f7c8a \
LOGIC_PRO_MCP_TEAM_ID=ADHOC \
bash <(curl -fsSL https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp/v2.3.1/Scripts/install.sh)
```

The installer:
- Downloads the pinned binary from the GitHub release
- Verifies SHA256 hash against the supplied value
- Verifies code signature (adhoc) with `codesign --verify --strict`
- Strips the macOS quarantine attribute so it runs on first launch
- Registers with Claude Code automatically

### Option B — Build from source

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
codesign --force --sign - .build/release/LogicProMCP
sudo cp .build/release/LogicProMCP /usr/local/bin/
claude mcp add --scope user logic-pro -- LogicProMCP
```

---

## 2. Grant macOS Permissions

Open **System Settings → Privacy & Security**:

1. **Accessibility** → add `LogicProMCP` (click `+` → `/usr/local/bin/LogicProMCP`) → toggle ON
2. **Automation** → find `LogicProMCP` → check the `Logic Pro` checkbox

Verify:

```bash
LogicProMCP --check-permissions
# Expected: Accessibility: granted / Automation (Logic Pro): granted
```

---

## 3. Register MCU Control Surface (mandatory for mixer control)

The MCP server controls Logic Pro's mixer via the Mackie Control Universal (MCU) protocol over a virtual MIDI port.

> ⚠️ **MCU registration is the single most failure-prone step** — if you skip it, mixer writes will fail with "All channels exhausted" errors. Follow it exactly.

1. Launch **Logic Pro**. The MCP server auto-starts when Claude Code connects.
2. Menu: **Logic Pro → Control Surfaces → Setup…** (KR: `컨트롤 서피스 → 설정…`)
3. Top-left menu: **New → Install…** (KR: `신규 → 설치…`)
4. Find **Mackie Designs → Mackie Control** → click **Add**
5. Click the newly added **Mackie Control** device card
6. In the Inspector panel, set **BOTH** In and Out ports to `LogicProMCP-MCU-Internal`
7. Close the setup window (saves automatically)

Verify in Claude:

> "Check Logic Pro MCP health and report MCU status."

Expected:

```json
{ "connected": true, "registered_as_device": true, "feedback_stale": false }
```

---

## 4. Install Key Commands Preset (optional — for edit shortcuts)

Enables undo/redo/cut/copy/paste/split/quantize/etc. via virtual MIDI CC.

```bash
# From a cloned repo:
Scripts/install-keycmds.sh

# Or, after installer Option A:
/usr/local/bin/LogicProMCP-install-keycmds
```

Inside Logic Pro:

1. Menu: **Logic Pro → Key Commands → Import Key Commands…** (⌥K)
2. Select `keycmd-preset.plist` from the installer output directory
3. Accept the import prompt

After import, approve the channel:

```bash
LogicProMCP --approve-channel MIDIKeyCommands --approval-note "Imported preset"
```

---

## 5. Install Scripter Insert (optional — for plugin parameter control)

Enables `set_plugin_param` for fine-grained plugin automation via CC 102-119.

1. In Logic Pro, select a Software Instrument track
2. Click the **MIDI FX** slot on the channel strip → select **Scripter**
3. In the Scripter window, click the **Script Editor** tab
4. Paste the contents of `Scripts/LogicProMCP-Scripter.js` into the editor
5. Click **Run Script**

Approve:

```bash
LogicProMCP --approve-channel Scripter --approval-note "Validated insertion on target track"
```

---

## 6. Verify Everything

Ask Claude:

> "Check Logic Pro MCP health."

Expected — all 7 channels `ready`:

```
- Accessibility ✓
- AppleScript ✓
- CoreMIDI ✓
- MCU ✓
- MIDIKeyCommands ✓ (if you completed step 4)
- Scripter ✓ (if you completed step 5)
- CGEvent ✓
```

If any channel is `manual_validation_required`, return to step 4 or 5 and complete the approval.

---

## Uninstall

```bash
Scripts/uninstall.sh

# Or manually:
sudo rm /usr/local/bin/LogicProMCP
claude mcp remove logic-pro
Scripts/uninstall-keycmds.sh   # restores original Key Commands
```

Inside Logic Pro, open **Control Surfaces → Setup…**, select the Mackie Control device, and press Delete.

---

## What's Next

- [API Reference](API.md) — full MCP tool surface
- [Troubleshooting](TROUBLESHOOTING.md) — common issues
- [Architecture](ARCHITECTURE.md) — how the 7-channel design works
