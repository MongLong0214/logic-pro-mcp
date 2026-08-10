import Testing
@testable import LogicProMCP

@Suite("Operation registry", .serialized)
struct OperationRegistryTests {
    private static let commands: [(OperationID, String)] = [
        (.transportPlay, "play"),
        (.transportStop, "stop"),
        (.transportRecord, "record"),
        (.transportPause, "pause"),
        (.transportRewind, "rewind"),
        (.transportFastForward, "fast_forward"),
        (.transportToggleCycle, "toggle_cycle"),
        (.transportToggleMetronome, "toggle_metronome"),
        (.transportSetTempo, "set_tempo"),
        (.transportGotoPosition, "goto_position"),
        (.transportSetCycleRange, "set_cycle_range"),
        (.transportToggleCountIn, "toggle_count_in"),
        (.transportToggleAutopunch, "toggle_autopunch"),
    ]

    private static let readbackCommands: Set<String> = [
        "play", "stop", "record", "pause", "toggle_metronome", "goto_position",
    ]

    private static let mixerCommands: [(OperationID, String)] = [
        (.mixerSetVolume, "set_volume"),
        (.mixerSetPan, "set_pan"),
        (.mixerSetMasterVolume, "set_master_volume"),
        (.mixerSetPluginParam, "set_plugin_param"),
        (.mixerInsertPlugin, "insert_plugin"),
    ]

    private static let navigateCommands: [(String, String)] = [
        ("navigate.goto_bar", "goto_bar"),
        ("navigate.goto_marker", "goto_marker"),
        ("navigate.create_marker", "create_marker"),
        ("navigate.delete_marker", "delete_marker"),
        ("navigate.rename_marker", "rename_marker"),
        ("navigate.zoom_to_fit", "zoom_to_fit"),
        ("navigate.set_zoom", "set_zoom"),
        ("navigate.toggle_view", "toggle_view"),
    ]

    private static let unverifiedNavigateCommands: Set<String> = [
        "delete_marker", "toggle_view",
    ]

    private static let navigateAvailabilityOverrides: [String: AvailabilityPolicy] = [
        "delete_marker": .requiresKeyBinding,
    ]

    private static let smallToolCount = 19
    private static let expectedRegistryCount =
        commands.count + mixerCommands.count + navigateCommands.count + smallToolCount
            + editCommands.count + projectCommands.count + midiCommands.count + trackCommands.count

    @Test("transport registry is exact, unique, and valid")
    func completenessAndValidation() {
        let transportSpecs = OperationRegistry.specs.filter { $0.tool == .logicTransport }
        #expect(transportSpecs.count == 13)
        #expect(Set(transportSpecs.map(\.command)).count == 13)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(DeadlineClass.short.seconds == 25)
        #expect(DeadlineClass.medium.seconds == 90)
        #expect(DeadlineClass.long.seconds == 300)
        #expect(OperationRegistry.validationErrors().isEmpty)
    }

    @Test("raw validation rejects every malformed registry shape")
    func malformedRawEntries() throws {
        let entries = OperationRegistry.specs.map {
            OperationRegistry.ValidationEntry(
                operationID: $0.id.rawValue,
                tool: $0.tool.rawValue,
                command: $0.command
            )
        }
        let first = try #require(entries.first)
        let second = try #require(entries.dropFirst().first)

        var duplicateID = entries
        duplicateID.append(.init(operationID: first.operationID, tool: first.tool, command: "duplicate_id_probe"))

        var duplicateCommand = entries
        duplicateCommand.append(.init(operationID: "transport.duplicate_command_probe", tool: first.tool, command: first.command))

        var unexpectedID = entries
        unexpectedID[0] = .init(operationID: "transport.unexpected", tool: first.tool, command: first.command)

        var unexpectedCommand = entries
        unexpectedCommand[0] = .init(operationID: first.operationID, tool: first.tool, command: "unexpected")

        var wrongTool = entries
        wrongTool[0] = .init(operationID: first.operationID, tool: "logic_midi", command: first.command)

        var mismatch = entries
        mismatch[0] = .init(operationID: second.operationID, tool: first.tool, command: first.command)
        mismatch[1] = .init(operationID: first.operationID, tool: second.tool, command: second.command)

        let cases: [([OperationRegistry.ValidationEntry], String)] = [
            (duplicateID, "duplicate operation IDs:"),
            (duplicateCommand, "duplicate commands:"),
            (Array(entries.dropLast()), "entry count:"),
            (Array(entries.dropLast()), "missing operation IDs:"),
            (Array(entries.dropLast()), "missing commands:"),
            (unexpectedID, "unexpected operation IDs:"),
            (unexpectedCommand, "unexpected commands:"),
            (wrongTool, "incorrect tools:"),
            (mismatch, "ID/command mismatches:"),
        ]
        for (malformed, message) in cases {
            #expect(OperationRegistry.validationErrors(for: malformed).contains { $0.contains(message) })
        }
    }

    @Test("all transport metadata matches current runtime truth")
    func metadata() throws {
        let transportCommands = OperationRegistry.specs
            .filter { $0.tool == .logicTransport }
            .map(\.command)
        #expect(Set(Self.commands.map(\.1)) == Set(transportCommands))

        for (id, command) in Self.commands {
            let spec = try #require(OperationRegistry.spec(tool: ToolID.logicTransport.rawValue, command: command))
            #expect(spec.id == id)
            #expect(spec.tool == .logicTransport)
            #expect(spec.command == command)
            #expect(spec.mutability == Mutability.`mutating`)
            #expect(spec.confirmation == .none)
            #expect(spec.target == .none)
            #expect(spec.verification == (Self.readbackCommands.contains(command) ? .readbackRequired : .none))
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == .short)
            #expect(spec.availability == (command == "set_cycle_range" ? .unsupported : .defaultInstall))
            #expect(spec.capability.rawValue == id.rawValue)
        }

