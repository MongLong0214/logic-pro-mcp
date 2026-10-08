# Command parameters

<!-- Generated from the operation registry by CommandSchemaProjection.parameterTable. Do not edit; run `LPM_WRITE_GENERATED_DOCS=1 swift test --filter Issue957` to regenerate. -->

Each command's accepted parameters and the registry's policy words for it. "Closed" means a key the row does not list is refused: by the server's generic strict-parameter gate, or, for the keys a dispatcher answers with its own error (such as `port` on `logic_midi` `list_ports`), which that gate forwards, by the dispatcher; "open" means that gate does not run for the row, and the command's dispatcher still validates its parameters. The table assumes strict parameter checking, the default; `LOGIC_MCP_ADR003_STRICT_PARAMS=0` turns the gate off and opens every row. A parameter followed by a kind (`bar: integer`) is one whose value of another type the dispatcher refuses before any channel runs; a parameter with no kind is one the dispatcher coerces, defaults or ignores, and the registry gives the reason. "Required" lists the groups of which one key must be present. Both come from `OperationRegistry.parameterContracts`, which a census drives against every dispatcher. A list in parentheses is the only values the dispatcher takes, read from the dispatcher's own constant. This is a projection of `OperationRegistry`, not a second source, and not qualification evidence.

## `logic_audio`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `analyze_file` | `expected_channel_count`, `expected_duration_seconds`, `expected_sample_rate`, `max_decoded_frames`, `max_duration_drift_seconds`, `max_input_duration_seconds`, `max_input_file_size_bytes`, `max_peak_dbfs`, `max_silence_ratio`, `maximum_decoded_frames`, `maximum_duration_drift_seconds`, `maximum_input_duration_seconds`, `maximum_input_file_size_bytes`, `maximum_peak_dbfs`, `maximum_silence_ratio`, `min_duration_seconds`, `min_file_size_bytes`, `minimum_duration_seconds`, `minimum_file_size_bytes`, `near_silence_dbfs`, `near_silence_threshold_dbfs`, `output_root`, `path` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `analyze_spectrum` | `path`, `target_curve`: array | `path` | closed | read_only | none | none | none | never_automatic | default_install |
| `compare_spectra` | `after_path`, `before_path`, `comparison_mode`: string (absolute, spectral_shape), `output_root` | `before_path`; `after_path` | closed | read_only | none | none | none | never_automatic | default_install |
| `recommend_eq` | `minimum_level`: number, `path` | `path` | closed | read_only | none | none | none | never_automatic | default_install |

## `logic_edit`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `bounce_in_place` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `copy` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `cut` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `delete` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `duplicate` | none | none | closed | mutating | none | none | none | never_automatic | requires_key_binding |
| `join` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `move_to_playhead` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `normalize` | none | none | closed | mutating | none | none | none | never_automatic | requires_key_binding |
| `paste` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `quantize` | `grid`: string (1/1, 1/2, 1/4, 1/8, 1/16, 1/32, 1/64, 1/4T, 1/8T, 1/16T), `value`: string (1/1, 1/2, 1/4, 1/8, 1/16, 1/32, 1/64, 1/4T, 1/8T, 1/16T) | `value` or `grid` | closed | mutating | none | none | none | never_automatic | default_install |
| `redo` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `select_all` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `split` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_step_input` | none | none | closed | mutating | none | none | none | never_automatic | requires_key_binding |
| `undo` | none | none | closed | mutating | none | none | none | never_automatic | default_install |

## `logic_midi`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `create_virtual_port` | `name` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `import_file` | `path`: string | `path` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `list_ports` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `mmc_locate` | `bar`: integer, `time` | `bar` or `time` | closed | mutating | none | none | best_effort | never_automatic | default_install |
| `mmc_play` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `mmc_record` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `mmc_stop` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `play_sequence` | `notes`: string, `port`: string (keycmd, midi) | `notes` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_aftertouch` | `channel`: integer, `port`: string (keycmd, midi), `value`: integer | `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_cc` | `channel`: integer, `controller`: integer, `port`: string (keycmd, midi), `value`: integer | `controller`; `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_chord` | `channel`: integer, `duration_ms`: integer, `notes`: listOrString, `port`: string (keycmd, midi), `velocity`: integer | `notes` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_note` | `channel`: integer, `duration_ms`: integer, `note`: integer, `port`: string (keycmd, midi), `velocity`: integer | `note` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_pitch_bend` | `channel`: integer, `port`: string (keycmd, midi), `value`: integer | `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_program_change` | `channel`: integer, `port`: string (keycmd, midi), `program`: integer | `program` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_sysex` | `bytes`, `data` | `bytes` or `data` | closed | mutating | none | none | none | never_automatic | default_install |
| `step_input` | `duration`: stringOrInteger, `note`: integer | `note`; `duration` | closed | mutating | none | none | none | never_automatic | default_install |

## `logic_mixer`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `bank` | `count`: integer, `direction`: scalar (left, right) | `direction` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `insert_plugin` | `channel_configuration`, `configuration`, `confirmed`: boolean, `index`: integer, `insert`: integer, `name`, `plugin`, `plugin_name`, `slot`: integer, `track`: integer, `track_index`: integer | `track` or `track_index` or `index`; `slot` or `insert`; `plugin_name` or `plugin` or `name` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `set_master_volume` | `value`: number, `volume`: number | `value` or `volume` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `set_output_verified` | `destination`: object, `expected_current`: object, `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref`; `destination` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_pan` | `index`: integer, `pan`: number, `project_ref`, `target_ref`, `track`: integer, `value`: number | `index` or `track` or `target_ref`; `value` or `pan` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_plugin_param` | `insert`: integer, `param`: integer, `track`: integer, `value`: number | `track`; `insert`; `param`; `value` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `set_volume` | `index`: integer, `project_ref`, `target_ref`, `track`: integer, `value`: number, `volume`: number | `index` or `track` or `target_ref`; `value` or `volume` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |

## `logic_navigate`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `capture_markers` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_marker` | `name` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `delete_marker` | `index`: integer | `index` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `goto_bar` | `bar`: integer | `bar` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `goto_marker` | `index`: integer, `name` | `index` or `name` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `rename_marker` | `index`: integer, `name`: scalar | `index`; `name` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `set_zoom` | `direction`, `level` | `level` or `direction` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `toggle_view` | `view`, `visible`: boolean | `view` | closed | mutating | none | none | none | never_automatic | default_install |
| `zoom_to_fit` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |

