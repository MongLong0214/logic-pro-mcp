import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1092: rewind and fast_forward move the playhead one bar and stop. Apple's Rewind and Forward keys
// (Comma, Period) do that. The MCU Rewind/Forward buttons and MMC REWIND/FAST FORWARD start a shuttle
// that keeps winding after the reply: driven live in ko on 2026-10-03 from bar 9, the MCU rung read
// 5, 2, -3 at 0.5, 1.5 and 3 s for rewind and 13, 16, 19 for forward. So neither rung may answer,
// and a refused keystroke must not walk on to them.
//
// These tests drive the real router. Beside the CGEvent channel stand rungs that would answer
// anything: healthy, so the router does not skip them for health, and successful, so reaching one
// ends the walk with a reply. Each counts what reached it.

/// A rung that answers anything and records each operation that reaches it.
private actor AnsweringRung: Channel {
    nonisolated let id: ChannelID
    private(set) var reached: [String] = []

    init(_ id: ChannelID) { self.id = id }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        reached.append(operation)
        return .success("answered by \(id.rawValue)")
    }

    func healthCheck() async -> ChannelHealth { .healthy(detail: "test rung") }
}

private let steps: [(operation: String, keyCode: CGKeyCode)] = [
    ("transport.rewind", 43),        // Comma, Apple's Rewind
    ("transport.fast_forward", 47),  // Period, Apple's Forward
]

/// Every channel but CGEvent, as answering rungs.
private func answeringRungs() -> [AnsweringRung] {
    ChannelID.allCases.filter { $0 != .cgEvent }.map { AnsweringRung($0) }
}

private func reachedRungs(_ rungs: [AnsweringRung]) async -> [String] {
    var reached: [String] = []
    for rung in rungs {
        for operation in await rung.reached {
            reached.append("\(rung.id.rawValue): \(operation)")
        }
    }
    return reached
}

@Test func rewindAndForwardRouteToCGEventAlone() {
    // Mutation killed: `.mcu` or `.coreMIDI` put back in either chain.
    for step in steps {
        #expect(ChannelRouter.v2RoutingTable[step.operation] == [.cgEvent], "\(step.operation)")
    }
}

@Test func aStepIsApplesKeyAndNoOtherRungRuns() async throws {
    for step in steps {
        let recorder = CGEventRecorder()
        let router = ChannelRouter()
        let rungs = answeringRungs()
        await router.register(CGEventChannel(runtime: CGEventChannel.Runtime(
            isLogicProRunning: { true },
            logicProPID: { 42 },
            postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
            sleepMicros: { _ in }
        )))
        for rung in rungs { await router.register(rung) }

        let result = await router.route(operation: step.operation)

        #expect(result.isSuccess, "\(step.operation): \(result.message)")
        #expect(recorder.postedEvents.map(\.keyCode) == [step.keyCode], "\(step.operation)")
        let reached = await reachedRungs(rungs)
        #expect(reached.isEmpty, "\(step.operation) also reached \(reached)")
    }
}

@Test func aRefusedStepWalksOntoNoShuttle() async throws {
    // Logic is not frontmost and cannot be brought forward, so CGEvent refuses. The reply is that
    // refusal; no rung after it runs. Mutation killed: `.mcu` or `.coreMIDI` appended after
    // `.cgEvent`, where the old chain had them before it (reached by the router, the refusal turns
    // into a shuttle's success).
    for step in steps {
        let recorder = CGEventRecorder()
        let router = ChannelRouter()
        let rungs = answeringRungs()
        await router.register(CGEventChannel(runtime: CGEventChannel.Runtime(
            isLogicProRunning: { true },
            logicProPID: { 42 },
            postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
            sleepMicros: { _ in },
            isLogicFrontmost: { false },
            activateLogic: { false }
        )))
        for rung in rungs { await router.register(rung) }

        let result = await router.route(operation: step.operation)

        #expect(!result.isSuccess, "\(step.operation): \(result.message)")
        #expect(recorder.postedEvents.isEmpty, "\(step.operation)")
        let reached = await reachedRungs(rungs)
        #expect(reached.isEmpty, "\(step.operation) walked on to \(reached)")
    }
}

@Test func theShuttleRungsSendNothingForAStep() async {
    // Called directly, the MCU and CoreMIDI channels have no step to send and send nothing.
    // Mutation killed: either channel's old case restored (a button press or an MMC SysEx).
    for step in steps {
        let transport = MockMCUTransport()
        let mcu = await MCUChannel(transport: transport, cache: StateCache()).execute(operation: step.operation, params: [:])
        #expect(!mcu.isSuccess, "\(step.operation): \(mcu.message)")
        let pressed = await transport.sentBytes
        #expect(pressed.isEmpty, "\(step.operation) pressed \(pressed)")

        let engine = MockCoreMIDIEngine()
        let mmc = await CoreMIDIChannel(engine: engine).execute(operation: step.operation, params: [:])
        #expect(!mmc.isSuccess, "\(step.operation): \(mmc.message)")
        let sent = await engine.sysexMessages
        #expect(sent.isEmpty, "\(step.operation) sent \(sent)")
    }
}

// #1092 review R1, R1092-01: macOS discards a synthetic event this process is not authorized to post,
// and `postToPid` says nothing, so a State B success would report a key Logic never received. The
// channel asks first (`Runtime.canPostEvents`, `CGPreflightPostEventAccess` in production).

private final class Activations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() -> Bool {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return true
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private func unauthorizedChannel(_ recorder: CGEventRecorder, _ activations: Activations) -> CGEventChannel {
    CGEventChannel(runtime: CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 42 },
        postKeyEvent: { keyCode, flags, pid in recorder.post(keyCode: keyCode, flags: flags, pid: pid) },
        sleepMicros: { _ in },
        isLogicFrontmost: { false },
        activateLogic: { activations.record() },
        canPostEvents: { false }
    ))
}

private func stateCObject(_ result: ChannelResult) -> [String: Any]? {
    guard let data = result.message.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Test func aStepWithoutPostingAuthorizationIsRefusedAndWalksOntoNoShuttle() async throws {
    // Mutation killed: the check removed from the keystroke path (the key is posted, Logic is
    // activated, and the reply is a State B success).
    for step in steps {
        let recorder = CGEventRecorder()
        let activations = Activations()
        let router = ChannelRouter()
        let rungs = answeringRungs()
        await router.register(unauthorizedChannel(recorder, activations))
        for rung in rungs { await router.register(rung) }

        let result = await router.route(operation: step.operation)

        #expect(!result.isSuccess, "\(step.operation): \(result.message)")
        let object = try #require(stateCObject(result), "\(step.operation): \(result.message)")
        #expect(object["error"] as? String == "permission_denied", "\(step.operation)")
        #expect(recorder.postedEvents.isEmpty, "\(step.operation)")
        #expect(activations.total == 0, "\(step.operation) brought Logic forward")
        let reached = await reachedRungs(rungs)
        #expect(reached.isEmpty, "\(step.operation) walked on to \(reached)")
    }
}

@Test func goToPositionWithoutPostingAuthorizationTypesNothing() async throws {
    // The goto sequence asks too. Mutation killed: the check removed from the goto path.
    let recorder = CGEventRecorder()
    let activations = Activations()
    let result = await unauthorizedChannel(recorder, activations)
        .execute(operation: "transport.goto_position", params: ["position": "9.1.1.1"])

    #expect(!result.isSuccess, "\(result.message)")
    let object = try #require(stateCObject(result), "\(result.message)")
    #expect(object["error"] as? String == "permission_denied")
    #expect(recorder.postedEvents.isEmpty)
    #expect(activations.total == 0)
}
