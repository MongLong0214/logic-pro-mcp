import Testing

@testable import LogicProMCP

/// The UMP converter skipped SysEx7 whole, so the MCU display never reached `parseBytes` — which
/// has handled `.sysEx` all along. That is where the surface says WHAT it is controlling, by name,
/// and #856 could only read it through a throwaway raw-word dump.
///
/// The `F0`/`F7` framing is implied by the SysEx7 status and absent from the data, so these rows
/// assert it is added back, and that a fragment whose other half is not in this packet is COUNTED
/// rather than emitted — half a display write is not a display write.
@Suite("UMP SysEx7 reaches the parser")
struct MIDIFeedbackSysExConversionTests {
    /// word0 = mt(4) group(4) status(4) numBytes(4) data0(8) data1(8)
    private func word0(status: UInt32, count: UInt32, _ d0: UInt32, _ d1: UInt32) -> UInt32 {
        (0x3 << 28) | (0 << 24) | (status << 20) | (count << 16) | (d0 << 8) | d1
    }
    private func word1(_ d2: UInt32, _ d3: UInt32, _ d4: UInt32, _ d5: UInt32) -> UInt32 {
        (d2 << 24) | (d3 << 16) | (d4 << 8) | d5
    }

    @Test("a complete SysEx7 in one message becomes a framed F0…F7")
    func completeMessageIsFramed() {
        // MCU display header: 00 00 66 14 12 00
        let words = [word0(status: 0, count: 6, 0x00, 0x00), word1(0x66, 0x14, 0x12, 0x00)]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes == [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00, 0xF7])
        #expect(result.unconverted == 0)
    }

    @Test("a start/end pair is joined into one message")
    func startAndEndAreJoined() {
        let words = [
            word0(status: 1, count: 6, 0x00, 0x00), word1(0x66, 0x14, 0x12, 0x00),
            word0(status: 3, count: 2, 0x41, 0x42), word1(0, 0, 0, 0),
        ]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes == [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00, 0x41, 0x42, 0xF7])
        #expect(result.unconverted == 0)
    }

    @Test("a continue between start and end carries its bytes")
    func continueIsCarried() {
        let words = [
            word0(status: 1, count: 2, 0x01, 0x02), word1(0, 0, 0, 0),
            word0(status: 2, count: 2, 0x03, 0x04), word1(0, 0, 0, 0),
            word0(status: 3, count: 2, 0x05, 0x06), word1(0, 0, 0, 0),
        ]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes == [0xF0, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0xF7])
    }

    @Test("a SysEx left open when the packet ends is counted, not emitted")
    func unterminatedIsCounted() {
        let words = [word0(status: 1, count: 6, 0x00, 0x00), word1(0x66, 0x14, 0x12, 0x00)]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes.isEmpty)
        #expect(result.unconverted > 0)
    }

    @Test("a continue with no start is counted, not emitted")
    func orphanContinueIsCounted() {
        let words = [word0(status: 2, count: 2, 0x41, 0x42), word1(0, 0, 0, 0)]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes.isEmpty)
        #expect(result.unconverted == 2)
    }

    @Test("numBytes larger than the two words can hold is refused, not clamped")
    func overlongCountIsRefused() {
        let words = [word0(status: 0, count: 7, 0x41, 0x42), word1(0, 0, 0, 0)]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes.isEmpty)
        #expect(result.unconverted == 2)
    }

    @Test("the assembled bytes parse back into a sysEx event")
    func assembledBytesReachTheParser() {
        let words = [word0(status: 0, count: 6, 0x00, 0x00), word1(0x66, 0x14, 0x12, 0x00)]
        let events = MIDIFeedback.parseBytes(MIDIFeedback.midi1Bytes(fromUMPWords: words).bytes)
        var sawSysEx = false
        for event in events {
            if case .sysEx = event { sawSysEx = true }
        }
        #expect(sawSysEx)
    }

    /// Channel voice alongside SysEx must still convert — the new branch must not swallow the
    /// stream it shares a loop with.
    @Test("channel voice around a SysEx still converts")
    func channelVoiceSurvives() {
        let noteOn: UInt32 = (0x2 << 28) | (0x90 << 16) | (0x3C << 8) | 0x7F
        let words = [
            noteOn,
            word0(status: 0, count: 2, 0x11, 0x22), word1(0, 0, 0, 0),
            noteOn,
        ]
        let result = MIDIFeedback.midi1Bytes(fromUMPWords: words)
        #expect(result.bytes == [0x90, 0x3C, 0x7F, 0xF0, 0x11, 0x22, 0xF7, 0x90, 0x3C, 0x7F])
        #expect(result.unconverted == 0)
    }
}
