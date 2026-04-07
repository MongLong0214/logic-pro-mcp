import Foundation
import Testing
@testable import LogicProMCP

enum MockKeyCmdTransportError: Error {
    case sendFailed
}

private func manualValidationStoreURL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .appendingPathExtension("json")
}

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
    #expect(result.message.contains("No MIDI Key Command mapping"))
}

@Test func testKeyCommandMappingCount() {
    let mapping = MIDIKeyCommandsChannel.mappingTable
    #expect(mapping.count >= 30)
}

@Test func testKeyCommandHealthReflectsTransportReadiness() async throws {
    let store = ManualValidationStore(fileURL: manualValidationStoreURL(prefix: "keycmd-health"))
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport, approvalStore: store)

    let beforeStart = await channel.healthCheck()
    #expect(beforeStart.available == false)
    #expect(beforeStart.verificationStatus == .unavailable)

    try await channel.start()
    let afterStart = await channel.healthCheck()
    #expect(afterStart.available == true)
    #expect(afterStart.verificationStatus == .manualValidationRequired)
    #expect(afterStart.detail.contains("not verifiable"))
}

@Test func testKeyCommandHealthBecomesRuntimeReadyAfterApproval() async throws {
    let store = ManualValidationStore(fileURL: manualValidationStoreURL(prefix: "keycmd-approval"))
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport, approvalStore: store)

    try await channel.start()
    let beforeApproval = await channel.healthCheck()
    #expect(beforeApproval.ready == false)

    try await store.approve(ManualValidationChannel.midiKeyCommands, note: "validated in Logic Pro")

    let afterApproval = await channel.healthCheck()
    #expect(afterApproval.ready == true)
    #expect(afterApproval.verificationStatus == ChannelVerificationStatus.runtimeReady)
    #expect(afterApproval.detail.contains("approved by operator"))
}

@Test func testKeyCommandExecuteSurfacesTransportSendFailure() async {
    let transport = MockKeyCmdTransport()
    await transport.setSendError(.sendFailed)
    let channel = MIDIKeyCommandsChannel(transport: transport)

    let result = await channel.execute(operation: "edit.undo", params: [:])

    #expect(!result.isSuccess)
    #expect(result.message.contains("Failed to send key command"))
}

// MARK: - Mock

actor MockKeyCmdTransport: KeyCmdTransportProtocol {
    var sentBytes: [[UInt8]] = []
    var prepared = false
    var sendError: MockKeyCmdTransportError?

    func prepare() async throws {
        prepared = true
    }

    func send(_ bytes: [UInt8]) async throws {
        if let sendError {
            throw sendError
        }
        sentBytes.append(bytes)
    }

    func setSendError(_ error: MockKeyCmdTransportError?) {
        sendError = error
    }

    func readiness() async -> KeyCmdTransportReadiness {
        if prepared {
            return KeyCmdTransportReadiness(available: true, detail: "Mock KeyCmd transport ready")
        }
        return KeyCmdTransportReadiness(available: false, detail: "Mock KeyCmd transport not prepared")
    }
}
