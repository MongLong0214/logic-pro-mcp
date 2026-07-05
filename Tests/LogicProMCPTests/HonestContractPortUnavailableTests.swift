import Foundation
import Testing
@testable import LogicProMCP

// T1 — HonestContract `.portUnavailable` FailureError + terminalErrorCodes.
// PRD-issue1-keycmd-port-routing §4.1 step 7, §10.1 R7, OQ-7. The router uses
// State C `port_unavailable` to short-circuit the fallback chain when the
// requested channel/port itself is not configured (e.g. CoreMIDI VirtualPort
// missing). It must be a terminal error so a downstream channel does not
// silently regress into a vacuous success.

@Test func testPortUnavailableErrorRawValue() {
    #expect(HonestContract.FailureError.portUnavailable.rawValue == "port_unavailable")
}

@Test func testPortUnavailableInTerminalErrorCodes() {
    #expect(HonestContract.terminalErrorCodes.contains("port_unavailable"))
}

@Test func testIsTerminalStateCWithPortUnavailableEnvelope() {
    let envelope = HonestContract.encodeStateC(
        error: .portUnavailable,
        hint: "CoreMIDI virtual port not configured"
    )
    #expect(HonestContract.isTerminalStateC(envelope))
}

@Test func testEncodeStateCPortUnavailableEnvelopeShape() {
    let json = HonestContract.encodeStateC(
        error: .portUnavailable,
        hint: "CoreMIDI virtual port not configured",
        extras: ["channel": "coremidi", "requestedPort": "Logic Pro Virtual In"]
    )
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "port_unavailable")
    #expect(obj["hint"] as? String == "CoreMIDI virtual port not configured")
    #expect(obj["channel"] as? String == "coremidi")
    #expect(obj["requestedPort"] as? String == "Logic Pro Virtual In")
    #expect(obj["verified"] == nil, "State C must not carry verified")
    #expect(obj["reason"] == nil, "State C must not carry reason")
}

@Test func testExistingFailureErrorsUnaffected() {
    #expect(HonestContract.FailureError.invalidParams.rawValue == "invalid_params")
    #expect(HonestContract.FailureError.elementNotFound.rawValue == "element_not_found")
    #expect(HonestContract.FailureError.axWriteFailed.rawValue == "ax_write_failed")
    #expect(HonestContract.FailureError.notImplemented.rawValue == "not_implemented")
    #expect(HonestContract.FailureError.permissionDenied.rawValue == "permission_denied")
    #expect(HonestContract.FailureError.logicNotRunning.rawValue == "logic_not_running")
    #expect(HonestContract.FailureError.readbackUnavailable.rawValue == "readback_unavailable")
    #expect(HonestContract.FailureError.readbackMismatch.rawValue == "readback_mismatch")

    // Existing terminal codes still present.
    #expect(HonestContract.terminalErrorCodes.contains("element_not_found"))
    #expect(HonestContract.terminalErrorCodes.contains("invalid_params"))
    #expect(HonestContract.terminalErrorCodes.contains("not_implemented"))
}
