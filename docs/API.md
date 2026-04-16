# API Reference

Complete schema for Logic Pro MCP server. The server exposes **8 tools**, **6 resources**, and **1 resource template** over MCP JSON-RPC (stdio transport).

**Design principle:** Tools perform write/action operations. **Reads are exposed exclusively through resources** — use `resources/read` for state queries, not tool calls.

Every tool call returns a `CallTool.Result` with `content: [{ type: "text", text: string }]` and an `isError: boolean`. On error, the text is a human-readable message (sometimes with a JSON fragment).

---

## Tool Catalog

| Tool | Purpose | Nature |
|------|---------|--------|
| [`logic_transport`](#logic_transport) | Play, stop, record, tempo, position | Write |
| [`logic_tracks`](#logic_tracks) | Track create/delete/mute/solo/arm/rename/automation | Write |
| [`logic_mixer`](#logic_mixer) | Fader, pan, send, plugin parameters | Write |
| [`logic_midi`](#logic_midi) | Raw MIDI + MMC + step input | Write |
| [`logic_edit`](#logic_edit) | Undo/redo/cut/copy/paste/quantize | Write |
| [`logic_navigate`](#logic_navigate) | Bar navigation, markers, zoom, view toggles | Write |
| [`logic_project`](#logic_project) | Open, save, close, bounce, quit | Write |
| [`logic_system`](#logic_system) | Health, permissions, help, cache refresh | Mixed |

All tool invocations use:
```json
{"name": "logic_xxx", "arguments": {"command": "...", "params": { ... }}}
```

---

## Resource Catalog (Read-only)

| URI | Content | Source |
|-----|---------|--------|
| `logic://transport/state` | `TransportState` JSON | Cache (MCU feedback + AX poll) |
| `logic://tracks` | `TrackState[]` JSON | Cache (MCU + AX) |
| `logic://tracks/{index}` | Single `TrackState` JSON | Cache — template |
| `logic://mixer` | `{ mcu_connected, registered, strips }` | Cache |
| `logic://project/info` | `ProjectInfo` JSON | Cache (3s AX poll) |
| `logic://midi/ports` | `{ sources, destinations }` | CoreMIDI live query |
| `logic://system/health` | Health JSON (same schema as `logic_system health`) | Composed on read |

All resources return `contents: [{ uri, text, mimeType: "application/json" }]`.

Prefer resources over repeated tool calls — they are cheap and safe to poll at 1 Hz.

---

## logic_transport

### Commands (write only)

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `play` | — | text | Accessibility → MCU → CoreMIDI → CGEvent |
| `stop` | — | text | Accessibility → MCU → CoreMIDI → CGEvent → AppleScript |
| `record` | — | text | Accessibility → MCU → CoreMIDI → CGEvent → AppleScript |
| `pause` | — | text | CoreMIDI → CGEvent |
| `rewind` | — | text | MCU → CoreMIDI → CGEvent |
| `fast_forward` | — | text | MCU → CoreMIDI → CGEvent |
| `toggle_cycle` | — | text | Accessibility → MCU → MIDIKeyCommands → CGEvent |
| `toggle_metronome` | — | text | Accessibility → MIDIKeyCommands → CGEvent |
| `toggle_count_in` | — | text | Accessibility → MIDIKeyCommands → CGEvent |
| `set_tempo` | `{ tempo: number }` (20–300) | text | Accessibility → MIDIKeyCommands |
| `goto_position` | `{ bar: int }` or `{ position: "B.B.S.S" }` | text | Accessibility → MCU → CoreMIDI → CGEvent |
| `set_cycle_range` | `{ start: int, end: int }` | text | Accessibility |
| `capture_recording` | — | text | MIDIKeyCommands → CGEvent |

### Reading transport state

**Not a tool command.** Read `logic://transport/state` instead:

```ts
// logic://transport/state (v2.2+ wrapped shape)
{
  state: {
    isPlaying: boolean,
    isRecording: boolean,
    isPaused: boolean,
    isCycleEnabled: boolean,
    isMetronomeEnabled: boolean,
    tempo: number,           // BPM
    position: string,        // "B.B.S.S" — e.g. "9.1.1.1"
    timePosition: string,    // "HH:MM:SS.mmm"
    sampleRate: number,
    lastUpdated: string      // ISO 8601
  },
  has_document: boolean,     // false ⇒ no project open; `state` is a default-initialised placeholder
  transport_age_sec: number  // seconds since StatePoller last refreshed `state`; astronomically large when stale
}
```

Clients can detect stale snapshots without cross-referencing `logic://system/health`:
- `has_document === false` → no project open.
- `transport_age_sec` > poll interval (3 s) + tolerance → snapshot is outdated.

### Examples

```json
{"command": "play"}
{"command": "set_tempo", "params": {"tempo": 128}}
{"command": "goto_position", "params": {"bar": 9}}
{"command": "set_cycle_range", "params": {"start": 1, "end": 5}}
```

---

## logic_tracks

### Commands (write only)

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `select` | `{ index: int }` | text | Accessibility → MCU |
| `create_audio` | — | text | AX → MIDIKeyCommands → CGEvent |
| `create_instrument` | — | text | AX → MIDIKeyCommands → CGEvent |
| `create_drummer` | — | text | AX → MIDIKeyCommands → CGEvent |
| `create_external_midi` | — | text | AX → MIDIKeyCommands → CGEvent |
| `delete` | `{ index: int }` | text | MIDIKeyCommands → CGEvent |
| `duplicate` | `{ index: int }` | text | MIDIKeyCommands → CGEvent |
| `rename` | `{ index: int, name: string }` (max 255 chars) | text | Accessibility |
| `mute` | `{ index: int, enabled?: bool }` | text | MCU → AX → CGEvent |
| `solo` | `{ index: int, enabled?: bool }` | text | MCU → AX → CGEvent |
| `arm` | `{ index: int, enabled?: bool }` | text | MCU → AX → CGEvent |
| `arm_only` | `{ index: int }` | text | composite (disarm-all + arm target) — ⚠️ MCU unregistered ⇒ disarm best-effort |
| `record_sequence` | `{ index: int, bar?: int, notes: "pitch,offsetMs,durMs[,vel[,ch]];..." }` | text | composite (select + arm_only + record + play + stop) — ⚠️ **known: uncompensated record-arm latency + silent mid-step failures** |
| `set_automation` | `{ index: int, mode: "off"\|"read"\|"touch"\|"latch"\|"write" }` | text | MCU |
| `set_instrument` | `{ index: int, path?: string }` or `{ index: int, category: string, preset: string }` | text | Accessibility |
| `list_library` | — | text | Accessibility |
| `scan_library` | — | text | Accessibility |
| `resolve_path` | `{ path: string }` | text | Accessibility |
| `scan_plugin_presets` | `{ submenuOpenDelayMs?: int }` | text | Accessibility |
| `set_color` | — | error | Not exposed in the production MCP contract |

### Reading tracks

**Not tool commands.** Use:
- `logic://tracks` → `TrackState[]` for the full list
- `logic://tracks/{index}` → single `TrackState` for one track

```ts
// TrackState
{
  id: int,
  name: string,
  type: "audio" | "software_instrument" | "drummer" | "external_midi" | "aux" | "bus" | "master" | "unknown",
  isMuted: boolean,
  isSoloed: boolean,
  isArmed: boolean,
  isSelected: boolean,
  volume: number,
  pan: number,
  automationMode: "off" | "read" | "trim" | "touch" | "latch" | "write",
  color?: string
}
```

### Examples

```json
{"command": "mute", "params": {"index": 3, "enabled": true}}
{"command": "rename", "params": {"index": 0, "name": "Lead Vox"}}
{"command": "set_automation", "params": {"index": 1, "mode": "touch"}}
{"command": "scan_library"}
{"command": "resolve_path", "params": {"path": "Bass/Sub Bass"}}
{"command": "set_instrument", "params": {"index": 0, "path": "Bass/Sub Bass"}}
```

**Input validation:** `rename` truncates names to 255 chars. Unicode (including emoji, Korean, Japanese) is fully supported.

**`record_sequence` known limitations (as of v2.2):**
1. Record-arm latency is variable (50–300 ms) and uncompensated — notes land at `bar + latency`, not `bar`. Multi-track sync is similarly drift-prone.
2. The composite pipeline `goto → record → sleep → play → stop` discards intermediate channel errors, so an arm or transport failure can surface as a success response.
3. In MCU-unregistered environments, `arm_only`'s per-track disarm step is best-effort and may leave multiple tracks armed, causing MIDI duplication.

For reliable recording today, prefer live `send_chord` / `send_note` over `record_sequence`. The full fix is tracked in the internal `record_sequence sync bug` memory entry and will ship as a Level 2 redesign (likely server-side SMF generation + AX import).

**Library preconditions:** `list_library`, `scan_library`, and `set_instrument` require the Library panel to be visible in Logic Pro. `resolve_path` is cache-backed and requires a prior successful `scan_library`.

---

## logic_mixer

⚠️ **All mixer write operations require MCU registration.** See [MCU-SETUP.md](MCU-SETUP.md). Writes have **no fallback**.

### Commands (write only)

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `set_volume` | `{ index: int, volume: number }` (0.0–1.0) | text | **MCU only** |
| `set_pan` | `{ index: int, value: number }` (-1.0–1.0) | text | **MCU only** |
| `set_master_volume` | `{ volume: number }` (0.0–1.0) | text | **MCU only** |
| `set_plugin_param` | `{ track: int, insert: int, param: int, value: number }` | text | Scripter |
| `insert_plugin` | — | error | Removed in v2.2 — no supported channel; use `set_plugin_param` via Scripter |
| `bypass_plugin` | — | error | Removed in v2.2 — no supported channel; use `set_plugin_param` via Scripter |
| `set_send` | — | error | Not yet deterministic in production contract |
| `set_output` | — | error | Not exposed in the production MCP contract |
| `set_input` | — | error | Not exposed in the production MCP contract |
| `toggle_eq` | — | error | Not exposed in the production MCP contract |
| `reset_strip` | — | error | Not exposed in the production MCP contract |

### Reading mixer state

**Not tool commands.** Use `logic://mixer`:

```ts
// Mixer resource
{
  mcu_connected: boolean,
  registered: boolean,
  strips: Array<{
    trackIndex: int,
    volume: number,       // 0.0–1.0
    pan: number,          // -1.0–1.0
    sends: [],
    input?: string,
    output?: string,
    eqEnabled: boolean,
    plugins: Array<{ index: int, name: string, isBypassed: boolean }>
  }>
}
```

### Examples

```json
{"command": "set_volume", "params": {"index": 0, "volume": 0.75}}
{"command": "set_pan", "params": {"index": 2, "value": -0.3}}
{"command": "set_plugin_param", "params": {"track": 1, "insert": 0, "param": 3, "value": 0.65}}
```

---

## logic_midi

### Commands

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `send_note` | `{ note: 0–127, velocity?: 0–127, channel?: 1–16, duration_ms?: 1–30000 }` | `"Note X on ch Y vel Z dur Wms"` | CoreMIDI |
| `send_chord` | `{ notes: "60,64,67" \| int[], velocity?: 0–127, channel?: 1–16, duration_ms?: 1–30000 }` | `"Chord sent: N notes"` | CoreMIDI |
| `send_cc` | `{ controller: 0–127, value: 0–127, channel?: 1–16 }` | `"CC X=Y on ch Z"` | CoreMIDI |
| `send_program_change` | `{ program: 0–127, channel?: 1–16 }` | text | CoreMIDI |
| `send_pitch_bend` | `{ value: 0–16383 \| -8192..8191, channel?: 1–16 }` | text | CoreMIDI |
| `send_aftertouch` | `{ value: 0–127, channel?: 1–16 }` | text | CoreMIDI |
| `send_sysex` | `{ bytes: "F0 ... F7" \| int[] }` | text | CoreMIDI |
| `step_input` | `{ note: 0–127, duration?: "1/1"\|"1/2"\|"1/4"\|"1/8"\|"1/16"\|"1/32" \| int_ms }` | text | CoreMIDI |
| `create_virtual_port` | `{ name: string }` (max 63 chars, no newlines/nulls) | text | CoreMIDI |
| `mmc_play` | — | text | CoreMIDI |
| `mmc_stop` | — | text | CoreMIDI |
| `mmc_record` | — | text | CoreMIDI |
| `mmc_locate` | `{ bar: int }` or `{ time: "HH:MM:SS:FF" }` | text | CoreMIDI |

### Listing ports

**Not a tool command.** Use `logic://midi/ports`:

```ts
{ sources: string[], destinations: string[] }
```

### Input validation

| Field | Rule |
|-------|------|
| `note` | 0–127 (values outside are clamped by CoreMIDI) |
| `velocity` | 0–127; default `100` |
| `channel` | 1–16 (wire: 0–15); default `1` |
| `duration_ms` | Capped at **30,000** to prevent actor DoS |
| `port name` | Newlines/nulls stripped; truncated to 63 chars |
| SysEx bytes | Must start `0xF0`, end `0xF7`; 7-bit body |

### Examples

```json
{"command": "send_note", "params": {"note": 60, "velocity": 100, "duration_ms": 500}}
{"command": "send_chord", "params": {"notes": "60,64,67,72", "duration_ms": 1000}}
{"command": "send_cc", "params": {"controller": 7, "value": 100}}
{"command": "send_pitch_bend", "params": {"value": 0}}
{"command": "step_input", "params": {"note": 60, "duration": "1/4"}}
{"command": "mmc_locate", "params": {"bar": 9}}
```

---

## logic_edit

All commands route through `MIDIKeyCommands → CGEvent`.

| Command | Params | Returns |
|---------|--------|---------|
| `undo` | — | text |
| `redo` | — | text |
| `cut` | — | text |
| `copy` | — | text |
| `paste` | — | text |
| `delete` | — | text |
| `select_all` | — | text |
| `split` | — | text |
| `join` | — | text |
| `quantize` | `{ value?: "1/4"\|"1/8"\|"1/16" }` | text |
| `bounce_in_place` | — | text |
| `normalize` | — | text |
| `duplicate` | — | text |
| `toggle_step_input` | — | text |

---

## logic_navigate

> ⚠️ Known gaps (tracked in [docs/tickets/navigate-redesign/](tickets/navigate-redesign/)):
> - `goto_bar` is routed to `[MCU, CGEvent]` but neither channel implements it today; prefer `transport.goto_position` with `"bar.beat.sub.tick"` until the ticket lands.
> - `goto_marker` by `{ name: ... }` consults the marker cache, which is currently not populated by the state poller. `goto_marker` by `{ index: ... }` (MIDIKeyCommands) remains reliable.

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `goto_bar` | `{ bar: int }` | text | MCU → CGEvent — **gap, see above** |
| `goto_marker` | `{ name: string }` or `{ index: int }` | text | MIDIKeyCommands → CGEvent |
| `create_marker` | `{ name?: string }` | text | MIDIKeyCommands → CGEvent |
| `delete_marker` | `{ index: int }` | text | MIDIKeyCommands → CGEvent |
| `rename_marker` | `{ index: int, name: string }` | text | Accessibility |
| `zoom_to_fit` | — | text | MIDIKeyCommands → CGEvent |
| `set_zoom` | `{ direction: "in"\|"out"\|"fit" }` | text | MIDIKeyCommands → CGEvent |
| `toggle_view` | `{ view: "mixer"\|"piano_roll"\|"score"\|"step_editor"\|"library"\|"inspector"\|"automation" }` | text | MIDIKeyCommands → CGEvent |

### Reading markers

**Not a tool command.** Read `logic://project/info` or use internal poller state.

```ts
// MarkerState (inside other payloads)
{ id: int, name: string, position: string }
```

---

## logic_project

⚠️ **Destructive operations require `{ "confirmed": true }`.** See [Destructive Policy](#destructive-policy).

| Command | Params | Returns | Channel | Level |
|---------|--------|---------|---------|-------|
| `new` | — | text | CGEvent | L1 |
| `open` | `{ path: string, confirmed?: bool }` | text | AppleScript | L2 |
| `save` | — | text | MIDIKeyCommands → CGEvent → AppleScript | L1 |
| `save_as` | `{ path: string, confirmed?: bool }` | text | Accessibility → AppleScript | L2 |
| `close` | `{ saving?: "yes"\|"no"\|"ask", confirmed?: bool }` | text | AppleScript → CGEvent | L3 |
| `bounce` | `{ confirmed?: bool }` | text | MIDIKeyCommands → CGEvent | L2 |
| `is_running` | — | `"true"` or `"false"` | (direct) | L0 |
| `get_regions` | — | JSON `RegionInfo[]` | Accessibility (read-only arrange area scan) | L0 |
| `launch` | — | text | AppleScript | L1 |
| `quit` | `{ confirmed?: bool }` | text | AppleScript | L3 |

### Reading project info

**Not a tool command.** Use `logic://project/info`:

```ts
// ProjectInfo
{
  name: string,
  sampleRate: number,
  bitDepth: number,
  tempo: number,
  timeSignature: string,
  trackCount: int,
  filePath?: string,
  lastUpdated: string   // ISO 8601
}
```

### Destructive Policy

Without `confirmed: true`, destructive operations return:

```json
{
  "confirmation_required": true,
  "command": "quit",
  "risk": "L3",
  "reason": "..."
}
```

Re-call with `{"confirmed": true}` to execute.

### Path validation

`project.open` paths must satisfy **all** of:

- Absolute path (begins with `/`)
- `.logicx` extension
- No control characters (`\n`, `\r`, `\t`, `\0`)
- Not under `/dev/`
- Directory exists and contains `Resources/ProjectInformation.plist` and `Alternatives/*/ProjectData`

Invalid paths return an error **before** any AppleScript execution.

---

## logic_system

| Command | Params | Returns |
|---------|--------|---------|
| `health` | — | Health JSON |
| `permissions` | — | Text summary of Accessibility + Automation permissions |
| `refresh_cache` | — | text |
| `help` | — | Text listing all tools and commands |

### Health schema

Returned by both `logic_system health` (tool) and `logic://system/health` (resource).

```ts
{
  logic_pro_running: boolean,
  logic_pro_version: string,
  mcu: {
    connected: boolean,
    registered_as_device: boolean,
    last_feedback_at: string | null,   // ISO 8601
    feedback_stale: boolean,
    port_name: string
  },
  channels: Array<{
    channel: string,                   // "MCU", "MIDIKeyCommands", ...
    available: boolean,
    ready: boolean,
    latency_ms: number | null,
    detail: string,
    verification_status: "runtime_ready" | "manual_validation_required" | "unavailable" | "unknown"
  }>,                                   // 7 entries
  cache: {
    poll_mode: "active" | "idle",
    transport_age_sec: number,
    track_count: int,
    project: string
  },
  permissions: {
    accessibility: boolean,
    automation: boolean,
    automation_granted: boolean | null,
    accessibility_status: string,
    automation_status: string,
    automation_verifiable: boolean,
    post_event_access: boolean
  },
  process: {
    memory_mb: number,
    cpu_percent: number,
    uptime_sec: int
  }
}
```

`logic_system permissions` returns a human-readable summary string. For machine-readable permission state including `post_event_access`, use `logic_system health` or `logic://system/health`.

---

## Error Format

Tool errors:
```ts
{ content: [{ type: "text", text: string }], isError: true }
```

Common messages:

| Message pattern | Meaning |
|-----------------|---------|
| `Unknown {category} command: {name}` | Command not in dispatcher |
| `Missing '{param}' parameter` | Required param absent |
| `All channels exhausted for {op}. Last error: ...` | Fallback chain exhausted — see `detail` for final error |
| `Invalid path: must be absolute and end in .logicx` | Path validation failed |
| `Confirmation required` | Destructive op without `confirmed: true` |
| `MCU feedback not detected. Register 'LogicProMCP-MCU-Internal' in Logic Pro > Control Surfaces > Setup` | MCU handshake incomplete — see [MCU-SETUP.md](MCU-SETUP.md) |

Resource errors throw `MCPError.invalidParams`:
- `Unknown resource URI: {uri}`
- `No track at index {N}`
- `No Logic Pro document is open`

---

## Performance Reference

| Operation | Typical Latency |
|-----------|-----------------|
| `tools/list`, `resources/list` | < 30 ms |
| `logic_system health` (warm) | 50–150 ms |
| `logic_system health` (cold — first call) | 200–2000 ms |
| MCU write (`mixer.set_volume`, `transport.play`) | 2–10 ms |
| CoreMIDI write (`send_note`, `send_cc`) | 1–5 ms |
| AX-backed resource read (transport/state, tracks ≤16) | 20–80 ms |
| AX read on large projects (100+ tracks) | 300–800 ms |
| AppleScript (`project.open`) | 200–2000 ms |

No server-side rate limit. Actor-based design serializes per-channel work while allowing parallel dispatch across channels.

**Safety caps:**
- `send_note` / `send_chord` / `step_input`: `duration_ms` capped at 30,000
- `rename`: name truncated to 255 chars
- `create_virtual_port`: name truncated to 63 chars, newlines/nulls stripped
