# Command parameters

<!-- Generated from the operation registry by CommandSchemaProjection.parameterTable. Do not edit; run `LPM_WRITE_GENERATED_DOCS=1 swift test --filter Issue957` to regenerate. -->

Each command's accepted parameters and the registry's policy words for it. "Closed" means the server's generic strict-parameter gate refuses a key the row does not list; "open" means that gate does not run for the row, and the command's dispatcher still validates its parameters. The table assumes strict parameter checking, the default; `LOGIC_MCP_ADR003_STRICT_PARAMS=0` turns the gate off and opens every row. Neither word covers values, types or required keys: the dispatchers check those and the registry does not record them. This is a projection of `OperationRegistry`, not a second source, and not qualification evidence.

## `logic_audio`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `analyze_file` | `expected_channel_count`, `expected_duration_seconds`, `expected_sample_rate`, `max_decoded_frames`, `max_duration_drift_seconds`, `max_input_duration_seconds`, `max_input_file_size_bytes`, `max_peak_dbfs`, `max_silence_ratio`, `maximum_decoded_frames`, `maximum_duration_drift_seconds`, `maximum_input_duration_seconds`, `maximum_input_file_size_bytes`, `maximum_peak_dbfs`, `maximum_silence_ratio`, `min_duration_seconds`, `min_file_size_bytes`, `minimum_duration_seconds`, `minimum_file_size_bytes`, `near_silence_dbfs`, `near_silence_threshold_dbfs`, `output_root`, `path` | closed | read_only | none | none | none | never_automatic | default_install |
| `analyze_spectrum` | `path` | closed | read_only | none | none | none | never_automatic | default_install |
| `compare_spectra` | `after_path`, `before_path`, `output_root` | closed | read_only | none | none | none | never_automatic | default_install |
| `recommend_eq` | `minimum_level`, `path` | closed | read_only | none | none | none | never_automatic | default_install |

## `logic_edit`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `bounce_in_place` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `copy` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `cut` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `delete` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `duplicate` | none | closed | mutating | none | none | none | never_automatic | requires_key_binding |
| `join` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `move_to_playhead` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `normalize` | none | closed | mutating | none | none | none | never_automatic | requires_key_binding |
| `paste` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `quantize` | `grid`, `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `redo` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `select_all` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `split` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_step_input` | none | closed | mutating | none | none | none | never_automatic | requires_key_binding |
| `undo` | none | closed | mutating | none | none | none | never_automatic | default_install |

## `logic_midi`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `create_virtual_port` | `name` | closed | mutating | none | none | none | never_automatic | default_install |
| `import_file` | `path` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `list_ports` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `mmc_locate` | `bar`, `time` | closed | mutating | none | none | best_effort | never_automatic | default_install |
| `mmc_play` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `mmc_record` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `mmc_stop` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `play_sequence` | `notes`, `port` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_aftertouch` | `channel`, `port`, `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_cc` | `channel`, `controller`, `port`, `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_chord` | `channel`, `duration_ms`, `notes`, `port`, `velocity` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_note` | `channel`, `duration_ms`, `note`, `port`, `velocity` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_pitch_bend` | `channel`, `port`, `value` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_program_change` | `channel`, `port`, `program` | closed | mutating | none | none | none | never_automatic | default_install |
| `send_sysex` | `bytes`, `data` | closed | mutating | none | none | none | never_automatic | default_install |
| `step_input` | `duration`, `note` | closed | mutating | none | none | none | never_automatic | default_install |

## `logic_mixer`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `bank` | `count`, `direction` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `insert_plugin` | `channel_configuration`, `configuration`, `confirmed`, `index`, `insert`, `name`, `plugin`, `plugin_name`, `slot`, `track`, `track_index` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `set_master_volume` | `value`, `volume` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `set_output_verified` | `destination`, `expected_current`, `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_pan` | `index`, `pan`, `project_ref`, `target_ref`, `track`, `value` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_plugin_param` | `insert`, `param`, `track`, `value` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `set_volume` | `index`, `project_ref`, `target_ref`, `track`, `value`, `volume` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |

## `logic_navigate`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `create_marker` | `name` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `delete_marker` | `index` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `goto_bar` | `bar` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `goto_marker` | `index`, `name` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `rename_marker` | `index`, `name` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `set_zoom` | `direction`, `level` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `toggle_view` | `view` | closed | mutating | none | none | none | never_automatic | default_install |
| `zoom_to_fit` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |

## `logic_plugins`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `get_inventory` | `index`, `track`, `track_index` | closed | read_only | none | none | none | never_automatic | default_install |
| `insert_verified` | `expected_name`, `insert`, `mode`, `plugin`, `plugin_id`, `plugin_name`, `project_expected_path`, `project_ref`, `slot`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_eq_band_verified` | `band`, `insert`, `mode`, `parameter`, `project_expected_path`, `project_ref`, `target_ref`, `track`, `unit`, `value` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_param_verified` | `insert`, `mode`, `param`, `plugin`, `plugin_id`, `plugin_name`, `project_expected_path`, `project_ref`, `target_ref`, `track`, `unit`, `value` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |

