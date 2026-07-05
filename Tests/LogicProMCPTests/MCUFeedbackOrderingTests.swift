import Testing
@testable import LogicProMCP

// WS6 / AC1 + AC2 (audit-concurrency MCU race + audit-completeness bank-offset).
//
// The production MCU feedback path used to fan every parsed event into an
// unstructured Task{} at TWO sites (MCUChannel + ProductionMCUTransport), so
// an actor admitted events in scheduling order rather than arrival order —
// pitch-bend echoes could land last-write-wins out of order and flip a mixer
// write to a false State A/B. WS6 replaces both fan-outs with ONE ordered
// AsyncStream single-consumer drained in start() and cancelled in stop().
//
// These tests reuse the module-internal MockMCUTransport (declared in
// MCUChannelTests.swift): `emit()` invokes the channel's feedback sink exactly
// as the CoreMIDI callback would.

private let faderTolerance = 1.0 / 16383.0

/// Poll the strip's cached volume until it reaches `expected` (within one MCU
/// LSB) or the deadline elapses. Returns the observed volume, or nil on
/// timeout. Keeps the ordering tests free of arbitrary fixed sleeps.
private func awaitFaderVolume(
    _ cache: StateCache,
    strip: Int,
    expected: Double,
    attempts: Int = 200
) async -> Double? {
    for _ in 0..<attempts {
        let snapshot = await cache.getFaderEchoSnapshot(strip: strip)
        if let volume = snapshot.volume, abs(volume - expected) <= faderTolerance / 2 {
            return volume
        }
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
    }
    return await cache.getFaderEchoSnapshot(strip: strip).volume
}

// MARK: - AC2: bank-offset master fader

@Test func testMasterFaderFeedbackIsBankInvariant() async throws {
    // Master fader feedback arrives on pitch-bend channel 8 and is
    // bank-invariant per the MCU spec: it must map to strip 8 regardless of
    // the active bank. Pre-fix the parser added the bank offset to channel 8
    // too, writing the master volume onto an unrelated banked track (8 + 16 =
    // 24) and leaving strip 8 empty → false set_master_volume echo.
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await parser.setBankOffsetProvider { 2 }  // bank 2 → offset 16

    await parser.handle(.pitchBend(channel: 8, value: 12000))  // master
    await parser.handle(.pitchBend(channel: 3, value: 8000))   // banked track

    // Master maps to strip 8, NOT strip 24.
    let master = await cache.getFaderEchoSnapshot(strip: 8)
    let masterVolume = try #require(
        master.volume,
        "master fader (ch8) must map to strip 8, not shift with the bank"
    )
    #expect(abs(masterVolume - 12000.0 / 16383.0) <= faderTolerance)

    let corrupted = await cache.getFaderEchoSnapshot(strip: 24)
    #expect(corrupted.volume == nil)  // old bug wrote master onto strip 24

    // A per-strip fader DOES follow the bank: channel 3 + offset 16 = strip 19.
    let banked = await cache.getFaderEchoSnapshot(strip: 19)
    let bankedVolume = try #require(
        banked.volume,
        "a banked track fader must shift with the bank offset"
    )
    #expect(abs(bankedVolume - 8000.0 / 16383.0) <= faderTolerance)
}

// MARK: - AC1: ordered single-consumer + lifecycle

@Test func testBurstFeedbackProcessedInFIFOOrder() async throws {
    // Feed a rapid monotonically-increasing ramp of fader echoes for one
    // strip. Under a single ordered consumer the last value fed (255) wins
    // deterministically. Under the old per-event Task{} fan-out the winning
    // value is whichever task happened to land last — the FIFO invariant this
    // test pins is exactly what the race violated (flip-test target).
    let cache = StateCache()
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: cache)
    try await channel.start()

    let last = 255
    for value in 1...last {
        await transport.emit(.pitchBend(channel: 0, value: UInt16(value)))
    }

    let expected = Double(last) / 16383.0
    let observed = try #require(
        await awaitFaderVolume(cache, strip: 0, expected: expected),
        "burst did not drain to the final value — ordering/consumer broken"
    )
    #expect(abs(observed - expected) <= faderTolerance)

    await channel.stop()
}

@Test func testStartStopStartCreatesFreshStream() async throws {
    // A start → stop → start cycle must not crash and must resume delivering
    // feedback on a fresh stream/consumer.
    let cache = StateCache()
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: cache)

    try await channel.start()
    await channel.stop()
    try await channel.start()  // restart on a fresh stream

    await transport.emit(.pitchBend(channel: 0, value: 8000))

    let expected = 8000.0 / 16383.0
    let observed = try #require(
        await awaitFaderVolume(cache, strip: 0, expected: expected),
        "restarted channel did not process feedback on a fresh stream"
    )
    #expect(abs(observed - expected) <= faderTolerance)

    let starts = await transport.startCount
    #expect(starts == 2)

    await channel.stop()
}

@Test func testFeedbackAfterStopIsIgnored() async throws {
    // After stop() the consumer is torn down: feedback that arrives late must
    // NOT mutate the cache. Pre-fix the per-event Task{} still ran after
    // stop() and clobbered the strip; the ordered consumer drops it because
    // the stream continuation is finished.
    let cache = StateCache()
    let transport = MockMCUTransport()
    let channel = MCUChannel(transport: transport, cache: cache)
    try await channel.start()

    // Establish a baseline the drain has fully processed.
    await transport.emit(.pitchBend(channel: 0, value: 4000))
    let baseline = 4000.0 / 16383.0
    let observed = try #require(
        await awaitFaderVolume(cache, strip: 0, expected: baseline),
        "baseline feedback was not processed before stop()"
    )
    #expect(abs(observed - baseline) <= faderTolerance)

    await channel.stop()

    // Late feedback after stop() — must be ignored.
    await transport.emit(.pitchBend(channel: 0, value: 12000))
    try? await Task.sleep(nanoseconds: 200_000_000)  // allow any stray task to run

    let after = await cache.getFaderEchoSnapshot(strip: 0)
    let afterVolume = try #require(after.volume)
    #expect(abs(afterVolume - baseline) <= faderTolerance)  // still baseline, not 12000
}