## `logic_plugins`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `get_inventory` | `index`, `track`, `track_index` | `index` or `track` or `track_index` | closed | read_only | none | none | none | never_automatic | default_install |
| `get_param_verified` | `insert`: integer, `param`: string, `plugin`: string, `plugin_id`: string, `plugin_name`: string, `project_ref`, `target_ref`: string, `track`: integer, `unit`: string | `target_ref`; `param` | closed | read_only | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `insert_verified` | `expected_name`, `insert`, `mode`, `plugin`, `plugin_id`, `plugin_name`, `project_expected_path`, `project_ref`, `slot`, `target_ref`, `track` | `track` or `target_ref`; `insert` or `slot` or `target_ref`; `plugin` or `plugin_id` or `plugin_name`; `expected_name` or `target_ref`; `mode`; `project_expected_path` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_eq_band_verified` | `band`, `insert`, `mode`, `parameter`, `project_expected_path`, `project_ref`, `target_ref`, `track`, `unit`, `value` | `track` or `target_ref`; `insert` or `target_ref`; `band`; `parameter`; `value`; `unit`; `mode`; `project_expected_path` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_param_verified` | `insert`, `mode`, `param`, `plugin`, `plugin_id`, `plugin_name`, `project_expected_path`, `project_ref`, `target_ref`, `track`, `unit`, `value` | `track` or `target_ref`; `insert` or `target_ref`; `plugin` or `plugin_id` or `plugin_name`; `param`; `value`; `mode`; `project_expected_path` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |

## `logic_project`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `apply_session_repair` | `confirmed`, `digest`, `idempotency_key`, `plan_id` | `plan_id`; `digest`; `confirmed`; `idempotency_key` | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `audit` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `bounce` | `confirmed`: boolean | none | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `cleanup_apply` | `confirmed`: boolean, `name`, `names`, `new_name`, `stepId`, `step_id` | `step_id` or `stepId`; `confirmed` | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `cleanup_plan` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `close` | `confirmed`: boolean, `saving` | none | closed | mutating | l3 | none | none | never_automatic | default_install |
| `export_plan` | `artifact`, `artifacts`, `collision_policy`, `kind`, `naming_policy`, `outputRoot`, `output_root`, `path`, `project`, `projects` | `projects` or `project` or `path`; `output_root` or `outputRoot` | closed | read_only | none | none | none | never_automatic | default_install |
| `export_resume` | `artifact`, `artifacts`, `collision_policy`, `confirmed`: boolean, `kind`, `naming_policy`, `outputRoot`, `output_root`, `path`, `project`, `projects` | `projects` or `project` or `path`; `output_root` or `outputRoot` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `export_run` | `artifact`, `artifacts`, `collision_policy`, `confirmed`: boolean, `kind`, `naming_policy`, `outputRoot`, `output_root`, `path`, `project`, `projects` | `projects` or `project` or `path`; `output_root` or `outputRoot` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `get_regions` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `inspect_session` | `allow_ui_navigation`: boolean, `domains`, `project_ref`, `scope`, `snapshot_id` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `is_running` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `launch` | none | none | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `new` | none | none | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `open` | `confirmed`: boolean, `path`: scalar | `path` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `plan_session_repair` | `allow_create_aux`, `allow_replace_send`, `allow_stack_membership_change`, `digest`, `names`, `on_ambiguity`, `plan_id`, `policy`, `snapshot_id` | `plan_id` or `snapshot_id` and `policy` | closed | read_only | none | none | none | never_automatic | default_install |
| `quit` | `confirmed`: boolean | none | closed | mutating | l3 | none | readback_required | never_automatic | default_install |
| `save` | none | none | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `save_as` | `confirmed`: boolean, `path`: scalar | `path` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |

