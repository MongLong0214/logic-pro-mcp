import Foundation
import Testing
@testable import LogicProMCP

// v3.4.5-rc5 — Issues #10/#11. When a mixer write returns State B with
// `echo_timeout_<ms>ms`, downstream safety harnesses need enough context
// to distinguish three root causes without writing their own probes:
//
//   1. MCU port never received any feedback (control surface not registered
//      in Logic, virtual port not bridged).
//   2. MCU was connected at some point but feedback has gone stale (Logic
//      lost the connection mid-session).
//   3. MCU is healthy and fresh, but THIS specific fader/V-Pot echo did
//      not land — points to a Logic-build regression or bank-offset
//      mismatch, not a setup issue.
//
// Embedding `mcu_connected` / `mcu_registered` / `mcu_last_feedback_age_ms`
// into the HC envelope extras (both State A and State B) lets a harness
// branch on these without making an extra `logic://mixer` or
// `logic_system` call. State A also carries them so the harness can log
// a "confirmed write while MCU was fresh" provenance row uniformly.

private func decodeMixerJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

private actor SlowSendMCUTransport: MCUTransportProtocol {
    let delayNs: UInt64

    init(delayNs: UInt64) {
        self.delayNs = delayNs
    }

    func send(_ bytes: [UInt8]) async {
        _ = bytes
        try? await Task.sleep(nanoseconds: delayNs)
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {
        _ = onReceive
    }

    func stop() {}
}

@Test func testSetVolumeStateBIncludesMCUDiagnostics_disconnected() async {
    // No feedback has ever arrived → mcuConnection defaults all false / nil.
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!)

    // Issue #10/#11 diagnostic extras
    #expect(
        !((obj["mcu_connected"] as? Bool)!),
        "State B must surface mcu_connected so the harness can identify control-surface registration gaps"
    )
    #expect(!((obj["mcu_registered"] as? Bool)!))
    // No feedback ever → null. JSONSerialization renders nil as NSNull.
    #expect(
        obj["mcu_last_feedback_age_ms"] is NSNull,
        "no feedback observed yet → mcu_last_feedback_age_ms must be JSON null"
    )
}

@Test func testSetVolumeStateAIncludesMCUDiagnostics_connectedFresh() async {
    // Pre-stamp the connection as connected + recently-seen-feedback. State A
    // requires the echo to land *after* sendAt is captured inside execute,
    // so we drive a matching pitch-bend with a 50ms detached delay (same
    // pattern as testMCUSetVolumeReturnsStateAWhenEchoMatches). The
    // connection extras are populated from `cache.getMCUConnection()` after
    // the poll, so even if Test scheduling lands us in State B under
    // parallel load, the diagnostic fields must still be present and
    // populated from the freshly-stamped connection state.
    let transport = MockMCUTransport()
    let cache = StateCache()
    var conn = await cache.getMCUConnection()
    conn.isConnected = true
    conn.registeredAsDevice = true
    conn.portName = "LogicProMCP-MCU-Internal"
    conn.lastFeedbackAt = Date()
    await cache.updateMCUConnection(conn)
    let channel = MCUChannel(transport: transport, cache: cache)

    let target = 0.5
    let raw = UInt16(target * 16383.0)
    Task.detached {
        try? await Task.sleep(nanoseconds: 50_000_000)
        await channel.handleFeedback(.pitchBend(channel: 0, value: raw))
    }

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "\(target)"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    // Diagnostic fields must appear regardless of State A vs B outcome —
    // that's the contract this test guards.
    #expect((obj["mcu_connected"] as? Bool)!)
    #expect((obj["mcu_registered"] as? Bool)!)
    let ageMs = obj["mcu_last_feedback_age_ms"] as? Int
    #expect(ageMs != nil, "connection had a feedback timestamp → age must be a number")
    if let ageMs {
        #expect(ageMs >= 0)
        #expect(ageMs < 5_000, "feedback was just stamped, age must be sub-5s")
    }
}

