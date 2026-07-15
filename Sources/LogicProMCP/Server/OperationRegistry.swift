enum OperationID: String, CaseIterable, Codable, Sendable, Hashable {
    case transportPlay = "transport.play"
    case transportStop = "transport.stop"
    case transportRecord = "transport.record"
    case transportPause = "transport.pause"
    case transportRewind = "transport.rewind"
    case transportFastForward = "transport.fast_forward"
    case transportToggleCycle = "transport.toggle_cycle"
    case transportToggleMetronome = "transport.toggle_metronome"
    case transportSetTempo = "transport.set_tempo"
    case transportGotoPosition = "transport.goto_position"
    case transportSetCycleRange = "transport.set_cycle_range"
    case transportToggleCountIn = "transport.toggle_count_in"
    case transportToggleAutopunch = "transport.toggle_autopunch"
    case mixerSetVolume = "mixer.set_volume"
    case mixerSetPan = "mixer.set_pan"
    case mixerSetMasterVolume = "mixer.set_master_volume"
    case mixerSetPluginParam = "mixer.set_plugin_param"
    case mixerInsertPlugin = "mixer.insert_plugin"
    case navigateGotoBar = "navigate.goto_bar"
    case navigateGotoMarker = "navigate.goto_marker"
    case navigateCreateMarker = "navigate.create_marker"
    case navigateDeleteMarker = "navigate.delete_marker"
    case navigateRenameMarker = "navigate.rename_marker"
    case navigateZoomToFit = "navigate.zoom_to_fit"
    case navigateSetZoom = "navigate.set_zoom"
    case navigateToggleView = "navigate.toggle_view"
    case audioAnalyzeFile = "audio.analyze_file"
    case systemHealth = "system.health"
    case systemPermissions = "system.permissions"
    case systemRefreshCache = "system.refresh_cache"
    case systemListRecentTraces = "system.list_recent_traces"
    case systemGetTrace = "system.get_trace"
    case systemClearTraces = "system.clear_traces"
    case systemExportSupportBundle = "system.export_support_bundle"
    case systemHelp = "system.help"
    case systemSagaPreflight = "system.saga_preflight"
    case systemSagaExecute = "system.saga_execute"
    case systemSagaStatus = "system.saga_status"
    case systemSagaCancel = "system.saga_cancel"
    case pluginsGetInventory = "plugins.get_inventory"
    case pluginsSetParamVerified = "plugins.set_param_verified"
    case pluginsInsertVerified = "plugins.insert_verified"
    case editUndo = "edit.undo"
    case editRedo = "edit.redo"
    case editCut = "edit.cut"
    case editCopy = "edit.copy"
    case editPaste = "edit.paste"
    case editDelete = "edit.delete"
    case editSelectAll = "edit.select_all"
    case editSplit = "edit.split"
    case editJoin = "edit.join"
    case editQuantize = "edit.quantize"
    case editBounceInPlace = "edit.bounce_in_place"
    case editNormalize = "edit.normalize"
    case editDuplicate = "edit.duplicate"
    case editToggleStepInput = "edit.toggle_step_input"
    case projectNew = "project.new"
    case projectOpen = "project.open"
    case projectSave = "project.save"
    case projectSaveAs = "project.save_as"
    case projectClose = "project.close"
    case projectBounce = "project.bounce"
    case projectIsRunning = "project.is_running"
    case projectLaunch = "project.launch"
    case projectQuit = "project.quit"
    case projectGetRegions = "project.get_regions"
    case projectExportPlan = "project.export_plan"
    case projectExportRun = "project.export_run"
    case projectExportResume = "project.export_resume"
    case projectAudit = "project.audit"
    case projectCleanupPlan = "project.cleanup_plan"
    case projectCleanupApply = "project.cleanup_apply"
    case midiSendNote = "midi.send_note"
    case midiSendChord = "midi.send_chord"
    case midiSendCC = "midi.send_cc"
    case midiSendProgramChange = "midi.send_program_change"
    case midiSendPitchBend = "midi.send_pitch_bend"
    case midiSendAftertouch = "midi.send_aftertouch"
    case midiSendSysEx = "midi.send_sysex"
    case midiPlaySequence = "midi.play_sequence"
    case midiImportFile = "midi.import_file"
    case midiListPorts = "midi.list_ports"
    case midiCreateVirtualPort = "midi.create_virtual_port"
    case midiStepInput = "midi.step_input"
    case midiMMCPlay = "midi.mmc_play"
    case midiMMCStop = "midi.mmc_stop"
    case midiMMCRecord = "midi.mmc_record"
    case midiMMCLocate = "midi.mmc_locate"
    case tracksSelect = "tracks.select"
    case tracksCreateAudio = "tracks.create_audio"
    case tracksCreateInstrument = "tracks.create_instrument"
    case tracksCreateDrummer = "tracks.create_drummer"
    case tracksCreateExternalMIDI = "tracks.create_external_midi"
    case tracksDelete = "tracks.delete"
    case tracksDuplicate = "tracks.duplicate"
    case tracksRename = "tracks.rename"
    case tracksMute = "tracks.mute"
    case tracksSolo = "tracks.solo"
    case tracksArm = "tracks.arm"
    case tracksArmOnly = "tracks.arm_only"
    case tracksRecordSequence = "tracks.record_sequence"
    case tracksSetAutomation = "tracks.set_automation"
    case tracksSetInstrument = "tracks.set_instrument"
    case tracksListLibrary = "tracks.list_library"
    case tracksScanLibrary = "tracks.scan_library"
    case tracksResolvePath = "tracks.resolve_path"
    case tracksScanPluginPresets = "tracks.scan_plugin_presets"
}

