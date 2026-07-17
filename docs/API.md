# API Reference

Current surface: Logic Pro MCP exposes 10 tools, 18 static resources, and 12 resource templates. The published stable release is v3.11.0. That release keeps the 10-tool / 18-resource / 11-template surface; the current source tree adds the read-only generated operation catalog. It includes the v3.9.0 MCP capability additions (resource subscriptions, workflow prompts, and per-tool `outputSchema` / `structuredContent`), keeps the v3.9.2 verified plugin closed-window fix, keeps v3.10.0 desktop/Creator Studio targeting, and adds the v3.11.0 Doctor, tempo, Bounce, region, marker, native toggle, and help-category fixes. `logic_midi` send-only successes and `logic_tracks.arm_only` return Honest Contract JSON envelopes (BREAKING response shape — see CHANGELOG).

Use tools for actions. Use resources for state. Treat every mutating result as one of:

- State A: confirmed success. The server wrote to Logic and independently read the result back.
- State B: uncertain success. The server attempted the action but could not verify the result.
- State C: hard failure. The action did not land and is safe to retry only when `retry_safe` says so.

## MCP Capabilities

`initialize` advertises `resources.subscribe: true`, `resources.listChanged: false`, `prompts.listChanged: false`, and `tools.listChanged: false`.

Resource subscriptions are session-scoped. `resources/subscribe` and `resources/unsubscribe` accept any listed resource URI or concrete resource-template URI. When a subscribed state resource changes, the server sends `notifications/resources/updated` with the changed `uri`. Change detection hashes the stable `data` payload of cache-envelope resources, or the whole payload for non-envelope resources, after recursively excluding volatile keys: `generated_at`, `fetched_at`, `cache_age_sec`, and `mcu_last_feedback_age_ms`.

`prompts/list` and `prompts/get` expose the workflow skill catalog as prompt templates. Prompt definitions are derived from `WorkflowSkillCatalog`, the same source used by `logic://workflow-skills`.

Every tool in `tools/list` advertises an `outputSchema`. Mixed command tools advertise the Honest Contract envelope for mutating commands: mutating commands return the Honest Contract envelope (`success`/`verified`/`state`, additional operation-specific keys); read-only commands return command-specific JSON objects. Honest Contract properties are non-required so read-only responses validate against the mixed-tool schema. Read-only/read-ish tools advertise a generic JSON object. For `tools/call`, when the text response is already a JSON object, the same object is also attached as `structuredContent`; the text payload is unchanged for backward compatibility.

## Tools

| Tool | Purpose |
|------|---------|
| `logic_transport` | play, stop, record, locate, tempo, cycle, metronome, count-in, autopunch |
| `logic_tracks` | create, select, rename, delete, duplicate, arm/arm_only, mute, solo, automation, set instrument, library scans |
| `logic_mixer` | volume, pan, master volume, mixer strip reads, guarded legacy plugin insertion |
| `logic_plugins` | verified stock-plugin inventory, exact-slot insertion, verified parameter write/readback |
| `logic_midi` | send notes/CC/SysEx/MMC, import MIDI, step input, create/list virtual ports |
| `logic_edit` | undo, redo, cut, copy, paste, quantize, split, join, bounce-in-place, normalize, duplicate |
| `logic_navigate` | bars, markers, zoom, view toggles |
| `logic_project` | new, open, save, save_as, close, bounce, launch/quit, is_running, regions, export plan/run/resume, audit, cleanup |
| `logic_audio` | read-only audio artifact analysis |
| `logic_system` | health, permissions, command help, trace list/read/clear, saga preflight/execute/status/cancel |

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

`logic://system/operations` (exact read-only catalog URI), `logic://tracks/{index}`, `logic://tracks/{index}/regions`, `logic://mixer/{strip}`,
`logic://stock-plugins/{id}`, `logic://stock-plugins/search?query={query}`,
`logic://stock-instruments/{id}`, `logic://stock-instruments/search?query={query}`,
`logic://session-players/{id}`, `logic://workflow-plans/session?prompt={prompt}`,
`logic://workflow-skills/{id}`, `logic://workflow-skills/search?query={query}`.