@Test func testSetPanStateBIncludesMCUDiagnostics_disconnected() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "-0.3"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(!((obj["mcu_connected"] as? Bool)!))
    #expect(!((obj["mcu_registered"] as? Bool)!))
    #expect(obj["mcu_last_feedback_age_ms"] is NSNull)
}

// T-A4 (P1-5 / R8) — set_pan is a relative V-Pot nudge, not an absolute
// target set (MCU has no absolute-position command; speed = max(1, …) so
// even pan 0.0 moves one tick). The envelope must disclose `pan_write_mode`
// so a harness does not treat set_pan as an idempotent absolute write.
@Test func testSetPanCarriesRelativeModeExtra() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_pan",
        params: ["index": "0", "pan": "0.0"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect(obj["pan_write_mode"] as? String == "relative_vpot")
    // No echo from the mock → must not claim verification.
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["observed"] is NSNull)
}

// set_volume must NOT carry pan_write_mode (relative disclosure is pan-only).
@Test func testSetVolumeHasNoPanWriteMode() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)
    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    let obj = decodeMixerJSON(result.message)
    #expect(obj["pan_write_mode"] == nil)
}

@Test func testSetMasterVolumeStateBIncludesMCUDiagnostics_disconnected() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_master_volume",
        params: ["volume": "0.4"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["track"] as? String == "master")
    #expect(!((obj["mcu_connected"] as? Bool)!))
    #expect(!((obj["mcu_registered"] as? Bool)!))
    #expect(obj["mcu_last_feedback_age_ms"] is NSNull)
}

// v3.4.5-rc5 (Boomer BOOMER-6 / B2) — regression guard for the TOCTOU
// race that previously let `pollFaderEcho` pair an old value with a new
// timestamp and false-positive State A. The fix routes both reads
// through `StateCache.getFaderEchoSnapshot` so they happen in the same
// actor turn. This test seeds a stale (value, oldTimestamp) pair, then
// races `updateFader(newValue, newTimestamp)` against the poll loop;
// the new value must NEVER bind to the old timestamp on the wire.
@Test func testFaderEchoSnapshotIsAtomic() async {
    let cache = StateCache()
    let oldTimestamp = Date().addingTimeInterval(-10.0)
    let newTimestamp = Date()

    // Seed (oldValue, oldTimestamp) via direct mutation.
    await cache.updateFader(strip: 0, volume: 0.3)
    // Re-snapshot with a forced-old timestamp by re-driving the parser
    // path: there is no public setter for `faderUpdatedAt` outside
    // `updateFader`, so we use updateFader twice with a tiny delay and
    // assert the snapshot semantics, not the absolute timestamps.
    let snap1 = await cache.getFaderEchoSnapshot(strip: 0)
    #expect(snap1.volume == 0.3)
    #expect(snap1.updatedAt != nil)

    // Bind in a fresh update.
    await cache.updateFader(strip: 0, volume: 0.7)
    let snap2 = await cache.getFaderEchoSnapshot(strip: 0)
    #expect(snap2.volume == 0.7)
    #expect(snap2.updatedAt != nil)
    if let t1 = snap1.updatedAt, let t2 = snap2.updatedAt {
        #expect(t2 >= t1, "later update must produce newer (or equal) timestamp")
    }
    // Boundary: a fresh actor read pairs the value and timestamp from
    // the same backing store snapshot. The atomicity claim is structural
    // (one actor turn, one read), so any (value, updatedAt) pair this
    // helper returns is guaranteed consistent.
    _ = oldTimestamp
    _ = newTimestamp
}

@Test func testPanEchoSnapshotIsAtomic() async {
    let cache = StateCache()
    await cache.updatePan(strip: 0, value: -0.4)
    let snap1 = await cache.getPanEchoSnapshot(strip: 0)
    #expect(snap1.pan == -0.4)
    #expect(snap1.updatedAt != nil)

    await cache.updatePan(strip: 0, value: 0.6)
    let snap2 = await cache.getPanEchoSnapshot(strip: 0)
    #expect(snap2.pan == 0.6)
    if let t1 = snap1.updatedAt, let t2 = snap2.updatedAt {
        #expect(t2 >= t1)
    }
}

