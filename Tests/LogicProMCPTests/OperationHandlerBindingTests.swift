import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Operation handler bindings", .serialized)
struct OperationHandlerBindingTests {
    private static let handledCommandsByTool: [ToolID: Set<String>] = [
        .logicTransport: TransportDispatcher.handledCommands,
        .logicTracks: TrackDispatcher.handledCommands,
        .logicMixer: MixerDispatcher.handledCommands,
        .logicMidi: MIDIDispatcher.handledCommands,
        .logicEdit: EditDispatcher.handledCommands,
        .logicNavigate: NavigateDispatcher.handledCommands,
        .logicProject: ProjectDispatcher.handledCommands,
        .logicAudio: AudioDispatcher.handledCommands,
        .logicSystem: SystemDispatcher.handledCommands,
        .logicPlugins: PluginsDispatcher.handledCommands,
    ]
    private static let directOnlyCommandsByTool: [ToolID: Set<String>] = [
        .logicTracks: TrackDispatcher.directOnlyCommands,
    ]

    private static func parityIssues(
        registered: Set<String>,
        handled: Set<String>
    ) -> (missing: [String], phantom: [String]) {
        (
            registered.subtracting(handled).sorted(),
            handled.subtracting(registered).sorted()
        )
    }

    private static func dependencies() -> HandlerDependencies {
        let cache = StateCache()
        return HandlerDependencies(
            router: ChannelRouter(),
            cache: cache,
            targetRegistry: TargetRegistry(),
            poller: StatePoller(
                axChannel: AccessibilityChannel(),
                cache: cache,
                runtime: .fastTest
            ),
            dialogPresent: { false },
            supportBundleExporter: nil
        )
    }

