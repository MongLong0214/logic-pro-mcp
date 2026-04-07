import CoreMIDI
import Foundation
import MCP

private func emitMIDIPacket(to source: MIDIEndpointRef, bytes: [UInt8]) {
    let bufferSize = max(MemoryLayout<MIDIPacketList>.size, MemoryLayout<MIDIPacketList>.size + bytes.count)
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    buffer.withUnsafeMutableBytes { rawBuf in
        let packetList = rawBuf.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
        var pkt = MIDIPacketListInit(packetList)
        bytes.withUnsafeBufferPointer { dataBuf in
            guard let base = dataBuf.baseAddress else { return }
            pkt = MIDIPacketListAdd(packetList, bufferSize, pkt, 0, bytes.count, base)
        }
        MIDIReceived(source, packetList)
    }
}

struct ServerCompositionSnapshot: Sendable, Equatable {
    let channelIDs: [ChannelID]
    let toolNames: [String]
    let resourceURIs: [String]
    let templateURIs: [String]
    let startupBanner: String
}

enum ServerCatalog {
    static let tools: [Tool] = [
        TransportDispatcher.tool,
        TrackDispatcher.tool,
        MixerDispatcher.tool,
        MIDIDispatcher.tool,
        EditDispatcher.tool,
        NavigateDispatcher.tool,
        ProjectDispatcher.tool,
        SystemDispatcher.tool,
    ]

    static func startupBanner(channelCount: Int) -> String {
        "Starting \(ServerConfig.serverName) v\(ServerConfig.serverVersion) — \(tools.count) tools, \(ResourceProvider.resources.count) resources, \(channelCount) channels"
    }

    static func snapshot(channelIDs: [ChannelID]) -> ServerCompositionSnapshot {
        ServerCompositionSnapshot(
            channelIDs: channelIDs,
            toolNames: tools.map(\.name),
            resourceURIs: ResourceProvider.resources.map(\.uri),
            templateURIs: ResourceProvider.templates.map(\.uriTemplate),
            startupBanner: startupBanner(channelCount: channelIDs.count)
        )
    }
}

struct LogicProServerHandlers: Sendable {
    let listTools: @Sendable (ListTools.Parameters) async -> ListTools.Result
    let callTool: @Sendable (CallTool.Parameters) async -> CallTool.Result
    let listResources: @Sendable (ListResources.Parameters) async -> ListResources.Result
    let readResource: @Sendable (ReadResource.Parameters) async throws -> ReadResource.Result
    let listResourceTemplates: @Sendable (ListResourceTemplates.Parameters) async -> ListResourceTemplates.Result
}

struct LogicProServerRuntimeOverrides: @unchecked Sendable {
    var startPorts: (@Sendable () async throws -> Void)?
    var registerChannels: (@Sendable () async -> Void)?
    var startChannels: (@Sendable () async -> ChannelRouter.StartReport)?
    var startPoller: (@Sendable () async -> Void)?
    var registerHandlers: (@Sendable () async -> Void)?
    var serve: (@Sendable () async throws -> Void)?
    var stopPoller: (@Sendable () async -> Void)?
    var stopChannels: (@Sendable () async -> Void)?
    var stopPorts: (@Sendable () async -> Void)?
}

/// Internal lifecycle plan executed serially by the server startup path.
/// The stored closures may capture actor references, so we keep the plan local
/// and run it immediately rather than sharing it across concurrent contexts.
struct ServerRuntimePlan: @unchecked Sendable {
    let startPorts: () async throws -> Void
    let registerChannels: () async -> Void
    let startChannels: () async -> ChannelRouter.StartReport
    let startPoller: () async -> Void
    let registerHandlers: () async -> Void
    let serve: () async throws -> Void
    let stopPoller: () async -> Void
    let stopChannels: () async -> Void
    let stopPorts: () async -> Void
    let startupError: ([ChannelID: String]) -> Error

