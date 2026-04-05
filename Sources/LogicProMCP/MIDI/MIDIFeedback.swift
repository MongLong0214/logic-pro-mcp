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
    static func parse(packetList: MIDIPacketList, into continuation: AsyncStream<Event>.Continuation) {
        var list = packetList
        withUnsafePointer(to: &list.packet) { firstPacket in
            var packet = firstPacket
            for _ in 0..<list.numPackets {
                let p = packet.pointee
                let length = Int(p.length)
                let bytes = withUnsafeBytes(of: p.data) { raw in
                    Array(raw.prefix(length).bindMemory(to: UInt8.self))
                }
                for event in parseBytes(bytes) {
                    continuation.yield(event)
                }
                packet = UnsafePointer(MIDIPacketNext(packet))
            }
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
