import Foundation
import Testing
@testable import LogicProMCP

private actor Issue1568StartOrder {
    private var ids: [ChannelID] = []

    func append(_ id: ChannelID) {
        ids.append(id)
    }

    func snapshot() -> [ChannelID] {
        ids
    }
}

private actor Issue1568StartBarrier {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor Issue1568Completion {
    private(set) var finished = false

    func markFinished() {
        finished = true
    }
}

private enum Issue1568StartError: Error {
    case failed
}

private actor Issue1568MIDIProbe: Channel {
    nonisolated let id: ChannelID
    private(set) var starts = 0
    private(set) var executions = 0
    private(set) var healthChecks = 0
    private(set) var stops = 0
    private let order: Issue1568StartOrder?
    private let startBarrier: Issue1568StartBarrier?
    private var startFailuresRemaining: Int

    init(
        _ id: ChannelID,
        order: Issue1568StartOrder? = nil,
        startBarrier: Issue1568StartBarrier? = nil,
        startFailures: Int = 0
    ) {
        self.id = id
        self.order = order
        self.startBarrier = startBarrier
        self.startFailuresRemaining = startFailures
    }

    func start() async throws {
        starts += 1
        if starts == 1 {
            await startBarrier?.pause()
        }
        await order?.append(id)
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw Issue1568StartError.failed
        }
    }

    func stop() async {
        stops += 1
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executions += 1
        return .success("test execution")
    }

    func healthCheck() async -> ChannelHealth {
        healthChecks += 1
        return .healthy(detail: "test channel ready")
    }
}

@Test func issue1568PassiveStartupDefersEntireMIDIGroup() async {
    let router = ChannelRouter()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)
    let accessibility = Issue1568MIDIProbe(.accessibility)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    await router.register(accessibility)

    let report = await router.startAll()

    #expect(await keyCommands.starts == 0)
    #expect(await scripter.starts == 0)
    #expect(await coreMIDI.starts == 0)
    #expect(await accessibility.starts == 1)
    #expect(!report.started.contains(.midiKeyCommands))
    #expect(!report.started.contains(.scripter))
    #expect(!report.started.contains(.coreMIDI))
    #expect(report.started.contains(.accessibility))
}

@Test func issue1568FirstMIDIDemandStartsWholeGroupOnceInRegistrationOrder() async {
    let router = ChannelRouter()
    let order = Issue1568StartOrder()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands, order: order)
    let scripter = Issue1568MIDIProbe(.scripter, order: order)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI, order: order)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let result = await router.route(operation: "midi.send_cc")

    #expect(result.isSuccess)
    #expect(await keyCommands.starts == 1)
    #expect(await scripter.starts == 1)
    #expect(await coreMIDI.starts == 1)
    #expect(await order.snapshot() == [.midiKeyCommands, .scripter, .coreMIDI])
    #expect(await keyCommands.executions == 0)
    #expect(await scripter.executions == 0)
    #expect(await coreMIDI.executions == 1)
}

@Test func issue1568ShutdownDrainsStartupAndPreventsLateStartsOrExecution() async throws {
    let router = ChannelRouter()
    let barrier = Issue1568StartBarrier()
    let completion = Issue1568Completion()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands, startBarrier: barrier)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let demand = Task { await router.route(operation: "midi.send_cc") }
    let limit = ContinuousClock.now + .seconds(1)
    while !(await barrier.entered), ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await barrier.entered)

    let shutdown = Task {
        await router.stopAll()
        await completion.markFinished()
    }
    try await Task.sleep(for: .milliseconds(10))
    let shutdownFinishedBeforeRelease = await completion.finished
    await barrier.release()

    let result = await demand.value
    await shutdown.value

    #expect(!shutdownFinishedBeforeRelease)
    #expect(!result.isSuccess)
    #expect(await keyCommands.starts == 1)
    #expect(await scripter.starts == 0)
    #expect(await coreMIDI.starts == 0)
    #expect(await keyCommands.executions == 0)
    #expect(await scripter.executions == 0)
    #expect(await coreMIDI.executions == 0)
    #expect(await keyCommands.stops == 1)
    #expect(await scripter.stops == 1)
    #expect(await coreMIDI.stops == 1)
}

@Test func issue1568HealthReportDoesNotStartOrProbeDeferredMIDIGroup() async throws {
    let router = ChannelRouter()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let health = await router.healthReport()

    for id in [ChannelID.midiKeyCommands, .scripter, .coreMIDI] {
        let entry = try #require(health[id])
        #expect(!entry.available)
        #expect(entry.detail.contains("deferred"))
    }
    #expect(await keyCommands.starts == 0)
    #expect(await scripter.starts == 0)
    #expect(await coreMIDI.starts == 0)
    #expect(await keyCommands.healthChecks == 0)
    #expect(await scripter.healthChecks == 0)
    #expect(await coreMIDI.healthChecks == 0)
}

