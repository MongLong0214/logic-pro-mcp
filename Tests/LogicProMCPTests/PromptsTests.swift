import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Prompts")
struct PromptsTests {
    @Test("prompts_list_and_get_roundtrip")
    func promptsListAndGetRoundtrip() async throws {
        let server = LogicProServer()
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        _ = try await waitForProbeResponse(transport, id: 1)

        await transport.queueJSON(probeRequestFrame(id: 2, method: "prompts/list", params: "{}"))
        let listResponse = try await waitForProbeResponse(transport, id: 2)
        let listResult = try #require(listResponse["result"] as? [String: Any])
        let prompts = try #require(listResult["prompts"] as? [[String: Any]])
        let expected = WorkflowSkillCatalog.defaultSnapshot().workflows
        #expect(prompts.count == expected.count)

        let firstWorkflow = try #require(expected.first)
        let firstPrompt = try #require(prompts.first)
        #expect(firstPrompt["name"] as? String == firstWorkflow.id)
        #expect(firstPrompt["title"] as? String == firstWorkflow.title)

        await transport.queueJSON(probeRequestFrame(
            id: 3,
            method: "prompts/get",
            params: #"{"name":"\#(firstWorkflow.id)"}"#
        ))
        let getResponse = try await waitForProbeResponse(transport, id: 3)
        let getResult = try #require(getResponse["result"] as? [String: Any])
        #expect(getResult["description"] as? String == firstWorkflow.intent)

        let messages = try #require(getResult["messages"] as? [[String: Any]])
        let message = try #require(messages.first)
        let content = try #require(message["content"] as? [String: Any])
        let text = try #require(content["text"] as? String)
        let workflowJSON = try #require(sharedJSONObject(text))
        #expect(workflowJSON["id"] as? String == firstWorkflow.id)
    }

    @Test("capabilities_advertise_subscribe_and_prompts")
    func capabilitiesAdvertiseSubscribeAndPrompts() async throws {
        let server = LogicProServer()
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        let initializeResponse = try await waitForProbeResponse(transport, id: 1)
        let result = try #require(initializeResponse["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        let resources = try #require(capabilities["resources"] as? [String: Any])
        let prompts = try #require(capabilities["prompts"] as? [String: Any])

        #expect(try #require(resources["subscribe"] as? Bool))
        let v1 = try #require(prompts["listChanged"] as? Bool)
        #expect(!v1)
    }
}