enum ToolID: String, Sendable, Equatable {
    case logicTransport = "logic_transport"
    case logicMixer = "logic_mixer"
    case logicNavigate = "logic_navigate"
    case logicAudio = "logic_audio"
    case logicSystem = "logic_system"
    case logicPlugins = "logic_plugins"
    case logicEdit = "logic_edit"
    case logicProject = "logic_project"
    case logicMidi = "logic_midi"
    case logicTracks = "logic_tracks"
}

enum Mutability: Sendable, Equatable {
    case `mutating`
    case readOnly
}

enum ConfirmationPolicy: Sendable, Equatable {
    case none
    case l1
    case l2
    case l3
}

enum TargetPolicy: Sendable, Equatable {
    case none
    case requiresStableTarget
}

enum VerificationPolicy: Sendable, Equatable {
    case none
    case readbackRequired
    case bestEffort
}

enum RetryPolicy: Sendable, Equatable {
    case idempotent
    case beforeWriteBoundaryOnly
    case neverAutomatic
}

enum DeadlineClass: Sendable, Equatable {
    case short
    case medium
    case long

    var seconds: Double {
        switch self {
        case .short: 25
        case .medium: 90
        case .long: 300
        }
    }
}

enum AvailabilityPolicy: Sendable, Equatable {
    case defaultInstall
    case requiresProfile
    case requiresKeyBinding
    case experimental
    case unsupported
}

struct CapabilityID: RawRepresentable, Sendable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct OperationSpec: Sendable {
    let id: OperationID
    let tool: ToolID
    let command: String
    let mutability: Mutability
    let confirmation: ConfirmationPolicy
    let target: TargetPolicy
    let verification: VerificationPolicy
    let retry: RetryPolicy
    let deadline: DeadlineClass
    let availability: AvailabilityPolicy
    let allowedParams: Set<String>
    let capability: CapabilityID
}

enum OperationRegistry {
    struct ValidationEntry: Sendable {
        let operationID: String
        let tool: String
        let command: String
    }

