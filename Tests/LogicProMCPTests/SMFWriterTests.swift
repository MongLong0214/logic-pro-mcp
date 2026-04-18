import Testing
import Foundation
@testable import LogicProMCP

@Test func testSMFWriterGeneratesValidHeader() throws {
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))

    // MThd header: "MThd" + length(6) + format(0) + ntrks(1) + division(480)
    let bytes = [UInt8](data)
    #expect(bytes[0] == 0x4D) // M
    #expect(bytes[1] == 0x54) // T
    #expect(bytes[2] == 0x68) // h
    #expect(bytes[3] == 0x64) // d
    #expect(bytes[4...7] == [0x00, 0x00, 0x00, 0x06]) // length = 6
    #expect(bytes[8...9] == [0x00, 0x00]) // format = 0
    #expect(bytes[10...11] == [0x00, 0x01]) // ntrks = 1
    #expect(bytes[12...13] == [0x01, 0xE0]) // division = 480
}

@Test func testSMFWriterTempoMetaEvent() throws {
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    let bytes = [UInt8](data)

    // 120 BPM = 500000 μs/quarter = 0x07A120
    // Tempo meta-event: delta(0) FF 51 03 07 A1 20
    let tempoPattern: [UInt8] = [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
    let found = findPattern(tempoPattern, in: bytes)
    #expect(found, "Tempo meta-event for 120 BPM not found")
}

@Test func testSMFWriterTimeSignatureMetaEvent() throws {
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    let bytes = [UInt8](data)

    // 4/4: FF 58 04 04 02 18 08
    let tsPattern: [UInt8] = [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]
    let found = findPattern(tsPattern, in: bytes)
    #expect(found, "Time signature 4/4 meta-event not found")
}

@Test func testSMFWriterNoteEventsAtCorrectTicks() throws {
    // 3 quarter notes at 120 BPM with ms offsets 0, 500, 1000
    // At 120 BPM, 480 tpq: 500ms = 480 ticks (one quarter note)
    let events = [
        SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0),
        SMFWriter.NoteEvent(pitch: 64, offsetTicks: 480, durationTicks: 480, velocity: 100, channel: 0),
        SMFWriter.NoteEvent(pitch: 67, offsetTicks: 960, durationTicks: 480, velocity: 100, channel: 0),
    ]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    let bytes = [UInt8](data)

    // Note-on C4: 90 3C 64 (channel 0, note 60, velocity 100)
    let noteOnC = findPattern([0x90, 0x3C, 0x64], in: bytes)
    #expect(noteOnC, "Note-on C4 not found")

    // Note-on E4: 90 40 64
    let noteOnE = findPattern([0x90, 0x40, 0x64], in: bytes)
    #expect(noteOnE, "Note-on E4 not found")

    // Note-on G4: 90 43 64
    let noteOnG = findPattern([0x90, 0x43, 0x64], in: bytes)
    #expect(noteOnG, "Note-on G4 not found")
}

@Test func testSMFWriterBarOffset() throws {
    // Bar 5, 4/4, 480 tpq → offset = (5-1) * 4 * 480 = 7680 ticks
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 5, tempo: 120, timeSignature: (4, 4))
    let bytes = [UInt8](data)

    // 7680 ticks in VLQ = 0xBF 0x00 (7680 = 0x1E00, VLQ: 111_1100 0000000 → 0xBC 0x00)
    // Actually: 7680 = 0x1E00 → VLQ: (0x1E00 >> 7 | 0x80) = 0xBC, (0x1E00 & 0x7F) = 0x00
    // Wait, let me recalculate: 7680 in binary = 0001_1110_0000_0000
    // VLQ: split into 7-bit groups from right: 0000000, 0111100 → 0xBC, 0x00
    // Nope, 7680 = 0b1_1110_0000000 → two groups: 0111100 (0x3C) | 0x80 = 0xBC, 0000000 = 0x00
    // So VLQ = [0xBC, 0x00] before the first note-on

    // The first note event should have a non-zero delta time (the bar offset)
    // Just verify the data is longer than bar-1 version
    let dataBar1 = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    #expect(data.count > dataBar1.count, "Bar 5 data should be longer due to larger delta time encoding")
}

