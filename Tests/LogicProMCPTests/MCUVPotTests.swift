import Foundation
import Testing
@testable import LogicProMCP

// v3.1.3 (#1) — V-Pot LED-ring decoder + StateCache.panUpdatedAt + MCUChannel.pollPanEcho.
// Promotes `mixer.set_pan` from State B `readback_unavailable` to State A
// `verified:true` (echo matches) or State B `echo_timeout_<ms>ms` (no echo).

private func decodeJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

// MARK: - Pure decoder / encoder round-trip

@Test func testVPotEncodeDecodeRoundtrip() {
    // Centre LED → position 6 → pan 0.0
    let centre = MCUProtocol.decodeVPotLEDRing(cc: 0x30, value: 0x06)
    #expect(centre?.position == 6)
    #expect(centre?.strip == 0)
    #expect(MCUProtocol.vpotPositionToPan(6) == 0.0)

    // Hard left → position 0 → pan -1.0
    let left = MCUProtocol.decodeVPotLEDRing(cc: 0x31, value: 0x00)
    #expect(left?.position == 0)
    #expect(left?.strip == 1)
    #expect(MCUProtocol.vpotPositionToPan(0) == -1.0)

    // Hard right → position 11 → pan +1.0
    let right = MCUProtocol.decodeVPotLEDRing(cc: 0x37, value: 0x0B)
    #expect(right?.position == 11)
    #expect(right?.strip == 7)
    #expect(MCUProtocol.vpotPositionToPan(11) == 1.0)

    // Centre indicator bit (0x40) is preserved without affecting position.
    let withCenter = MCUProtocol.decodeVPotLEDRing(cc: 0x30, value: 0x46)
    #expect(withCenter?.position == 6)
    #expect((withCenter?.center)!)

    // Mode bits (0x10..0x30) are decoded for diagnostic completeness.
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x30, value: 0x06)?.mode == .singleDot)
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x30, value: 0x16)?.mode == .boostCut)
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x30, value: 0x26)?.mode == .wrap)
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x30, value: 0x36)?.mode == .spread)

    // Out-of-range CCs return nil so the parser doesn't false-route timecode
    // (CC 0x40+) through the V-Pot decoder.
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x2F, value: 0x06) == nil)
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x38, value: 0x06) == nil)
    #expect(MCUProtocol.decodeVPotLEDRing(cc: 0x40, value: 0x06) == nil)

    // panToVPotPosition is the inverse mapping used by tests / round-trip.
    #expect(MCUProtocol.panToVPotPosition(0.0) == 6)
    #expect(MCUProtocol.panToVPotPosition(-1.0) == 0)
    #expect(MCUProtocol.panToVPotPosition(1.0) == 11)
    // Round-trip on each discrete LED position.
    for pos in 0...11 {
        let pan = MCUProtocol.vpotPositionToPan(pos)
        #expect(MCUProtocol.panToVPotPosition(pan) == pos,
                "round-trip mismatch at position \(pos): pan=\(pan), back=\(MCUProtocol.panToVPotPosition(pan))")
    }
}

// MARK: - MCUFeedbackParser writes pan into cache

@Test func testFeedbackParserUpdatesPanFromVPotLEDRing() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateChannelStrips((0..<8).map { ChannelStripState(trackIndex: $0) })

    // CC 0x32 (strip 2), value 0x0B (position 11 → pan +1.0).
    let event = MIDIFeedback.Event.controlChange(channel: 0, controller: 0x32, value: 0x0B)
    await parser.handle(event)

    let strips = await cache.getChannelStrips()
    #expect(abs(strips[2].pan - 1.0) < 0.0001, "expected pan=1.0 on strip 2, got \(strips[2].pan)")
    let stamp = await cache.getPanUpdatedAt(strip: 2)
    #expect(stamp != nil, "panUpdatedAt must be stamped after a V-Pot LED-ring echo")
}

// MARK: - pollPanEcho

@Test func testPollPanEchoMatchesValue() async {
    let cache = StateCache()
    let channel = MCUChannel(transport: MockMCUTransport(), cache: cache)

    // Capture sendAt BEFORE the echo write so the freshness stamp is
    // unambiguously after sendAt. Then yield a clock tick so updatePan's
    // internal Date() lands strictly later (millisecond clock can otherwise
    // produce equal timestamps under heavy parallel load — that's the
    // flake we observed in --parallel runs).
    let sendAt = Date()
    try? await Task.sleep(nanoseconds: 10_000_000)
    // Seed the echo deterministically — no Task.detached race with the
    // poll loop. pollPanEcho's first iteration must observe the cache
    // hit + freshness stamp > sendAt and return immediately.
    await cache.updatePan(strip: 1, value: 0.5)

    let observed = await channel.pollPanEcho(
        strip: 1, target: 0.5, timeoutMs: 500, requireFreshAfter: sendAt
    )
    #expect(observed != nil, "fresh matching echo must return a non-nil pan")
    #expect(abs((observed ?? -99) - 0.5) <= 0.1)
}

