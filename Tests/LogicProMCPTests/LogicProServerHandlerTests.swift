import Foundation
import MCP
import Testing
@testable import LogicProMCP

private let serverToolText = sharedToolText
private let serverResourceText = sharedResourceText
// ServerStartRecorder lives in SharedTestHelpers (SharedServerStartRecorder, aliased via EndToEndTests)

@Test func testLogicProServerHandlersListCatalogAndTemplates() async {
    let server = LogicProServer()
    let handlers = await server.makeHandlers()

    let tools = await handlers.listTools(ListTools.Parameters())
    let resources = await handlers.listResources(ListResources.Parameters())
    let templates = await handlers.listResourceTemplates(ListResourceTemplates.Parameters())

    #expect(tools.tools.map(\.name) == [
        "logic_transport",
        "logic_tracks",
        "logic_mixer",
        "logic_midi",
        "logic_edit",
        "logic_navigate",
        "logic_project",
        "logic_system",
    ])
    #expect(resources.resources.map(\.uri) == [
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://project/info",
        "logic://midi/ports",
        "logic://system/health",
    ])
    #expect(templates.templates.map(\.uriTemplate) == ["logic://tracks/{index}"])
}

@Test func testLogicProServerHandlersDispatchToolNamesWithoutStartingServer() async {
    let server = LogicProServer()
    let handlers = await server.makeHandlers()
    let toolNames = [
        "logic_transport",
        "logic_tracks",
        "logic_mixer",
        "logic_midi",
        "logic_edit",
        "logic_navigate",
        "logic_project",
        "logic_system",
    ]

    for name in toolNames {
        let result = await handlers.callTool(
            CallTool.Parameters(name: name, arguments: ["command": Value.string("__unknown__")])
        )
        #expect(!serverToolText(result).isEmpty)
    }

    let unknown = await handlers.callTool(
        CallTool.Parameters(name: "logic_unknown", arguments: ["command": Value.string("noop")])
    )
    #expect(unknown.isError == true)
    #expect(serverToolText(unknown).contains("Unknown tool"))
}

@Test func testLogicProServerHandlersReadResourcesWithoutRegisteredTransport() async throws {
    let server = LogicProServer()
    let handlers = await server.makeHandlers()

    let transport = try await handlers.readResource(.init(uri: "logic://transport/state"))
    let tracks = try await handlers.readResource(.init(uri: "logic://tracks"))
    let health = try await handlers.readResource(.init(uri: "logic://system/health"))

    let trackPayload = serverResourceText(tracks)
    let trackJSON = try JSONSerialization.jsonObject(with: Data(trackPayload.utf8)) as? [[String: Any]]

    #expect(serverResourceText(transport).contains("\"tempo\""))
    #expect(trackJSON?.isEmpty == true)
    #expect(serverResourceText(health).contains("\"logic_pro_running\""))
}

@Test func testLogicProServerStartUsesRuntimeOverridesOnSuccess() async throws {
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.coreMIDI], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        registerHandlers: { await recorder.record("registerHandlers") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    try await server.start()

    #expect(await recorder.snapshot() == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "startPoller",
        "registerHandlers",
        "serve",
        "stopPoller",
        "stopChannels",
        "stopPorts",
    ])
}

@Test func testLogicProServerStartUsesRuntimeOverridesOnStartupFailure() async {
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [], failures: [.mcu: "missing"], degraded: [:])
        },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    await #expect(throws: LogicProServer.StartupError.self) {
        try await server.start()
    }

    #expect(await recorder.snapshot() == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "stopChannels",
        "stopPorts",
    ])
}

@Test func testLogicProServerStartUsesDefaultHandlerRegistrationWhenNotOverridden() async throws {
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.mcu, .coreMIDI], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    try await server.start()

    #expect(await recorder.snapshot() == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "startPoller",
        "serve",
        "stopPoller",
        "stopChannels",
        "stopPorts",
    ])

    let handlers = await server.makeHandlers()
    let toolNames = await handlers.listTools(ListTools.Parameters())
    #expect(toolNames.tools.count == 8)
}

@Test func testLogicProServerStartUsesDefaultRegisterAndCleanupPaths() async throws {
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        startPorts: { await recorder.record("startPorts") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.mcu], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    try await server.start()

    let handlers = await server.makeHandlers()
    let systemHelp = await handlers.callTool(
        CallTool.Parameters(name: "logic_system", arguments: ["command": Value.string("help")])
    )

    #expect(serverToolText(systemHelp).contains("Logic Pro MCP"))
    #expect(await recorder.snapshot() == [
        "startPorts",
        "startChannels",
        "startPoller",
        "serve",
        "stopPoller",
    ])
}

@Test func testLogicProServerStartCoversDefaultPortAndPollerLifecyclePaths() async throws {
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.mcu, .coreMIDI], failures: [:], degraded: [:])
        },
        serve: { await recorder.record("serve") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    try await server.start()

    let handlers = await server.makeHandlers()
    let resources = await handlers.listResources(ListResources.Parameters())
    #expect(resources.resources.count == 6)
    #expect(await recorder.snapshot() == [
        "startChannels",
        "serve",
    ])
}