Registered operations reject unknown command-parameter keys at the runtime boundary by default, before cache access, mutation gates, or dispatcher invocation. The State C `invalid_params` response includes sorted `unknown_params` and `allowed_params`. Selector keys are operation-scoped: `target_ref` is recognized only when the operation's target policy is `requiresStableTarget`, while `index` and `track` appear only on operations whose dispatcher consumes those aliases. The exact per-operation set is published by `logic://system/operations`; `record_sequence` also preserves its ignored `instrument` / `instrument_path` inputs. Set `LOGIC_MCP_ADR003_STRICT_PARAMS=0` only as a temporary compatibility escape hatch for registered-command parameter pass-through; it does not expose unregistered commands or dispatcher-only aliases.

### Track state values (`logic://tracks`)

Since v3.8.0, `logic://tracks` reports each track's `volume`, `pan`, and `automationMode` as REAL values read from the live track header (the same AX fader the mixer write path drives). These three were previously fabricated (`0.0` / `0.0` / `off`) by the production builder. The correction is **value-only** — the `TrackState` keys and types are unchanged (no new field, sentinel, or nullable), so existing parsers are unaffected. On a rare AX-read failure a field falls back to its former default, and the envelope's `source` / `ax_occluded` fields already flag degraded reads.

Track objects do **not** carry a sample rate. Sample rate is a project/transport-level value exposed on `logic://project/info`, which still falls back to a fabricated `44100` default when a live transport sample-rate is unavailable (documented limitation).

## Command Notes

### `logic_transport`

