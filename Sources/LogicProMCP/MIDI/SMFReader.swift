import Foundation

enum SMFReaderError: Error, Equatable {
    case malformedHeader
    case unsupportedFormat(Int)
    case unsupportedDivision(UInt16)
    case invalidTrackLength
    case malformedVLQ
    case malformedEvent
    case missingEndOfTrack
    case badEndOfTrackLength
    case eventAfterEndOfTrack
    case truncatedEvent
    case invalidTimeDivision
    case unmatchedNoteOff(pitch: UInt8, channel: Int)
    case danglingNotes
}

struct SMFReader {
    struct Note: Equatable {
        let pitch: UInt8
        let velocity: UInt8
        let startBar: Int
        let startBeat: Double
        let durationBeats: Double
        let channel: Int
    }

    static func parse(_ data: Data) throws -> [Note] {
        var reader = ByteReader([UInt8](data))
        try reader.expect([0x4D, 0x54, 0x68, 0x64])
        let headerLength = try reader.readUInt32()
        guard headerLength >= 6 else { throw SMFReaderError.malformedHeader }

        let format = Int(try reader.readUInt16())
        guard format == 0 || format == 1 else { throw SMFReaderError.unsupportedFormat(format) }
        let trackCount = Int(try reader.readUInt16())
        guard format == 1 || trackCount == 1 else { throw SMFReaderError.malformedHeader }

        let divisionRaw = try reader.readUInt16()
        guard divisionRaw & 0x8000 == 0 else { throw SMFReaderError.unsupportedDivision(divisionRaw) }
        let ticksPerQuarter = Int(divisionRaw)
        guard ticksPerQuarter > 0 else { throw SMFReaderError.unsupportedDivision(divisionRaw) }
        try reader.skip(Int(headerLength) - 6)

        var notes: [RawNote] = []
        var timeSignatures: [TimeSignatureChange] = []
        for _ in 0..<trackCount {
            try reader.expect([0x4D, 0x54, 0x72, 0x6B])
            let length = Int(try reader.readUInt32())
            guard reader.remaining >= length else { throw SMFReaderError.invalidTrackLength }
            let trackBytes = try reader.readBytes(length)
            let track = try parseTrack(trackBytes)
            notes.append(contentsOf: track.notes)
            timeSignatures.append(contentsOf: track.timeSignatures)
        }
        guard reader.isAtEnd else { throw SMFReaderError.invalidTrackLength }

        let map = try TimeMap(ticksPerQuarter: ticksPerQuarter, changes: timeSignatures)
        return try notes.sorted().map { try map.note(from: $0) }
    }

    private struct ParsedTrack {
        let notes: [RawNote]
        let timeSignatures: [TimeSignatureChange]
    }

    private struct NoteKey: Hashable {
        let pitch: UInt8
        let channel: Int
    }

    private struct ActiveNote {
        let tick: Int
        let velocity: UInt8
    }

    private struct RawNote: Comparable {
        let pitch: UInt8
        let velocity: UInt8
        let startTick: Int
        let endTick: Int
        let channel: Int

        static func < (lhs: RawNote, rhs: RawNote) -> Bool {
            if lhs.startTick != rhs.startTick { return lhs.startTick < rhs.startTick }
            if lhs.pitch != rhs.pitch { return lhs.pitch < rhs.pitch }
            return lhs.channel < rhs.channel
        }
    }

    private static func parseTrack(_ bytes: [UInt8]) throws -> ParsedTrack {
        var reader = ByteReader(bytes)
        var tick = 0
        var runningStatus: UInt8?
        var active: [NoteKey: [ActiveNote]] = [:]
        var notes: [RawNote] = []
        var timeSignatures: [TimeSignatureChange] = []
        var sawEndOfTrack = false

        while !reader.isAtEnd {
            tick += try reader.readVLQ()
            let first = try reader.readByte()

            if first == 0xFF {
                runningStatus = nil
                if try parseMetaEvent(tick: tick, reader: &reader, timeSignatures: &timeSignatures) {
                    guard !sawEndOfTrack else { throw SMFReaderError.eventAfterEndOfTrack }
                    sawEndOfTrack = true
                    guard reader.isAtEnd else { throw SMFReaderError.eventAfterEndOfTrack }
                }
            } else if first == 0xF0 || first == 0xF7 {
                runningStatus = nil
                try reader.skip(try reader.readVLQ())
            } else {
                try parseChannelEvent(
                    firstByte: first,
                    tick: tick,
                    runningStatus: &runningStatus,
                    reader: &reader,
                    active: &active,
                    notes: &notes
                )
            }
        }

        guard sawEndOfTrack else { throw SMFReaderError.missingEndOfTrack }
        guard active.values.allSatisfy(\.isEmpty) else { throw SMFReaderError.danglingNotes }
        return ParsedTrack(notes: notes, timeSignatures: timeSignatures)
    }

