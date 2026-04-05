import CoreMIDI
import Foundation
import MCP

/// Main MCP server for Logic Pro integration.
/// Exposes 8 dispatcher tools + 7 resources, routing through
/// the ChannelRouter to the appropriate macOS communication channel.
actor LogicProServer {
    private let server: Server
    private let router: ChannelRouter
    private let cache: StateCache
    private let poller: StatePoller
    private let portManager: MIDIPortManager

    // Channel instances (7 channels — PRD §4.1)
    private let coreMIDIChannel: CoreMIDIChannel
    private let mcuChannel: MCUChannel
    private let keyCommandsChannel: MIDIKeyCommandsChannel
    private let scripterChannel: ScripterChannel
    private let axChannel: AccessibilityChannel
    private let cgEventChannel: CGEventChannel
    private let appleScriptChannel: AppleScriptChannel

    init() {
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

        // Legacy channels
        let midiEngine = MIDIEngine()
        self.coreMIDIChannel = CoreMIDIChannel(engine: midiEngine)
        self.axChannel = AccessibilityChannel()
        self.cgEventChannel = CGEventChannel()
        self.appleScriptChannel = AppleScriptChannel()

        // New v2 channels (MCU, KeyCommands, Scripter)
        // These use MockMCUTransport at init — replaced with real transport in start()
        // For production, we create a real CoreMIDI-backed transport in start()
        let mcuTransport = ProductionMCUTransport(portManager: portManager)
        self.mcuChannel = MCUChannel(transport: mcuTransport, cache: cache)

        let keyCmdTransport = ProductionKeyCmdTransport(portManager: portManager)
        self.keyCommandsChannel = MIDIKeyCommandsChannel(transport: keyCmdTransport)

        let scripterTransport = ProductionKeyCmdTransport(portManager: portManager, portName: "LogicProMCP-Scripter-Internal")
        self.scripterChannel = ScripterChannel(transport: scripterTransport)

        self.poller = StatePoller(axChannel: axChannel, cache: cache)
    }

    // MARK: - Tool Registration (8 dispatchers)

    private func registerTools() async {
        let allTools: [Tool] = [
            TransportDispatcher.tool,
            TrackDispatcher.tool,
            MixerDispatcher.tool,
            MIDIDispatcher.tool,
            EditDispatcher.tool,
            NavigateDispatcher.tool,
            ProjectDispatcher.tool,
            SystemDispatcher.tool,
        ]

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: allTools)
        }

        let router = self.router
        let cache = self.cache

        await server.withMethodHandler(CallTool.self) { params in
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
                return CallTool.Result(
                    content: [.text("Unknown tool: \(name)")],
                    isError: true
                )
            }
        }
    }

    // MARK: - Resource Registration (7 resources)

    private func registerResources() async {
        let router = self.router
        let cache = self.cache

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: ResourceProvider.resources, nextCursor: nil)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await ResourceHandlers.read(uri: params.uri, cache: cache, router: router)
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: ResourceProvider.templates)
        }
    }

    // MARK: - Server Lifecycle

    func start() async throws {
        // Start port manager
        try await portManager.start()

        // Register all 7 channels with router
        await router.register(mcuChannel)
        await router.register(keyCommandsChannel)
        await router.register(scripterChannel)
        await router.register(coreMIDIChannel)
        await router.register(axChannel)
        await router.register(cgEventChannel)
        await router.register(appleScriptChannel)

        // Start all channels
        await router.startAll()

        // Start the state poller
        await poller.start()

        // Register tool handlers and resources
        await registerTools()
        await registerResources()

        Log.info(
            "Starting \(ServerConfig.serverName) v\(ServerConfig.serverVersion) — 8 tools, 7 resources, 7 channels",
            subsystem: "server"
        )

        // Start MCP server with stdio transport
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()

        // Cleanup
        await poller.stop()
        await router.stopAll()
        await portManager.stop()
    }
}

// MARK: - Production Transports

/// Real MIDI transport for MCU channel using MIDIPortManager.
actor ProductionMCUTransport: MCUTransportProtocol {
    private let portManager: MIDIPortManager
    private var port: MIDIPortManager.MIDIPortPair?
    private var onReceive: (@Sendable (MIDIFeedback.Event) -> Void)?

    init(portManager: MIDIPortManager) {
        self.portManager = portManager
    }

    func send(_ bytes: [UInt8]) async {
        guard let source = port?.source else {
            Log.warn("MCU port not started — dropping \(bytes.count) bytes", subsystem: "mcu")
            return
        }
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

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async {
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
        }
    }

    func stop() async {
        port = nil
    }
}

/// Real MIDI transport for KeyCmd/Scripter channels — send-only.
actor ProductionKeyCmdTransport: KeyCmdTransportProtocol {
    private let portManager: MIDIPortManager
    private let portName: String
    private var port: MIDIPortManager.MIDIPortPair?

    init(portManager: MIDIPortManager, portName: String = "LogicProMCP-KeyCmd-Internal") {
        self.portManager = portManager
        self.portName = portName
    }

    func send(_ bytes: [UInt8]) async {
        // Lazy port creation
        if port == nil {
            do {
                port = try await portManager.createSendOnlyPort(name: portName)
            } catch {
                Log.warn("KeyCmd port creation failed: \(error)", subsystem: "keycmd")
                return
            }
        }
        guard let source = port?.source else { return }
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
}