    private static let allowedOperationIDsByTool: [String: Set<String>] = [
        ToolID.logicTransport.rawValue: [
            "transport.play", "transport.stop", "transport.record", "transport.pause",
            "transport.rewind", "transport.fast_forward", "transport.toggle_cycle",
            "transport.toggle_metronome", "transport.set_tempo", "transport.goto_position",
            "transport.set_cycle_range", "transport.toggle_count_in", "transport.toggle_autopunch",
        ],
        ToolID.logicMixer.rawValue: [
            "mixer.set_volume", "mixer.set_pan", "mixer.set_master_volume",
            "mixer.set_plugin_param", "mixer.insert_plugin",
        ],
        ToolID.logicNavigate.rawValue: [
            "navigate.goto_bar", "navigate.goto_marker", "navigate.create_marker",
            "navigate.delete_marker", "navigate.rename_marker", "navigate.zoom_to_fit",
            "navigate.set_zoom", "navigate.toggle_view",
        ],
        ToolID.logicAudio.rawValue: [
            "audio.analyze_file",
        ],
        ToolID.logicSystem.rawValue: [
            "system.health", "system.permissions", "system.refresh_cache",
            "system.list_recent_traces", "system.get_trace", "system.clear_traces",
            "system.export_support_bundle", "system.help", "system.saga_preflight",
            "system.saga_execute", "system.saga_status", "system.saga_cancel",
        ],
        ToolID.logicPlugins.rawValue: [
            "plugins.get_inventory", "plugins.set_param_verified", "plugins.insert_verified",
        ],
        ToolID.logicEdit.rawValue: [
            "edit.undo", "edit.redo", "edit.cut", "edit.copy", "edit.paste", "edit.delete",
            "edit.select_all", "edit.split", "edit.join", "edit.quantize",
            "edit.bounce_in_place", "edit.normalize", "edit.duplicate", "edit.toggle_step_input",
        ],
        ToolID.logicProject.rawValue: [
            "project.new", "project.open", "project.save", "project.save_as", "project.close",
            "project.bounce", "project.is_running", "project.launch", "project.quit",
            "project.get_regions", "project.export_plan", "project.export_run",
            "project.export_resume", "project.audit", "project.cleanup_plan",
            "project.cleanup_apply",
        ],
        ToolID.logicMidi.rawValue: [
            "midi.send_note", "midi.send_chord", "midi.send_cc", "midi.send_program_change",
            "midi.send_pitch_bend", "midi.send_aftertouch", "midi.send_sysex",
            "midi.play_sequence", "midi.import_file", "midi.list_ports",
            "midi.create_virtual_port", "midi.step_input", "midi.mmc_play", "midi.mmc_stop",
            "midi.mmc_record", "midi.mmc_locate",
        ],
        ToolID.logicTracks.rawValue: [
            "tracks.select", "tracks.create_audio", "tracks.create_instrument",
            "tracks.create_drummer", "tracks.create_external_midi", "tracks.delete",
            "tracks.duplicate", "tracks.rename", "tracks.mute", "tracks.solo", "tracks.arm",
            "tracks.arm_only", "tracks.record_sequence", "tracks.set_automation",
            "tracks.set_instrument", "tracks.list_library", "tracks.scan_library",
            "tracks.resolve_path", "tracks.scan_plugin_presets",
        ],
    ]

    private static let allowedCommandsByTool: [String: Set<String>] = [
        ToolID.logicTransport.rawValue: [
            "play", "stop", "record", "pause", "rewind", "fast_forward", "toggle_cycle",
            "toggle_metronome", "set_tempo", "goto_position", "set_cycle_range", "toggle_count_in",
            "toggle_autopunch",
        ],
        ToolID.logicMixer.rawValue: [
            "set_volume", "set_pan", "set_master_volume", "set_plugin_param", "insert_plugin",
        ],
        ToolID.logicNavigate.rawValue: [
            "goto_bar", "goto_marker", "create_marker", "delete_marker", "rename_marker",
            "zoom_to_fit", "set_zoom", "toggle_view",
        ],
        ToolID.logicAudio.rawValue: [
            "analyze_file",
        ],
        ToolID.logicSystem.rawValue: [
            "health", "permissions", "refresh_cache", "export_support_bundle", "help",
            "list_recent_traces", "get_trace", "clear_traces",
            "saga_preflight", "saga_execute", "saga_status", "saga_cancel",
        ],
        ToolID.logicPlugins.rawValue: [
            "get_inventory", "set_param_verified", "insert_verified",
        ],
        ToolID.logicEdit.rawValue: [
            "undo", "redo", "cut", "copy", "paste", "delete", "select_all", "split", "join",
            "quantize", "bounce_in_place", "normalize", "duplicate", "toggle_step_input",
        ],
        ToolID.logicProject.rawValue: [
            "new", "open", "save", "save_as", "close", "bounce", "is_running", "launch",
            "quit", "get_regions", "export_plan", "export_run", "export_resume", "audit",
            "cleanup_plan", "cleanup_apply",
        ],
        ToolID.logicMidi.rawValue: [
            "send_note", "send_chord", "send_cc", "send_program_change", "send_pitch_bend",
            "send_aftertouch", "send_sysex", "play_sequence", "import_file", "list_ports",
            "create_virtual_port", "step_input", "mmc_play", "mmc_stop", "mmc_record",
            "mmc_locate",
        ],
        ToolID.logicTracks.rawValue: [
            "select", "create_audio", "create_instrument", "create_drummer",
            "create_external_midi", "delete", "duplicate", "rename", "mute", "solo", "arm",
            "arm_only", "record_sequence", "set_automation", "set_instrument", "list_library",
            "scan_library", "resolve_path", "scan_plugin_presets",
        ],
    ]