    private static func parseMetaEvent(
        tick: Int,
        reader: inout ByteReader,
        timeSignatures: inout [TimeSignatureChange]
    ) throws -> Bool {
        let type = try reader.readByte()
        let length = try reader.readVLQ()

        if type == 0x2F {
            guard length == 0 else { throw SMFReaderError.badEndOfTrackLength }
            return true
        }

        let payload = try reader.readBytes(length)

        switch type {
        case 0x51:
            guard length == 3 else { throw SMFReaderError.malformedEvent }
        case 0x58:
            guard length == 4, payload[0] > 0, payload[1] < 8 else { throw SMFReaderError.malformedEvent }
            timeSignatures.append(TimeSignatureChange(
                tick: tick,
                signature: TimeSignature(numerator: Int(payload[0]), denominator: 1 << Int(payload[1]))
            ))
        default:
            break
        }
        return false
    }

    private static func parseChannelEvent(
        firstByte: UInt8,
        tick: Int,
        runningStatus: inout UInt8?,
        reader: inout ByteReader,
        active: inout [NoteKey: [ActiveNote]],
        notes: inout [RawNote]
    ) throws {
        var dataBytes: [UInt8] = []
        let status: UInt8

        if firstByte < 0x80 {
            guard let running = runningStatus else { throw SMFReaderError.malformedEvent }
            status = running
            dataBytes.append(firstByte)
        } else {
            guard firstByte < 0xF0 else { throw SMFReaderError.malformedEvent }
            status = firstByte
            runningStatus = status
        }

        let highNibble = status & 0xF0
        let dataCount = (highNibble == 0xC0 || highNibble == 0xD0) ? 1 : 2
        while dataBytes.count < dataCount {
            let byte = try reader.readByte()
            guard byte < 0x80 else { throw SMFReaderError.malformedEvent }
            dataBytes.append(byte)
        }

        guard highNibble == 0x80 || highNibble == 0x90 else { return }
        let pitch = dataBytes[0]
        let velocity = dataBytes[1]
        let channel = Int(status & 0x0F) + 1
        let key = NoteKey(pitch: pitch, channel: channel)

        if highNibble == 0x90 && velocity > 0 {
            active[key, default: []].append(ActiveNote(tick: tick, velocity: velocity))
            return
        }

        guard var stack = active[key], !stack.isEmpty else {
            throw SMFReaderError.unmatchedNoteOff(pitch: pitch, channel: channel)
        }
        let start = stack.removeFirst()
        active[key] = stack
        // #1031: a Note Off can land on its Note On's tick (a zero-length note,
        // common for drum triggers) -- that is not malformed, only a negative
        // span is. `tick` only ever grows while a track is parsed (deltas are
        // non-negative VLQs), so `tick < start.tick` cannot occur here today;
        // the guard stays as a defensive invariant on that ordering.
        guard tick >= start.tick else { throw SMFReaderError.malformedEvent }
        notes.append(RawNote(
            pitch: pitch,
            velocity: start.velocity,
            startTick: start.tick,
            endTick: tick,
            channel: channel
        ))
    }

    private struct TimeSignature: Equatable {
        let numerator: Int
        let denominator: Int

        func ticksPerBeat(_ ticksPerQuarter: Int) throws -> Double {
            guard ticksPerQuarter > 0, denominator > 0 else { throw SMFReaderError.invalidTimeDivision }
            let ticks = Double(ticksPerQuarter) * 4.0 / Double(denominator)
            guard ticks > 0, ticks.isFinite else { throw SMFReaderError.invalidTimeDivision }
            return ticks
        }
    }

    private struct TimeSignatureChange {
        let tick: Int
        let signature: TimeSignature
    }