    func run() async throws {
        try await startPorts()
        await registerChannels()

        let startReport = await startChannels()
        if startReport.hasDegraded {
            let summary = startReport.degraded
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue): \($0.value)" }
                .joined(separator: "; ")
            Log.warn("Starting in degraded mode — \(summary)", subsystem: "server")
        }
        if startReport.hasFailures {
            await stopChannels()
            await stopPorts()
            throw startupError(startReport.failures)
        }

        await startPoller()

        do {
            await registerHandlers()
            try await serve()
        } catch {
            await stopPoller()
            await stopChannels()
            await stopPorts()
            throw error
        }

        await stopPoller()
        await stopChannels()
        await stopPorts()
    }
}

/// Main MCP server for Logic Pro integration.
/// Exposes 8 dispatcher tools + 6 resources + 1 template, routing through
/// the ChannelRouter to the appropriate macOS communication channel.
actor LogicProServer {
    private let server: Server
    private let router: ChannelRouter
    private let cache: StateCache
    private let poller: StatePoller
    private let portManager: MIDIPortManager
    private let manualValidationStore: ManualValidationStore

    // Channel instances (7 channels — PRD §4.1)
    private let coreMIDIChannel: CoreMIDIChannel
    private let mcuChannel: MCUChannel
    private let keyCommandsChannel: MIDIKeyCommandsChannel
    private let scripterChannel: ScripterChannel
    private let axChannel: AccessibilityChannel
    private let cgEventChannel: CGEventChannel
    private let appleScriptChannel: AppleScriptChannel
    private let runtimeOverrides: LogicProServerRuntimeOverrides?

    init(runtimeOverrides: LogicProServerRuntimeOverrides? = nil) {
        self.runtimeOverrides = runtimeOverrides
        self.server = Server(
            name: ServerConfig.serverName,
            version: ServerConfig.serverVersion,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        self.router = ChannelRouter()
        self.cache = StateCache()
        self.portManager = MIDIPortManager()
        self.manualValidationStore = ManualValidationStore()

        // Legacy channels
        let midiEngine = MIDIEngine()
        self.coreMIDIChannel = CoreMIDIChannel(engine: midiEngine, portManager: portManager)
        self.axChannel = AccessibilityChannel()
        self.cgEventChannel = CGEventChannel()
        self.appleScriptChannel = AppleScriptChannel()

        // New v2 channels (MCU, KeyCommands, Scripter)
        // These use MockMCUTransport at init — replaced with real transport in start()
        // For production, we create a real CoreMIDI-backed transport in start()
        let mcuTransport = ProductionMCUTransport(portManager: portManager)
        self.mcuChannel = MCUChannel(transport: mcuTransport, cache: cache)

        let keyCmdTransport = ProductionKeyCmdTransport(portManager: portManager)
        self.keyCommandsChannel = MIDIKeyCommandsChannel(
            transport: keyCmdTransport,
            approvalStore: manualValidationStore
        )

        let scripterTransport = ProductionKeyCmdTransport(portManager: portManager, portName: "LogicProMCP-Scripter-Internal")
        self.scripterChannel = ScripterChannel(
            transport: scripterTransport,
            approvalStore: manualValidationStore
        )

        self.poller = StatePoller(axChannel: axChannel, cache: cache)
    }

    enum StartupError: Error, CustomStringConvertible {
        case channelStartupFailed([ChannelID: String])

        var description: String {
            switch self {
            case .channelStartupFailed(let failures):
                let summary = failures
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue): \($0.value)" }
                    .joined(separator: "; ")
                return "Channel startup failed — \(summary)"
            }
        }
    }

    // MARK: - Tool Registration (8 dispatchers)

    func makeHandlers() -> LogicProServerHandlers {
        let router = self.router
        let cache = self.cache

        return LogicProServerHandlers(
            listTools: { _ in
                ListTools.Result(tools: ServerCatalog.tools)
            },
            callTool: { params in
                let name = params.name
                let command = params.arguments?["command"]?.stringValue ?? ""
                let cmdParams: [String: Value] = params.arguments?["params"]?.objectValue ?? [:]

                await cache.recordToolAccess()

                switch name {
                case "logic_transport":
                    return await TransportDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_tracks":
                    return await TrackDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_mixer":
                    return await MixerDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_midi":
                    return await MIDIDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_edit":
                    return await EditDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_navigate":
                    return await NavigateDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_project":
                    return await ProjectDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                case "logic_system":
                    return await SystemDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                default:
                    return toolTextResult("Unknown tool: \(name)", isError: true)
                }
            },
            listResources: { _ in
                ListResources.Result(resources: ResourceProvider.resources, nextCursor: nil)
            },
            readResource: { params in
                try await ResourceHandlers.read(uri: params.uri, cache: cache, router: router)
            },
            listResourceTemplates: { _ in
                ListResourceTemplates.Result(templates: ResourceProvider.templates)
            }
        )
    }

    private func registerTools() async {
        let handlers = makeHandlers()
        await server.withMethodHandler(ListTools.self) { params in
            await handlers.listTools(params)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await handlers.callTool(params)
        }
    }

    // MARK: - Resource Registration (6 resources + 1 template)

    private func registerResources() async {
        let handlers = makeHandlers()
        await server.withMethodHandler(ListResources.self) { params in
            await handlers.listResources(params)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await handlers.readResource(params)
        }

        await server.withMethodHandler(ListResourceTemplates.self) { params in
            await handlers.listResourceTemplates(params)
        }
    }

    // MARK: - Server Lifecycle

    func compositionSnapshot() -> ServerCompositionSnapshot {
        ServerCatalog.snapshot(channelIDs: registeredChannels().map(\.id))
    }

    func start() async throws {
        let plan = runtimePlan()
        try await plan.run()
    }

    private func runtimePlan() -> ServerRuntimePlan {
        let server = self.server
        let router = self.router
        let poller = self.poller
        let portManager = self.portManager
        let channels = registeredChannels()
        let snapshot = ServerCatalog.snapshot(channelIDs: channels.map(\.id))

        return ServerRuntimePlan(
            startPorts: {
                if let startPorts = self.runtimeOverrides?.startPorts {
                    try await startPorts()
                } else {
                    do {
                        try await portManager.start()
                    } catch {
                        Log.warn("MIDI port manager unavailable — continuing degraded: \(error)", subsystem: "server")
                    }
                }
            },
            registerChannels: {
                if let registerChannels = self.runtimeOverrides?.registerChannels {
                    await registerChannels()
                } else {
                    for channel in channels {
                        await router.register(channel)
                    }
                }
            },
            startChannels: {
                if let startChannels = self.runtimeOverrides?.startChannels {
                    return await startChannels()
                }
                return await router.startAll()
            },
            startPoller: {
                if let startPoller = self.runtimeOverrides?.startPoller {
                    await startPoller()
                } else {
                    await poller.start()
                }
            },
            registerHandlers: {
                if let registerHandlers = self.runtimeOverrides?.registerHandlers {
                    await registerHandlers()
                } else {
                    await self.registerTools()
                    await self.registerResources()
                }
            },
            serve: {
                if let serve = self.runtimeOverrides?.serve {
                    try await serve()
                } else {
                    Log.info(snapshot.startupBanner, subsystem: "server")
                    let transport = StdioTransport()
                    try await server.start(transport: transport)
                    await server.waitUntilCompleted()
                }
            },
            stopPoller: {
                if let stopPoller = self.runtimeOverrides?.stopPoller {
                    await stopPoller()
                } else {
                    await poller.stop()
                }
            },
            stopChannels: {
                if let stopChannels = self.runtimeOverrides?.stopChannels {
                    await stopChannels()
                } else {
                    await router.stopAll()
                }
            },
            stopPorts: {
                if let stopPorts = self.runtimeOverrides?.stopPorts {
                    await stopPorts()
                } else {
                    await portManager.stop()
                }
            },
            startupError: {
                StartupError.channelStartupFailed($0)
            }
        )
    }

    private func registeredChannels() -> [any Channel] {
        [
            mcuChannel,
            keyCommandsChannel,
            scripterChannel,
            coreMIDIChannel,
            axChannel,
            cgEventChannel,
            appleScriptChannel,
        ]
    }
}

