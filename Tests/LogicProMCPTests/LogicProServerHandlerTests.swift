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
        "logic_audio",
        "logic_system",
        "logic_plugins",
    ])
    // #215: the list always advertises the full static catalog, including
    // `logic://mcu/state`, even in a fresh (MCU-disconnected) server — the
    // resource is always directly readable and the docs advertise it as stable.
    let resourceURIs = Set(resources.resources.map(\.uri))
    let expectedResources: Set<String> = [
        "logic://mcu/state",
        "logic://system/health",
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://markers",
        "logic://project/info",
        "logic://project/audit",
        "logic://project/cleanup-plan",
        "logic://midi/ports",
        "logic://library/inventory",
        "logic://stock-plugins",
        "logic://stock-plugins/census",
        "logic://stock-plugins/capabilities",
        "logic://stock-instruments",
        "logic://session-players",
        "logic://workflow-skills",
        "logic://workflow-skills/schema",
    ]
    #expect(expectedResources.isSubset(of: resourceURIs))
    #expect(resourceURIs.contains("logic://mcu/state"))
    #expect(resourceURIs.count == 18)
    let templateURIs = Set(templates.templates.map(\.uriTemplate))
    let expectedTemplates: Set<String> = [
        "logic://tracks/{index}",
        "logic://tracks/{index}/regions",
        "logic://mixer/{strip}",
        "logic://stock-plugins/{id}",
        "logic://stock-plugins/search?query={query}",
        "logic://stock-instruments/{id}",
        "logic://stock-instruments/search?query={query}",
        "logic://session-players/{id}",
        "logic://workflow-plans/session?prompt={prompt}",

        "logic://workflow-skills/{id}",
        "logic://workflow-skills/search?query={query}",
    ]
    #expect(expectedTemplates.isSubset(of: templateURIs))
}

