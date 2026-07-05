import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Issue141 library modal preconditions")
struct Issue141LibraryModalPreconditionTests {
    private actor TrackingChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        private var executedOps: [(String, [String: String])] = []

        func start() async throws {}
        func stop() async {}

        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            executedOps.append((operation, params))
            return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
        }

        func healthCheck() async -> ChannelHealth {
            .healthy(detail: "tracking channel")
        }

        func operations() -> [(String, [String: String])] {
            executedOps
        }
    }

    private func call(
        command: String,
        params: [String: Value],
        dialogPresent: @escaping @Sendable () -> Bool = { true }
    ) async -> (CallTool.Result, TrackingChannel) {
        let router = ChannelRouter()
        let channel = TrackingChannel()
        await router.register(channel)
        let result = await TrackDispatcher.handle(
            command: command,
            params: params,
            router: router,
            cache: StateCache(),
            dialogPresent: dialogPresent
        )
        return (result, channel)
    }

    @Test("set_instrument refuses before routing while a blocking dialog is present")
    func setInstrumentRefusesBlockingDialog() async throws {
        let (result, channel) = await call(
            command: "set_instrument",
            params: ["index": .int(1), "path": .string("Bass/Sub Bass")]
        )

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(json["error"] as? String == "unsupported_state")
        #expect(json["operation"] as? String == "track.set_instrument")
        #expect(json["failure_stage"] as? String == "preflight_blocking_dialog")
        #expect((json["blocking_dialog_present"] as? Bool)!)
        #expect(!((json["write_attempted"] as? Bool)!))
        #expect(await channel.operations().isEmpty)
    }

    @Test("list_library refuses before routing while a blocking dialog is present")
    func listLibraryRefusesBlockingDialog() async throws {
        let (result, channel) = await call(command: "list_library", params: [:])

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(json["error"] as? String == "unsupported_state")
        #expect(json["operation"] as? String == "library.list")
        #expect(json["failure_stage"] as? String == "preflight_blocking_dialog")
        #expect(await channel.operations().isEmpty)
    }

    @Test("scan_plugin_presets refuses before routing while a blocking dialog is present")
    func scanPluginPresetsRefusesBlockingDialog() async throws {
        let (result, channel) = await call(command: "scan_plugin_presets", params: [:])

        let isError = try #require(result.isError)
        #expect(isError)
        let json = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(json["error"] as? String == "unsupported_state")
        #expect(json["operation"] as? String == "plugin.scan_presets")
        #expect(json["failure_stage"] as? String == "preflight_blocking_dialog")
        #expect(await channel.operations().isEmpty)
    }

    @Test("disk-only scan_library remains available while a blocking dialog is present")
    func diskOnlyScanLibraryBypassesBlockingDialogGuard() async throws {
        let (result, channel) = await call(
            command: "scan_library",
            params: ["mode": .string("disk")]
        )

        let isError = try #require(result.isError)
        #expect(!isError)
        #expect(await channel.operations().map(\.0) == ["library.scan_all"])
    }

    @Test("default scan_library remains available while a blocking dialog is present")
    func defaultScanLibraryBypassesBlockingDialogGuard() async throws {
        let (result, channel) = await call(command: "scan_library", params: [:])

        let isError = try #require(result.isError)
        #expect(!isError)
        #expect(await channel.operations().map(\.0) == ["library.scan_all"])
    }
}
