import CoreMIDI
import Foundation

/// Parses inbound MIDI from Logic Pro and emits structured events.
enum MIDIFeedback {
    /// Parsed MIDI event types.
    enum Event: Sendable {
        case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
        case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
        case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
        case programChange(channel: UInt8, program: UInt8)
        case pitchBend(channel: UInt8, value: UInt16)
        case aftertouch(channel: UInt8, pressure: UInt8)
        case polyAftertouch(channel: UInt8, note: UInt8, pressure: UInt8)
        case sysEx([UInt8])
        case unknown([UInt8])
    }

    /// Parse a CoreMIDI packet list and yield events into an AsyncStream continuation.
    static func parse(packetList: UnsafePointer<MIDIPacketList>, into continuation: AsyncStream<Event>.Continuation) {
        for packet in packetList.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let bytes = withUnsafeBytes(of: packet.pointee.data) { raw -> [UInt8]? in
                // Reject, rather than truncate, packets larger than Swift's imported
                // 256-byte data tuple: truncation could turn one MIDI command into another.
                guard length <= raw.count else { return nil }
                return Array(raw.prefix(length).bindMemory(to: UInt8.self))
            }
            guard let bytes else { continue }
            for event in parseBytes(bytes) {
                continuation.yield(event)
            }
        }
    }

    /// Convert one CoreMIDI Universal MIDI Packet into the MIDI 1.0 byte stream `parseBytes` reads.
    ///
    /// The MCU port is created with `MIDIDestinationCreateWithProtocol(..., ._1_0, ...)`, so
    /// CoreMIDI delivers MIDI 1.0 messages wrapped in 32-bit UMP words. A word's LAYOUT and its byte
    /// order in memory are different things: the word is
    ///
    ///     (0x2 << 28) | (group << 24) | (status << 16) | (data1 << 8) | data2
    ///
    /// and on a little-endian host its bytes are `[data2, data1, status, 0x20|group]`. Slicing the
    /// memory image and calling it a MIDI stream reverses every message. Measured 2026-09-08 against
    /// a Logic whose Mackie surface was bound: 161 packets produced 8 events instead of 112, and
    /// every fader position was dropped — a four-byte packet puts the status at index 2 and leaves
    /// one byte after it, enough for channel pressure's guard and not for anything with two data
    /// bytes. That is what `echo_timeout_500ms` was.
    ///
    /// Returns the messages this converter understands, concatenated, and the number of WORDS it did
    /// not convert — so a caller can report how much it did not read rather than presenting a
    /// partial decode as a complete one. Words, not messages: a 128-bit message this converter skips
    /// is four words of feedback lost, and counting it as one understates the gap by four.
    static func midi1Bytes(fromUMPWords words: [UInt32]) -> (bytes: [UInt8], unconverted: Int) {
        var out: [UInt8] = []
        var unconverted = 0
        var i = 0
        // SysEx7 assembly state, for a message split across several words of THIS packet. A message
        // that starts here and ends in a later CoreMIDI packet is not assembled — this function is
        // called per packet and holds no state between calls — and its words are counted as
        // unconverted at the end rather than emitted as a truncated frame.
        var sysExPending: [UInt8] = []
        var inSysEx = false
        while i < words.count {
            let word = words[i]
            let messageType = UInt8((word >> 28) & 0xF)
            let size = wordCount(forMessageType: messageType)

            // A message whose words are not all here. Walking into it would read a truncated tail as
            // a header, so the remainder is counted as lost and the loop stops.
            guard i + size <= words.count else {
                unconverted += words.count - i
                break
            }

            switch messageType {
            case 0x0:                       // utility — carries no MIDI 1.0 message and loses none
                break
            case 0x1, 0x2:                  // system real-time/common, and MIDI 1.0 channel voice
                let status = UInt8((word >> 16) & 0xFF)
                let data1 = UInt8((word >> 8) & 0xFF)
                let data2 = UInt8(word & 0xFF)
                // A data byte with bit 7 set is not a data byte. Masking it produced a valid-looking
                // event out of a malformed word and destroyed the evidence that anything was wrong;
                // the word is counted as unconverted instead. `0xF0`/`0xF7` are SysEx FRAMING, which
                // lives in message type 0x3 — accepted here they would open a SysEx event that no
                // word in this stream can close.
                let statusIsFramingInTheWrongType = (messageType == 0x1 && (status == 0xF0 || status == 0xF7))
                switch dataByteCount(forStatus: status) {
                case _ where statusIsFramingInTheWrongType:
                    unconverted += size
                case 0:
                    out.append(status)
                case 1 where data1 < 0x80:
                    out.append(contentsOf: [status, data1])
                case 2 where data1 < 0x80 && data2 < 0x80:
                    out.append(contentsOf: [status, data1, data2])
                default:
                    unconverted += size
                }
            case 0x3:
                // SysEx7. Skipping this whole is what hid the MCU display: the surface reports WHAT
                // it is controlling on its LCD, by name, and every one of those messages arrives
                // here. Measured 2026-09-11 with a Mackie Control bound, plug-in assignment mode
                // wrote `Cha EQ` per strip and pan mode wrote `Angle Divers LFE Spread` — none of
                // which reached `parseBytes`, which has handled `.sysEx` all along.
                //
                //   word0 = mt(4) group(4) status(4) numBytes(4) data0(8) data1(8)
                //   word1 = data2(8) data3(8) data4(8) data5(8)
                //
                // status: 0 complete, 1 start, 2 continue, 3 end. The `F0`/`F7` framing is IMPLIED
                // by the status and is not in the data, so it is added back here.
                let status = UInt8((word >> 20) & 0xF)
                let declared = Int((word >> 16) & 0xF)
                // `numBytes` is a claim by the sender and six is the physical maximum. A larger
                // value would read past the two words that exist, so it is refused rather than
                // clamped. Clamping to six was rejected: a packet that lies about its length is
                // not one to half-believe, and a truncated display write would read as a real one.
                guard declared <= 6 else {
                    unconverted += size
                    sysExPending = []
                    inSysEx = false
                    i += size
                    continue
                }
                let word1 = words[i + 1]
                let available: [UInt8] = [
                    UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF),
                    UInt8((word1 >> 24) & 0xFF), UInt8((word1 >> 16) & 0xFF),
                    UInt8((word1 >> 8) & 0xFF), UInt8(word1 & 0xFF),
                ]
                let payload = Array(available.prefix(declared))
                switch status {
                case 0x0:
                    out.append(0xF0)
                    out.append(contentsOf: payload)
                    out.append(0xF7)
                    sysExPending = []
                    inSysEx = false
                case 0x1:
                    sysExPending = payload
                    inSysEx = true
                case 0x2:
                    // A continue with no start is a fragment whose head this call never saw. It is
                    // counted rather than emitted: half a display write is not a display write.
                    if inSysEx {
                        sysExPending.append(contentsOf: payload)
                    } else {
                        unconverted += size
                    }
                case 0x3:
                    if inSysEx {
                        out.append(0xF0)
                        out.append(contentsOf: sysExPending)
                        out.append(contentsOf: payload)
                        out.append(0xF7)
                    } else {
                        unconverted += size
                    }
                    sysExPending = []
                    inSysEx = false
                default:
                    unconverted += size
                }
            default:
                // Everything else is a message this converter does not read: MIDI 2.0 channel voice,
                // Data128, Flex Data, UMP Stream. It is skipped WHOLE.
                unconverted += size
            }
            i += size
        }
        // A SysEx left open when the packet ended is not a message. Counting its words keeps the
        // gap visible instead of letting a partial display write look like a complete one.
        if inSysEx {
            unconverted += (sysExPending.count + 5) / 6 * 2
        }
        return (out, unconverted)
    }

    /// How many 32-bit words a UMP message of this type occupies.
    ///
    /// The STRIDE matters as much as the byte order. Advancing one word past a multi-word message
    /// reads its continuation as a header, which turns a message this converter merely does not
    /// understand into a FABRICATED one whenever that continuation happens to look like channel
    /// voice — the same class of defect as reading the words as bytes, one level up.
    ///
    /// The table is the UMP specification's, and the four entries CoreMIDI names agree with it:
    /// `MIDIMessages.h` records utility/system/channel-voice-1 as one word, SysEx as two,
    /// channel-voice-2 as two, Data128 as four, Flex Data as four and UMP Stream as four.
    private static func wordCount(forMessageType type: UInt8) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4              // 0x5, 0xD, 0xE, 0xF
        }
    }

    /// How many data bytes a MIDI 1.0 status byte carries. `0` for a status that carries none.
    private static func dataByteCount(forStatus status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch status {
            case 0xF1, 0xF3: return 1
            case 0xF2: return 2
            default: return 0          // real-time, tune request, and SysEx framing bytes
            }
        default: return 2
        }
    }

    /// Parse raw MIDI bytes into one or more events.
    /// Handles running status and SysEx spanning.
    static func parseBytes(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        var i = 0
        var runningStatus: UInt8 = 0  // Running status byte

        while i < bytes.count {
            let byte = bytes[i]

            // SysEx start — resets running status
            if byte == 0xF0 {
                runningStatus = 0
                if let endIndex = bytes[i...].firstIndex(of: 0xF7) {
                    let sysex = Array(bytes[i...endIndex])
                    events.append(.sysEx(sysex))
                    i = endIndex + 1
                } else {
                    events.append(.sysEx(Array(bytes[i...])))
                    break
                }
                continue
            }

            // System Real-Time (0xF8-0xFF): a single status byte with no data.
            // These may appear ANYWHERE — including between the data bytes of
            // a running-status stream — so they must be consumed on their own
            // WITHOUT disturbing `runningStatus`. Previously they fell into the
            // channel-voice branch, which overwrote runningStatus with 0xF8+
            // and then double-consumed a following byte (audit #5), silently
            // dropping the next message.
            if byte >= 0xF8 {
                i += 1
                continue
            }

            // System Common (0xF1-0xF7): resets running status and carries a
            // fixed number of data bytes. Consume the status byte plus exactly
            // its data bytes so the following channel-voice message survives.
            if byte >= 0xF1 {
                runningStatus = 0
                let dataBytes: Int
                switch byte {
                case 0xF2: dataBytes = 2  // Song Position Pointer
                case 0xF1, 0xF3: dataBytes = 1  // MTC Quarter Frame, Song Select
                default: dataBytes = 0  // 0xF4/0xF5 undefined, 0xF6 Tune Request, 0xF7 EOX
                }
                i += 1 + dataBytes
                continue
            }

            // Determine status byte: new status or running status
            let status: UInt8
            let channel: UInt8
            if byte & 0x80 != 0 {
                // New status byte
                runningStatus = byte
                status = byte & 0xF0
                channel = byte & 0x0F
                i += 1  // consume status byte
            } else if runningStatus != 0 {
                // Running status: reuse previous status
                status = runningStatus & 0xF0
                channel = runningStatus & 0x0F
                // don't consume — byte is first data byte
            } else {
                // Data byte with no prior status — skip
                i += 1
                continue
            }

            // i now points to first data byte (status already consumed or running)
            switch status {
            case 0x90:
                guard i + 1 < bytes.count else { i += 1; break }
                let note = bytes[i] & 0x7F
                let vel = bytes[i + 1] & 0x7F
                if vel == 0 {
                    events.append(.noteOff(channel: channel, note: note, velocity: 0))
                } else {
                    events.append(.noteOn(channel: channel, note: note, velocity: vel))
                }
                i += 2
                continue
            case 0x80:
                guard i + 1 < bytes.count else { i += 1; break }
                events.append(.noteOff(channel: channel, note: bytes[i] & 0x7F, velocity: bytes[i + 1] & 0x7F))
                i += 2
                continue
            case 0xB0:
                guard i + 1 < bytes.count else { i += 1; break }
                events.append(.controlChange(channel: channel, controller: bytes[i] & 0x7F, value: bytes[i + 1] & 0x7F))
                i += 2
                continue
            case 0xC0:
                guard i < bytes.count else { break }
                events.append(.programChange(channel: channel, program: bytes[i] & 0x7F))
                i += 1
                continue
            case 0xE0:
                guard i + 1 < bytes.count else { i += 1; break }
                let lsb = UInt16(bytes[i] & 0x7F)
                let msb = UInt16(bytes[i + 1] & 0x7F)
                events.append(.pitchBend(channel: channel, value: (msb << 7) | lsb))
                i += 2
                continue
            case 0xD0:
                guard i < bytes.count else { break }
                events.append(.aftertouch(channel: channel, pressure: bytes[i] & 0x7F))
                i += 1
                continue
            case 0xA0:
                guard i + 1 < bytes.count else { i += 1; break }
                events.append(.polyAftertouch(channel: channel, note: bytes[i] & 0x7F, pressure: bytes[i + 1] & 0x7F))
                i += 2
                continue
            default:
                break
            }

            // Unknown status — skip one byte
            i += 1
        }

        return events
    }
}