@Test func testPollPanEchoTimeoutReturnsNilWhenNoFreshEcho() async {
    let cache = StateCache()
    let channel = MCUChannel(transport: MockMCUTransport(), cache: cache)

    // No echo dispatched. With requireFreshAfter set, deadline elapses → nil.
    let observed = await channel.pollPanEcho(
        strip: 0, target: 0.5, timeoutMs: 100, requireFreshAfter: Date()
    )
    #expect(observed == nil, "no fresh echo + freshness required → nil")
}

@Test func testPanUpdatedAtFreshnessRejectsStaleCache() async {
    let cache = StateCache()
    let channel = MCUChannel(transport: MockMCUTransport(), cache: cache)

    // Pre-seed a stale pan as if a previous confirmed set_pan had echoed.
    await cache.updatePan(strip: 0, value: 0.5)
    try? await Task.sleep(nanoseconds: 5_000_000)
    let sendAt = Date()

    // No new echo arrives. requireFreshAfter must reject the stale cache hit.
    let observed = await channel.pollPanEcho(
        strip: 0, target: 0.5, timeoutMs: 100, requireFreshAfter: sendAt
    )
    #expect(observed == nil, "stale cache value must not be reported as a fresh echo")
}

// MARK: - executeSetPan end-to-end (State A / State B routing)

@Test func testMixerSetPanReturnsStateAOnEcho() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Target pan 0.5 → LED ring position 8 → CC 0x30 (strip 0), value 0x08.
    // Deliver the echo repeatedly at high priority until execute returns: the
    // V-Pot echo must be fresh (after the internal sendAt stamp), so a single
    // timed delivery is starvable under parallel load and can miss the poll
    // window → false State B. Repeated high-priority delivery guarantees a
    // fresh echo lands inside the window regardless of scheduler pressure.
    let echoTask = Task.detached(priority: .high) {
        while !Task.isCancelled {
            await channel.handleFeedback(.controlChange(channel: 0, controller: 0x30, value: 0x08))
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
    defer { echoTask.cancel() }

    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "0.4"]
    )
    echoTask.cancel()
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    // Position 8 → pan 0.4 (= (8-6)/5). Within ±0.1 of requested 0.4 → State A.
    #expect((obj["verified"] as? Bool)!,
            "matching V-Pot LED-ring echo must promote State B → State A; got \(obj)")
    #expect(obj["track"] as? Int == 0)
    #expect(obj["requested"] as? Double == 0.4)
}

@Test func testMixerSetPanReturnsStateBEchoTimeoutWhenNoFeedback() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // No feedback → poll window elapses → State B with echo_timeout_<ms>ms,
    // NOT readback_unavailable (which was the pre-v3.1.3 behaviour).
    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "-0.3"]
    )
    #expect(result.isSuccess, "timeout is State B (success:true, verified:false)")
    let obj = decodeJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    let reason = obj["reason"] as? String ?? ""
    #expect(reason.hasPrefix("echo_timeout_"),
            "expected echo_timeout_<ms>ms after V-Pot wiring, got \(reason)")
    #expect(reason.hasSuffix("ms"))
    #expect(obj["track"] as? Int == 0)
}

@Test func testMixerSetPanStaleCacheDoesNotReturnStateA() async {
    // Same Ralph-2 / C1 anti-stale guard as set_volume: a previously-cached
    // pan value (e.g. from an earlier confirmed set_pan against a since-
    // disconnected transport) must NOT cause a later identical-target call
    // to flip to State A. The send-time freshness stamp on updatePan +
    // pollPanEcho's requireFreshAfter together enforce "I saw Logic echo
    // *this* call."
    let transport = MockMCUTransport()
    let cache = StateCache()
    await cache.updatePan(strip: 0, value: 0.5)
    let channel = MCUChannel(transport: transport, cache: cache)

    try? await Task.sleep(nanoseconds: 5_000_000)

    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "0.5"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!),
            "stale pan cache must not be reported as a fresh Logic echo")
    let reason = obj["reason"] as? String ?? ""
    #expect(reason.hasPrefix("echo_timeout_"),
            "expected echo_timeout_<ms>ms for stale-only pan cache, got \(reason)")
}
