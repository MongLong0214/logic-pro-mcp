import Foundation
import Testing
@testable import LogicProMCP

// MCUChannel tests use MockMCUTransport to avoid CoreMIDI dependency.

@Test func testMCUChannelExecuteSetVolume() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.7"]
    )
    #expect(result.isSuccess)

    // Verify PitchBend was sent
    let sent = await transport.sentBytes
    #expect(!sent.isEmpty)
    #expect(sent[0][0] == 0xE0) // PitchBend ch0
}

@Test func testMCUBankingAtomic() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Track 12 → needs banking (bank 1, strip 4)
    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "12", "volume": "0.5"]
    )
    #expect(result.isSuccess)

    // Verify banking sequence: bankRight → fader → bankLeft (restore)
    let sent = await transport.sentBytes
    #expect(sent.count >= 3) // bank + fader + restore
}

@Test func testMCUBankingQueueDuringBank() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Fire two commands that need different banks concurrently
    async let r1 = channel.execute(operation: "mixer.set_volume", params: ["index": "12", "volume": "0.5"])
    async let r2 = channel.execute(operation: "mixer.set_volume", params: ["index": "0", "volume": "0.8"])

    let result1 = await r1
    let result2 = await r2
    #expect(result1.isSuccess)
    #expect(result2.isSuccess)
}

@Test func testMCUConnectionStateTracking() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Simulate feedback
    await channel.handleFeedback(.noteOn(channel: 0, note: 0x5E, velocity: 0x7F))

    let conn = await cache.getMCUConnection()
    #expect(conn.isConnected)
}

@Test func testMCUChannelHealthCheck() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let health = await channel.healthCheck()
    // Without start(), should report basic status
    #expect(health.detail.count > 0)
}

@Test func testMCUStartRequiresFeedbackBeforeHealthy() async throws {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    try await channel.start()

    let conn = await cache.getMCUConnection()
    #expect(!(conn.isConnected))
    #expect(!(conn.registeredAsDevice))

    let health = await channel.healthCheck()
    #expect(!(health.available))
    #expect(health.detail.contains("feedback not detected"))
}

@Test func testMCUChannelStartSendsHandshakeAndStopClearsConnection() async throws {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    try await channel.start()

    let sentBeforeStop = await transport.sentBytes
    let connAfterStart = await cache.getMCUConnection()
    #expect(sentBeforeStop == [MCUProtocol.encodeDeviceQuery()])
    #expect(connAfterStart.portName == "LogicProMCP-MCU-Internal")
    #expect(await transport.startCount == 1)

    await channel.stop()

    let connAfterStop = await cache.getMCUConnection()
    #expect(!(connAfterStop.isConnected))
    #expect(await transport.stopCount == 1)
}

@Test func testMCUChannelStartCallbackRoutesFeedbackAndHandshakeRegistration() async throws {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    try await channel.start()
    await transport.emit(.sysEx([0xF0, 0x00, 0x00, 0x66, 0x14, 0x01, 0x42, 0x00, 0x01, 0xF7]))

    // WS6: feedback is applied by the ordered consumer Task, so the cache update
    // lands after `emit` returns. Poll until the registration is observed rather
    // than reading before the drain runs (the prior `== true` was a dead
    // assertion that hid this ordering gap).
    var conn = await cache.getMCUConnection()
    for _ in 0..<100 where !conn.isConnected {
        try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        conn = await cache.getMCUConnection()
    }
    #expect(conn.isConnected)
    #expect(conn.registeredAsDevice)
}

@Test func testMCUChannelTransportCommandsEmitExpectedBytes() async {
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: StateCache())

    let cases: [(String, [UInt8])] = [
        ("transport.play", MCUProtocol.encodeTransport(.play)),
        ("transport.stop", MCUProtocol.encodeTransport(.stop)),
        ("transport.record", MCUProtocol.encodeTransport(.record)),
        ("transport.rewind", MCUProtocol.encodeTransport(.rewind)),
        ("transport.fast_forward", MCUProtocol.encodeTransport(.fastForward)),
        ("transport.toggle_cycle", MCUProtocol.encodeTransport(.cycle)),
    ]

    for (operation, expected) in cases {
        let result = await channel.execute(operation: operation, params: [:])
        #expect(result.isSuccess)
        let sent = await transport.sentBytes
        #expect(sent.last == expected)
    }

    let sent = await transport.sentBytes
    #expect(sent == cases.map { $0.1 })
}