// MARK: - Production Transports

/// Real MIDI transport for MCU channel using MIDIPortManager.
actor ProductionMCUTransport: MCUTransportProtocol {
    private let portManager: any VirtualPortManaging
    private let packetSink: @Sendable (MIDIEndpointRef, [UInt8]) -> Void
    private var port: MIDIPortManager.MIDIPortPair?
    private var onReceive: (@Sendable (MIDIFeedback.Event) -> Void)?

    init(
        portManager: any VirtualPortManaging,
        packetSink: @escaping @Sendable (MIDIEndpointRef, [UInt8]) -> Void = emitMIDIPacket
    ) {
        self.portManager = portManager
        self.packetSink = packetSink
    }

    func send(_ bytes: [UInt8]) async {
        guard let source = port?.source else {
            Log.warn("MCU port not started — dropping \(bytes.count) bytes", subsystem: "mcu")
            return
        }
        packetSink(source, bytes)
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {
        self.onReceive = onReceive
        do {
            port = try await portManager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { [weak self] eventList, _ in
                guard let self else { return }
                // Parse UMP event list → MIDI 1.0 bytes → MIDIFeedback.Event
                // Use original eventList pointer (not a stack copy) for safe traversal
                let numPackets = Int(eventList.pointee.numPackets)
                guard numPackets > 0 else { return }
                var packetPtr = UnsafeRawPointer(eventList)
                    .advanced(by: MemoryLayout.offset(of: \MIDIEventList.packet)!)
                    .assumingMemoryBound(to: MIDIEventPacket.self)
                for _ in 0..<numPackets {
                    let wordCount = Int(packetPtr.pointee.wordCount)
                    if wordCount > 0 {
                        let bytes: [UInt8] = withUnsafeBytes(of: packetPtr.pointee.words) { raw in
                            Array(raw.prefix(wordCount * 4))
                        }
                        let events = MIDIFeedback.parseBytes(bytes)
                        for event in events {
                            Task { [weak self] in await self?.onReceive?(event) }
                        }
                    }
                    packetPtr = UnsafePointer(MIDIEventPacketNext(packetPtr))
                }
            }
        } catch {
            Log.warn("MCU port creation failed: \(error)", subsystem: "mcu")
            throw error
        }
    }

    func stop() async {
        port = nil
    }
}

/// Real MIDI transport for KeyCmd/Scripter channels — send-only.
actor ProductionKeyCmdTransport: KeyCmdTransportProtocol {
    private let portManager: any VirtualPortManaging
    private let portName: String
    private let packetSink: @Sendable (MIDIEndpointRef, [UInt8]) -> Void
    private var port: MIDIPortManager.MIDIPortPair?
    private var startupError: String?

    init(
        portManager: any VirtualPortManaging,
        portName: String = "LogicProMCP-KeyCmd-Internal",
        packetSink: @escaping @Sendable (MIDIEndpointRef, [UInt8]) -> Void = emitMIDIPacket
    ) {
        self.portManager = portManager
        self.portName = portName
        self.packetSink = packetSink
    }

    func prepare() async throws {
        guard port == nil else { return }
        do {
            port = try await portManager.createSendOnlyPort(name: portName)
            startupError = nil
        } catch {
            startupError = "Failed to create virtual MIDI port '\(portName)': \(error)"
            Log.warn("KeyCmd port creation failed: \(error)", subsystem: "keycmd")
            throw error
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await prepare()
        guard let source = port?.source else {
            throw NSError(domain: "LogicProMCP.ProductionKeyCmdTransport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Virtual MIDI port '\(portName)' is unavailable"
            ])
        }
        packetSink(source, bytes)
    }

    func readiness() async -> KeyCmdTransportReadiness {
        if let port {
            return KeyCmdTransportReadiness(
                available: true,
                detail: "Virtual MIDI port '\(port.name)' is ready"
            )
        }
        if let startupError {
            return KeyCmdTransportReadiness(available: false, detail: startupError)
        }
        return KeyCmdTransportReadiness(
            available: false,
            detail: "Virtual MIDI port '\(portName)' has not been prepared"
        )
    }

    func stop() async {
        port = nil
        startupError = nil
    }
}
