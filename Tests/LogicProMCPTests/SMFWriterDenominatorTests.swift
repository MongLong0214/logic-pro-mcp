import Testing
import Foundation
@testable import LogicProMCP

// MARK: - SMF parsing helpers

/// Decode the absolute tick of the first note-on (0x90|ch) in a single-track
/// SMF produced by `SMFWriter.generate`. Walks the MTrk event stream honestly
/// (VLQ delta + explicit-status events; SMFWriter never uses running status),
/// so the assertion pins the real encoded bar offset, not a byte pattern.
private func firstNoteOnTick(in data: Data) -> Int? {
    let bytes = [UInt8](data)
    // MThd (14) + MTrk header "MTrk" + 4-byte length (8) → track data at offset 22.
    var i = 22
    guard bytes.count > i else { return nil }
    var tick = 0

    func readVLQ() -> Int? {
        var value = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            value = (value << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { return value }
        }
        return nil
    }

    while i < bytes.count {
        guard let delta = readVLQ() else { return nil }
        tick += delta
        guard i < bytes.count else { return nil }
        let status = bytes[i]
        if status == 0xFF {
            // Meta: FF <type> <len VLQ> <data>
            i += 2
            guard let len = readVLQ() else { return nil }
            i += len
        } else if status & 0xF0 == 0x90 {
            return tick  // first note-on's absolute tick
        } else if [0x80, 0xA0, 0xB0, 0xE0].contains(status & 0xF0) {
            i += 3  // status + 2 data bytes
        } else if [0xC0, 0xD0].contains(status & 0xF0) {
            i += 2  // status + 1 data byte
        } else {
            return nil
        }
    }
    return nil
}

private func containsPattern(_ pattern: [UInt8], in bytes: [UInt8]) -> Bool {
    guard pattern.count <= bytes.count, !pattern.isEmpty else { return false }
    for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<(i + pattern.count)]) == pattern {
        return true
    }
    return false
}

// MARK: - Denominator-aware bar offset (AC3)

@Test func testSMFWriter68BarOffsetUsesDenominatorAwareBeat() throws {
    // 6/8, bar 2, 480 tpq: ticksPerBeat = 480*4/8 = 240; barOffset = (2-1)*6*240 = 1440.
    // The pre-fix code multiplied the offset by ticksPerQuarter (480) directly,
    // encoding 2880 — exactly 2× too far. This test is RED on the old code.
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 240, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 2, tempo: 120, timeSignature: (6, 8))
    let tick = try #require(firstNoteOnTick(in: data), "note-on not found in SMF")
    #expect(tick == 1440)
    #expect(tick != 2880)  // guard against the old 4/4-assuming value
}

@Test func testSMFWriter44BarOffsetUnchangedByDenominatorFix() throws {
    // 4/4 path stays byte-identical: ticksPerBeat = 480*4/4 = 480; barOffset = (5-1)*4*480 = 7680.
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 5, tempo: 120, timeSignature: (4, 4))
    let tick = try #require(firstNoteOnTick(in: data))
    #expect(tick == 7680)
}

@Test func testSMFWriter34BarOffsetUsesQuarterBeat() throws {
    // 3/4, bar 3, 480 tpq: ticksPerBeat = 480*4/4 = 480; barOffset = (3-1)*3*480 = 2880.
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 3, tempo: 120, timeSignature: (3, 4))
    let tick = try #require(firstNoteOnTick(in: data))
    #expect(tick == 2880)
}

@Test func testSMFWriter716BarOffset() throws {
    // 7/16, bar 2, 480 tpq: ticksPerBeat = 480*4/16 = 120; barOffset = (2-1)*7*120 = 840.
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 120, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 2, tempo: 120, timeSignature: (7, 16))
    let tick = try #require(firstNoteOnTick(in: data))
    #expect(tick == 840)
}

// MARK: - Trap guards (AC3, audit #23)

@Test func testSMFWriterZeroOrNaNBPMDoesNotTrapAndFallsBackTo120() throws {
    // Int(60_000_000 / bpm) traps for bpm ≤ 0 (Int(∞)) and NaN (Int(NaN)).
    // The guard falls back to the MIDI default 120 BPM = 500000 μs/quarter = 0x07A120.
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let tempoPattern: [UInt8] = [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]

    let zero = try SMFWriter.generate(events: events, bar: 1, tempo: 0, timeSignature: (4, 4))
    #expect(containsPattern(tempoPattern, in: [UInt8](zero)))

    let negative = try SMFWriter.generate(events: events, bar: 1, tempo: -120, timeSignature: (4, 4))
    #expect(containsPattern(tempoPattern, in: [UInt8](negative)))

    let nan = try SMFWriter.generate(events: events, bar: 1, tempo: Double.nan, timeSignature: (4, 4))
    #expect(containsPattern(tempoPattern, in: [UInt8](nan)))

    let inf = try SMFWriter.generate(events: events, bar: 1, tempo: Double.infinity, timeSignature: (4, 4))
    #expect(containsPattern(tempoPattern, in: [UInt8](inf)))
}

@Test func testSMFWriterOversizedNumeratorClampsWithoutTrapping() throws {
    // UInt8(numerator) traps for numerator > 255; UInt8(clamping:) caps at 255 (0xFF).
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (300, 4))
    // Time-signature meta with clamped numerator byte: FF 58 04 FF 02 18 08.
    #expect(containsPattern([0xFF, 0x58, 0x04, 0xFF, 0x02, 0x18, 0x08], in: [UInt8](data)))
}

@Test func testSMFWriterZeroDenominatorDoesNotDivideByZeroAndFallsBackTo4() throws {
    // ticksPerBeat = ticksPerQuarter*4/denominator divides by zero on denominator 0;
    // the guard falls back to 4 → ticksPerBeat 480 → barOffset (2-1)*4*480 = 1920.
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 2, tempo: 120, timeSignature: (4, 0))
    let tick = try #require(firstNoteOnTick(in: data))
    #expect(tick == 1920)
}