    private static let allowedOperationIDs = Set(allowedOperationIDsByTool.values.flatMap { $0 })
    static let registeredToolRawValues = Set(allowedOperationIDsByTool.keys)
    // The saga surfaces (#287) do their OWN strict param validation inside
    // SystemDispatcher and return richer, saga-specific error envelopes
    // (typed error + journal_scope). Routing them through the generic
    // strict-param gate would replace that with a bare invalid_params that
    // drops journal_scope, so they opt out and rely on their own validation.
    static let strictParamValidationOptOuts: Set<OperationID> = [
        .systemSagaPreflight, .systemSagaExecute, .systemSagaStatus, .systemSagaCancel,
    ]
    static let legacyIgnoredParamsByOperation: [OperationID: Set<String>] = [
        .tracksRecordSequence: ["instrument", "instrument_path"],
    ]
    static let dispatcherRejectedParamsByOperation: [OperationID: Set<String>] = [
        .midiPlaySequence: ["channel"],
        .midiSendSysEx: ["port"],
        .midiImportFile: ["port"],
        .midiListPorts: ["port"],
        .midiCreateVirtualPort: ["port"],
        .midiStepInput: ["port"],
        .midiMMCPlay: ["port"],
        .midiMMCStop: ["port"],
        .midiMMCRecord: ["port"],
        .midiMMCLocate: ["port"],
        .tracksRecordSequence: ["port"],
    ]

    private static func allowedParams(
        for operationID: OperationID,
        target: TargetPolicy = .none,
        commandSpecific: Set<String>
    ) -> Set<String> {
        var allowed = commandSpecific
            .union(legacyIgnoredParamsByOperation[operationID] ?? [])
        if target == .requiresStableTarget {
            allowed.insert("target_ref")
        }
        return allowed
    }

