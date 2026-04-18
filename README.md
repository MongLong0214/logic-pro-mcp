<p align="center">
  <img src="https://img.shields.io/badge/Logic_Pro-MCP_Server-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Logic Pro MCP Server" />
</p>

<p align="center">
  <strong>The missing API for Logic Pro.</strong><br/>
  Control core Logic Pro workflows from AI assistants via the Model Context Protocol.
</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0+-F05138.svg?style=flat-square" /></a>
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14+-000000.svg?style=flat-square&logo=apple" /></a>
  <a href="https://github.com/modelcontextprotocol/swift-sdk"><img src="https://img.shields.io/badge/MCP_SDK-0.10-blue.svg?style=flat-square" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" /></a>
  <img src="https://img.shields.io/badge/tests-green-brightgreen.svg?style=flat-square" />
  <img src="https://img.shields.io/badge/coverage-~95%25_DAW-blueviolet.svg?style=flat-square" />
</p>

---

Logic Pro has no public API. This server bridges that gap by combining **7 native macOS control channels** into a single MCP interface — giving AI assistants bidirectional, real-time control over mixing, transport, MIDI, plugins, automation, and project management.

> **8 tools. 6 resources + 1 template. 90+ routed operations. Sub-millisecond transport latency.**

## Quick Start

```bash
# Build
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp && swift build -c release

# Install
sudo cp .build/release/LogicProMCP /usr/local/bin/

# Register with Claude
claude mcp add --scope user logic-pro -- LogicProMCP
```

Then complete the required Logic Pro setup:
- **Control Surfaces > Setup > New > Mackie Control** — set MIDI In/Out to `LogicProMCP-MCU-Internal`
- **MIDI FX > Scripter** — load `Scripts/LogicProMCP-Scripter.js`
- **Key Commands > Edit** — import the LogicProMCP preset

Until those steps are finished, Key Commands and Scripter remain `manual_validation_required`.

After validating them in Logic Pro, approve them for runtime use:

```bash
LogicProMCP --approve-channel MIDIKeyCommands
LogicProMCP --approve-channel Scripter
LogicProMCP --list-approvals
```

## How It Works

```
                        ┌──────────────────────────────────┐
  Claude / AI ─────────>│     8 MCP Dispatcher Tools       │
       ^                │   6 MCP Resources + 1 Template   │
       │                └──────────────┬───────────────────┘
       │                               │
       │                ┌──────────────v───────────────────┐
       │                │       Channel Router             │
       │                │    90+ operations × 7 channels   │
       │                │    priority chains + fallbacks    │
       │                └──┬──────┬──────┬──────┬──────┬───┘
       │                   │      │      │      │      │
       │                ┌──v──┐┌──v──┐┌──v──┐┌──v──┐┌──v──┐
       │                │ MCU ││KeyCm││Core ││ AS  ││CGEv │
       │                │<2ms ││<2ms ││MIDI ││~200 ││<2ms │
       │                │ ↕   ││  ↓  ││<1ms ││ ms  ││  ↓  │
       │                │     ││     ││ ↕   ││  ↓  ││     │
       │                └──┬──┘└─────┘└──┬──┘└─────┘└─────┘
       │                   │             │
       │                ┌──v─────────────v─────────────────┐
       └────────────────│   MCU Feedback → State Cache     │
         real-time      │   LCD SysEx • Fader Positions    │
         state sync     │   Button LEDs • Transport State  │
                        └──────────────────────────────────┘
```

Every command routes through the **fastest available ready channel**, with fallback when a higher-priority path is unavailable. MCU provides bidirectional state feedback, while Accessibility polling supplements project metadata where supported.

## Channels

| Channel | Latency | Direction | What It Controls |
|:--------|:-------:|:---------:|:-----------------|
| **MCU** (Mackie Control Universal) | <2ms | Bidirectional | Faders, pan, mute/solo/arm, plugins, sends, EQ, automation, transport |
| **MIDI Key Commands** | <2ms | Send | 60 keyboard shortcuts mapped to MIDI CC on Channel 16 |
| **CoreMIDI** | <1ms | Bidirectional | Note input, chords, step input, CC, SysEx, MMC |
| **Scripter** | <5ms | Send | Per-plugin parameter control (CC 102-119 via MIDI FX) |
| **AppleScript** | ~200ms | Send | Project open/save/close/bounce (NSWorkspace, injection-safe) |
| **CGEvent** | <2ms | Send | Keyboard shortcut fallback |
| **Accessibility** | ~15ms | Read | Project info, regions, markers (supplementary) |