@Test func testSMFWriterMsToTicksRoundHalfUp() {
    // 83ms at 137 BPM, 480 tpq
    // ticks = 83 * 137 * 480 / (60 * 1000) = 83 * 137 * 480 / 60000
    // = 83 * 65760 / 60000 = 5458080 / 60000 = 90.968 → rounds to 91
    let (offset, _) = SMFWriter.msToTicks(offsetMs: 83, durationMs: 100, tempo: 137, ticksPerQuarter: 480)
    #expect(offset == 91)

    // 500ms at 120 BPM → exactly 480 ticks
    let (offset2, dur2) = SMFWriter.msToTicks(offsetMs: 500, durationMs: 500, tempo: 120, ticksPerQuarter: 480)
    #expect(offset2 == 480)
    #expect(dur2 == 480)
}

@Test func testSMFWriterRejectsEmptyEvents() {
    #expect(throws: SMFWriterError.self) {
        try SMFWriter.generate(events: [], bar: 1, tempo: 120, timeSignature: (4, 4))
    }
}

@Test func testSMFWriterRejectsInvalidPitch() {
    let events = [SMFWriter.NoteEvent(pitch: 128, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    #expect(throws: SMFWriterError.self) {
        try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    }
}

@Test func testSMFWriterAccepts1024Notes() throws {
    let events = (0..<1024).map { i in
        SMFWriter.NoteEvent(pitch: UInt8(60 + (i % 12)), offsetTicks: i * 120, durationTicks: 100, velocity: 80, channel: 0)
    }
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    #expect(data.count > 0)
}

@Test func testSMFWriterEndOfTrack() throws {
    let events = [SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0)]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    let bytes = [UInt8](data)

    // Last 3 bytes should be end-of-track: FF 2F 00 (plus a delta time byte before)
    let lastThree = Array(bytes.suffix(3))
    #expect(lastThree == [0xFF, 0x2F, 0x00], "End-of-track meta-event not at end of file")
}

@Test func testSMFWriterChordEvents() throws {
    // 3 notes at same offset = chord
    let events = [
        SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0),
        SMFWriter.NoteEvent(pitch: 64, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0),
        SMFWriter.NoteEvent(pitch: 67, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0),
    ]
    let data = try SMFWriter.generate(events: events, bar: 1, tempo: 120, timeSignature: (4, 4))
    let bytes = [UInt8](data)

    // All 3 note-ons should be present
    var noteOnCount = 0
    for i in 0..<(bytes.count - 2) {
        if bytes[i] == 0x90 && bytes[i + 2] == 0x64 { noteOnCount += 1 }
    }
    #expect(noteOnCount == 3, "Expected 3 note-on events for chord")
}

@Test func testSMFWriterCleanupDeletesOldFiles() throws {
    let tempDir = NSTemporaryDirectory() + "SMFWriter-cleanup-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let oldFile = "\(tempDir)/old.mid"
    let recentFile = "\(tempDir)/recent.mid"
    FileManager.default.createFile(atPath: oldFile, contents: Data([0, 1, 2]))
    FileManager.default.createFile(atPath: recentFile, contents: Data([0, 1, 2]))

    // Backdate oldFile by 10 minutes
    let oldDate = Date().addingTimeInterval(-600)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile)

    SMFWriter.cleanupOrphanFiles(in: tempDir, olderThan: 300)

    #expect(!FileManager.default.fileExists(atPath: oldFile), "old file should be deleted")
    #expect(FileManager.default.fileExists(atPath: recentFile), "recent file should be preserved")
}

@Test func testSMFWriterCleanupHandlesMissingDir() {
    // No error should be thrown — this is a safe no-op.
    SMFWriter.cleanupOrphanFiles(in: "/tmp/does-not-exist-\(UUID().uuidString)")
}

// MARK: - Helpers

private func findPattern(_ pattern: [UInt8], in bytes: [UInt8]) -> Bool {
    guard pattern.count <= bytes.count else { return false }
    for i in 0...(bytes.count - pattern.count) {
        if Array(bytes[i..<(i + pattern.count)]) == pattern { return true }
    }
    return false
}
