import CoreMIDI
import Testing
@testable import LogicProMCP

private func withMIDIPacketList(_ packets: [[UInt8]], _ body: (MIDIPacketList) -> Void) {
    let payloadSize = packets.reduce(0) { partial, packet in
        partial + max(MemoryLayout<MIDIPacket>.size, packet.count)
    }
    let bufferSize = max(1024, MemoryLayout<MIDIPacketList>.size + payloadSize)
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    buffer.withUnsafeMutableBytes { rawBuffer in
        let packetList = rawBuffer.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
        var currentPacket = MIDIPacketListInit(packetList)

        for packetBytes in packets {
            packetBytes.withUnsafeBufferPointer { bytes in
                if let base = bytes.baseAddress {
                    currentPacket = MIDIPacketListAdd(
                        packetList,
                        bufferSize,
                        currentPacket,
                        0,
                        packetBytes.count,
                        base
                    )
                }
            }
        }

        body(packetList.pointee)
    }
}

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

@Test func testMIDIFeedbackParsesAdditionalChannelVoiceMessages() {
    let bytes: [UInt8] = [
        0x90, 0x3C, 0x00,  // Note-on with zero velocity -> note-off
        0xC1, 0x0A,  // Program change, channel 1
        0xE2, 0x00, 0x40,  // Pitch bend center, channel 2
        0xD3, 0x20,  // Aftertouch, channel 3
        0xA4, 0x31, 0x22,  // Poly aftertouch, channel 4
        0xB5, 0x07, 0x64,  // CC 7=100, channel 5
    ]

    let events = MIDIFeedback.parseBytes(bytes)
    #expect(events.count == 6)

    if case .noteOff(let channel, let note, let velocity) = events[0] {
        #expect(channel == 0)
        #expect(note == 0x3C)
        #expect(velocity == 0)
    } else {
        Issue.record("Expected noteOff from zero-velocity noteOn")
    }

    if case .programChange(let channel, let program) = events[1] {
        #expect(channel == 1)
        #expect(program == 0x0A)
    } else {
        Issue.record("Expected programChange event")
    }

    if case .pitchBend(let channel, let value) = events[2] {
        #expect(channel == 2)
        #expect(value == 8192)
    } else {
        Issue.record("Expected pitchBend event")
    }

    if case .aftertouch(let channel, let pressure) = events[3] {
        #expect(channel == 3)
        #expect(pressure == 0x20)
    } else {
        Issue.record("Expected aftertouch event")
    }

    if case .polyAftertouch(let channel, let note, let pressure) = events[4] {
        #expect(channel == 4)
        #expect(note == 0x31)
        #expect(pressure == 0x22)
    } else {
        Issue.record("Expected polyAftertouch event")
    }

    if case .controlChange(let channel, let controller, let value) = events[5] {
        #expect(channel == 5)
        #expect(controller == 0x07)
        #expect(value == 0x64)
    } else {
        Issue.record("Expected controlChange event")
    }
}

@Test func testMIDIFeedbackParsesCompleteAndTruncatedSysEx() {
    let complete = MIDIFeedback.parseBytes([0xF0, 0x7D, 0x01, 0xF7, 0x90, 0x3C, 0x64])
    #expect(complete.count == 2)
    if case .sysEx(let bytes) = complete[0] {
        #expect(bytes == [0xF0, 0x7D, 0x01, 0xF7])
    } else {
        Issue.record("Expected complete SysEx event")
    }
    if case .noteOn(let channel, let note, let velocity) = complete[1] {
        #expect(channel == 0)
        #expect(note == 0x3C)
        #expect(velocity == 0x64)
    } else {
        Issue.record("Expected noteOn after SysEx")
    }

    let truncated = MIDIFeedback.parseBytes([0xF0, 0x7D, 0x02])
    #expect(truncated.count == 1)
    if case .sysEx(let bytes) = truncated[0] {
        #expect(bytes == [0xF0, 0x7D, 0x02])
    } else {
        Issue.record("Expected truncated SysEx event")
    }
}

@Test func testMIDIFeedbackSkipsStrayDataBytesWithoutStatus() {
    let events = MIDIFeedback.parseBytes([0x40, 0x41, 0x90, 0x3C, 0x64])
    #expect(events.count == 1)
    if case .noteOn(let channel, let note, let velocity) = events[0] {
        #expect(channel == 0)
        #expect(note == 0x3C)
        #expect(velocity == 0x64)
    } else {
        Issue.record("Expected noteOn after stray data bytes")
    }
}

@Test func testMIDIFeedbackParsesMIDIPacketListIntoStream() async {
    let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream()
    var iterator = stream.makeAsyncIterator()

    withMIDIPacketList([
        [0x80, 0x3C, 0x40],
        [0xF8],
    ]) { packetList in
        MIDIFeedback.parse(packetList: packetList, into: continuation)
    }
    continuation.finish()

    let first = await iterator.next()
    let second = await iterator.next()

    if case .noteOff(let channel, let note, let velocity)? = first {
        #expect(channel == 0)
        #expect(note == 0x3C)
        #expect(velocity == 0x40)
    } else {
        Issue.record("Expected noteOff from packet list")
    }

    #expect(second == nil)
}

@Test func testMMCCommandsBuildExpectedTransportMessages() {
    #expect(MMCCommands.play() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x02, 0xF7])
    #expect(MMCCommands.stop() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x01, 0xF7])
    #expect(MMCCommands.recordStrobe() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x06, 0xF7])
    #expect(MMCCommands.recordExit() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x07, 0xF7])
    #expect(MMCCommands.pause() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x09, 0xF7])
    #expect(MMCCommands.fastForward() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x04, 0xF7])
    #expect(MMCCommands.rewind() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x05, 0xF7])
    #expect(
        MMCCommands.locate(hours: 1, minutes: 2, seconds: 3, frames: 4, subframes: 5)
            == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x44, 0x06, 0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0xF7]
    )
}
