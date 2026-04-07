import Testing
@testable import LogicProMCP

private enum RuntimePlanTestError: Error {
    case boom
}

private actor RuntimePlanRecorder {
    var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@Test func testServerRuntimePlanRunsLifecycleAndCleansUpOnSuccess() async throws {
    let recorder = RuntimePlanRecorder()
    let plan = ServerRuntimePlan(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.coreMIDI], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        registerHandlers: { await recorder.record("registerHandlers") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") },
        startupError: { _ in RuntimePlanTestError.boom }
    )

    try await plan.run()

    let events = await recorder.snapshot()
    #expect(events == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "startPoller",
        "registerHandlers",
        "serve",
        "stopPoller",
        "stopChannels",
        "stopPorts",
    ])
}

@Test func testServerRuntimePlanFailsFastOnChannelStartupFailure() async {
    let recorder = RuntimePlanRecorder()
    let plan = ServerRuntimePlan(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [], failures: [.mcu: "failed"], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        registerHandlers: { await recorder.record("registerHandlers") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") },
        startupError: { _ in RuntimePlanTestError.boom }
    )

    await #expect(throws: RuntimePlanTestError.boom) {
        try await plan.run()
    }

    let events = await recorder.snapshot()
    #expect(events == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "stopChannels",
        "stopPorts",
    ])
}

@Test func testServerRuntimePlanCleansUpWhenServeThrows() async {
    let recorder = RuntimePlanRecorder()
    let plan = ServerRuntimePlan(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.coreMIDI], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        registerHandlers: { await recorder.record("registerHandlers") },
        serve: {
            await recorder.record("serve")
            throw RuntimePlanTestError.boom
        },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") },
        startupError: { _ in RuntimePlanTestError.boom }
    )

    await #expect(throws: RuntimePlanTestError.boom) {
        try await plan.run()
    }

    let events = await recorder.snapshot()
    #expect(events == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "startPoller",
        "registerHandlers",
        "serve",
        "stopPoller",
        "stopChannels",
        "stopPorts",
    ])
}

@Test func testServerRuntimePlanStopsImmediatelyWhenPortsFail() async {
    let recorder = RuntimePlanRecorder()
    let plan = ServerRuntimePlan(
        startPorts: {
            await recorder.record("startPorts")
            throw RuntimePlanTestError.boom
        },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [], failures: [:], degraded: [:])
        },
        startPoller: { await recorder.record("startPoller") },
        registerHandlers: { await recorder.record("registerHandlers") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") },
        startupError: { _ in RuntimePlanTestError.boom }
    )

    await #expect(throws: RuntimePlanTestError.boom) {
        try await plan.run()
    }

    let events = await recorder.snapshot()
    #expect(events == ["startPorts"])
}

@Test func testServerRuntimePlanContinuesWhenOnlyDegradedChannelsFail() async throws {
    let recorder = RuntimePlanRecorder()
    let plan = ServerRuntimePlan(
        startPorts: { await recorder.record("startPorts") },
        registerChannels: { await recorder.record("registerChannels") },
        startChannels: {
            await recorder.record("startChannels")
            return .init(started: [.coreMIDI], failures: [:], degraded: [.accessibility: "not trusted"])
        },
        startPoller: { await recorder.record("startPoller") },
        registerHandlers: { await recorder.record("registerHandlers") },
        serve: { await recorder.record("serve") },
        stopPoller: { await recorder.record("stopPoller") },
        stopChannels: { await recorder.record("stopChannels") },
        stopPorts: { await recorder.record("stopPorts") },
        startupError: { _ in RuntimePlanTestError.boom }
    )

    try await plan.run()

    let events = await recorder.snapshot()
    #expect(events == [
        "startPorts",
        "registerChannels",
        "startChannels",
        "startPoller",
        "registerHandlers",
        "serve",
        "stopPoller",
        "stopChannels",
        "stopPorts",
    ])
}
