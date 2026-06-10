import Foundation
import Testing
@testable import LogicProMCP

// Contract-shape tests for the HonestContract encoder. Each mutating op has
// its own behavioural tests elsewhere; these ensure the envelope that every
// op shares stays invariant (3-state, mandatory fields).

@Test func testStateAEncodesSuccessVerifiedTrue() {
    let json = HonestContract.encodeStateA(extras: ["requested": "Piano", "observed": "Piano"])
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == true)
    #expect(obj["requested"] as? String == "Piano")
    #expect(obj["observed"] as? String == "Piano")
    #expect(obj["reason"] == nil, "State A must not carry reason")
    #expect(obj["error"] == nil, "State A must not carry error")
}

@Test func testStateBRequiresReasonAndHasSuccessVerifiedFalse() {
    let json = HonestContract.encodeStateB(
        reason: .echoTimeout(ms: 500),
        extras: ["requested": 0.8, "observed": NSNull()]
    )
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == false)
    #expect(obj["reason"] as? String == "echo_timeout_500ms")
    #expect(obj["error"] == nil, "State B must not carry error")
}

@Test func testStateBReadbackUnavailableReason() {
    let json = HonestContract.encodeStateB(reason: .readbackUnavailable)
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["reason"] as? String == "readback_unavailable")
}

@Test func testStateBRetryExhaustedReason() {
    let json = HonestContract.encodeStateB(reason: .retryExhausted)
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["reason"] as? String == "retry_exhausted")
}

@Test func testStateCRequiresErrorEnum() {
    let json = HonestContract.encodeStateC(
        error: .axWriteFailed,
        axCode: -25212,
        hint: "permission?",
        extras: ["requested": 7]
    )
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["success"] as? Bool == false)
    #expect(obj["error"] as? String == "ax_write_failed")
    #expect(obj["axCode"] as? Int == -25212)
    #expect(obj["hint"] as? String == "permission?")
    #expect(obj["verified"] == nil, "State C must not carry verified")
    #expect(obj["reason"] == nil, "State C must not carry reason")
}

@Test func testStateCElementNotFoundHasNoAxCodeByDefault() {
    let json = HonestContract.encodeStateC(error: .elementNotFound)
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["success"] as? Bool == false)
    #expect(obj["error"] as? String == "element_not_found")
    #expect(obj["axCode"] == nil)
    #expect(obj["hint"] == nil)
}

@Test func testStateCReadbackUnavailableError() {
    let json = HonestContract.encodeStateC(
        error: .readbackUnavailable,
        hint: "write executed but could not be verified"
    )
    let obj = try! JSONSerialization.jsonObject(
        with: json.data(using: .utf8)!, options: []
    ) as! [String: Any]
    #expect(obj["success"] as? Bool == false)
    #expect(obj["error"] as? String == "readback_unavailable")
    #expect(obj["hint"] as? String == "write executed but could not be verified")
}

@Test func testReadbackUnavailableInTerminalErrorCodes() {
    #expect(HonestContract.terminalErrorCodes.contains("readback_unavailable"))
}

@Test func testStateCErrorCodeExtraction() {
    let terminal = HonestContract.encodeStateC(error: .elementNotFound)
    let nonTerminal = HonestContract.encodeStateC(error: .axWriteFailed)
    let uncertain = HonestContract.encodeStateB(reason: .readbackUnavailable)

    #expect(HonestContract.stateCErrorCode(terminal) == "element_not_found")
    #expect(HonestContract.stateCErrorCode(nonTerminal) == "ax_write_failed")
    #expect(HonestContract.stateCErrorCode(uncertain) == nil)
    #expect(HonestContract.stateCErrorCode("not json") == nil)
}

@Test func testJSONIsSortedKeyDeterministic() {
    let a = HonestContract.jsonString(["b": 1, "a": 2])
    let b = HonestContract.jsonString(["a": 2, "b": 1])
    #expect(a == b, "same logical object should serialize identically regardless of insertion order")
}

// MARK: - addExtras (caller-side post-encode top-level merge)

@Test("addExtras: State A 응답에 extras top-level merge")
func testAddExtras_stateA_mergesAtTopLevel() throws {
    let raw = HonestContract.encodeStateA(extras: ["requested": "1.1.1.1"])
    let merged = HonestContract.addExtras(["caller_flag": true], into: raw)
    let obj = try #require(sharedJSONObject(merged))
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == true)
    #expect(obj["requested"] as? String == "1.1.1.1", "기존 extras 보존")
    #expect(obj["caller_flag"] as? Bool == true, "신규 caller extras 추가")
}

@Test("addExtras: State B 응답에 reason 보존 + extras merge")
func testAddExtras_stateB_preservesReasonAndMerges() throws {
    let raw = HonestContract.encodeStateB(reason: .readbackUnavailable)
    let merged = HonestContract.addExtras(["caller_flag": true], into: raw)
    let obj = try #require(sharedJSONObject(merged))
    #expect(obj["success"] as? Bool == true)
    #expect(obj["verified"] as? Bool == false)
    #expect(obj["reason"] as? String == "readback_unavailable", "State B reason 보존")
    #expect(obj["caller_flag"] as? Bool == true)
}

@Test("addExtras: State C (success:false) 는 변경 없이 통과 — error 보존")
func testAddExtras_stateC_skipsMerge() {
    let raw = HonestContract.encodeStateC(error: .axWriteFailed, hint: "permission?")
    let merged = HonestContract.addExtras(["caller_flag": true], into: raw)
    #expect(merged == raw, "State C raw 그대로 — caller extras 추가 금지")
}

@Test("addExtras: 비-JSON 입력 → 원본 그대로")
func testAddExtras_invalidJSON_returnsRaw() {
    let raw = "not json"
    let merged = HonestContract.addExtras(["caller_flag": true], into: raw)
    #expect(merged == raw)
}