        #expect(OperationRegistry.spec(tool: "logic_transport", command: "set_tempo")?.verification == VerificationPolicy.none)
        let cycleRange = try #require(OperationRegistry.spec(tool: "logic_transport", command: "set_cycle_range"))
        #expect(cycleRange.verification == .none)
        #expect(cycleRange.availability == .unsupported)
    }

    @Test("derived mutating commands equal the transport command set")
    func mutatingParity() {
        #expect(OperationRegistry.mutatingCommands(tool: .logicTransport) == Set(Self.commands.map(\.1)))
    }

    @Test("mixer registry is exact, unique, and isolated")
    func mixerCompletenessAndIsolation() {
        #expect(OperationRegistry.specs.count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map { "\($0.tool.rawValue):\($0.command)" }).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(OperationRegistry.validationErrors().isEmpty)
        #expect(OperationRegistry.spec(tool: ToolID.logicMixer.rawValue, command: "play") == nil)
        #expect(OperationRegistry.spec(tool: ToolID.logicTransport.rawValue, command: "set_volume") == nil)
        #expect(OperationRegistry.spec(tool: "logic_midi", command: "set_volume") == nil)
        #expect(OperationRegistry.spec(tool: ToolID.logicMixer.rawValue, command: "unknown") == nil)
    }

    @Test("all mixer metadata matches current runtime truth")
    func mixerMetadata() throws {
        let mixerSpecs = OperationRegistry.specs.filter { $0.tool == .logicMixer }
        let targetBearingCommands: Set<String> = ["set_volume", "set_pan"]
        #expect(Set(Self.mixerCommands.map(\.1)) == Set(mixerSpecs.map(\.command)))

        for (id, command) in Self.mixerCommands {
            let spec = try #require(OperationRegistry.spec(tool: ToolID.logicMixer.rawValue, command: command))
            #expect(spec.id == id)
            #expect(spec.tool == .logicMixer)
            #expect(spec.command == command)
            #expect(spec.mutability == Mutability.`mutating`)
            #expect(spec.confirmation == (command == "insert_plugin" ? .l2 : .none))
            #expect(spec.target == (targetBearingCommands.contains(command) ? .acceptsStableTarget : .none))
            #expect(spec.verification == .readbackRequired)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == .short)
            #expect(spec.availability == .defaultInstall)
            #expect(spec.capability.rawValue == id.rawValue)
        }
    }

    @Test("derived mixer mutations and deadlines match server decisions")
    func mixerLegacyParity() {
        #expect(OperationRegistry.mutatingCommands(tool: .logicMixer) == Set(Self.mixerCommands.map(\.1)))
        for (_, command) in Self.mixerCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: ToolID.logicMixer.rawValue, command: command) == 25)
            #expect(LogicProServer.isMutatingCommand(tool: ToolID.logicMixer.rawValue, command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: ToolID.logicMixer.rawValue, command: command) == 25)
        }
    }

    @Test("validation rejects a mixer command assigned to transport")
    func mixerWrongToolValidation() throws {
        var entries = OperationRegistry.specs.map {
            OperationRegistry.ValidationEntry(
                operationID: $0.id.rawValue,
                tool: $0.tool.rawValue,
                command: $0.command
            )
        }
        let index = try #require(entries.firstIndex { $0.command == "set_volume" })
        entries[index] = .init(
            operationID: entries[index].operationID,
            tool: ToolID.logicTransport.rawValue,
            command: entries[index].command
        )
        #expect(OperationRegistry.validationErrors(for: entries).contains { $0.contains("incorrect tools:") })
    }

    @Test("mixer decisions are registry-backed")
    func mixerFlagOff() {
        for (_, command) in Self.mixerCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_mixer", command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: command) == 25)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_mixer", command: "play"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: "play") == 25)
    }

    @Test("mixer decisions stay cross-tool isolated")
    func mixerFlagOn() {
        for (_, command) in Self.mixerCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_mixer", command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: command) == 25)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_mixer", command: "play"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: "import_file") == 25)
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
    }

    @Test("registry short deadlines match server decisions")
    func deadlineParity() {
        for spec in OperationRegistry.specs where [
            ToolID.logicTransport, .logicMixer, .logicNavigate,
        ].contains(spec.tool) {
            #expect(spec.deadline.seconds == 25)
            #expect(OperationRegistry.deadlineSeconds(tool: spec.tool.rawValue, command: spec.command) == 25)
            #expect(LogicProServer.commandDeadlineSeconds(tool: spec.tool.rawValue, command: spec.command) == 25)
        }
    }

    @Test("transport decisions are registry-backed")
    func flagOff() {
        for (_, command) in Self.commands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_transport", command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: command) == 25)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_transport", command: "unknown"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: "unknown") == 25)
    }

    @Test("transport decisions stay cross-tool isolated")
    func flagOn() {
        for spec in OperationRegistry.specs where [
            ToolID.logicTransport, .logicMixer, .logicNavigate,
        ].contains(spec.tool) {
            #expect(LogicProServer.isMutatingCommand(tool: spec.tool.rawValue, command: spec.command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: spec.tool.rawValue, command: spec.command) == 25)
        }
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: "import_file") == 300)
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_transport", command: "bounce"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: "bounce") == 25)
    }

    @Test("navigate registry is exact, unique, and isolated")
    func navigateCompletenessAndIsolation() throws {
        let tool = try #require(ToolID(rawValue: "logic_navigate"))
        let navigateSpecs = OperationRegistry.specs.filter { $0.tool == tool }
        #expect(navigateSpecs.count == Self.navigateCommands.count)
        #expect(Set(navigateSpecs.map(\.command)) == Set(Self.navigateCommands.map(\.1)))
        #expect(Set(navigateSpecs.map(\.id.rawValue)) == Set(Self.navigateCommands.map(\.0)))
        #expect(OperationRegistry.validationErrors().isEmpty)
        #expect(OperationRegistry.spec(tool: "logic_navigate", command: "play") == nil)
        #expect(OperationRegistry.spec(tool: ToolID.logicTransport.rawValue, command: "goto_bar") == nil)
        #expect(OperationRegistry.spec(tool: ToolID.logicMixer.rawValue, command: "goto_bar") == nil)
        #expect(OperationRegistry.spec(tool: "logic_navigate", command: "unknown") == nil)
    }

    @Test("all navigate metadata matches current runtime truth")
    func navigateMetadata() throws {
        let tool = try #require(ToolID(rawValue: "logic_navigate"))

        for (idRawValue, command) in Self.navigateCommands {
            let id = try #require(OperationID(rawValue: idRawValue))
            let spec = try #require(OperationRegistry.spec(tool: tool.rawValue, command: command))
            #expect(spec.id == id)
            #expect(spec.tool == tool)
            #expect(spec.command == command)
            #expect(spec.mutability == Mutability.`mutating`)
            #expect(spec.confirmation == .none)
            #expect(spec.target == .none)
            #expect(spec.verification == (Self.unverifiedNavigateCommands.contains(command) ? .none : .readbackRequired))
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == .short)
            #expect(spec.availability == (Self.navigateAvailabilityOverrides[command] ?? .defaultInstall))
            #expect(spec.capability.rawValue == idRawValue)
        }
    }

    @Test("derived navigate mutations and deadlines match server decisions")
    func navigateLegacyParity() throws {
        let tool = try #require(ToolID(rawValue: "logic_navigate"))
        #expect(OperationRegistry.mutatingCommands(tool: tool) == Set(Self.navigateCommands.map(\.1)))
        for (_, command) in Self.navigateCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: tool.rawValue, command: command) == 25)
            #expect(LogicProServer.isMutatingCommand(tool: tool.rawValue, command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: tool.rawValue, command: command) == 25)
        }
    }

    @Test("navigate rename marker requires verified AX readback")
    func navigateRenameMarkerVerified() throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_navigate", command: "rename_marker"))
        #expect(spec.availability == .defaultInstall)
        #expect(spec.verification == .readbackRequired)
        #expect(spec.confirmation == .none)
    }

    @Test("navigate decisions are registry-backed")
    func navigateFlagOff() {
        for (_, command) in Self.navigateCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_navigate", command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: command) == 25)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_navigate", command: "play"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: "play") == 25)
    }

    @Test("navigate decisions stay cross-tool isolated")
    func navigateFlagOn() {
        for (_, command) in Self.navigateCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_navigate", command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: command) == 25)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_navigate", command: "play"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: "import_file") == 25)
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
    }

    private static let smallToolCommands: [(
        tool: String,
        id: String,
        command: String,
        mutability: Mutability,
        deadline: DeadlineClass,
        verification: VerificationPolicy
    )] = [
        ("logic_audio", "audio.analyze_file", "analyze_file", .readOnly, .short, .none),
        ("logic_audio", "audio.analyze_spectrum", "analyze_spectrum", .readOnly, .short, .none),
        ("logic_audio", "audio.recommend_eq", "recommend_eq", .readOnly, .short, .none),
        ("logic_system", "system.health", "health", .readOnly, .short, .none),
        ("logic_system", "system.permissions", "permissions", .readOnly, .short, .none),
        ("logic_system", "system.refresh_cache", "refresh_cache", .readOnly, .short, .none),
        ("logic_system", "system.list_recent_traces", "list_recent_traces", .readOnly, .short, .none),
        ("logic_system", "system.get_trace", "get_trace", .readOnly, .short, .none),
        ("logic_system", "system.clear_traces", "clear_traces", .readOnly, .short, .none),
        ("logic_system", "system.help", "help", .readOnly, .short, .none),
        ("logic_system", "system.export_support_bundle", "export_support_bundle", .mutating, .medium, .readbackRequired),
        ("logic_system", "system.saga_preflight", "saga_preflight", .readOnly, .medium, .none),
        ("logic_system", "system.saga_execute", "saga_execute", .mutating, .long, .readbackRequired),
        ("logic_system", "system.saga_status", "saga_status", .readOnly, .short, .none),
        ("logic_system", "system.saga_cancel", "saga_cancel", .mutating, .short, .readbackRequired),
        ("logic_system", "system.setup_arm_key", "setup_arm_key", .mutating, .long, .readbackRequired),
        ("logic_plugins", "plugins.get_inventory", "get_inventory", .readOnly, .short, .none),
        ("logic_plugins", "plugins.set_param_verified", "set_param_verified", .mutating, .medium, .readbackRequired),
        ("logic_plugins", "plugins.insert_verified", "insert_verified", .mutating, .medium, .readbackRequired),
    ]

    @Test("small-tool registries are exact, unique, and isolated")
    func smallToolCompletenessAndIsolation() throws {
        #expect(OperationRegistry.specs.count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map { "\($0.tool.rawValue):\($0.command)" }).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(OperationRegistry.validationErrors().isEmpty)

        for toolRawValue in ["logic_audio", "logic_system", "logic_plugins"] {
            let tool = try #require(ToolID(rawValue: toolRawValue))
            let expected = Self.smallToolCommands.filter { $0.tool == toolRawValue }
            let actual = OperationRegistry.specs.filter { $0.tool == tool }
            #expect(Set(actual.map(\.command)) == Set(expected.map(\.command)))
            #expect(Set(actual.map(\.id.rawValue)) == Set(expected.map(\.id)))
        }

        #expect(OperationRegistry.spec(tool: "logic_audio", command: "health") == nil)
        #expect(OperationRegistry.spec(tool: "logic_system", command: "analyze_file") == nil)
        #expect(OperationRegistry.spec(tool: "logic_plugins", command: "refresh_cache") == nil)
        for command in ["list_recent_traces", "get_trace", "clear_traces"] {
            #expect(OperationRegistry.spec(tool: "logic_system", command: command) != nil)
        }
    }

    @Test("all small-tool metadata matches current runtime truth")
    func smallToolMetadata() throws {
        for entry in Self.smallToolCommands {
            let tool = try #require(ToolID(rawValue: entry.tool))
            let id = try #require(OperationID(rawValue: entry.id))
            let spec = try #require(OperationRegistry.spec(tool: entry.tool, command: entry.command))
            #expect(spec.id == id)
            #expect(spec.tool == tool)
            #expect(spec.command == entry.command)
            #expect(spec.mutability == entry.mutability)
            #expect(spec.confirmation == (id == .systemClearTraces ? .l2 : .none))
            #expect(spec.target == (
                id == .pluginsSetParamVerified || id == .pluginsInsertVerified
                    ? .acceptsStableTarget
                    : .none
            ))
            #expect(spec.verification == entry.verification)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == entry.deadline)
            // PRD-014: trace-op availability is generated from the feature
            // policy (defaultInstall only when tracing was enabled when the
            // registry was built); everything else stays defaultInstall.
            #expect(spec.availability == (
                OperationRegistry.traceOperationIDs.contains(id)
                    ? OperationRegistry.traceAvailability(
                        traceEnabled: OperationRegistry.traceEnabledAtRegistryBuild
                    )
                    : .defaultInstall
            ))
            #expect(spec.capability.rawValue == entry.id)
        }
    }

    @Test("derived small-tool mutations match server decisions")
    func smallToolLegacyMutationParity() throws {
        for toolRawValue in ["logic_audio", "logic_system", "logic_plugins"] {
            let tool = try #require(ToolID(rawValue: toolRawValue))
            let expected = Set(Self.smallToolCommands
                .filter { $0.tool == toolRawValue && $0.mutability == Mutability.`mutating` }
                .map(\.command))
            #expect(OperationRegistry.mutatingCommands(tool: tool) == expected)
            for entry in Self.smallToolCommands where entry.tool == toolRawValue {
                #expect(LogicProServer.isMutatingCommand(tool: toolRawValue, command: entry.command)
                    == (entry.mutability == Mutability.`mutating`))
            }
        }
    }

    @Test("read-only registry entries remain nonmutating")
    func smallToolReadOnlyFlagParity() {
        let entries = Self.smallToolCommands.filter { $0.mutability == .readOnly }

        for entry in entries {
            #expect(!LogicProServer.isMutatingCommand(tool: entry.tool, command: entry.command))
        }
    }

    @Test("plugin medium deadlines match server decisions")
    func pluginMediumDeadlineFlagParity() {
        let commands = ["set_param_verified", "insert_verified"]

        for command in commands {
            #expect(OperationRegistry.deadlineSeconds(tool: "logic_plugins", command: command) == 90)
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_plugins", command: command) == 90)
        }
    }

    @Test("small-tool decisions are registry-backed with safe unknown fallthroughs")
    func smallToolFlagGateAndFallbacks() {
        for entry in Self.smallToolCommands {
            #expect(LogicProServer.isMutatingCommand(tool: entry.tool, command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: entry.tool, command: entry.command)
                == entry.deadline.seconds)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_audio", command: "import_file"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_audio", command: "import_file") == 25)
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
    }

    private static let editCommands: [(
        id: String,
        command: String,
        availability: AvailabilityPolicy,
        verification: VerificationPolicy
    )] = [
        ("edit.undo", "undo", .defaultInstall, .none),
        ("edit.redo", "redo", .defaultInstall, .none),
        ("edit.cut", "cut", .defaultInstall, .none),
        ("edit.copy", "copy", .defaultInstall, .none),
        ("edit.paste", "paste", .defaultInstall, .none),
        ("edit.delete", "delete", .defaultInstall, .none),
        ("edit.select_all", "select_all", .defaultInstall, .none),
        ("edit.split", "split", .defaultInstall, .none),
        ("edit.join", "join", .defaultInstall, .none),
        ("edit.quantize", "quantize", .defaultInstall, .none),
        ("edit.bounce_in_place", "bounce_in_place", .defaultInstall, .none),
        ("edit.normalize", "normalize", .requiresKeyBinding, .none),
        ("edit.duplicate", "duplicate", .requiresKeyBinding, .none),
        ("edit.toggle_step_input", "toggle_step_input", .requiresKeyBinding, .none),
    ]

    @Test("edit registry is exact, unique, and isolated")
    func editCompletenessAndIsolation() throws {
        let tool = try #require(ToolID(rawValue: "logic_edit"))
        let editSpecs = OperationRegistry.specs.filter { $0.tool == tool }
        #expect(editSpecs.count == Self.editCommands.count)
        #expect(Set(editSpecs.map(\.command)) == Set(Self.editCommands.map(\.command)))
        #expect(Set(editSpecs.map(\.id.rawValue)) == Set(Self.editCommands.map(\.id)))
        #expect(OperationRegistry.specs.count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map { "\($0.tool.rawValue):\($0.command)" }).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(OperationRegistry.validationErrors().isEmpty)

        #expect(OperationRegistry.spec(tool: "logic_edit", command: "play") == nil)
        #expect(OperationRegistry.spec(tool: "logic_transport", command: "undo") == nil)
        #expect(OperationRegistry.spec(tool: "logic_mixer", command: "undo") == nil)
        #expect(OperationRegistry.spec(tool: "logic_navigate", command: "undo") == nil)
        #expect(OperationRegistry.spec(tool: "logic_edit", command: "unknown") == nil)
    }

    @Test("all edit metadata and derived availability match runtime truth")
    func editMetadataAndAvailability() throws {
        let tool = try #require(ToolID(rawValue: "logic_edit"))

        for entry in Self.editCommands {
            let id = try #require(OperationID(rawValue: entry.id))
            let spec = try #require(OperationRegistry.spec(tool: tool.rawValue, command: entry.command))
            #expect(spec.id == id)
            #expect(spec.tool == tool)
            #expect(spec.command == entry.command)
            #expect(spec.mutability == Mutability.`mutating`)
            #expect(spec.confirmation == .none)
            #expect(spec.target == .none)
            #expect(spec.verification == entry.verification)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == .short)
            #expect(spec.availability == entry.availability)
            #expect(spec.capability.rawValue == entry.id)
        }
    }

    @Test("derived edit mutations and deadlines match server decisions")
    func editLegacyParity() throws {
        let tool = try #require(ToolID(rawValue: "logic_edit"))
        let commands = Set(Self.editCommands.map(\.command))
        #expect(OperationRegistry.mutatingCommands(tool: tool) == commands)
        for command in commands {
            #expect(OperationRegistry.deadlineSeconds(tool: tool.rawValue, command: command) == 25)
            #expect(LogicProServer.isMutatingCommand(tool: tool.rawValue, command: command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: tool.rawValue, command: command) == 25)
        }
    }

    @Test("edit decisions are registry-backed and cross-tool isolated")
    func editFlagGateAndFallbacks() {
        for entry in Self.editCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_edit", command: entry.command))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_edit", command: entry.command) == 25)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_edit", command: "play"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_edit", command: "play") == 25)
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
    }

    private static let projectCommands: [(
        id: String,
        command: String,
        mutability: Mutability,
        deadline: DeadlineClass,
        verification: VerificationPolicy
    )] = [
        ("project.new", "new", .mutating, .medium, .readbackRequired),
        ("project.open", "open", .mutating, .long, .readbackRequired),
        ("project.save", "save", .mutating, .medium, .readbackRequired),
        ("project.save_as", "save_as", .mutating, .long, .readbackRequired),
        ("project.close", "close", .mutating, .medium, .none),
        ("project.bounce", "bounce", .mutating, .long, .readbackRequired),
        ("project.is_running", "is_running", .readOnly, .short, .none),
        ("project.launch", "launch", .mutating, .short, .readbackRequired),
        ("project.quit", "quit", .mutating, .medium, .readbackRequired),
        ("project.get_regions", "get_regions", .readOnly, .short, .none),
        ("project.export_plan", "export_plan", .readOnly, .short, .none),
        ("project.export_run", "export_run", .mutating, .long, .readbackRequired),
        ("project.export_resume", "export_resume", .mutating, .long, .readbackRequired),
        ("project.audit", "audit", .readOnly, .short, .none),
        ("project.cleanup_plan", "cleanup_plan", .readOnly, .short, .none),
        ("project.cleanup_apply", "cleanup_apply", .mutating, .medium, .readbackRequired),
    ]

    /// ADR-003: every operation that declares a confirmation policy, and its
    /// level — the exhaustive enforcement census. A new spec declaring l1+
    /// without being added here (and wired to an enforcement surface) fails.
    private static let confirmationCensus: [(tool: String, command: String, confirmation: ConfirmationPolicy)] = [
        ("logic_project", "new", .l1),
        ("logic_project", "save", .l1),
        ("logic_project", "launch", .l1),
        ("logic_project", "cleanup_apply", .l1),
        ("logic_project", "open", .l2),
        ("logic_project", "save_as", .l2),
        ("logic_project", "bounce", .l2),
        ("logic_project", "export_run", .l2),
        ("logic_project", "export_resume", .l2),
        ("logic_mixer", "insert_plugin", .l2),
        ("logic_system", "clear_traces", .l2),
        ("logic_project", "close", .l3),
        ("logic_project", "quit", .l3),
    ]

    @Test("project registry is exact and globally unique")
    func projectCompletenessAndUniqueness() throws {
        let tool = try #require(ToolID(rawValue: "logic_project"))
        let projectSpecs = OperationRegistry.specs.filter { $0.tool == tool }
        #expect(projectSpecs.count == Self.projectCommands.count)
        #expect(Set(projectSpecs.map(\.command)) == Set(Self.projectCommands.map(\.command)))
        #expect(Set(projectSpecs.map(\.id.rawValue)) == Set(Self.projectCommands.map(\.id)))
        #expect(OperationRegistry.specs.count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map { "\($0.tool.rawValue):\($0.command)" }).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(OperationRegistry.validationErrors().isEmpty)
    }

    @Test("all project metadata matches dispatcher and manifest truth")
    func projectMetadata() throws {
        let tool = try #require(ToolID(rawValue: "logic_project"))

        for entry in Self.projectCommands {
            let id = try #require(OperationID(rawValue: entry.id))
            let spec = try #require(OperationRegistry.spec(tool: tool.rawValue, command: entry.command))
            #expect(spec.id == id)
            #expect(spec.tool == tool)
            #expect(spec.command == entry.command)
            #expect(spec.mutability == entry.mutability)
            #expect(spec.target == .none)
            #expect(spec.verification == entry.verification)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == entry.deadline)
            // PRD-014: trace-op availability is generated from the feature
            // policy (defaultInstall only when tracing was enabled when the
            // registry was built); everything else stays defaultInstall.
            #expect(spec.availability == (
                OperationRegistry.traceOperationIDs.contains(id)
                    ? OperationRegistry.traceAvailability(
                        traceEnabled: OperationRegistry.traceEnabledAtRegistryBuild
                    )
                    : .defaultInstall
            ))
            #expect(spec.capability.rawValue == entry.id)
        }
    }

    @Test("project mutations exactly match registry behavior")
    func projectLegacyMutationParity() throws {
        let tool = try #require(ToolID(rawValue: "logic_project"))
        let expected = Set(Self.projectCommands
            .filter { $0.mutability == Mutability.`mutating` }
            .map(\.command))
        #expect(expected == Set([
            "new", "open", "save", "save_as", "close", "bounce", "launch", "quit",
            "export_run", "export_resume", "cleanup_apply",
        ]))
        #expect(OperationRegistry.mutatingCommands(tool: tool) == expected)
        for entry in Self.projectCommands {
            #expect(LogicProServer.isMutatingCommand(tool: tool.rawValue, command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
        }
    }

    @Test("project deadlines exactly match registry short medium and long tiers")
    func projectDeadlineParity() {
        #expect(Self.projectCommands.filter { $0.deadline == .short }.count == 6)
        #expect(Self.projectCommands.filter { $0.deadline == .medium }.count == 5)
        #expect(Self.projectCommands.filter { $0.deadline == .long }.count == 5)

        for entry in Self.projectCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: "logic_project", command: entry.command)
                == entry.deadline.seconds)
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: entry.command)
                == entry.deadline.seconds)
        }
    }

    @Test("registry is the single confirmation authority across the full surface")
    func confirmationAuthorityCensus() throws {
        // Exact-set equality: every spec declaring a confirmation policy is in
        // the census with the declared level, and nothing else declares one.
        var declared: [String: ConfirmationPolicy] = [:]
        for spec in OperationRegistry.specs where spec.confirmation != .none {
            declared["\(spec.tool.rawValue)/\(spec.command)"] = spec.confirmation
        }
        var expected: [String: ConfirmationPolicy] = [:]
        for entry in Self.confirmationCensus {
            expected["\(entry.tool)/\(entry.command)"] = entry.confirmation
        }
        #expect(declared == expected)

        // The DestructivePolicy adapter (project-scoped bare-command lookup)
        // resolves through the registry: parity for every project command,
        // and .l0 for commands with no project spec.
        for entry in Self.projectCommands {
            let spec = try #require(OperationRegistry.spec(
                tool: "logic_project",
                command: entry.command
            ))
            #expect(DestructivePolicy.level(for: entry.command)
                == DestructivePolicy.level(of: spec.confirmation))
        }
        #expect(DestructivePolicy.level(for: "no_such_command") == .l0)
        // insert_plugin is a mixer command — the project-scoped adapter must
        // NOT pick it up (its gate lives in MixerDispatcher via the registry).
        #expect(DestructivePolicy.level(for: "insert_plugin") == .l0)

        // Prompt labels project from ConfirmationPolicy, never a literal.
        #expect(DestructivePolicy.promptLabel(of: .none) == nil)
        #expect(DestructivePolicy.promptLabel(of: .l1) == nil)
        #expect(DestructivePolicy.promptLabel(of: .l2) == "L2")
        #expect(DestructivePolicy.promptLabel(of: .l3) == "L3")
    }

    @Test("registry is the single dirty-cache authority")
    func dirtyCacheSectionCensus() throws {
        var declared: [String: Set<CacheSectionID>] = [:]
        for spec in OperationRegistry.specs where !spec.dirtySections.isEmpty {
            declared["\(spec.tool.rawValue)/\(spec.command)"] = spec.dirtySections
        }
        // Exactly the project lifecycle transitions dirty the whole world;
        // the dispatcher's invalidate-on-success derives from these entries,
        // so adding a lifecycle op without declaring impact here fails.
        let all = Set(CacheSectionID.allCases)
        #expect(declared == [
            "logic_project/new": all,
            "logic_project/open": all,
            "logic_project/save_as": all,
            "logic_project/close": all,
        ])
    }

    @Test("catalog rows expose capability and dirty sections from the registry")
    func catalogCarriesCapabilityAndDirtySections() throws {
        let byID = Dictionary(
            uniqueKeysWithValues: OperationCatalog.snapshot().operations.map { ($0.id, $0) }
        )
        #expect(byID.count == OperationRegistry.specs.count)
        for spec in OperationRegistry.specs {
            let row = try #require(byID[spec.id.rawValue])
            #expect(row.capability == spec.capability.rawValue)
            #expect(row.dirtySections == spec.dirtySections.map(\.rawValue).sorted())
        }
    }

    @Test("tool description command lists match the registry exactly")
    func toolDescriptionCommandListsMatchRegistry() throws {
        let tools: [(ToolID, String?)] = [
            (.logicTransport, TransportDispatcher.tool.description),
            (.logicMixer, MixerDispatcher.tool.description),
            (.logicNavigate, NavigateDispatcher.tool.description),
            (.logicAudio, AudioDispatcher.tool.description),
            (.logicSystem, SystemDispatcher.tool.description),
            (.logicPlugins, PluginsDispatcher.tool.description),
            (.logicEdit, EditDispatcher.tool.description),
            (.logicProject, ProjectDispatcher.tool.description),
            (.logicMidi, MIDIDispatcher.tool.description),
            (.logicTracks, TrackDispatcher.tool.description),
        ]
        for (toolID, description) in tools {
            let text = try #require(description, Comment(rawValue: toolID.rawValue))
            let marker = try #require(
                text.range(of: "Commands: "),
                "\(toolID.rawValue) tool description lacks a 'Commands: ' segment"
            )
            let segment = text[marker.upperBound...].prefix { $0 != "." }
            let listed = Set(
                segment.split(separator: ",").map {
                    String($0.drop(while: { $0 == " " }))
                }
            )
            let registered = Set(
                OperationRegistry.specs.filter { $0.tool == toolID }.map(\.command)
            )
            #expect(
                listed == registered,
                "\(toolID.rawValue) description drift — described-only: \(listed.subtracting(registered).sorted()); registry-only: \(registered.subtracting(listed).sorted())"
            )
        }
    }

    @Test("project decisions are registry-backed")
    func projectFlagOff() {
        for entry in Self.projectCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_project", command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: entry.command)
                == entry.deadline.seconds)
        }
    }

    @Test("project decisions stay cross-tool isolated with safe fallthroughs")
    func projectFlagGateAndCrossToolIsolation() {
        #expect(OperationRegistry.spec(tool: "logic_project", command: "play") == nil)
        #expect(OperationRegistry.spec(tool: "logic_transport", command: "new") == nil)
        #expect(OperationRegistry.spec(tool: "logic_audio", command: "open") == nil)

        for entry in Self.projectCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_project", command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: entry.command)
                == entry.deadline.seconds)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_project", command: "import_file"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: "import_file") == 25)
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
    }

    private static let midiCommands: [(
        id: String,
        command: String,
        mutability: Mutability,
        deadline: DeadlineClass,
        verification: VerificationPolicy
    )] = [
        ("midi.send_note", "send_note", .mutating, .short, .none),
        ("midi.send_chord", "send_chord", .mutating, .short, .none),
        ("midi.send_cc", "send_cc", .mutating, .short, .none),
        ("midi.send_program_change", "send_program_change", .mutating, .short, .none),
        ("midi.send_pitch_bend", "send_pitch_bend", .mutating, .short, .none),
        ("midi.send_aftertouch", "send_aftertouch", .mutating, .short, .none),
        ("midi.send_sysex", "send_sysex", .mutating, .short, .none),
        ("midi.play_sequence", "play_sequence", .mutating, .medium, .none),
        ("midi.import_file", "import_file", .mutating, .long, .readbackRequired),
        ("midi.list_ports", "list_ports", .readOnly, .short, .none),
        ("midi.create_virtual_port", "create_virtual_port", .mutating, .short, .none),
        ("midi.step_input", "step_input", .mutating, .short, .none),
        ("midi.mmc_play", "mmc_play", .mutating, .short, .none),
        ("midi.mmc_stop", "mmc_stop", .mutating, .short, .none),
        ("midi.mmc_record", "mmc_record", .mutating, .short, .none),
        ("midi.mmc_locate", "mmc_locate", .mutating, .short, .bestEffort),
    ]

    @Test("MIDI registry is exact, globally unique, and cross-tool isolated")
    func midiCompletenessAndIsolation() throws {
        let tool = try #require(ToolID(rawValue: "logic_midi"))
        let midiSpecs = OperationRegistry.specs.filter { $0.tool == tool }
        #expect(midiSpecs.count == Self.midiCommands.count)
        #expect(Set(midiSpecs.map(\.command)) == Set(Self.midiCommands.map(\.command)))
        #expect(Set(midiSpecs.map(\.id.rawValue)) == Set(Self.midiCommands.map(\.id)))
        #expect(OperationRegistry.specs.count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map { "\($0.tool.rawValue):\($0.command)" }).count
            == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(OperationRegistry.validationErrors().isEmpty)

        #expect(OperationRegistry.spec(tool: "logic_midi", command: "play") == nil)
        #expect(OperationRegistry.spec(tool: "logic_transport", command: "send_note") == nil)
        #expect(OperationRegistry.spec(tool: "logic_project", command: "import_file") == nil)
        #expect(OperationRegistry.spec(tool: "logic_midi", command: "send_note.keycmd") == nil)
    }

    @Test("all MIDI metadata matches dispatcher and routing truth")
    func midiMetadata() throws {
        let tool = try #require(ToolID(rawValue: "logic_midi"))

        for entry in Self.midiCommands {
            let id = try #require(OperationID(rawValue: entry.id))
            let spec = try #require(OperationRegistry.spec(tool: tool.rawValue, command: entry.command))
            #expect(spec.id == id)
            #expect(spec.tool == tool)
            #expect(spec.command == entry.command)
            #expect(spec.mutability == entry.mutability)
            #expect(spec.confirmation == .none)
            #expect(spec.target == .none)
            #expect(spec.verification == entry.verification)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == entry.deadline)
            // PRD-014: trace-op availability is generated from the feature
            // policy (defaultInstall only when tracing was enabled when the
            // registry was built); everything else stays defaultInstall.
            #expect(spec.availability == (
                OperationRegistry.traceOperationIDs.contains(id)
                    ? OperationRegistry.traceAvailability(
                        traceEnabled: OperationRegistry.traceEnabledAtRegistryBuild
                    )
                    : .defaultInstall
            ))
            #expect(spec.capability.rawValue == entry.id)
        }
    }

    @Test("MIDI mutations exactly match registry behavior")
    func midiLegacyMutationParity() throws {
        let tool = try #require(ToolID(rawValue: "logic_midi"))
        let expected = Set(Self.midiCommands
            .filter { $0.mutability == Mutability.`mutating` }
            .map(\.command))
        #expect(expected == Set([
            "send_note", "send_chord", "send_cc", "send_program_change", "send_pitch_bend",
            "send_aftertouch", "send_sysex", "play_sequence", "import_file", "create_virtual_port",
            "step_input", "mmc_play", "mmc_stop", "mmc_record", "mmc_locate",
        ]))
        #expect(OperationRegistry.mutatingCommands(tool: tool) == expected)
        #expect(!expected.contains("list_ports"))
        for entry in Self.midiCommands {
            #expect(LogicProServer.isMutatingCommand(tool: tool.rawValue, command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
        }
    }

    @Test("MIDI deadlines preserve registry short medium and long tiers")
    func midiDeadlineParity() {
        #expect(Self.midiCommands.filter { $0.deadline == .short }.count == 14)
        #expect(Self.midiCommands.filter { $0.deadline == .medium }.map(\.command) == ["play_sequence"])
        #expect(Self.midiCommands.filter { $0.deadline == .long }.map(\.command) == ["import_file"])

        for entry in Self.midiCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: "logic_midi", command: entry.command)
                == entry.deadline.seconds)
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: entry.command)
                == entry.deadline.seconds)
        }
    }

    @Test("MIDI decisions are registry-backed")
    func midiFlagOff() {
        for entry in Self.midiCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: entry.command)
                == entry.deadline.seconds)
        }
    }

    @Test("MIDI decisions stay cross-tool isolated")
    func midiFlagGateAndCrossToolIsolation() {
        for entry in Self.midiCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: entry.command)
                == entry.deadline.seconds)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_midi", command: "list_ports"))
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_midi", command: "is_running"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: "open") == 25)
    }

    private static let trackCommands: [(
        id: String,
        command: String,
        mutability: Mutability,
        deadline: DeadlineClass,
        verification: VerificationPolicy
    )] = [
        ("tracks.select", "select", .mutating, .short, .readbackRequired),
        ("tracks.create_audio", "create_audio", .mutating, .short, .readbackRequired),
        ("tracks.create_instrument", "create_instrument", .mutating, .short, .readbackRequired),
        ("tracks.create_drummer", "create_drummer", .mutating, .short, .readbackRequired),
        ("tracks.create_external_midi", "create_external_midi", .mutating, .short, .readbackRequired),
        ("tracks.delete", "delete", .mutating, .short, .readbackRequired),
        ("tracks.duplicate", "duplicate", .mutating, .short, .none),
        ("tracks.rename", "rename", .mutating, .short, .readbackRequired),
        ("tracks.mute", "mute", .mutating, .short, .readbackRequired),
        ("tracks.solo", "solo", .mutating, .short, .readbackRequired),
        ("tracks.arm", "arm", .mutating, .short, .readbackRequired),
        ("tracks.arm_only", "arm_only", .mutating, .short, .readbackRequired),
        ("tracks.record_sequence", "record_sequence", .mutating, .long, .readbackRequired),
        ("tracks.set_automation", "set_automation", .mutating, .short, .readbackRequired),
        ("tracks.set_instrument", "set_instrument", .mutating, .medium, .readbackRequired),
        ("tracks.list_library", "list_library", .readOnly, .long, .none),
        ("tracks.scan_library", "scan_library", .readOnly, .long, .none),
        ("tracks.resolve_path", "resolve_path", .readOnly, .short, .none),
        ("tracks.scan_plugin_presets", "scan_plugin_presets", .readOnly, .long, .none),
    ]

    @Test("tracks registry is exact, globally unique, and cross-tool isolated")
    func tracksCompletenessAndIsolation() throws {
        let tool = try #require(ToolID(rawValue: "logic_tracks"))
        let trackSpecs = OperationRegistry.specs.filter { $0.tool == tool }
        #expect(trackSpecs.count == Self.trackCommands.count)
        #expect(Set(trackSpecs.map(\.command)) == Set(Self.trackCommands.map(\.command)))
        #expect(Set(trackSpecs.map(\.id.rawValue)) == Set(Self.trackCommands.map(\.id)))
        #expect(OperationRegistry.specs.count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)).count == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map { "\($0.tool.rawValue):\($0.command)" }).count
            == Self.expectedRegistryCount)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))
        #expect(OperationRegistry.validationErrors().isEmpty)

        #expect(OperationRegistry.spec(tool: "logic_tracks", command: "library") == nil)
        #expect(OperationRegistry.spec(tool: "logic_tracks", command: "set_color") == nil)
        #expect(OperationRegistry.spec(tool: "logic_tracks", command: "unknown") == nil)
        #expect(OperationRegistry.spec(tool: "logic_transport", command: "rename") == nil)
        #expect(OperationRegistry.spec(tool: "logic_midi", command: "record_sequence") == nil)
    }

    @Test("all tracks metadata matches dispatcher and channel truth")
    func tracksMetadata() throws {
        let tool = try #require(ToolID(rawValue: "logic_tracks"))
        let targetBearingCommands: Set<String> = [
            "select", "delete", "duplicate", "rename", "mute", "solo", "arm", "arm_only",
            "set_automation", "set_instrument",
        ]

        for entry in Self.trackCommands {
            let id = try #require(OperationID(rawValue: entry.id))
            let spec = try #require(OperationRegistry.spec(tool: tool.rawValue, command: entry.command))
            #expect(spec.id == id)
            #expect(spec.tool == tool)
            #expect(spec.command == entry.command)
            #expect(spec.mutability == entry.mutability)
            #expect(spec.confirmation == .none)
            #expect(spec.target == (targetBearingCommands.contains(entry.command) ? .acceptsStableTarget : .none))
            #expect(spec.verification == entry.verification)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == entry.deadline)
            // PRD-014: trace-op availability is generated from the feature
            // policy (defaultInstall only when tracing was enabled when the
            // registry was built); everything else stays defaultInstall.
            #expect(spec.availability == (
                OperationRegistry.traceOperationIDs.contains(id)
                    ? OperationRegistry.traceAvailability(
                        traceEnabled: OperationRegistry.traceEnabledAtRegistryBuild
                    )
                    : .defaultInstall
            ))
            #expect(spec.capability.rawValue == entry.id)
        }
    }

    @Test("tracks mutations exactly match registry behavior")
    func tracksLegacyMutationParity() throws {
        let tool = try #require(ToolID(rawValue: "logic_tracks"))
        let expected = Set(Self.trackCommands
            .filter { $0.mutability == Mutability.`mutating` }
            .map(\.command))
        #expect(expected == Set([
            "select", "create_audio", "create_instrument", "create_drummer", "create_external_midi",
            "delete", "duplicate", "rename", "mute", "solo", "arm", "arm_only", "record_sequence",
            "set_automation", "set_instrument",
        ]))
        #expect(OperationRegistry.mutatingCommands(tool: tool) == expected)
        for command in ["list_library", "scan_library", "resolve_path", "scan_plugin_presets"] {
            #expect(!expected.contains(command))
        }
        for entry in Self.trackCommands {
            #expect(LogicProServer.isMutatingCommand(tool: tool.rawValue, command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
        }
    }

    @Test("tracks deadlines preserve short medium long and read-only long tiers")
    func tracksDeadlineParity() {
        #expect(Self.trackCommands.filter { $0.deadline == .short }.count == 14)
        #expect(Self.trackCommands.filter { $0.deadline == .medium }.map(\.command) == ["set_instrument"])
        #expect(Set(Self.trackCommands.filter { $0.deadline == .long }.map(\.command)) == Set([
            "record_sequence", "list_library", "scan_library", "scan_plugin_presets",
        ]))
        #expect(Set(Self.trackCommands
            .filter { $0.mutability == .readOnly && $0.deadline == .long }
            .map(\.command)) == Set(["list_library", "scan_library", "scan_plugin_presets"]))

        for entry in Self.trackCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: "logic_tracks", command: entry.command)
                == entry.deadline.seconds)
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_tracks", command: entry.command)
                == entry.deadline.seconds)
        }
    }

    @Test("tracks decisions are registry-backed")
    func tracksFlagOff() {
        for entry in Self.trackCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_tracks", command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_tracks", command: entry.command)
                == entry.deadline.seconds)
        }
    }

    @Test("tracks decisions stay cross-tool isolated")
    func tracksFlagGateAndCrossToolIsolation() {
        for entry in Self.trackCommands {
            #expect(LogicProServer.isMutatingCommand(tool: "logic_tracks", command: entry.command)
                == (entry.mutability == Mutability.`mutating`))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_tracks", command: entry.command)
                == entry.deadline.seconds)
        }
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_tracks", command: "library"))
        #expect(OperationRegistry.spec(tool: "logic_tracks", command: "library") == nil)
        #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: "import_file") == 300)
    }

    @Test("registry covers the exact server catalog and server decisions")
    func registryCoversExactServerCatalogAndLegacyMutations() {
        let expectedTools: Set<String> = [
            "logic_transport", "logic_tracks", "logic_mixer", "logic_midi", "logic_edit",
            "logic_navigate", "logic_project", "logic_audio", "logic_system", "logic_plugins",
        ]
        #expect(ServerCatalog.toolNames == expectedTools)
        #expect(OperationRegistry.registeredToolRawValues == expectedTools)
        #expect(OperationRegistry.registeredToolRawValues.count == 10)

        for tool in expectedTools {
            let toolID = ToolID(rawValue: tool)
            #expect(toolID != nil)
            if let toolID {
                for spec in OperationRegistry.specs where spec.tool == toolID {
                    #expect(LogicProServer.isMutatingCommand(tool: tool, command: spec.command)
                        == (spec.mutability == Mutability.`mutating`))
                }
            }
        }
    }
}
