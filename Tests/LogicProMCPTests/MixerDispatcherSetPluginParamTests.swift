import Foundation
import Testing
@testable import LogicProMCP

private actor StateBSelectForPluginMockChannel: Channel {
    nonisolated let id: ChannelID = .mcu
    var executedOps: [(String, [String: String])] = []

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        if operation == "track.select" {
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: [
                    "requested": Int(params["index"] ?? "0") ?? 0,
                    "observed": NSNull(),
                ]
            ))
        }
        return .success("Mock: \(operation)")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "state-b select for plugin mock")
    }
}

@Test func testSetPluginParamRefusesOnUnverifiedSelection() async {
    let router = ChannelRouter()
    let mcu = StateBSelectForPluginMockChannel()
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: [
            "track": .int(2),
            "insert": .int(0),
            "param": .int(3),
            "value": .double(0.5),
        ],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!, "set_plugin_param must error on State B select")
    let text = sharedToolText(result)
    let object = try? #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(!((object?["success"] as? Bool)!))
    #expect(object?["error"] as? String == "readback_mismatch")
    #expect(((object?["hint"] as? String)?.contains("set_plugin_param refused"))!)
    let selectResponse = object?["select_response"] as? String
    #expect((selectResponse?.contains("\"verified\":false"))!)

    let mcuOps = await mcu.executedOps
    let scripterOps = await scripter.executedOps
    #expect(mcuOps.map(\.0) == ["track.select"])
    #expect(scripterOps.isEmpty, "plugin.set_param must not route after unverified select")
}

@Test func testSetPluginParamProceedsOnVerifiedSelection() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: [
            "track": .int(4),
            "insert": .int(0),
            "param": .int(5),
            "value": .double(0.75),
        ],
        router: router,
        cache: StateCache()
    )

    #expect(!(result.isError!), "verified selection should route to Scripter")

    let mcuOps = await mcu.executedOps
    let scripterOps = await scripter.executedOps
    #expect(mcuOps.count == 1)
    #expect(mcuOps[0].0 == "track.select")
    #expect(mcuOps[0].1 == ["index": "4"])
    #expect(scripterOps.count == 1)
    #expect(scripterOps[0].0 == "plugin.set_param")
    #expect(scripterOps[0].1 == [
        "track": "4",
        "insert": "0",
        "param": "5",
        "value": "0.75",
    ])
}

// Phase 6 P1 (RB-1.a): a non-numeric `value` must be rejected BEFORE the
// track.select side effect — not coerced to 0.0 and written.
@Test func testSetPluginParamRejectsNonNumericValueWithoutSideEffect() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(0), "param": .int(3), "value": .string("abc")],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(sharedToolText(result).contains("numeric"))
    let mcuOps = await mcu.executedOps
    let scripterOps = await scripter.executedOps
    #expect(mcuOps.isEmpty, "non-numeric value must be rejected before track.select")
    #expect(scripterOps.isEmpty)
}

// Out-of-range value (>1.0) rejected before any side effect.
@Test func testSetPluginParamRejectsOutOfRangeValueWithoutSideEffect() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(0), "param": .int(3), "value": .double(2.0)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(sharedToolText(result).contains("0.0...1.0"))
    #expect(await mcu.executedOps.isEmpty, "out-of-range value must be rejected before track.select")
}

// param > 17 (outside Scripter CC 102–119) rejected before any side effect.
@Test func testSetPluginParamRejectsOutOfRangeParamWithoutSideEffect() async {
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let scripter = MockChannel(id: .scripter)
    await router.register(mcu)
    await router.register(scripter)

    let result = await MixerDispatcher.handle(
        command: "set_plugin_param",
        params: ["track": .int(1), "insert": .int(0), "param": .int(18), "value": .double(0.5)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!)
    #expect(sharedToolText(result).contains("0...17"))
    #expect(await mcu.executedOps.isEmpty, "out-of-range param must be rejected before track.select")
}
