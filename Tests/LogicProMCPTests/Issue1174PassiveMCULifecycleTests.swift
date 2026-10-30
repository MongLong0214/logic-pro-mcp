import Foundation
import Testing
@testable import LogicProMCP

private actor MCULifecycleBarrier {
    var entered = false
    var boundaries = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func recordBoundary() { boundaries += 1 }
}

private actor PassiveMCUProbe: Channel {
    nonisolated let id: ChannelID
    var starts = 0
    var executions = 0
    var published = 0
    var startFailures: Int
    let ready: Bool
    let healthBarrier: MCULifecycleBarrier?
    let startBarrier: MCULifecycleBarrier?
    init(_ id: ChannelID, ready: Bool = true, healthBarrier: MCULifecycleBarrier? = nil,
         startBarrier: MCULifecycleBarrier? = nil, startFailures: Int = 0) {
        self.id = id; self.ready = ready; self.healthBarrier = healthBarrier
        self.startBarrier = startBarrier; self.startFailures = startFailures
    }
    func start() async throws {
        starts += 1
        if starts == 1, let startBarrier { await startBarrier.pause() }
        try Task.checkCancellation()
        if startFailures > 0 { startFailures -= 1; throw MockStartError.startupFailed }
        published += 1
    }
    func stop() async {}
    func healthCheck() async -> ChannelHealth {
        if let healthBarrier { await healthBarrier.pause() }
        return ready ? .healthy(detail: "test feedback ready") : .unavailable("no Logic feedback")
    }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executions += 1
        return .success("test execution")
    }
}

@Test func issue1174FailedMCUStartupCanRetryWithoutRestartingSuccessfulChannel() async {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu, startFailures: 1)
    await router.register(mcu)
    _ = await router.startAll()
    let first = await router.route(operation: "mixer.bank", params: ["direction": "right"])
    let retry = await router.route(operation: "mixer.bank", params: ["direction": "right"])
    #expect(!first.isSuccess)
    #expect(retry.isSuccess)
    #expect(await mcu.starts == 2)
    #expect(await mcu.published == 1)
    #expect(await mcu.executions == 1)
    await router.stopAll()
}

@Test func issue1174CallerCancellationReachesPendingMCUStartup() async throws {
    let router = ChannelRouter()
    let barrier = MCULifecycleBarrier()
    let mcu = PassiveMCUProbe(.mcu, startBarrier: barrier)
    await router.register(mcu)
    _ = await router.startAll()
    let write = Task { await router.route(operation: "mixer.bank", params: ["direction": "right"]) }
    let limit = ContinuousClock.now + .seconds(1)
    while !(await barrier.entered) && ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await barrier.entered)
    write.cancel()
    await barrier.release()
    let result = await write.value
    #expect(!result.isSuccess)
    #expect(await mcu.published == 0)
    #expect(await mcu.executions == 0)
    let retry = await router.route(operation: "mixer.bank", params: ["direction": "right"])
    #expect(retry.isSuccess)
    #expect(await mcu.starts == 2)
    await router.stopAll()
}

@Test func issue1174ConcurrentMCUUseSharesStartupAndDoesNotRelabelRunningChannel() async throws {
    let router = ChannelRouter()
    let barrier = MCULifecycleBarrier()
    let mcu = PassiveMCUProbe(.mcu, startBarrier: barrier)
    await router.register(mcu)
    _ = await router.startAll()
    let first = Task { await router.route(operation: "mixer.bank", params: ["direction": "right"]) }
    let limit = ContinuousClock.now + .seconds(1)
    while !(await barrier.entered) && ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await barrier.entered)
    let second = Task { await router.route(operation: "mixer.bank", params: ["direction": "left"]) }
    await Task.yield()
    await barrier.release()
    #expect((await first.value).isSuccess)
    #expect((await second.value).isSuccess)
    #expect(await mcu.starts == 1)
    _ = await router.startAll()
    #expect(await mcu.starts == 1)
    let mcuHealth = try #require((await router.healthReport())[.mcu])
    #expect(mcuHealth.ready)
    await router.stopAll()
}

@Test func issue1174ShutdownWhileHealthAwaitsCannotExecuteMCU() async throws {
    let router = ChannelRouter()
    let barrier = MCULifecycleBarrier()
    let mcu = PassiveMCUProbe(.mcu, healthBarrier: barrier)
    await router.register(mcu)
    _ = await router.startAll()
    let write = Task {
        await OperationTraceParentBoundary.$onWriteBoundary.withValue({ await barrier.recordBoundary() }) {
            await OperationTraceWriteBoundaryArm.armed(nil) {
                await router.route(operation: "mixer.bank", params: ["direction": "right"])
            }
        }
    }
    let limit = ContinuousClock.now + .seconds(1)
    while !(await barrier.entered) && ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await barrier.entered)
    await router.stopAll()
    await barrier.release()
    let result = await write.value
    #expect(!result.isSuccess)
    #expect(await mcu.executions == 0)
    #expect(await barrier.boundaries == 0)
}

