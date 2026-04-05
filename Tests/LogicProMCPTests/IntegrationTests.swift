import Testing
import Foundation
@testable import LogicProMCP

// MARK: - MCU Loopback

@Test func testMCULoopbackFaderRoundTrip() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)
    await cache.updateChannelStrips((0..<8).map { ChannelStripState(trackIndex: $0) })

    // Send set_volume → verify bytes sent
    let result = await channel.execute(operation: "mixer.set_volume", params: ["index": "2", "volume": "0.75"])
    #expect(result.isSuccess)

    let sent = await transport.sentBytes
    #expect(!sent.isEmpty)
    #expect(sent[0][0] == 0xE2) // PitchBend ch2

    // Simulate feedback from Logic Pro
    let feedbackValue: UInt16 = UInt16(0.75 * 16383)
    await channel.handleFeedback(.pitchBend(channel: 2, value: feedbackValue))

    let strips = await cache.getChannelStrips()
    #expect(abs(strips[2].volume - 0.75) < 0.01)
}

@Test func testMCULoopbackButtonRoundTrip() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)
    await cache.updateTracks((0..<8).map { TrackState(id: $0, name: "Track \($0)", type: .audio) })

    let result = await channel.execute(operation: "track.set_mute", params: ["index": "3", "enabled": "true"])
    #expect(result.isSuccess)

    // Simulate mute feedback
    await channel.handleFeedback(.noteOn(channel: 0, note: 0x13, velocity: 0x7F))

    let tracks = await cache.getTracks()
    #expect(tracks[3].isMuted == true)
}

// MARK: - Router End-to-End

@Test func testRouterToChannelEndToEnd() async {
    let router = ChannelRouter()
    let mcu = MockChannel(id: .mcu) // Always available mock
    await router.register(mcu)

    let result = await router.route(operation: "transport.play")
    #expect(result.isSuccess)

    let ops = await mcu.executedOps
    #expect(ops.count == 1)
    #expect(ops[0].0 == "transport.play")
}

// MARK: - Edge Cases

@Test func testLogicProNotRunningGraceful() async {
    // All channels should handle unavailability gracefully
    let router = ChannelRouter()
    let result = await router.route(operation: "mixer.set_volume", params: ["index": "0", "volume": "0.5"])
    // No channels registered → error but no crash
    #expect(!result.isSuccess)
    #expect(result.message.contains("exhausted") || result.message.contains("Unknown"))
}

@Test func testKeyCommandFallbackToCGEvent() async {
    let router = ChannelRouter()
    let keyCmd = MockChannel(id: .midiKeyCommands, available: false)
    let cgEvent = MockChannel(id: .cgEvent)
    await router.register(keyCmd)
    await router.register(cgEvent)

    let result = await router.route(operation: "edit.undo")
    #expect(result.isSuccess)

    let cgOps = await cgEvent.executedOps
    #expect(cgOps.count == 1)
}

@Test func testConcurrentMCUCommands() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Fire 10 concurrent commands
    await withTaskGroup(of: ChannelResult.self) { group in
        for i in 0..<10 {
            group.addTask {
                await channel.execute(
                    operation: "mixer.set_volume",
                    params: ["index": String(i % 8), "volume": "0.\(i)"]
                )
            }
        }
        var results: [ChannelResult] = []
        for await result in group {
            results.append(result)
        }
        #expect(results.count == 10)
        for r in results { #expect(r.isSuccess) }
    }
}

@Test func testDuplicatePortName() async {
    let manager = MIDIPortManager()
    // getPort on non-existent should return nil
    let port = await manager.getPort(name: "test-port")
    #expect(port == nil)
}

@Test func testLogicProCrashDetection() async {
    // Simulate: MCU was connected, then feedback stops
    let cache = StateCache()
    var conn = MCUConnectionState()
    conn.isConnected = true
    conn.lastFeedbackAt = Date().addingTimeInterval(-10) // 10s ago
    await cache.updateMCUConnection(conn)

    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: cache)
    let health = await channel.healthCheck()
    #expect(health.detail.contains("stale"))
}

@Test func testDegradedModeNoAXPermission() async {
    // When AX channel is unavailable, MCU + KeyCmd should still work
    let router = ChannelRouter()
    let ax = MockChannel(id: .accessibility, available: false)
    let mcu = MockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(ax)
    await router.register(mcu)
    await router.register(keyCmd)

    // Mixer (MCU) should work
    let mixResult = await router.route(operation: "mixer.set_volume")
    #expect(mixResult.isSuccess)

    // Edit (KeyCmd) should work
    let editResult = await router.route(operation: "edit.undo")
    #expect(editResult.isSuccess)
}

@Test func testDegradedModeNoAutomationPermission() async {
    let router = ChannelRouter()
    let as_ = MockChannel(id: .appleScript, available: false)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(as_)
    await router.register(keyCmd)

    // project.save should fallback to KeyCmd
    let result = await router.route(operation: "project.save")
    #expect(result.isSuccess)
}