| Command | Params | Result | Route |
|---------|--------|--------|-------|
| `play`, `record` | none | text / contract envelope | Accessibility -> MCU -> CoreMIDI -> CGEvent -> AppleScript |
| `stop` | none | text / contract envelope | CGEvent -> Accessibility -> MCU -> CoreMIDI -> AppleScript |
| `pause`, `rewind`, `fast_forward` | none | text / contract envelope | routed transport fallback chain |
| `toggle_cycle` | — | text | Accessibility → MIDIKeyCommands → CGEvent → MCU |
| `toggle_count_in` | — | text / contract envelope | routed transport fallback chain |
| `toggle_autopunch` | — | State A/B/C contract envelope | Accessibility |
| `set_cycle_range` | `{ start, end }` | fails closed: current Logic builds expose no verifiable numeric cycle-locator automation path, so it returns State C (`not_implemented` / `readback_unavailable`) rather than claim an unverified success | Accessibility (attempted) |
| `set_tempo` | `{ tempo: number }` (5–999, matches Logic's actual accepted range) | text | Accessibility |
| `goto_position` | `{ bar: number }` or `{ position: string }` | text / contract envelope | Accessibility -> MIDIKeyCommands -> MMC |

Read current state from `logic://transport/state` after any transport mutation.

### `logic_tracks`

Use explicit indices or names. Track mutation fails closed when the target cannot be identified or read back.

Common commands: `select`, `create_audio`, `create_instrument`, `create_drummer`, `create_external_midi`, `delete`, `duplicate`, `rename`, `mute`, `solo`, `arm`, `arm_only`, `record_sequence`, `set_automation`, `set_instrument`, `list_library`, `scan_library`, `resolve_path`, `scan_plugin_presets`.

`set_automation` is State B (MCU write, no readback echo).

For Library patches, treat `presetsByCategory` as a browse/catalog view. Default `scan_library` uses the local filesystem catalog from the user Logic Library plus Logic Pro's app bundle, dedupes relative `.patch` candidates, and reports `candidatePatchCount` plus `nonApplicablePatchCount` when a file candidate has no Panel-taxonomy route. Before calling `set_instrument`, call `resolve_path` and require `exists: true`, `kind: "leaf"`, and `loadable: true`. Folder/category rows return `loadable: false` and `set_instrument` fails closed with `folder_not_preset` instead of treating a selected row as a loaded patch.

`record_sequence` writes a server-generated MIDI file under a private server-managed temp directory, imports it into Logic, and verifies the created region. If the import returns an unverified State B result, including GM Device / External MIDI lanes that can bounce silent, `record_sequence` fails closed with `audibility_unverified` or `import_unverified` instead of promoting region readback to audible success.

### `logic_mixer`

Public commands: `set_volume`, `set_pan`, `set_master_volume`, `set_plugin_param`, `insert_plugin`.

`set_volume` and `set_pan` use Accessibility write/readback against the visible strip. `set_master_volume` requires MCU. `set_output`, `set_input`, `set_send`, `toggle_eq`, `reset_strip`, and `bypass_plugin` are recognized only to return State C `command_not_exposed` until their targets are deterministic.

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
- `set_param_verified` can open the target insert's plugin editor when it is closed, but it writes only after the requested AX slider is present in the acquired window.
- Arbitrary plugin parameters fail closed with `unsupported_param_readback`.
- The legacy Scripter `set_plugin_param` path is a legacy unverified State B path. Use `logic_plugins.set_param_verified` for verified apply-back.

Minimal `set_param_verified` shape:

```json
{
  "command": "set_param_verified",
  "track": 5,
  "insert": 6,
  "plugin": "logic.stock.effect.compressor",
  "param": "threshold",
  "value": 60,
  "unit": "normalized",
  "mode": "duplicate_applyback",
  "project_expected_path": "/path/to/project.logicx"
}
```

### `logic_midi`

Common commands: `send_note`, `send_chord`, `send_cc`, `send_program_change`, `send_pitch_bend`, `send_aftertouch`, `send_sysex`, `play_sequence`, `import_file`, `list_ports`, `create_virtual_port`, `step_input`, `mmc_play`, `mmc_stop`, `mmc_record`, `mmc_locate`.

Channels are 1-based (`1..16`) to match Logic's UI.

`send_sysex` accepts `{ bytes: [Int] }` or `{ data: "F0 ... F7" }` and rejects payloads over 1024 bytes before routing to CoreMIDI.

Send-only success responses return an Honest Contract State B JSON envelope because CoreMIDI/MMC writes have no deterministic readback:

```json
{
  "success": true,
  "verified": false,
  "state": "B",
  "reason": "send_only_no_readback",
  "operation": "midi.send_note",
  "legacy_message": "Note 60 on ch 0 vel 100 dur 30ms",
  "note": 60,
  "velocity": 100,
  "channel_wire": 0,
  "duration_ms": 30,
  "message_count": 2
}
```

`mmc_locate` with a `bar` parameter is the exception: it routes through `transport.goto_position` and keeps the transport readback contract. Time-based `mmc_locate` remains send-only State B.

`create_virtual_port` reuses same-name/same-mode ports. Reusing a name across modes fails closed with State C `port_unavailable` and includes `port_name`, `existing_mode`, and `requested_mode`.

No MIDI read-back command is shipped in v3.11.0: `read_selection_notes` and `record_sequence verify_notes` are deferred.

### `logic_edit`

Common commands: `undo`, `redo`, `cut`, `copy`, `paste`, `delete`, `select_all`, `split`, `join`, `quantize`, `bounce_in_place`, `normalize`, `duplicate`, `toggle_step_input`.

`quantize` requires `{ value: String }` or `{ grid: String }` and accepts the dispatcher grids `1/1`, `1/2`, `1/4`, `1/8`, `1/16`, `1/32`, `1/64`, `1/4T`, `1/8T`, and `1/16T`.

### `logic_navigate`

Common commands: `goto_bar`, `goto_marker`, `create_marker`, `delete_marker`, `rename_marker`, `zoom_to_fit`, `set_zoom`, `toggle_view`.

`delete_marker` and indexed `goto_marker` require explicit indices. `rename_marker` is not implemented on Logic 12.x and returns State C `not_implemented`. `set_zoom` accepts `in`, `out`, `fit`, or integer levels `1..10` and uses the writable Accessibility zoom slider when present.

### `logic_project`

Common commands: `new`, `open`, `save`, `save_as`, `close`, `bounce`, `is_running`, `launch`, `quit`, `get_regions`, `export_plan`, `export_run`, `export_resume`, `audit`, `cleanup_plan`, `cleanup_apply`.

Destructive or file-writing paths require confirmation. `save_as` verifies the resulting `.logicx` package. `audit` marks GM Device / External MIDI tracks with MIDI regions as `external_midi_regions_bounce_risk` export blockers. `bounce` runs that preflight, then opens and verifies Logic's native File > Bounce dialog; the caller completes the settings and destination in Logic. It returns `export_readiness_blocked` before opening the dialog when blockers are present. `export_plan` is read-only; `export_run` and `export_resume` re-plan, open, verify project identity, bounce, and verify artifacts via `logic_audio`.

`get_regions` returns `{ regions, complete, scope, reason, returned_count, _debug }`. Logic's AX tree currently exposes the visible arrange viewport only, so the response reports `complete:false`, `scope:"visible_arrange_area"`, and `reason:"logic_ax_viewport_only"`; callers must not treat `regions` as a project-wide inventory. Project audit preserves that limitation as `ax_visible_subset`, emits `region_inventory_partial`, and withholds empty-track claims for unseen lanes.

### `logic_audio`

`analyze_file` inspects an existing audio artifact and reports duration, level, silence ratio, and verification status. It does not mutate Logic.

### `logic_system`

Common commands: `health`, `permissions`, `refresh_cache`, `export_support_bundle`, `list_recent_traces`, `get_trace`, `clear_traces`, `saga_preflight`, `saga_execute`, `saga_status`, `saga_cancel`, `help`.

Use `health` for channel readiness and `help` for command summaries. `help` accepts category `all`, `transport`, `tracks`, `mixer`, `midi`, `edit`, `navigate`, `project`, `audio`, `plugins`, or `system`.

With `LOGIC_MCP_ADR005_OPERATION_TRACE=1`, `list_recent_traces` returns bounded summaries from the in-process trace store and accepts optional `limit`.
`get_trace` returns one stored trace by required `trace_id`.
`clear_traces` clears only the in-process trace store and requires `confirmed:true` because it destroys in-session diagnostic evidence.

`saga_preflight` and `saga_execute` accept `{ steps: [step], idempotency_key: String }`; each step contains `operation_id`, optional `target_ref`, `params`, and `expected_inverse`. Preflight performs no Logic writes and reports per-step before-state availability. Execute reports verified per-step evidence; a failed request remains State C even when every applied step is compensated, while partial or unknown compensation is State B.

The bounded journal belongs only to the current server session and is cleared on session end or process restart. A completed duplicate key returns its stored outcome with `duplicate:true`; `saga_status` reads that record. `saga_cancel` returns a typed refusal for active work because the current engine has no safe cancellation seam. Ordered work with compensation does not promise all-or-nothing completion or durable recovery.

The journal keeps two independently bounded tiers, so pressure costs stored evidence rather than safety:

- **Replay protection (whole session).** Every `idempotency_key` begun in a session stays recorded for that whole session. A key that reached a terminal state never starts again — replay protection does not lapse, expire, or time out. There is no wall-clock TTL.
- **Outcome bodies (most recent N).** Full stored outcomes are retained for the most recent `journal_record_capacity` sagas (default 1024). Under insertion pressure the oldest terminal body is dropped; in-flight sagas are never dropped.

Retrying an older completed saga whose body was dropped returns `saga_outcome_unavailable` (State C, terminal) instead of the original body — never a re-execution. It carries `terminal_kind` (`completed` or `cancelled`), `outcome_retained:false`, `safe_to_retry:false`, and `write_attempted:false`. `terminal_kind` names only which path the saga terminated on; it is **not** a claim that the intent succeeded (a `completed` saga may have applied only partially). Reconcile by observing current state via `saga_status` or the relevant read operations — do not re-fire the same intent blindly. `saga_status` for such a key still reports its terminal `status` with `outcome_retained:false` and no `outcome`.

`saga_journal_capacity_exceeded` remains distinct and unchanged in meaning: the journal cannot admit a **new** key. It is returned under either of two conditions — the session's replay-protection tier (`journal_compact_capacity`, default 65536) is full, or the outcome tier is fully occupied by in-flight sagas and therefore holds no terminal body that can be reclaimed. Both stay fail-closed: admitting a key the session cannot replay-protect, or evicting a saga still running, would be a correctness hole rather than an availability one.

`saga_status` and `saga_preflight` publish `journal_full_body_count`, `journal_compact_count`, `journal_body_evictions`, `journal_compact_capacity`, and `journal_record_capacity` for operators. These are diagnostics only — none of them promises that a later retry will fit, and `journal_survives_process_restart` stays `false`.

### Not-exposed commands

A few command tokens are recognised by the dispatchers but are deliberately **not part of the production MCP contract** (no deterministic / verified path exists yet). They are excluded from the workflow command census and return a single machine-classifiable State C shape — `error: "command_not_exposed"`, `not_exposed: true`, `supported: false`, plus the `operation` — so a complete-surface demo/test harness can classify them as *expected*, not a malfunction:

- `logic_tracks.set_color`
- `logic_mixer.set_send`, `logic_mixer.set_output`, `logic_mixer.set_input`, `logic_mixer.toggle_eq`, `logic_mixer.reset_strip`, `logic_mixer.bypass_plugin`

## Error Format

State C errors use stable machine-readable strings such as `invalid_params`, `not_implemented`, `command_not_exposed`, `index_out_of_range`, `element_not_found`, `readback_mismatch`, `port_unavailable`, `channels_exhausted`, `unsupported_param_readback`, and `confirmation_required`.

Clients should branch on `state`, `verified`, `error`, and `retry_safe`; do not parse human prose as the contract.
