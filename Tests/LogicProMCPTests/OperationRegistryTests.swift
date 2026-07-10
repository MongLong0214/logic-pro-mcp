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
        #expect(OperationRegistry.specs.count == 13)
        #expect(Set(OperationRegistry.specs.map(\.command)).count == 13)
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
        #expect(Set(Self.commands.map(\.1)) == Set(OperationRegistry.specs.map(\.command)))

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
        #expect(OperationRegistry.mutatingCommands == LogicProServer.mutatingCommandsByTool["logic_transport"])
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
}