@Test func testMCUChannelPanMasterAndStripButtonCommands() async {
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: StateCache())

    let panClockwise = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "1", "pan": "0.5"]
    )
    let panCounterClockwise = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "2", "pan": "-0.4"]
    )
    let master = await channel.execute(
        operation: "mixer.set_master_volume",
        params: ["volume": "0.75"]
    )
    let solo = await channel.execute(
        operation: "track.set_solo",
        params: ["index": "3", "enabled": "1"]
    )
    let arm = await channel.execute(
        operation: "track.set_arm",
        params: ["index": "4", "enabled": "true"]
    )
    // track.select ignores the enabled flag by design — it's not a toggle,
    // so the channel always emits on: true (making the track selected).
    // The explicit "enabled:false" here verifies the override is applied.
    let select = await channel.execute(
        operation: "track.select",
        params: ["index": "5", "enabled": "false"]
    )

    #expect(panClockwise.isSuccess)
    #expect(panCounterClockwise.isSuccess)
    #expect(master.isSuccess)
    #expect(solo.isSuccess)
    #expect(arm.isSuccess)
    #expect(select.isSuccess)

    let sent = await transport.sentBytes
    #expect(sent == [
        MCUProtocol.encodeVPot(strip: 1, direction: .clockwise, speed: 7),
        MCUProtocol.encodeVPot(strip: 2, direction: .counterClockwise, speed: 6),
        MCUProtocol.encodeFader(track: 8, value: 0.75),
        MCUProtocol.encodeButton(.solo, strip: 3, on: true),
        MCUProtocol.encodeButton(.recArm, strip: 4, on: true),
        MCUProtocol.encodeButton(.select, strip: 5, on: true),
    ])
}

@Test func testMCUChannelPluginParamAndAutomationModes() async {
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: StateCache())

    let pluginResult = await channel.execute(
        operation: "mixer.set_plugin_param",
        params: ["param": "9", "value": "0.8"]
    )
    #expect(!pluginResult.isSuccess)

    let automationModes: [(String, MCUProtocol.ButtonFunction)] = [
        ("read", .automationRead),
        ("write", .automationWrite),
        ("touch", .automationTouch),
        ("latch", .automationLatch),
        ("trim", .automationTrim),
    ]

    for (mode, function) in automationModes {
        let result = await channel.execute(
            operation: "track.set_automation",
            params: ["mode": mode]
        )
        #expect(result.isSuccess)
        let sent = await transport.sentBytes
        #expect(sent.last == MCUProtocol.encodeButton(function, on: true))
    }

    let invalidAutomation = await channel.execute(
        operation: "track.set_automation",
        params: ["mode": "preview"]
    )
    #expect(!invalidAutomation.isSuccess)
    #expect(invalidAutomation.message.contains("Unknown automation mode"))

    let sent = await transport.sentBytes
    #expect(!(sent.isEmpty))
}

@Test func testMCUChannelHealthReflectsHealthyAndStaleFeedbackModes() async {
    let cache = StateCache()
    let channel = MCUChannel(transport: MockMCUTransport(), cache: cache)

    var connected = await cache.getMCUConnection()
    connected.isConnected = true
    connected.registeredAsDevice = true
    connected.lastFeedbackAt = Date(timeIntervalSinceNow: -6)
    await cache.updateMCUConnection(connected)

    let staleHealth = await channel.healthCheck()
    #expect(staleHealth.available)
    #expect(staleHealth.detail.contains("stale"))
    #expect(staleHealth.detail.contains("device registration confirmed"))

    connected.registeredAsDevice = false
    connected.lastFeedbackAt = Date()
    await cache.updateMCUConnection(connected)

    let activeHealth = await channel.healthCheck()
    #expect(activeHealth.available)
    #expect(activeHealth.detail.contains("feedback active"))
    #expect(activeHealth.detail.contains("device registration not confirmed"))
}

@Test func testMCUChannelUnknownOperationFails() async {
    let result = await MCUChannel(transport: MockMCUTransport(), cache: StateCache()).execute(
        operation: "mixer.flip_channel_strip",
        params: [:]
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("Unknown MCU operation"))
}

// MARK: - v3.1.2 P0-1 — Honest Contract envelope on remaining MCU surfaces.
// Pre-v3.1.2 these returned free-form `"select on for track 56"` /
// `"Transport: play"` / `"Automation mode: read"` strings; agents had to
// regex-parse to know whether the press landed. Now every MCU mutating op
// returns the same 3-state contract every other channel honors, with
// `readback_unavailable` because the MCU button surface is LED-only and the
// echo isn't yet plumbed to StateCache.

private func decodeMCUJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

