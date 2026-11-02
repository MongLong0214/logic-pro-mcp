import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor CompressorReadBarrier {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func blockFirst() async {
        guard !entered else { return }
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private actor CompressorSagaChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    var threshold = 60.0
    var limiter = false
    var writes: [String] = []
    var reads: [String] = []
    let fault: String
    let barrier: CompressorReadBarrier?
    var ownedChild = true

    init(_ fault: String = "", barrier: CompressorReadBarrier? = nil) {
        self.fault = fault; self.barrier = barrier
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "injected Compressor surface") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let param = params["param"] ?? ""
        if operation == "plugin.get_param_verified" {
            reads.append(param)
            await barrier?.blockFirst()
            if (fault == "unknown" && param == "limiter_on")
                || (fault == "after_unknown" && !writes.isEmpty && param == "threshold") {
                return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable,
                    extras: ["write_attempted": false]))
            }
            let observed: Any = param == "threshold" ? threshold as Any : limiter as Any
            return .success(HonestContract.encodeV2StateA(extras: [
                "param": param, "observed_raw": observed,
                "raw_unit": param == "threshold" ? "normalized" : "boolean",
                "target_identity": ["track_index": 0, "insert": 0,
                    "plugin_id": "logic.stock.effect.compressor"], "write_attempted": false,
            ]))
        }
        guard operation == "plugin.set_param_verified" else {
            return .error(HonestContract.encodeV2StateC(error: .commandNotExposed))
        }
        let context = OperationTraceContext.current
        if let context, let deadline = context.deadline {
            ownedChild = ownedChild && context.ownsGate()
                && ContinuousClock.now.duration(to: deadline) <= .seconds(25)
        } else { ownedChild = false }
        // Approved before-state is an internal typed context, never a public setter string.
        #expect(params["expected_before"] == nil)
        if param == "limiter_on" && (fault == "second" || fault == "user_edit") {
            if fault == "user_edit" { threshold = 39 }
            return .error(HonestContract.encodeV2StateC(error: .axWriteFailed,
                extras: ["write_attempted": false]))
        }
        writes.append(param)
        if param == "threshold" { threshold = Double(params["value"] ?? "") ?? .nan }
        else { limiter = params["value"] == "1.0" || params["value"] == "1" }
        return .success(HonestContract.encodeV2StateA(extras: ["write_attempted": true]))
    }
    func changeBefore(_ param: String) {
        if param == "threshold" { threshold = 60.5 } else { limiter = true }
    }
    func snapshot() -> (Double, Bool, [String], [String], Bool) {
        (threshold, limiter, writes, reads, ownedChild)
    }
}

extension VerifiedOpGateSharedTests {
@Suite(.serialized)
struct Issue955ConfirmedCompressorSagaTests {
    private struct Fixture {
        let router: ChannelRouter
        let channel: CompressorSagaChannel
        let cache: StateCache
        let registry: TargetRegistry
        let journal: SagaJournal
        let plan: SagaPlan
        let wire: [String: Value]
    }

    private func fixture(_ fault: String = "", barrier: CompressorReadBarrier? = nil) async -> Fixture {
        let registry = TargetRegistry()
        let project = TargetDescriptor.project(name: "Disposable", filePath: "/tmp/disposable.logicx", epoch: 0)
        _ = await registry.bind(kind: .project, descriptor: project, fingerprint: project.fingerprint)
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Audio 1")
        let reference = await registry.bind(kind: .pluginInsert, descriptor: descriptor,
            fingerprint: TargetRefResolver.pluginInsertFingerprint(descriptor: descriptor, insert: 0,
                pluginIdentity: "logic.stock.effect.compressor"))
        let steps: [SagaStep] = [
            .init(operationID: .pluginsSetParamVerified, targetRef: reference,
                params: ["param": .string("threshold"), "unit": .string("normalized"),
                    "value": .double(38), "expected_before": .double(60)],
                expectedInverse: .init(operationID: .pluginsSetParamVerified, valueParameter: "value")),
            .init(operationID: .pluginsSetParamVerified, targetRef: reference,
                params: ["param": .string("limiter_on"), "unit": .string("boolean"),
                    "value": .bool(true), "expected_before": .bool(false)],
                expectedInverse: .init(operationID: .pluginsSetParamVerified, valueParameter: "value")),
        ]
        let wire: [String: Value] = ["idempotency_key": .string("confirmed-compressor"),
            "steps": .array(steps.map { .object([
                "operation_id": .string($0.operationID.rawValue), "target_ref": .string($0.targetRef!.rawValue),
                "params": .object($0.params), "expected_inverse": .object([
                    "operation_id": .string($0.expectedInverse.operationID.rawValue),
                    "value_parameter": .string("value")]),
            ]) })]
        let channel = CompressorSagaChannel(fault, barrier: barrier)
        let router = ChannelRouter(); await router.register(channel)
        let cache = StateCache()
        await cache.updateTracks([TrackState(id: 0, name: "Audio 1", type: .audio)])
        return Fixture(router: router, channel: channel, cache: cache, registry: registry,
            journal: SagaJournal(), plan: .init(steps: steps, idempotencyKey: "confirmed-compressor"), wire: wire)
    }

