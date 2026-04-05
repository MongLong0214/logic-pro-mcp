import Testing
@testable import LogicProMCP

@Test func testChannelIDEnumContainsNewCases() {
    // Verify new channel IDs exist and have rawValues
    #expect(ChannelID.mcu.rawValue == "MCU")
    #expect(ChannelID.midiKeyCommands.rawValue == "MIDIKeyCommands")
    #expect(ChannelID.scripter.rawValue == "Scripter")
}

@Test func testChannelIDNoOSC() {
    // Verify OSC case is removed
    let allCases = ChannelID.allCases.map(\.rawValue)
    #expect(!allCases.contains("OSC"))
}
