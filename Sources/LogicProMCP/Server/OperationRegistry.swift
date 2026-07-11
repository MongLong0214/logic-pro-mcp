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
    case systemHelp = "system.help"
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
            "system.health", "system.permissions", "system.refresh_cache", "system.help",
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
            "health", "permissions", "refresh_cache", "help",
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
    ]

    private static let allowedOperationIDs = Set(allowedOperationIDsByTool.values.flatMap { $0 })
    static let registeredToolRawValues = Set(allowedOperationIDsByTool.keys)

    static let specs: [OperationSpec] = ([
        (.transportPlay, "play", .readbackRequired, .defaultInstall),
        (.transportStop, "stop", .readbackRequired, .defaultInstall),
        (.transportRecord, "record", .readbackRequired, .defaultInstall),
        (.transportPause, "pause", .readbackRequired, .defaultInstall),
        (.transportRewind, "rewind", .none, .defaultInstall),
        (.transportFastForward, "fast_forward", .none, .defaultInstall),
        (.transportToggleCycle, "toggle_cycle", .none, .defaultInstall),
        (.transportToggleMetronome, "toggle_metronome", .readbackRequired, .defaultInstall),
        (.transportSetTempo, "set_tempo", .none, .defaultInstall),
        (.transportGotoPosition, "goto_position", .readbackRequired, .defaultInstall),
        (.transportSetCycleRange, "set_cycle_range", .none, .unsupported),
        (.transportToggleCountIn, "toggle_count_in", .none, .defaultInstall),
        (.transportToggleAutopunch, "toggle_autopunch", .none, .defaultInstall),
    ] as [(OperationID, String, VerificationPolicy, AvailabilityPolicy)]).map { entry in
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
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.mixerSetVolume, "set_volume", .none),
        (.mixerSetPan, "set_pan", .none),
        (.mixerSetMasterVolume, "set_master_volume", .none),
        (.mixerSetPluginParam, "set_plugin_param", .none),
        (.mixerInsertPlugin, "insert_plugin", .l2),
    ] as [(OperationID, String, ConfirmationPolicy)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicMixer,
            command: entry.1,
            mutability: Mutability.`mutating`,
            confirmation: entry.2,
            target: .none,
            verification: .readbackRequired,
            retry: .neverAutomatic,
            deadline: .short,
            availability: .defaultInstall,
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.navigateGotoBar, "goto_bar", .readbackRequired, .defaultInstall),
        (.navigateGotoMarker, "goto_marker", .readbackRequired, .defaultInstall),
        (.navigateCreateMarker, "create_marker", .readbackRequired, .defaultInstall),
        (.navigateDeleteMarker, "delete_marker", .none, .requiresKeyBinding),
        (.navigateRenameMarker, "rename_marker", .none, .unsupported),
        (.navigateZoomToFit, "zoom_to_fit", .readbackRequired, .defaultInstall),
        (.navigateSetZoom, "set_zoom", .readbackRequired, .defaultInstall),
        (.navigateToggleView, "toggle_view", .none, .defaultInstall),
    ] as [(OperationID, String, VerificationPolicy, AvailabilityPolicy)]).map { entry in
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
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.audioAnalyzeFile, "analyze_file", Mutability.readOnly),
    ] as [(OperationID, String, Mutability)]).map { entry in
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
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.systemHealth, "health", Mutability.readOnly),
        (.systemPermissions, "permissions", Mutability.readOnly),
        (.systemRefreshCache, "refresh_cache", Mutability.readOnly),
        (.systemHelp, "help", Mutability.readOnly),
    ] as [(OperationID, String, Mutability)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicSystem,
            command: entry.1,
            mutability: entry.2,
            confirmation: .none,
            target: .none,
            verification: .none,
            retry: .neverAutomatic,
            deadline: .short,
            availability: .defaultInstall,
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.pluginsGetInventory, "get_inventory", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none),
        (.pluginsSetParamVerified, "set_param_verified", Mutability.`mutating`, DeadlineClass.medium, VerificationPolicy.readbackRequired),
        (.pluginsInsertVerified, "insert_verified", Mutability.`mutating`, DeadlineClass.medium, VerificationPolicy.readbackRequired),
    ] as [(OperationID, String, Mutability, DeadlineClass, VerificationPolicy)]).map { entry in
        OperationSpec(
            id: entry.0,
            tool: .logicPlugins,
            command: entry.1,
            mutability: entry.2,
            confirmation: .none,
            target: .none,
            verification: entry.4,
            retry: .neverAutomatic,
            deadline: entry.3,
            availability: .defaultInstall,
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.editUndo, "undo", AvailabilityPolicy.defaultInstall, VerificationPolicy.none),
        (.editRedo, "redo", .defaultInstall, .none),
        (.editCut, "cut", .defaultInstall, .none),
        (.editCopy, "copy", .defaultInstall, .none),
        (.editPaste, "paste", .defaultInstall, .none),
        (.editDelete, "delete", .defaultInstall, .none),
        (.editSelectAll, "select_all", .defaultInstall, .none),
        (.editSplit, "split", .defaultInstall, .none),
        (.editJoin, "join", .defaultInstall, .none),
        (.editQuantize, "quantize", .defaultInstall, .none),
        (.editBounceInPlace, "bounce_in_place", .defaultInstall, .none),
        (.editNormalize, "normalize", .requiresKeyBinding, .none),
        (.editDuplicate, "duplicate", .requiresKeyBinding, .none),
        (.editToggleStepInput, "toggle_step_input", .requiresKeyBinding, .none),
    ] as [(OperationID, String, AvailabilityPolicy, VerificationPolicy)]).map { entry in
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
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.projectNew, "new", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.medium),
        (.projectOpen, "open", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long),
        (.projectSave, "save", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.medium),
        (.projectSaveAs, "save_as", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long),
        (.projectClose, "close", Mutability.`mutating`, ConfirmationPolicy.l3, VerificationPolicy.none, DeadlineClass.medium),
        (.projectBounce, "bounce", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long),
        (.projectIsRunning, "is_running", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short),
        (.projectLaunch, "launch", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.short),
        (.projectQuit, "quit", Mutability.`mutating`, ConfirmationPolicy.l3, VerificationPolicy.readbackRequired, DeadlineClass.medium),
        (.projectGetRegions, "get_regions", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short),
        (.projectExportPlan, "export_plan", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short),
        (.projectExportRun, "export_run", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long),
        (.projectExportResume, "export_resume", Mutability.`mutating`, ConfirmationPolicy.l2, VerificationPolicy.readbackRequired, DeadlineClass.long),
        (.projectAudit, "audit", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short),
        (.projectCleanupPlan, "cleanup_plan", Mutability.readOnly, ConfirmationPolicy.none, VerificationPolicy.none, DeadlineClass.short),
        (.projectCleanupApply, "cleanup_apply", Mutability.`mutating`, ConfirmationPolicy.l1, VerificationPolicy.readbackRequired, DeadlineClass.medium),
    ] as [(OperationID, String, Mutability, ConfirmationPolicy, VerificationPolicy, DeadlineClass)]).map { entry in
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
            capability: CapabilityID(rawValue: entry.0.rawValue)
        )
    } + ([
        (.midiSendNote, "send_note", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiSendChord, "send_chord", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiSendCC, "send_cc", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiSendProgramChange, "send_program_change", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiSendPitchBend, "send_pitch_bend", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiSendAftertouch, "send_aftertouch", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiSendSysEx, "send_sysex", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiPlaySequence, "play_sequence", Mutability.`mutating`, DeadlineClass.medium, VerificationPolicy.none),
        (.midiImportFile, "import_file", Mutability.`mutating`, DeadlineClass.long, VerificationPolicy.readbackRequired),
        (.midiListPorts, "list_ports", Mutability.readOnly, DeadlineClass.short, VerificationPolicy.none),
        (.midiCreateVirtualPort, "create_virtual_port", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiStepInput, "step_input", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiMMCPlay, "mmc_play", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiMMCStop, "mmc_stop", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiMMCRecord, "mmc_record", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.none),
        (.midiMMCLocate, "mmc_locate", Mutability.`mutating`, DeadlineClass.short, VerificationPolicy.bestEffort),
    ] as [(OperationID, String, Mutability, DeadlineClass, VerificationPolicy)]).map { entry in
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
