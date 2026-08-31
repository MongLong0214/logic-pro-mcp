import Testing
@testable import LogicProMCP

private actor IngressDroppingMCUTransport: MCUTransportProtocol {
    func send(_ bytes: [UInt8]) async {}

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {}

    func start(
        onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void,
        onIngressDrop: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        onIngressDrop(3)
    }

    func stop() async {}
}

/// #683: the CoreMIDI callback may receive feedback for MCU units the server
/// does not own, as well as partial SysEx. Neither shape may wait for a device
/// response or turn the feedback hand-off into an unbounded queue.
@Suite("Issue #683 — MCU feedback liveness")
struct Issue683MCUFeedbackLivenessTests {
    @Test("unknown MCU device queries and truncated SysEx stay finite")
    func unknownDeviceQueriesAndTruncatedSysExStayFinite() {
        let deviceIDs: [UInt8] = [0x14, 0x10, 0x11, 0x15, 0x17]
        for deviceID in deviceIDs {
            let bytes: [UInt8] = [0xF0, 0x00, 0x00, 0x66, deviceID, 0x00, 0xF7]
            let events = MIDIFeedback.parseBytes(bytes)
            #expect(events.count == 1)
            guard case .sysEx(let parsed)? = events.first else {
                Issue.record("device query for id \(deviceID) was not emitted as finite SysEx")
                continue
            }
            #expect(parsed == bytes)
        }

        // A partial frame is one finite event. It is not retained for future
        // reassembly and it cannot wait for a terminator that may never arrive.
        let truncated: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x00]
        let events = MIDIFeedback.parseBytes(truncated)
        #expect(events.count == 1)
        guard case .sysEx(let parsed)? = events.first else {
            Issue.record("truncated SysEx was not returned as an ignored finite event")
            return
        }
        #expect(parsed == truncated)
    }

    @Test("normal MCU feedback packet shapes parse without a device-specific reply")
    func normalFeedbackShapesParseWithoutDeviceSpecificReply() {
        // Channel pressure, LCD SysEx, fader pitch bend, V-Pot ring, button
        // LED and timecode CC, as captured from the reporter's Logic session.
        let bytes: [UInt8] = [
            0xD0, 0x40,
            0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00, 0x54, 0x31, 0xF7,
            0xE0, 0x00, 0x40,
            0xB0, 0x30, 0x46,
            0x90, 0x12, 0x7F,
            0xB0, 0x40, 0x01,
        ]
        let events = MIDIFeedback.parseBytes(bytes)
        #expect(events.count == 6)
        guard events.count == 6 else { return }
        guard case .aftertouch(channel: 0, pressure: 0x40) = events[0] else {
            Issue.record("channel pressure did not parse")
            return
        }
        guard case .sysEx = events[1] else {
            Issue.record("LCD SysEx did not parse")
            return
        }
        guard case .pitchBend(channel: 0, value: 8192) = events[2] else {
            Issue.record("fader position did not parse")
            return
        }
        guard case .controlChange(channel: 0, controller: 0x30, value: 0x46) = events[3] else {
            Issue.record("V-Pot ring did not parse")
            return
        }
        guard case .noteOn(channel: 0, note: 0x12, velocity: 0x7F) = events[4] else {
            Issue.record("button LED did not parse")
            return
        }
        guard case .controlChange(channel: 0, controller: 0x40, value: 0x01) = events[5] else {
            Issue.record("timecode CC did not parse")
            return
        }
    }

    @Test("feedback ingress is bounded and exposes its overflow")
    func feedbackIngressIsBoundedAndExposesOverflow() {
        // Do not consume the stream: this simulates a stalled feedback
        // consumer. The second event must be rejected instead of allocating an
        // unbounded backlog, and the exact fact is available to health checks.
        let ingress = MCUFeedbackIngress(capacity: 1)
        ingress.yield(.noteOn(channel: 0, note: 0x12, velocity: 0x7F))
        ingress.yield(.pitchBend(channel: 0, value: 8192))
        ingress.recordDrop(count: 3)

        let snapshot = ingress.snapshot()
        #expect(snapshot.overflowed)
        #expect(snapshot.droppedEventCount == 4)
    }

    @Test("MCU health exposes CoreMIDI callback drops")
    func mcuHealthExposesCallbackDrops() async throws {
        let channel = MCUChannel(transport: IngressDroppingMCUTransport(), cache: StateCache())

        try await channel.start()

        let snapshot = await channel.feedbackIngressSnapshot()
        let health = await channel.healthCheck()
        #expect(snapshot == MCUFeedbackIngressSnapshot(droppedEventCount: 3, overflowed: true))
        #expect(!health.available)
        #expect(health.detail.contains("dropped 3 event(s)"))
    }
}