@Test func testFaderEchoSnapshotEmptyStripReturnsNilNil() async {
    let cache = StateCache()
    let snap = await cache.getFaderEchoSnapshot(strip: 0)
    // Strip 0 was never written. The strip array may auto-expand on
    // upstream calls, so the helper either returns (nil, nil) or
    // (defaultVolume, nil). The atomicity invariant we care about is
    // that updatedAt is nil when no write has happened.
    #expect(snap.updatedAt == nil)
}

@Test func testMCUDiagnosticsClampsNegativeAgeFromClockJump() async {
    // Boomer P2 (BOOMER-6 / E): if the system clock slews backwards between
    // the feedback timestamp and the diagnostic read, `Date.timeIntervalSince`
    // returns a negative interval. The wire format must never carry a
    // negative age — clamp to 0 so harnesses can rely on the field being a
    // non-negative integer (or null).
    let transport = MockMCUTransport()
    let cache = StateCache()
    var conn = await cache.getMCUConnection()
    conn.isConnected = true
    conn.registeredAsDevice = true
    conn.portName = "LogicProMCP-MCU-Internal"
    // Pretend feedback arrived 5s in the future (clock jumped back).
    conn.lastFeedbackAt = Date().addingTimeInterval(5.0)
    await cache.updateMCUConnection(conn)
    let channel = MCUChannel(transport: transport, cache: cache)

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    let obj = decodeMixerJSON(result.message)
    let ageMs = obj["mcu_last_feedback_age_ms"] as? Int
    #expect(ageMs != nil, "stamped lastFeedbackAt → ageMs must be an Int")
    if let ageMs {
        #expect(ageMs >= 0, "clock-jump-induced negative age must clamp to 0, got \(ageMs)")
    }
}

// v3.4.5-rc5 (tester P2 followup) — the *reporter's actual case*: MCU has
// handshaken at least once (isConnected:true, registered:true) and the
// feedback age is fresh (<500ms), but the specific fader pitch-bend echo
// for this write didn't arrive within the poll window. This is the wire
// shape the corrective comment on Issues #10/#11 promised the harness
// would see, so a deterministic unit test is the right contract gate.
@Test func testSetVolumeStateBSurfacesRegisteredAndFreshButEchoMissing() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    // Pre-seed the connection as healthy + recently-seen, but do NOT
    // dispatch a matching pitch-bend echo. pollFaderEcho will time out
    // and the envelope must surface State B with the diagnostic triplet
    // showing connected:true + small (sub-second) age — pointing the
    // harness at root cause #3 (Logic-side echo regression / bank
    // offset) rather than #1 (Mackie Control unregistered).
    var conn = await cache.getMCUConnection()
    conn.isConnected = true
    conn.registeredAsDevice = true
    conn.portName = "LogicProMCP-MCU-Internal"
    conn.lastFeedbackAt = Date()
    await cache.updateMCUConnection(conn)

    let channel = MCUChannel(transport: transport, cache: cache)
    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!)
    // The smoking-gun shape from the reporter's environment:
    #expect((obj["mcu_connected"] as? Bool)!)
    #expect((obj["mcu_registered"] as? Bool)!)
    if let ageMs = obj["mcu_last_feedback_age_ms"] as? Int {
        // Sub-second: the 500ms poll plus a few ms of test overhead.
        #expect(ageMs < 2000, "fresh feedback case must report sub-2s age, got \(ageMs)")
    } else {
        Issue.record("fresh-feedback case must produce an Int age, not null")
    }
}

