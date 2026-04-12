# MCU Control Surface — Detailed Setup

The Logic Pro MCP server communicates with Logic Pro's mixer via the **Mackie Control Universal (MCU) protocol** over a virtual MIDI port. This document describes the exact setup in Logic Pro 12 on macOS.

> **Why MCU?** Logic Pro has no public OSC/API. MCU is the only bidirectional control-surface protocol Logic supports, giving the MCP server real-time access to faders, pan, mute/solo/arm, plugin parameters, and transport state with 14-bit resolution.

---

## Prerequisites

1. **Logic Pro 12.0+** installed
2. **MCP server running** — the virtual MIDI port `LogicProMCP-MCU-Internal` appears only while the server is alive. Claude Code launches the server on demand.
3. **macOS permissions granted** (`LogicProMCP --check-permissions`)

Verify the server is running and the port exists:

```bash
# Check if the MCP server process is alive
pgrep -l LogicProMCP
# Expected: a PID with "LogicProMCP"

# Verify the virtual MIDI port is visible
ls /dev/midi* 2>/dev/null || true
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"logic_midi","arguments":{"command":"list_ports"}}}' \
  | LogicProMCP 2>/dev/null | grep LogicProMCP
```

---

## Step-by-Step Registration

### 1. Open Control Surface Setup

**Menu bar:** `Logic Pro` → `Control Surfaces` → `Setup…`
**Korean UI:** `Logic Pro` → `컨트롤 서피스` → `설정…`

Keyboard shortcut: none by default (can be assigned in Key Commands).

### 2. Install a Mackie Control

In the Setup window:

1. Top-left menu: **`New`** → **`Install…`** (Korean: `신규` → `설치…`)
2. A list of installable devices appears, sorted by manufacturer.
3. Find **`Mackie Designs`** → **`Mackie Control`**
4. Select it and click **`Add`** (or double-click).

A new device card labeled **Mackie Control** appears in the Setup window.

### 3. Configure MIDI Ports

Select the newly added **Mackie Control** device (click the card). The **Inspector panel** on the right (or below, depending on macOS version) shows the device's configuration.

Set **both** ports to `LogicProMCP-MCU-Internal`:

| Field | Value |
|-------|-------|
| **Out Port** (Korean: `출력 포트`) | `LogicProMCP-MCU-Internal` |
| **Input** (Korean: `입력`) | `LogicProMCP-MCU-Internal` |

> ⚠️ **Both In and Out must be set.** If only one is configured, Logic Pro will not send feedback back to the server, and `health.mcu.feedback_stale` will be `true`.

### 4. Close the Setup Window

Changes save automatically. No save button.

### 5. Verify

Call `logic_system health` and check the `mcu` section:

```bash
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"logic_system","arguments":{"command":"health"}}}' \
  | LogicProMCP 2>/dev/null
```

Expected `mcu` section:
```json
{
  "connected": true,
  "registered_as_device": true,
  "last_feedback_at": "2026-04-12T09:34:21.483Z",
  "feedback_stale": false,
  "port_name": "LogicProMCP-MCU-Internal"
}
```

Or test from within Claude:
> "Check Logic Pro MCP health and report MCU status."

---

## Visual Reference

