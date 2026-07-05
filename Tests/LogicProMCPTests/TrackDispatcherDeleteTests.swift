import Foundation
import Testing
@testable import LogicProMCP

// v3.1.2 P1-5 — `track.delete` must refuse to proceed when the preceding
// `track.select` returns a State B envelope (`verified:false`). Allowing
// delete to follow an unverified select is a data-loss vector: the
// previously-selected track gets deleted instead of the requested target,
// and there is no UI signal that the operation hit the wrong row.

// MARK: - Mocks

/// Returns a State B envelope for `track.select` (verified:false,
/// reason: "retry_exhausted"), and the generic mock reply for everything
/// else. Used to simulate the live AX path where the AX write is delivered
/// but the read-back can't confirm selection landed on the requested track.
private actor StateBSelectMockChannel: Channel {
    nonisolated let id: ChannelID
    var executedOps: [(String, [String: String])] = []

    init(id: ChannelID) {
        self.id = id
    }

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
        .healthy(detail: "state-b select mock")
    }
}

// MARK: - Tests

@Test func testDeleteRefusesOnUnverifiedSelection() async {
    // Arrange: the only channel registered for `track.select` returns
    // State B (verified:false). The keyCmd channel handles `track.delete`,
    // and we'll assert that it never gets called.
    let router = ChannelRouter()
    let mcu = StateBSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    // Act
    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(2)],
        router: router,
        cache: StateCache()
    )

    // Assert — dispatcher returned an error and never routed `track.delete`.
    #expect(result.isError!, "delete must error on State B select")
    let text = sharedToolText(result)
    #expect(
        text.contains("track.delete refused"),
        "expected explicit refusal wording, got: \(text)"
    )
    #expect(
        text.contains("State B") || text.contains("unverified"),
        "expected mention of State B / unverified, got: \(text)"
    )

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 1, "track.select should have been routed exactly once")
    #expect(mcuOps[0].0 == "track.select")
    #expect(keyCmdOps.isEmpty, "track.delete must NOT be routed after State B select")
}

@Test func testDeleteProceedsOnVerifiedSelection() async {
    // Companion to the State B refusal test: confirm the verified path
    // still completes end-to-end. `VerifiedSelectMockChannel` lives in
    // DispatcherTests.swift (same target).
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(3)],
        router: router,
        cache: StateCache()
    )

    #expect(!(result.isError!), "delete must succeed on State A select")

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 1)
    #expect(mcuOps[0].0 == "track.select")
    #expect(mcuOps[0].1 == ["index": "3"])
    #expect(keyCmdOps.count == 1)
    #expect(keyCmdOps[0].0 == "track.delete")
}

// RB-1.c (2026-05-08 enterprise review): `track.duplicate` mirrors
// `track.delete`'s State-A gate. Pre-fix duplicate proceeded on any
// `selectResult.isSuccess`, including State-B (verified:false) — which
// meant duplicating whatever was actually selected when the AX read-back
// couldn't confirm the requested track. Post-fix duplicate refuses with
// the same hint pattern so the caller can re-issue selection.
@Test func testDuplicateRefusesOnUnverifiedSelection() async {
    let router = ChannelRouter()
    let mcu = StateBSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(3)],
        router: router,
        cache: StateCache()
    )

    #expect(result.isError!, "duplicate must error on State B select")
    let text = sharedToolText(result)
    #expect(
        text.contains("track.duplicate refused"),
        "expected explicit refusal wording, got: \(text)"
    )
    #expect(
        text.contains("State B") || text.contains("unverified"),
        "expected mention of State B / unverified, got: \(text)"
    )

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 1, "track.select should have been routed exactly once")
    #expect(mcuOps[0].0 == "track.select")
    #expect(keyCmdOps.isEmpty, "track.duplicate must NOT be routed after State B select")
}

@Test func testDuplicateProceedsOnVerifiedSelection() async {
    // Companion to the State B refusal test for duplicate.
    let router = ChannelRouter()
    let mcu = VerifiedSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "duplicate",
        params: ["index": .int(4)],
        router: router,
        cache: StateCache()
    )

    #expect(!(result.isError!), "duplicate must succeed on State A select")

    let mcuOps = await mcu.executedOps
    let keyCmdOps = await keyCmd.executedOps
    #expect(mcuOps.count == 1)
    #expect(mcuOps[0].0 == "track.select")
    #expect(mcuOps[0].1 == ["index": "4"])
    #expect(keyCmdOps.count == 1)
    #expect(keyCmdOps[0].0 == "track.duplicate")
}

@Test func testDeleteRefusalIncludesSelectResponseDetail() async {
    // Diagnostic detail check — the refusal message must surface the
    // original select envelope so the caller can debug WHICH State B
    // branch fired (retry_exhausted vs readback_mismatch vs ...).
    let router = ChannelRouter()
    let mcu = StateBSelectMockChannel(id: .mcu)
    let keyCmd = MockChannel(id: .midiKeyCommands)
    await router.register(mcu)
    await router.register(keyCmd)

    let result = await TrackDispatcher.handle(
        command: "delete",
        params: ["index": .int(7)],
        router: router,
        cache: StateCache()
    )

    let text = sharedToolText(result)
    let object = try? #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(!((object?["success"] as? Bool)!))
    #expect(object?["error"] as? String == "readback_mismatch")
    let selectResponse = object?["select_response"] as? String
    #expect((selectResponse?.contains("retry_exhausted"))!, "expected reason forwarded, got: \(text)")
    #expect((selectResponse?.contains("\"verified\":false"))!, "expected envelope detail, got: \(text)")
}
