import Testing
import Foundation
@testable import LogicProMCP

@Test func testSMFReaderParsesRunningStatus() throws {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x64,
            0x81, 0x70, 0x40, 0x5A,
            0x81, 0x70, 0x3C, 0x00,
            0x00, 0x40, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let notes = try SMFReader.parse(data)

    #expect(notes.count == 2)
    #expect(notes[0] == SMFReader.Note(pitch: 60, velocity: 100, startBar: 1, startBeat: 1.0, durationBeats: 1.0, channel: 1))
    #expect(notes[1] == SMFReader.Note(pitch: 64, velocity: 90, startBar: 1, startBeat: 1.5, durationBeats: 0.5, channel: 1))
}

@Test func testSMFReaderTreatsVelocityZeroNoteOnAsNoteOff() throws {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x40,
            0x83, 0x60, 0x90, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let note = try #require(try SMFReader.parse(data).first)

    #expect(note.pitch == 60)
    #expect(note.velocity == 64)
    #expect(note.durationBeats == 1.0)
}

@Test func testSMFReaderKeepsSamePitchOverlapsSeparate() throws {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x64,
            0x81, 0x70, 0x90, 0x3C, 0x50,
            0x81, 0x70, 0x80, 0x3C, 0x00,
            0x81, 0x70, 0x80, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let notes = try SMFReader.parse(data)

    #expect(notes.count == 2)
    #expect(notes[0].pitch == 60)
    #expect(notes[0].velocity == 100)
    #expect(notes[0].startBeat == 1.0)
    #expect(notes[0].durationBeats == 1.0)
    #expect(notes[1].pitch == 60)
    #expect(notes[1].velocity == 80)
    #expect(notes[1].startBeat == 1.5)
    #expect(notes[1].durationBeats == 1.0)
}

@Test func testSMFReaderKeepsZeroLengthNoteBetweenOtherNotes() throws {
    // #1031: a Note Off landing on its Note On's tick (zero-length note --
    // e.g. a drum trigger) must not reject the whole file. Names the
    // pre-#1031 guard (`tick > start.tick`) it kills: reverting SMFReader.swift's
    // note-off guard to that strict form throws malformedEvent on the middle
    // note and fails this test.
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x64,
            0x83, 0x60, 0x80, 0x3C, 0x00,
            0x00, 0x90, 0x3E, 0x50,
            0x00, 0x80, 0x3E, 0x00,
            0x81, 0x70, 0x90, 0x40, 0x5A,
            0x81, 0x70, 0x80, 0x40, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let notes = try SMFReader.parse(data)

    #expect(notes.count == 3)
    #expect(notes[0] == SMFReader.Note(pitch: 60, velocity: 100, startBar: 1, startBeat: 1.0, durationBeats: 1.0, channel: 1))
    #expect(notes[1] == SMFReader.Note(pitch: 62, velocity: 80, startBar: 1, startBeat: 2.0, durationBeats: 0.0, channel: 1))
    #expect(notes[2] == SMFReader.Note(pitch: 64, velocity: 90, startBar: 1, startBeat: 2.5, durationBeats: 0.5, channel: 1))
}

@Test func testSMFReaderRejectsSMPTEDivision() {
    let data = smfData(division: 0xE250, tracks: [
        trackData([0x00, 0xFF, 0x2F, 0x00]),
    ])

    #expect(throws: SMFReaderError.self) {
        try SMFReader.parse(data)
    }
}

@Test func testSMFReaderRejectsVLQAndTrackLengthBounds() {
    let oversizedVLQ = smfData(tracks: [
        trackData([
            0x81, 0x80, 0x80, 0x80, 0x00, 0x90, 0x3C, 0x64,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])
    let overstatedTrackLength = smfDataWithRawTrackLength(
        declaredTrackLength: 9,
        trackBytes: [0x00, 0xFF, 0x2F, 0x00]
    )

    #expect(throws: SMFReaderError.self) {
        try SMFReader.parse(oversizedVLQ)
    }
    #expect(throws: SMFReaderError.self) {
        try SMFReader.parse(overstatedTrackLength)
    }
}

@Test func testSMFReaderRequiresEndOfTrackEvent() {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x40,
            0x83, 0x60, 0x80, 0x3C, 0x00,
        ]),
    ])

    expectSMFReaderError(.missingEndOfTrack, parsing: data)
}

@Test func testSMFReaderRejectsEndOfTrackWithPayload() {
    let data = smfData(tracks: [
        trackData([
            0x00, 0xFF, 0x2F, 0x01, 0x00,
        ]),
    ])

    expectSMFReaderError(.badEndOfTrackLength, parsing: data)
}

@Test func testSMFReaderRejectsEventBytesAfterEndOfTrack() {
    let data = smfData(tracks: [
        trackData([
            0x00, 0xFF, 0x2F, 0x00,
            0x00, 0x90, 0x3C, 0x40,
            0x83, 0x60, 0x80, 0x3C, 0x00,
        ]),
    ])

    expectSMFReaderError(.eventAfterEndOfTrack, parsing: data)
}

