import Testing
@testable import LogicProMCP

@Test func testScripterParamToCC() {
    // param 0 → CC 102
    #expect(ScripterChannel.ccForParam(0) == 102)
}

@Test func testScripterParamRange() {
    // param 0-17 → CC 102-119
    for i in 0..<18 {
        #expect(ScripterChannel.ccForParam(i) == UInt8(102 + i))
    }
}

@Test func testScripterValueNormalize() {
    // value 0.5 → MIDI velocity 64
    #expect(ScripterChannel.midiValue(for: 0.5) == 64)
    #expect(ScripterChannel.midiValue(for: 0.0) == 0)
    #expect(ScripterChannel.midiValue(for: 1.0) == 127)
}

@Test func testScripterOutOfRange() {
    // param 18 → nil
    #expect(ScripterChannel.ccForParam(18) == nil)
    #expect(ScripterChannel.ccForParam(-1) == nil)
}

@Test func testScripterChannel16() async {
    let transport = MockScripterTransport()
    let channel = ScripterChannel(transport: transport)

    let result = await channel.execute(
        operation: "plugin.set_param",
        params: ["param": "0", "value": "0.5"]
    )
    #expect(result.isSuccess)

    let sent = await transport.sentBytes
    #expect(!sent.isEmpty)
    // 0xBF = CC on ch15 (zero-indexed = channel 16)
    #expect(sent[0][0] == 0xBF)
    #expect(sent[0][1] == 102) // CC 102 = param 0
    #expect(sent[0][2] == 64)  // 0.5 → 64
}

// MARK: - Mock

actor MockScripterTransport: KeyCmdTransportProtocol {
    var sentBytes: [[UInt8]] = []
    func send(_ bytes: [UInt8]) { sentBytes.append(bytes) }
}