## `logic_project`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `audit` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `bounce` | `confirmed` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `cleanup_apply` | `confirmed`, `name`, `names`, `new_name`, `stepId`, `step_id` | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `cleanup_plan` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `close` | `confirmed`, `saving` | closed | mutating | l3 | none | none | never_automatic | default_install |
| `export_plan` | `artifact`, `artifacts`, `collision_policy`, `kind`, `naming_policy`, `outputRoot`, `output_root`, `path`, `project`, `projects` | closed | read_only | none | none | none | never_automatic | default_install |
| `export_resume` | `artifact`, `artifacts`, `collision_policy`, `confirmed`, `kind`, `naming_policy`, `outputRoot`, `output_root`, `path`, `project`, `projects` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `export_run` | `artifact`, `artifacts`, `collision_policy`, `confirmed`, `kind`, `naming_policy`, `outputRoot`, `output_root`, `path`, `project`, `projects` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `get_regions` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `inspect_session` | `allow_ui_navigation`, `domains`, `project_ref`, `scope`, `snapshot_id` | closed | read_only | none | none | none | never_automatic | default_install |
| `is_running` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `launch` | none | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `new` | none | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `open` | `confirmed`, `path` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |
| `plan_session_repair` | `digest`, `names`, `plan_id`, `policy`, `snapshot_id` | closed | read_only | none | none | none | never_automatic | default_install |
| `quit` | `confirmed` | closed | mutating | l3 | none | readback_required | never_automatic | default_install |
| `save` | none | closed | mutating | l1 | none | readback_required | never_automatic | default_install |
| `save_as` | `confirmed`, `path` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |

## `logic_system`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `clear_traces` | `confirmed` | closed | read_only | l2 | none | none | never_automatic | default_install |
| `export_support_bundle` | `dir` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `get_trace` | `trace_id` | closed | read_only | none | none | none | never_automatic | default_install |
| `health` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `help` | `category` | closed | read_only | none | none | none | never_automatic | default_install |
| `list_recent_traces` | `limit` | closed | read_only | none | none | none | never_automatic | default_install |
| `permissions` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `refresh_cache` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `saga_cancel` | `idempotency_key` | open | mutating | none | none | readback_required | never_automatic | default_install |
| `saga_execute` | `idempotency_key`, `steps` | open | mutating | none | none | readback_required | never_automatic | default_install |
| `saga_preflight` | `idempotency_key`, `steps` | open | read_only | none | none | none | never_automatic | default_install |
| `saga_status` | `idempotency_key` | open | read_only | none | none | none | never_automatic | default_install |
| `setup_arm_key` | `consent` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `setup_control_surface` | `consent` | closed | mutating | none | none | readback_required | never_automatic | default_install |

## `logic_tracks`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `arm` | `enabled`, `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `arm_only` | `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `create_audio` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_drummer` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_external_midi` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `create_instrument` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `delete` | `expected_name`, `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `duplicate` | `expected_name`, `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | none | never_automatic | default_install |
| `list_library` | none | closed | read_only | none | none | none | never_automatic | default_install |
| `mute` | `enabled`, `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `record_sequence` | `bar`, `instrument`, `instrument_path`, `notes`, `tempo` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `rename` | `index`, `name`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `resolve_path` | `path` | closed | read_only | none | none | none | never_automatic | default_install |
| `scan_library` | `mode` | closed | read_only | none | none | none | never_automatic | default_install |
| `scan_plugin_presets` | `submenuOpenDelayMs` | closed | read_only | none | none | none | never_automatic | default_install |
| `select` | `index`, `name`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_automation` | `index`, `mode`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `set_instrument` | `category`, `expected_name`, `index`, `path`, `preset`, `project_ref`, `target_ref` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `solo` | `enabled`, `index`, `project_ref`, `target_ref`, `track` | closed | mutating | none | accepts_stable_target | readback_required | never_automatic | default_install |
| `sort_verified` | `confirmed`, `criterion`, `expected_order` | closed | mutating | l2 | none | readback_required | never_automatic | default_install |

## `logic_transport`

| Command | Parameters | Unknown parameters | Mutability | Confirmation | Target | Verification | Retry | Availability |
|---|---|---|---|---|---|---|---|---|
| `fast_forward` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `goto_position` | `bar`, `position` | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `pause` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `play` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `record` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `rewind` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `set_cycle_range` | `end`, `start` | closed | mutating | none | none | none | never_automatic | unsupported |
| `set_tempo` | `bpm`, `tempo` | closed | mutating | none | none | none | never_automatic | default_install |
| `stop` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
| `toggle_autopunch` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_count_in` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_cycle` | none | closed | mutating | none | none | none | never_automatic | default_install |
| `toggle_metronome` | none | closed | mutating | none | none | readback_required | never_automatic | default_install |
