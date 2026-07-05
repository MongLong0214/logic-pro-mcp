import Foundation
import MCP
import Testing
@testable import LogicProMCP

private struct FailingJSONValue: Encodable {
    let value: Double = .nan
}

@Test func testEncodeJSONReturnsFallbackWhenEncodingFails() {
    let json = encodeJSON(FailingJSONValue())
    // Fallback payload is now self-describing: names the failing type and
    // preserves the underlying error message for debugging.
    #expect(json.contains("\"error\""))
    #expect(json.contains("FailingJSONValue"))
    // Still valid JSON so MCP clients can parse it as a structured error.
    #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
}

@Test func testDispatcherSupportStrictHelpersReturnNilForMissingOrInvalidValues() {
    let params: [String: Value] = [
        "badInt": .double(1.5),
        "badDouble": .string("not-a-number"),
        "badBool": .int(2),
    ]

    #expect(intParamOrNil(params, "missing") == nil)
    #expect(intParamOrNil(params, "badInt") == nil)
    #expect(doubleParamOrNil(params, "missing") == nil)
    #expect(doubleParamOrNil(params, "badDouble") == nil)
    #expect(boolParamOrNil(params, "missing") == nil)
    #expect(boolParamOrNil(params, "badBool") == nil)
    #expect(stringParam(params, "missing", default: "fallback") == "fallback")
}

@Test func testDispatcherSupportHelpersRespectProvidedValues() {
    let params: [String: Value] = [
        "track": .int(9),
        "tempo": .double(128.5),
        "name": .string("Verse"),
        "enabled": .bool(false),
        "numbers": .string("1,2,3"),
    ]

    #expect(intParamOrNil(params, "track") == 9)
    #expect(doubleParamOrNil(params, "tempo") == 128.5)
    #expect(stringParam(params, "name", default: "") == "Verse")
    #expect(!(boolParamOrNil(params, "enabled")!))
}
