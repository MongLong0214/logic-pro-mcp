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
    /// Returns the messages this converter understands, concatenated, and the count of words it did
    /// not convert — so a caller can report how much it did not read rather than presenting a
    /// partial decode as a complete one.
    static func midi1Bytes(fromUMPWords words: [UInt32]) -> (bytes: [UInt8], unconverted: Int) {
        var out: [UInt8] = []
        var unconverted = 0
        var i = 0
        while i < words.count {
            let word = words[i]
            let messageType = UInt8((word >> 28) & 0xF)
            switch messageType {
            case 0x0:                       // utility — carries no MIDI 1.0 message
                i += 1
            case 0x1, 0x2:                  // system real-time/common, and MIDI 1.0 channel voice
                let status = UInt8((word >> 16) & 0xFF)
                let data1 = UInt8((word >> 8) & 0x7F)
                let data2 = UInt8(word & 0x7F)
                switch dataByteCount(forStatus: status) {
                case 0: out.append(status)
                case 1: out.append(contentsOf: [status, data1])
                default: out.append(contentsOf: [status, data1, data2])
                }
                i += 1
            // The STRIDE matters as much as the order. Advancing one word past a 64-bit message
            // reads its second word as a header, which turns a missing event into a FABRICATED one
            // whenever that word happens to look like channel voice.
            case 0x3, 0x4:                  // 64-bit: SysEx7 data, MIDI 2.0 channel voice
                unconverted += 1
                i += 2
            case 0x5:                       // 128-bit
                unconverted += 1
                i += 4
            default:
                unconverted += 1
                i += 1
            }
        }
        return (out, unconverted)
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