    private static func bytes(_ result: CallTool.Result) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    private static func object(_ result: CallTool.Result) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes(result)) as? [String: Any])
    }

    @Test("dispatchers and registry have bidirectional command parity")
    func dispatcherCommandsMatchRegistryInBothDirections() {
        #expect(
            Set(Self.handledCommandsByTool.keys.map(\.rawValue))
                == OperationRegistry.registeredToolRawValues
        )

        for (tool, handled) in Self.handledCommandsByTool {
            let registered = Set(OperationRegistry.specs
                .filter { $0.tool == tool }
                .map(\.command))
            let issues = Self.parityIssues(registered: registered, handled: handled)
            #expect(issues.missing.isEmpty, "\(tool.rawValue) missing dispatcher cases: \(issues.missing)")
            #expect(issues.phantom.isEmpty, "\(tool.rawValue) phantom dispatcher cases: \(issues.phantom)")
        }
    }

    @Test("parity detector identifies phantom and missing commands")
    func parityDetectorProvesBothDirections() {
        let registered: Set<String> = ["implemented"]
        let phantom = Self.parityIssues(
            registered: registered,
            handled: ["implemented", "__phantom"]
        )
        let missing = Self.parityIssues(registered: registered, handled: [])

        #expect(phantom.missing.isEmpty)
        #expect(phantom.phantom == ["__phantom"])
        #expect(missing.missing == ["implemented"])
        #expect(missing.phantom.isEmpty)
    }

    @Test("only deliberate not-exposed stubs have an unregistered MCP fallback")
    func onlyNotExposedStubsHaveUnregisteredFallback() {
        for (tool, commands) in Self.directOnlyCommandsByTool {
            #expect(commands.isDisjoint(with: Self.handledCommandsByTool[tool] ?? []))
            for command in commands {
                #expect(OperationRegistry.spec(tool: tool.rawValue, command: command) == nil)
                #expect(OperationHandlerRegistry.fallbackHandler(
                    tool: tool.rawValue,
                    command: command
                ) == nil)
            }
        }

        let typedStubs = [
            (ToolID.logicTracks.rawValue, "set_color"),
            (ToolID.logicMixer.rawValue, "set_send"),
            (ToolID.logicMixer.rawValue, "set_output"),
            (ToolID.logicMixer.rawValue, "set_input"),
            (ToolID.logicMixer.rawValue, "toggle_eq"),
            (ToolID.logicMixer.rawValue, "reset_strip"),
            (ToolID.logicMixer.rawValue, "bypass_plugin"),
        ]

        for (tool, command) in typedStubs {
            #expect(OperationRegistry.spec(tool: tool, command: command) == nil)
            #expect(
                OperationHandlerRegistry.fallbackHandler(tool: tool, command: command) != nil,
                "\(tool).\(command) must reach its typed dispatcher stub"
            )
        }

        #expect(TrackDispatcher.notExposedCommands == ["set_color"])
        #expect(MixerDispatcher.notExposedCommands == [
            "set_send", "set_output", "set_input", "toggle_eq", "reset_strip", "bypass_plugin",
        ])
        #expect(TrackDispatcher.notExposedCommands.isDisjoint(with: TrackDispatcher.handledCommands))
        #expect(MixerDispatcher.notExposedCommands.isDisjoint(with: MixerDispatcher.handledCommands))

        #expect(OperationHandlerRegistry.fallbackHandler(
            tool: ToolID.logicTracks.rawValue,
            command: "__unknown__"
        ) == nil)
    }

    @Test("registry exactly binds every operation spec once")
    func registryMatchesOperationSpecs() throws {
        let specs = OperationRegistry.specs
        let bindings = OperationHandlerRegistry.bindings
        let specIDs = Set(specs.map(\.id))
        let bindingIDs = bindings.map(\.id)
        let specKeys = Set(specs.map { "\($0.tool.rawValue):\($0.command)" })
        let bindingKeys = bindings.map { "\($0.tool):\($0.command)" }

        #expect(specs.count == 112)   // #575 registered edit.move_to_playhead
        #expect(bindings.count == specs.count)
        #expect(Set(bindingIDs).count == bindings.count, "duplicate handler IDs")
        #expect(Set(bindingKeys).count == bindings.count, "duplicate handler keys")
        #expect(Set(bindingIDs) == specIDs, "missing or orphan handler IDs")
        #expect(Set(bindingKeys) == specKeys, "missing or orphan handler keys")
        #expect(OperationHandlerRegistry.validationErrors().isEmpty)

        OperationHandlerRegistry.validate()
        for command in ["list_recent_traces", "get_trace", "clear_traces"] {
            let spec = try #require(OperationRegistry.spec(
                tool: ToolID.logicSystem.rawValue,
                command: command
            ))
            #expect(OperationHandlerRegistry.handler(for: spec.id) != nil)
            #expect(OperationHandlerRegistry.fallbackHandler(
                tool: ToolID.logicSystem.rawValue,
                command: command
            ) != nil)
        }
        for spec in specs {
            #expect(OperationHandlerRegistry.handler(for: spec.id) != nil)
            #expect(OperationHandlerRegistry.handler(
                tool: spec.tool.rawValue,
                command: spec.command
            ) != nil)
        }
    }

    @Test("representative registry handlers are byte-identical to direct dispatch")
    func representativeHandlersMatchDirectDispatchers() async throws {
        let dependencies = Self.dependencies()
        await dependencies.router.register(MockChannel(id: .coreMIDI))
        await dependencies.router.register(MockChannel(id: .accessibility))
        let cases: [(OperationID, [String: Value], CallTool.Result)] = [
            (
                .midiListPorts,
                [:],
                await MIDIDispatcher.handle(
                    command: "list_ports",
                    params: [:],
                    router: dependencies.router,
                    cache: dependencies.cache
                )
            ),
            (
                .tracksListLibrary,
                [:],
                await TrackDispatcher.handle(
                    command: "list_library",
                    params: [:],
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry,
                    dialogPresent: dependencies.dialogPresent
                )
            ),
            (
                .pluginsGetInventory,
                ["track": .int(0)],
                await PluginsDispatcher.handle(
                    command: "get_inventory",
                    params: ["track": .int(0)],
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry
                )
            ),
            (
                .systemExportSupportBundle,
                // PRD-011: an absolute path outside the support-bundle root is
                // rejected by containment before any write — both paths must
                // produce the identical typed rejection.
                ["dir": .string("/definitely-outside-bundle-root")],
                await SystemDispatcher.handle(
                    command: "export_support_bundle",
                    params: ["dir": .string("/definitely-outside-bundle-root")],
                    router: dependencies.router,
                    cache: dependencies.cache,
                    poller: dependencies.poller,
                    supportBundleExporter: dependencies.supportBundleExporter
                )
            ),
        ]

        for (operationID, params, direct) in cases {
            let handler = try #require(OperationHandlerRegistry.handler(for: operationID))
            let throughRegistry = await handler(dependencies, params)
            #expect(throughRegistry == direct)
            #expect(try Self.bytes(throughRegistry) == Self.bytes(direct))
        }
    }

    @Test("known not-exposed commands reach typed stubs while truly unknown commands stay rejected")
    func knownNotExposedCommandsReachTypedStubsAndUnknownCommandsStayRejected() async throws {
        let server = LogicProServer()
        let handlers = await server.makeHandlers()
        let notExposedCases = [
            (ToolID.logicTracks.rawValue, "set_color"),
            (ToolID.logicMixer.rawValue, "set_send"),
            (ToolID.logicMixer.rawValue, "set_output"),
            (ToolID.logicMixer.rawValue, "set_input"),
            (ToolID.logicMixer.rawValue, "toggle_eq"),
            (ToolID.logicMixer.rawValue, "reset_strip"),
            (ToolID.logicMixer.rawValue, "bypass_plugin"),
        ]

        for (tool, command) in notExposedCases {
            let result = await handlers.callTool(.init(
                name: tool,
                arguments: ["command": .string(command)]
            ))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(OperationHandlerRegistry.handler(tool: tool, command: command) == nil)
            #expect(OperationHandlerRegistry.fallbackHandler(tool: tool, command: command) != nil)
            let v1 = try #require(result.isError)
            #expect(v1)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "command_not_exposed")
            let v2 = try #require(body["not_exposed"] as? Bool)
            #expect(v2)
            let v3 = try #require(body["supported"] as? Bool)
            #expect(!v3)
        }

        for command in ["library", "__nope__"] {
            let result = await handlers.callTool(.init(
                name: ToolID.logicTracks.rawValue,
                arguments: ["command": .string(command)]
            ))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(OperationHandlerRegistry.fallbackHandler(
                tool: ToolID.logicTracks.rawValue,
                command: command
            ) == nil)
            let v4 = try #require(result.isError)
            #expect(v4)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "invalid_params")
            #expect(body["tool"] as? String == ToolID.logicTracks.rawValue)
            #expect(body["command"] as? String == command)
            let v5 = try #require(body["write_attempted"] as? Bool)
            #expect(!v5)
        }

        let unknownTool = await handlers.callTool(.init(
            name: "logic_unknown",
            arguments: ["command": .string("noop")]
        ))
        let directUnknownTool = toolTextResult("Unknown tool: logic_unknown", isError: true)
        #expect(unknownTool == directUnknownTool)
        #expect(try Self.bytes(unknownTool) == Self.bytes(directUnknownTool))
    }

    @Test("MCP protocol preserves registered results and typed unregistered rejection")
    func protocolRoutePreservesDispatcherResults() async throws {
        let server = LogicProServer()
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        _ = try await waitForProbeResponse(transport, id: 1)

        let dependencies = Self.dependencies()
        let registeredDirect = await TransportDispatcher.handle(
            command: "set_tempo",
            params: [:],
            router: dependencies.router,
            cache: dependencies.cache,
            dialogPresent: dependencies.dialogPresent
        )
        await transport.queueJSON(probeToolCallFrame(
            id: 2,
            name: TransportDispatcher.tool.name,
            command: "set_tempo"
        ))
        let registeredResponse = try await waitForProbeResponse(transport, id: 2)
        let registeredResult = try #require(registeredResponse["result"] as? [String: Any])
        #expect(try canonicalJSONObjectData(registeredResult)
            == canonicalJSONObjectData(Self.object(registeredDirect)))

        let unknownCommand = "__operation_handler_protocol_unknown__"
        let unknownExpected = await server.makeHandlers().callTool(.init(
            name: TrackDispatcher.tool.name,
            arguments: ["command": .string(unknownCommand)]
        ))
        await transport.queueJSON(probeToolCallFrame(
            id: 3,
            name: TrackDispatcher.tool.name,
            command: unknownCommand
        ))
        let unknownResponse = try await waitForProbeResponse(transport, id: 3)
        let unknownResult = try #require(unknownResponse["result"] as? [String: Any])
        #expect(try canonicalJSONObjectData(unknownResult)
            == canonicalJSONObjectData(Self.object(unknownExpected)))
    }
}
