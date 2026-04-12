import Testing
@testable import LogicProMCP

// MARK: - Fader

@Test func testEncodeFaderPosition() {
    // track 0, value 0.5 → PitchBend ch0, value 0x2000 (8192)
    let bytes = MCUProtocol.encodeFader(track: 0, value: 0.5)
    #expect(bytes[0] == 0xE0) // PitchBend ch0
    let lsb = UInt16(bytes[1])
    let msb = UInt16(bytes[2])
    let value = (msb << 7) | lsb
    #expect(abs(Int(value) - 8192) <= 1) // ~0x2000
}

@Test func testEncodeFaderMax() {
    // track 7, value 1.0 → PitchBend ch7, value 0x3FFF (16383)
    let bytes = MCUProtocol.encodeFader(track: 7, value: 1.0)
    #expect(bytes[0] == 0xE7) // PitchBend ch7
    let lsb = UInt16(bytes[1])
    let msb = UInt16(bytes[2])
    let value = (msb << 7) | lsb
    #expect(value == 0x3FFF)
}

@Test func testDecodeFaderFeedback() {
    // PitchBend ch3 value ~0.25 → track 3, ~0.25
    let target: UInt16 = 4096 // ~0.25 of 16383
    let lsb = UInt8(target & 0x7F)
    let msb = UInt8((target >> 7) & 0x7F)
    let bytes: [UInt8] = [0xE3, lsb, msb]
    let result = MCUProtocol.decodeFader(bytes)
    #expect(result != nil)
    #expect(result?.track == 3)
    #expect(abs(result!.value - 0.25) < 0.01)
}

// MARK: - Buttons

@Test func testEncodeMuteButton() {
    // mute strip 2 on → Note On 0x12, vel 0x7F
    let bytes = MCUProtocol.encodeButton(.mute, strip: 2, on: true)
    #expect(bytes == [0x90, 0x12, 0x7F])
}

@Test func testDecodeSoloLED() {
    // Note On 0x0A vel 0x7F → solo strip 2 on
    let bytes: [UInt8] = [0x90, 0x0A, 0x7F]
    let result = MCUProtocol.decodeButton(bytes)
    #expect(result != nil)
    #expect(result?.function == .solo)
    #expect(result?.strip == 2)
    #expect(result?.on == true)
}

// MARK: - Transport

@Test func testEncodeTransportPlay() {
    let bytes = MCUProtocol.encodeTransport(.play)
    #expect(bytes == [0x90, 0x5E, 0x7F])
}

@Test func testEncodeTransportStop() {
    let bytes = MCUProtocol.encodeTransport(.stop)
    #expect(bytes == [0x90, 0x5D, 0x7F])
}

// MARK: - V-Pot

@Test func testEncodeVPotCW() {
    // strip 0, clockwise speed 3
    let bytes = MCUProtocol.encodeVPot(strip: 0, direction: .clockwise, speed: 3)
    #expect(bytes == [0xB0, 0x10, 0x03])
}

@Test func testEncodeVPotCCW() {
    // strip 0, counter-clockwise speed 3
    let bytes = MCUProtocol.encodeVPot(strip: 0, direction: .counterClockwise, speed: 3)
    #expect(bytes == [0xB0, 0x10, 0x43])
}

// MARK: - Banking

@Test func testEncodeBankRight() {
    let bytes = MCUProtocol.encodeButton(.bankRight, strip: 0, on: true)
    #expect(bytes == [0x90, 0x2F, 0x7F])
}

// MARK: - LCD

@Test func testMCUDeviceQuerySysEx() {
    let query = MCUProtocol.encodeDeviceQuery()
    #expect(query == [0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7])
}

@Test func testMCULCDSysExDecode() {
    let sysex: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xF7]
    let result = MCUProtocol.decodeLCDSysEx(sysex)
    #expect(result != nil)
    #expect(result?.offset == 0)
    #expect(result?.text == "Hello")
    #expect(result?.row == .upper)
}

@Test func testMCULCDLowerRow() {
    let sysex: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x38, 0x54, 0x65, 0x73, 0x74, 0xF7]
    let result = MCUProtocol.decodeLCDSysEx(sysex)
    #expect(result?.row == .lower)
    #expect(result?.text == "Test")
}

// MARK: - Automation

@Test func testEncodeAutomationTouch() {
    let bytes = MCUProtocol.encodeButton(.automationTouch, strip: 0, on: true)
    #expect(bytes == [0x90, 0x4D, 0x7F])
}

// MARK: - Jog Wheel

@Test func testEncodeJogCW() {
    let bytes = MCUProtocol.encodeJog(direction: .clockwise, clicks: 1)
    #expect(bytes == [0xB0, 0x3C, 0x01])
}

// MARK: - Handshake

@Test func testDecodeDeviceResponseSuccess() {
    let response: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x01, 0x42, 0x00, 0x01, 0xF7]
    let result = MCUProtocol.parseDeviceResponse(response)
    if case .success(let firmware) = result {
        #expect(firmware == [0x42, 0x00, 0x01])
    } else {
        Issue.record("Expected success, got \(result)")
    }
}

@Test func testDecodeDeviceResponseNoResponse() {
    let result = MCUProtocol.parseDeviceResponse([])
    #expect(result == .noResponse)
}

@Test func testDecodeDeviceResponseMalformed() {
    let malformed: [UInt8] = [0xF0, 0x00, 0x00, 0xF7]
    let result = MCUProtocol.parseDeviceResponse(malformed)
    if case .failure = result {
        // expected
    } else {
        Issue.record("Expected failure, got \(result)")
    }
}

@Test func testDecodeDeviceResponseWrongSubID() {
    let wrong: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x02, 0xF7]
    let result = MCUProtocol.parseDeviceResponse(wrong)
    if case .failure(let reason) = result {
        #expect(reason.contains("sub-ID"))
    } else {
        Issue.record("Expected failure for wrong sub-ID")
    }
}

// MARK: - Validation

@Test func testSysExValidation() {
    #expect(MCUProtocol.isValidSysEx([0xF0, 0x00, 0x01, 0x7F, 0xF7]) == true)
    #expect(MCUProtocol.isValidSysEx([0xF0, 0x00, 0x80, 0x01, 0xF7]) == false)
    #expect(MCUProtocol.isValidSysEx([0x00, 0x01, 0xF7]) == false)
    #expect(MCUProtocol.isValidSysEx([0xF0, 0x00, 0x01]) == false)
}