@Test func testMCUChannelRejectsMissingOrInvalidDirectMutationParams() async {
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: StateCache())
    let cases: [(operation: String, params: [String: String], hintFragment: String)] = [
        ("mixer.set_volume", ["volume": "0.5"], "'index'"),
        ("mixer.set_volume", ["index": "0"], "'volume'"),
        ("mixer.set_volume", ["index": "0", "volume": "1.5"], "between 0.0 and 1.0"),
        ("mixer.set_pan", ["index": "0", "pan": "2"], "between -1.0 and 1.0"),
        ("mixer.set_master_volume", [:], "'volume'"),
        ("track.set_solo", ["index": "3"], "'enabled'"),
        ("track.set_arm", ["enabled": "true"], "'index'"),
        ("track.set_mute", ["index": "3", "enabled": "yes"], "'enabled'"),
        ("track.select", [:], "'index'"),
        ("track.set_automation", [:], "'mode'"),
        ("track.set_automation", ["mode": "preview"], "Unknown automation mode"),
    ]

    for item in cases {
        let result = await channel.execute(operation: item.operation, params: item.params)
        #expect(!result.isSuccess, "\(item.operation) should reject invalid params")
        let obj = decodeMCUJSON(result.message)
        #expect(!((obj["success"] as? Bool)!))
        #expect(obj["error"] as? String == "invalid_params")
        #expect(obj["operation"] as? String == item.operation)
        #expect(obj["channel"] as? String == "MCU")
        #expect(((obj["hint"] as? String)?.contains(item.hintFragment))!)
    }

    let sent = await transport.sentBytes
    #expect(sent.isEmpty)
}

@Test func testStripButtonReturnsHonestContractEnvelope() async {
    let channel = MCUChannel(transport: MockMCUTransport(), cache: StateCache())

    let result = await channel.execute(
        operation: "track.select",
        params: ["index": "56"]
    )
    #expect(result.isSuccess)
    let obj = decodeMCUJSON(result.message)
    #expect((obj["success"] as? Bool)!, "envelope must carry success:true")
    #expect(!((obj["verified"] as? Bool)!), "MCU button echo is LED-only — never State A")
    #expect(
        obj["reason"] as? String == "readback_unavailable",
        "MCU button surface has no read-back — must use readback_unavailable"
    )
    #expect(obj["track"] as? Int == 56)
    #expect(obj["function"] as? String == "select")
    // track.select forces enabled:true regardless of the inbound flag (it's
    // not a toggle); the envelope mirrors that decision so callers can audit.
    #expect((obj["enabled"] as? Bool)!)

    // Mute / Solo / Arm honor the inbound enabled flag.
    let mute = await channel.execute(
        operation: "track.set_mute",
        params: ["index": "3", "enabled": "false"]
    )
    let muteObj = decodeMCUJSON(mute.message)
    #expect(muteObj["function"] as? String == "mute")
    #expect(!((muteObj["enabled"] as? Bool)!))
    #expect(muteObj["reason"] as? String == "readback_unavailable")
}

@Test func testSendTransportReturnsHonestContractEnvelope() async {
    let channel = MCUChannel(transport: MockMCUTransport(), cache: StateCache())

    for op in [
        "transport.play", "transport.stop", "transport.record",
        "transport.rewind", "transport.fast_forward", "transport.toggle_cycle"
    ] {
        let result = await channel.execute(operation: op, params: [:])
        #expect(result.isSuccess, "\(op) should produce State B envelope")
        let obj = decodeMCUJSON(result.message)
        #expect((obj["success"] as? Bool)!, "\(op): envelope success:true")
        #expect(!((obj["verified"] as? Bool)!), "\(op): MCU transport buttons are press-only")
        #expect(
            obj["reason"] as? String == "readback_unavailable",
            "\(op): expected readback_unavailable, got \(obj["reason"] ?? "nil")"
        )
        #expect(obj["function"] as? String == "transport")
        #expect(!(((obj["command"] as? String)?.isEmpty)!))
    }
}

@Test func testSetAutomationReturnsHonestContractEnvelope() async {
    let channel = MCUChannel(transport: MockMCUTransport(), cache: StateCache())

    let result = await channel.execute(
        operation: "track.set_automation",
        params: ["mode": "write"]
    )
    #expect(result.isSuccess)
    let obj = decodeMCUJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["mode"] as? String == "write")
    #expect(obj["function"] as? String == "set_automation")
}

// MARK: - Mock Transport

actor MockMCUTransport: MCUTransportProtocol {
    var sentBytes: [[UInt8]] = []
    var startCount = 0
    var stopCount = 0
    private var onReceive: (@Sendable (MIDIFeedback.Event) -> Void)?

    func send(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {
        startCount += 1
        self.onReceive = onReceive
    }

    func stop() {
        stopCount += 1
        sentBytes.removeAll()
    }

    func emit(_ event: MIDIFeedback.Event) {
        onReceive?(event)
    }
}
