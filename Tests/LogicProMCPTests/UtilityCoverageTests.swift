import MCP
import Testing
@testable import LogicProMCP

private struct FailingJSONValue: Encodable {
    let value: Double = .nan
}

@Test func testEncodeJSONReturnsFallbackWhenEncodingFails() {
    let json = encodeJSON(FailingJSONValue())
    #expect(json == "{\"error\": \"Failed to encode response\"}")
}

@Test func testDispatcherSupportHelpersUseFallbackValues() {
    let params: [String: Value] = [
        "numbers": .array([.int(60), .int(64), .int(67)]),
        "name": .string("Lead"),
    ]

    #expect(intParam(params, "missing", default: 7) == 7)
    #expect(doubleParam(params, "missing", default: 0.25) == 0.25)
    #expect(stringParam(params, "missing", default: "fallback") == "fallback")
    #expect(boolParam(params, "missing", default: true) == true)
    #expect(csvIntListOrStringParam(params, key: "numbers") == "60,64,67")
}

@Test func testDispatcherSupportHelpersRespectProvidedValues() {
    let params: [String: Value] = [
        "track": .int(9),
        "tempo": .double(128.5),
        "name": .string("Verse"),
        "enabled": .bool(false),
        "numbers": .string("1,2,3"),
    ]

    #expect(intParam(params, "track", default: 0) == 9)
    #expect(doubleParam(params, "tempo", default: 0) == 128.5)
    #expect(stringParam(params, "name", default: "") == "Verse")
    #expect(boolParam(params, "enabled", default: true) == false)
    #expect(csvIntListOrStringParam(params, key: "numbers") == "1,2,3")
}
