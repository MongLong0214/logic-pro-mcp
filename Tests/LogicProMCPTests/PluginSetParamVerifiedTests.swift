@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// T3 — logic_plugins.set_param_verified, R6 precedence steps 1-5 (write-preceding).
// AC10 (unsupported_param_readback, no write), AC11 (identity), AC17
// (unsupported_mode), AC19 (project_path_required), AC23 (single precedence).
//
// The live write path (R6 steps 6+) is NOT in T3; Gain's capability preflight
// fail-closes every request at step 5 before any write. These tests inject a
// deterministic front-document path so the project gate is exercised without a
// running Logic Pro.

private let expectedPath = "/Users/me/Music/MySong copy.logicx"

private func runSetParam(
    _ params: [String: String],
    frontDoc: String? = expectedPath
) async -> [String: Any] {
    // No mixer fixture needed — every T3 request stops at step 5 (or earlier),
    // none of which reaches live AX. A minimal logic runtime suffices.
    let b = FakeAXRuntimeBuilder()
    let runtime = b.makeLogicRuntime(appElement: b.element(800))
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: params,
        runtime: runtime,
        frontDocumentPath: { frontDoc }
    )
    return try! JSONSerialization.jsonObject(
        with: result.message.data(using: .utf8)!, options: []
    ) as! [String: Any]
}

private func validGainParams(
    plugin: String = "logic.stock.effect.gain",
    param: String = "gain_db",
    value: String = "-4.0",
    unit: String = "dB",
    mode: String = "duplicate_applyback",
    path: String? = expectedPath
) -> [String: String] {
    var p: [String: String] = [
        "track": "0", "insert": "2", "plugin": plugin, "param": param,
        "value": value, "unit": unit, "mode": mode,
    ]
    if let path { p["project_expected_path"] = path }
    return p
}

// MARK: - AC10: Gain preflight is unsupported, no write

@Test func testSetParamGainReachesUnsupportedParamReadback() async {
    let obj = await runSetParam(validGainParams())
    #expect(obj["state"] as? String == "C")
    #expect(obj["error"] as? String == "unsupported_param_readback")
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["hc_schema"] as? Int == 2)
    #expect(!((obj["write_attempted"] as? Bool)!), "no write may be attempted (AC10)")
    // post-resolution identity carries canonical id.
    let identity = obj["target_identity"] as? [String: Any]
    #expect(identity?["plugin_id"] as? String == "logic.stock.effect.gain")
}

@Test func testSetParamDisplayNameAliasAlsoReachesPreflight() async {
    // AC23 second clause: alias "Gain" must resolve at step 4 so it reaches the
    // step-5 capability preflight (unsupported_param_readback), not stall at
    // unknown_plugin_identity.
    let obj = await runSetParam(validGainParams(plugin: "Gain"))
    #expect(obj["error"] as? String == "unsupported_param_readback")
}

// MARK: - AC17: confirmed_live blocked (step 2)

@Test func testSetParamConfirmedLiveBlocked() async {
    let obj = await runSetParam(validGainParams(mode: "confirmed_live"))
    #expect(obj["error"] as? String == "unsupported_mode")
    #expect(!((obj["write_attempted"] as? Bool)!))
}

// MARK: - AC19: project_expected_path required (step 3)

@Test func testSetParamMissingPathRejected() async {
    let obj = await runSetParam(validGainParams(path: nil))
    #expect(obj["error"] as? String == "project_path_required")
}

// MARK: - AC15-adjacent: path mismatch (step 3)

@Test func testSetParamPathMismatchRejected() async {
    let obj = await runSetParam(validGainParams(), frontDoc: "/Users/me/Music/MySong.logicx")
    #expect(obj["error"] as? String == "project_identity_mismatch")
    let identity = obj["target_identity"] as? [String: Any]
    #expect(identity?["project_path_expected"] as? String == expectedPath)
    #expect(identity?["project_path_observed"] as? String == "/Users/me/Music/MySong.logicx")
}

// MARK: - AC11: unknown identity (step 4)

@Test func testSetParamUnknownIdentityRejected() async {
    let obj = await runSetParam(validGainParams(plugin: "com.apple.logic.gain"))
    #expect(obj["error"] as? String == "unknown_plugin_identity")
}

// MARK: - AC23: single precedence — path-mismatch wins over unsupported-param

