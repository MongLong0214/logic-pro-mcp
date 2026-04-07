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
    #expect(conn.isConnected == true)
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
    #expect(conn.isConnected == false)
    #expect(conn.registeredAsDevice == false)

    let health = await channel.healthCheck()
    #expect(health.available == false)
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
    #expect(connAfterStop.isConnected == false)
    #expect(await transport.stopCount == 1)
}

@Test func testMCUChannelStartCallbackRoutesFeedbackAndHandshakeRegistration() async throws {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    try await channel.start()
    await transport.emit(.sysEx([0xF0, 0x00, 0x00, 0x66, 0x14, 0x01, 0x42, 0x00, 0x01, 0xF7]))

    let conn = await cache.getMCUConnection()
    #expect(conn.isConnected == true)
    #expect(conn.registeredAsDevice == true)
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
        MCUProtocol.encodeButton(.select, strip: 5, on: false),
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
    #expect(sent.isEmpty == false)
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
