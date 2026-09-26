import Testing
@testable import LogicProMCP

@Suite("OperationRegistry coverage")
struct OperationRegistryCoverageTests {
    private static func operationKey(tool: String, command: String) -> String {
        "\(tool).\(command)"
    }

    private static var publicOperations: Set<String> {
        Set(WorkflowSkillCatalog.publicCommands.flatMap { tool, commands in
            commands.map { operationKey(tool: tool, command: $0) }
        })
    }

    private static var registeredOperations: Set<String> {
        Set(OperationRegistry.specs.map {
            operationKey(tool: $0.tool.rawValue, command: $0.command)
        })
    }

    @Test("registry exactly covers every public command")
    func registryExactlyCoversEveryPublicCommand() {
        let missing = Self.publicOperations.subtracting(Self.registeredOperations).sorted()
        let orphans = Self.registeredOperations.subtracting(Self.publicOperations).sorted()

        #expect(OperationRegistry.specs.count == 115)   // #884 system.setup_control_surface, #862 mixer.bank
        #expect(OperationRegistry.registeredToolRawValues == Set(WorkflowSkillCatalog.publicCommands.keys))
        #expect(Self.registeredOperations.count == OperationRegistry.specs.count)
        #expect(missing.isEmpty, "missing specs: \(missing)")
        #expect(orphans.isEmpty, "orphan specs: \(orphans)")
        #expect(OperationRegistry.validationErrors().isEmpty)
    }

    @Test("registry drives server mutability and deadlines for every public command")
    func registryDrivesServerDecisionsForEveryPublicCommand() throws {
        for tool in WorkflowSkillCatalog.publicCommands.keys.sorted() {
            for command in WorkflowSkillCatalog.publicCommands[tool, default: []].sorted() {
                let spec = try #require(OperationRegistry.spec(tool: tool, command: command))
                let registryDeadline = try #require(
                    OperationRegistry.deadlineSeconds(tool: tool, command: command)
                )

                let isMutating = LogicProServer.isMutatingCommand(tool: tool, command: command)
                #expect(spec.mutability == Mutability.`mutating` ? isMutating : !isMutating)
                #expect(registryDeadline == LogicProServer.commandDeadlineSeconds(
                    tool: tool,
                    command: command
                ))
            }
        }
    }

    @Test("unregistered commands use the safe deadline and mutation fallthrough")
    func unregisteredCommandsUseSafeFallthrough() {
        #expect(OperationRegistry.spec(tool: "logic_audio", command: "import_file") == nil)
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_audio", command: "import_file") == 25)
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_audio", command: "import_file"))
        #expect(LogicProServer.commandDeadlineSeconds(tool: "logic_unknown", command: "bounce") == 25)
        #expect(!LogicProServer.isMutatingCommand(tool: "logic_unknown", command: "play"))
    }

    @Test("unclassified mutation targets = 0")
    func everyMutationHasAnExplicitTargetPolicy() {
        let mutating = OperationRegistry.specs.filter { $0.mutability == Mutability.`mutating` }
        let readOnly = OperationRegistry.specs.filter { $0.mutability == .readOnly }
        let targetBearingIDs = Set(mutating
            .filter { $0.target == .acceptsStableTarget }
            .map(\.id))
        let targetless = mutating.filter { $0.target == .none }
        let expectedTargetBearingIDs: Set<OperationID> = [
            .mixerSetVolume,
            .mixerSetPan,
            .pluginsSetParamVerified,
            .pluginsSetEQBandVerified,
            .pluginsInsertVerified,
            .tracksSelect,
            .tracksDelete,
            .tracksDuplicate,
            .tracksRename,
            .tracksMute,
            .tracksSolo,
            .tracksArm,
            .tracksArmOnly,
            .tracksSetAutomation,
            .tracksSetInstrument,
        ]

        #expect(mutating.count == 92)   // #448: sort_verified is a mutating structural verb;
                                        // #301 added plugins.set_eq_band_verified, which is
                                        // target-bearing, so `targetless` is unchanged;
                                        // #884 added system.setup_control_surface, which bears no
                                        // target — it configures the application, not a track;
                                        // #862 added mixer.bank, which moves the MCU strip
                                        // window and so bears no track target either
        #expect(readOnly.count == 23)
        #expect(targetBearingIDs == expectedTargetBearingIDs)
        #expect(targetless.count == 77)   // #448 sort_verified, #884 setup_control_surface and #862 bank bear no target
        #expect(targetBearingIDs.count + targetless.count == mutating.count)
        #expect(readOnly.allSatisfy { $0.target == .none })
    }
}
