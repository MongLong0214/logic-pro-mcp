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

/// #1040: the MCU Mute LED is not the track header's Mute checkbox (Logic lights it on a track a
/// solo silences), so it writes no track state: a Mute read off stays off, an unread one stays unread.
@Test func testFeedbackParserLeavesMuteToTheHeader() async throws {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateChannelStrips((0..<8).map { ChannelStripState(trackIndex: $0) })
    var rows = (0..<8).map { TrackState(id: $0, name: "Track \($0)", type: .audio) }
    rows[2].isMuted = false
    await cache.updateTracks(rows)

    await parser.handle(MIDIFeedback.Event.noteOn(channel: 0, note: 0x12, velocity: 0x7F))
    await parser.handle(MIDIFeedback.Event.noteOn(channel: 0, note: 0x13, velocity: 0x7F))

    let tracks = await cache.getTracks()
    let track2Muted = try #require(tracks[2].isMuted)
    #expect(!track2Muted)
    let track3Unread = tracks[3].isMuted.map { _ in false } ?? true
    #expect(track3Unread)
}

@Test func testFeedbackParserUpdatesSoloState() async throws {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks((0..<8).map { TrackState(id: $0, name: "Track \($0)", type: .audio) })

    let event = MIDIFeedback.Event.noteOn(channel: 0, note: 0x0A, velocity: 0x7F)
    await parser.handle(event)

    let tracks = await cache.getTracks()
    let track2Soloed = try #require(tracks[2].isSoloed)
    #expect(track2Soloed)
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
    #expect(updated.isConnected)
    #expect(updated.lastFeedbackAt != nil)
    #expect(updated.registeredAsDevice)
}

@Test func testFeedbackParserBankOffsetApplied() async throws {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)

    // 16 tracks, bank 1 (offset 8)
    await cache.updateTracks((0..<16).map { TrackState(id: $0, name: "Track \($0)", type: .audio, isMuted: false, isSoloed: false, isArmed: false) })
    await parser.setBankOffsetProvider { 1 } // bank 1 → offset 8

    // Solo strip 0 should map to track 8 (not track 0). Solo, because the Mute LED writes no
    // track state (#1040).
    let event = MIDIFeedback.Event.noteOn(channel: 0, note: 0x08, velocity: 0x7F)
    await parser.handle(event)

    let tracks = await cache.getTracks()
    let track0Soloed = try #require(tracks[0].isSoloed)
    #expect(!track0Soloed) // track 0 untouched
    let track8Soloed = try #require(tracks[8].isSoloed)
    #expect(track8Soloed)  // track 8 soloed
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

@Test func testFeedbackParserHandlesNoteOffForSelectAndLeavesTheArmAlone() async throws {
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
    // A dark Rec LED is half of Logic's blink on an armed track, not a disarm (#1020).
    let track0Armed = try #require(tracks[0].isArmed)
    #expect(track0Armed)
    #expect(!(tracks[1].isSelected))
}

/// Logic blinks an armed track's Rec LED. Replayed as the frames it sends, the cached arm state has to
/// hold through every dark frame, and a lit frame on a disarmed track does not arm it either: the arm
/// state is the poller's reading of the checkbox (#1020).
@Test func testFeedbackParserRecArmBlinkDoesNotMoveTheCachedArm() async throws {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks((0..<2).map { index in
        var track = TrackState(id: index, name: "Track \(index)", type: .audio)
        track.isArmed = index == 0
        return track
    })

    for frame in 0..<6 {
        let lit: UInt8 = frame % 2 == 0 ? 0x7F : 0x00
        await parser.handle(.noteOn(channel: 0, note: 0x00, velocity: lit))
        await parser.handle(.noteOn(channel: 0, note: 0x01, velocity: lit))
        let tracks = await cache.getTracks()
        let track0Armed = try #require(tracks[0].isArmed, "frame \(frame)")
        #expect(track0Armed, "frame \(frame)")
        let track1Armed = try #require(tracks[1].isArmed, "frame \(frame)")
        #expect(!track1Armed, "frame \(frame)")
    }
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
        #expect(i == 2 ? track.isSelected : !track.isSelected, "track \(i) selection mismatch")
    }
    #expect(await cache.getSelectedTrack()?.id == 2)

    // A subsequent on-event for a different strip must transfer selection,
    // not add a second selected track.
    await parser.handle(.noteOn(channel: 0, note: 0x1D, velocity: 0x7F))
    let after = await cache.getTracks()
    #expect(after.filter { $0.isSelected }.count == 1)
    #expect(after[5].isSelected)
}

@Test(arguments: [false, true])
func testFeedbackSelectionCannotPreserveAXReadProvenance(on: Bool) async throws {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks([TrackState(id: 0, name: "Observed", type: .audio,
                                        isSelected: true, selectionReadback: true)])
    await parser.handle(.noteOn(channel: 0, note: 0x18, velocity: on ? 0x7F : 0))
    let track = try #require(await cache.getTracks().first)
    #expect(track.selectionReadback == nil)
    if on { #expect(track.isSelected) } else { #expect(!track.isSelected) }
}

@Test func testFeedbackParserIgnoresControlChangeAndDefaultEventsAfterUpdatingConnection() async throws {
    let cache = StateCache()
    let parser = MCUFeedbackParser(cache: cache)
    await cache.updateTracks([TrackState(id: 0, name: "Track 0", type: .audio, isMuted: false, isSoloed: false, isArmed: false)])
    var initialConn = await cache.getMCUConnection()
    initialConn.portName = "LogicProMCP-MCU-Internal"
    await cache.updateMCUConnection(initialConn)

    await parser.handle(.controlChange(channel: 0, controller: 0x10, value: 0x20))
    await parser.handle(.programChange(channel: 0, program: 0x01))

    let conn = await cache.getMCUConnection()
    let tracks = await cache.getTracks()
    #expect(conn.isConnected)
    #expect(conn.lastFeedbackAt != nil)
    #expect(conn.registeredAsDevice)
    let track0Muted = try #require(tracks[0].isMuted)
    #expect(!track0Muted)
    let track0Soloed = try #require(tracks[0].isSoloed)
    #expect(!track0Soloed)
}
