import MCP
import Testing
@testable import LogicProMCP

@Test func testToolTextContentProducesTextPayload() {
    let content = toolTextContent("Logic Pro MCP")

    switch content {
    case .text(let text, _, _):
        #expect(text == "Logic Pro MCP")
    default:
        Issue.record("Expected text tool content")
    }
}

@Test func testToolTextResultUsesExplicitErrorFlag() {
    let result = toolTextResult("boom", isError: true)

    #expect(result.isError == true)
    #expect(result.content.count == 1)
    if case .text(let text, _, _) = result.content[0] {
        #expect(text == "boom")
    } else {
        Issue.record("Expected text tool content")
    }
}

@Test func testToolTextResultReflectsChannelResultSuccessAndFailure() {
    let success = toolTextResult(ChannelResult.success("ok"))
    let failure = toolTextResult(ChannelResult.error("failed"))

    #expect(success.isError == false)
    #expect(failure.isError == true)

    if case .text(let text, _, _) = success.content[0] {
        #expect(text == "ok")
    } else {
        Issue.record("Expected success text tool content")
    }

    if case .text(let text, _, _) = failure.content[0] {
        #expect(text == "failed")
    } else {
        Issue.record("Expected failure text tool content")
    }
}

@Test func testCommandToolUsesSharedCommandSchema() {
    let tool = commandTool(
        name: "logic_test",
        description: "Test command tool",
        commandDescription: "Command under test"
    )

    #expect(tool.name == "logic_test")
    #expect(tool.description == "Test command tool")
    if case .object(let schema) = tool.inputSchema {
        #expect(schema["required"] != nil)
        if case .object(let properties) = schema["properties"] {
            #expect(properties["command"] != nil)
            #expect(properties["params"] != nil)
        } else {
            Issue.record("Expected properties object")
        }
    } else {
        Issue.record("Expected object input schema")
    }
}