@Test func testSMFReaderRejectsEventPayloadTruncatedAtTrackEnd() {
    let data = smfData(tracks: [
        trackData([
            0x00, 0xFF, 0x01, 0x02, 0x7F,
        ]),
    ])

    expectSMFReaderError(.truncatedEvent, parsing: data)
}

@Test func testSMFReaderUsesFractionalTicksPerBeat() throws {
    let data = smfData(division: 1, tracks: [
        trackData([
            0x00, 0xFF, 0x58, 0x04, 0x06, 0x03, 0x18, 0x08,
            0x00, 0x90, 0x3C, 0x40,
            0x01, 0x80, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let note = try #require(try SMFReader.parse(data).first)

    #expect(note.durationBeats == 2.0)
}

@Test func testSMFReaderIntegratesDurationAcrossTimeSignatureChanges() throws {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x40,
            0x83, 0x60, 0xFF, 0x58, 0x04, 0x06, 0x03, 0x18, 0x08,
            0x83, 0x60, 0x80, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let note = try #require(try SMFReader.parse(data).first)

    #expect(note.durationBeats == 3.0)
}

@Test func testSMFReaderMergesFormat1TempoAndTimeSignatureTrack() throws {
    let tempoAndMeterTrack = trackData([
        0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
        0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08,
        0x00, 0xFF, 0x2F, 0x00,
    ])
    let notesTrack = trackData([
        0x8B, 0x20, 0x91, 0x3E, 0x5A,
        0x83, 0x60, 0x81, 0x3E, 0x00,
        0x00, 0xFF, 0x2F, 0x00,
    ])
    let data = smfData(format: 1, tracks: [tempoAndMeterTrack, notesTrack])

    let note = try #require(try SMFReader.parse(data).first)

    #expect(note.pitch == 62)
    #expect(note.startBar == 2)
    #expect(note.startBeat == 1.0)
    #expect(note.durationBeats == 1.0)
    #expect(note.channel == 2)
}

@Test func testSMFReaderOutputsOneBasedChannels() throws {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x92, 0x3C, 0x64,
            0x83, 0x60, 0x82, 0x3C, 0x00,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    let note = try #require(try SMFReader.parse(data).first)

    #expect(note.channel == 3)
}

@Test func testSMFReaderFailsClosedOnMalformedFileWithoutPartialResults() {
    let data = smfData(tracks: [
        trackData([
            0x00, 0x90, 0x3C, 0x64,
            0x83, 0x60, 0x80, 0x3C, 0x00,
            0x00, 0x90, 0x40, 0x64,
            0x00, 0xFF, 0x2F, 0x00,
        ]),
    ])

    #expect(throws: SMFReaderError.self) {
        try SMFReader.parse(data)
    }
}

@Test func testSMFReaderRoundTripsSMFWriterOutput() throws {
    let generated = try SMFWriter.generate(
        events: [
            SMFWriter.NoteEvent(pitch: 60, offsetTicks: 0, durationTicks: 480, velocity: 100, channel: 0),
            SMFWriter.NoteEvent(pitch: 64, offsetTicks: 240, durationTicks: 240, velocity: 90, channel: 1),
        ],
        bar: 2,
        tempo: 120,
        timeSignature: (4, 4)
    )

    let notes = try SMFReader.parse(generated)

    #expect(notes.count == 2)
    #expect(notes[0] == SMFReader.Note(pitch: 60, velocity: 100, startBar: 2, startBeat: 1.0, durationBeats: 1.0, channel: 1))
    #expect(notes[1] == SMFReader.Note(pitch: 64, velocity: 90, startBar: 2, startBeat: 1.5, durationBeats: 0.5, channel: 2))
}

private func smfData(
    format: Int = 0,
    division: Int = 480,
    tracks: [[UInt8]]
) -> Data {
    var data = Data()
    data.append(contentsOf: [0x4D, 0x54, 0x68, 0x64])
    data.append(contentsOf: uint32BEForSMFReaderTests(6))
    data.append(contentsOf: uint16BEForSMFReaderTests(format))
    data.append(contentsOf: uint16BEForSMFReaderTests(tracks.count))
    data.append(contentsOf: uint16BEForSMFReaderTests(division))
    for track in tracks {
        data.append(contentsOf: track)
    }
    return data
}

private func smfDataWithRawTrackLength(
    declaredTrackLength: Int,
    trackBytes: [UInt8]
) -> Data {
    var data = smfData(tracks: [])
    data.replaceSubrange(10..<12, with: uint16BEForSMFReaderTests(1))
    data.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B])
    data.append(contentsOf: uint32BEForSMFReaderTests(declaredTrackLength))
    data.append(contentsOf: trackBytes)
    return data
}

private func trackData(_ events: [UInt8]) -> [UInt8] {
    [0x4D, 0x54, 0x72, 0x6B] + uint32BEForSMFReaderTests(events.count) + events
}

private func expectSMFReaderError(_ expected: SMFReaderError, parsing data: Data) {
    do {
        _ = try SMFReader.parse(data)
        Issue.record("Expected SMFReaderError.\(expected)")
    } catch let error as SMFReaderError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected SMFReaderError.\(expected), got \(error)")
    }
}

private func uint16BEForSMFReaderTests(_ value: Int) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func uint32BEForSMFReaderTests(_ value: Int) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
}
