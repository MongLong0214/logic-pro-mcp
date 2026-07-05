import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Issue144 project modal preconditions")
struct Issue144ProjectModalPreconditionTests {
    private actor TrackingProjectChannel: Channel {
        nonisolated let id: ChannelID = .appleScript
        private var executedOps: [(String, [String: String])] = []

        func start() async throws {}
        func stop() async {}

        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            executedOps.append((operation, params))
            return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
        }

        func healthCheck() async -> ChannelHealth {
            .healthy(detail: "tracking project channel")
        }

        func operations() -> [(String, [String: String])] {
            executedOps
        }
    }

    private func call(
        command: String,
        params: [String: Value] = [:]
    ) async -> (CallTool.Result, TrackingProjectChannel) {
        let router = ChannelRouter()
        let channel = TrackingProjectChannel()
        await router.register(channel)
        let result = await ProjectDispatcher.handle(
            command: command,
            params: params,
            router: router,
            cache: StateCache(),
            dialogPresent: { true }
        )
        return (result, channel)
    }

    @Test("project.new refuses before routing while a blocking dialog is present")
    func projectNewRefusesBlockingDialog() async throws {
        let (result, channel) = await call(command: "new")

        try assertBlockingDialog(result, operation: "project.new")
        #expect(await channel.operations().isEmpty)
    }

    @Test("project.save refuses before routing while a blocking dialog is present")
    func projectSaveRefusesBlockingDialog() async throws {
        let (result, channel) = await call(command: "save")

        try assertBlockingDialog(result, operation: "project.save")
        #expect(await channel.operations().isEmpty)
    }

    @Test("project.bounce refuses before routing while a blocking dialog is present")
    func projectBounceRefusesBlockingDialog() async throws {
        let (result, channel) = await call(
            command: "bounce",
            params: ["confirmed": .bool(true)]
        )

        try assertBlockingDialog(result, operation: "project.bounce")
        #expect(await channel.operations().isEmpty)
    }

    private func assertBlockingDialog(_ result: CallTool.Result, operation: String) throws {
        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(json["error"] as? String == "unsupported_state")
        #expect(json["operation"] as? String == operation)
        #expect(json["failure_stage"] as? String == "preflight_blocking_dialog")
        #expect((json["blocking_dialog_present"] as? Bool)!)
        #expect(!((json["write_attempted"] as? Bool)!))
    }
}