    private struct TimeSegment {
        let startTick: Int
        let startBar: Int
        let startBeat: Double
        let signature: TimeSignature
    }

    private struct TimeMap {
        let ticksPerQuarter: Int
        let segments: [TimeSegment]

        init(ticksPerQuarter: Int, changes: [TimeSignatureChange]) throws {
            self.ticksPerQuarter = ticksPerQuarter
            let defaultSignature = TimeSignature(numerator: 4, denominator: 4)
            var byTick = [0: defaultSignature]
            for change in changes where change.tick >= 0 {
                byTick[change.tick] = change.signature
            }

            let ordered = byTick
                .map { TimeSignatureChange(tick: $0.key, signature: $0.value) }
                .sorted { $0.tick < $1.tick }
            var built = [TimeSegment(startTick: 0, startBar: 1, startBeat: 1.0, signature: defaultSignature)]
            for change in ordered {
                if change.tick == 0 {
                    built[0] = TimeSegment(startTick: 0, startBar: 1, startBeat: 1.0, signature: change.signature)
                } else {
                    let location = try Self.location(of: change.tick, segments: built, ticksPerQuarter: ticksPerQuarter)
                    built.append(TimeSegment(
                        startTick: change.tick,
                        startBar: location.bar,
                        startBeat: location.beat,
                        signature: change.signature
                    ))
                }
            }
            segments = built
        }

        func note(from raw: RawNote) throws -> Note {
            let location = try Self.location(of: raw.startTick, segments: segments, ticksPerQuarter: ticksPerQuarter)
            let durationBeats = try Self.durationBeats(
                from: raw.startTick,
                to: raw.endTick,
                segments: segments,
                ticksPerQuarter: ticksPerQuarter
            )
            return Note(
                pitch: raw.pitch,
                velocity: raw.velocity,
                startBar: location.bar,
                startBeat: location.beat,
                durationBeats: durationBeats,
                channel: raw.channel
            )
        }

        private static func durationBeats(
            from startTick: Int,
            to endTick: Int,
            segments: [TimeSegment],
            ticksPerQuarter: Int
        ) throws -> Double {
            guard endTick >= startTick else { throw SMFReaderError.malformedEvent }
            var current = startTick
            var total = 0.0
            while current < endTick {
                let segment = segments.last { $0.startTick <= current } ?? segments[0]
                let nextChange = segments.first { $0.startTick > current }?.startTick ?? endTick
                let segmentEnd = min(endTick, nextChange)
                total += Double(segmentEnd - current) / (try segment.signature.ticksPerBeat(ticksPerQuarter))
                current = segmentEnd
            }
            return total
        }

        private static func location(
            of tick: Int,
            segments: [TimeSegment],
            ticksPerQuarter: Int
        ) throws -> (bar: Int, beat: Double, signature: TimeSignature) {
            let segment = segments.last { $0.startTick <= tick } ?? segments[0]
            let ticksPerBeat = try segment.signature.ticksPerBeat(ticksPerQuarter)
            let beatIndex = segment.startBeat - 1.0 + Double(tick - segment.startTick) / ticksPerBeat
            let barOffset = Int(floor(beatIndex / Double(segment.signature.numerator)))
            let beat = 1.0 + beatIndex - Double(barOffset * segment.signature.numerator)
            return (segment.startBar + barOffset, beat, segment.signature)
        }
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index == bytes.count }
    var remaining: Int { bytes.count - index }

    mutating func expect(_ expected: [UInt8]) throws {
        guard try readBytes(expected.count) == expected else { throw SMFReaderError.malformedHeader }
    }

    mutating func readByte() throws -> UInt8 {
        guard index < bytes.count else { throw SMFReaderError.malformedEvent }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw SMFReaderError.malformedEvent }
        guard remaining >= count else { throw SMFReaderError.truncatedEvent }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    mutating func skip(_ count: Int) throws {
        _ = try readBytes(count)
    }

    mutating func readUInt16() throws -> UInt16 {
        let raw = try readBytes(2)
        return (UInt16(raw[0]) << 8) | UInt16(raw[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let raw = try readBytes(4)
        return (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
    }

    mutating func readVLQ() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try readByte()
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw SMFReaderError.malformedVLQ
    }
}