@Test func issue1568FailedGroupMemberIsNotRetriedOrExecuted() async {
    let router = ChannelRouter()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands, startFailures: 1)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let coreResult = await router.route(operation: "midi.send_cc")
    let failedKeyResult = await router.route(operation: "midi.send_cc.keycmd")

    #expect(coreResult.isSuccess)
    #expect(!failedKeyResult.isSuccess)
    #expect(await keyCommands.starts == 1)
    #expect(await scripter.starts == 1)
    #expect(await coreMIDI.starts == 1)
    #expect(await keyCommands.executions == 0)
    #expect(await coreMIDI.executions == 1)
}

@Test func issue1568ConcurrentMIDIDemandsShareOneStartupFlight() async throws {
    let router = ChannelRouter()
    let barrier = Issue1568StartBarrier()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands, startBarrier: barrier)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let coreDemand = Task { await router.route(operation: "midi.send_cc") }
    let limit = ContinuousClock.now + .seconds(1)
    while !(await barrier.entered), ContinuousClock.now < limit {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await barrier.entered)

    let keyDemand = Task { await router.route(operation: "midi.send_cc.keycmd") }
    try await Task.sleep(for: .milliseconds(10))
    let keyExecutedBeforeRelease = await keyCommands.executions
    await barrier.release()

    #expect((await coreDemand.value).isSuccess)
    #expect((await keyDemand.value).isSuccess)
    #expect(keyExecutedBeforeRelease == 0)
    #expect(await keyCommands.starts == 1)
    #expect(await scripter.starts == 1)
    #expect(await coreMIDI.starts == 1)
    #expect(await keyCommands.executions == 1)
    #expect(await coreMIDI.executions == 1)
}

@Test func issue1568StopResetsDeferredMIDIGroupForNextLifecycle() async {
    let router = ChannelRouter()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands, startFailures: 1)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let firstLifecycle = await router.route(operation: "midi.send_cc.keycmd")
    await router.stopAll()
    _ = await router.startAll()
    let secondLifecycle = await router.route(operation: "midi.send_cc.keycmd")

    #expect(!firstLifecycle.isSuccess)
    #expect(secondLifecycle.isSuccess)
    #expect(await keyCommands.starts == 2)
    #expect(await scripter.starts == 2)
    #expect(await coreMIDI.starts == 2)
    #expect(await keyCommands.executions == 1)
}

@Test func issue1568EagerRestartDoesNotStartMIDIGroupAgainOnDemand() async throws {
    let router = ChannelRouter()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()
    _ = await router.route(operation: "midi.send_cc")
    await router.stopAll()

    _ = await router.startAll(deferMIDIGroup: false)
    let health = await router.healthReport()
    let result = await router.route(operation: "midi.send_cc")

    #expect(result.isSuccess)
    #expect(try #require(health[.midiKeyCommands]).available)
    #expect(try #require(health[.scripter]).available)
    #expect(try #require(health[.coreMIDI]).available)
    #expect(await keyCommands.starts == 2)
    #expect(await scripter.starts == 2)
    #expect(await coreMIDI.starts == 2)
    #expect(await coreMIDI.executions == 2)
}

@Test func issue1568DebugRestrictionCannotClaimExcludedMIDIGroup() async {
    let router = ChannelRouter()
    let keyCommands = Issue1568MIDIProbe(.midiKeyCommands)
    let scripter = Issue1568MIDIProbe(.scripter)
    let coreMIDI = Issue1568MIDIProbe(.coreMIDI)

    await router.register(keyCommands)
    await router.register(scripter)
    await router.register(coreMIDI)
    _ = await router.startAll()

    let excluded = await router.route(
        operation: "midi.send_cc",
        debugRestriction: .only(.cgEvent)
    )
    let invalid = await router.route(
        operation: "midi.send_cc",
        debugRestriction: .invalid("not-a-channel")
    )

    #expect(!excluded.isSuccess)
    #expect(!invalid.isSuccess)
    #expect(await keyCommands.starts == 0)
    #expect(await scripter.starts == 0)
    #expect(await coreMIDI.starts == 0)
    #expect(await keyCommands.healthChecks == 0)
    #expect(await scripter.healthChecks == 0)
    #expect(await coreMIDI.healthChecks == 0)
}
