import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #957: the rich tool schema is derived from the operation registry, and every branch says what the
/// runtime's strict-parameter gate does with the same request. The schema checks here read the
/// projected JSON, not the projection's own helpers, so a helper that lies is caught by the gate.
@Suite struct Issue957CommandSchemaProjectionTests {
    typealias Projection = CommandSchemaProjection

    /// Mutation this kills: any set value read as rich, which would switch a client onto a schema it
    /// was not tested with.
    @Test func onlyTheExactWordRichSelectsTheRichSchema() {
        #expect(Projection.mode(from: [:]) == .legacy)
        #expect(Projection.mode(from: [Projection.environmentKey: "rich"]) == .rich)
        for other in ["", "RICH", "1", "legacy", "rich "] {
            #expect(Projection.mode(from: [Projection.environmentKey: other]) == .legacy, "\(other)")
        }
    }

    @Test func theLegacyModeListsTheToolsUnchanged() {
        let listed = Projection.listedTools(ServerCatalog.tools, mode: .legacy, strictParams: true)
        #expect(listed.map(\.name) == ServerCatalog.tools.map(\.name))
        #expect(listed.map(\.inputSchema) == ServerCatalog.tools.map(\.inputSchema))
    }

    /// Each branch fixes `command` with `const`, so exactly one branch can apply to a request.
    /// Mutation this kills: a branch that names its command only in its title.
    @Test func everyBranchBindsItsCommandWithConst() throws {
        for tool in Projection.listedTools(ServerCatalog.tools, mode: .rich, strictParams: true) {
            let schema = try #require(tool.inputSchema.objectValue)
            #expect(schema["type"] == .string("object"))
            #expect(schema["required"] == .array([.string("command")]))
            let oneOf = try #require(schema["oneOf"]?.arrayValue, "\(tool.name) has no oneOf")
            for branch in oneOf {
                let object = try #require(branch.objectValue)
                let constant = object["properties"]?.objectValue?["command"]?.objectValue?["const"]?.stringValue
                let bound = constant != nil && constant == object["title"]?.stringValue
                #expect(bound, "\(tool.name) branch \(object["title"] ?? .null) does not bind its command")
            }
        }
    }

    /// Mutation this kills: the command enum or the branch titles taken from anything but the
    /// registry's commands for the tool.
    @Test func everyToolEnumeratesExactlyItsRegisteredCommands() throws {
        for tool in Projection.listedTools(ServerCatalog.tools, mode: .rich, strictParams: true) {
            let id = try #require(ToolID(rawValue: tool.name))
            let expected = OperationRegistry.commands(for: id)
            #expect(!expected.isEmpty)
            #expect(Set(try commandEnum(tool)) == expected, "\(tool.name)")
            #expect(Set(try branches(tool).keys) == expected, "\(tool.name)")
        }
    }

    /// For every registered operation, under strict validation on and off, the branch titled with
    /// its command admits a parameter exactly when the runtime gate does: each allowed parameter,
    /// and an unknown one. Mutations this kills: branches always closed (opt-outs and strict-off
    /// refused by the schema but admitted by the server), always open (an unknown parameter admitted
    /// by the schema and refused by the server), or listing the wrong parameters.
    @Test(arguments: [true, false])
    func eachBranchAdmitsWhatTheRuntimeGateAdmits(strict: Bool) async throws {
        let tools = Projection.listedTools(ServerCatalog.tools, mode: .rich, strictParams: strict)
        var closed = 0, open = 0
        for spec in OperationRegistry.specs {
            let tool = try #require(tools.first { $0.name == spec.tool.rawValue })
            let branch = try #require(try branches(tool)[spec.command], "\(spec.id.rawValue)")
            let paramsSchema = branch["properties"]?.objectValue?["params"]?.objectValue ?? [:]
            var requests = spec.allowedParams.map { [$0: Value.string("x")] }
            requests.append(["zz_not_a_parameter": .string("x")])
            requests.append([:])
            for params in requests {
                let refused = await FeatureFlags.withAdr003StrictParamsForTests(strict) {
                    LogicProServer.strictParamValidationResult(
                        tool: spec.tool.rawValue, command: spec.command, params: params) != nil
                }
                // The comparison is made outside the macro: `#expect(x == !y)` in this loop recorded
                // nothing when it was false (Swift Testing 0.99, seen with a dropped parameter).
                let matching = try matchingBranches(tool, command: spec.command, params: params)
                let agrees = (matching == 1) != refused
                #expect(agrees, "\(spec.id.rawValue) strict=\(strict) \(params.keys.sorted()): runtime refused=\(refused)")
            }
            if paramsSchema["additionalProperties"] == .bool(false) { closed += 1 } else { open += 1 }
        }
        // Control: both kinds of branch occur when strict is on, so neither half of the check is vacuous.
        if strict {
            #expect(closed > 0 && open > 0, "closed \(closed), open \(open)")
        } else {
            #expect(closed == 0)
        }
    }

