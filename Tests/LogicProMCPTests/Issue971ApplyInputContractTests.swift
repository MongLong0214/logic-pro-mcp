import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#971 apply input validation precedes provider availability", .serialized)
struct Issue971ApplyInputContractTests {
    private actor Provider {
        private(set) var calls = 0
        func apply() -> CallTool.Result {
            calls += 1
            return toolTextResult(HonestContract.encodeStateA(extras: ["write_attempted": true]))
        }
    }

    private func validParameters() -> [String: Value] {
        ["plan_id": .string("plan_input_fixture"), "digest": .string(String(repeating: "0", count: 64)),
         "confirmed": .bool(true), "idempotency_key": .string("input-fixture")]
    }

    private func dispatch(_ params: [String: Value], provider: (@Sendable (ApprovedSessionRepair.ApplyRequest) async -> CallTool.Result)?) async -> CallTool.Result {
        await ProjectDispatcher.handle(command: "apply_session_repair", params: params,
            router: ChannelRouter(), cache: StateCache(), isLogicProRunning: { false },
            executeLifecycleScript: { _ in Issue.record("lifecycle execution forbidden"); return .init(executionError: "forbidden", timedOut: false, terminationStatus: 1, stderrOutput: "") },
            blockingDialogInfo: { nil }, cleanupAuditFileReader: .unavailable, applySessionRepair: provider)
    }

    @Test(arguments: ["missing_plan_id", "missing_digest", "missing_confirmed", "missing_idempotency_key",
                      "empty_plan", "short_digest", "integer_digest", "false_confirmed", "string_confirmed",
                      "empty_key", "integer_key", "unknown_key"], [false, true])
    func invalidRequestCannotDependOnOrReachAProvider(kind: String, hasProvider: Bool) async throws {
        let provider = Provider()
        var params = validParameters()
        switch kind {
        case "missing_plan_id": params.removeValue(forKey: "plan_id")
        case "missing_digest": params.removeValue(forKey: "digest")
        case "missing_confirmed": params.removeValue(forKey: "confirmed")
        case "missing_idempotency_key": params.removeValue(forKey: "idempotency_key")
        case "empty_plan": params["plan_id"] = .string("")
        case "short_digest": params["digest"] = .string("0")
        case "integer_digest": params["digest"] = .int(64)
        case "false_confirmed": params["confirmed"] = .bool(false)
        case "string_confirmed": params["confirmed"] = .string("true")
        case "empty_key": params["idempotency_key"] = .string("")
        case "integer_key": params["idempotency_key"] = .int(1)
        case "unknown_key": params["caller_authority"] = .bool(true)
        default: Issue.record("unknown fixture case")
        }
        let callback: (@Sendable (ApprovedSessionRepair.ApplyRequest) async -> CallTool.Result)?
        if hasProvider { callback = { _ in await provider.apply() } } else { callback = nil }
        let result = await dispatch(params, provider: callback)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(await provider.calls == 0)
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "invalid_params")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
    }

    @Test(arguments: [false, true])
    func aValidRequestRetainsProviderAvailabilityBehavior(hasProvider: Bool) async throws {
        let provider = Provider()
        let callback: (@Sendable (ApprovedSessionRepair.ApplyRequest) async -> CallTool.Result)?
        if hasProvider { callback = { _ in await provider.apply() } } else { callback = nil }
        let body = try #require(sharedJSONObject(sharedToolText(await dispatch(validParameters(), provider: callback))))
        #expect(body["state"] as? String == (hasProvider ? "A" : "C"))
        #expect(await provider.calls == (hasProvider ? 1 : 0))
        if !hasProvider { #expect(body["error"] as? String == "unsupported_state") }
    }
}
