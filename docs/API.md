# API Reference

Current surface: Logic Pro MCP exposes 10 tools, 18 static resources, and 12 resource templates. What each release changed, including every breaking response shape, is in [CHANGELOG.md](../CHANGELOG.md); this page describes the surface, not its history.

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
| `logic_mixer` | volume, pan, master volume, mixer strip reads, guarded legacy plugin insertion, verified output assignment |
| `logic_plugins` | verified stock-plugin inventory, exact-slot insertion, verified parameter write/readback |
| `logic_midi` | send notes/CC/SysEx/MMC, import MIDI, step input, create/list virtual ports |
| `logic_edit` | undo, redo, cut, copy, paste, quantize, split, join, bounce-in-place, normalize, duplicate |
| `logic_navigate` | bars, markers, zoom, view toggles |
| `logic_project` | new, open, save, save_as, close, bounce, launch/quit, is_running, regions, export plan/run/resume, audit, cleanup |
| `logic_audio` | read-only audio artifact analysis |
| `logic_system` | health, permissions, command help, arm key-command auto-setup, trace list/read/clear, saga preflight/execute/status/cancel |

### Rich tool schemas (opt-in, #957)

By default every tool takes `{command, params}` with `params` an open object. A server started with `LOGIC_MCP_TOOL_SCHEMA=rich` lists a richer input schema for each tool instead. `command` gains an `enum` of the tool's commands. The schema gains a top-level `oneOf` with one branch per command: the branch fixes `command` with `const` and names that command's parameters under `params`. A branch sets `additionalProperties: false` only where the server refuses an unknown parameter, that is, with strict parameter checking on (the default; `LOGIC_MCP_ADR003_STRICT_PARAMS=0` turns it off) and for every operation except the saga commands. Each branch's `description` carries the registry's mutability, confirmation, target, verification, retry and availability words. Any other value of the variable, or none, lists the legacy shape.

The schema is derived from the operation registry, the same source the generic parameter-key check reads; it adds no enforcement. It describes parameter keys only. Values, types and required keys are checked by each command's dispatcher and are not in the registry, so the schema admits requests the dispatcher refuses, such as `goto_position` with no `bar` or `position`. The keys a dispatcher always refuses with its own error (the eleven in `dispatcherRejectedParamsByOperation`) are not listed. Claude Code 2.1.283 listed every tool from the rich schema and called one with schema-conforming input (2026-10-03). Some clients refuse a top-level combinator; they are not measured, so keep them on the default. `docs/COMMAND-PARAMETERS.md` is a table generated from the same registry: `LPM_WRITE_GENERATED_DOCS=1 swift test --filter Issue957` rewrites it, and a test fails when it differs.

## Resources