    private func hash(_ plan: SagaPlan) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(plan)).map { String(format: "%02x", $0) }.joined()
    }
    private func run(_ f: Fixture, params: [String: Value], command: String = "saga_execute",
                     expired: Bool = false, gate: LogicMutationGate? = nil) async throws -> [String: Any] {
        try await FeatureFlags.withAdr004MutationSagaForTests(true) {
            try await FeatureFlags.withAdr002TargetRefForTests(true) {
                let result = await SystemDispatcher.handle(command: command, params: params,
                    router: f.router, cache: f.cache, targetRegistry: f.registry, dialogPresent: { false },
                    sagaJournal: f.journal, mutationGate: gate ?? LogicMutationGate(),
                    sagaRefreshAfterWrite: {}, sagaLiveReadback: .unavailable,
                    sagaLifecycleDeadline: expired ? ContinuousClock.now : nil)
                guard case .text(let text, _, _) = result.content.first else { throw CocoaError(.coderReadCorrupt) }
                return try #require(decodedJSONObject(text))
            }
        }
    }
    private func confirmed(_ f: Fixture) throws -> [String: Value] {
        f.wire.merging(["confirmed_plan_hash": .string(try hash(f.plan))]) { _, new in new }
    }
    private func waitForVerifiedIdle() async throws {
        for _ in 0..<1000 {
            if VerifiedOpGate.shared.tryAcquire() { VerifiedOpGate.shared.release(); return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the owned test worker did not exit and release its verified lease")
    }

    @Test func confirmedTwoParameterPlanUsesIndependentReadsAndExistingJournal() async throws {
        let f = await fixture()
        let preflight = try await run(f, params: f.wire, command: "saga_preflight")
        #expect(preflight["plan_hash"] as? String == (try hash(f.plan)))
        let result = try await run(f, params: confirmed(f))
        #expect(result["state"] as? String == "A")
        let actual = await f.channel.snapshot()
        #expect(actual.0 == 38 && actual.1)
        #expect(actual.2 == ["threshold", "limiter_on"])
        #expect(actual.3.prefix(2) == ["threshold", "limiter_on"])
        #expect(actual.4)
        let duplicate = try await run(f, params: confirmed(f))
        let duplicated = try #require(duplicate["duplicate"] as? Bool)
        #expect(duplicated)
        #expect(await f.channel.snapshot().2 == actual.2)
    }

    @Test(arguments: ["missing", "wrong", "later_invalid", "threshold", "limiter_on", "unknown", "expired"])
    func wholeKnownInvalidOrUnconfirmedPlanIsWriteFree(_ fault: String) async throws {
        let f = await fixture(fault)
        if fault == "threshold" || fault == "limiter_on" { await f.channel.changeBefore(fault) }
        var params = try confirmed(f)
        if fault == "missing" { params.removeValue(forKey: "confirmed_plan_hash") }
        if fault == "wrong" { params["confirmed_plan_hash"] = .string(String(repeating: "0", count: 64)) }
        if fault == "later_invalid", var steps = params["steps"]?.arrayValue,
           var later = steps[1].objectValue, var fields = later["params"]?.objectValue {
            fields["unit"] = .string("dB"); later["params"] = .object(fields)
            steps[1] = .object(later); params["steps"] = .array(steps)
        }
        let result = try await run(f, params: params, expired: fault == "expired")
        #expect(result["state"] as? String == "C")
        #expect(await f.channel.snapshot().2.isEmpty)
        if fault == "missing" || fault == "wrong" {
            #expect(try #require(result["terminal"] as? Bool))
            #expect(result["terminal_scope"] as? String == "mcp_request_only")
            #expect(try #require(result["safe_to_retry"] as? Bool))
            #expect(!(try #require(result["human_intervention_required"] as? Bool)))
            #expect(result["human_intervention_requests"] as? Int == 0)
            #expect(result["human_dependent_transitions"] as? Int == 0)
            let hint = try #require(result["hint"] as? String)
            #expect(hint.contains("confirmed_plan_hash"))
            #expect(hint.contains("saga_preflight"))
            #expect(!hint.contains("Confirm this"))
        }
        if fault == "expired" { try await waitForVerifiedIdle() }
    }

    @Test(arguments: ["second", "user_edit"])
    func partialFailureRestoresOnlyItsFreshlyOwnedAfterValue(_ fault: String) async throws {
        let f = await fixture(fault)
        let result = try await run(f, params: confirmed(f))
        #expect(result["state"] as? String != "A")
        let actual = await f.channel.snapshot()
        #expect(actual.2 == (fault == "second" ? ["threshold", "threshold"] : ["threshold"]),
            "Partial failure receipt: \(HonestContract.jsonString(result))")
        #expect(actual.0 == (fault == "second" ? 60 : 39))
        #expect(!actual.1)
    }

    @Test func timedOutOwnedReaderCannotReleaseItsLeaseOrStartAnotherStep() async throws {
        let barrier = CompressorReadBarrier()
        let f = await fixture(barrier: barrier)
        let params = try confirmed(f)
        let task = Task {
            let result = try await CompressorParameterSaga.$testStepSeconds.withValue(0.03) {
                try await run(f, params: params)
            }
            return HonestContract.jsonString(result)
        }
        await barrier.waitUntilEntered()
        let text = try await task.value
        let result = try #require(decodedJSONObject(text))
        #expect(result["state"] as? String != "A")
        let actual = await f.channel.snapshot()
        #expect(actual.2.isEmpty)
        #expect(actual.3 == ["threshold"])
        let reacquired = VerifiedOpGate.shared.tryAcquire()
        if reacquired { VerifiedOpGate.shared.release() }
        #expect(!reacquired)
        await barrier.release()
        try await waitForVerifiedIdle()
        let next = await fixture()
        let nextResult = try await run(next, params: confirmed(next))
        #expect(nextResult["state"] as? String == "A")
    }

    @Test func anInactiveInheritedLeaseCannotReacquireAFreeGate() async throws {
        let f = await fixture()
        let lease = try #require(VerifiedPluginSagaLease(gate: .shared))
        lease.release()
        let readParams: [String: Value] = ["target_ref": .string(f.plan.steps[0].targetRef!.rawValue),
            "param": .string("threshold"), "unit": .string("normalized")]
        let refused = await PluginsDispatcher.$sagaLease.withValue(lease) {
            await PluginsDispatcher.handle(command: "get_param_verified", params: readParams,
                router: f.router, cache: f.cache, targetRegistry: f.registry)
        }
        guard case .text(let text, _, _) = refused.content.first else { throw CocoaError(.coderReadCorrupt) }
        #expect(decodedJSONObject(text)?["state"] as? String == "C")
        #expect(await f.channel.snapshot().3.isEmpty)
        let independent = await PluginsDispatcher.handle(command: "get_param_verified", params: readParams,
            router: f.router, cache: f.cache, targetRegistry: f.registry)
        guard case .text(let independentText, _, _) = independent.content.first else { throw CocoaError(.coderReadCorrupt) }
        #expect(decodedJSONObject(independentText)?["state"] as? String == "A")
    }

    @Test func unknownAfterReadStopsAndAccountsForBothRequestedParameters() async throws {
        let f = await fixture("after_unknown")
        let result = try await run(f, params: confirmed(f))
        #expect(result["state"] as? String == "B")
        let actual = await f.channel.snapshot()
        #expect(actual.2 == ["threshold"])
        #expect(actual.0 == 38 && !actual.1)
        let rows = try #require(result["parameters"] as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows.map { $0["status"] as? String } == ["unknown", "unknown"])
        #expect(rows[1]["observed_after"] is NSNull)
    }

    @Test(arguments: ["cancelled", "gate", "project_epoch"])
    func cancellationGateAndProjectLossStayWriteFree(_ fault: String) async throws {
        let f = await fixture()
        let params = try confirmed(f)
        let gate = LogicMutationGate()
        let claim = fault == "gate" ? gate.tryAcquire(operation: "injected-existing-owner") : nil
        defer { if let claim { gate.release(claim) } }
        if fault == "gate" { _ = try #require(claim) }
        if fault == "project_epoch" { await f.registry.bumpProjectEpoch() }
        let text = try await Task {
            if fault == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return HonestContract.jsonString(try await run(f, params: params, gate: gate))
        }.value
        let result = try #require(decodedJSONObject(text))
        #expect(result["state"] as? String == "C")
        #expect(await f.channel.snapshot().2.isEmpty)
        if fault == "cancelled" { try await waitForVerifiedIdle() }
    }

    @Test func sameIdempotencyKeyCannotApplyDifferentConfirmedContent() async throws {
        let f = await fixture()
        let first = try await run(f, params: confirmed(f))
        #expect(first["state"] as? String == "A")
        let count = await f.channel.snapshot().2.count
        var changed = f.wire
        var steps = try #require(changed["steps"]?.arrayValue)
        var step = try #require(steps[0].objectValue)
        var params = try #require(step["params"]?.objectValue)
        params["value"] = .double(37)
        step["params"] = .object(params); steps[0] = .object(step); changed["steps"] = .array(steps)
        let plan = try SagaWire.plan(from: changed)
        changed["confirmed_plan_hash"] = .string(try hash(plan))
        let result = try await run(f, params: changed)
        #expect(result["state"] as? String == "C")
        #expect(result["error"] as? String == HonestContract.FailureError.idempotencyKeyConflict.rawValue)
        #expect(await f.channel.snapshot().2.count == count)
    }

    @Test(arguments: ["threshold", "limiter_on"])
    func parameterOutcomeJSONPreservesItsActualNumericAndBooleanValues(_ param: String) async throws {
        let f = await fixture()
        let result = try await run(f, params: confirmed(f))
        #expect(result["state"] as? String == "A")
        #expect(await f.channel.snapshot().2 == ["threshold", "limiter_on"])
        let rows = try #require(result["parameters"] as? [[String: Any]])
        let row = try #require(rows.first { $0["param"] as? String == param })
        let steps = try #require(result["steps"] as? [[String: Any]])
        let index = param == "threshold" ? 0 : 1
        let evidence = try #require(steps[index]["evidence"] as? [String: Any])
        let before = try #require(evidence["before_state"] as? [String: Any])
        if param == "threshold" {
            #expect(before["value"].flatMap { JSONInspector.number(of: $0) } == 60)
            for key in ["requested", "approved_before", "observed_before", "observed_after"] {
                let expected = key == "requested" || key == "observed_after" ? 38.0 : 60.0
                #expect(row[key].flatMap { JSONInspector.number(of: $0) } == expected)
            }
        } else {
            let prior = try #require(before["value"] as? Bool)
            #expect(!prior)
            for key in ["requested", "approved_before", "observed_before", "observed_after"] {
                let raw = try #require(row[key])
                #expect(JSONInspector.isBoolean(raw))
                if let observed = raw as? Bool {
                    if key == "requested" || key == "observed_after" { #expect(observed) }
                    else { #expect(!observed) }
                } else { Issue.record("parameter outcome \(key) must be a literal JSON Boolean") }
            }
        }
    }
}
}
