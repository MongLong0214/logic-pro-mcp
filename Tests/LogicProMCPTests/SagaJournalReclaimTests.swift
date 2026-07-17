import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Minimal write probe for the reclaim surface: only `mixer.set_volume` is
/// exercised, and every landed write moves BOTH the live surface and the cache
/// mirror so a saga verifies cleanly.
private actor SagaReclaimWriteProbeChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private let cache: StateCache
    private let surface: SagaLiveTrackSurface
    private var calls: [String] = []

    init(cache: StateCache, surface: SagaLiveTrackSurface) {
        self.cache = cache
        self.surface = surface
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append(operation)
        guard let rawIndex = params["index"], let index = Int(rawIndex) else {
            return .error(HonestContract.encodeStateC(error: .invalidParams))
        }
        switch operation {
        case "mixer.set_volume":
            guard let rawValue = params["volume"], let value = Double(rawValue) else {
                return .error(HonestContract.encodeStateC(error: .invalidParams))
            }
            surface.update(index) { $0.volume = value }
            await cache.updateTrack(at: index) { $0.volume = value }
        default:
            return .error(HonestContract.encodeStateC(error: .commandNotExposed))
        }
        return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "saga reclaim write probe")
    }

    func writeCount() -> Int { calls.count }
}

/// Counts step executions so "did this saga re-run?" is directly assertable.
private actor SagaReclaimCountingExecutor: SagaStepExecutor {
    private var states: [TargetReference: Value]
    private var runs = 0

    init(states: [TargetReference: Value]) {
        self.states = states
    }

    func run(_ step: SagaStep) async -> StepResult {
        runs += 1
        if let target = step.targetRef,
           let desired = step.params[step.expectedInverse.valueParameter] {
            states[target] = desired
        }
        return StepResult(state: .stateA, writeBoundaryCrossed: true, detail: "synthetic A")
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        guard let target = step.targetRef, let value = states[target] else { return nil }
        return ObservedState(value: value, evidence: "reclaim counting executor")
    }

    func runCount() -> Int { runs }
}

@Suite("SagaJournal bounded reclaim", .serialized)
struct SagaJournalReclaimTests {
    private struct Fixture: Sendable {
        let router: ChannelRouter
        let cache: StateCache
        let surface: SagaLiveTrackSurface
        let targetRegistry: TargetRegistry
        let journal: SagaJournal
        let channel: SagaReclaimWriteProbeChannel
        let target: TargetReference
    }

    // MARK: - helpers

