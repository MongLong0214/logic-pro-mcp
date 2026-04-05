import Foundation

/// Protocol for MCU MIDI transport — abstracted for testing.
protocol MCUTransportProtocol: Actor {
    func send(_ bytes: [UInt8]) async
    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async
    func stop() async
}

/// MCU (Mackie Control Universal) channel for bidirectional Logic Pro control.
actor MCUChannel: Channel {
    nonisolated let id = ChannelID.mcu

    private let transport: any MCUTransportProtocol
    private let cache: StateCache
    private let feedbackParser: MCUFeedbackParser
    private(set) var currentBank: Int = 0
    private var bankingQueue: [CheckedContinuation<Void, Never>] = []
    private var isBanking: Bool = false

    // Note: verify-after-write was simplified to avoid actor deadlock.
    // Instead of blocking on feedback, we rely on MCUFeedbackParser updating
    // StateCache asynchronously. Callers check StateCache after a short delay if needed.

    init(transport: any MCUTransportProtocol, cache: StateCache) {
        self.transport = transport
        self.cache = cache
        self.feedbackParser = MCUFeedbackParser(cache: cache)
    }

    func start() async throws {
        // Pass bank offset getter to feedback parser
        await feedbackParser.setBankOffsetProvider { [weak self] in
            await self?.currentBank ?? 0
        }

        await transport.start { [weak self] event in
            guard let self else { return }
            Task { await self.receiveFeedback(event) }
        }

        // Handshake: send Device Query
        let query = MCUProtocol.encodeDeviceQuery()
        await transport.send(query)

        // Note: registeredAsDevice is updated by feedbackParser when MCU Device Response SysEx is received.
        // We don't block on response here to avoid actor deadlock.
        var conn = await cache.getMCUConnection()
        conn.isConnected = true
        conn.portName = "LogicProMCP-MCU-Internal"
        await cache.updateMCUConnection(conn)

        Log.info("MCU Channel started, handshake query sent", subsystem: "mcu")
    }

    func stop() async {
        await transport.stop()
        var conn = await cache.getMCUConnection()
        conn.isConnected = false
        await cache.updateMCUConnection(conn)
        Log.info("MCU Channel stopped", subsystem: "mcu")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        case "mixer.set_volume":
            return await executeSetVolume(params)
        case "mixer.set_pan":
            return await executeSetPan(params)
        case "mixer.set_send":
            return await executeSetSend(params)
        case "transport.play":
            return await sendTransport(.play)
        case "transport.stop":
            return await sendTransport(.stop)
        case "transport.record":
            return await sendTransport(.record)
        case "transport.rewind":
            return await sendTransport(.rewind)
        case "transport.fast_forward":
            return await sendTransport(.fastForward)
        case "transport.toggle_cycle":
            return await sendTransport(.cycle)
        case "track.set_mute":
            return await executeStripButton(.mute, params: params)
        case "track.set_solo":
            return await executeStripButton(.solo, params: params)
        case "track.set_arm":
            return await executeStripButton(.recArm, params: params)
        case "track.select":
            return await executeStripButton(.select, params: params)
        case "mixer.set_plugin_param":
            return await executePluginParam(params)
        case "track.set_automation":
            return await executeAutomation(params)
        default:
            return .error("Unknown MCU operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        let conn = await cache.getMCUConnection()
        if !conn.isConnected {
            return .unavailable("MCU not connected. Register in Logic Pro > Control Surfaces > Setup")
        }
        let age = conn.lastFeedbackAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let stale = age > 5.0
        let registered = conn.registeredAsDevice ? "registered" : "MIDI only (MCU not registered)"
        let detail = stale
            ? "MCU \(registered), feedback stale (\(Int(age))s)"
            : "MCU \(registered), feedback active"
        return .healthy(latencyMs: nil, detail: detail)
    }

    /// Handle incoming feedback event (called from tests or transport callback).
    func handleFeedback(_ event: MIDIFeedback.Event) async {
        await receiveFeedback(event)
    }

    // MARK: - Feedback Reception

    private func receiveFeedback(_ event: MIDIFeedback.Event) async {
        await feedbackParser.handle(event)
    }

    // MARK: - Send with optional verify delay

    /// Send bytes. For operations that need verification, caller checks StateCache after a short delay.
    /// This avoids actor deadlock from continuation-based verify-after-write.
    private func sendCommand(_ bytes: [UInt8]) async {
        await transport.send(bytes)
    }

    // MARK: - Command Implementations

    private func executeSetVolume(_ params: [String: String]) async -> ChannelResult {
        let track = Int(params["index"] ?? "0") ?? 0
        let value = Double(params["volume"] ?? "0") ?? 0.0

        return await withBanking(targetTrack: track) { strip in
            let bytes = MCUProtocol.encodeFader(track: strip, value: value)
            await self.sendCommand(bytes)
            return .success("Volume set to \(value) on track \(track)")
        }
    }

    private func executeSetPan(_ params: [String: String]) async -> ChannelResult {
        let track = Int(params["index"] ?? "0") ?? 0
        let value = Double(params["pan"] ?? "0") ?? 0.0

        return await withBanking(targetTrack: track) { strip in
            let speed: UInt8 = max(1, min(15, UInt8(abs(value) * 15)))
            let direction: MCUProtocol.VPotDirection = value >= 0 ? .clockwise : .counterClockwise
            let bytes = MCUProtocol.encodeVPot(strip: strip, direction: direction, speed: speed)
            await self.transport.send(bytes)
            return .success("Pan set to \(value) on track \(track)")
        }
    }

    private func executeSetSend(_ params: [String: String]) async -> ChannelResult {
        let bytes = MCUProtocol.encodeButton(.assignSend, on: true)
        await transport.send(bytes)
        return .success("Send mode entered")
    }

    private func sendTransport(_ command: MCUProtocol.TransportCommand) async -> ChannelResult {
        let bytes = MCUProtocol.encodeTransport(command)
        await transport.send(bytes)
        return .success("Transport: \(command)")
    }

    private func executeStripButton(_ function: MCUProtocol.ButtonFunction, params: [String: String]) async -> ChannelResult {
        let track = Int(params["index"] ?? "0") ?? 0
        let enabled = params["enabled"] == "true" || params["enabled"] == "1"

        return await withBanking(targetTrack: track) { strip in
            let bytes = MCUProtocol.encodeButton(function, strip: strip, on: enabled)
            await self.transport.send(bytes)
            return .success("\(function) \(enabled ? "on" : "off") for track \(track)")
        }
    }

    private func executePluginParam(_ params: [String: String]) async -> ChannelResult {
        let modeBytes = MCUProtocol.encodeButton(.assignPlugin, on: true)
        await transport.send(modeBytes)

        let param = Int(params["param"] ?? "0") ?? 0
        let value = Double(params["value"] ?? "0") ?? 0.0
        let strip = param % 8
        let speed: UInt8 = max(1, min(15, UInt8(value * 15)))
        let vpotBytes = MCUProtocol.encodeVPot(strip: strip, direction: .clockwise, speed: speed)
        await transport.send(vpotBytes)
        return .success("Plugin param \(param) set to \(value)")
    }

    private func executeAutomation(_ params: [String: String]) async -> ChannelResult {
        let mode = params["mode"] ?? "read"
        let function: MCUProtocol.ButtonFunction
        switch mode {
        case "read": function = .automationRead
        case "write": function = .automationWrite
        case "touch": function = .automationTouch
        case "latch": function = .automationLatch
        case "trim": function = .automationTrim
        default: return .error("Unknown automation mode: \(mode)")
        }
        let bytes = MCUProtocol.encodeButton(function, on: true)
        await transport.send(bytes)
        return .success("Automation mode: \(mode)")
    }

    // MARK: - Banking (Proper Queue)

    private func withBanking(targetTrack: Int, operation: @escaping (Int) async -> ChannelResult) async -> ChannelResult {
        let targetBank = targetTrack / 8
        let strip = targetTrack % 8

        if targetBank == currentBank {
            return await operation(strip)
        }

        // Wait if another banking operation is in progress (loop to handle spurious wakeups)
        while isBanking {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                bankingQueue.append(continuation)
            }
        }

        isBanking = true
        defer {
            isBanking = false
            if !bankingQueue.isEmpty {
                bankingQueue.removeFirst().resume()
            }
        }
        let originalBank = currentBank

        // Bank to target
        let bankDelta = targetBank - currentBank
        let bankButton: MCUProtocol.ButtonFunction = bankDelta > 0 ? .bankRight : .bankLeft
        for _ in 0..<abs(bankDelta) {
            await transport.send(MCUProtocol.encodeButton(bankButton, on: true))
            try? await Task.sleep(for: .milliseconds(1))
        }
        currentBank = targetBank

        // Execute on target bank
        let result = await operation(strip)

        // Restore original bank
        let restoreDelta = originalBank - currentBank
        let restoreButton: MCUProtocol.ButtonFunction = restoreDelta > 0 ? .bankRight : .bankLeft
        for _ in 0..<abs(restoreDelta) {
            await transport.send(MCUProtocol.encodeButton(restoreButton, on: true))
            try? await Task.sleep(for: .milliseconds(1))
        }
        currentBank = originalBank

        // defer handles: isBanking = false + queue wake
        return result
    }
}
