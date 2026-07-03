# API Reference

Current stable surface: Logic Pro MCP v3.7.4 exposes 10 tools, 18 static resources, and 11 resource templates.

Use tools for actions. Use resources for state. Treat every mutating result as one of:

- State A: confirmed success. The server wrote to Logic and independently read the result back.
- State B: uncertain success. The server attempted the action but could not verify the result.
- State C: hard failure. The action did not land and is safe to retry only when `retry_safe` says so.

## Tools

| Tool | Purpose |
|------|---------|
| `logic_transport` | play, stop, record, locate, tempo, cycle, metronome, count-in |
| `logic_tracks` | create, select, rename, delete, duplicate, arm, mute, solo, set instrument |
| `logic_mixer` | volume, pan, master volume, mixer strip reads, guarded legacy plugin insertion |
| `logic_plugins` | verified stock-plugin inventory, exact-slot insertion, verified parameter write/readback |
| `logic_midi` | send notes/CC/MMC, import MIDI, create/list virtual ports |
| `logic_edit` | undo, redo, cut, copy, paste, quantize, split, join, normalize, duplicate |
| `logic_navigate` | bars, markers, zoom, view toggles |
| `logic_project` | new, open, save, save_as, close, bounce, export plan/run/resume, audit, cleanup |
| `logic_audio` | read-only audio artifact analysis |
| `logic_system` | health, permissions, command help |

## Resources

| Resource | Returns |
|----------|---------|
| `logic://system/health` | channel readiness, permissions, manual-validation state |
| `logic://transport/state` | tempo, position, cycle, play/record state |
| `logic://tracks` | track list with source/freshness metadata |
| `logic://mixer` | mixer strips, plugin slots, data-source labels |
| `logic://markers` | marker list when Logic exposes it |
| `logic://project/info` | project name/path, tempo, sample rate, track count |
| `logic://project/audit` | read-only project/session audit |
| `logic://project/cleanup-plan` | read-only cleanup plan |
| `logic://midi/ports` | CoreMIDI ports visible to the process |
| `logic://mcu/state` | MCU registration/feedback state |
| `logic://library/inventory` | cached Logic library inventory |
| `logic://stock-plugins` | stock plugin catalog |
| `logic://stock-plugins/census` | catalog validation summary |
| `logic://stock-plugins/capabilities` | writable/readable plugin capability matrix |
| `logic://stock-instruments` | stock instrument catalog |
| `logic://session-players` | Session Player catalog |
| `logic://workflow-skills` | workflow recipe catalog |
| `logic://workflow-skills/schema` | workflow recipe schema |

## Resource Templates

`logic://tracks/{index}`, `logic://tracks/{index}/regions`, `logic://mixer/{strip}`,
`logic://stock-plugins/{id}`, `logic://stock-plugins/search?query={query}`,
`logic://stock-instruments/{id}`, `logic://stock-instruments/search?query={query}`,
`logic://session-players/{id}`, `logic://workflow-plans/session?prompt={prompt}`,
`logic://workflow-skills/{id}`, `logic://workflow-skills/search?query={query}`.

## Command Notes

### `logic_transport`

