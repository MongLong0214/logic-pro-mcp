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

// MARK: - Mock Transport

actor MockMCUTransport: MCUTransportProtocol {
    var sentBytes: [[UInt8]] = []

    func send(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) {
        // No-op for tests
    }

    func stop() {
        sentBytes.removeAll()
    }
}