    private func withSagaFeatures<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await FeatureFlags.withAdr002TargetRefForTests(true, operation: operation)
        }
    }

    private func makeFixture(journal: SagaJournal) async -> Fixture {
        let cache = StateCache()
        let tracks = [TrackState(id: 0, name: "Bass", type: .audio, volume: 0.25)]
        await cache.updateTracks(tracks)
        let surface = SagaLiveTrackSurface(tracks)
        let targetRegistry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Bass")
        let target = await targetRegistry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let channel = SagaReclaimWriteProbeChannel(cache: cache, surface: surface)
        let router = ChannelRouter()
        await router.register(channel)
        return Fixture(
            router: router,
            cache: cache,
            surface: surface,
            targetRegistry: targetRegistry,
            journal: journal,
            channel: channel,
            target: target
        )
    }

    private func dispatch(
        command: String,
        params: [String: Value],
        fixture: Fixture
    ) async -> CallTool.Result {
        await SystemDispatcher.handle(
            command: command,
            params: params,
            router: fixture.router,
            cache: fixture.cache,
            targetRegistry: fixture.targetRegistry,
            sagaJournal: fixture.journal,
            sagaLiveReadback: fixture.surface.readback
        )
    }

    private func resultObject(_ result: CallTool.Result) throws -> [String: Any] {
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected text tool result")
            return [:]
        }
        return try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    /// A wire plan that sets track 0's volume — distinct `value` per key keeps
    /// each saga's verification independent.
    private func wirePlan(_ fixture: Fixture, key: String, value: Double) -> [String: Value] {
        [
            "idempotency_key": .string(key),
            "steps": .array([.object([
                "operation_id": .string(OperationID.mixerSetVolume.rawValue),
                "target_ref": .string(fixture.target.rawValue),
                "params": .object(["value": .double(value)]),
                "expected_inverse": .object([
                    "operation_id": .string(OperationID.mixerSetVolume.rawValue),
                    "value_parameter": .string("value"),
                ]),
            ])]),
        ]
    }

    /// A journal-only plan. Never executed — the journal never inspects step
    /// semantics, only plan identity.
    private func unitPlan(_ key: String, name: String = "Lead") -> SagaPlan {
        SagaPlan(
            steps: [SagaStep(
                operationID: .tracksRename,
                targetRef: TargetReference(rawValue: "track:0"),
                params: ["name": .string(name)],
                expectedInverse: SagaExpectedInverse(
                    operationID: .tracksRename,
                    valueParameter: "name"
                )
            )],
            idempotencyKey: key
        )
    }

    private func storedOutcome(_ marker: String) -> SagaJournal.StoredOutcome {
        SagaJournal.StoredOutcome(
            body: HonestContract.encodeStateA(extras: ["marker": marker]),
            isError: false
        )
    }

    /// Drives `key` to a retained terminal `completed` record.
    @discardableResult
    private func terminate(
        _ journal: SagaJournal,
        key: String,
        name: String = "Lead"
    ) async -> Bool {
        guard case .started(let claim) = await journal.begin(unitPlan(key, name: name)) else {
            Issue.record("expected a fresh claim for \(key)")
            return false
        }
        return await journal.complete(claim, outcome: storedOutcome(key))
    }

    private func isStarted(_ result: SagaJournal.BeginResult) -> Bool {
        if case .started = result { return true }
        return false
    }

    // MARK: - RED: body reclaim

    @Test("insertion pressure evicts the oldest terminal body instead of failing closed")
    func bodyEvictionAdmitsNewKeys() async throws {
        let journal = SagaJournal(maxRecords: 2)
        await terminate(journal, key: "k1")
        await terminate(journal, key: "k2")

        let third = await journal.begin(unitPlan("k3"))

        #expect(third != .capacityExceeded)
        #expect(isStarted(third))
    }

    @Test("an evicted terminal key never re-executes and never answers started")
    func evictedTerminalKeyNeverReExecutes() async throws {
        let journal = SagaJournal(maxRecords: 2)
        await terminate(journal, key: "k1")
        await terminate(journal, key: "k2")
        _ = await journal.begin(unitPlan("k3"))

        let retry = await journal.begin(unitPlan("k1"))

        #expect(!isStarted(retry))
        #expect(retry != .capacityExceeded)
        #expect(retry != .completed(storedOutcome("k1")))
    }

    @Test("cancel on a body-less terminal is typed, never notFound or completed")
    func cancelOnBodylessTerminalIsTyped() async throws {
        let journal = SagaJournal(maxRecords: 2)
        await terminate(journal, key: "k1")
        await terminate(journal, key: "k2")
        _ = await journal.begin(unitPlan("k3"))

        let cancel = await journal.cancel(idempotencyKey: "k1")

        #expect(cancel != .notFound)
        #expect(cancel != .completed)
    }

    @Test("an evicted body keeps its compact row and reports the terminal path")
    func evictedBodyRetainsCompactRow() async throws {
        let journal = SagaJournal(maxRecords: 2)
        await terminate(journal, key: "k1")
        await terminate(journal, key: "k2")
        _ = await journal.begin(unitPlan("k3"))
        let metrics = await journal.metrics()

        #expect(await journal.begin(unitPlan("k1")) == .outcomeEvicted(terminal: .completed))
        #expect(await journal.record(for: "k1") == .outcomeEvicted(terminal: .completed))
        #expect(await journal.disposition(for: unitPlan("k1"))
            == .outcomeEvicted(terminal: .completed))
        #expect(await journal.cancel(idempotencyKey: "k1")
            == .outcomeEvicted(terminal: .completed))
        // The compact row survives eviction; only the body is gone.
        #expect(metrics.compactCount == 3)
        #expect(metrics.fullBodyCount == 2)
        #expect(metrics.bodyEvictions == 1)
        // k2 is younger than k1, so k1's body is the one that goes.
        #expect(await journal.begin(unitPlan("k2")) == .completed(storedOutcome("k2")))
    }

    @Test("an evicted cancellation reports the cancelled terminal path")
    func evictedCancellationReportsCancelled() async throws {
        let journal = SagaJournal(maxRecords: 2)
        guard case .started(let claim) = await journal.begin(unitPlan("c1")) else {
            Issue.record("expected a fresh claim")
            return
        }
        #expect(await journal.cancel(idempotencyKey: "c1") == .requested)
        #expect(await journal.completeCancellation(
            claim,
            outcome: storedOutcome("c1"),
            verified: true
        ))
        await terminate(journal, key: "c2")
        _ = await journal.begin(unitPlan("c3"))

        #expect(await journal.begin(unitPlan("c1")) == .outcomeEvicted(terminal: .cancelled))
        #expect(await journal.record(for: "c1") == .outcomeEvicted(terminal: .cancelled))
    }

    // MARK: - the load-bearing invariant

    @Test("no terminal key ever answers started, at any insertion pressure")
    func terminalKeysNeverLapseWithinAGeneration() async throws {
        let journal = SagaJournal(maxRecords: 4)
        var terminalKeys: [String] = []

        for index in 0..<64 {
            let key = "key-\(index)"
            if case .started(let claim) = await journal.begin(unitPlan(key)) {
                await journal.complete(claim, outcome: storedOutcome(key))
                terminalKeys.append(key)
            }
            // After EVERY insertion, every key that ever went terminal must
            // still refuse to start. This is the whole point of the compact
            // tier: saturation costs bodies, never replay protection.
            for terminal in terminalKeys {
                let replay = await journal.begin(unitPlan(terminal))
                #expect(!isStarted(replay))
                #expect(replay != .capacityExceeded)
                #expect(replay != .conflict)
            }
        }

        #expect(terminalKeys.count == 64)
        let metrics = await journal.metrics()
        #expect(metrics.compactCount == 64)
        #expect(metrics.fullBodyCount <= 4)
        #expect(metrics.bodyEvictions == 60)
    }

    @Test("in-flight entries are never evicted and saturate fail-closed")
    func inProgressEntriesAreImmuneToEviction() async throws {
        let journal = SagaJournal(maxRecords: 3)
        for index in 0..<3 {
            #expect(isStarted(await journal.begin(unitPlan("live-\(index)"))))
        }

        #expect(await journal.begin(unitPlan("live-new")) == .capacityExceeded)
        #expect(await journal.disposition(for: unitPlan("live-new")) == .capacityExceeded)
        for index in 0..<3 {
            #expect(await journal.record(for: "live-\(index)") == .inProgress)
        }
        let metrics = await journal.metrics()
        #expect(metrics.bodyEvictions == 0)
        #expect(metrics.fullBodyCount == 3)
    }

    @Test("compact tier exhaustion still fails closed with capacityExceeded")
    func compactCapacityExhaustionFailsClosed() async throws {
        let journal = SagaJournal(maxRecords: 2, compactCapacity: 2)
        await terminate(journal, key: "c1")
        await terminate(journal, key: "c2")

        #expect(await journal.begin(unitPlan("c3")) == .capacityExceeded)
        // Both admitted keys stay replay-protected.
        #expect(await journal.begin(unitPlan("c1")) == .completed(storedOutcome("c1")))
        #expect(await journal.begin(unitPlan("c2")) == .completed(storedOutcome("c2")))
    }

    // MARK: - plan identity

    @Test("a different plan on a retained terminal key conflicts")
    func planIdentityConflictsWhileBodyRetained() async throws {
        let journal = SagaJournal(maxRecords: 4)
        await terminate(journal, key: "identity", name: "Lead")

        #expect(await journal.begin(unitPlan("identity", name: "Other")) == .conflict)
        #expect(await journal.disposition(for: unitPlan("identity", name: "Other")) == .conflict)
        #expect(await journal.begin(unitPlan("identity", name: "Lead"))
            == .completed(storedOutcome("identity")))
    }

    @Test("a different plan on an evicted terminal key still conflicts")
    func planIdentityConflictsAfterBodyEviction() async throws {
        let journal = SagaJournal(maxRecords: 2)
        await terminate(journal, key: "identity", name: "Lead")
        await terminate(journal, key: "filler")
        _ = await journal.begin(unitPlan("pressure"))
        #expect(await journal.record(for: "identity") == .outcomeEvicted(terminal: .completed))

        // The plan is gone, so this is the hash path doing the work.
        #expect(await journal.begin(unitPlan("identity", name: "Other")) == .conflict)
        #expect(await journal.disposition(for: unitPlan("identity", name: "Other")) == .conflict)
        #expect(await journal.begin(unitPlan("identity", name: "Lead"))
            == .outcomeEvicted(terminal: .completed))
    }

    // MARK: - generation

    @Test("clear resets both tiers but keeps the eviction counter monotonic")
    func clearResetsBothTiers() async throws {
        let journal = SagaJournal(maxRecords: 2)
        await terminate(journal, key: "g1")
        await terminate(journal, key: "g2")
        _ = await journal.begin(unitPlan("g3"))
        #expect(await journal.metrics().bodyEvictions == 1)

        await journal.clear()
        let metrics = await journal.metrics()

        #expect(metrics.compactCount == 0)
        #expect(metrics.fullBodyCount == 0)
        #expect(await journal.record(for: "g1") == nil)
        #expect(await journal.record(for: "g3") == nil)
        // A new generation is a new session: keys are free to start again.
        #expect(isStarted(await journal.begin(unitPlan("g1"))))
        // Monotonic across generations — it is an ops counter, not tier state.
        #expect(metrics.bodyEvictions == 1)
    }

    // MARK: - RED: wire

    @Test("saga_execute retry of an evicted key answers saga_outcome_unavailable")
    func wireRetryOfEvictedKeyIsOutcomeUnavailable() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(journal: SagaJournal(maxRecords: 1))
            let first = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "evict-first", value: 0.5),
                fixture: fixture
            ))
            let second = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "evict-second", value: 0.6),
                fixture: fixture
            ))
            let writesBeforeRetry = await fixture.channel.writeCount()
            let retry = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "evict-first", value: 0.5),
                fixture: fixture
            ))

            #expect(first["state"] as? String == "A")
            #expect(second["state"] as? String == "A")
            #expect(retry["state"] as? String == "C")
            #expect(retry["error"] as? String == "saga_outcome_unavailable")
            #expect(retry["safe_to_retry"] as? Bool == false)
            #expect(retry["write_attempted"] as? Bool == false)
            #expect(retry["outcome_retained"] as? Bool == false)
            #expect(await fixture.channel.writeCount() == writesBeforeRetry)
        }
    }

    @Test("saga_status reports a body-less terminal honestly")
    func wireStatusReportsEvictedBody() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(journal: SagaJournal(maxRecords: 1))
            _ = await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "status-first", value: 0.5),
                fixture: fixture
            )
            _ = await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "status-second", value: 0.6),
                fixture: fixture
            )
            let status = try resultObject(await dispatch(
                command: "saga_status",
                params: ["idempotency_key": .string("status-first")],
                fixture: fixture
            ))
            let record = try #require(status["record"] as? [String: Any])

            #expect(record["status"] as? String == "completed")
            #expect(record["outcome_retained"] as? Bool == false)
            #expect(record["outcome"] == nil)
        }
    }

    @Test("saga_journal_capacity_exceeded keeps its existing envelope shape")
    func wireCapacityExceededShapeUnchanged() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(
                journal: SagaJournal(maxRecords: 1, compactCapacity: 1)
            )
            let first = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "cap-first", value: 0.5),
                fixture: fixture
            ))
            let second = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "cap-second", value: 0.6),
                fixture: fixture
            ))

            #expect(first["state"] as? String == "A")
            #expect(second["state"] as? String == "C")
            #expect(second["error"] as? String == "saga_journal_capacity_exceeded")
            #expect(second["idempotency_key"] as? String == "cap-second")
            #expect(second["journal_scope"] as? String == "session")
            // Capacity is distinct from an evicted body: no key was admitted, so
            // there is no terminal path to name.
            #expect(second["terminal_kind"] == nil)
            #expect(second["outcome_retained"] == nil)
        }
    }

    /// LPMCP-PRD-005 item 8: `MutationSaga.sessions` is request-local scratch and
    /// must NOT be dual-bounded — SystemDispatcher builds a fresh MutationSaga
    /// per preflight and per execute, so `sessions` never outlives one call.
    ///
    /// This is the strongest DETERMINISTIC runtime pin available. A code-shape
    /// census could only prove the constructor is textually inside the case; this
    /// proves request-locality behaviourally. `journal.clear()` starts a new
    /// generation, so the journal cannot answer the replayed key — the request
    /// reaches MutationSaga. If a MutationSaga instance were shared across
    /// dispatcher calls, `sessions[key]` would still hold the first outcome and
    /// short-circuit `execute` (MutationSaga.swift:416), so NO new write would
    /// land. A fresh instance per call re-runs the step, so the write count
    /// strictly increases.
    @Test("dispatcher saga paths keep MutationSaga.sessions request-local")
    func mutationSagaSessionsAreRequestLocal() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(journal: SagaJournal())
            let first = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "local", value: 0.5),
                fixture: fixture
            ))
            let writesAfterFirst = await fixture.channel.writeCount()

            await fixture.journal.clear()
            let replay = try resultObject(await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "local", value: 0.5),
                fixture: fixture
            ))

            #expect(first["state"] as? String == "A")
            #expect(replay["state"] as? String == "A")
            #expect(writesAfterFirst == 1)
            #expect(await fixture.channel.writeCount() == 2)
            // A shared MutationSaga would have replayed the cached outcome and
            // reported `duplicate` from its own scratch instead.
            #expect(replay["duplicate"] as? Bool == false)
        }
    }

    /// The other half of the request-locality pin: this proves the behaviour
    /// `mutationSagaSessionsAreRequestLocal` excludes is REAL. One MutationSaga
    /// instance replaying the same key answers from `sessions` and runs no
    /// steps. So the dispatcher test's "the replay ran the step again" outcome
    /// is only reachable with a fresh instance per call — without this, that
    /// test could pass for the wrong reason.
    @Test("one MutationSaga instance suppresses re-execution from its session scratch")
    func mutationSagaSessionsSuppressReExecutionWithinOneInstance() async throws {
        try await withSagaFeatures {
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Bass")
            let target = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let executor = SagaReclaimCountingExecutor(states: [target: .double(0.25)])
            let saga = MutationSaga(
                targetRegistry: registry,
                enabled: true,
                routeAvailable: { _ in true }
            )
            let plan = SagaPlan(
                steps: [SagaStep(
                    operationID: .mixerSetVolume,
                    targetRef: target,
                    params: ["value": .double(0.5)],
                    expectedInverse: SagaExpectedInverse(
                        operationID: .mixerSetVolume,
                        valueParameter: "value"
                    )
                )],
                idempotencyKey: "instance-local"
            )

            _ = await saga.execute(plan, executor: executor)
            let afterFirst = await executor.runCount()
            _ = await saga.execute(plan, executor: executor)

            #expect(afterFirst == 1)
            #expect(await executor.runCount() == afterFirst)
        }
    }

    @Test("saga_status and saga_preflight publish journal tier metrics")
    func wireObservabilityExtras() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(journal: SagaJournal(maxRecords: 1))
            _ = await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "metrics-first", value: 0.5),
                fixture: fixture
            )
            let status = try resultObject(await dispatch(
                command: "saga_status",
                params: ["idempotency_key": .string("metrics-first")],
                fixture: fixture
            ))
            let preflight = try resultObject(await dispatch(
                command: "saga_preflight",
                params: wirePlan(fixture, key: "metrics-second", value: 0.6),
                fixture: fixture
            ))

            for body in [status, preflight] {
                #expect(body["journal_full_body_count"] as? Int == 1)
                #expect(body["journal_compact_count"] as? Int == 1)
                #expect(body["journal_body_evictions"] as? Int == 0)
                #expect(body["journal_compact_capacity"] as? Int
                    == SagaJournal.defaultCompactCapacity)
                #expect(body["journal_record_capacity"] as? Int == 1)
            }

            // Drive an eviction and prove the counter moves and only ever up.
            _ = await dispatch(
                command: "saga_execute",
                params: wirePlan(fixture, key: "metrics-second", value: 0.6),
                fixture: fixture
            )
            let after = try resultObject(await dispatch(
                command: "saga_status",
                params: ["idempotency_key": .string("metrics-second")],
                fixture: fixture
            ))
            let later = try resultObject(await dispatch(
                command: "saga_status",
                params: ["idempotency_key": .string("metrics-second")],
                fixture: fixture
            ))

            #expect(after["journal_body_evictions"] as? Int == 1)
            #expect(later["journal_body_evictions"] as? Int == 1)
            #expect(after["journal_compact_count"] as? Int == 2)
            #expect(after["journal_full_body_count"] as? Int == 1)
        }
    }
}