| Command | Params | Result | Route |
|---------|--------|--------|-------|
| `play`, `record` | none | text / contract envelope | Accessibility -> MCU -> CoreMIDI -> CGEvent -> AppleScript |
| `stop` | none | text / contract envelope | CGEvent -> Accessibility -> MCU -> CoreMIDI -> AppleScript |
| `toggle_cycle` | — | text | Accessibility → MIDIKeyCommands → CGEvent → MCU |
| `set_cycle_range` | `{ startBar, endBar }` | State C `not_implemented` on current public surface | none |
| `set_tempo` | `{ tempo: number }` (5–999, matches Logic's actual accepted range) | text | Accessibility |
| `goto_bar` | `{ bar: number }` | text / contract envelope | Accessibility -> MIDIKeyCommands -> MMC |

Read current state from `logic://transport/state` after any transport mutation.

### `logic_tracks`

Use explicit indices or names. Track mutation fails closed when the target cannot be identified or read back.

Common commands: `create_audio`, `create_instrument`, `create_drummer`, `create_external_midi`, `select`, `rename`, `delete`, `duplicate`, `mute`, `solo`, `arm`, `set_instrument`, `record_sequence`, `get_regions`.

For Library patches, treat `presetsByCategory` as a browse/catalog view. Default `scan_library` uses the local filesystem catalog from the user Logic Library plus Logic Pro's app bundle, dedupes relative `.patch` candidates, and reports `candidatePatchCount` plus `nonApplicablePatchCount` when a file candidate has no Panel-taxonomy route. Before calling `set_instrument`, call `resolve_path` and require `exists: true`, `kind: "leaf"`, and `loadable: true`. Folder/category rows return `loadable: false` and `set_instrument` fails closed with `folder_not_preset` instead of treating a selected row as a loaded patch.

`record_sequence` writes a server-generated MIDI file under a private server-managed temp directory, imports it into Logic, and verifies the created region. If the import returns an unverified State B result, including GM Device / External MIDI lanes that can bounce silent, `record_sequence` fails closed with `audibility_unverified` or `import_unverified` instead of promoting region readback to audible success.

### `logic_mixer`

`set_volume` and `set_pan` use Accessibility write/readback against the visible strip. `set_master_volume` requires MCU. `set_output`, `set_input`, `set_send`, `toggle_eq`, and `reset_strip` are refused until their targets are deterministic.

Read `logic://mixer` before and after mixer mutations.

### `logic_plugins`

This is the verified apply-back surface.

Flow:

1. `get_inventory` reads the target track's plugin insert slots.
2. `insert_verified` inserts an allowlisted stock plugin into an explicit physical slot and verifies post-write inventory.
3. `logic_plugins.set_param_verified` writes a supported parameter and verifies readback.

Important constraints:

- `insert_verified` requires a confirmation gate named `duplicate_applyback` when the operation can mutate an existing session.
- `set_param_verified` currently verifies Compressor `threshold` only, normalized 0..100, tolerance 1.0.
- Arbitrary plugin parameters fail closed with `unsupported_param_readback`.
- The legacy Scripter `set_plugin_param` path is a legacy unverified State B path. Use `logic_plugins.set_param_verified` for verified apply-back.

Minimal `set_param_verified` shape:

```json
{
  "command": "set_param_verified",
  "track_index": 5,
  "insert_index": 6,
  "plugin_id": "logic.stock.effect.compressor",
  "parameter_id": "threshold",
  "normalized_value": 60,
  "project_expected_path": "/path/to/project.logicx"
}
```

### `logic_midi`

Common commands: `send_note`, `send_chord`, `send_cc`, `send_program_change`, `send_pitch_bend`, `send_aftertouch`, `play_sequence`, `import_file`, `list_ports`, `create_virtual_port`, `mmc_play`, `mmc_stop`, `mmc_locate`.

Channels are 1-based (`1..16`) to match Logic's UI.

`send_sysex` accepts `{ bytes: [Int] }` or `{ data: "F0 ... F7" }` and rejects payloads over 1024 bytes before routing to CoreMIDI.

### `logic_navigate`

Common commands: `goto_bar`, `goto_marker`, `create_marker`, `delete_marker`, `rename_marker`, `zoom_to_fit`, `set_zoom`, `toggle_view`.

`delete_marker` and indexed `goto_marker` require explicit indices. `rename_marker` is not implemented on Logic 12.x and returns State C `not_implemented`. `set_zoom` accepts `in`, `out`, `fit`, or integer levels `1..10` and uses the writable Accessibility zoom slider when present.

### `logic_project`

Common commands: `new`, `open`, `save`, `save_as`, `close`, `bounce`, `launch`, `quit`, `get_regions`, `export_plan`, `export_run`, `export_resume`, `audit`, `cleanup_plan`, `cleanup_apply`.

Destructive or file-writing paths require confirmation. `save_as` verifies the resulting `.logicx` package. `audit` marks GM Device / External MIDI tracks with MIDI regions as `external_midi_regions_bounce_risk` export blockers. `bounce` runs that preflight and returns `export_readiness_blocked` before opening the Bounce dialog when blockers are present. `export_plan` is read-only; `export_run` and `export_resume` re-plan, open, verify project identity, bounce, and verify artifacts via `logic_audio`.

### `logic_audio`

`analyze_file` inspects an existing audio artifact and reports duration, level, silence ratio, and verification status. It does not mutate Logic.

### `logic_system`

Use `health` for channel readiness and `help` for command summaries.

### Not-exposed commands

A few command tokens are recognised by the dispatchers but are deliberately **not part of the production MCP contract** (no deterministic / verified path exists yet). They are excluded from the workflow command census and return a single machine-classifiable State C shape — `error: "command_not_exposed"`, `not_exposed: true`, `supported: false`, plus the `operation` — so a complete-surface demo/test harness can classify them as *expected*, not a malfunction:

- `logic_tracks.set_color`
- `logic_mixer.set_send`, `logic_mixer.set_output`, `logic_mixer.set_input`, `logic_mixer.toggle_eq`, `logic_mixer.reset_strip`, `logic_mixer.bypass_plugin`

## Error Format

State C errors use stable machine-readable strings such as `invalid_params`, `not_implemented`, `command_not_exposed`, `index_out_of_range`, `element_not_found`, `readback_mismatch`, `port_unavailable`, `channels_exhausted`, `unsupported_param_readback`, and `confirmation_required`.

Clients should branch on `state`, `verified`, `error`, and `retry_safe`; do not parse human prose as the contract.
