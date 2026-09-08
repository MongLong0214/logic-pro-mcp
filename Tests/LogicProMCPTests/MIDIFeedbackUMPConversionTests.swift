import Testing
@testable import LogicProMCP

/// #736 — UMP words are not a MIDI 1.0 byte stream, and the difference is every fader echo.
///
/// The shipped callback sliced the words' MEMORY IMAGE and handed it to `parseBytes`. A word is
/// `(0x2 << 28) | (group << 24) | (status << 16) | (data1 << 8) | data2`, whose little-endian bytes
/// are `[data2, data1, status, 0x20|group]` — reversed. Measured live 2026-09-08: 161 packets from
/// Logic produced 8 events instead of 112, because a four-byte packet leaves one byte after the
/// status and every two-data-byte message failed its guard.
///
/// These cases assert the CONVERSION, using words written out in full, so none of them can be
/// satisfied by a fixture that merely agrees with the implementation.
@Suite("Issue #736 — UMP to MIDI 1.0 conversion")
struct MIDIFeedbackUMPConversionTests {

    @Test("a channel-pressure word yields status and ONE data byte, in MIDI order")
    func channelPressureKeepsItsSingleDataByte() {
        let (bytes, unconverted) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x20D01000])
        #expect(bytes == [0xD0, 0x10])
        #expect(unconverted == 0)
    }

    @Test("a pitch-bend word round-trips through parseBytes to the value Logic sent")
    func pitchBendSurvivesConversion() {
        let (bytes, _) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x20E81B61])
        #expect(bytes == [0xE8, 0x1B, 0x61])
        let events = MIDIFeedback.parseBytes(bytes)
        #expect(events.count == 1)
        guard case let .pitchBend(channel, value)? = events.first else {
            Issue.record("expected one pitch bend, got \(events)")
            return
        }
        #expect(channel == 8)
        #expect(value == 12443)
    }

    @Test("a packet carrying two messages yields both, in order")
    func twoMessagesInOnePacketBothSurvive() {
        let (bytes, _) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x20B03010, 0x20E80040])
        let events = MIDIFeedback.parseBytes(bytes)
        #expect(events.count == 2)
        guard case .controlChange = events.first else {
            Issue.record("first event was not a control change: \(events)")
            return
        }
        guard case .pitchBend = events.last else {
            Issue.record("second event was not a pitch bend: \(events)")
            return
        }
    }

    /// The stride, in the shape that MISCOUNTS. `0x66142000` is message type 6, which no branch
    /// converts, so a one-word stride inflates `unconverted` and produces no extra event.
    @Test("a 64-bit message is skipped whole, and the message after it still parses")
    func sixtyFourBitMessageIsSkippedWhole() {
        let (bytes, unconverted) = MIDIFeedback.midi1Bytes(
            fromUMPWords: [0x30160000, 0x66142000, 0x20903C64])
        let events = MIDIFeedback.parseBytes(bytes)
        #expect(events.count == 1)
        #expect(unconverted == 1)
    }

    /// The stride, in the shape that FABRICATES — and the packet needs THREE words to show it.
    ///
    /// My first version of this case used only the 64-bit message's two words and expected one
    /// event. That is wrong: both words belong to that message, so a CORRECT reader yields zero and
    /// the case failed for the right reason. The fabrication is only visible when a real message
    /// follows: with the proper stride the continuation is consumed and one event comes out; with a
    /// one-word stride the continuation is read as a header and a second, invented event appears.
    @Test("a continuation word that looks like channel voice is not read as a header")
    func aContinuationWordIsNotReadAsAHeader() {
        let (bytes, unconverted) = MIDIFeedback.midi1Bytes(
            fromUMPWords: [0x30060000, 0x20903C64, 0x20B03010])
        let events = MIDIFeedback.parseBytes(bytes)
        #expect(events.count == 1)          // the control change only; the note-on would be invented
        #expect(unconverted == 1)
        guard case .controlChange = events.first else {
            Issue.record("expected the trailing control change, got \(events)")
            return
        }
    }

    /// Criterion 2's word cannot witness this: `0x20E81B61`'s data bytes are `0x1B` and `0x61`,
    /// neither with bit 7 set, so `0x7F` and `0xFF` give the same answer there.
    /// BOTH data bytes, because one word cannot witness both masks. `0x209040FF` has bit 7 set in
    /// data2 only, so a mutation that stops masking data1 survives it — measured, after that mutant
    /// passed a suite that already had this case. The second word sets bit 7 in data1.
    @Test("both data bytes are masked to seven bits")
    func dataBytesAreMaskedToSevenBits() {
        let (high2, _) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x209040FF])
        #expect(high2 == [0x90, 0x40, 0x7F])
        let (high1, _) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x2090C040])
        #expect(high1 == [0x90, 0x40, 0x40])
    }

    @Test("the legacy packet-list path is untouched by the conversion")
    func legacyByteStreamStillParsesDirectly() {
        let events = MIDIFeedback.parseBytes([0x90, 0x3C, 0x64])
        #expect(events.count == 1)
    }
}
