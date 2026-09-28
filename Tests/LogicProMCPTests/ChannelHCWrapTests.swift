import Foundation
import Testing
@testable import LogicProMCP

/// v3.1.1 (P2-2 / P2-3) — verify CGEvent and MIDIKeyCommands channels return
/// Honest Contract State B envelopes for successful mutating operations.
/// Both channels are fundamentally fire-and-forget (CGEvent posts a
/// keystroke, MIDI Key Commands sends a CC pair) so neither can read back
/// the resulting Logic state — every success is `verified:false /
/// readback_unavailable`.

private func parseEnvelope(_ message: String) -> [String: Any]? {
    guard let data = message.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return raw as? [String: Any]
}

@Test func testCGEventMappedShortcutReturnsHCEnvelope() async {
    let recorder = CGEventRecorder()
    let runtime = CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 99 },
        postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in }
    )
    let channel = CGEventChannel(runtime: runtime)

    let result = await channel.execute(operation: "transport.play", params: [:])
    #expect(result.isSuccess)
    guard let env = parseEnvelope(result.message) else {
        Issue.record("CGEvent response is not valid JSON")
        return
    }
    #expect((env["success"] as? Bool)!)
    #expect(!((env["verified"] as? Bool)!))
    #expect(env["reason"] as? String == "readback_unavailable")
    #expect(env["operation"] as? String == "transport.play")
    #expect(env["method"] as? String == "cgevent")
    #expect((env["sent"] as? Bool)!)
}

@Test func testCGEventGotoPositionReturnsHCEnvelopeWithPosition() async {
    let recorder = CGEventRecorder()
    let screen = GotoDialogScreen(pid: 99)
    let runtime = CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 99 },
        postKeyEvent: screen.observing { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in },
        onScreenWindowList: { screen.windows() }
    )
    let channel = CGEventChannel(runtime: runtime)

    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "5.1.1.1"]
    )
    #expect(result.isSuccess)
    guard let env = parseEnvelope(result.message) else {
        Issue.record("CGEvent goto_position response is not valid JSON")
        return
    }
    #expect(env["operation"] as? String == "transport.goto_position")
    #expect(env["position"] as? String == "5.1.1.1")
    #expect(env["method"] as? String == "cgevent")
    #expect(!((env["verified"] as? Bool)!))
}

@Test func testCGEventErrorPathStaysFreeText() async {
    // Force a post failure on the first event.
    let recorder = CGEventRecorder()
    recorder.failAtEventIndex = 0
    let runtime = CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 99 },
        postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in }
    )
    let channel = CGEventChannel(runtime: runtime)

    let result = await channel.execute(operation: "transport.play", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("Failed to post CGEvent"))
    // Errors stay free-text so the router's terminal-state detection still
    // sees the existing failure signal unchanged.
    #expect(parseEnvelope(result.message) == nil)
}

@Test func testMIDIKeyCommandSuccessReturnsHCEnvelope() async {
    let transport = MockKeyCmdTransport()
    let channel = MIDIKeyCommandsChannel(transport: transport)

    let result = await channel.execute(operation: "edit.undo", params: [:])
    #expect(result.isSuccess)
    guard let env = parseEnvelope(result.message) else {
        Issue.record("MIDI key command response is not valid JSON")
        return
    }
    #expect((env["success"] as? Bool)!)
    #expect(!((env["verified"] as? Bool)!))
    #expect(env["reason"] as? String == "readback_unavailable")
    #expect(env["operation"] as? String == "edit.undo")
    #expect(env["method"] as? String == "midi_key_command")
    #expect(env["cc"] as? Int == 30)
    #expect(env["channel"] as? Int == 16)
    // Legacy free-text preserved inside `raw` for diagnostics.
    let raw = env["raw"] as? String ?? ""
    #expect(raw.contains("Key command triggered"))
    #expect(raw.contains("CC 30"))
}

@Test func testMIDIKeyCommandErrorPathStaysFreeText() async {
    let transport = MockKeyCmdTransport()
    await transport.setSendError(.sendFailed)
    let channel = MIDIKeyCommandsChannel(transport: transport)

    let result = await channel.execute(operation: "edit.undo", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("Failed to send key command"))
    #expect(parseEnvelope(result.message) == nil)
}