```
┌──── Control Surface Setup ─────────────────────────────┐
│  Edit  New ▼   Help                                    │
│        │                                               │
│        ├── Install…       ← Step 2                     │
│        └── Create…                                     │
│                                                        │
│                                                        │
│    ┌──────────────────┐                                │
│    │ ┌──┐             │   Device Info (Inspector)      │
│    │ │▓▓│  Mackie     │   ┌──────────────────────────┐ │
│    │ │  │  Control    │   │ Module:  Logic Control   │ │
│    │ └──┘             │   │                          │ │
│    │                  │   │ Out Port:                │ │
│    └──────────────────┘   │  [LogicProMCP-MCU-▼]    │ │
│        ↑                  │                   ← Step 3│ │
│     Step 2 result         │ Input:                   │ │
│                           │  [LogicProMCP-MCU-▼]    │ │
│                           │                          │ │
│                           │ Fader Bank: 1            │ │
│                           └──────────────────────────┘ │
└────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| `LogicProMCP-MCU-Internal` is missing from the port dropdown | MCP server is not running | Restart Claude Code, or run `LogicProMCP` manually once to confirm it starts. Check with `pgrep LogicProMCP`. |
| `health.mcu.connected: false` | Port exists but Logic Pro hasn't registered it | Repeat steps 1–4. |
| `health.mcu.registered_as_device: false` | Only one of In/Out is set to the MCP port | Set **both** In and Out to `LogicProMCP-MCU-Internal`. |
| `health.mcu.feedback_stale: true` | Logic Pro isn't sending feedback | Restart Logic Pro. Reopen the Control Surface Setup window once (does not need to change anything — just opening it wakes the handshake). |
| `mixer.set_volume` returns `All channels exhausted for mixer.set_volume. Last error: Channel MCU: MCU feedback not detected.` | MCU handshake incomplete or not registered | Follow this entire guide. This operation has **no fallback** — MCU registration is mandatory for mixer control. |
| IAC Driver appears instead of `LogicProMCP-MCU-Internal` | Default Mackie Control ships with IAC Driver preset | Explicitly change both In and Out dropdowns to `LogicProMCP-MCU-Internal`. |
| Port appears but `connected: false` after 30 seconds | Logic Pro rejected the handshake (rare) | Delete the Mackie Control device (select + Delete key) and repeat installation. |

---

## MCU Feature Matrix

| Feature | MCU Channel | Notes |
|---------|-------------|-------|
| Fader volume | ✅ bidirectional | 14-bit pitch-bend per channel |
| Pan | ✅ bidirectional | VPot encoder, CC 16-23 |
| Mute / Solo / Arm | ✅ bidirectional | Note-on LED feedback |
| Transport (play/stop/record) | ✅ bidirectional | Note-on with LED state |
| Cycle / Metronome | ✅ bidirectional | LED state via feedback |
| LCD display (channel names, values) | ✅ read | SysEx 7-bit text |
| Bank navigation (8-track groups) | ✅ write | Bank left/right buttons |
| Plugin parameter display | ✅ read | Requires plugin focused in VPot mode |
| Automation mode | ✅ write | Read/Touch/Latch/Write |

---

## Why Mandatory for Mixer

The MCP server's routing table assigns mixer operations exclusively to MCU **with no fallback**:

```
mixer.set_volume:    [.mcu]          ← NO fallback
mixer.set_pan:       [.mcu]          ← NO fallback
mixer.set_send:      [.mcu]          ← NO fallback
mixer.set_master_volume: [.mcu]      ← NO fallback
mixer.set_plugin_param:  [.scripter] ← Scripter, not MCU
mixer.get_state:     [.mcu, .accessibility]  ← AX fallback for READ only
mixer.get_channel_strip: [.mcu, .accessibility]
```

This is intentional:
- **AX-based mixer writes are fragile** — the mixer UI layout varies by Logic Pro version, locale, and screen configuration.
- **MCU has 14-bit resolution**; AX would clamp to UI widget granularity (typically 10-bit).
- **MCU is bidirectional** — the state cache reflects what Logic actually did, not what the server requested.

If MCU is unavailable, **read-only mixer operations fall back to AX**, but **all mixer writes will fail with a structured error** until MCU is registered.

---

## Uninstall MCU

1. Open `Logic Pro → Control Surfaces → Setup…`
2. Select the Mackie Control device
3. Press `Delete` (or `Edit → Delete`)
4. Close the window

Removing MCU does not affect other MCP channels (Scripter, MIDIKeyCommands, CoreMIDI remain functional). Only mixer write operations will be disabled.
