import Testing
@testable import LogicProMCP

@Test func testFeedbackParserUpdatesFaderState() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateChannelStrips((0..<8).map { ChannelStripState(trackIndex: $0) })

    let value: UInt16 = 8192
    let event = MIDIFeedback.Event.pitchBend(channel: 2, value: value)
    await parser.handle(event)

    let strips = await cache.getChannelStrips()
    #expect(abs(strips[2].volume - 0.5) < 0.01)
}

@Test func testFeedbackParserUpdatesMuteState() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateChannelStrips((0..<8).map { ChannelStripState(trackIndex: $0) })
    await cache.updateTracks((0..<8).map { TrackState(id: $0, name: "Track \($0)", type: .audio) })

    let event = MIDIFeedback.Event.noteOn(channel: 0, note: 0x12, velocity: 0x7F)
    await parser.handle(event)

    let tracks = await cache.getTracks()
    #expect(tracks[2].isMuted == true)
}

@Test func testFeedbackParserUpdatesSoloState() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks((0..<8).map { TrackState(id: $0, name: "Track \($0)", type: .audio) })

    let event = MIDIFeedback.Event.noteOn(channel: 0, note: 0x0A, velocity: 0x7F)
    await parser.handle(event)

    let tracks = await cache.getTracks()
    #expect(tracks[2].isSoloed == true)
}

@Test func testFeedbackParserParsesLCD() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateChannelStrips((0..<8).map { ChannelStripState(trackIndex: $0) })

    let sysex: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00,
                          0x56, 0x6F, 0x63, 0x61, 0x6C, 0x73, 0x20,
                          0xF7]
    let event = MIDIFeedback.Event.sysEx(sysex)
    await parser.handle(event)

    let display = await cache.getMCUDisplay()
    #expect(display.upperRow.hasPrefix("Vocals"))
}

@Test func testFeedbackParserUpdatesConnectionState() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    var conn = await cache.getMCUConnection()
    conn.portName = "LogicProMCP-MCU-Internal"
    await cache.updateMCUConnection(conn)

    let event = MIDIFeedback.Event.noteOn(channel: 0, note: 0x5E, velocity: 0x7F)
    await parser.handle(event)

    let updated = await cache.getMCUConnection()
    #expect(updated.isConnected == true)
    #expect(updated.lastFeedbackAt != nil)
    #expect(updated.registeredAsDevice == true)
}

@Test func testFeedbackParserBankOffsetApplied() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)

    // 16 tracks, bank 1 (offset 8)
    await cache.updateTracks((0..<16).map { TrackState(id: $0, name: "Track \($0)", type: .audio) })
    await parser.setBankOffsetProvider { 1 } // bank 1 → offset 8

    // Mute strip 0 should map to track 8 (not track 0)
    let event = MIDIFeedback.Event.noteOn(channel: 0, note: 0x10, velocity: 0x7F)
    await parser.handle(event)

    let tracks = await cache.getTracks()
    #expect(tracks[0].isMuted == false) // track 0 untouched
    #expect(tracks[8].isMuted == true)  // track 8 muted
}

@Test func testFeedbackParserFaderBankOffset() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)

    await cache.updateChannelStrips((0..<16).map { ChannelStripState(trackIndex: $0) })
    await parser.setBankOffsetProvider { 1 } // bank 1 → offset 8

    // PitchBend ch0 at bank 1 → should update strip 8
    let event = MIDIFeedback.Event.pitchBend(channel: 0, value: 8192)
    await parser.handle(event)

    let strips = await cache.getChannelStrips()
    #expect(strips[0].volume == 0.0) // strip 0 untouched
    #expect(abs(strips[8].volume - 0.5) < 0.01) // strip 8 updated
}

@Test func testFeedbackParserHandlesNoteOffForRecArmAndSelect() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks((0..<8).map { index in
        var track = TrackState(id: index, name: "Track \(index)", type: .audio)
        track.isArmed = true
        track.isSelected = true
        return track
    })

    await parser.handle(.noteOff(channel: 0, note: 0x00, velocity: 0))
    await parser.handle(.noteOff(channel: 0, note: 0x19, velocity: 0))

    let tracks = await cache.getTracks()
    #expect(tracks[0].isArmed == false)
    #expect(tracks[1].isSelected == false)
}

@Test func testFeedbackParserSelectOnEnforcesSingleSelection() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)

    // Pre-populate with a stale multi-selection that must be cleared the
    // moment Logic Pro reports a new select event.
    await cache.updateTracks((0..<8).map { index in
        var track = TrackState(id: index, name: "Track \(index)", type: .audio)
        track.isSelected = (index == 0 || index == 3)
        return track
    })

    // Note 0x1A = select button on strip 2, velocity 0x7F = "on".
    await parser.handle(.noteOn(channel: 0, note: 0x1A, velocity: 0x7F))

    let tracks = await cache.getTracks()
    for (i, track) in tracks.enumerated() {
        #expect(track.isSelected == (i == 2), "track \(i) selection mismatch")
    }
    #expect(await cache.getSelectedTrack()?.id == 2)

    // A subsequent on-event for a different strip must transfer selection,
    // not add a second selected track.
    await parser.handle(.noteOn(channel: 0, note: 0x1D, velocity: 0x7F))
    let after = await cache.getTracks()
    #expect(after.filter { $0.isSelected }.count == 1)
    #expect(after[5].isSelected == true)
}

@Test func testFeedbackParserIgnoresControlChangeAndDefaultEventsAfterUpdatingConnection() async {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks([TrackState(id: 0, name: "Track 0", type: .audio)])
    var initialConn = await cache.getMCUConnection()
    initialConn.portName = "LogicProMCP-MCU-Internal"
    await cache.updateMCUConnection(initialConn)

    await parser.handle(.controlChange(channel: 0, controller: 0x10, value: 0x20))
    await parser.handle(.programChange(channel: 0, program: 0x01))

    let conn = await cache.getMCUConnection()
    let tracks = await cache.getTracks()
    #expect(conn.isConnected == true)
    #expect(conn.lastFeedbackAt != nil)
    #expect(conn.registeredAsDevice == true)
    #expect(tracks[0].isMuted == false)
    #expect(tracks[0].isSoloed == false)
}
