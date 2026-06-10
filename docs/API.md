# API Reference

Complete schema for Logic Pro MCP server. The server exposes **8 tools**, **14 resources**, and **7 resource templates** over MCP JSON-RPC (stdio transport). `logic://mcu/state` is filtered out of `resources/list` when the MCU control surface is disconnected.

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

**14 static resources + 7 templates.** `logic://mcu/state` is filtered from `resources/list` when the MCU control surface is disconnected, but direct `resources/read` still works for bookmarked clients.

| URI | Content | Source |
|-----|---------|--------|
| `logic://system/health` | Health JSON (same schema as `logic_system health`) | Composed on read |
| `logic://transport/state` | `{ state: TransportState, has_document, transport_age_sec }` JSON (v2.2+ wrapper; see below) | Cache (MCU feedback + AX poll) |
| `logic://tracks` | `TrackState[]` JSON | Cache (MCU + AX) |
| `logic://mixer` | `{ cache_age_sec, fetched_at, data_source, ax_occluded, mcu_connected, mcu_registered, mcu_last_feedback_age_ms, registered (alias), strips }` — `data_source` ∈ `ax_poll`/`cache_stale`/`mixer_not_visible` (#11) | Cache (MCU echo + AX poll) |
| `logic://markers` | `MarkerState[]` JSON | Cache (AX poll, every 5 cycles) — see [Marker semantics](#marker-semantics) |
| `logic://project/info` | `ProjectInfo` JSON wrapped in cache envelope (v3.1.8+) — see [Tempo semantics](#tempo-semantics-projectinfo-vs-transportstate) | Tier-merge: live transport/cache → MetaData.plist → defaults (3s AX poll) |
| `logic://midi/ports` | `{ sources, destinations }` | CoreMIDI live query |
| `logic://mcu/state` | `{ connection, display }` — MCU handshake + LCD state | Cache |
| `logic://library/inventory` | Cached Library tree JSON (empty placeholder if not yet scanned) | File (resolved via `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env, `Resources/library-inventory.json`, or `~/Library/Application Support/LogicProMCP/`). All candidates must sit under the path allowlist (`~/Library/Application Support/LogicProMCP/`, `<CWD>/Resources/`, `~/Music/Logic/`); extend via `LOGIC_PRO_MCP_INVENTORY_ALLOWLIST` (colon-separated, additive). |
| `logic://stock-plugins` | `{ schema_version, generated_at, logic_version, catalog_source, validation, entries[] }` — conservative Logic stock plugin catalog with per-entry truth labels | Static catalog + local Logic app census |
| `logic://stock-plugins/census` | Catalog census metadata, state counts, validation state | Static catalog + local Logic app census |
| `logic://stock-plugins/capabilities` | Truth labels, safe write capability labels, and read-only catalog contract | Static |
| `logic://workflow-skills` | `{ schema_version, workflow_count, validation, workflows[] }` — validated workflow skill pack | Static validated pack |
| `logic://workflow-skills/schema` | Workflow schema fields, evidence levels, mutation kinds, and resource names | Static |
| `logic://tracks/{index}` | Single `TrackState` JSON | Cache — template |
| `logic://tracks/{index}/regions` | `RegionState[]` JSON filtered by `trackIndex` | Cache — template |
| `logic://mixer/{strip}` | `{ cache_age_sec, fetched_at, data_source, strip: ChannelStripState }` | Cache — template |
| `logic://stock-plugins/{id}` | Single stock plugin catalog entry by stable ID | Static catalog + local Logic app census — template |
| `logic://stock-plugins/search?query={query}` | Search stock plugin catalog entries | Static catalog + local Logic app census — template |
| `logic://workflow-skills/{id}` | Single workflow skill by stable ID | Static validated pack — template |
| `logic://workflow-skills/search?query={query}` | Search workflow skills | Static validated pack — template |

All resources return `contents: [{ uri, text, mimeType: "application/json" }]`.

Prefer resources over repeated tool calls — they are cheap and safe to poll at 1 Hz.

### Stock Plugin Intelligence

`logic://stock-plugins` is read-only. It does not insert plugins or broaden existing write gates. The catalog covers the documented Logic stock set (effects, instruments, MIDI FX) under stable ID namespaces `logic.stock.effect.*`, `logic.stock.instrument.*`, and `logic.stock.midi_fx.*`.

Each entry has an `availability_state`:

| State | Trust contract |
|-------|----------------|
| `verified` | Live insert/readback evidence on this machine, with source, method, timestamp, and evidence. |
| `observed` | Seen in a live Logic session (e.g. menu observation) without full readback. |
| `manifested` | Per-plugin factory metadata was found in the local Logic installation (a `Plug-In Settings/<Display Name>` folder), with the probed `source_path` recorded in provenance. |
| `inferred` | Documented stock identity only; clients must verify against the live menu before relying on it. |
| `unavailable` | A live census recorded this plugin as absent. Never produced by static knowledge alone. |
| `readback_mismatch` | Live readback returned a different identity than expected. |

The production census can only produce `inferred` and `manifested` (see `production_reachable_states` in `logic://stock-plugins/capabilities`); `verified`, `observed`, `unavailable`, and `readback_mismatch` require injected live-census evidence and are never fabricated. Absence of a factory settings folder is deliberately **not** treated as evidence of absence.

`known_presets` stays empty unless preset names have provenance. For `manifested` entries it lists factory preset filenames harvested from the probed settings folder (capped at `preset_name_cap`, currently 12; the full set remains on disk at the provenance `source_path`).

Clients should prefer stable `id` values and treat `display_name` as user-facing text, not identity. Insert paths are menu hints unless their own state says otherwise. Parameter metadata remains conservative: no parameter is `verified` unless a readback path is evidenced. Entries with `safe_write_capabilities: "insert_only"` (Gain, Compressor, Channel EQ) match the `logic_mixer insert_plugin` allowlist; everything else is discovery-only.

### Workflow Skills

`logic://workflow-skills` is also read-only. It returns workflow recipes that tell clients which resources/tools to call, which state checks must pass, when confirmation is required, and which response fields prove success. Reading a workflow never executes it.

The pack is linted against the **real server surface** — no hand-maintained allowlists:

- Tool references must name registered MCP tools, and every mutating step must carry an exact public `command` that exists in the per-tool command census (the census itself is pinned to the dispatcher sources by test).
- Resource references must be servable by this build (exact static URI, a registered template, or a concrete instantiation of one) or be covered by the workflow's declared `depends_on` external dependencies.
- `mutation_kind` must agree with step mutability in both directions; mutating steps must be covered by a declared confirmation (level `L1`/`L2` only, matching command); `live_verified` workflows must reference their evidence file.

Each served workflow carries computed honesty fields: `dependencies_resolved` says whether every referenced resource is servable by **this** running build, and `unresolved_resources` lists the gaps. The stock-plugin workflows (`logic.workflow.plugins.stock_chain_plan`, `logic.workflow.plugins.stock_insert_gain_live_verified`) declare the #14 stock catalog via `depends_on`; until #14 is merged into the running build they are served with `dependencies_resolved: false`, and clients must not execute them against a server that cannot serve their resources.

Mutating workflows are not marked `production_ready` unless they have matching `live_verified` evidence. `logic.workflow.plugins.stock_insert_gain_live_verified` is the guarded L2 Gain insert recipe backed by the existing Logic Pro 12.2 live evidence file and still requires current-session confirmation/readback.

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
| `set_tempo` | `{ tempo: number }` (5–999, matches Logic's actual accepted range) | text | Accessibility → MIDIKeyCommands |
| `goto_position` | `{ bar: int }` (1..9999) or `{ position: string }` — `"B.B.S.S"` or `"HH:MM:SS:FF"` SMPTE | text | Accessibility (dialog, auto-extends project, ~800ms) → MCU → CoreMIDI → CGEvent |
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
| `select` | `{ index: int }` (preferred) or `{ name: string }` — name uses **case-insensitive substring match, first hit wins** (implemented via `localizedCaseInsensitiveContains`) | text | Accessibility → MCU |
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
| `arm_only` | `{ index: int }` | text on full success; **error** when target arm fails or any disarm fails | composite (disarm-all + arm target) |
| `record_sequence` | `{ bar?: int, notes: "pitch,offsetMs,durMs[,vel[,ch]];...", tempo?: float }` | JSON on success; **error** when goto fails OR no new track is observed via live AX within 500 ms | **v2.3 rewrite**: SMF generation + AX `File → Import → MIDI File…` — byte-exact timing |
| `set_automation` | `{ index: int, mode: "off"\|"read"\|"touch"\|"latch"\|"trim"\|"write" }` | text | MCU |
| `set_instrument` | `{ index: int, path: string }` OR `{ index: int, category: string, preset: string }` — at least one path OR (category + preset) is required | text | Accessibility |
| `list_library` | — | text | Accessibility |
| `scan_library` | — | text | Accessibility |
| `resolve_path` | `{ path: string }` | text | Accessibility |
| `scan_plugin_presets` | `{ submenuOpenDelayMs?: int }` | text | Accessibility |
| `set_color` | — | error | Not exposed in the production MCP contract |

> **All mutating commands** (rename, mute, solo, arm, arm_only, delete, duplicate, set_automation, set_instrument) **reject requests without an explicit `index`** to prevent accidental track-0 mutations from malformed callers. Non-numeric values (e.g. `{"index":"abc"}`) are also rejected. The default `0` behaviour was removed in v3.0.0. `select` is the one exception: if `index` is absent, it falls back to `{ name }` matching; a supplied-but-invalid `index` still fails closed.

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

**`record_sequence` behavior (v2.3+)**:

The old real-time `goto → record → sleep → play_sequence → stop` pipeline is gone. `record_sequence` now:

1. Parses the `notes` spec into internal `NoteEvent` structs.
2. Generates a Type 0 Standard MIDI File with `SMFWriter` — tempo and time-signature meta events + byte-exact note positions computed from `ms` offsets via round-half-up tick conversion.
3. Writes to `/tmp/LogicProMCP/{uuid}.mid` (cleaned up via `defer` on return and via server-startup sweep for crash recovery).
4. Routes `midi.import_file` → `AccessibilityChannel` which validates the `.mid` file after symlink/path cleanup, drives `파일 → 가져오기 → MIDI 파일… (File → Import → MIDI File…)` via AppleScript, dismisses the `템포 가져오기 (Import Tempo)` sub-dialog with `아니요 (No)`, and waits for a new live AX track before returning success.
5. Reads the live AX track-header tree for up to 500 ms until a new track appears. Returns `{ recorded_to_track, created_track, bar, note_count, method: "smf_import" }`. If the new track never appears within the readback window, the command returns an error instead of lying about `created_track`. `recorded_to_track` is a legacy alias for `created_track`; new clients should prefer `created_track`.

**Error conditions for `record_sequence`**:

- `hasDocument` is false (no project open)
- `notes` is empty, or no valid events parsed
- Playhead reset (`transport.goto_position` with `bar=1`) fails — treated as a hard precondition because Logic's MIDI File Import anchors the region at playhead; without the reset, notes would land at the wrong bar
- `midi.import_file` fails, rejects the path, or completes without a new live AX track
- No new track is observed via live AX within 500 ms of import (v3.1.2+ switched from 2s cache polling to live `AXLogicProElements.allTrackHeaders` after the cache-poll race documented in CHANGELOG §3.1.2)

**Strategy D — tick-0 padding CC**: Logic Pro's MIDI File import strips leading empty delta before the first MIDI channel event, which would silently place every imported region at bar 1 regardless of the caller's `bar` parameter. SMFWriter counters this by emitting `CC#110 value 0` on channel 0 at tick 0 whenever `bar > 1`. Logic preserves the full tick timeline because a MIDI channel event now exists at tick 0. The resulting region spans bar 1 through the target bar; the caller's notes land at exactly the encoded positions inside the region. Verified on Logic Pro 12 — a `bar=50` request produces a region that Logic describes as starting at bar 1 and ending at bar 51, with the note at the trailing edge.

**Response caveats**:
- The region's start is always bar 1 (cosmetic trade-off of the padding strategy). If you need the region itself trimmed, the caller can run `편집 → 이동 → 재생헤드로 (Edit → Move → To Playhead)` on the selected region after positioning the playhead.
- `created_track` is always the 0-based index of the newly-created track (Logic always creates a new MIDI track per import). The v2.3.0 `track_index_confirmed` fallback was removed in v3.0.0; v3.1.2 then replaced the original 2-second cache-poll loop with a 500 ms live-AX read against `AXLogicProElements.allTrackHeaders` (cache-poll race fix). On success the field would always be `true` so it was dropped from the response.

**`arm_only` behavior (v3.0.0+)**:

On full success (target arm succeeded and every disarm succeeded), returns a JSON payload:

```json
{
  "armed": 2,              // target track index
  "armedSuccess": true,    // always true in success-payload responses
  "disarmed": [0, 1, 3],   // indices that were successfully disarmed
  "failedDisarm": [],      // always empty in success-payload responses
  "detail": "..."          // channel detail message
}
```

If the primary arm fails, or if any disarm fails, the command returns `isError: true` with a message listing which disarms failed. The structured payload is reserved for complete success — partial failures are no longer silently buried in a "success" envelope.

**Library preconditions:** `list_library`, `scan_library`, and `set_instrument` require the Library panel to be visible in Logic Pro. `resolve_path` is cache-backed and requires a prior successful `scan_library`.

---

## logic_mixer

⚠️ **All mixer write operations require MCU registration.** See [SETUP.md §3](SETUP.md#3-register-mcu-control-surface-mandatory-for-mixer-control). Writes have **no fallback**.

### Commands (write only)

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `set_volume` | `{ track: int, value: number }` (0.0–1.0) | HC State A/B (`observed`, `observed_mcu`, `observed_ax`, `verify_source`, `mcu_connected`, `mcu_last_feedback_age_ms`) | MCU write + MCU/AX readback |
| `set_pan` | `{ track: int, value: number }` (-1.0–1.0) | HC State A/B (+ `pan_write_mode:"relative_vpot"` — relative V-Pot nudge, not idempotent) | **MCU only** |
| `set_master_volume` | `{ volume: number }` (0.0–1.0) | HC State A/B | **MCU only** |
| `set_plugin_param` | `{ track: int, insert: 0, param: 0–17, value: 0.0–1.0 }` | Malformed/out-of-range input → `isError` text, rejected **before** any track-select side effect; an unverified selection → `isError` (State B refused); a routed write → HC State B `readback_unavailable` (write-only) | Scripter (selected track) |
| `insert_plugin` | `{ track: int, slot: int, plugin_name: "Gain" \| "Compressor" \| "Channel EQ", confirmed: true }` | HC State A when AX slot readback confirms the inserted plugin; without `confirmed:true` returns an L2 `confirmation_required` payload; occupied slots fail closed with `slot_occupied` | Accessibility mixer insert menu |
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
  cache_age_sec: number | null,
  fetched_at: string | null,
  data_source: "ax_poll" | "cache_stale" | "mixer_not_visible",  // strip freshness — #11
  ax_occluded: boolean,
  mcu_connected: boolean,
  mcu_registered: boolean,
  mcu_last_feedback_age_ms: int | null,
  registered: boolean,   // one-release alias of mcu_registered
  strips: Array<{
    trackIndex: int,
    volume: number,       // 0.0–1.0 (0 dB ≈ 0.785)
    pan: number,          // -1.0–1.0
    sends: [],
    input?: string,
    output?: string,
    eqEnabled: boolean,
    plugins_source?: "ax",
    plugins_read_error?: string,
    plugins: Array<{ index: int, name: string, isBypassed: boolean }>  // AX names/bypass snapshot for occupied insert slots
  }>
}
```

> **Trust rule (#11/#12):** when `data_source` is `cache_stale`/`mixer_not_visible` or `mcu_connected` is `false`, treat `strips` as last-known-good, not current. When `plugins_source:"ax"` is present, `plugins[]` is a live AX insert-slot name/bypass snapshot; when `plugins_read_error` is present, distinguish read failure from a genuinely empty insert chain.

### Examples

```json
{"command": "set_volume", "params": {"track": 0, "value": 0.75}}
{"command": "set_pan", "params": {"track": 2, "value": -0.3}}
{"command": "set_plugin_param", "params": {"track": 1, "insert": 0, "param": 3, "value": 0.65}}
{"command": "insert_plugin", "params": {"track": 0, "slot": 2, "plugin_name": "Gain", "confirmed": true}}
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
| `import_file` | `{ path: "/tmp/LogicProMCP/name.mid" }` | HC JSON text; State A only after a new AX track appears | Accessibility |
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
| `import_file.path` | Must resolve to a regular `.mid` file under `/tmp/LogicProMCP/`; symlinks/path traversal/control characters are rejected |
| `port name` | Newlines/nulls stripped; truncated to 63 chars |
| SysEx bytes | Must start `0xF0`, end `0xF7`; 7-bit body |

### Examples

```json
{"command": "send_note", "params": {"note": 60, "velocity": 100, "duration_ms": 500}}
{"command": "send_chord", "params": {"notes": "60,64,67,72", "duration_ms": 1000}}
{"command": "send_cc", "params": {"controller": 7, "value": 100}}
{"command": "send_pitch_bend", "params": {"value": 0}}
{"command": "import_file", "params": {"path": "/tmp/LogicProMCP/part-01.mid"}}
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

| Command | Params | Returns | Channel |
|---------|--------|---------|---------|
| `goto_bar` | `{ bar: int }` | text | Delegates to `transport.goto_position` — dialog primary (auto-extends project, ~800ms), slider fallback |
| `goto_marker` | `{ name: string }` or `{ index: int }` | text | By name: cache lookup → `transport.goto_position`. v3.2 — when routing to a fallback/unknown provenance marker, adds `marker_position_uncertain: true` + `marker_position_source` to response extras (HC State A/B only; State C preserved). NG10: navigates only the first dot-component (bar) — sub-bar accuracy is deferred to v3.3 |
| `create_marker` | `{ name?: string }` | text | MIDIKeyCommands → CGEvent |
| `delete_marker` | `{ index: int }` | text | MIDIKeyCommands → CGEvent |
| `rename_marker` | `{ index: int, name: string }` | text | Accessibility |
| `zoom_to_fit` | — | text | MIDIKeyCommands → CGEvent |
| `set_zoom` | `{ level: "in"\|"out"\|"fit" }` | text | MIDIKeyCommands → CGEvent |
| `toggle_view` | `{ view: "mixer"\|"piano_roll"\|"score"\|"step_editor"\|"library"\|"inspector"\|"automation" }` | text | MIDIKeyCommands → CGEvent |

### Reading markers

The state poller enumerates markers through AX every 3 seconds and caches them. On Logic Pro 12.2-style hierarchies it prefers the Marker List window strategy; older/alternate hierarchies fall back to the structural marker-ruler walker. `goto_marker { name: ... }` and `delete_marker { name: ... }` use this cache for name-based lookup.

```ts
// MarkerState (v3.2 wire schema — JSON)
{
  id: int,
  name: string,
  position: string,                                // "bar.beat.div.tick" canonical
  position_source: "parser" | "fallback" | "unknown",  // v3.2 — provenance
  is_canonical: boolean                            // v3.2 — derived: position_source == "parser"
}
```

#### Marker semantics

`logic://markers` resolves marker data **only via AX** — there is no project-file fallback. Logic stores marker positions/names in `Alternatives/000/ProjectData` (an opaque binary blob; reverse-engineering deferred per PRD-issue7-logic12-read-paths.md NG2).

Envelope `source` values:
- `"ax_live"` — markers came from a successful AX marker read (Marker List window or marker-ruler fallback)
- `"cache"` — markers came from a prior poll; `ax_occluded:true` flags untrusted-empty (plugin window / modal stole AX focus)
- `"default"` — empty array, no successful poll yet (cold-start) **or** the AX marker reader could not locate a supported marker subtree/window

On Logic Pro 12.x the new `AXRuler`-structural walker (v3.1.8) succeeds for typical projects but a 12.2-specific marker hierarchy variant has been observed where the walk fails; tracked separately. When `source: "default"` appears on a project that visibly has markers, the AX subtree on that Logic build hasn't been characterized yet.

---

## logic_project

⚠️ **Destructive operations require `{ "confirmed": true }`.** See [Destructive Policy](#destructive-policy).

| Command | Params | Returns | Channel | Level |
|---------|--------|---------|---------|-------|
| `new` | — | text | CGEvent | L1 |
| `open` | `{ path: string, confirmed?: bool }` | text | AppleScript | L2 |
| `save` | — | text | MIDIKeyCommands → CGEvent → AppleScript | L1 |
| `save_as` | `{ path: string, confirmed?: bool }` | HC JSON text; State A only after package existence/mtime readback | Accessibility → AppleScript | L2 |
| `close` | `{ saving?: "yes"\|"no"\|"ask", confirmed?: bool }` | text | AppleScript → CGEvent | L3 |
| `bounce` | `{ confirmed?: bool }` | text | MIDIKeyCommands → CGEvent | L2 |
| `is_running` | — | `"true"` or `"false"` | (direct) | L0 |
| `get_regions` | — | JSON `RegionInfo[]` | Accessibility (read-only arrange area scan) | L0 |
| `launch` | — | text | AppleScript | L1 |
| `quit` | `{ confirmed?: bool }` | text | AppleScript | L3 |

### Reading project info

**Not a tool command.** Use `logic://project/info`:

```ts
// ProjectInfo (v3.1.8+ wraps in cache envelope)
{
  name: string,
  sampleRate: number,
  bitDepth: number,
  tempo: number,
  timeSignature: string,
  trackCount: int,
  filePath?: string,
  lastUpdated: string,            // ISO 8601
  source?: "ax_live" | "cache" | "project_file" | "default",  // v3.1.8+
  lastSavedAgeSec?: number        // v3.1.8+; present when source == "project_file"
}
```

#### Tempo semantics: `project/info` vs `transport/state`

These two resources expose **two semantically different tempos** and callers must pick the right one:

| Resource | Tempo semantic | When to use |
|----------|----------------|-------------|
| `logic://project/info.tempo` | **Best available project tempo field.** Live transport tempo wins when the transport cache is fresh; otherwise saved `MetaData.plist` `BeatsPerMinute` is used; otherwise the default is `120`. | Project metadata, generation defaults, and UI summaries where a single best-known BPM is acceptable. Read `source` to distinguish live/cache/project-file/default provenance. |
| `logic://transport/state.state.tempo` | **Live tempo at current playhead position** — read from Logic's transport bar (AX scrape). On projects with mid-song tempo automation, this changes as the playhead moves. | Live monitoring, "follow-along" UIs, tempo-sync visualizations. |

**Worked example.** Project `Hope_master4.logicx` saves with `tempo: 64`, `timeSignature: "5/4"`, but contains a tempo automation that ramps to 70 BPM by bar 186. With the playhead parked at bar 186:

```
logic://project/info       → { tempo: 70,  timeSignature: "5/4", trackCount: 117, source: "ax_live" }
logic://transport/state    → { state: { tempo: 70, position: "186.1.1.1", ... } }
```

If the live transport tier is unavailable, `logic://project/info` falls back to the saved `64 BPM` and reports `source: "project_file"`. Both shapes are correct given their provenance.

**Out of scope (v3.1.8):** the full tempo map / time-signature change list is **not** exposed by either resource. `ProjectData` (the binary blob containing the automation curves) is not parsed — see PRD-issue7-logic12-read-paths.md §NG1/NG2. If you need the full curve, the path forward is project-file binary reverse-engineering; track a follow-up issue if this is on your critical path.

#### Source attribution (v3.1.8+)

The `source` field tells you which transport tier produced each response:

| `source` | Meaning |
|----------|---------|
| `"ax_live"` | Live/cache value refreshed within the last 3 seconds by AX or transport polling. Tempo/sample-rate may come from `TransportState`. |
| `"cache"` | Live/cache value older than 3 seconds. Treat as potentially stale. |
| `"project_file"` | Read from `MetaData.plist`. Reflects last-saved state — `lastSavedAgeSec` shows how stale relative to the on-disk file. |
| `"default"` | Struct defaults (`tempo: 120`, `timeSignature: "4/4"`, `trackCount: 0`). Logic not running, no document open, or all tiers unavailable. |

The cache layer is the live tier; `MetaData.plist` is the saved-state tier. `ResourceHandlers.readProjectInfo` performs **per-field merge**: live cache/transport values win where available, otherwise fields fall through to `MetaData.plist`. Cache itself is read-only at this layer — `MetaData.plist` reads do not poison `StateCache`, so name-routed write actions (`track.select { name: ... }`) continue to consult only the live AX-derived state. `trackCount` intentionally does **not** promote visible AX track rows to a whole-project total; use saved project metadata or `logic://tracks` depending on whether you need package metadata or currently visible live rows.

#### `project.save_as` readback

`project.save_as` requires `{ "confirmed": true }` and validates the path before touching Logic. On success, the AppleScript fallback wraps the result in Honest Contract State A only after the requested `.logicx` package is observed on disk. For an existing package, the modification time must advance or be at least as new as the save start time. Missing packages, unreadable mtimes, or stale mtimes return State C `readback_mismatch` with `path`, `observed`, and mtime extras when available.

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

`midi.import_file` has a separate, stricter input boundary: the path must resolve to a regular `.mid` under `/tmp/LogicProMCP/`. This keeps raw MCP callers from steering the AX open panel at arbitrary user files.

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
| HC State C `{ "success": false, "error": "channels_exhausted", "operation": "{op}", "hint": "…", "last_error": "…" }` (rc5+) | Fallback chain exhausted — every channel in the chain was unavailable, manual-validation-required, or returned a non-terminal error. The `hint` / `last_error` extras carry the upstream detail. Pre-rc5 this surfaced as a free-form `"All channels exhausted for {op}. Last error: ..."` string. |
| `Invalid path: must be absolute and end in .logicx` | Path validation failed |
| `Confirmation required` | Destructive op without `confirmed: true` |
| `MCU feedback not detected. Register 'LogicProMCP-MCU-Internal' in Logic Pro > Control Surfaces > Setup` | MCU handshake incomplete — see [SETUP.md §3](SETUP.md#3-register-mcu-control-surface-mandatory-for-mixer-control) |

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
