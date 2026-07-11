import Foundation
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
        "delete_marker", "rename_marker", "toggle_view",
    ]

    private static let navigateAvailabilityOverrides: [String: AvailabilityPolicy] = [
        "delete_marker": .requiresKeyBinding,
        "rename_marker": .unsupported,
    ]

    private static let expectedRegistryCount = commands.count + mixerCommands.count + navigateCommands.count

    private func withRegistryFlag(_ value: String?, body: () -> Void) {
        let key = "LOGIC_MCP_ADR003_OPERATION_REGISTRY"
        let previous = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        body()
    }

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

    @Test("derived mutating commands equal the unchanged legacy transport set")
    func mutatingParity() {
        #expect(OperationRegistry.mutatingCommands(tool: .logicTransport) == LogicProServer.mutatingCommandsByTool["logic_transport"])
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
        #expect(Set(Self.mixerCommands.map(\.1)) == Set(mixerSpecs.map(\.command)))

        for (id, command) in Self.mixerCommands {
            let spec = try #require(OperationRegistry.spec(tool: ToolID.logicMixer.rawValue, command: command))
            #expect(spec.id == id)
            #expect(spec.tool == .logicMixer)
            #expect(spec.command == command)
            #expect(spec.mutability == Mutability.`mutating`)
            #expect(spec.confirmation == (command == "insert_plugin" ? .l2 : .none))
            #expect(spec.target == .none)
            #expect(spec.verification == .readbackRequired)
            #expect(spec.retry == .neverAutomatic)
            #expect(spec.deadline == .short)
            #expect(spec.availability == .defaultInstall)
            #expect(spec.capability.rawValue == id.rawValue)
        }
    }

    @Test("derived mixer mutations and deadlines equal unchanged legacy behavior")
    func mixerLegacyParity() {
        #expect(OperationRegistry.mutatingCommands(tool: .logicMixer) == LogicProServer.mutatingCommandsByTool["logic_mixer"])
        for (_, command) in Self.mixerCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: ToolID.logicMixer.rawValue, command: command) == 25)
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

    @Test("flag off uses unchanged legacy mixer decisions")
    func mixerFlagOff() {
        withRegistryFlag(nil) {
            #expect(FeatureFlags.adr003OperationRegistry == false)
            for (_, command) in Self.mixerCommands {
                #expect(LogicProServer.mutatingCommandsByTool["logic_mixer"]?.contains(command) == true)
                #expect(LogicProServer.isMutatingCommand(tool: "logic_mixer", command: command))
                #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: command) == 25)
            }
            #expect(!LogicProServer.isMutatingCommand(tool: "logic_mixer", command: "play"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: "play") == 25)
        }
    }

    @Test("flag on derives mixer decisions and preserves legacy fallbacks")
    func mixerFlagOn() {
        withRegistryFlag("1") {
            #expect(FeatureFlags.adr003OperationRegistry)
            for (_, command) in Self.mixerCommands {
                #expect(LogicProServer.isMutatingCommand(tool: "logic_mixer", command: command))
                #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: command) == 25)
            }
            #expect(!LogicProServer.isMutatingCommand(tool: "logic_mixer", command: "play"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_mixer", command: "import_file") == 300)
            #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
        }
    }

    @Test("registry deadlines are short and match legacy with the flag unset")
    func deadlineParity() {
        withRegistryFlag(nil) {
            #expect(FeatureFlags.adr003OperationRegistry == false)
            for spec in OperationRegistry.specs {
                #expect(spec.deadline.seconds == 25)
                #expect(OperationRegistry.deadlineSeconds(tool: spec.tool.rawValue, command: spec.command) == 25)
                #expect(LogicProServer.commandDeadlineSeconds(tool: spec.tool.rawValue, command: spec.command) == 25)
            }
        }
    }

    @Test("flag off uses legacy mutability and deadlines")
    func flagOff() {
        withRegistryFlag(nil) {
            #expect(FeatureFlags.adr003OperationRegistry == false)
            for (_, command) in Self.commands {
                #expect(LogicProServer.mutatingCommandsByTool["logic_transport"]?.contains(command) == true)
                #expect(LogicProServer.isMutatingCommand(tool: "logic_transport", command: command))
                #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: command) == 25)
            }
            #expect(!LogicProServer.isMutatingCommand(tool: "logic_transport", command: "unknown"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: "unknown") == 25)
        }
    }

    @Test("flag on derives known transport decisions and preserves legacy fallbacks")
    func flagOn() {
        withRegistryFlag("1") {
            #expect(FeatureFlags.adr003OperationRegistry)
            for spec in OperationRegistry.specs {
                #expect(LogicProServer.isMutatingCommand(tool: spec.tool.rawValue, command: spec.command))
                #expect(LogicProServer.commandDeadlineSeconds(tool: spec.tool.rawValue, command: spec.command) == 25)
            }
            #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_midi", command: "import_file") == 300)
            #expect(!LogicProServer.isMutatingCommand(tool: "logic_transport", command: "bounce"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_transport", command: "bounce") == 300)
        }
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

    @Test("derived navigate mutations and deadlines equal unchanged legacy behavior")
    func navigateLegacyParity() throws {
        let tool = try #require(ToolID(rawValue: "logic_navigate"))
        #expect(OperationRegistry.mutatingCommands(tool: tool) == LogicProServer.mutatingCommandsByTool["logic_navigate"])
        for (_, command) in Self.navigateCommands {
            #expect(OperationRegistry.deadlineSeconds(tool: tool.rawValue, command: command) == 25)
        }
    }

    @Test("navigate rename marker is honestly marked unsupported")
    func navigateRenameMarkerUnsupported() throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_navigate", command: "rename_marker"))
        #expect(spec.availability == .unsupported)
        #expect(spec.verification == .none)
        #expect(spec.confirmation == .none)
        #expect(HonestContract.terminalErrorCodes.contains("not_implemented"))
    }

    @Test("flag off uses unchanged legacy navigate decisions")
    func navigateFlagOff() {
        withRegistryFlag(nil) {
            #expect(FeatureFlags.adr003OperationRegistry == false)
            #expect(!LogicProServer.usesOperationRegistry(tool: "logic_navigate"))
            for (_, command) in Self.navigateCommands {
                #expect(LogicProServer.mutatingCommandsByTool["logic_navigate"]?.contains(command) == true)
                #expect(LogicProServer.isMutatingCommand(tool: "logic_navigate", command: command))
                #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: command) == 25)
            }
            #expect(!LogicProServer.isMutatingCommand(tool: "logic_navigate", command: "play"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: "play") == 25)
        }
    }

    @Test("flag on derives navigate decisions and preserves legacy fallbacks")
    func navigateFlagOn() {
        withRegistryFlag("1") {
            #expect(FeatureFlags.adr003OperationRegistry)
            #expect(LogicProServer.usesOperationRegistry(tool: "logic_transport"))
            #expect(LogicProServer.usesOperationRegistry(tool: "logic_mixer"))
            #expect(LogicProServer.usesOperationRegistry(tool: "logic_navigate"))
            #expect(!LogicProServer.usesOperationRegistry(tool: "logic_midi"))
            for (_, command) in Self.navigateCommands {
                #expect(LogicProServer.isMutatingCommand(tool: "logic_navigate", command: command))
                #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: command) == 25)
            }
            #expect(!LogicProServer.isMutatingCommand(tool: "logic_navigate", command: "play"))
            #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_navigate", command: "import_file") == 300)
            #expect(LogicProServer.isMutatingCommand(tool: "logic_midi", command: "import_file"))
        }
    }
}