## `logic_system`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `clear_traces` | `confirmed`: boolean | `confirmed` | closed | read_only | l2 | none | none | never_automatic | default_install |
| `export_support_bundle` | `dir`: string | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `get_trace` | `trace_id`: string | `trace_id` | closed | read_only | none | none | none | never_automatic | default_install |
| `health` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `help` | `category` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `list_recent_traces` | `limit`: integer | none | closed | read_only | none | none | none | never_automatic | default_install |
| `permissions` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `refresh_cache` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `saga_cancel` | `idempotency_key`: string | `idempotency_key` | open | mutating | none | none | readback_required | never_automatic | default_install |
| `saga_execute` | `idempotency_key`: string, `steps`: array | `idempotency_key`; `steps` | open | mutating | none | none | readback_required | never_automatic | default_install |
| `saga_preflight` | `idempotency_key`: string, `steps`: array | `idempotency_key`; `steps` | open | read_only | none | none | none | never_automatic | default_install |
| `saga_status` | `idempotency_key`: string | `idempotency_key` | open | read_only | none | none | none | never_automatic | default_install |
| `setup_arm_key` | `consent` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `setup_control_surface` | `consent` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |

## `logic_tracks`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `arm` | `enabled`: booleanLike, `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `arm_only` | `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `create_audio` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_drummer` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_external_midi` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_instrument` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `delete` | `expected_name`, `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref`; `expected_name` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `duplicate` | `expected_name`, `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref`; `expected_name` or `target_ref` | closed | mutating | none | accepts_stable_target | none | never_automatic | default_install |
| `list_library` | none | none | closed | read_only | none | none | none | never_automatic | default_install |
| `mute` | `enabled`: booleanLike, `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `record_sequence` | `bar`: integer, `instrument`, `instrument_path`, `notes`: string, `tempo`: number | `notes` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `rename` | `index`: integer, `name`: scalar, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref`; `name` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `resolve_path` | `path`: scalar | `path` | closed | read_only | none | none | none | never_automatic | default_install |
| `scan_library` | `mode` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `scan_plugin_presets` | `submenuOpenDelayMs`: integer | none | closed | read_only | none | none | none | never_automatic | default_install |
| `select` | `index`: integer, `name`, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `name` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_automation` | `index`: integer, `mode`: scalar (read, write, touch, latch, trim), `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref`; `mode` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_instrument` | `category`, `expected_name`, `index`: integer, `path`, `preset`, `project_ref`, `target_ref` | `index` or `target_ref`; `path` or `category` and `preset`; `expected_name` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `solo` | `enabled`: booleanLike, `index`: integer, `project_ref`, `target_ref`, `track`: integer | `index` or `track` or `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `sort_verified` | `confirmed`, `criterion`: scalar (midi_channel, audio_channel, output_channel, instrument_name, track_name, used, creation_date), `expected_order`: array | `criterion`; `expected_order` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |

## `logic_transport`

| Command | Parameters | Required | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|---|
| `fast_forward` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `goto_position` | `bar`: integer, `position` | `bar` or `position` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `pause` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `play` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `record` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `rewind` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `set_cycle_range` | `end`: integer, `start`: integer | `start`; `end` | closed | mutating | none | none | none | never_automatic | unsupported |
| `set_tempo` | `bpm`: number, `tempo`: number | `bpm` or `tempo` | closed | mutating | none | none | none | never_automatic | default_install |
| `stop` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `toggle_autopunch` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_count_in` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_cycle` | none | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_metronome` | none | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