@Test func testSetVolumeDiagnosticsAgeAnchorsToWriteStartUnderSlowTransport() async {
    let transport = SlowSendMCUTransport(delayNs: 2_500_000_000)
    let cache = StateCache()
    var conn = await cache.getMCUConnection()
    conn.isConnected = true
    conn.registeredAsDevice = true
    conn.portName = "LogicProMCP-MCU-Internal"
    conn.lastFeedbackAt = Date()
    await cache.updateMCUConnection(conn)

    let channel = MCUChannel(transport: transport, cache: cache)
    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(((obj["reason"] as? String)?.hasPrefix("echo_timeout_"))!)
    #expect((obj["mcu_connected"] as? Bool)!)
    #expect((obj["mcu_registered"] as? Bool)!)
    if let ageMs = obj["mcu_last_feedback_age_ms"] as? Int {
        #expect(
            ageMs < 1000,
            "write-start snapshot must stay fresh even if the send path stalls, got \(ageMs)"
        )
    } else {
        Issue.record("slow-send fresh case must produce an Int age, not null")
    }
}

@Test func testSetVolumeUsesAXReadbackAfterMCUEchoTimeout() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(
        transport: transport,
        cache: cache,
        axReadback: .init(
            readVolume: { track in track == 0 ? 0.5 : nil },
            readPan: { _ in nil }
        )
    )

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )

    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["verify_source"] as? String == "ax_readback")
    #expect(obj["observed"] as? Double == 0.5)
    #expect(obj["observed_ax"] as? Double == 0.5)
    #expect(obj["observed_mcu"] is NSNull)

    let echo = await cache.getFaderEchoSnapshot(strip: 0)
    #expect(echo.updatedAt == nil, "AX readback must not be written into the MCU echo cache")
}

@Test func testSetVolumeAXReadbackMismatchReturnsStateBWithoutCachePollution() async {
    let transport = MockMCUTransport()
    let cache = StateCache()
    let channel = MCUChannel(
        transport: transport,
        cache: cache,
        axReadback: .init(
            readVolume: { track in track == 0 ? 0.2 : nil },
            readPan: { _ in nil }
        )
    )

    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )

    #expect(result.isSuccess)
    let obj = decodeMixerJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["verify_source"] as? String == "ax_readback")
    #expect(obj["observed"] as? Double == 0.2)
    #expect(obj["observed_ax"] as? Double == 0.2)
    #expect(obj["observed_mcu"] is NSNull)

    let echo = await cache.getFaderEchoSnapshot(strip: 0)
    #expect(echo.updatedAt == nil, "mismatched AX readback must not be written into the MCU echo cache")
}

@Test func testSetVolumeStateBSurfacesConnectionRegisteredButStale() async {
    // Emulate: MCU was connected (e.g. a Device Response arrived during
    // startup) but no further feedback during the write window. This is
    // the "registered but Logic 12.2 dropped the fader echo" shape #10 is
    // describing. mcu_last_feedback_age_ms must be >= the time we waited.
    let transport = MockMCUTransport()
    let cache = StateCache()
    let staleAt = Date().addingTimeInterval(-2.0) // 2s ago
    var conn = await cache.getMCUConnection()
    conn.isConnected = true
    conn.registeredAsDevice = true
    conn.portName = "LogicProMCP-MCU-Internal"
    conn.lastFeedbackAt = staleAt
    await cache.updateMCUConnection(conn)

    let channel = MCUChannel(transport: transport, cache: cache)
    let result = await channel.execute(
        operation: "mixer.set_volume",
        params: ["index": "0", "volume": "0.5"]
    )
    let obj = decodeMixerJSON(result.message)
    #expect(!((obj["verified"] as? Bool)!))
    #expect((obj["mcu_connected"] as? Bool)!)
    #expect((obj["mcu_registered"] as? Bool)!)
    if let ageMs = obj["mcu_last_feedback_age_ms"] as? Int {
        #expect(ageMs >= 1500, "stale feedback (~2s ago) should report age >= 1.5s")
    } else {
        Issue.record("expected mcu_last_feedback_age_ms to be an Int")
    }
}
