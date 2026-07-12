import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Operation handler bindings", .serialized)
struct OperationHandlerBindingTests {
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

    @Test("registry exactly binds every operation spec once")
    func registryMatchesOperationSpecs() throws {
        let specs = OperationRegistry.specs
        let bindings = OperationHandlerRegistry.bindings
        let specIDs = Set(specs.map(\.id))
        let bindingIDs = bindings.map(\.id)
        let specKeys = Set(specs.map { "\($0.tool.rawValue):\($0.command)" })
        let bindingKeys = bindings.map { "\($0.tool):\($0.command)" }

        #expect(specs.count == 100)
        #expect(bindings.count == specs.count)
        #expect(Set(bindingIDs).count == bindings.count, "duplicate handler IDs")
        #expect(Set(bindingKeys).count == bindings.count, "duplicate handler keys")
        #expect(Set(bindingIDs) == specIDs, "missing or orphan handler IDs")
        #expect(Set(bindingKeys) == specKeys, "missing or orphan handler keys")
        #expect(OperationHandlerRegistry.validationErrors().isEmpty)

        OperationHandlerRegistry.validate()
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
                ["dir": .string("relative")],
                await SystemDispatcher.handle(
                    command: "export_support_bundle",
                    params: ["dir": .string("relative")],
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

    @Test("unregistered server command preserves dispatcher bytes")
    func unregisteredCommandPreservesDispatcherUnknownResponse() async throws {
        let command = "__operation_handler_binding_unknown__"
        let server = LogicProServer()
        let handlers = await server.makeHandlers()
        let throughServer = await handlers.callTool(.init(
            name: TrackDispatcher.tool.name,
            arguments: ["command": .string(command)]
        ))
        let dependencies = Self.dependencies()
        let direct = await TrackDispatcher.handle(
            command: command,
            params: [:],
            router: dependencies.router,
            cache: dependencies.cache,
            targetRegistry: dependencies.targetRegistry,
            dialogPresent: dependencies.dialogPresent
        )

        #expect(OperationHandlerRegistry.handler(
            tool: TrackDispatcher.tool.name,
            command: command
        ) == nil)
        #expect(throughServer == direct)
        #expect(try Self.bytes(throughServer) == Self.bytes(direct))

        let unknownTool = await handlers.callTool(.init(
            name: "logic_unknown",
            arguments: ["command": .string("noop")]
        ))
        let directUnknownTool = toolTextResult("Unknown tool: logic_unknown", isError: true)
        #expect(unknownTool == directUnknownTool)
        #expect(try Self.bytes(unknownTool) == Self.bytes(directUnknownTool))
    }

    @Test("MCP protocol preserves registered and unregistered dispatcher results")
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
        let unknownDirect = await TrackDispatcher.handle(
            command: unknownCommand,
            params: [:],
            router: dependencies.router,
            cache: dependencies.cache,
            targetRegistry: dependencies.targetRegistry,
            dialogPresent: dependencies.dialogPresent
        )
        await transport.queueJSON(probeToolCallFrame(
            id: 3,
            name: TrackDispatcher.tool.name,
            command: unknownCommand
        ))
        let unknownResponse = try await waitForProbeResponse(transport, id: 3)
        let unknownResult = try #require(unknownResponse["result"] as? [String: Any])
        #expect(try canonicalJSONObjectData(unknownResult)
            == canonicalJSONObjectData(Self.object(unknownDirect)))
    }
}
