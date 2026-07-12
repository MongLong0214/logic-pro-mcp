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

        #expect(OperationRegistry.registeredToolRawValues == Set(WorkflowSkillCatalog.publicCommands.keys))
        #expect(Self.registeredOperations.count == OperationRegistry.specs.count)
        #expect(missing.isEmpty, "missing specs: \(missing)")
        #expect(orphans.isEmpty, "orphan specs: \(orphans)")
        #expect(OperationRegistry.validationErrors().isEmpty)
    }

    @Test("registry mutability and deadlines equal flag-off legacy values for every public command")
    func registryValuesEqualFlagOffLegacyValues() throws {
        let registryMutations = Set(OperationRegistry.specs
            .filter { $0.mutability == Mutability.`mutating` }
            .map { Self.operationKey(tool: $0.tool.rawValue, command: $0.command) })
        let legacyMutations = Set(LogicProServer.mutatingCommandsByTool.flatMap { tool, commands in
            commands.map { Self.operationKey(tool: tool, command: $0) }
        })
        #expect(registryMutations == legacyMutations)

        #expect(!FeatureFlags.adr003OperationRegistry)
        for tool in WorkflowSkillCatalog.publicCommands.keys.sorted() {
            #expect(!LogicProServer.usesOperationRegistry(tool: tool))
            for command in WorkflowSkillCatalog.publicCommands[tool, default: []].sorted() {
                let spec = try #require(OperationRegistry.spec(tool: tool, command: command))
                let legacyMutating = LogicProServer.mutatingCommandsByTool[tool, default: []]
                    .contains(command)
                let registryDeadline = try #require(
                    OperationRegistry.deadlineSeconds(tool: tool, command: command)
                )

                #expect((spec.mutability == Mutability.`mutating`) == legacyMutating)
                #expect(registryDeadline == LogicProServer.commandDeadlineSeconds(
                    tool: tool,
                    command: command
                ))
            }
        }
    }
}
