# Logic Pro MCP Server

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-000000.svg?logo=apple)](https://developer.apple.com/macos/)
[![MCP SDK 0.10](https://img.shields.io/badge/MCP_SDK-0.10-blue.svg)](https://github.com/modelcontextprotocol/swift-sdk)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Bidirectional, stateful control of Logic Pro from AI assistants. **7 native macOS channels** (MCU, MIDI Key Commands, CoreMIDI, Scripter, Accessibility, CGEvent, AppleScript) with smart routing, fallback chains, and real-time state feedback.

**8 tools, 7 resources, 93 tests, ~95% DAW control coverage.**

## How It Works

```
Claude ──── 8 dispatcher tools ──── logic_transport("play")
         │                           logic_mixer("set_volume", {track: 2, value: 0.7})
         │  7 MCP resources ──────── logic://transport/state
         │  (zero tool cost)         logic://mixer
         v
   ┌─── LogicProMCP Server ──────────────────────────────────────┐
   │  Command Dispatcher → Channel Router (priority + fallback)   │
   │     │       │        │       │       │       │       │       │
   │   MCU   KeyCmds  CoreMIDI Scripter  AS    CGEvent   AX      │
   │  <2ms    <2ms     <1ms    <5ms    ~200ms   <2ms   ~15ms     │
   └──────────────────────────────────────────────────────────────┘
         ↕ = bidirectional (MCU feedback → state cache)
```

## Channels

| Channel | Role | Direction | Primary For |
|---------|------|-----------|-------------|
| **MCU** (Mackie Control) | Mixer, transport, plugins, automation | Bidirectional | Faders, pan, mute/solo, plugin params |
| **MIDI Key Commands** | Logic Pro keyboard shortcuts via MIDI CC | Send only | Editing, view toggles, track creation |
| **CoreMIDI** | MIDI note/CC input, Step Input | Bidirectional | Note entry, real-time MIDI |
| **Scripter** | Plugin parameter deep control via MIDI FX | Send only | Per-plugin parameter automation |
| **AppleScript** | Project lifecycle | Send only | Open, save, close, bounce |
| **CGEvent** | Keyboard shortcut fallback | Send only | Fallback for Key Commands |
| **Accessibility** | UI state reading (supplementary) | Read only | Project info, regions, markers |

## Tools & Resources

### Tools (8 dispatchers)

| Tool | Commands | Examples |
|------|----------|---------|
| `logic_transport` | play, stop, record, set_tempo, goto_position... | `logic_transport("play")` |
| `logic_tracks` | select, create, mute, solo, arm, set_automation... | `logic_tracks("mute", {index: 2, enabled: true})` |
| `logic_mixer` | set_volume, set_pan, set_send, set_plugin_param... | `logic_mixer("set_volume", {track: 0, value: 0.8})` |
| `logic_midi` | send_note, send_chord, step_input, send_cc... | `logic_midi("send_chord", {notes: [60,64,67]})` |
| `logic_edit` | undo, redo, cut, copy, quantize, toggle_step_input... | `logic_edit("quantize", {value: "1/16"})` |
| `logic_navigate` | goto_bar, create_marker, toggle_view, zoom... | `logic_navigate("toggle_view", {view: "mixer"})` |
| `logic_project` | open, save, close, bounce, launch, quit | `logic_project("save")` |
| `logic_system` | health, permissions, refresh_cache, help | `logic_system("health")` |

### Resources (7 URIs)

| URI | Description |
|-----|-------------|
| `logic://transport/state` | Playing, recording, tempo, position, cycle |
| `logic://tracks` | All tracks with mute/solo/arm/automation states |
| `logic://tracks/{index}` | Single track detail |
| `logic://mixer` | Channel strips: volume, pan, plugins + MCU status |
| `logic://project/info` | Project name, sample rate, time signature |
| `logic://midi/ports` | Available MIDI ports |
| `logic://system/health` | Channel status, MCU connection, permissions |

## Installation

### Build from Source

Requires Swift 6.0+ and macOS 14+.

```bash
git clone https://github.com/MongLong0214/logic-pro-mcp.git
cd logic-pro-mcp
swift build -c release
sudo cp .build/release/LogicProMCP /usr/local/bin/
```

### Register with Claude Code

```bash
claude mcp add --scope user logic-pro -- LogicProMCP
```

### Logic Pro Setup

1. **MCU Control Surface** (required for mixer/transport control):
   - Logic Pro > Control Surfaces > Setup
   - New > Install > Mackie Control > Add
   - Set MIDI In/Out to `LogicProMCP-MCU-Internal`

2. **Key Commands** (optional, for keyboard shortcut control):
   ```bash
   Scripts/install-keycmds.sh
   ```

3. **Scripter MIDI FX** (optional, for plugin parameter control):
   - Add Scripter to channel strip > paste `Scripts/LogicProMCP-Scripter.js`

### Permissions

```bash
LogicProMCP --check-permissions
```

Required:
- **System Settings > Privacy & Security > Accessibility** — add your terminal
- **System Settings > Privacy & Security > Automation > Logic Pro** — allow

## Safety

### Destructive Operation Policy

| Level | Commands | Behavior |
|-------|----------|----------|
| L3 (Critical) | quit, close | Requires `{confirmed: true}` parameter |
| L2 (High) | save_as, bounce, open | Warning in response, audit logged |
| L1 (Normal) | save, new, launch | Audit logged |
| L0 (Safe) | Everything else | Immediate execution |

### Security

- **AppleScript injection**: `project.open` uses `NSWorkspace.open()` (no string interpolation)
- **Transport whitelist**: Only `play`, `stop`, `record`, `pause` allowed via AppleScript
- **SysEx validation**: F0/F7 framing + 7-bit body enforcement

## Architecture

```
Sources/LogicProMCP/
├── Channels/           # 7 communication channels
│   ├── MCUChannel.swift          # Mackie Control Universal (bidirectional)
│   ├── MIDIKeyCommandsChannel.swift  # CC → key command mapping
│   ├── ScripterChannel.swift     # Plugin parameter control
│   ├── CoreMIDIChannel.swift     # MIDI I/O
│   ├── AccessibilityChannel.swift # AX tree reading
│   ├── CGEventChannel.swift      # Keyboard events
│   ├── AppleScriptChannel.swift  # Project lifecycle
│   ├── Channel.swift             # Protocol + ChannelID enum
│   └── ChannelRouter.swift       # 90+ operation routing table
├── Dispatchers/        # 8 MCP tool handlers
├── MIDI/               # MCU protocol, feedback parser, port manager
│   ├── MCUProtocol.swift         # Full MCU encode/decode (§4.5 spec)
│   ├── MCUFeedbackParser.swift   # Feedback → StateCache (bank-aware)
│   ├── MIDIPortManager.swift     # Multi-port actor
│   ├── MIDIEngine.swift          # CoreMIDI I/O
│   └── MIDIFeedback.swift        # MIDI parser (running status)
├── State/              # Cache + poller
├── Resources/          # MCP resource handlers
├── Server/             # LogicProServer + config
└── Utilities/          # Safety, logging, permissions
```

## Testing

```bash
swift test  # 93 tests
```

## Uninstall

```bash
Scripts/uninstall.sh
```

## License

MIT
