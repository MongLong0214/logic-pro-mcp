import Testing
@testable import LogicProMCP

@Test func testKeyCommandMappingUndo() {
    let mapping = MIDIKeyCommandsChannel.mappingTable
    #expect(mapping["edit.undo"] == 30)
}

@Test func testKeyCommandMappingCreateAudio() {
    let mapping = MIDIKeyCommandsChannel.mappingTable
    #expect(mapping["track.create_audio"] == 20)
}

@Test func testKeyCommandMappingToggleMixer() {
    let mapping = MIDIKeyCommandsChannel.mappingTable
    #expect(mapping["view.toggle_mixer"] == 50)
}

@Test func testKeyCommandAllMappingsUnique() {
    let mapping = MIDIKeyCommandsChannel.mappingTable
    let ccValues = Array(mapping.values)
    let uniqueValues = Set(ccValues)
    #expect(ccValues.count == uniqueValues.count, "Duplicate CC# found in mapping table")
}

@Test func testKeyCommandChannelExecute() async {
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport)

    let result = await channel.execute(operation: "edit.undo", params: [:])
    #expect(result.isSuccess)

    let sent = await transport.sentBytes
    #expect(sent.count == 2) // CC on (0x7F) + CC off (0x00) release
    // CC 30 on CH 16 (0xBF = CC on ch 15 zero-indexed)
    #expect(sent[0][0] == 0xBF)
    #expect(sent[0][1] == 30)
    #expect(sent[0][2] == 0x7F)
    // Release
    #expect(sent[1][2] == 0x00)
}

@Test func testKeyCommandUnknownOperation() async {
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport)

    let result = await channel.execute(operation: "nonexistent.command", params: [:])
    #expect(!result.isSuccess)
}

@Test func testKeyCommandMappingCount() {
    let mapping = MIDIKeyCommandsChannel.mappingTable
    #expect(mapping.count >= 30)
}

// MARK: - Mock

actor MockKeyCmdTransport: KeyCmdTransportProtocol {
    var sentBytes: [[UInt8]] = []

    func send(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
    }
}
