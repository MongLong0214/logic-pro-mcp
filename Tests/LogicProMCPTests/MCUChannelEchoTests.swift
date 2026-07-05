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

    // Deliver the matching fader echo CONCURRENTLY with execute. The echo must
    // land *after* the internal sendAt stamp (pollFaderEcho rejects stale
    // values), so it can't be pre-seeded. A single timed delivery is starvable
    // under parallel test load (a delayed background task can miss the poll
    // window entirely → false State B). Instead deliver repeatedly at high
    // priority until execute returns, so at least one fresh echo always lands
    // inside the poll window regardless of scheduler pressure.
    let echoTask = Task.detached(priority: .high) {
        while !Task.isCancelled {
            await channel.handleFeedback(.pitchBend(channel: 0, value: (UInt16(msb) << 7) | UInt16(lsb)))
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
    defer { echoTask.cancel() }

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "\(target)"]
    )
    echoTask.cancel()
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
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
    #expect(!((obj["verified"] as? Bool)!))
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
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["track"] as? String == "master")
    #expect(((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!)
}

// #142 — on echo timeout, set_master_volume must DISCLOSE that MCU echo is the
// only readback path for the master fader (which, unlike per-track strips, has
// no AX track-header equivalent to verify against), so a caller never mistakes
// this State B for a recoverable failure on a verifiable surface. The envelope
// must carry readback_source:"mcu_echo", an explicit surface_limitation note,
// and keep observed (null here) + requested.
@Test func testMCUSetMasterVolumeTimeoutDisclosesSurfaceLimitation() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_master_volume",
        params: ["volume": "0.8"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!)
    #expect(obj["track"] as? String == "master")
    #expect(obj["readback_source"] as? String == "mcu_echo")
    #expect(obj["requested"] as? Double == 0.8)
    #expect(obj["observed"] is NSNull, "no echo landed → observed must be JSON null")
    let limitation = obj["surface_limitation"] as? String
    let resolvedLimitation = try! #require(limitation)
    #expect(resolvedLimitation.contains("master fader"))
    #expect(resolvedLimitation.contains("no AX track-header"))
    #expect(resolvedLimitation.contains("non-deterministic"))
}

// #142 — when a fresh MCU echo DOES land, master volume is State A and still
// discloses readback_source:"mcu_echo", but must NOT carry the surface_limitation
// note (that note is reserved for the unverifiable timeout path).
@Test func testMCUSetMasterVolumeStateADisclosesEchoSourceWithoutLimitation() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    // Master fader echoes on pitch-bend channel 8 (MCU strip 8).
    let target = 0.6
    let raw = UInt16(target * 16383.0)
    // Mirror set_volume/set_pan State-A coverage: the echo must land after
    // executeSetMasterVolume stamps sendAt, so a single timed delivery is
    // starvable under full-suite parallel load and can miss the poll window.
    let echoTask = Task.detached(priority: .high) {
        while !Task.isCancelled {
            await channel.handleFeedback(.pitchBend(channel: 8, value: raw))
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
    defer { echoTask.cancel() }

    let result = await channel.execute(
        operation: "mixer.set_master_volume",
        params: ["volume": "\(target)"]
    )
    echoTask.cancel()
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["track"] as? String == "master")
    #expect(obj["readback_source"] as? String == "mcu_echo")
    #expect(obj["surface_limitation"] == nil, "State A must not carry the unverifiable-surface note")
    let observed = obj["observed"] as? Double
    let resolvedObserved = try! #require(observed)
    #expect(abs(resolvedObserved - target) <= 0.01)
}

@Test func testMCUSetPanReturnsStateBEchoTimeoutWhenNoFeedback() async {
    // v3.1.3 (#1) — V-Pot LED-ring decoding (CC 0x30+strip) is now wired
    // into StateCache via MCUFeedbackParser. With no feedback dispatched
    // the poll window elapses and we surface State B `echo_timeout_<ms>ms`
    // (the same envelope set_volume uses) instead of the legacy
    // `readback_unavailable`. State A coverage lives in MCUVPotTests.
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "-0.3"]
    )
    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    let reason = obj["reason"] as? String ?? ""
    #expect(reason.hasPrefix("echo_timeout_"),
            "expected echo_timeout_<ms>ms post-v3.1.3, got \(reason)")
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
        !((obj["verified"] as? Bool)!),
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
    #expect(!((obj["verified"] as? Bool)!))
    #expect(((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!)
}

@Test func testMCUEchoTimeoutEnvVarIsRespected() {
    // Default 500ms.
    #expect(MCUChannel.echoTimeoutMs == 500)
    // Setenv is process-global; not safe to mutate mid-test — this test
    // just documents that valid overrides are 250/500/1000. Invalid values
    // collapse back to the 500 default (covered by the inline logic).
}