@Test func issue1174ExpiredClaimCannotPublishMCU() async {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu)
    await router.register(mcu)
    _ = await router.startAll()
    let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { false })
    let result = await OperationTraceContext.$current.withValue(context) {
        await router.route(operation: "mixer.bank", params: ["direction": "right"])
    }
    #expect(!result.isSuccess)
    #expect(await mcu.starts == 0)
    #expect(await mcu.executions == 0)
    await router.stopAll()
}

@Test func issue1174StartsMCUOnceOnlyWhenWriteReachesItsRung() async {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu)
    let ax = PassiveMCUProbe(.accessibility)
    await router.register(mcu)
    await router.register(ax)
    _ = await router.startAll()
    let axWrite = await router.route(operation: "mixer.set_volume", params: ["index": "0", "volume": "0.7"])
    #expect(axWrite.isSuccess)
    #expect(await mcu.starts == 0)
    let first = await router.route(operation: "mixer.bank", params: ["direction": "right"])
    let second = await router.route(operation: "mixer.bank", params: ["direction": "left"])
    #expect(first.isSuccess)
    #expect(second.isSuccess)
    #expect(await mcu.starts == 1)
    #expect(await mcu.executions == 2)
    await router.stopAll()
}

@Test func issue1174SetupRequiresConsentBeforeStartingMCU() async {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu)
    await router.register(mcu)
    _ = await router.startAll()
    let cache = StateCache()
    _ = await SystemDispatcher.handle(command: "setup_control_surface", params: [:],
        router: router, cache: cache, controlSurfaceSetup: { _ in
            Issue.record("setup drive ran without consent")
            return .failed(stage: "test", hint: "test", .init())
        })
    #expect(await mcu.starts == 0)
    _ = await SystemDispatcher.handle(command: "setup_control_surface", params: ["consent": .string("true")],
        router: router, cache: cache, controlSurfaceSetup: { _ in
            .failed(stage: "test", hint: "test", .init())
        })
    #expect(await mcu.starts == 1)
    await router.stopAll()
}

@Test func issue1174SetupDriveRetainsCallerOwnershipContext() async {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu)
    await router.register(mcu)
    _ = await router.startAll()
    let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { true })
    _ = await OperationTraceContext.$current.withValue(context) {
        await SystemDispatcher.handle(command: "setup_control_surface", params: ["consent": .string("true")],
            router: router, cache: StateCache(), controlSurfaceSetup: { _ in
                #expect(OperationTraceContext.current === context)
                return .failed(stage: "test", hint: "test", .init())
            })
    }
    await router.stopAll()
}

@Test func issue1403ControlSurfaceDriveFailureIsPublishedAsTerminalAndNonHuman() async throws {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu)
    await router.register(mcu)
    _ = await router.startAll()
    let result = await SystemDispatcher.handle(
        command: "setup_control_surface",
        params: ["consent": .string("true")],
        router: router,
        cache: StateCache(),
        controlSurfaceSetup: { _ in
            .failed(stage: "open_setup_window", hint: "automatic setup terminated", .init())
        }
    )
    let body = try #require(sharedJSONObject(sharedToolText(result)))
    let terminal = try #require(body["terminal"] as? Bool)
    let humanRequired = try #require(body["human_intervention_required"] as? Bool)
    let writeAttempted = try #require(body["write_attempted"] as? Bool)
    #expect(terminal)
    #expect(!humanRequired)
    #expect(!writeAttempted)
    await router.stopAll()
}

@Test func issue1174MCUStartupDoesNotInventFeedbackReadiness() async throws {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu, ready: false)
    await router.register(mcu)
    _ = await router.startAll()
    let result = await router.route(operation: "mixer.bank", params: ["direction": "right"])
    #expect(await mcu.starts == 1)
    #expect(!result.isSuccess)
    #expect(await mcu.executions == 0)
    let mcuHealth = try #require((await router.healthReport())[.mcu])
    #expect(!mcuHealth.ready)
    await router.stopAll()
}

@Test func issue1174PassiveStartupAndReadDoNotPublishMCUPorts() async throws {
    let router = ChannelRouter()
    let mcu = PassiveMCUProbe(.mcu)
    let ax = PassiveMCUProbe(.accessibility)
    await router.register(mcu)
    await router.register(ax)
    let report = await router.startAll()
    let health = await router.healthReport()
    let read = await router.route(operation: "mixer.get_state")
    #expect(await mcu.starts == 0)
    #expect(await mcu.executions == 0)
    #expect(!report.started.contains(.mcu))
    let mcuHealth = try #require(health[.mcu])
    #expect(!mcuHealth.available)
    #expect(read.isSuccess)
    #expect(await ax.executions == 1)
    await router.stopAll()
}