    static let specs: [OperationSpec] = ([
        (.transportPlay, "play", .readbackRequired, .defaultInstall, []),
        (.transportStop, "stop", .readbackRequired, .defaultInstall, []),
        (.transportRecord, "record", .readbackRequired, .defaultInstall, []),
        (.transportPause, "pause", .readbackRequired, .defaultInstall, []),
        (.transportRewind, "rewind", .none, .defaultInstall, []),
        (.transportFastForward, "fast_forward", .none, .defaultInstall, []),
        (.transportToggleCycle, "toggle_cycle", .none, .defaultInstall, []),
        (.transportToggleMetronome, "toggle_metronome", .readbackRequired, .defaultInstall, []),
        (.transportSetTempo, "set_tempo", .none, .defaultInstall, ["bpm", "tempo"]),
        (.transportGotoPosition, "goto_position", .readbackRequired, .defaultInstall, ["bar", "position"]),
        (.transportSetCycleRange, "set_cycle_range", .none, .unsupported, ["end", "start"]),
        (.transportToggleCountIn, "toggle_count_in", .none, .defaultInstall, []),
        (.transportToggleAutopunch, "toggle_autopunch", .none, .defaultInstall, []),
    ] as [(OperationID, String, VerificationPolicy, AvailabilityPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicTransport,
            command: entry.1,
            mutability: Mutability.`mutating`,
            confirmation: .none,
            target: .none,
            verification: entry.2,
            retry: .neverAutomatic,
            deadline: .short,
            availability: entry.3,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.4),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (
            .mixerSetVolume,
            "set_volume",
            .none,
            TargetPolicy.requiresStableTarget,
            ["index", "track", "value", "volume"]
        ),
        (.mixerSetPan, "set_pan", .none, .requiresStableTarget, ["index", "pan", "track", "value"]),
        (.mixerSetMasterVolume, "set_master_volume", .none, .none, ["value", "volume"]),
        (
            .mixerSetPluginParam,
            "set_plugin_param",
            .none,
            .none,
            ["insert", "param", "track", "value"]
        ),
        (
            .mixerInsertPlugin,
            "insert_plugin",
            .l2,
            .none,
            [
                "confirmed", "index", "insert", "name", "plugin", "plugin_name", "slot",
                "track", "track_index",
            ]
        ),
    ] as [(OperationID, String, ConfirmationPolicy, TargetPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicMixer,
            command: entry.1,
            mutability: Mutability.`mutating`,
            confirmation: entry.2,
            target: entry.3,
            verification: .readbackRequired,
            retry: .neverAutomatic,
            deadline: .short,
            availability: .defaultInstall,
            allowedParams: allowedParams(
                for: entry.0,
                target: entry.3,
                commandSpecific: entry.4
            ),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.navigateGotoBar, "goto_bar", .readbackRequired, .defaultInstall, ["bar"]),
        (.navigateGotoMarker, "goto_marker", .readbackRequired, .defaultInstall, ["index", "name"]),
        (.navigateCreateMarker, "create_marker", .readbackRequired, .defaultInstall, ["name"]),
        (.navigateDeleteMarker, "delete_marker", .none, .requiresKeyBinding, ["index"]),
        (.navigateRenameMarker, "rename_marker", .none, .unsupported, ["index", "name"]),
        (.navigateZoomToFit, "zoom_to_fit", .readbackRequired, .defaultInstall, []),
        (.navigateSetZoom, "set_zoom", .readbackRequired, .defaultInstall, ["direction", "level"]),
        (.navigateToggleView, "toggle_view", .none, .defaultInstall, ["view"]),
    ] as [(OperationID, String, VerificationPolicy, AvailabilityPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicNavigate,
            command: entry.1,
            mutability: Mutability.`mutating`,
            confirmation: .none,
            target: .none,
            verification: entry.2,
            retry: .neverAutomatic,
            deadline: .short,
            availability: entry.3,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.4),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (
            .audioAnalyzeFile,
            "analyze_file",
            Mutability.readOnly,
            [
                "expected_channel_count", "expected_duration_seconds", "expected_sample_rate",
                "max_decoded_frames", "max_duration_drift_seconds", "max_input_duration_seconds",
                "max_input_file_size_bytes", "max_peak_dbfs", "max_silence_ratio",
                "maximum_decoded_frames", "maximum_duration_drift_seconds",
                "maximum_input_duration_seconds", "maximum_input_file_size_bytes",
                "maximum_peak_dbfs", "maximum_silence_ratio", "min_duration_seconds",
                "min_file_size_bytes", "minimum_duration_seconds", "minimum_file_size_bytes",
                "near_silence_dbfs", "near_silence_threshold_dbfs", "output_root", "path",
            ]
        ),
    ] as [(OperationID, String, Mutability, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicAudio,
            command: entry.1,
            mutability: entry.2,
            confirmation: .none,
            target: .none,
            verification: .none,
            retry: .neverAutomatic,
            deadline: .short,
            availability: .defaultInstall,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.3),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.systemHealth, "health", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, []),
        (.systemPermissions, "permissions", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, []),
        (.systemRefreshCache, "refresh_cache", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, []),
        (.systemListRecentTraces, "list_recent_traces", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, ["limit"]),
        (.systemGetTrace, "get_trace", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, ["trace_id"]),
        // WHY: trace deletion destroys internal evidence, not Logic state, so it stays readOnly and bypasses the Logic-write gate.
        (.systemClearTraces, "clear_traces", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, ["confirmed"]),
        (.systemExportSupportBundle, "export_support_bundle", Mutability.`mutating`, DeadlineClass.medium, VerificationPolicy.readbackRequired, ["dir"]),
        (.systemHelp, "help", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, ["category"]),
        (.systemSagaPreflight, "saga_preflight", Mutability.readOnly, DeadlineClass.medium, VerificationPolicy.none, ["idempotency_key", "steps"]),
        (.systemSagaExecute, "saga_execute", Mutability.`mutating`, DeadlineClass.long, VerificationPolicy.readbackRequired, ["idempotency_key", "steps"]),
        (.systemSagaStatus, "saga_status", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, ["idempotency_key"]),
        (.systemSagaCancel, "saga_cancel", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["idempotency_key"]),
    ] as [(OperationID, String, Mutability, DeadlineClass, VerificationPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicSystem,
            command: entry.1,
            mutability: entry.2,
            confirmation: entry.0 == .systemClearTraces ? .l2 : .none,
            target: .none,
            verification: entry.4,
            retry: .neverAutomatic,
            deadline: entry.3,
            availability: .defaultInstall,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.5),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (
            .pluginsGetInventory,
            "get_inventory",
            Mutability.readOnly,
            DeadlineClass.short,
            VerificationPolicy.none,
            TargetPolicy.none,
            ["index", "track", "track_index"]
        ),
        (
            .pluginsSetParamVerified,
            "set_param_verified",
            Mutability.`mutating`,
            DeadlineClass.medium,
            VerificationPolicy.readbackRequired,
            TargetPolicy.requiresStableTarget,
            [
                "insert", "mode", "param", "plugin", "plugin_id", "plugin_name",
                "project_expected_path", "track", "unit", "value",
            ]
        ),
        (
            .pluginsInsertVerified,
            "insert_verified",
            Mutability.`mutating`,
            DeadlineClass.medium,
            VerificationPolicy.readbackRequired,
            TargetPolicy.requiresStableTarget,
            [
                "insert", "mode", "plugin", "plugin_id", "plugin_name", "project_expected_path",
                "slot", "track",
            ]
        ),
    ] as [(OperationID, String, Mutability, DeadlineClass, VerificationPolicy, TargetPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicPlugins,
            command: entry.1,
            mutability: entry.2,
            confirmation: .none,
            target: entry.5,
            verification: entry.4,
            retry: .neverAutomatic,
            deadline: entry.3,
            availability: .defaultInstall,
            allowedParams: allowedParams(
                for: entry.0,
                target: entry.5,
                commandSpecific: entry.6
            ),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.editUndo, "undo", AvailabilityPolicy.defaultInstall, VerificationPolicy.none, []),
        (.editRedo, "redo", .defaultInstall, .none, []),
        (.editCut, "cut", .defaultInstall, .none, []),
        (.editCopy, "copy", .defaultInstall, .none, []),
        (.editPaste, "paste", .defaultInstall, .none, []),
        (.editDelete, "delete", .defaultInstall, .none, []),
        (.editSelectAll, "select_all", .defaultInstall, .none, []),
        (.editSplit, "split", .defaultInstall, .none, []),
        (.editJoin, "join", .defaultInstall, .none, []),
        (.editQuantize, "quantize", .defaultInstall, .none, ["grid", "value"]),
        (.editBounceInPlace, "bounce_in_place", .defaultInstall, .none, []),
        (.editNormalize, "normalize", .requiresKeyBinding, .none, []),
        (.editDuplicate, "duplicate", .requiresKeyBinding, .none, []),
        (.editToggleStepInput, "toggle_step_input", .requiresKeyBinding, .none, []),
    ] as [(OperationID, String, AvailabilityPolicy, VerificationPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicEdit,
            command: entry.1,
            mutability: Mutability.`mutating`,
            confirmation: .none,
            target: .none,
            verification: entry.3,
            retry: .neverAutomatic,
            deadline: .short,
            availability: entry.2,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.4),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.projectNew, "new", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.medium, []),
        (.projectOpen, "open", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long, ["confirmed", "path"]),
        (.projectSave, "save", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.medium, []),
        (.projectSaveAs, "save_as", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long, ["confirmed", "path"]),
        (.projectClose, "close", Mutability.`mutating`, ConfirmationPolicy.l3, VerificationPolicy.none, DeadlineClass.medium, ["confirmed", "saving"]),
        (.projectBounce, "bounce", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long, ["confirmed"]),
        (.projectIsRunning, "is_running", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short, []),
        (.projectLaunch, "launch", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.short, []),
        (.projectQuit, "quit", Mutability.`mutating`, ConfirmationPolicy.l3, VerificationPolicy.readbackRequired, DeadlineClass.medium, ["confirmed"]),
        (.projectGetRegions, "get_regions", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short, []),
        (
            .projectExportPlan,
            "export_plan",
            Mutability.readOnly,
            ConfirmationPolicy.none,
            VerificationPolicy.none,
            DeadlineClass.short,
            [
                "artifact", "artifacts", "collision_policy", "kind", "naming_policy",
                "outputRoot", "output_root", "path", "project", "projects",
            ]
        ),
        (
            .projectExportRun,
            "export_run",
            Mutability.`mutating`,
            ConfirmationPolicy.l2,
            VerificationPolicy.readbackRequired,
            DeadlineClass.long,
            [
                "artifact", "artifacts", "collision_policy", "confirmed", "kind", "naming_policy",
                "outputRoot", "output_root", "path", "project", "projects",
            ]
        ),
        (
            .projectExportResume,
            "export_resume",
            Mutability.`mutating`,
            ConfirmationPolicy.l2,
            VerificationPolicy.readbackRequired,
            DeadlineClass.long,
            [
                "artifact", "artifacts", "collision_policy", "confirmed", "kind", "naming_policy",
                "outputRoot", "output_root", "path", "project", "projects",
            ]
        ),
        (.projectAudit, "audit", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short, []),
        (.projectCleanupPlan, "cleanup_plan", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short, []),
        (
            .projectCleanupApply,
            "cleanup_apply",
            Mutability.`mutating`,
            ConfirmationPolicy.l1,
            VerificationPolicy.readbackRequired,
            DeadlineClass.medium,
            ["confirmed", "name", "names", "new_name", "stepId", "step_id"]
        ),
    ] as [(OperationID, String, Mutability, ConfirmationPolicy, VerificationPolicy, DeadlineClass, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicProject,
            command: entry.1,
            mutability: entry.2,
            confirmation: entry.3,
            target: .none,
            verification: entry.4,
            retry: .neverAutomatic,
            deadline: entry.5,
            availability: .defaultInstall,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.6),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.midiSendNote, "send_note", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["channel", "duration_ms", "note", "port", "velocity"]),
        (.midiSendChord, "send_chord", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["channel", "duration_ms", "notes", "port", "velocity"]),
        (.midiSendCC, "send_cc", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["channel", "controller", "port", "value"]),
        (.midiSendProgramChange, "send_program_change", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["channel", "port", "program"]),
        (.midiSendPitchBend, "send_pitch_bend", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["channel", "port", "value"]),
        (.midiSendAftertouch, "send_aftertouch", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["channel", "port", "value"]),
        (.midiSendSysEx, "send_sysex", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["bytes", "data"]),
        (.midiPlaySequence, "play_sequence", Mutability.`mutating`, DeadlineClass.medium, VerificationPolicy.none, ["notes", "port"]),
        (.midiImportFile, "import_file", Mutability.`mutating`, DeadlineClass.long, VerificationPolicy.readbackRequired, ["path"]),
        (.midiListPorts, "list_ports", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, []),
        (.midiCreateVirtualPort, "create_virtual_port", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["name"]),
        (.midiStepInput, "step_input", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, ["duration", "note"]),
        (.midiMMCPlay, "mmc_play", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, []),
        (.midiMMCStop, "mmc_stop", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, []),
        (.midiMMCRecord, "mmc_record", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, []),
        (.midiMMCLocate, "mmc_locate", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.bestEffort, ["bar", "time"]),
    ] as [(OperationID, String, Mutability, DeadlineClass, VerificationPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicMidi,
            command: entry.1,
            mutability: entry.2,
            confirmation: .none,
            target: .none,
            verification: entry.4,
            retry: .neverAutomatic,
            deadline: entry.3,
            availability: .defaultInstall,
            allowedParams: allowedParams(for: entry.0, commandSpecific: entry.5),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (
            .tracksSelect,
            "select",
            Mutability.`mutating`,
            DeadlineClass.short,
            VerificationPolicy.readbackRequired,
            TargetPolicy.requiresStableTarget,
            ["index", "name", "track"]
        ),
        (.tracksCreateAudio, "create_audio", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.none, []),
        (.tracksCreateInstrument, "create_instrument", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.none, []),
        (.tracksCreateDrummer, "create_drummer", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.none, []),
        (.tracksCreateExternalMIDI, "create_external_midi", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.none, []),
        (.tracksDelete, "delete", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["index", "track"]),
        (.tracksDuplicate, "duplicate", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, TargetPolicy.requiresStableTarget, ["index", "track"]),
        (.tracksRename, "rename", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["index", "name", "track"]),
        (.tracksMute, "mute", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["enabled", "index", "track"]),
        (.tracksSolo, "solo", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["enabled", "index", "track"]),
        (.tracksArm, "arm", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["enabled", "index", "track"]),
        (.tracksArmOnly, "arm_only", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["index", "track"]),
        (.tracksRecordSequence, "record_sequence", Mutability.`mutating`, DeadlineClass.long, VerificationPolicy.readbackRequired, TargetPolicy.none, ["bar", "notes", "tempo"]),
        (.tracksSetAutomation, "set_automation", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none, TargetPolicy.requiresStableTarget, ["index", "mode", "track"]),
        (.tracksSetInstrument, "set_instrument", Mutability.`mutating`, DeadlineClass.medium, VerificationPolicy.readbackRequired, TargetPolicy.requiresStableTarget, ["category", "index", "path", "preset"]),
        (.tracksListLibrary, "list_library", Mutability.readOnly, DeadlineClass.long, VerificationPolicy.none, TargetPolicy.none, []),
        (.tracksScanLibrary, "scan_library", Mutability.readOnly, DeadlineClass.long, VerificationPolicy.none, TargetPolicy.none, ["mode"]),
        (.tracksResolvePath, "resolve_path", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none, TargetPolicy.none, ["path"]),
        (.tracksScanPluginPresets, "scan_plugin_presets", Mutability.readOnly, DeadlineClass.long, VerificationPolicy.none, TargetPolicy.none, ["submenuOpenDelayMs"]),
    ] as [(OperationID, String, Mutability, DeadlineClass, VerificationPolicy, TargetPolicy, Set<String>)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicTracks,
            command: entry.1,
            mutability: entry.2,
            confirmation: .none,
            target: entry.5,
            verification: entry.4,
            retry: .neverAutomatic,
            deadline: entry.3,
            availability: .defaultInstall,
            allowedParams: allowedParams(
                for: entry.0,
                target: entry.5,
                commandSpecific: entry.6
            ),
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    }

    static func spec(tool: String, command: String) -> OperationSpec? {
        specs.first { $0.tool.rawValue == tool && $0.command == command }
    }

    static func mutatingCommands(tool: ToolID) -> Set<String> {
        Set(specs.filter { $0.tool == tool && $0.mutability == Mutability.`mutating` }.map(\.command))
    }

    static func deadlineSeconds(tool: String, command: String) -> Double? {
        spec(tool: tool, command: command)?.deadline.seconds
    }

    static func validationErrors(for candidateSpecs: [OperationSpec] = specs) -> [String] {
        validationErrors(for: candidateSpecs.map {
            ValidationEntry(operationID: $0.id.rawValue, tool: $0.tool.rawValue, command: $0.command)
        })
    }

    static func validationErrors(for entries: [ValidationEntry]) -> [String] {
        var errors: [String] = []

        if entries.count != allowedOperationIDs.count {
            errors.append("entry count: expected \(allowedOperationIDs.count), got \(entries.count)")
        }

        let duplicateIDs = Dictionary(grouping: entries.map(\.operationID), by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
        if !duplicateIDs.isEmpty {
            errors.append("duplicate operation IDs: \(duplicateIDs.joined(separator: ", "))")
        }

        let duplicateCommands = Dictionary(grouping: entries.map { "\($0.tool):\($0.command)" }, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
        if !duplicateCommands.isEmpty {
            errors.append("duplicate commands: \(duplicateCommands.joined(separator: ", "))")
        }

        let actualIDs = Set(entries.map(\.operationID))
        let missingIDs = allowedOperationIDs.subtracting(actualIDs).sorted()
        if !missingIDs.isEmpty {
            errors.append("missing operation IDs: \(missingIDs.joined(separator: ", "))")
        }
        let unexpectedIDs = actualIDs.subtracting(allowedOperationIDs).sorted()
        if !unexpectedIDs.isEmpty {
            errors.append("unexpected operation IDs: \(unexpectedIDs.joined(separator: ", "))")
        }

        for tool in allowedCommandsByTool.keys.sorted() {
            let toolEntries = entries.filter { $0.tool == tool }
            let actualCommands = Set(toolEntries.map(\.command))
            let allowedCommands = allowedCommandsByTool[tool] ?? []
            let missingCommands = allowedCommands.subtracting(actualCommands).sorted()
            if !missingCommands.isEmpty {
                errors.append("missing commands: \(missingCommands.joined(separator: ", "))")
            }
            let unexpectedCommands = actualCommands.subtracting(allowedCommands).sorted()
            if !unexpectedCommands.isEmpty {
                errors.append("unexpected commands: \(unexpectedCommands.joined(separator: ", "))")
            }
        }

        let expectedTools = allowedOperationIDsByTool.reduce(into: [String: String]()) { result, entry in
            for operationID in entry.value {
                result[operationID] = entry.key
            }
        }
        let incorrectTools = entries
            .filter { entry in
                guard let expectedTool = expectedTools[entry.operationID] else {
                    return !allowedOperationIDsByTool.keys.contains(entry.tool)
                }
                return entry.tool != expectedTool
            }
            .map { "\($0.command)=\($0.tool)" }
            .sorted()
        if !incorrectTools.isEmpty {
            errors.append("incorrect tools: \(incorrectTools.joined(separator: ", "))")
        }

        let operationPrefixes = [
            ToolID.logicTransport.rawValue: "transport",
            ToolID.logicMixer.rawValue: "mixer",
            ToolID.logicNavigate.rawValue: "navigate",
            ToolID.logicAudio.rawValue: "audio",
            ToolID.logicSystem.rawValue: "system",
            ToolID.logicPlugins.rawValue: "plugins",
            ToolID.logicEdit.rawValue: "edit",
            ToolID.logicProject.rawValue: "project",
            ToolID.logicMidi.rawValue: "midi",
            ToolID.logicTracks.rawValue: "tracks",
        ]
        let mismatches = entries
            .filter { entry in
                guard let prefix = operationPrefixes[entry.tool] else { return true }
                return entry.operationID != "\(prefix).\(entry.command)"
            }
            .map { "\($0.operationID)=\($0.command)" }
            .sorted()
        if !mismatches.isEmpty {
            errors.append("ID/command mismatches: \(mismatches.joined(separator: ", "))")
        }

        return errors
    }
}
