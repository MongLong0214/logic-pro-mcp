import Foundation
import Testing
@testable import LogicProMCP

enum MockScripterTransportError: Error {
    case sendFailed
}

private func scripterApprovalStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("scripter-approval-\(UUID().uuidString)")
        .appendingPathExtension("json")
}

private func decodeScripterJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

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
    let obj = decodeScripterJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["param"] as? Int == 0)
    #expect(obj["insert"] as? Int == 0)
    #expect(obj["cc"] as? Int == 102)
    #expect(obj["applied_midi_value"] as? Int == 64)
    #expect(obj["midi_channel"] as? Int == 16)
    #expect(obj["readback_source"] as? String == "scripter_send_only")

    let sent = await transport.sentBytes
    #expect(!sent.isEmpty)
    // 0xBF = CC on ch15 (zero-indexed = channel 16)
    #expect(sent[0][0] == 0xBF)
    #expect(sent[0][1] == 102) // CC 102 = param 0
    #expect(sent[0][2] == 64)  // 0.5 → 64
}

@Test func testScripterHealthReflectsTransportReadiness() async throws {
    let store = ManualValidationStore(fileURL: scripterApprovalStoreURL())
    let transport = MockScripterTransport()
    let channel = ScripterChannel(transport: transport, approvalStore: store)

    let beforeStart = await channel.healthCheck()
    #expect(!(beforeStart.available))
    #expect(beforeStart.verificationStatus == .unavailable)

    try await channel.start()
    let afterStart = await channel.healthCheck()
    #expect(afterStart.available)
    #expect(afterStart.verificationStatus == .manualValidationRequired)
    #expect(afterStart.detail.contains("not verifiable"))
}

@Test func testScripterHealthBecomesRuntimeReadyAfterApproval() async throws {
    let store = ManualValidationStore(fileURL: scripterApprovalStoreURL())
    let transport = MockScripterTransport()
    let channel = ScripterChannel(transport: transport, approvalStore: store)

    try await channel.start()
    let beforeApproval = await channel.healthCheck()
    #expect(!(beforeApproval.ready))

    try await store.approve(ManualValidationChannel.scripter, note: "validated in Logic Pro")

    let afterApproval = await channel.healthCheck()
    #expect(afterApproval.ready)
    #expect(afterApproval.verificationStatus == ChannelVerificationStatus.runtimeReady)
    #expect(afterApproval.detail.contains("approved by operator"))
}

@Test func testScripterRejectsUnsupportedOperation() async {
    let channel = ScripterChannel(transport: MockScripterTransport())

    let result = await channel.execute(operation: "plugin.insert", params: [:])

    #expect(!result.isSuccess)
    let obj = decodeScripterJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "not_implemented")
    #expect(((obj["hint"] as? String)?.contains("only handles plugin.set_param"))!)
}

@Test func testScripterExecuteSurfacesTransportSendFailure() async {
    let transport = MockScripterTransport()
    await transport.setSendError(.sendFailed)
    let channel = ScripterChannel(transport: transport)

    let result = await channel.execute(
        operation: "plugin.set_param",
        params: ["param": "1", "value": "0.25"]
    )

    #expect(!result.isSuccess)
    let obj = decodeScripterJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "port_unavailable")
    #expect(((obj["hint"] as? String)?.contains("Failed to send Scripter param 1"))!)
}

@Test func testScripterRejectsUnsupportedInsertAndOutOfRangeParam() async {
    let transport = MockScripterTransport()
    let channel = ScripterChannel(transport: transport)

    let badInsert = await channel.execute(
        operation: "plugin.set_param",
        params: ["insert": "1", "param": "0", "value": "0.5"]
    )
    #expect(!badInsert.isSuccess)
    let badInsertObj = decodeScripterJSON(badInsert.message)
    #expect(badInsertObj["error"] as? String == "not_implemented")
    #expect(((badInsertObj["hint"] as? String)?.contains("insert 0"))!)

    let badParam = await channel.execute(
        operation: "plugin.set_param",
        params: ["insert": "0", "param": "18", "value": "0.5"]
    )
    #expect(!badParam.isSuccess)
    let badParamObj = decodeScripterJSON(badParam.message)
    #expect(badParamObj["error"] as? String == "invalid_params")
    #expect(((badParamObj["hint"] as? String)?.contains("out of range"))!)

    let sent = await transport.sentBytes
    #expect(sent.isEmpty)
}

@Test func testScripterRejectsOutOfRangeValueWithoutClamping() async {
    let transport = MockScripterTransport()
    let channel = ScripterChannel(transport: transport)

    let low = await channel.execute(
        operation: "plugin.set_param",
        params: ["insert": "0", "param": "0", "value": "-0.1"]
    )
    let high = await channel.execute(
        operation: "plugin.set_param",
        params: ["insert": "0", "param": "0", "value": "1.1"]
    )

    #expect(!low.isSuccess)
    #expect(!high.isSuccess)
    #expect(decodeScripterJSON(low.message)["error"] as? String == "invalid_params")
    #expect(decodeScripterJSON(high.message)["error"] as? String == "invalid_params")
    let sent = await transport.sentBytes
    #expect(sent.isEmpty, "out-of-range values must fail closed, not clamp and send")
}

// MARK: - Mock

actor MockScripterTransport: KeyCmdTransportProtocol {
    var sentBytes: [[UInt8]] = []
    var prepared = false
    var sendError: MockScripterTransportError?

    func prepare() async throws {
        prepared = true
    }

    func send(_ bytes: [UInt8]) async throws {
        if let sendError {
            throw sendError
        }
        sentBytes.append(bytes)
    }

    func setSendError(_ error: MockScripterTransportError?) {
        sendError = error
    }

    func readiness() async -> KeyCmdTransportReadiness {
        if prepared {
            return KeyCmdTransportReadiness(available: true, detail: "Mock Scripter transport ready")
        }
        return KeyCmdTransportReadiness(available: false, detail: "Mock Scripter transport not prepared")
    }
}
