import Foundation
import Testing
@testable import LogicProMCP

// HC v2 (logic_plugins.* verified-plugin surface) contract-shape tests.
private func decode(_ json: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!, options: []) as! [String: Any]
}

// MARK: - v2 State A

@Test func testV2StateACarriesStateAndSchema() {
    let obj = decode(HonestContract.encodeV2StateA(extras: [
        "operation": "logic_plugins.set_param_verified",
        "observed_display": -4.02,
    ]))
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["state"] as? String == "A")
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["observed_display"] as? Double == -4.02)
    #expect(obj["reason"] == nil, "State A must not carry reason")
    #expect(obj["error"] == nil, "State A must not carry error")
}

// MARK: - v2 State B

@Test func testV2StateBCarriesStateSchemaAndReason() {
    let obj = decode(HonestContract.encodeV2StateB(
        reason: .readbackUnavailable,
        extras: [
            "operation": "logic_plugins.get_inventory",
            "what_was_attempted": "read insert chain inventory for track 0",
            "safe_to_retry": true,
        ]
    ))
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["state"] as? String == "B")
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect((obj["safe_to_retry"] as? Bool)!)
    #expect(obj["error"] == nil, "State B must not carry error")
}

// MARK: - v2 State C

@Test func testV2StateCCarriesVerifiedFalseAndState() {
    let obj = decode(HonestContract.encodeV2StateC(
        error: .readbackMismatch,
        extras: [
            "operation": "logic_plugins.set_param_verified",
            "what_was_attempted": "set Gain gain_db to -4.0 dB",
            "write_attempted": true,
            "safe_to_retry": true,
        ]
    ))
    #expect(!((obj["success"] as? Bool)!))
    #expect(!((obj["verified"] as? Bool)!), "v2 State C carries explicit verified:false (unlike v1)")
    #expect(obj["state"] as? String == "C")
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect((obj["write_attempted"] as? Bool)!)
    #expect(obj["reason"] == nil, "State C must not carry reason")
}

// MARK: - New §4 error codes

@Test func testV2NewErrorCodeRawValues() {
    let expected: [(HonestContract.FailureError, String)] = [
        (.unsupportedMode, "unsupported_mode"),
        (.projectPathRequired, "project_path_required"),
        (.projectIdentityMismatch, "project_identity_mismatch"),
        (.unknownPluginIdentity, "unknown_plugin_identity"),
        (.unsupportedParamReadback, "unsupported_param_readback"),
        (.incompleteInventory, "incomplete_inventory"),
        (.targetPluginMismatch, "target_plugin_mismatch"),
        (.pluginWindowPluginMismatch, "plugin_window_plugin_mismatch"),
        (.duplicatePluginEditorAlreadyOpen, "duplicate_plugin_editor_already_open"),
        (.duplicatePluginEditorCountMismatch, "duplicate_plugin_editor_count_mismatch"),
        (.slotOccupied, "slot_occupied"),
        (.trackSelectionFailed, "track_selection_failed"),
        (.staleSnapshot, "stale_snapshot"),
        (.windowOpenFailed, "window_open_failed"),
        (.windowIdentityUnresolved, "window_identity_unresolved"),
        (.pluginViewNotConfirmed, "plugin_view_not_confirmed"),
        (.paramControlNotFound, "param_control_not_found"),
        (.readbackLostAfterWrite, "readback_lost_after_write"),
        (.postInsertPluginMismatch, "post_insert_plugin_mismatch"),
        (.postInsertReadbackUnavailable, "post_insert_readback_unavailable"),
        (.insertNotAxAutomatable, "insert_not_ax_automatable"),
        (.insertSetupFailed, "insert_setup_failed"),
        (.insertLandedAtDifferentSlot, "insert_landed_at_different_slot"),
        (.rollbackFailed, "rollback_failed"),
        (.verifiedOpInProgress, "verified_op_in_progress"),
        (.mutatingOperationInProgress, "mutating_operation_in_progress"),
        (.operationTimeout, "operation_timeout"),
    ]
    for (err, raw) in expected {
        #expect(err.rawValue == raw)
    }
}

