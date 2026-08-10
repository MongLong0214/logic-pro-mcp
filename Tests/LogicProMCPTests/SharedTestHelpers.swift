import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Some CI and agent sandboxes deny LaunchServices process inspection and the CoreMIDI
/// service connection, so tests that need either are skipped there and remain live
/// qualification instead. A sandbox announces itself by exporting a seatbelt marker.
///
/// The marker's own name is not written here: this repository's public-surface check
/// forbids naming the tooling that produced a build, and a test helper has no reason to.
/// Set `LOGIC_MCP_SANDBOX=seatbelt` to opt in explicitly on any host.
let restrictedSandboxActive: Bool = {
    let env = ProcessInfo.processInfo.environment
    if env["LOGIC_MCP_SANDBOX"] == "seatbelt" { return true }
    return env.contains { $0.key.hasSuffix("_SANDBOX") && $0.value == "seatbelt" }
}()
let processInspectionUnavailableInSandbox: ConditionTrait = .disabled(
    if: restrictedSandboxActive,
    "This sandbox traps LaunchServices process inspection; the behaviour remains live qualification."
)
let coreMIDIUnavailableInSandbox: ConditionTrait = .disabled(
    if: restrictedSandboxActive,
    "This sandbox denies the CoreMIDI service connection; the behaviour remains live qualification."
)

/// PRD-007 — live AX header-scan fixture for `.corroborated` ops.
///
/// Mirrors `AXLogicProElements.trackNames()`'s shape (`[Int: String]?`, nil ==
/// unreadable). Seed-set ops (`tracks.delete` / `duplicate` / `set_instrument`,
/// `logic_plugins.insert_verified`) refuse a bare index, so any deterministic
/// test that wants one of them to REACH the router must supply both this scan
/// and a matching `expected_name` — exactly what a real caller must now do.
func sharedLiveTrackNames(_ names: [Int: String]) -> @Sendable () -> [Int: String]? {
    { names }
}

/// Extract text from a CallTool.Result, supporting both .text and .resource content types.
func sharedToolText(_ result: CallTool.Result) -> String {
    guard let first = result.content.first else { return "" }
    switch first {
    case .text(let text, _, _):
        return text
    case .resource(let resource, _, _):
        return resource.text ?? ""
    default:
        return ""
    }
}

/// Extract text from a ReadResource.Result.
func sharedResourceText(_ result: ReadResource.Result) -> String {
    guard let content = result.contents.first else { return "" }
    return content.text ?? ""
}

/// Parse a string as generic JSON.
func sharedParseJSON(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}

/// Try to parse a string as a top-level JSON object.
func sharedJSONObject(_ text: String) -> [String: Any]? {
    (try? sharedParseJSON(text)) as? [String: Any]
}

/// Try to parse a string as a top-level JSON array.
func sharedJSONArray(_ text: String) -> [[String: Any]]? {
    (try? sharedParseJSON(text)) as? [[String: Any]]
}

/// Actor that records server lifecycle events for runtime-override tests.
actor SharedServerStartRecorder {
    var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}
