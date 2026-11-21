# Cursor + Logic Pro MCP

Logic Pro MCP talks to Logic Pro only on **macOS**. Cloud Agents that boot on Linux **cannot** run `LogicProMCP` or drive Logic Pro from the cloud VM. Connect MCP in **Cursor on your Mac**, or attach a **self-hosted Mac worker** so agents run beside Logic Pro.

## Quick connect (Mac)

1. Install the server ([SETUP.md](SETUP.md#install)):

   ```bash
   brew tap MongLong0214/logic-pro-mcp https://github.com/MongLong0214/logic-pro-mcp
   brew trust monglong0214/logic-pro-mcp
   brew install logic-pro-mcp
   ```

2. Run the repo setup script (installs Homebrew package if needed, merges Cursor config, runs doctor):

   ```bash
   bash Scripts/cursor-mcp-setup.sh
   ```

3. Complete permissions and Logic MCU wiring ([SETUP.md](SETUP.md#macos-permissions), [MCU setup](SETUP.md#mcu-control-surface)).

4. Restart Cursor or reload the **logic-pro** server under **Settings → MCP**.

This repository ships a project config at [`.cursor/mcp.json`](../.cursor/mcp.json). Cursor merges it with your user `~/.cursor/mcp.json`. If you build from source, either put the binary on `PATH` as `LogicProMCP` or set an absolute path:

```json
{
  "mcpServers": {
    "logic-pro": {
      "command": "/absolute/path/to/.build/release/LogicProMCP"
    }
  }
}
```

## Verify in Cursor

Ask the agent:

> Check Logic Pro MCP health and show all ready channels.

Or in Terminal:

```bash
LogicProMCP doctor --json --client cursor
```

## Cloud Agents vs local Cursor

| Where you chat | Logic Pro MCP |
|----------------|---------------|
| Cursor desktop on your Mac, MCP enabled | Connected when `LogicProMCP` runs and permissions are granted |
| Cloud Agent on a Linux VM | **Not connected** — no Logic Pro, no macOS server binary |
| Cloud Agent on a **self-hosted Mac worker** | Possible — worker must run on the Mac that hosts Logic Pro |

To use Cloud Agents **with** Logic Pro, start a worker on that Mac ([Cursor docs: self-hosted machines](https://cursor.com/docs/cloud-agent/self-hosted/my-machines)):

```bash
agent login
agent worker start
```

Then launch agents targeting that worker pool. MCP still runs locally on the Mac; the agent process must be the one that launches `LogicProMCP` (with Cursor granted Accessibility on that machine).

## Troubleshooting

- **logic-pro shows error in MCP settings** — run `LogicProMCP doctor --client cursor` and fix `failed` / `manual` checks.
- **Stale connection in Cursor** — disable and re-enable the server, or restart Cursor. For debugging, see `logic_mcp_proxy.py` in the repo root (direct stdio probe).
- **Second server instance** — only one `LogicProMCP` should publish the MCU MIDI port; quit duplicate MCP connections.

More: [TROUBLESHOOTING.md](TROUBLESHOOTING.md), [SETUP.md](SETUP.md).