@Test func testInvalidPaginationCursorRejectedWithInvalidParams() {
    // #218: the server paginates into a single page and never issues a
    // nextCursor, so ANY client cursor is invalid → JSON-RPC -32602. An absent
    // cursor (nil) is the normal first-page read and must pass.
    for method in ["tools/list", "resources/list", "resources/templates/list"] {
        #expect(LogicProServer.invalidCursorError("bogus", method: method)?.code == -32602)
        #expect(LogicProServer.invalidCursorError("", method: method)?.code == -32602)
        #expect(LogicProServer.invalidCursorError(nil, method: method) == nil)
    }
    // The error message identifies the offending method + cursor.
    let err = LogicProServer.invalidCursorError("abc", method: "tools/list")
    #expect(err?.errorDescription?.contains("tools/list") == true)
    #expect(err?.errorDescription?.contains("abc") == true)
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
        "logic_audio",
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
    #expect(unknown.isError!)
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

@Test func testLogicProServerStartCleansOwnedAndLegacySMFArtifacts() async throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("logic-pro-server-startup-cleanup-\(UUID().uuidString)", isDirectory: true)
    let tempRoot = sandbox.appendingPathComponent("temp-root", isDirectory: true)
    let legacyDir = sandbox.appendingPathComponent("LogicProMCP", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let ownedDirPath = SMFWriter.temporaryDirectoryPrefix(baseDirectory: tempRoot) + UUID().uuidString
    let unrelatedFilePath = tempRoot.appendingPathComponent("other.mid").path
    let legacyFilePath = legacyDir.appendingPathComponent("old.mid").path
    try FileManager.default.createDirectory(atPath: ownedDirPath, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: "\(ownedDirPath)/owned.mid",
        contents: Data([0, 1, 2])
    )
    FileManager.default.createFile(atPath: unrelatedFilePath, contents: Data([0, 1, 2]))
    FileManager.default.createFile(atPath: legacyFilePath, contents: Data([0, 1, 2]))

    let oldDate = Date().addingTimeInterval(-600)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: ownedDirPath)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelatedFilePath)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: legacyFilePath)

    let overrides = LogicProServerRuntimeOverrides(
        cleanupStartupArtifacts: {
            SMFWriter.cleanupStartupOrphanFiles(
                baseDirectory: tempRoot,
                legacyManagedDirectories: [legacyDir.standardizedFileURL.path]
            )
        },
        startPorts: {},
        registerChannels: {},
        startChannels: { .init(started: [], failures: [:], degraded: [:]) },
        startPoller: {},
        registerHandlers: {},
        serve: {},
        stopPoller: {},
        stopChannels: {},
        stopPorts: {}
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    try await server.start()

    #expect(!FileManager.default.fileExists(atPath: ownedDirPath))
    #expect(FileManager.default.fileExists(atPath: unrelatedFilePath))
    #expect(!FileManager.default.fileExists(atPath: legacyFilePath))
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
    #expect(toolNames.tools.count == 10)
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
    // Override startPoller/stopPoller to no-ops — the production path spawns a
    // real StatePoller against AccessibilityChannel which, in a test without
    // Logic Pro running, makes the task never complete. We're exercising the
    // handler wire-up here, not the live poller path (which has its own
    // `testStatePollerStartStopLifecycle` coverage with the fast-test runtime).
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.mcu, .coreMIDI], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    try await server.start()

    let handlers = await server.makeHandlers()
    let resources = await handlers.listResources(ListResources.Parameters())
    // #215: the full static catalog is always listed, including
    // `logic://mcu/state`, even with a fresh (MCU-disconnected) cache.
    let uris = Set(resources.resources.map(\.uri))
    let expectedResources: Set<String> = [
        "logic://mcu/state",
        "logic://system/health",
        "logic://transport/state",
        "logic://tracks",
        "logic://mixer",
        "logic://markers",
        "logic://project/info",
        "logic://project/audit",
        "logic://project/cleanup-plan",
        "logic://midi/ports",
        "logic://library/inventory",
        "logic://stock-plugins",
        "logic://stock-plugins/census",
        "logic://stock-plugins/capabilities",
        "logic://stock-instruments",
        "logic://session-players",
        "logic://workflow-skills",
        "logic://workflow-skills/schema",
    ]
    #expect(expectedResources.isSubset(of: uris))
    #expect(uris.contains("logic://mcu/state"))
    #expect(uris.count == 18)
    // server.start() runs serve() to completion then tears poller/channels/ports
    // down in reverse order. With serve recorded as a no-op, the tail section
    // executes immediately so stopPoller is captured too.
    #expect(await recorder.snapshot() == [
        "startChannels",
        "startPoller",
        "serve",
        "stopPoller",
    ])
}

// RB-3 (signal cleanup): MainEntrypoint's SIGTERM/SIGINT handlers were
// `exit(0)` before this fix, which leaked the AX poller, channel transports,
// and virtual MIDI ports on every supervisor restart. The fix adds a public
// `LogicProServer.stop()` that the signal handler now invokes; this test
// guards the behaviour by exercising stop() directly.
@Test func testLogicProServerStopInvokesPollerChannelsPortsTeardown() async {
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    await server.stop()

    #expect(await recorder.snapshot() == [
        "stopPoller",
        "stopChannels",
        "stopPorts",
    ])
}

@Test func testLogicProServerStopDoesNotHangOnRepeatInvocation() async {
    // RB-3 (signal cleanup): repeat-stop tolerance is required because a
    // supervisor may send SIGTERM while the previous shutdown is still in
    // flight. `stop()` itself does NOT dedupe — each call drives the full
    // teardown closure chain — but the underlying actors (`StatePoller`,
    // `ChannelRouter`, `MIDIPortManager`) swallow repeats internally
    // (`StatePoller.stop()` early-returns when `pollingTask == nil`, etc.).
    // This test pins the entrypoint behaviour: "two consecutive stop()
    // invocations complete without throwing or hanging," not "stop()
    // self-dedupes its work."
    let recorder = ServerStartRecorder()
    let overrides = LogicProServerRuntimeOverrides(
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") }
    )
    let server = LogicProServer(runtimeOverrides: overrides)

    await server.stop()
    await server.stop()

    #expect(await recorder.snapshot() == [
        "stopPoller", "stopChannels", "stopPorts",
        "stopPoller", "stopChannels", "stopPorts",
    ])
}
