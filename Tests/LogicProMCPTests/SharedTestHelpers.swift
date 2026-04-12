import Foundation
import MCP
@testable import LogicProMCP

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