## API Reference

### Tools

<details>
<summary><code>logic_transport</code> — Transport control</summary>

```
play, stop, record, pause, rewind, fast_forward,
toggle_cycle, toggle_metronome, set_tempo, goto_position
```

```json
{"command": "set_tempo", "params": {"bpm": 128}}
```
</details>

<details>
<summary><code>logic_mixer</code> — Mixer & plugin control</summary>

```
set_volume, set_pan, set_master_volume, set_plugin_param
```

```json
{"command": "set_volume", "params": {"track": 2, "value": 0.75}}
{"command": "set_plugin_param", "params": {"track": 1, "insert": 0, "param": 3, "value": 0.65}}
```

> `insert_plugin` and `bypass_plugin` were removed from the public surface in v2.2; no supported channel implements them. Use `set_plugin_param` on the selected track via Scripter for deterministic plugin parameter control.
</details>

<details>
<summary><code>logic_tracks</code> — Track management</summary>

```
select, create_audio, create_instrument, create_drummer,
create_external_midi, delete, duplicate, mute, solo, arm,
arm_only, record_sequence,
rename, set_automation, set_instrument,
list_library, scan_library, resolve_path
```

```json
{"command": "mute", "params": {"index": 3, "enabled": true}}
{"command": "arm_only", "params": {"index": 2}}
// Generate a MIDI file server-side and import it into a new track.
// Notes are laid down with BYTE-EXACT timing at the requested bar position.
// The imported region always spans bar 1 through the target bar (Logic Pro's
// MIDI File import quirk); notes land at the correct bar INSIDE the region.
{"command": "record_sequence", "params": {"bar": 5, "notes": "60,0,480;64,500,480;67,1000,480", "tempo": 120}}
{"command": "set_automation", "params": {"index": 1, "mode": "touch"}}

// Library enumeration + instrument loading (v2.2+)
{"command": "scan_library"}                         // Full tree scan — returns LibraryRoot JSON, caches to Resources/library-inventory.json
{"command": "list_library"}                         // Shallow — currently-visible columns only
{"command": "resolve_path", "params": {"path": "Bass/Sub Bass"}}  // Cache-backed read-only lookup
{"command": "set_instrument", "params": {"index": 0, "path": "Bass/Sub Bass"}}       // Path mode (preferred)
{"command": "set_instrument", "params": {"index": 0, "category": "Bass", "preset": "Sub Bass"}}  // Legacy shape
```

Notes:
- The Library must be visible in Logic Pro (⌘L) for `list_library` / `scan_library` / `set_instrument`.
- `scan_library` clicks through every category — don't touch Logic during scan.
- `resolve_path` never injects a click; it requires a prior `scan_library` to populate the in-memory cache.
- `Resources/library-inventory.json` is a **per-user artifact** — gitignored, regenerated on each scan.
</details>

<details>
<summary><code>logic_midi</code> — MIDI operations</summary>

```
send_note, send_chord, send_cc, step_input,
send_program_change, send_pitch_bend, send_sysex
```

```json
{"command": "send_chord", "params": {"notes": [60,64,67], "velocity": 100, "duration_ms": 500}}
{"command": "step_input", "params": {"note": 60, "duration": "1/4"}}
```
</details>

<details>
<summary><code>logic_edit</code> — Editing operations</summary>

```
undo, redo, cut, copy, paste, delete, select_all,
split, join, quantize, duplicate, toggle_step_input
```

```json
{"command": "quantize", "params": {"value": "1/16"}}
```
</details>

<details>
<summary><code>logic_navigate</code> — Navigation & views</summary>

```
goto_bar, goto_marker, create_marker, delete_marker, rename_marker,
toggle_view, zoom_to_fit, set_zoom
```

```json
{"command": "goto_bar", "params": {"bar": 17}}
{"command": "goto_marker", "params": {"name": "Hook"}}
{"command": "toggle_view", "params": {"view": "mixer"}}
```
</details>

<details>
<summary><code>logic_project</code> — Project lifecycle + read-only state</summary>

