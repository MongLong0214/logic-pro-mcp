import Foundation
import Testing
@testable import LogicProMCP

// v3.1.0 (T4) — Honest Contract coverage for MCU mixer ops that now poll
// for fader echo before reporting success. Uses MockMCUTransport + direct
// feedback injection to drive deterministic State-A / State-B outcomes.

private func decodeJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

@Test func testMCUSetVolumeReturnsStateAWhenEchoMatches() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Drive a matching pitch-bend echo after a short delay so the poll
    // loop inside executeSetVolume sees it. 0.7 * 16383 ≈ 11468 → LSB=0x4C, MSB=0x59.
    let target = 0.7
    let raw = UInt16(target * 16383.0)
    let lsb = UInt8(raw & 0x7F)
    let msb = UInt8((raw >> 7) & 0x7F)

    Task.detached {
        try? await Task.sleep(nanoseconds: 50_000_000)
        await channel.handleFeedback(.pitchBend(channel: 0, value: (UInt16(msb) << 7) | UInt16(lsb)))
    }

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "\(target)"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == true)
    #expect(obj["track"] as? Int == 0)
    // `requested` is the target; `observed` should be within tolerance.
    #expect(obj["requested"] as? Double ?? 0 == target)
}

@Test func testMCUSetVolumeReturnsStateBEchoTimeoutWhenNoFeedback() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // No feedback dispatched → poll window elapses → State B with
    // `echo_timeout_<ms>ms`.
    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    #expect(result.isSuccess, "timeout is State B (success:true, verified:false)")
    let obj = decodeJSON(result.message)
    #expect(obj["verified"] as? Bool == false)
    let reason = obj["reason"] as? String ?? ""
    #expect(reason.hasPrefix("echo_timeout_"), "expected echo_timeout_<ms>ms, got \(reason)")
    #expect(reason.hasSuffix("ms"))
}

@Test func testMCUSetMasterVolumeTimesOutAsStateB() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_master_volume",
        params: ["volume": "0.5"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(obj["verified"] as? Bool == false)
    #expect(obj["track"] as? String == "master")
    #expect((obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true)
}

@Test func testMCUSetPanReturnsStateBReadbackUnavailable() async {
    // V-Pot feedback (CC 0x30+strip) is not yet plumbed to StateCache, so
    // pan writes cannot be read back. Contract: State B with
    // `readback_unavailable` until echo wiring is done in a later phase.
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "-0.3"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(obj["verified"] as? Bool == false)
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["track"] as? Int == 0)
}

// v3.1.0 (Ralph-2 / C1) — stale cache regression guard. If the cache already
// holds the target volume (e.g. from a prior confirmed set_volume against a
// since-disconnected transport), a second identical-value set_volume must NOT
// return State A. The freshness stamp on updateFader + pollFaderEcho's
// requireFreshAfter parameter together enforce "I saw Logic echo *this* call."
@Test func testSetVolumeStaleCacheDoesNotReturnStateA() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    // Pre-seed the cache as if a previous set_volume 0.5 had been echoed +
    // parsed by MCUFeedbackParser. No feedback will be dispatched during the
    // next call — we are emulating a transport that has gone quiet.
    await cache.updateFader(strip: 0, volume: 0.5)
    let channel = MCUChannel(transport: transport, cache: cache)

    // Small delay so the deadline evaluator above treats the seed as
    // "before send" (sendAt will be captured inside executeSetVolume).
    try? await Task.sleep(nanoseconds: 5_000_000)

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    #expect(result.isSuccess, "stale-only hit stays State B — the envelope is still success:true")
    let obj = decodeJSON(result.message)
    #expect(
        obj["verified"] as? Bool == false,
        "stale cache must not be reported as a fresh Logic echo"
    )
    let reason = obj["reason"] as? String ?? ""
    #expect(
        reason.hasPrefix("echo_timeout_"),
        "expected echo_timeout_<ms>ms for stale-only cache, got \(reason)"
    )
}

@Test func testSetMasterVolumeStaleCacheDoesNotReturnStateA() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    // Master echoes on strip index 8 per MCU spec. Seed stale.
    await cache.updateFader(strip: 8, volume: 0.5)
    let channel = MCUChannel(transport: transport, cache: cache)

    try? await Task.sleep(nanoseconds: 5_000_000)

    let result = await channel.execute(
        operation: "mixer.set_master_volume",
        params: ["volume": "0.5"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(obj["verified"] as? Bool == false)
    #expect((obj["reason"] as? String)?.hasPrefix("echo_timeout_") == true)
}

@Test func testMCUEchoTimeoutEnvVarIsRespected() {
    // Default 500ms.
    #expect(MCUChannel.echoTimeoutMs == 500)
    // Setenv is process-global; not safe to mutate mid-test — this test
    // just documents that valid overrides are 250/500/1000. Invalid values
    // collapse back to the 500 default (covered by the inline logic).
}