    /// The issue's first deliverable: a valid request, a missing, wrong and unknown parameter on one
    /// command, and a second command's parameter sent to it.
    @Test func gotoPositionAgreesWithTheGateOnValidUnknownAndForeignParameters() async throws {
        let tools = Projection.listedTools(ServerCatalog.tools, mode: .rich, strictParams: true)
        let transport = try #require(tools.first { $0.name == ToolID.logicTransport.rawValue })
        let spec = try #require(OperationRegistry.spec(tool: "logic_transport", command: "goto_position"))
        let foreign = try #require(OperationRegistry.specs
            .filter { $0.tool == .logicTransport && $0.command != "goto_position" }
            .flatMap(\.allowedParams).first { !spec.allowedParams.contains($0) })
        let cases: [([String: Value], Bool)] = [
            (["position": .string("1.1.1.1")], true),
            ([:], true),
            (["positon": .string("1.1.1.1")], false),
            ([foreign: .string("x")], false),
        ]
        for (params, admitted) in cases {
            let refused = await FeatureFlags.withAdr003StrictParamsForTests(true) {
                LogicProServer.strictParamValidationResult(
                    tool: "logic_transport", command: "goto_position", params: params) != nil
            }
            let runtimeAgrees = refused != admitted
            let schemaAgrees = (try matchingBranches(transport, command: "goto_position", params: params) == 1) == admitted
            #expect(runtimeAgrees, "runtime \(params.keys.sorted())")
            #expect(schemaAgrees, "schema \(params.keys.sorted())")
        }
    }

    /// The committed table is the registry's rendering. Mutation this kills: a hand edit to the
    /// table, or a registry change committed without regenerating it.
    @Test func theCommittedParameterTableIsTheRegistrysRendering() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(Projection.generatedTablePath)
        let rendered = Projection.parameterTable()
        if ProcessInfo.processInfo.environment["LPM_WRITE_GENERATED_DOCS"] == "1" {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: url, encoding: .utf8)
        let same = committed == rendered
        #expect(same, "\(Projection.generatedTablePath) differs from the registry; regenerate it")
        // Control: every registered command has a row, so an empty rendering cannot match an empty file.
        for spec in OperationRegistry.specs {
            let row = "| `\(spec.command)` |"
            let present = rendered.contains(row)
            #expect(present, "no row for \(spec.id.rawValue)")
        }
    }

    // MARK: - Reading the projected JSON

    private func commandEnum(_ tool: Tool) throws -> [String] {
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        let values = try #require(properties["command"]?.objectValue?["enum"]?.arrayValue)
        return values.compactMap(\.stringValue)
    }

    /// The top-level branches, keyed by the command their `const` fixes.
    private func branches(_ tool: Tool) throws -> [String: [String: Value]] {
        let oneOf = try #require(tool.inputSchema.objectValue?["oneOf"]?.arrayValue)
        var byCommand: [String: [String: Value]] = [:]
        for branch in oneOf {
            let object = try #require(branch.objectValue)
            let command = try #require(object["properties"]?.objectValue?["command"]?.objectValue?["const"]?.stringValue)
            #expect(byCommand[command] == nil, "two branches fix command \(command)")
            byCommand[command] = object
        }
        return byCommand
    }

    /// How many top-level branches a `{command, params}` request satisfies, reading the subset of
    /// JSON Schema the branches use: `const` on `command`, and an object `params` whose
    /// `properties` names its parameters, closed when `additionalProperties` is false.
    private func matchingBranches(_ tool: Tool, command: String, params: [String: Value]) throws -> Int {
        let oneOf = try #require(tool.inputSchema.objectValue?["oneOf"]?.arrayValue)
        return oneOf.filter { branch in
            let properties = branch.objectValue?["properties"]?.objectValue ?? [:]
            guard properties["command"]?.objectValue?["const"]?.stringValue == command else { return false }
            let schema = properties["params"]?.objectValue ?? [:]
            guard schema["type"] == .string("object") else { return false }
            guard schema["additionalProperties"] == .bool(false) else { return true }
            let named = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            return Set(params.keys).isSubset(of: named)
        }.count
    }
}
