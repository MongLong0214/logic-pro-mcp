import Testing
@testable import LogicProMCP

// WS6 / AC4 (audit-completeness P1) — MIDIFeedback System Common (0xF1-0xF6)
// and Real-Time (0xF8-0xFF) status bytes must be consumed explicitly. The
// pre-fix parser double-consumed them (i+=1 in the status branch AND i+=1 in
// the trailing default) and clobbered runningStatus with 0xFn, silently
// dropping the message that followed. These tests pin the corrected behavior;
// each is RED against the pre-fix parser.

// MARK: - Real-Time (0xF8-0xFF)

@Test func testRealtimeByteBeforeNoteOnYieldsNoteOn() {
    // AC4 canonical trace: a MIDI Clock (0xF8) immediately preceding a
    // channel-voice message must be consumed as a zero-length real-time
    // message, leaving the note-on fully intact. Pre-fix: 0 events.
    let events = MIDIFeedback.parseBytes([0xF8, 0x90, 0x3C, 0x64])
    #expect(events.count == 1)
    let event = try? #require(events.first)
    guard case .noteOn(let channel, let note, let velocity) = event else {
        Issue.record("Expected a single note-on after the 0xF8 real-time byte, got \(events)")
        return
    }
    #expect(channel == 0)
    #expect(note == 0x3C)
    #expect(velocity == 0x64)
}

@Test func testRealtimeInterleavingPreservesRunningStatus() {
    // A real-time byte (0xF8) may appear ANYWHERE, including between the data
    // bytes of a running-status stream. It must NOT reset/overwrite the
    // running status, so the trailing 0x3E 0x60 still parses as a running
    // 0x90 note-on. Pre-fix: runningStatus was clobbered to 0xF8 → 1 event.
    let events = MIDIFeedback.parseBytes([0x90, 0x3C, 0x64, 0xF8, 0x3E, 0x60])
    #expect(events.count == 2)
    guard events.count == 2 else {
        Issue.record("Real-time interleaving corrupted running status: \(events)")
        return
    }
    guard case .noteOn(_, let firstNote, _) = events[0] else {
        Issue.record("Expected first running-status note-on, got \(events[0])")
        return
    }
    guard case .noteOn(_, let secondNote, let secondVel) = events[1] else {
        Issue.record("Expected running-status note-on after the real-time byte, got \(events[1])")
        return
    }
    #expect(firstNote == 0x3C)
    #expect(secondNote == 0x3E)
    #expect(secondVel == 0x60)
}

@Test func testLoneRealtimeByteYieldsNoEvents() {
    // A stand-alone real-time byte carries no channel-voice payload; it must
    // parse to zero events (and not consume a phantom trailing byte).
    #expect(MIDIFeedback.parseBytes([0xF8]).isEmpty)
    #expect(MIDIFeedback.parseBytes([0xFE]).isEmpty)  // Active Sensing
}

// MARK: - System Common (0xF1-0xF6)

@Test func testTuneRequestDoesNotSwallowFollowingNoteOn() {
    // Tune Request (0xF6) has ZERO data bytes. The pre-fix double-consume ate
    // the following 0x90 status byte, dropping the note-on entirely (0 events).
    let events = MIDIFeedback.parseBytes([0xF6, 0x90, 0x3C, 0x64])
    #expect(events.count == 1)
    let event = try? #require(events.first)
    guard case .noteOn(_, let note, let velocity) = event else {
        Issue.record("Tune Request swallowed the following note-on: \(events)")
        return
    }
    #expect(note == 0x3C)
    #expect(velocity == 0x64)
}

@Test func testSongPositionConsumesTwoDataBytesNoteOnIntact() {
    // Song Position Pointer (0xF2) carries exactly two data bytes. They must
    // be consumed so the trailing note-on parses cleanly and no stray data
    // byte leaks through.
    let events = MIDIFeedback.parseBytes([0xF2, 0x10, 0x20, 0x90, 0x3C, 0x64])
    #expect(events.count == 1)
    let event = try? #require(events.first)
    guard case .noteOn(_, let note, let velocity) = event else {
        Issue.record("Song Position mis-consumed its data bytes: \(events)")
        return
    }
    #expect(note == 0x3C)
    #expect(velocity == 0x64)
}

@Test func testSystemCommonResetsRunningStatus() {
    // System Common resets running status (unlike Real-Time). After a
    // 0-data-byte System Common, bare data bytes with no fresh status must be
    // skipped rather than reusing the pre-common running status.
    let events = MIDIFeedback.parseBytes([0x90, 0x3C, 0x64, 0xF6, 0x3E, 0x60])
    // First note-on parses; the 0x3E 0x60 after the Tune Request are stray
    // (running status was reset) → only one event.
    #expect(events.count == 1)
    let event = try? #require(events.first)
    guard case .noteOn(_, let note, _) = event else {
        Issue.record("Expected the single pre-common note-on, got \(events)")
        return
    }
    #expect(note == 0x3C)
}