| Resource | Returns |
|----------|---------|
| `logic://system/health` | channel readiness, permissions, manual-validation state |
| `logic://transport/state` | tempo, position, cycle, play/record state |
| `logic://tracks` | track list with source/freshness metadata |
| `logic://mixer` | mixer strips (with per-strip `send_slots` occupancy), plugin slots, data-source labels, and the read-only `routing_graph` (#291): `trk_` source nodes carrying `output_classification` (`physical_output` / `bus` / `no_output` / `unclassified`), `bus_<n>` nodes and `mainOutput` edges only for a source whose own output slot reads as a bus, no send edges, a `snapshot_id` identifying its capture (separate resource and inspection reads have different IDs; resource graph IDs are not retained inspection-report handles), and `coverage` per domain (`population`, `strip_track_association`, `main_output`, `physical_output`, `bus_to_aux_input`, `sends`: `complete` / `partial` / `unavailable` / `unstable` / `not_observed` with `reasons`); `complete` is true only when every domain is, which no graph is in this increment |
| `logic://markers` | marker list when Logic exposes it |
| `logic://project/info` | project name (the document's own name, without Logic's localized ` - Tracks` window suffix)/path, tempo, sample rate, track count |
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

Registered operations reject unknown command-parameter keys at the runtime boundary by default, before cache access, mutation gates, or dispatcher invocation. The State C `invalid_params` response includes sorted `unknown_params` and `allowed_params`. Selector keys are operation-scoped: `target_ref` is recognized only when the operation's target policy is `accepts_stable_target`, while `index` and `track` appear only on operations whose dispatcher consumes those aliases. `expected_name` is recognized only on the `corroborated` index-binding tier (see [Index binding](#index-binding)). The exact per-operation set is published by `logic://system/operations`; `record_sequence` also preserves its ignored `instrument` / `instrument_path` inputs. Set `LOGIC_MCP_ADR003_STRICT_PARAMS=0` only as a temporary compatibility escape hatch for registered-command parameter pass-through; it does not expose unregistered commands or dispatcher-only aliases.

### Index binding

A track index is an **ordinal, not an identity**. Between the moment you read `logic://tracks` and the moment your write lands, a drag, a track creation, or a folder collapse can shift every row — and an index-keyed write then lands on a track you never named. `target_ref` (ADR-002) solves this by binding to a session-stable identity. It is accepted **by default** — set `LOGIC_MCP_ADR002_TARGET_REF=0` to disable the machinery, after which any supplied `target_ref` fails closed with `target_ref_unavailable`. But the server being willing to accept a `target_ref` does not make callers send one: the bare-index path stays open, so the registry declares what each operation demands of a **bare index** on a second, orthogonal axis: `index_binding`, published per-operation by `logic://system/operations`.

The field is present only on operations that are both target-bearing (`target` = `accepts_stable_target`) and mutating — the only ones with an index path that can hit a wrong target. Read-only and non-target operations omit it entirely rather than publishing a null.

| Tier | Meaning | Today |
| --- | --- | --- |
| `ref_required` | A bare index is refused; only `target_ref` binds. | **No operations.** Implemented and tested; the first promotion is a registry row flip and will appear as a catalog diff. |
| `corroborated` | A bare index must be corroborated by `expected_name`. | `tracks.delete`, `tracks.duplicate`, `tracks.set_instrument`, `plugins.insert_verified` |
| `legacy_index_allowed` | The historical unguarded index path. | **Deprecated** — see below. |

#### The corroboration contract

For a `corroborated` operation called **without** `target_ref`, supply `expected_name`: the track name you believe sits at the index. (It is not spelled `name` because several of these operations already spend `name` on an operand — `tracks.rename`'s new name, `tracks.select`'s by-name selector.) The server then reads the **live** track header before writing — never the state cache, which lags an out-of-band reorder by the poll interval and would therefore agree with exactly the stale view being defended against.

Every failure below is fail-closed and **pre-write**: `write_attempted: false` is a fact, not a claim — the operation returns before anything is routed.

| Condition | State C error | `safe_to_retry` |
| --- | --- | --- |
| No `expected_name` and no `target_ref` | `index_binding_corroboration_required` | `true` — supply either binding |
| Live name at the index ≠ `expected_name` | `target_identity_mismatch` (`reason: name_mismatch`) | `false` — re-read `logic://tracks` first |
| Live header unreadable | `target_identity_mismatch` (`reason: header_unreadable`) | `false` — an unreadable surface is never read as agreement |
| `expected_name` matches but names >1 live track | `ambiguous_target_name` (`ambiguous_track_indices` lists all colliding indices) | `false` — use `target_ref` |
| `expected_name` **and** `target_ref` both supplied | `invalid_params` | `true` — send exactly one binding |

Uniqueness is not a nicety. Two tracks sharing a name can swap positions and leave `(index, name)` self-consistent at **both** ordinals, so a match would prove nothing; `target_ref` is the only binding a swap cannot fool. Supplying `target_ref` bypasses this path entirely — the reference machinery carries its own live-identity and ambiguity checks, and the two are never stacked.

**Corroboration is a pre-write proof, not atomic with the write.** It reads the live header, then writes; a reorder that lands in that narrow guard-to-write interval can still put the write on the wrong track. Corroboration *narrows* the wrong-target window (from "any time since your last read" down to "the guard-to-write interval"); it does not eliminate it. Only `target_ref` — and the future `ref_required` tier — bind an identity that holds across the write and close the window entirely. Prefer `target_ref` when wrong-target cost is high.

`expected_name` is a binding proof, not a write parameter: it is never forwarded to the channel, and a matching, unique corroboration leaves the existing index write path completely unchanged.

#### Deprecation: `legacy_index_allowed`

This tier is the pre-ratchet behaviour and is **deprecated**. Its members still write to a bare, unproven ordinal; each remains only because a wrong-target write there is *recoverable* (`mixer.set_volume`, `mixer.set_pan`, `plugins.set_param_verified`, `tracks.select`, `tracks.rename`, `tracks.mute`, `tracks.solo`, `tracks.arm`, `tracks.arm_only`, `tracks.set_automation`). The set is pinned by census and may only shrink. Prefer `target_ref` on these operations today; do not build on the assumption that a bare index will keep being accepted.

A gap is tracked rather than papered over: two mutating operations key on a track strip yet carry target policy `none` — **`mixer.insert_plugin`** (irreversible insert) and **`mixer.set_plugin_param`** (reversible param write). Because they accept no `target_ref`, the corroboration refusal could not honestly offer one as an alternative, so neither carries a tier. Ratcheting either requires first making it target-bearing (`insert_plugin` would then become `corroborated`; `set_plugin_param`, being reversible, `legacy_index_allowed`).

This exact set is pinned by census — it may only shrink, and any new operation added to the class fails CI until an explicit decision is made. The census discriminator is: **mutating**, target policy **`none`**, and carrying a track-strip selector (`track` or `track_index`). The bare `index` alias is deliberately *not* part of the discriminator: the operations that take `index` without a track-strip selector are the marker operations (`navigate.goto_marker`, `navigate.delete_marker`, `navigate.rename_marker`), whose `index` addresses a marker, not a track — a different wrong-target class that ADR-002 index binding does not cover.

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

**`delete`, `duplicate`, and `set_instrument` no longer accept a bare index.** They are `corroborated` (see [Index binding](#index-binding)): pass `expected_name` (the track name you expect at that index) or `target_ref`. Without one, they fail closed with `index_binding_corroboration_required` and write nothing.

`set_automation` on MCU reads the track header's automation mode through Accessibility first and sends nothing when it already equals `mode` (State A, `write_attempted: false`). Otherwise it presses the strip's Select and presses the mode button only once the selection reads back as that track; a selection that reads as another track, or does not read, is State B `readback_mismatch` / `readback_unavailable` with `automation_write_attempted: false`. After the mode press it polls up to ten times at 50 ms, and each poll reads the mode and then Logic's modal set (#1077). Logic answered the Write press with a one-button warning and left it up, and quitting Logic under it crashed Logic in 4 of 4 runs (measured on a German Logic), so the poll clears a one-button informational alert or a stray open menu through the same reconciler the operation preflight uses, at most once per kind. The limit binds the kind actually pressed: the reconciler reads again before it acts, and a kind already acted on that this read finds is reported, not pressed again. A dialog with more than one button, a New Track sheet or any other sheet is reported and nothing in it is pressed. The poll stops early only when the mode reads as requested and two consecutive complete reads found no blocker. `modal_after_press` is what the last read found: `clear`, `open` (a blocker is still up: State B `modal_left_open` whatever the mode read) or `unreadable` (the read could not establish the set: State B `readback_unavailable` even when the mode matched). `reconciled_modal_kind` names the last blocker any read saw, and keeps naming it whatever the reads after it found, clean or unreadable; `reconciled_action` and `modal_reconciliation_witness` say what was done about that kind, and `reconciled_action` is `none` when nothing pressed it. So a reply after an acknowledged warning carries `modal_after_press: "clear"` beside `reconciled_modal_kind: "informational_alert"`, and a warning seen once before every later read failed carries `modal_after_press: "unreadable"` beside `reconciled_modal_kind: "informational_alert"` and `reconciled_action: "none"`. A mode that reads as requested with the set clear is State A with `observed_mode`; one that reads otherwise is State B `readback_mismatch`, and one that does not read is State B `readback_unavailable`.

`mute`, `solo` and `arm` route Accessibility → MCU → CGEvent. On the MCU rung the Mackie Control Mute / Solo / Rec buttons toggle on a press, so the handler is a set only by reading first (#1020): it reads the track header's button through Accessibility (the same `AXValue` the Accessibility rung reads, `verification_source: ax_value`), sends nothing when that state already equals `enabled` (State A, `write_attempted: false`, `observed`), and otherwise sends one press with its release and polls the same read up to ten times at 50 ms. The read showing `enabled` is State A with `write_attempted: true` and `write_source: mcu`; still the old value is State B `readback_mismatch`, unreadable after the press is State B `readback_unavailable`, both with `write_attempted: true`, `observed` (null when unreadable) and no second press. When the state cannot be read before the press the handler sends nothing and answers State C `track_state_unreadable` with `write_attempted: false`; that code is not terminal, so the router moves on to the next channel. `enabled: false` takes the same path (it used to send a bare release, which Logic ignores). `select` on MCU is unchanged: one press, State B `readback_unavailable` (`verification_source: mcu_led_echo`).

Every strip-relative MCU write (`mute`, `solo`, `arm`, `select` and `set_automation` on the MCU rung, and the mixer's `set_volume` / `set_pan`) addresses a strip index, which names a track only relative to the bank Logic is showing. For a track outside the bank the server last placed, the handler walks the bank one step at a time, each step measured as `mixer.bank` measures it (one press, then a quiescent LCD upper-row redraw to a different row), and presses the strip only when every step toward its bank moved (#1020). A step that does not move stops the walk: the strip is not pressed, the steps that moved are walked back, and the answer is State C `bank_walk_unverified` with `write_attempted: false`, `bank_presses_sent`, `banks_moved`, `banks_requested`, `bank_restored`, `step_windows`, `bank_bookkeeping_after`, `operation` and `channel: "MCU"`. With no LCD upper row received yet the same refusal comes with nothing sent. `bank_walk_unverified` is not terminal, so the router moves on to the next channel. When the walk succeeds, the write's own reply carries the same bank fields, and `bank_restored: false` says the walk home stopped at a step that did not move. A track in the bank the server already counts as showing is written with no bank press and no bank reading.

When a bank-right step moves but the LCD upper row, read as eight 7-character cells, may be the old row slid by fewer than eight strips (Logic stops the last bank at the last strip, so with 21 strips the second bank-right press shows strips 13-20; repeated names can look the same), one probe settles it: Logic clamps only the last right step, so one more Bank Right that still moves the row proves the step moved a full eight, and a Bank Left must then redraw that step's row byte for byte before the walk continues. `bank_steps_disambiguated` counts the steps a probe proved; probe presses count in `bank_presses_sent`, not in `banks_moved`. A probe that redraws the same row (Logic's last bank) stops the walk, walks back and refuses `bank_walk_unverified` with `bank_step_short_of_eight: true`; a probe that reads back as neither refuses the same way with `bank_probe_unresolved: true`. A row longer than 56 characters is not provable and a bank-left step is never probed. `mixer.bank` probes the same way; after it makes a step the probe did not prove full, strip-relative MCU writes refuse `bank_walk_unverified` with nothing sent and `bank_window_unaligned: true` while the counter is off bank 0, until a `mixer.bank` left walk ends on an unchanged redraw at bank 0. Through the router, `track.set_arm`'s refusal surfaces as State C `channels_exhausted` with the keyboard channel's `last_error`, not the MCU's code, because the keyboard rung answers last.

For Library patches, treat `presetsByCategory` as a browse/catalog view. Default `scan_library` uses the local filesystem catalog from the user Logic Library plus Logic Pro's app bundle, dedupes relative `.patch` candidates, and reports `candidatePatchCount` plus `nonApplicablePatchCount` when a file candidate has no Panel-taxonomy route. Before calling `set_instrument`, call `resolve_path` and require `exists: true`, `kind: "leaf"`, and `loadable: true`. Folder/category rows return `loadable: false` and `set_instrument` fails closed with `folder_not_preset` instead of treating a selected row as a loaded patch.

`record_sequence` writes a server-generated MIDI file under a private server-managed temp directory, imports it into Logic, and verifies the created region. If the import returns an unverified State B result, including GM Device / External MIDI lanes that can bounce silent, `record_sequence` fails closed with `audibility_unverified` or `import_unverified` instead of promoting region readback to audible success.

### `logic_mixer`

Public commands: `set_volume`, `set_pan`, `set_master_volume`, `set_plugin_param`, `insert_plugin`, `bank`, `set_output_verified`.

`set_volume` and `set_pan` use Accessibility write/readback against the visible strip. They move the track-header slider by ~10-raw-unit detents, then by at most one detent of `AXValue` writes toward the whole raw position nearest the request (#973; one raw unit per write was measured on Logic 12.3.1 en-US, not promised for every build). `reached_exact` says whether it landed on that position; `fine_steps` counts accepted `AXValue` write calls, not necessarily movement; `verified` still means within the detent tolerance. A fine write that moves the slider further from the target returns State B `readback_mismatch` with `reason_detail` and leaves it there, including when the read after the fine phase fails and `observed_raw` is null. `write_method` stays `ax_increment_decrement`, the identifier of the detent path. `set_master_volume` requires MCU. `set_output`, `set_input`, `set_send`, `toggle_eq`, `reset_strip`, and `bypass_plugin` are recognized only to return State C `command_not_exposed` until their targets are deterministic.

`bank` moves the Mackie Control fader bank by eight strips per step: `{ direction: "left" | "right", count?: Int }` (`count` 1–31, default 1), MCU only. Its readback is the MCU LCD upper row, the 56-character line that names the eight visible strips. The move is made one step at a time: for each of `count` steps the server snapshots the upper row, sends one press, and polls until the row is redrawn and holds still. A step moved when a fresh upper-row write arrived after that press, the row then held still for one more poll, AND the row differs from that step's snapshot; the press having been sent never counts. Two presses sent back to back moved Logic 12.3 one bank, so presses are never batched. The walk stops at the first step that did not move, and no further press is sent. Every reply the `mixer.bank` handler gives carries `banks_moved` (steps witnessed), `bank_presses_sent` (presses actually sent) and `step_windows` (the row after each step sent), including its `invalid_params` refusal; every reply after the parameters parse also carries `banks_requested` (`count`); the router's `channels_exhausted` refusal described below comes before the handler runs and carries none of them. State A (`verify_source: mcu_lcd_upper_row`, with `window_before`, `window_after`, `strips`) means every one of the `count` presses produced its own redraw to a different row. It still does not say which bank is showing, and a row that changes for another reason in the same interval (a rename, Logic re-banking on selection) reads the same. When no step moved, State B `noop_unobservable` means the row redrew unchanged (identical six-character names cannot confirm a move) and State B `echo_timeout_<ms>ms` means no upper-row write arrived within the MCU echo timeout. When some steps moved and then one did not, the answer is State B with the moves counted: `readback_mismatch` with a `surface_limitation` when the stopping step redrew unchanged (the end of the mixer in that direction), `echo_timeout_<ms>ms` when it did not redraw. A cold start has two answers, and neither sends a byte. With no MCU feedback received yet, the shared channel-router health gate refuses the call before the handler runs, as it refuses every MCU operation: State C `channels_exhausted`, with `last_error` saying MCU feedback was not detected. With feedback received but no LCD upper row yet (for example a surface that has drawn only the lower row), the handler refuses: State C `readback_unavailable` with `write_attempted: false`, `bank_presses_sent: 0`, `banks_moved: 0`, `banks_requested` equal to the requested `count`, and `step_windows: []`. Each bank step is sent as a button press followed by its release, so Logic sees one momentary press per step rather than a held bank button. `bank_bookkeeping_before` / `bank_bookkeeping_after` carry the server's own bank counter. It moves by `banks_moved` only, and Logic's re-banking on track selection can leave it stale; the reply exposes that drift, it does not correct it.

`set_output_verified` sets one strip's output to one exact destination and reads it back from the same strip (#291 R2). It takes `track` (index) or `target_ref`, a `destination` of `{kind:"bus", number:N}` (1–256), `{kind:"physical", ports:[a,b]}` (two ascending port numbers), or `{kind:"stereo_output"}`, and an optional `expected_current` of the same shape or `{kind:"no_output"}`. `no_output` is refused as a destination (`invalid_params`): a strip set to No Output was measured to open no output menu, so this command could not set it back. No parameter is a localized label, and an unknown key is refused. Before anything is pressed it refuses with State C when the reference does not resolve; when the strip's current output does not read or does not classify (`readback_unavailable`: unreadable is not absent), or reads No Output (`unsupported_state`); when `expected_current` differs from it (`stale_snapshot`); when the transport is playing or recording (`unsupported_state`) or its state does not read (`transport_state_unknown`); when the strip reads a bus as its input and the destination bus reaches that bus, itself or through the outputs of the strips that receive it (`routing_cycle`); when a strip that check has to follow does not say where its signal goes: its input, output or sends did not read, or it has an occupied send, whose destination is not read (`routing_dependency_unknown`); when a bus destination has no receiver, i.e. no other strip reads that bus as its input (`bus_has_no_receiver`: Logic would create an aux, and creating one belongs to #967); and when a Logic popup menu is already open. A destination already in place is State A with `changed: false` and nothing pressed. Otherwise it presses that strip's output slot, takes the one popup that opened under the Mixer, and chooses the entry under the submenu that owns it: the buses under Bus, `Stereo Output` and the pairs under Output. The root's checked entry only echoes the current output and is never pressed. For a bus, the loop and receiver checks are made again from the Mixer's strips with the popup open, right before the entry is pressed: a strip that changed meanwhile refuses the same way, and a strip count that moved or a Mixer child that did not read refuses `unsupported_state` with `strip_count_at_press` (an ordinal names the same strip only while the count holds); each carries `read_with_popup_open: true`, and nothing is selected. AX has no compare-and-press, so a change after that read is seen only afterwards, as a strip count that moved. A destination the popup does not offer is refused with `element_not_found` and `offered`, one offered twice under one parent with `ambiguous_target_name`, and a menu whose entries' titles or submenus do not all read with `element_not_found` and `menu_failure: "menu_not_read"`, since an entry that did not read could be the destination or a second copy of it; none is pressed. The popup is closed and `popup_menu_state` says what was measured. State A requires the same strip, found again at the same ordinal after the press (Logic replaces a strip's elements when its output changes), to read back the destination, and the Mixer's strip count not to move. A count that grew is State C `unexpected_side_effect: "strip_created"` and nothing is cleaned up; an after-read that fails or disagrees is State B (`readback_unavailable` / `readback_mismatch`), and dependent writes should stop. Logic adds a Mixer strip for an output pair that no strip used before, and removes it once no strip uses the pair (measured in ko and de), so a move onto or off such a pair answers State C (`strip_created` / `strip_removed`) although the output did change; re-read `logic://mixer` to see it. Every reply carries the observed `before`; to restore, call again with `destination` set to it and `expected_current` set to the new value. That call is checked like any other, so it can be refused (the old bus with no other strip reading it any more is `bus_has_no_receiver`) or end in State C when the strip count moves (a physical pair no strip used before). `set_output` stays not-exposed.

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

No MIDI read-back command is shipped: `read_selection_notes` and `record_sequence verify_notes` remain deferred.

### `logic_edit`

Common commands: `undo`, `redo`, `cut`, `copy`, `paste`, `delete`, `select_all`, `split`, `join`, `quantize`, `bounce_in_place`, `normalize`, `duplicate`, `toggle_step_input`.

`quantize` requires `{ value: String }` or `{ grid: String }` and accepts the dispatcher grids `1/1`, `1/2`, `1/4`, `1/8`, `1/16`, `1/32`, `1/64`, `1/4T`, `1/8T`, and `1/16T`.

### `logic_navigate`

Common commands: `goto_bar`, `goto_marker`, `create_marker`, `delete_marker`, `rename_marker`, `zoom_to_fit`, `set_zoom`, `toggle_view`.

`delete_marker` and indexed `goto_marker` require explicit indices. `rename_marker` is not implemented on Logic 12.x and returns State C `not_implemented`. `set_zoom` accepts `in`, `out`, `fit`, or integer levels `1..10` and uses the writable Accessibility zoom slider when present.

### `logic_project`

Common commands: `new`, `open`, `save`, `save_as`, `close`, `bounce`, `is_running`, `launch`, `quit`, `get_regions`, `export_plan`, `export_run`, `export_resume`, `audit`, `cleanup_plan`, `inspect_session`, `plan_session_repair`, `cleanup_apply`.

Destructive or file-writing paths require confirmation. `save_as` verifies the resulting `.logicx` package. `audit` marks GM Device / External MIDI tracks with MIDI regions as `external_midi_regions_bounce_risk` export blockers. `bounce` runs that preflight, then opens and verifies Logic's native File > Bounce dialog; the caller completes the settings and destination in Logic. It returns `export_readiness_blocked` before opening the dialog when blockers are present. `export_plan` is read-only. Its `stem` form deliberately refuses unless exactly one currently scanned project has a fresh, project-coherent complete region inventory proving its populated tracks and `output_root` is an existing readable directory. A dry plan cannot inspect Logic's Export-panel browser without opening it, so browser visibility is an execution-time precondition: the driver refuses an existing directory that is not exposed there and never navigates arbitrary paths or creates folders. Stem filenames and output format are late-bound and unpromised. For stems, `fail_if_exists` examines only top-level non-directory entries with suffix `wav`, `wave`, `aif`, `aiff`, `aifc`, `m4a`, or `mp3`, and refuses if enumeration fails or the authoritative immediately-pre-export snapshot is non-empty; files that appear only after that snapshot are observations, not attributed produced artifacts. `skip_existing` and `export_resume` refuse stems because Logic assigns filenames only after export. `export_run` re-plans, opens, verifies project identity, drives the stem Export panel or bounces as appropriate, and analyzes only eligible files observed in the destination's before/after snapshot. It reports one result per populated stem subject but does not invent a filename-to-subject association or claim an observed post-snapshot file was produced by Logic; unbound subject results remain State B. `export_resume` remains available for known-path artifacts.

`inspect_session` (#965, first increment) returns a `logic_pro_mcp_session_population.v1` report built from the state cache alone: no Accessibility call, no UI navigation, nothing restored. Params: `scope?` (`whole_project` | `selection`), `domains?` (array of `tracks`, `strips`, `associations`, `hierarchy`, `routing`, `color`; default the first four), `allow_ui_navigation?` (Bool; `true` is refused with State C `not_implemented` in this increment), `project_ref?`, `snapshot_id?`. Every requested domain carries `coverage` (`complete` | `partial` | `unavailable` | `unstable`) and `reasons[]`; `tracks` and `strips` carry witnessed `rows[]`; `overall.complete` is true only when every requested domain is `complete`. The cache cannot see hidden tracks, the children of a collapsed stack, strip names, or which strip belongs to which track, so `associations` and `hierarchy` are `unavailable` and a cold, contaminated, or unread cache is reported as `unavailable` rather than as an empty session. `snapshot_id` is the opaque identity of this immutable capture, shared by the report and its own routing section; equal revision counters do not give separate captures the same ID. Pass `snapshot_id` alone to retrieve the original report JSON and original capture interval, not a fresh observation. Lookup cannot combine `scope`, `domains`, `allow_ui_navigation` or `project_ref`. `snapshot_retention` reports `retained`, an optional `reason`, `ttl_seconds: 60`, `capacity: 8` and `max_bytes: 2097152`. Reports without an observed canonical project bundle path remain readable with `retained: false` and `reason: project_identity_unobserved`; their IDs are not retrievable, because names cannot prove document identity. Bound reports are retained in the existing process-local cache for at most 60 monotonic seconds, with at most eight reports whose report JSON plus encoded captured project/track/strip content fit 2 MiB each. Lookup does not renew expiry; unknown, expired, evicted, different-cache or changed-project handles fail State C `stale_snapshot` without generating a replacement. A bound report that is too large or whose project changes before retention is refused without issuing a reusable handle. Retained reports are historical data, not current observations or authority to mutate. Counts alone do not establish completion, so in this increment `tracks` is never `complete`: a matching project-file count is kept as evidence (`witnesses.expected_count`, `expected_count_matches_rail`) with the reason `count_is_the_only_end_witness`; a count from a bundle that is not the cached project's is not reported (`project_file_not_bound`); rows older than 30 seconds add `track_cache_stale`; `scope: selection` adds `selection_state_unverified`, because an unreadable AXSelected reads as unselected. Any section version, `ax_occluded` or document flag that moves during the capture makes every requested domain `unstable`, including a flag that flips and flips back before the capture ends. A `project_ref` that no longer names the project the cache holds is refused with State C `stale_target_reference`, `write_attempted: false`, and nothing is bound. A requested `routing` section (#291 R1) is built by the same publication `logic://mixer` uses, over the same capture: `graph` carries that graph's per-domain `coverage` verbatim and `snapshot_id` its `snapshot_id`; the section is `unavailable` (`routing_graph_unavailable`) before any mixer poll, `unstable` when the capture moved (`cache_moved_during_capture`) or a reference snapshot went stale during issuance (`target_snapshot_stale`), and otherwise `partial` (`routing_graph_partial`).

`plan_session_repair` (#966, canonical draft increment) is read-only. Pass a retained `snapshot_id`, a finite `logic_pro_mcp_repair_policy.v1` policy accepted by the existing intent parser, and optional `names: [{ target: declared policy handle, name: String }]` (at most 32 unique targets). Names are literal approved values, including leading/trailing whitespace; the existing scalar rename validator checks the unmodified value and its 128-character limit. Names do not infer roles. Unknown policy schemas, fields, actions, duplicate targets, or invalid names refuse the whole request without a partial plan; request JSON must fit 2 MiB. The `logic_pro_mcp_session_repair_plan.v1` draft includes its baseline ID, approved values, ordered `steps`, the same canonical `preview`, dependencies, required invariants, questions, blocked reasons, and a SHA-256 digest of the canonical content excluding `plan_id` and `digest`. No object is created.

Planning options (ADR-021 §3) are separate parameters, and each permits planning an effect, never executing it. `on_ambiguity` is `ask` (default) or `report_only`; neither guesses, and `report_only` marks the plan not executable with `report_only_requested`. `allow_create_aux`, `allow_stack_membership_change` and `allow_replace_send` are booleans, default false. The plan carries them as `planning_options`, so the digest binds them, and a `plan_id` lookup refuses them. An output approves only the bus a track feeds. What reads that bus is approved separately, in the policy's optional `receivers: [{bus, aux: "new" | "keep" | "none"}]`: `new` approves planning a new aux that reads the bus, `keep` approves the receivers observed reading it, and `none` says nothing is meant to (a sidechain-only bus). Each entry is assessed whether or not an output onto its bus needs changing. For an approved bus destination the planner reads whether an aux reads that bus, counting only an edge from one unambiguous bus node into exactly one aux node; absence is concluded only from a complete bus-to-aux reading. A missing receiver approved as `new` adds a `create_aux` step before the outputs that need it, with a `new:aux_bus_<n>` handle in `new_object_inventory`, when `allow_create_aux` is true, and otherwise blocks those outputs with `receiving_aux_missing` and `create_aux_not_allowed`. A missing receiver approved as `keep`, or a missing receiver with no `receivers` entry on the bus of an output that needs changing, plans nothing and adds a `receiver_questions` entry offering `new` and `none`; an output already on its bus asks nothing without an entry. An observed receiver against `new` or `none` asks the same way and offers `keep`. Every offered answer settles the question when the plan is built again with it, and an open question puts `receiver_intent_unresolved` in the plan's reasons. Today's routing graph does not read bus-to-aux inputs, so every bus destination carries `bus_receiver_unverified` instead. No step kind uses `allow_stack_membership_change` or `allow_replace_send` yet. Existing output and rename commands do not supply exact-target coupled-preservation and inverse adapters, so corresponding tasks remain blocked; this increment does not apply repairs. Pass `plan_id` alone, optionally with its digest, to retrieve the original bytes without regenerating a preview or renewing expiry. Lookup cannot combine new intent. Plans share the existing cache's eight-entry/2 MiB limits and expire no later than their source observation (60 monotonic seconds); baseline eviction, expiry, project change or another cache also invalidates lookup. Captured native values preserve observation provenance; a decoded report does not mint provenance. A retrieved plan is historical, never current-state or write authority: any future apply operation must revalidate the baseline and obtain explicit confirmation. Legacy `audit` and `cleanup_plan` contracts are unchanged.


`get_regions` returns `{ regions, complete, scope, reason, returned_count, _debug }`. Logic's AX tree currently exposes the visible arrange viewport only, so the response reports `complete:false`, `scope:"visible_arrange_area"`, and `reason:"logic_ax_viewport_only"`; callers must not treat `regions` as a project-wide inventory. Project audit preserves that limitation as `ax_visible_subset`, emits `region_inventory_partial`, and withholds empty-track claims for unseen lanes.

### `logic_audio`

`analyze_file` inspects an existing audio artifact and reports duration, level, silence ratio, and verification status. It does not mutate Logic.

`compare_spectra` takes `before_path`, `after_path` (absolute audio paths), and optional `output_root` (allowlist root). It uses the existing bounded native-format spectral decoder for both files, requires matching sample rate, channel interpretation and analysis policy, and binds each analysis to a SHA-256 of its file bytes. A changing, unsafe, incomplete or incompatible input is refused. Each band reports raw `after - before` energy in dB; unmeasured bands and values at the analysis floor have no `deltaDb` and carry `unavailableReason`. `complete` is true only when every band has an uncensored measured difference. The response includes both analyses and explicit limitations, including unequal temporal coverage where applicable. It does not time-align, normalize level, judge musical quality, apply EQ, or mutate files or Logic.

### `logic_system`

Common commands: `health`, `permissions`, `refresh_cache`, `export_support_bundle`, `setup_arm_key`, `list_recent_traces`, `get_trace`, `clear_traces`, `saga_preflight`, `saga_execute`, `saga_status`, `saga_cancel`, `help`.

Use `health` for channel readiness and `help` for command summaries. `help` accepts category `all`, `transport`, `tracks`, `mixer`, `midi`, `edit`, `navigate`, `project`, `audio`, `plugins`, or `system`.

#### `setup_arm_key` (v3.12.0)

Consent-gated auto-setup for Logic's "Toggle Track Record Enable" key command — the coordinate-free arm actuator's prerequisite. Without `consent: true` it returns State C `consent_required` before any parameter validation or mutation (consent-first). With consent it runs verify-first: it drives a real record-arm flip **and restore** using only the configured chord, so an already-working mapping short-circuits to State A (`write_source: "existing_mapping_verify"`) with zero GUI mutation; otherwise it performs the assignment in Logic's Key Commands window and functionally re-verifies the new mapping the same way. Every outcome is an Honest Contract envelope: State A only after an observed flip AND restore; a chord already owned by another command fails closed as `chord_conflict` and is never stolen; an environment with no selectable track fails closed as `verify_environment_unavailable` with no GUI mutation attempted. Evidence fields include `configuration_write_attempted`, `verification_mutation_attempted`, `restored`, `safe_to_retry`, and (GUI path) window/search/selection/learn readbacks. Set `LOGIC_PRO_MCP_ARM_KEYCODE` / `LOGIC_PRO_MCP_ARM_MODIFIERS` to choose a non-default chord.

Operation tracing is on by default (set `LOGIC_MCP_ADR005_OPERATION_TRACE=0` to disable), so every **successful** mutating result (State A/B) carries a `trace_id`; State C failures do not (nothing was traced to completion). `list_recent_traces` returns bounded summaries from the in-process trace store and accepts optional `limit`.
`get_trace` returns one stored trace by required `trace_id`.
`clear_traces` clears only the in-process trace store and requires `confirmed:true` because it destroys in-session diagnostic evidence.

#### Measuring the AppleScript segment (v3.13+)

`midi.import_file` runs under three nested time budgets: the operation deadline, the bound on its `osascript` call, and the Swift-side AX polling around it. Only the outermost one used to cross the process boundary, so the middle budget — the one that produced the `midi.import_file` timeout reported in #449 — could be reasoned about but not measured. Summing the script's own `delay` statements is not a substitute: those sums omit every AX query and file operation between the delays, so they cannot establish real headroom.

Traces for that operation now carry a `script_segment.completed` event with an `applescript_duration_ms` attribute: the measured elapsed time of the `osascript` call, taken with a monotonic clock so an NTP correction cannot invent or erase it. Compare it against the bound in `ServerConfig.midiImportAppleScriptTimeout` to read actual headroom on a given machine and project.

The attribute is diagnostic only. Nothing gates on it, it is never a verification signal, and it carries no user content — only an elapsed count of milliseconds.

`saga_preflight` and `saga_execute` accept `{ steps: [step], idempotency_key: String }`; each step contains `operation_id`, optional `target_ref`, `params`, and `expected_inverse`. Preflight performs no Logic writes and reports per-step before-state availability. Execute reports verified per-step evidence; a failed request remains State C even when every applied step is compensated, while partial or unknown compensation is State B.

The bounded journal belongs only to the current server session and is cleared on session end or process restart. A completed duplicate key returns its stored outcome with `duplicate:true`; `saga_status` reads that record. `saga_status` and `saga_cancel` take exactly `{ idempotency_key: String }`; any other key is `invalid_params`. `saga_cancel` on an in-flight saga records the request and returns State B `saga_cancellation_pending` with `status: "cancellation_requested"`, and a repeated request answers the same. Once the unwind is journaled it returns `status: "cancelled"` with the stored outcome: State A when the unwind was verified, State B `saga_reconciliation_required` when it was not. An unknown key is State C `element_not_found`, a completed saga is State C `unsupported_state`, and a terminal key whose body was dropped answers `saga_outcome_unavailable` as described below (`SystemDispatcher` `saga_cancel`, `SagaJournal.cancel`). Ordered work with compensation does not promise all-or-nothing completion or durable recovery.

The journal keeps two independently bounded tiers, so pressure costs stored evidence rather than safety:

- **Replay protection (whole session).** Every `idempotency_key` begun in a session stays recorded for that whole session. A key that reached a terminal state never starts again — replay protection does not lapse, expire, or time out. There is no wall-clock TTL.
- **Outcome bodies (most recent N).** Full stored outcomes are retained for the most recent `journal_record_capacity` sagas (default 1024). Under insertion pressure the oldest terminal body is dropped; in-flight sagas are never dropped.

Retrying an older completed saga whose body was dropped returns `saga_outcome_unavailable` (State C, terminal) instead of the original body — never a re-execution. It carries `terminal_kind` (`completed` or `cancelled`), `outcome_retained:false`, `safe_to_retry:false`, and `write_attempted:false`. `terminal_kind` names only which path the saga terminated on; it is **not** a claim that the intent succeeded (a `completed` saga may have applied only partially). Reconcile by observing current state via `saga_status` or the relevant read operations — do not re-fire the same intent blindly. `saga_status` for such a key still reports its terminal `status` with `outcome_retained:false` and no `outcome`.

`saga_journal_capacity_exceeded` remains distinct and unchanged in meaning: the journal cannot admit a **new** key. It is returned under either of two conditions — the session's replay-protection tier (`journal_compact_capacity`, default 65536) is full, or the outcome tier is fully occupied by in-flight sagas and therefore holds no terminal body that can be reclaimed. Both stay fail-closed: admitting a key the session cannot replay-protect, or evicting a saga still running, would be a correctness hole rather than an availability one.

`saga_status` and `saga_preflight` publish `journal_full_body_count`, `journal_compact_count`, `journal_body_evictions`, `journal_compact_capacity`, and `journal_record_capacity` for operators. These are diagnostics only — none of them promises that a later retry will fit, and `journal_survives_process_restart` stays `false`.

### CGEvent plain-letter keys and the keyboard input source

The CGEvent fallback sends nine operations as a letter key with no Command, Control or Option: `transport.record` (R), `transport.toggle_cycle` (C), `transport.toggle_metronome` (K), `view.toggle_mixer` (X), `view.toggle_piano_roll` (P), `view.toggle_library` (Y), `view.toggle_score_editor` (N), `nav.zoom_to_fit` (Z) and `automation.toggle_view` (A). Under an input source that is not ASCII-capable, such as 2-Set Korean, that key reaches Logic as the source's own character and runs nothing (#1039). For these keys the channel reads the current input source after Logic is brought forward, then:

- **ASCII-capable:** the key is posted; the State B reply carries `input_source_switched: false`.
- **Not ASCII-capable:** the channel selects a keyboard layout that types the key's U.S. letter and reads the current source back. It tries the ASCII-capable layout macOS names for the current source, then ABC, then U.S., and takes the first that is enabled and whose own key map types that letter on the key; on Dvorak, for example, the key for R types p, so ABC or U.S. is selected for it. Only when it reads as that layout does it wait 0.1 s, post the key, wait 0.1 s, select the user's source again and read it back. The State B reply carries `input_source_switched: true`, `input_source_before`, `input_source_switched_to`, `input_source_restored` and `input_source_after`. `input_source_restored` comes from that last reading, not from what macOS returned for the selection; when it is `false`, `input_source_after` names the source the user was left on (`null` when it did not read) and `hint` names the source to select again.
- **Switch not made or not read back:** State C `not_supported`, `reason: "input_source_blocks_plain_letters"`, nothing posted, `input_source_switched: false`, and `input_source_switch_failure` is one of `source_id_unreadable` (the source's id did not read, so it could not be selected back), `no_ascii_capable_layout`, `layout_types_another_letter` (no enabled candidate types the key's letter; nothing is selected), `select_failed` or `switch_not_verified`. When a selection was made, the user's source is selected back first, and `input_source_restored` / `input_source_after` report the reading.
- **Source unreadable:** State C `reason: "input_source_unreadable"`, nothing posted and nothing selected.

### Not-exposed commands

A few command tokens are recognised by the dispatchers but are deliberately **not part of the production MCP contract** (no deterministic / verified path exists yet). They are excluded from the workflow command census and return a single machine-classifiable State C shape — `error: "command_not_exposed"`, `not_exposed: true`, `supported: false`, plus the `operation` — so a complete-surface demo/test harness can classify them as *expected*, not a malfunction:

- `logic_tracks.set_color`
- `logic_mixer.set_send`, `logic_mixer.set_output`, `logic_mixer.set_input`, `logic_mixer.toggle_eq`, `logic_mixer.reset_strip`, `logic_mixer.bypass_plugin`

## Error Format

State C errors use stable machine-readable strings such as `invalid_params`, `not_implemented`, `command_not_exposed`, `index_out_of_range`, `element_not_found`, `readback_mismatch`, `port_unavailable`, `channels_exhausted`, `unsupported_param_readback`, and `confirmation_required`.

Clients should branch on `state`, `verified`, `error`, and `retry_safe`; do not parse human prose as the contract.
