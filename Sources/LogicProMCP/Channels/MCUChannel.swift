import Foundation

/// Protocol for MCU MIDI transport — abstracted for testing.
protocol MCUTransportProtocol: Actor {
    func send(_ bytes: [UInt8]) async
    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws
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

    // v3.1.0 (T4) — configurable echo-timeout for fader/V-Pot read-back.
    // MCU feedback timing varies by project load + Logic build; 500ms is
    // the empirical default. Override via `MCU_ECHO_TIMEOUT_MS` (250/500/1000).
    static var echoTimeoutMs: Int {
        if let s = ProcessInfo.processInfo.environment["MCU_ECHO_TIMEOUT_MS"],
           let n = Int(s), [250, 500, 1000].contains(n) {
            return n
        }
        return 500
    }

    // Note: verify-after-write was simplified to avoid actor deadlock.
    // Instead of blocking on feedback, we rely on MCUFeedbackParser updating
    // StateCache asynchronously. Callers check StateCache after a short delay if needed.

    init(transport: any MCUTransportProtocol, cache: StateCache) {
        self.transport = transport
        self.cache = cache
        self.feedbackParser = MCUFeedbackParser(cache: cache)
    }

    /// v3.1.0 (T4) — poll StateCache for a matching fader echo. The MCU
    /// feedback parser writes to `cache.channelStrips[strip].volume` as
    /// pitch-bend events arrive. We poll every 25ms and accept the value if
    /// it lands within `tolerance` of `target` before `timeoutMs` elapses.
    /// The 14-bit MCU resolution tolerance is 2/16383 (±2 LSB) as the default.
    ///
    /// v3.1.0 (Ralph-2 / C1) — `requireFreshAfter`, when non-nil, requires
    /// the echo's write-timestamp (`cache.getFaderUpdatedAt(strip:)`) to be
    /// strictly newer than that deadline. This prevents a stale cache value
    /// left over from a previous confirmed `set_volume 0.5` from
    /// false-positively acknowledging a later `set_volume 0.5` against a
    /// disconnected transport.
    ///
    /// Returns the observed volume if a matching, fresh echo arrived, or nil
    /// on timeout / stale-only.
    func pollFaderEcho(
        strip: Int,
        target: Double,
        timeoutMs: Int,
        tolerance: Double = 2.0 / 16383.0,
        requireFreshAfter: Date? = nil
    ) async -> Double? {
        let pollIntervalNs: UInt64 = 25_000_000
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let observed = await cache.getChannelStrip(at: strip)?.volume,
               abs(observed - target) <= tolerance {
                if let sendAt = requireFreshAfter {
                    // Fresh only if the parser wrote a post-send timestamp.
                    if let writtenAt = await cache.getFaderUpdatedAt(strip: strip),
                       writtenAt > sendAt {
                        return observed
                    }
                    // Value matches but it's stale — keep polling until
                    // either a new echo arrives or the deadline elapses.
                } else {
                    return observed
                }
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        // Deadline hit. Report the most-recent fresh observation (or nil if
        // nothing fresh arrived). When freshness isn't required, fall back
        // to the raw cached value for backward compat.
        if let sendAt = requireFreshAfter {
            if let writtenAt = await cache.getFaderUpdatedAt(strip: strip),
               writtenAt > sendAt {
                return await cache.getChannelStrip(at: strip)?.volume
            }
            return nil
        }
        return await cache.getChannelStrip(at: strip)?.volume
    }

    func start() async throws {
        // Pass bank offset getter to feedback parser
        await feedbackParser.setBankOffsetProvider { [weak self] in
            await self?.currentBank ?? 0
        }

        try await transport.start { [weak self] event in
            guard let self else { return }
            Task { await self.receiveFeedback(event) }
        }

        // Handshake: send Device Query
        let query = MCUProtocol.encodeDeviceQuery()
        await transport.send(query)

        var conn = await cache.getMCUConnection()
        conn.isConnected = false
        conn.registeredAsDevice = false
        conn.lastFeedbackAt = nil
        conn.portName = "LogicProMCP-MCU-Internal"
        await cache.updateMCUConnection(conn)

        Log.info("MCU Channel started, handshake query sent; waiting for feedback", subsystem: "mcu")
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
        case "mixer.set_master_volume":
            return await executeSetMasterVolume(params)
        case "mixer.set_send":
            return .error("MCU send targeting is not deterministic enough for the production MCP contract")
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
            return .error("Use plugin.set_param via the Scripter channel for deterministic plugin parameter control")
        case "track.set_automation":
            return await executeAutomation(params)
        default:
            return .error("Unknown MCU operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        let conn = await cache.getMCUConnection()
        if !conn.isConnected {
            let portName = conn.portName.isEmpty ? "LogicProMCP-MCU-Internal" : conn.portName
            return .unavailable(
                "MCU feedback not detected. Register '\(portName)' in Logic Pro > Control Surfaces > Setup"
            )
        }
        let age = conn.lastFeedbackAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let stale = age > 5.0
        let registered = conn.registeredAsDevice ? "device registration confirmed" : "MIDI feedback active, device registration not confirmed"
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
        let timeoutMs = Self.echoTimeoutMs

        return await withBanking(targetTrack: track) { strip in
            // v3.1.0 (Ralph-2 / C1) — stamp the send moment *before* the
            // write so pollFaderEcho can reject stale cache values that
            // pre-date this call. Without the stamp, an identical-value
            // re-send (set_volume 0.5 twice in a row) could return State A
            // on the stale echo from the first call even when the transport
            // is disconnected.
            let sendAt = Date()
            let bytes = MCUProtocol.encodeFader(track: strip, value: value)
            await self.sendCommand(bytes)
            // Poll the feedback parser's echo write into StateCache. Confirmed
            // fresh echo → State A. Timeout / stale-only → State B
            // `echo_timeout_<ms>ms`.
            let observed = await self.pollFaderEcho(
                strip: track, target: value, timeoutMs: timeoutMs,
                requireFreshAfter: sendAt
            )
            let extras: [String: Any] = [
                "requested": value,
                "observed": observed ?? NSNull(),
                "track": track
            ]
            if let observed, abs(observed - value) <= 2.0 / 16383.0 {
                return .success(HonestContract.encodeStateA(extras: extras))
            }
            return .success(HonestContract.encodeStateB(
                reason: .echoTimeout(ms: timeoutMs), extras: extras
            ))
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
            // v3.1.0 (T4) — V-Pot feedback is relative (CW/CCW nudges) and
            // Logic echoes position as a different event (CC 0x30+strip LED
            // ring, not pitch-bend). Until that parser is plumbed through
            // to StateCache, treat every pan write as `readback_unavailable`
            // so the contract stays honest.
            let extras: [String: Any] = [
                "requested": value,
                "observed": NSNull(),
                "track": track
            ]
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable, extras: extras
            ))
        }
    }