@Test func testSetParamPrecedencePathMismatchBeatsUnsupportedParam() async {
    // Wrong path AND a Gain param that would be unsupported at step 5. Step 3
    // (project_identity_mismatch) must be reported, NOT step 5.
    let obj = await runSetParam(validGainParams(), frontDoc: "/Users/me/Music/WRONG.logicx")
    #expect(obj["error"] as? String == "project_identity_mismatch")
}

@Test func testSetParamPrecedenceModeBeatsPath() async {
    // confirmed_live (step 2) is reported even when the path is also missing
    // (step 3) — lower step number wins.
    let obj = await runSetParam(validGainParams(mode: "confirmed_live", path: nil))
    #expect(obj["error"] as? String == "unsupported_mode")
}

@Test func testSetParamSchemaBeatsEverything() async {
    // Missing value (step 1) is reported even though mode is also invalid (step 2).
    var p = validGainParams(mode: "confirmed_live")
    p.removeValue(forKey: "value")
    let b = FakeAXRuntimeBuilder()
    let runtime = b.makeLogicRuntime(appElement: b.element(810))
    let result = await AccessibilityChannel.defaultSetParamVerified(
        params: p, runtime: runtime, frontDocumentPath: { expectedPath }
    )
    let obj = try! JSONSerialization.jsonObject(with: result.message.data(using: .utf8)!) as! [String: Any]
    #expect(obj["error"] as? String == "invalid_params")
}

// MARK: - Unit honesty (R8) + range (R6 step 1)

@Test func testSetParamWrongUnitIsInvalidParams() async {
    let obj = await runSetParam(validGainParams(unit: "Hz"))
    #expect(obj["error"] as? String == "invalid_params")
}

@Test func testSetParamOutOfRangeIsInvalidParams() async {
    let obj = await runSetParam(validGainParams(value: "999"))
    #expect(obj["error"] as? String == "invalid_params")
}

@Test func testSetParamBoundaryValuesPassSchemaReachPreflight() async {
    // -96 and +24 dB are the declared range edges (R8 boundary vectors); they
    // pass schema/range and reach the step-5 preflight.
    for edge in ["-96", "24", "0"] {
        let obj = await runSetParam(validGainParams(value: edge))
        #expect(obj["error"] as? String == "unsupported_param_readback",
                "value \(edge) should pass schema and reach preflight")
    }
}

// MARK: - ADR-011 / ADR-018 negative Controls-view evidence

@Test func testControlsViewSliderRefusesWithMeasuredNotActuableReason() async throws {
    let obj = await runSetParam([
        "track": "0", "insert": "2", "plugin": "Compressor", "param": "Ratio",
        "value": "4", "unit": "raw_ax_value", "mode": "duplicate_applyback",
        "project_expected_path": expectedPath,
    ])
    let error = try #require(obj["error"] as? String)
    let observation = try #require(obj["what_was_observed"] as? String)
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    let namesMeasurement = observation.contains("AXSlider actuation is refused")
        && observation.contains("direct AXValue set and AXIncrement")
        && observation.contains("did not change")
    let didNotFallBackToGenericAllowlistRefusal = !observation.contains("not in the verified allowlist")
    let didNotAttemptWrite = !writeAttempted
    #expect(error == "unsupported_param_readback")
    #expect(namesMeasurement)
    #expect(didNotFallBackToGenericAllowlistRefusal)
    #expect(didNotAttemptWrite)
}

@Test func testControlsViewPopupRefusesWithUnmeasuredReason() async throws {
    let obj = await runSetParam([
        "track": "0", "insert": "2", "plugin": "Compressor", "param": "circuit_type",
        "value": "0", "unit": "enumerated", "mode": "duplicate_applyback",
        "project_expected_path": expectedPath,
    ])
    let error = try #require(obj["error"] as? String)
    let observation = try #require(obj["what_was_observed"] as? String)
    let writeAttempted = try #require(obj["write_attempted"] as? Bool)
    let namesTheMeasuredWall = observation.contains("AXPopUpButton actuation is refused")
        && observation.contains("no choice can be named")
    let didNotAttemptWrite = !writeAttempted
    #expect(error == "unsupported_param_readback")
    #expect(namesTheMeasuredWall)
    #expect(didNotAttemptWrite)
}
