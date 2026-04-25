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

@Test func testJSONIsSortedKeyDeterministic() {
    let a = HonestContract.jsonString(["b": 1, "a": 2])
    let b = HonestContract.jsonString(["a": 2, "b": 1])
    #expect(a == b, "same logical object should serialize identically regardless of insertion order")
}