```
new, open, save, save_as, close, bounce, launch, quit,
is_running, get_regions
```

```json
{"command": "close", "params": {"saving": "no", "confirmed": true}}
{"command": "get_regions"}
```

> `open`, `save_as`, `bounce`, `quit`, and `close` require `{confirmed: true}` — see [Safety](#safety). `close` accepts `saving: "yes" | "no" | "ask"` (defaults to `"yes"`).

</details>

<details>
<summary><code>logic_system</code> — Diagnostics</summary>

```
health, permissions, refresh_cache, help
```

Returns channel status, MCU registration state, memory/CPU metrics.
</details>

### Resources

| URI | Description | Refresh |
|:----|:------------|:-------:|
| `logic://transport/state` | `{ state: TransportState, has_document, transport_age_sec }` — v2.2+ wrapper lets clients detect stale snapshots | Real-time (MCU) |
| `logic://tracks` | All tracks: name, mute, solo, arm, automation mode | Real-time (MCU) |
| `logic://tracks/{index}` | Single track detail | Real-time (MCU) |
| `logic://mixer` | Channel strips + MCU connection status | Real-time (MCU) |
| `logic://project/info` | Project name, sample rate, time signature | 3s (AX poll) |
| `logic://midi/ports` | Available MIDI ports | On-demand |
| `logic://system/health` | All channel status, latency, permissions | On-demand |

## Installation

### Prerequisites

- macOS 14+ (Sonoma or later)
- Swift 6.0+ (included with Xcode 16+ or Command Line Tools)
- Logic Pro 12.0+

### Build & Install

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
sudo cp .build/release/LogicProMCP /usr/local/bin/
```

## Documentation

- **[Architecture](docs/ARCHITECTURE.md)** — request flow, channel catalog, concurrency model, security boundaries
- **[API Reference](docs/API.md)** — every tool command, resource, param, channel chain
- **[MCU Setup](docs/MCU-SETUP.md)** — step-by-step Mackie Control registration in Logic Pro
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** — permissions, MCU handshake, MIDI routing, performance
- **[Setup Guide (Korean)](docs/SETUP-GUIDE.md)** — 한국어 퀵 셋업

### Enterprise Ops

- [Release Runbook](docs/release/RELEASE-RUNBOOK.md)
- [Clean Machine Validation](docs/release/CLEAN-MACHINE-VALIDATION.md)
- [Logic Pro E2E Checklist](docs/release/LOGIC-PRO-E2E-CHECKLIST.md)
- [Operator Approval Runbook](docs/release/OPERATOR-APPROVAL-RUNBOOK.md)
- [Support Matrix](docs/release/SUPPORT-MATRIX.md)

### Project

- [Changelog](CHANGELOG.md)
- [Security Policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

### Register

**Claude Code:**
```bash
claude mcp add --scope user logic-pro -- LogicProMCP
```

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "logic-pro": {
      "command": "/usr/local/bin/LogicProMCP",
      "args": []
    }
  }
}
```

### Logic Pro Configuration

<details>
<summary><strong>1. MCU Control Surface</strong> (required)</summary>

This enables bidirectional mixer/transport control with real-time state feedback.

1. Open Logic Pro
2. Go to **Logic Pro > Control Surfaces > Setup**
3. Choose **New > Install**
4. Select **Mackie Control** > **Add**
5. Set **MIDI Input** to `LogicProMCP-MCU-Internal`
6. Set **MIDI Output** to `LogicProMCP-MCU-Internal`
7. Close the setup window

> The MCP server must be running for the ports to appear.

</details>

<details>
<summary><strong>2. MIDI Key Commands</strong> (optional)</summary>

Maps 60 Logic Pro keyboard shortcuts to MIDI CC messages on Channel 16.

```bash
Scripts/install-keycmds.sh
```

Then manually assign in Logic Pro: **Key Commands > Edit** (Option-K) using MIDI Learn.

</details>

<details>
<summary><strong>3. Scripter MIDI FX</strong> (optional)</summary>

Enables per-plugin parameter control via CC 102-119.

1. Select target track in Logic Pro
2. Add **Scripter** to MIDI FX slot
3. Paste contents of `Scripts/LogicProMCP-Scripter.js` into the Script Editor
4. Click **Run Script**

</details>

### Permissions

```bash
LogicProMCP --check-permissions
# Accessibility: granted
# Automation (Logic Pro): granted
```

If not granted:
- **System Settings > Privacy & Security > Accessibility** — add your terminal app
- **System Settings > Privacy & Security > Automation** — allow Logic Pro control

## Safety

### Destructive Operation Policy

Commands that can cause data loss require explicit confirmation:

| Level | Commands | Behavior |
|:------|:---------|:---------|
| **L3** Critical | `quit`, `close` | Returns `confirmation_required` — must re-call with `{confirmed: true}` |
| **L2** High | `save_as`, `bounce`, `open` | Returns `confirmation_required` — must re-call with `{confirmed: true}` |
| **L1** Normal | `save`, `new`, `launch` | Audit logged |
| **L0** Safe | Everything else | Immediate execution |

### Security Measures

| Vector | Mitigation |
|:-------|:-----------|
| AppleScript injection | `project.open` uses `NSWorkspace.open()` — no string interpolation |
| Transport commands | Whitelist-only: `play`, `stop`, `record`, `pause` |
| SysEx injection | F0/F7 framing + 7-bit body validation |
| MIDI Key Commands | Dedicated Channel 16, CC 20-99 range (no instrument conflict) |

## Architecture

```
Sources/LogicProMCP/
├── Channels/              7 communication channels
│   ├── MCUChannel           Mackie Control Universal (bidirectional)
│   ├── MIDIKeyCommandsChannel  60 CC→shortcut mappings
│   ├── ScripterChannel      Plugin parameter control
│   ├── CoreMIDIChannel      MIDI I/O + MMC
│   ├── AccessibilityChannel AX tree reading
│   ├── CGEventChannel       Keyboard event fallback
│   ├── AppleScriptChannel   Project lifecycle (NSWorkspace)
│   ├── Channel              Protocol + ChannelID enum
│   └── ChannelRouter        90+ operation routing table
├── Dispatchers/           8 MCP tool handlers
├── MIDI/                  Protocol layer
│   ├── MCUProtocol          Full Mackie Control encode/decode
│   ├── MCUFeedbackParser    Bank-aware state updates
│   ├── MIDIPortManager      Multi-port actor
│   ├── MIDIEngine           CoreMIDI I/O (dynamic buffer)
│   └── MIDIFeedback         MIDI parser (running status)
├── State/                 Reactive state
│   ├── StateCache           Actor-isolated state store
│   ├── StateModels          Transport, Track, ChannelStrip, MCU models
│   └── StatePoller          AX supplementary (5s, project info only)
├── Resources/             MCP resource handlers
├── Server/                Server bootstrap + config
└── Utilities/             DestructivePolicy, AppleScriptSafety, Logger
```

### Key Design Decisions

| Decision | Chosen | Why |
|:---------|:-------|:----|
| Mixer control | MCU over OSC | Logic Pro has no native OSC support. MCU is bidirectional with 14-bit fader resolution. |
| Keyboard shortcuts | MIDI CC over CGEvent | Locale-independent, no window focus required, reliable. |
| Plugin parameters | MCU + Scripter | MCU for browsing, Scripter for direct CC-to-parameter mapping. |
| State reading | MCU feedback (primary) + AX polling (supplementary) | Event-driven for mixer/transport, 3s polling for project metadata only. |
| AppleScript safety | NSWorkspace.open() | Eliminates string interpolation entirely for file paths. |
| Concurrency | Swift actors throughout | Channels, cache, port manager, and feedback parser are actor-isolated to reduce race-condition risk. |

## Testing

```bash
swift test                          # 500 Swift tests (unit + integration + E2E)
swift build -c release              # production binary
LogicProMCP --check-permissions     # verify macOS permissions

# Live tests against a running Logic Pro instance (229 tests):
python3 scripts/live-e2e-test.py
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for test organization and conventions.

## Uninstall

```bash
Scripts/uninstall.sh
```

Or manually:
1. `sudo rm /usr/local/bin/LogicProMCP`
2. `claude mcp remove logic-pro`
3. Logic Pro > Control Surfaces > Setup > remove MCU device
4. `Scripts/uninstall-keycmds.sh` to restore original key commands

## License

MIT
