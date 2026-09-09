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

    /// The stride, in the shape that MISCOUNTS. The first two words are ONE 64-bit message, so the
    /// loss is two words and not one: `0x66142000` is that message's continuation, not a message
    /// type 6 of its own. Counting messages rather than words was the earlier reading here and it
    /// understated a SysEx gap by half.
    @Test("a 64-bit message is skipped whole, and the message after it still parses")
    func sixtyFourBitMessageIsSkippedWhole() {
        let (bytes, unconverted) = MIDIFeedback.midi1Bytes(
            fromUMPWords: [0x30160000, 0x66142000, 0x20903C64])
        let events = MIDIFeedback.parseBytes(bytes)
        #expect(events.count == 1)
        #expect(unconverted == 2)
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
        #expect(unconverted == 2)           // the 64-bit message is two words of loss, not one
        guard case .controlChange = events.first else {
            Issue.record("expected the trailing control change, got \(events)")
            return
        }
    }

    /// A data byte with bit 7 set is not a data byte, and the earlier shape here MASKED it — which
    /// turned `0xC0` into `0x40` and manufactured a valid-looking note-on out of a malformed word.
    /// The test then pinned that repair, so the suite certified the normalization rather than the
    /// contract. Both bytes, because one word cannot witness both positions: `0x209040FF` sets
    /// bit 7 in data2 only, and a converter that checked data2 alone would survive it.
    @Test("a data byte with bit 7 set is refused, not repaired")
    func malformedDataBytesAreRefusedRatherThanMasked() {
        let (highData2, lostData2) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x209040FF])
        #expect(highData2.isEmpty)
        #expect(lostData2 == 1)
        let (highData1, lostData1) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x2090C040])
        #expect(highData1.isEmpty)
        #expect(lostData1 == 1)
        // The well-formed word beside them still converts, so the refusal is about bit 7 and not
        // about note-ons.
        let (good, none) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x20904064])
        #expect(good == [0x90, 0x40, 0x64])
        #expect(none == 0)
    }

    /// The stride is per message type, and getting it wrong FABRICATES messages: a continuation
    /// word that happens to carry `0x2` in its top nibble is read as channel voice. Every
    /// multi-word type gets a witness whose continuation words are exactly that shape, so a
    /// converter that advanced one word would emit events no device sent.
    @Test("every multi-word message type is skipped whole, not walked into")
    func multiWordStridesDoNotFabricate() {
        let fakeChannelVoice: UInt32 = 0x20903C64      // reads as note-on if walked into
        let cases: [(name: String, header: UInt32, words: Int)] = [
            ("SysEx7 / Data64", 0x30060000, 2),
            ("MIDI 2.0 channel voice", 0x40903C00, 2),
            ("Data128", 0x50000000, 4),
            ("64-bit reserved 0x8", 0x80000000, 2),
            ("96-bit reserved 0xB", 0xB0000000, 3),
            ("Flex Data", 0xD0000000, 4),
            ("UMP Stream", 0xF0000000, 4),
        ]
        for testCase in cases {
            var words = [testCase.header]
            words.append(contentsOf: Array(repeating: fakeChannelVoice, count: testCase.words - 1))
            let (bytes, unconverted) = MIDIFeedback.midi1Bytes(fromUMPWords: words)
            #expect(bytes.isEmpty, "\(testCase.name) fabricated \(bytes.count) byte(s)")
            // Words, not messages: a message this converter skips costs its whole width.
            #expect(unconverted == testCase.words, "\(testCase.name) reported \(unconverted)")
        }
    }

    /// A message whose words are not all present. Walking into the remainder reads a truncated tail
    /// as a header, so what is left is counted as lost and the loop stops there.
    @Test("a truncated trailing message is counted, not walked into")
    func truncatedTailIsRefused() {
        let (bytes, unconverted) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x20903C64, 0x50000000, 0x20903C64])
        #expect(bytes == [0x90, 0x3C, 0x64])
        #expect(unconverted == 2)
    }

    /// `0xF0`/`0xF7` are SysEx FRAMING and belong to message type `0x3`. Accepted as a system
    /// message they open a SysEx event that no word in this stream can close, so a stray word
    /// would turn into a fabricated incomplete SysEx.
    @Test("SysEx framing in the system message type is refused")
    func sysExFramingInTheWrongTypeIsRefused() {
        let (opened, lostOpen) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x11F00000])
        #expect(opened.isEmpty)
        #expect(lostOpen == 1)
        let (closed, lostClose) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x11F70000])
        #expect(closed.isEmpty)
        #expect(lostClose == 1)
        // A real system message in the same type still converts.
        let (song, none) = MIDIFeedback.midi1Bytes(fromUMPWords: [0x11F20102])
        #expect(song == [0xF2, 0x01, 0x02])
        #expect(none == 0)
    }

    @Test("the legacy packet-list path is untouched by the conversion")
    func legacyByteStreamStillParsesDirectly() {
        let events = MIDIFeedback.parseBytes([0x90, 0x3C, 0x64])
        #expect(events.count == 1)
    }
}
