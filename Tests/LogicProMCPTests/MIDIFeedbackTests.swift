import Testing
@testable import LogicProMCP

@Test func testMIDIFeedbackNormalParsing() {
    // Note On: 0x90 ch0, note 0x3C, vel 0x7F
    let bytes: [UInt8] = [0x90, 0x3C, 0x7F]
    let events = MIDIFeedback.parseBytes(bytes)
    #expect(events.count == 1)
    if case .noteOn(let ch, let note, let vel) = events.first {
        #expect(ch == 0)
        #expect(note == 0x3C)
        #expect(vel == 0x7F)
    } else {
        Issue.record("Expected noteOn")
    }
}

@Test func testMIDIFeedbackRunningStatus() {
    // Running status: Note On ch0, then data bytes without status
    // 0x90 0x3C 0x7F 0x3E 0x60 (second note reuses 0x90 status)
    let bytes: [UInt8] = [0x90, 0x3C, 0x7F, 0x3E, 0x60]
    let events = MIDIFeedback.parseBytes(bytes)
    #expect(events.count == 2)
    if case .noteOn(_, let note1, _) = events[0] {
        #expect(note1 == 0x3C)
    }
    if case .noteOn(_, let note2, let vel2) = events[1] {
        #expect(note2 == 0x3E)
        #expect(vel2 == 0x60)
    } else {
        Issue.record("Expected second noteOn from running status")
    }
}

@Test func testSendSysExValidation() {
    // SysEx with invalid middle byte (>= 0x80) should be rejected
    let engine = MIDIEngine()
    // We can't directly test rejection without running, but we can test
    // the protocol-level validation
    let validSysEx: [UInt8] = [0xF0, 0x00, 0x01, 0x7F, 0xF7]
    let invalidMiddle: [UInt8] = [0xF0, 0x00, 0x80, 0x01, 0xF7]  // 0x80 invalid in SysEx body
    let noF0: [UInt8] = [0x00, 0x01, 0xF7]
    let noF7: [UInt8] = [0xF0, 0x00, 0x01]

    #expect(MCUProtocol.isValidSysEx(validSysEx) == true)
    #expect(MCUProtocol.isValidSysEx(invalidMiddle) == false)
    #expect(MCUProtocol.isValidSysEx(noF0) == false)
    #expect(MCUProtocol.isValidSysEx(noF7) == false)
}
