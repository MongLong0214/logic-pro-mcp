@preconcurrency import ApplicationServices
import Foundation
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

private func issue526SelectionFailureRuntime() -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(52_600)
    let arrange = builder.element(52_601)
    let markerList = builder.element(52_602)
    let table = builder.element(52_603)
    let row = builder.element(52_604)
    let lockCell = builder.element(52_605)
    let positionCell = builder.element(52_606)
    let markerNameCell = builder.element(52_607)
    let position = builder.element(52_608)
    let markerName = builder.element(52_609)

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Issue526 - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Issue526.logicx")
    builder.setAttribute(markerList, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Issue526 - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Issue526.logicx")
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(row, kAXRoleAttribute as String, kAXRowRole as String)
    for cell in [lockCell, positionCell, markerNameCell] {
        builder.setAttribute(cell, kAXRoleAttribute as String, kAXCellRole as String)
    }
    builder.setAttribute(position, kAXDescriptionAttribute as String, "1 1 1 1")
    builder.setAttribute(markerName, kAXDescriptionAttribute as String, "Target")
    builder.setChildren(positionCell, [position])
    builder.setChildren(markerNameCell, [markerName])
    builder.setChildren(row, [lockCell, positionCell, markerNameCell])
    builder.setAttribute(table, "AXRows", [row])
    builder.setChildren(table, [row])
    builder.setChildren(markerList, [table])

    // The row's selected attribute may be set, but the table never confirms it in
    // AXSelectedRows, which makes selectMarkerRowForDeletion refuse to press Delete.
    return builder.makeLogicRuntime(appElement: app)
}

private let issue526NoOpMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

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

@Test func testIssue526StateAExtrasCannotMasqueradeAsFallbackUnsafeStateC() {
    let envelope = HonestContract.encodeStateA(extras: [
        "success": false,
        "fallback_unsafe": true,
    ])

    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
}

@Test func testIssue526StateBEnvelopeWithMarkerIsNotFallbackUnsafeStateC() {
    let envelope = HonestContract.encodeStateB(
        reason: .readbackUnavailable,
        extras: [
            "success": false,
            "fallback_unsafe": true,
        ]
    )

    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
}

@Test func testIssue526FallbackUnsafeMarkerWithoutErrorStringIsNotFallbackUnsafeStateC() {
    let envelope = #"{"success":false,"state":"C","fallback_unsafe":true}"#

    #expect(!HonestContract.isFallbackUnsafeStateC(envelope))
}

@Test func testIssue526SelectionFailureRefusalIsFallbackUnsafeAndStopsChain() async {
    let refusal = await AccessibilityChannel.defaultDeleteMarker(
        index: 0,
        runtime: issue526SelectionFailureRuntime(),
        mouse: issue526NoOpMouseRuntime
    )
    let router = ChannelRouter()
    let accessibility = Issue526ErrorChannel(id: .accessibility, envelope: refusal.message)
    let keyCommands = Issue526SuccessProbeChannel(id: .midiKeyCommands)
    await router.register(accessibility)
    await router.register(keyCommands)

    let result = await router.route(operation: "nav.delete_marker", params: ["index": "0"])

    #expect(HonestContract.isFallbackUnsafeStateC(refusal.message))
    #expect(!result.isSuccess)
    #expect(result.message == refusal.message)
    #expect(await accessibility.executions() == 1)
    #expect(await keyCommands.executions() == 0)
}