@Test func testRetiredAmbiguousPluginInstanceErrorCannotBeDecoded() {
    // The duplicate-editor outcomes replaced this pre-acquisition error.
    // Keeping its raw value would make an unproducible error externally visible.
    let retired = HonestContract.FailureError(rawValue: "ambiguous_plugin_instance")
    #expect(retired == nil)
}

// MARK: - Detector / router compatibility (AC13)

@Test func testDetectorRecognizesV2StateCAsEnvelope() {
    // v2 State C carries verified:false, but the detector keys off
    // success:false + error — so it must still be recognized as an envelope.
    let json = HonestContract.encodeV2StateC(error: .targetPluginMismatch)
    #expect(HonestContractEnvelopeDetector.isAlreadyEnvelope(json))
}

@Test func testDetectorRecognizesV2StateAAndBAsEnvelope() {
    #expect(HonestContractEnvelopeDetector.isAlreadyEnvelope(HonestContract.encodeV2StateA()))
    #expect(HonestContractEnvelopeDetector.isAlreadyEnvelope(
        HonestContract.encodeV2StateB(reason: .readbackUnavailable)))
}

@Test func testV2StateCIsTerminalForVerifiedCodes() {
    // Every verified-path failure is terminal (AX-only, no fallback).
    let json = HonestContract.encodeV2StateC(error: .windowOpenFailed)
    #expect(HonestContract.isTerminalStateC(json))
    #expect(HonestContract.stateCErrorCode(json) == "window_open_failed")
}

@Test func testV2NewTerminalCodesRegistered() {
    let mustBeTerminal: [HonestContract.FailureError] = [
        .unsupportedMode, .projectPathRequired, .projectIdentityMismatch,
        .unknownPluginIdentity, .unsupportedParamReadback, .incompleteInventory,
        .targetPluginMismatch, .pluginWindowPluginMismatch,
        .duplicatePluginEditorAlreadyOpen, .duplicatePluginEditorCountMismatch, .slotOccupied,
        .trackSelectionFailed, .staleSnapshot,
        .windowOpenFailed, .windowIdentityUnresolved, .paramControlNotFound,
        .readbackLostAfterWrite, .postInsertPluginMismatch,
        .postInsertReadbackUnavailable, .insertNotAxAutomatable,
        .insertSetupFailed, .insertLandedAtDifferentSlot, .rollbackFailed, .verifiedOpInProgress,
        .mutatingOperationInProgress, .operationTimeout,
    ]
    for err in mustBeTerminal {
        #expect(HonestContract.terminalErrorCodes.contains(err.rawValue),
                "\(err.rawValue) must be terminal for the verified path")
    }
}

@Test func testV1StateCStillHasStateButNoVerifiedOrSchemaKeys() {
    let obj = decode(HonestContract.encodeStateC(error: .axWriteFailed))
    #expect(obj["verified"] == nil, "v1 State C must not carry verified")
    #expect(obj["state"] as? String == "C", "v1 State C must carry state")
    #expect(obj["hc_schema"] == nil, "v1 State C must not carry hc_schema")
}

@Test func testV1StateAAndBStillHaveStateButNoSchemaKeys() {
    let stateA = decode(HonestContract.encodeStateA())
    #expect(stateA["state"] as? String == "A", "v1 State A must carry state")
    #expect(stateA["hc_schema"] == nil, "v1 State A must not carry hc_schema")

    let stateB = decode(HonestContract.encodeStateB(reason: .readbackUnavailable))
    #expect(stateB["state"] as? String == "B", "v1 State B must carry state")
    #expect(stateB["hc_schema"] == nil, "v1 State B must not carry hc_schema")
}

@Test func testReadbackMismatchNotAddedToTerminalCodes() {
    // readbackMismatch predates v2 and is shared with channels where fallback
    // is still legitimate — it must stay non-terminal.
    #expect(!(HonestContract.terminalErrorCodes.contains(
        HonestContract.FailureError.readbackMismatch.rawValue)))
}
