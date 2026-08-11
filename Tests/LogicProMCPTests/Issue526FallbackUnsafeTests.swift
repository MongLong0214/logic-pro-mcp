import Testing
@testable import LogicProMCP

private actor Issue526ErrorChannel: Channel {
    nonisolated let id: ChannelID
    private let envelope: String
    private var executionCount = 0

    init(id: ChannelID, envelope: String) {
        self.id = id
        self.envelope = envelope
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executionCount += 1
        return .error(envelope)
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "Issue526 error channel")
    }

    func executions() -> Int {
        executionCount
    }
}

private actor Issue526SuccessProbeChannel: Channel {
    nonisolated let id: ChannelID
    private var executionCount = 0

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executionCount += 1
        return .success("Issue526 fallback executed")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "Issue526 success probe")
    }

    func executions() -> Int {
        executionCount
    }
}

@Test func testIssue526FallbackUnsafeStateCStopsMultiChannelFallback() async {
    let router = ChannelRouter()
    let envelope = HonestContract.encodeStateC(
        error: .axWriteFailed,
        hint: "Delete is unsafe without Marker List keyboard focus",
        extras: [
            "fallback_unsafe": true,
            "write_attempted": false,
        ]
    )
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: envelope)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.delete_marker", params: ["index": "1"])

    #expect(!result.isSuccess)
    #expect(result.message == envelope)
    #expect(HonestContract.isFallbackUnsafeStateC(result.message))
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 0)
}

@Test func testIssue526StateCWithoutFallbackUnsafeStillFallsThrough() async {
    let router = ChannelRouter()
    let envelope = HonestContract.encodeStateC(
        error: .axWriteFailed,
        hint: "AX write failed for a channel-local reason",
        extras: ["write_attempted": false]
    )
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: envelope)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.delete_marker", params: ["index": "1"])

    #expect(result.isSuccess)
    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 1)
}

@Test func testIssue526FallbackUnsafeTerminalStateCRemainsVerbatim() async {
    let router = ChannelRouter()
    let envelope = HonestContract.encodeStateC(
        error: .elementNotFound,
        hint: "Marker List row was not found",
        extras: ["fallback_unsafe": true]
    )
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: envelope)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.delete_marker", params: ["index": "1"])

    #expect(!result.isSuccess)
    #expect(result.message == envelope)
    #expect(HonestContract.isTerminalStateC(result.message))
    #expect(HonestContract.isFallbackUnsafeStateC(result.message))
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 0)
}
