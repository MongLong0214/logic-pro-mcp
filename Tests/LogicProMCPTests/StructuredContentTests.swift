import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor StructuredContentJSONChannel: Channel {
    nonisolated let id: ChannelID = .mcu
    private let response: String

    init(response: String) {
        self.response = response
    }

    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "structured-content-stub") }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "transport.rewind" else {
            return .error("unexpected operation: \(operation)")
        }
        return .success(response)
    }
}

@Suite(.serialized)
struct StructuredContentTests {
    @Test("tools_call_includes_structured_content_all_tools")
    func toolsCallIncludesStructuredContentAllTools() async throws {
        let server = LogicProServer()
        let handlers = await server.makeHandlers()
        let cases: [(tool: String, command: String, params: [String: Value])] = [
            ("logic_transport", "set_tempo", [:]),
            ("logic_tracks", "rename", [:]),
            ("logic_mixer", "set_volume", [:]),
            ("logic_midi", "send_note", [:]),
            ("logic_edit", "quantize", [:]),
            ("logic_navigate", "goto_bar", [:]),
            ("logic_project", "open", [:]),
            ("logic_audio", "analyze_file", [:]),
            ("logic_system", "health", [:]),
            ("logic_plugins", "set_param_verified", [
                "track": .int(0),
                "insert": .int(2),
                "plugin": .string("Gain"),
                "param": .string("gain_db"),
                "value": .double(-4.0),
                "unit": .string("dB"),
                "mode": .string("duplicate_applyback"),
                "project_expected_path": .string("/tmp/x.logicx"),
            ]),
        ]

        #expect(ServerCatalog.tools.count == 10)
        for tool in ServerCatalog.tools {
            #expect(tool.outputSchema != nil, "\(tool.name) must advertise outputSchema")
        }

        let gateHeld = VerifiedOpGate.shared.tryAcquire()
        #expect(gateHeld)
        defer { VerifiedOpGate.shared.release() }

        for item in cases {
            let result = await handlers.callTool(.init(
                name: item.tool,
                arguments: [
                    "command": .string(item.command),
                    "params": .object(item.params),
                ]
            ))
            let text = sharedToolText(result)
            let textObject = try #require(sharedJSONObject(text), "\(item.tool).\(item.command) must return JSON object text")
            let structured = try #require(result.structuredContent, "\(item.tool).\(item.command) must include structuredContent")
            let structuredData = try JSONEncoder().encode(structured)
            let structuredObject = try #require(JSONSerialization.jsonObject(with: structuredData) as? [String: Any])

            #expect(try canonicalJSONObjectData(structuredObject) == canonicalJSONObjectData(textObject))
        }
    }

    @Test("tools_call_probe_includes_structured_content", codexSeatbeltProcessInspectionDisabled)
    func toolsCallProbeIncludesStructuredContent() async throws {
        let server = LogicProServer()
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        _ = try await waitForProbeResponse(transport, id: 1)

        await transport.queueJSON(probeToolCallFrame(id: 2, name: "logic_system", command: "health"))
        let response = try await waitForProbeResponse(transport, id: 2)
        let result = try #require(response["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let firstContent = try #require(content.first)
        let text = try #require(firstContent["text"] as? String)
        let textObject = try #require(sharedJSONObject(text))
        let structured = try #require(result["structuredContent"] as? [String: Any])

        #expect(try canonicalJSONObjectData(structured) == canonicalJSONObjectData(textObject))
    }

    @Test("channel_result_path_dispatcher_response_includes_structured_content")
    func channelResultPathDispatcherResponseIncludesStructuredContent() async throws {
        let json = #"{"success":true,"verified":false,"state":"B","operation":"transport.rewind"}"#
        let router = ChannelRouter()
        await router.register(StructuredContentJSONChannel(response: json))

        let result = await TransportDispatcher.handle(
            command: "rewind",
            params: [:],
            router: router,
            cache: StateCache()
        )
        let textObject = try #require(sharedJSONObject(sharedToolText(result)))
        let structured = try #require(result.structuredContent)
        let structuredData = try JSONEncoder().encode(structured)
        let structuredObject = try #require(JSONSerialization.jsonObject(with: structuredData) as? [String: Any])

        #expect(try canonicalJSONObjectData(structuredObject) == canonicalJSONObjectData(textObject))
    }
}
