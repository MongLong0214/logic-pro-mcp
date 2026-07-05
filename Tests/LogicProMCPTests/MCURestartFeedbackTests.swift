import CoreMIDI
import Foundation
import Testing

@testable import LogicProMCP

// P1 restart regression (v3.8.0 WS6). ProductionMCUTransport used to capture
// its `onReceive` sink BY VALUE inside the closure handed to
// `createBidirectionalPort`. The real MIDIPortManager REUSES an existing
// destination on the 2nd create for the same name (`if let existing = ports[name]`)
// WITHOUT re-registering the callback, so after a stop→start the reused CoreMIDI
// callback kept yielding into the FIRST (now-finished) AsyncStream continuation —
// every MCU feedback event after any restart was silently dropped, breaking
// MCU-verified writes (e.g. set_master_volume echo) on a restarted session.
//
// This drives ProductionMCUTransport directly against a fake port manager that
// reproduces the callback-reuse-on-restart path. MockMCUTransport (in
// MCUChannelTests.swift) cannot reproduce it because it overwrites `onReceive`
// on every start().

/// Fake port manager that mimics `MIDIPortManager`'s `ports[name]` reuse: the
/// FIRST `createBidirectionalPort` installs & retains the CoreMIDI callback;
/// every later call with the same name returns the cached port and KEEPS the
/// original callback (the new closure is discarded — exactly the real reuse).
private actor ReusingPortManager: VirtualPortManaging {
    private var installedCallback:
        (@Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void)?
    private var cachedPair: MIDIPortManager.MIDIPortPair?
    private(set) var bidirectionalCallCount = 0

    func createSendOnlyPort(name: String) throws -> MIDIPortManager.MIDIPortPair {
        MIDIPortManager.MIDIPortPair(name: name, source: 1, destination: nil)
    }

    func createBidirectionalPort(
        name: String,
        onReceive: @escaping @Sendable (UnsafePointer<MIDIEventList>, UnsafeMutableRawPointer?) -> Void
    ) throws -> MIDIPortManager.MIDIPortPair {
        bidirectionalCallCount += 1
        if let cachedPair {
            // Reuse path — deliberately do NOT re-register `onReceive`.
            return cachedPair
        }
        installedCallback = onReceive
        let created = MIDIPortManager.MIDIPortPair(name: name, source: 1, destination: 2)
        cachedPair = created
        return created
    }

    /// Fire the registered CoreMIDI callback with a synthetic MIDI 1.0
    /// pitch-bend, driving the transport's real parse-and-deliver loop. The
    /// crafted UMP word's little-endian bytes are `[status, lsb, msb, 0]` —
    /// exactly what the callback slices out and hands to `MIDIFeedback.parseBytes`.
    func firePitchBend(channel: UInt8, value: UInt16) {
        guard let installedCallback else { return }
        let status = UInt8(0xE0) | (channel & 0x0F)
        let lsb = UInt8(value & 0x7F)
        let msb = UInt8((value >> 7) & 0x7F)
        let word = UInt32(status) | (UInt32(lsb) << 8) | (UInt32(msb) << 16)

        var list = MIDIEventList()
        list.numPackets = 1
        list.packet.wordCount = 1
        list.packet.words.0 = word
        withUnsafePointer(to: &list) { installedCallback($0, nil) }
    }
}

/// Thread-safe recorder for the pitch-bend values a sink observed — the sink is
/// invoked synchronously on the (fake) real-time callback thread.
private final class SinkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt16] = []

    func record(_ event: MIDIFeedback.Event) {
        guard case let .pitchBend(_, value) = event else { return }
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var pitchBends: [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Test func testRestartReusedPortDeliversFeedbackToFreshSink() async throws {
    let portManager = ReusingPortManager()
    let transport = ProductionMCUTransport(portManager: portManager)

    let firstSink = SinkRecorder()
    let secondSink = SinkRecorder()

    // Session 1 — feedback routes into the first sink.
    try await transport.start { firstSink.record($0) }
    await portManager.firePitchBend(channel: 0, value: 4000)
    #expect(firstSink.pitchBends == [4000])

    // Restart on a fresh sink. The fake reuses the cached destination and keeps
    // the ORIGINAL callback (mirroring MIDIPortManager) — a restart-safe
    // transport must still route feedback into `secondSink`.
    await transport.stop()
    try await transport.start { secondSink.record($0) }
    await portManager.firePitchBend(channel: 0, value: 8000)

    // Proves the reuse path was exercised (destination created once, reused once).
    let calls = await portManager.bidirectionalCallCount
    #expect(calls == 2)

    // The post-restart event must land on the CURRENT sink. On buggy HEAD the
    // reused callback still delivers to the stale first sink, so `secondSink`
    // stays empty here → RED. After the fix the box-held sink is current → GREEN.
    #expect(secondSink.pitchBends == [8000])
    // And the stale sink must NOT receive the post-restart event.
    #expect(firstSink.pitchBends == [4000])

    await transport.stop()
}