    private func executeSetMasterVolume(_ params: [String: String]) async -> ChannelResult {
        let value = Double(params["volume"] ?? "0") ?? 0.0
        let timeoutMs = Self.echoTimeoutMs
        // v3.1.0 (Ralph-2 / C1) — same send-time freshness check as per-strip
        // set_volume so a cached master value can't mascarade as a fresh
        // echo on a re-send with the same target.
        let sendAt = Date()
        let bytes = MCUProtocol.encodeFader(track: 8, value: value)
        await transport.send(bytes)
        // Master fader echoes on strip index 8 (channel 8 of the pitch-bend
        // stream, per MCU spec).
        let observed = await pollFaderEcho(
            strip: 8, target: value, timeoutMs: timeoutMs,
            requireFreshAfter: sendAt
        )
        let extras: [String: Any] = [
            "requested": value,
            "observed": observed ?? NSNull(),
            "track": "master"
        ]
        if let observed, abs(observed - value) <= 2.0 / 16383.0 {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success(HonestContract.encodeStateB(
            reason: .echoTimeout(ms: timeoutMs), extras: extras
        ))
    }

    private func sendTransport(_ command: MCUProtocol.TransportCommand) async -> ChannelResult {
        let bytes = MCUProtocol.encodeTransport(command)
        await transport.send(bytes)
        return .success("Transport: \(command)")
    }

    private func executeStripButton(_ function: MCUProtocol.ButtonFunction, params: [String: String]) async -> ChannelResult {
        let track = Int(params["index"] ?? "0") ?? 0
        // `track.select` is not a toggle — callers always mean "make this track
        // the selected one." Forcing on=true avoids the previous bug where an
        // absent `enabled` param silently deselected (→ Drummer stayed focused).
        let enabled: Bool
        if function == .select {
            enabled = true
        } else {
            enabled = params["enabled"] == "true" || params["enabled"] == "1"
        }

        return await withBanking(targetTrack: track) { strip in
            let bytes = MCUProtocol.encodeButton(function, strip: strip, on: enabled)
            await self.transport.send(bytes)
            return .success("\(function) \(enabled ? "on" : "off") for track \(track)")
        }
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
        // Sanity cap: real Logic projects rarely exceed 256 tracks (32 MCU banks).
        // A `track.select {index: 99999}` was seen to spend 25 s walking 12499
        // bank-right presses then restoring — far past any client timeout. Reject
        // up front rather than burning that time.
        guard (0...255).contains(targetTrack) else {
            return .error("MCU bank target track \(targetTrack) out of range (0..255)")
        }
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
