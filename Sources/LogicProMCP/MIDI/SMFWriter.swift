import Foundation

enum SMFWriterError: Error {
    case emptyEvents
    case invalidPitch(UInt8)
    case invalidVelocity(UInt8)
}

struct SMFWriter {
    struct NoteEvent {
        let pitch: UInt8
        let offsetTicks: Int
        let durationTicks: Int
        let velocity: UInt8
        let channel: UInt8
    }

    static func generate(
        events: [NoteEvent],
        bar: Int = 1,
        tempo: Double,
        timeSignature: (numerator: Int, denominator: Int),
        ticksPerQuarter: Int = 480
    ) throws -> Data {
        guard !events.isEmpty else { throw SMFWriterError.emptyEvents }
        for e in events {
            guard e.pitch <= 127 else { throw SMFWriterError.invalidPitch(e.pitch) }
            guard e.velocity <= 127 else { throw SMFWriterError.invalidVelocity(e.velocity) }
        }

        let barOffsetTicks = (bar - 1) * timeSignature.numerator * ticksPerQuarter

        var track = Data()
        track.append(tempoMetaEvent(bpm: tempo))
        track.append(timeSignatureMetaEvent(numerator: timeSignature.numerator, denominator: timeSignature.denominator))

        // Logic Pro's MIDI File import silently STRIPS leading empty delta
        // before the first channel event — meaning a SMF where note-on is at
        // tick 17280 gets placed at bar 1 of a new region regardless of the
        // intended bar offset. Workaround: emit a harmless channel event at
        // tick 0 (CC#110 value 0 on channel 0, an undefined/unused MIDI CC
        // that has no audible or UI side effects on any standard instrument)
        // so Logic preserves the full tick timeline. The region will span
        // from bar 1 through the last note, with the caller's notes landing
        // precisely at their encoded tick positions inside the region.
        if barOffsetTicks > 0 {
            track.append(contentsOf: [0x00, 0xB0, 0x6E, 0x00])
        }

        let midiEvents = buildMIDIEvents(events: events, barOffset: barOffsetTicks)
        var lastTick = 0
        for event in midiEvents {
            let delta = max(0, event.tick - lastTick)
            track.append(contentsOf: encodeVLQ(delta))
            track.append(contentsOf: event.bytes)
            lastTick = event.tick
        }

        let endDelta = 0
        track.append(contentsOf: encodeVLQ(endDelta))
        track.append(contentsOf: [0xFF, 0x2F, 0x00])

        var data = Data()
        data.append(header(ticksPerQuarter: ticksPerQuarter))
        data.append(trackChunk(track))
        return data
    }

    /// Sweep /tmp/LogicProMCP/ for orphan .mid files older than `olderThan` seconds
    /// (default 5 min). Safe no-op when the directory doesn't exist. Errors are
    /// swallowed so server startup never blocks on cleanup failure.
    static func cleanupOrphanFiles(
        in dir: String = "/tmp/LogicProMCP",
        olderThan: TimeInterval = 300
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for name in entries where name.hasSuffix(".mid") {
            let full = "\(dir)/\(name)"
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date,
                  mtime < cutoff else { continue }
            try? fm.removeItem(atPath: full)
        }
    }

    static func msToTicks(
        offsetMs: Int,
        durationMs: Int,
        tempo: Double,
        ticksPerQuarter: Int = 480
    ) -> (offsetTicks: Int, durationTicks: Int) {
        let ticksPerMs = tempo * Double(ticksPerQuarter) / 60000.0
        let offset = Int((Double(offsetMs) * ticksPerMs) + 0.5)
        let duration = max(1, Int((Double(durationMs) * ticksPerMs) + 0.5))
        return (offset, duration)
    }

    // MARK: - Private

    private struct TimedMIDIEvent: Comparable {
        let tick: Int
        let bytes: [UInt8]
        let isNoteOff: Bool

        static func < (lhs: TimedMIDIEvent, rhs: TimedMIDIEvent) -> Bool {
            if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
            if lhs.isNoteOff != rhs.isNoteOff { return lhs.isNoteOff }
            return false
        }
    }

    private static func buildMIDIEvents(events: [NoteEvent], barOffset: Int) -> [TimedMIDIEvent] {
        var midi: [TimedMIDIEvent] = []
        for e in events {
            let onTick = barOffset + e.offsetTicks
            let offTick = onTick + e.durationTicks
            let status: UInt8 = 0x90 | (e.channel & 0x0F)
            midi.append(TimedMIDIEvent(tick: onTick, bytes: [status, e.pitch, e.velocity], isNoteOff: false))
            midi.append(TimedMIDIEvent(tick: offTick, bytes: [status, e.pitch, 0x00], isNoteOff: true))
        }
        return midi.sorted()
    }

    private static func header(ticksPerQuarter: Int) -> Data {
        var d = Data()
        d.append(contentsOf: [0x4D, 0x54, 0x68, 0x64]) // MThd
        d.append(contentsOf: uint32BE(6))                 // length
        d.append(contentsOf: uint16BE(0))                 // format 0
        d.append(contentsOf: uint16BE(1))                 // 1 track
        d.append(contentsOf: uint16BE(ticksPerQuarter))   // division
        return d
    }

    private static func trackChunk(_ trackData: Data) -> Data {
        var d = Data()
        d.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B]) // MTrk
        d.append(contentsOf: uint32BE(trackData.count))
        d.append(trackData)
        return d
    }

    private static func tempoMetaEvent(bpm: Double) -> Data {
        let microsPerQuarter = Int(60_000_000.0 / bpm)
        var d = Data()
        d.append(contentsOf: encodeVLQ(0)) // delta time 0
        d.append(0xFF)
        d.append(0x51)
        d.append(0x03)
        d.append(UInt8((microsPerQuarter >> 16) & 0xFF))
        d.append(UInt8((microsPerQuarter >> 8) & 0xFF))
        d.append(UInt8(microsPerQuarter & 0xFF))
        return d
    }

    private static func timeSignatureMetaEvent(numerator: Int, denominator: Int) -> Data {
        let denomLog2: UInt8
        switch denominator {
        case 1: denomLog2 = 0
        case 2: denomLog2 = 1
        case 4: denomLog2 = 2
        case 8: denomLog2 = 3
        case 16: denomLog2 = 4
        default: denomLog2 = 2
        }
        var d = Data()
        d.append(contentsOf: encodeVLQ(0)) // delta time 0
        d.append(0xFF)
        d.append(0x58)
        d.append(0x04)
        d.append(UInt8(numerator))
        d.append(denomLog2)
        d.append(0x18) // 24 MIDI clocks per metronome click
        d.append(0x08) // 8 thirty-second notes per quarter
        return d
    }

    static func encodeVLQ(_ value: Int) -> [UInt8] {
        guard value >= 0 else { return [0] }
        if value == 0 { return [0x00] }
        var v = value
        var result: [UInt8] = []
        result.append(UInt8(v & 0x7F))
        v >>= 7
        while v > 0 {
            result.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return result.reversed()
    }

    private static func uint16BE(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint32BE(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}
