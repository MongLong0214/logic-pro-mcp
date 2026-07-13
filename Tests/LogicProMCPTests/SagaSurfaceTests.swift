import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor SagaSurfaceWriteProbeChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private let cache: StateCache
    private let failureCalls: Set<Int>
    private let updatesCache: Bool
    private var calls: [(operation: String, params: [String: String])] = []
    private var boundarySeenAtFirstDispatch = false

    init(
        cache: StateCache = StateCache(),
        failureCalls: Set<Int> = [],
        updatesCache: Bool = true
    ) {
        self.cache = cache
        self.failureCalls = failureCalls
        self.updatesCache = updatesCache
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append((operation, params))
        if calls.count == 1 {
            boundarySeenAtFirstDispatch = await OperationTraceStore.shared.recent(limit: 128)
                .first { $0.operationID == OperationID.systemSagaExecute.rawValue }?
                .events.contains { $0.phase == .writeBoundaryCrossed } ?? false
        }
        if failureCalls.contains(calls.count) {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                extras: ["write_attempted": false]
            ))
        }
        guard let rawIndex = params["index"], let index = Int(rawIndex) else {
            return .error(HonestContract.encodeStateC(error: .invalidParams))
        }
        switch operation {
        case "track.rename":
            guard let name = params["name"] else {
                return .error(HonestContract.encodeStateC(error: .invalidParams))
            }
            if updatesCache { await cache.updateTrack(at: index) { $0.name = name } }
        case "mixer.set_volume":
            guard let rawValue = params["volume"], let value = Double(rawValue) else {
                return .error(HonestContract.encodeStateC(error: .invalidParams))
            }
            if updatesCache { await cache.updateTrack(at: index) { $0.volume = value } }
        default:
            return .error(HonestContract.encodeStateC(error: .commandNotExposed))
        }
        return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "saga surface write probe")
    }

    func writeCount() -> Int { calls.count }
    func recordedOperations() -> [String] { calls.map(\.operation) }
    func sawSystemBoundaryAtFirstDispatch() -> Bool { boundarySeenAtFirstDispatch }
}

private actor SagaSurfaceCountingExecutor: SagaStepExecutor {
    private var calls = 0

    func run(_ step: SagaStep) async -> StepResult {
        calls += 1
        return StepResult(state: .stateA, writeBoundaryCrossed: true, detail: "dispatched")
    }

    func readState(_ step: SagaStep) async -> ObservedState? { nil }
    func runCount() -> Int { calls }
}

@Suite("Saga public MCP surface", .serialized)
struct SagaSurfaceTests {
    private struct Fixture: Sendable {
        let router: ChannelRouter
        let cache: StateCache
        let targetRegistry: TargetRegistry
        let journal: SagaJournal
        let channel: SagaSurfaceWriteProbeChannel
        let targets: [TargetReference]
    }

    private func withSagaEnabled<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await FeatureFlags.withAdr004MutationSagaForTests(true, operation: operation)
    }

    private func withSagaFeatures<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await withSagaEnabled {
            try await FeatureFlags.withAdr002TargetRefForTests(true, operation: operation)
        }
    }

    private func withTraceEnabled<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await FeatureFlags.withAdr005OperationTraceForTests(true, operation: operation)
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

    private func dispatcher(
        command: String,
        params: [String: Value],
        channel: SagaSurfaceWriteProbeChannel
    ) async -> CallTool.Result {
        let router = ChannelRouter()
        await router.register(channel)
        return await SystemDispatcher.handle(
            command: command,
            params: params,
            router: router,
            cache: StateCache()
        )
    }

    private func makeFixture(
        failureCalls: Set<Int> = [],
        populateCache: Bool = true,
        updatesCache: Bool = true,
        journal: SagaJournal = SagaJournal()
    ) async -> Fixture {
        let cache = StateCache()
        let tracks = [
            TrackState(id: 0, name: "Bass", type: .audio, volume: 0.25),
            TrackState(id: 1, name: "Keys", type: .softwareInstrument, volume: 0.2),
        ]
        if populateCache { await cache.updateTracks(tracks) }
        let targetRegistry = TargetRegistry()
        var targets: [TargetReference] = []
        for track in tracks {
            let descriptor = TargetDescriptor(trackIndex: track.id, trackName: track.name)
            targets.append(await targetRegistry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            ))
        }
        let channel = SagaSurfaceWriteProbeChannel(
            cache: cache,
            failureCalls: failureCalls,
            updatesCache: updatesCache
        )
        let router = ChannelRouter()
        await router.register(channel)
        return Fixture(
            router: router,
            cache: cache,
            targetRegistry: targetRegistry,
            journal: journal,
            channel: channel,
            targets: targets
        )
    }

    private func step(
        operationID: OperationID,
        target: TargetReference,
        valueParameter: String,
        value: Value
    ) -> Value {
        .object([
            "operation_id": .string(operationID.rawValue),
            "target_ref": .string(target.rawValue),
            "params": .object([valueParameter: value]),
            "expected_inverse": .object([
                "operation_id": .string(operationID.rawValue),
                "value_parameter": .string(valueParameter),
            ]),
        ])
    }

    private func plan(
        idempotencyKey: String,
        steps: [Value]
    ) -> [String: Value] {
        [
            "steps": .array(steps),
            "idempotency_key": .string(idempotencyKey),
        ]
    }

    private func twoStepPlan(_ fixture: Fixture, key: String) -> [String: Value] {
        plan(idempotencyKey: key, steps: [
            step(
                operationID: .tracksRename,
                target: fixture.targets[0],
                valueParameter: "name",
                value: .string("Sub Bass")
            ),
            step(
                operationID: .mixerSetVolume,
                target: fixture.targets[1],
                valueParameter: "value",
                value: .double(0.8)
            ),
        ])
    }

    private func dispatch(
        command: String,
        params: [String: Value],
        fixture: Fixture,
        dialogPresent: @escaping @Sendable () -> Bool = { false },
        sagaRefreshAfterWrite: (@Sendable () async -> Void)? = nil
    ) async -> CallTool.Result {
        await SystemDispatcher.handle(
            command: command,
            params: params,
            router: fixture.router,
            cache: fixture.cache,
            targetRegistry: fixture.targetRegistry,
            dialogPresent: dialogPresent,
            sagaJournal: fixture.journal,
            sagaRefreshAfterWrite: sagaRefreshAfterWrite
        )
    }

    @Test("saga wire rejects unknown keys, wrong types, and blank keys before writes")
    func strictWireValidationIsStateCAndWriteFree() async throws {
        var malformed: [[String: Value]] = [
            [
                "steps": .array([]),
                "idempotency_key": .string("unknown-plan-key"),
                "unexpected": .bool(true),
            ],
            [
                "steps": .string("not-an-array"),
                "idempotency_key": .string("wrong-steps-type"),
            ],
            [
                "steps": .array([.object([
                    "operation_id": .string(OperationID.tracksRename.rawValue),
                    "params": .object(["name": .string("Lead")]),
                    "expected_inverse": .object([
                        "operation_id": .string(OperationID.tracksRename.rawValue),
                        "value_parameter": .string("name"),
                    ]),
                    "unexpected": .bool(true),
                ])]),
                "idempotency_key": .string("unknown-step-key"),
            ],
            [
                "steps": .array([]),
                "idempotency_key": .string("   "),
            ],
            plan(idempotencyKey: "rename-type", steps: [
                .object([
                    "operation_id": .string(OperationID.tracksRename.rawValue),
                    "params": .object(["name": .int(42)]),
                    "expected_inverse": .object([
                        "operation_id": .string(OperationID.tracksRename.rawValue),
                        "value_parameter": .string("name"),
                    ]),
                ]),
            ]),
            plan(idempotencyKey: "volume-type", steps: [
                .object([
                    "operation_id": .string(OperationID.mixerSetVolume.rawValue),
                    "params": .object(["value": .string("0.8")]),
                    "expected_inverse": .object([
                        "operation_id": .string(OperationID.mixerSetVolume.rawValue),
                        "value_parameter": .string("value"),
                    ]),
                ]),
            ]),
            plan(idempotencyKey: "toggle-type", steps: [
                .object([
                    "operation_id": .string(OperationID.tracksMute.rawValue),
                    "params": .object(["enabled": .int(1)]),
                    "expected_inverse": .object([
                        "operation_id": .string(OperationID.tracksMute.rawValue),
                        "value_parameter": .string("enabled"),
                    ]),
                ]),
            ]),
            plan(idempotencyKey: "unknown-param", steps: [
                .object([
                    "operation_id": .string(OperationID.tracksRename.rawValue),
                    "params": .object([
                        "name": .string("Lead"),
                        "unexpected": .bool(true),
                    ]),
                    "expected_inverse": .object([
                        "operation_id": .string(OperationID.tracksRename.rawValue),
                        "value_parameter": .string("name"),
                    ]),
                ]),
            ]),
            [
                "steps": .array([]),
                "idempotency_key": .string(String(repeating: "k", count: 257)),
            ],
        ]
        malformed.append(plan(
            idempotencyKey: "too-many-steps",
            steps: Array(repeating: .object([
                "operation_id": .string(OperationID.tracksRename.rawValue),
                "params": .object(["name": .string("Lead")]),
                "expected_inverse": .object([
                    "operation_id": .string(OperationID.tracksRename.rawValue),
                    "value_parameter": .string("name"),
                ]),
            ]), count: SagaWire.maxPlanSteps + 1)
        ))

        for command in ["saga_preflight", "saga_execute"] {
            for params in malformed {
                let channel = SagaSurfaceWriteProbeChannel()
                let result = await dispatcher(
                    command: command,
                    params: params,
                    channel: channel
                )
                let object = try resultObject(result)
                #expect(result.isError ?? false)
                #expect(object["state"] as? String == "C")
                #expect(object["error"] as? String == "invalid_params")
                #expect(object["journal_scope"] as? String == "session")
                #expect(await channel.writeCount() == 0)
            }
        }

        for command in ["saga_status", "saga_cancel"] {
            let channel = SagaSurfaceWriteProbeChannel()
            let result = await dispatcher(
                command: command,
                params: [
                    "idempotency_key": .string("strict-key"),
                    "unexpected": .bool(true),
                ],
                channel: channel
            )
            let object = try resultObject(result)
            #expect(result.isError ?? false)
            #expect(object["state"] as? String == "C")
            #expect(object["error"] as? String == "invalid_params")
            #expect(await channel.writeCount() == 0)
        }
    }

    @Test("preflight reports engine issues and guarantees zero writes")
    func emptyPlanPreflightReportsIssueWithoutWrites() async throws {
        try await withSagaEnabled {
            let channel = SagaSurfaceWriteProbeChannel()
            let result = await dispatcher(
                command: "saga_preflight",
                params: [
                    "steps": .array([]),
                    "idempotency_key": .string("empty-plan"),
                ],
                channel: channel
            )
            let object = try resultObject(result)
            let issues = try #require(object["issues"] as? [[String: Any]])

            #expect(!(try #require(object["ok"] as? Bool)))
            #expect(issues.contains { $0["code"] as? String == "empty_plan" })
            #expect(object["writes_performed"] as? Int == 0)
            #expect(await channel.writeCount() == 0)
        }
    }

    @Test("saga_status registry keys match its in-process exact parser")
    func sagaStatusRegistryMatchesDispatcherValidation() async throws {
        // Deterministic saga parser only; AX/CGEvent parameter truth remains live qualification (B4).
        let spec = try #require(OperationRegistry.spec(
            tool: ToolID.logicSystem.rawValue,
            command: "saga_status"
        ))
        #expect(spec.allowedParams == ["idempotency_key"])
        #expect(OperationRegistry.strictParamValidationOptOuts.contains(spec.id))

        let allowedChannel = SagaSurfaceWriteProbeChannel()
        let allowed = await dispatcher(
            command: "saga_status",
            params: ["idempotency_key": .string("registry-parser-proof")],
            channel: allowedChannel
        )
        let allowedBody = try resultObject(allowed)
        #expect(allowed.isError == true)
        #expect(allowedBody["error"] as? String == "element_not_found")
        #expect(allowedBody["journal_scope"] as? String == "session")
        #expect(await allowedChannel.writeCount() == 0)
        #expect(LogicProServer.strictParamValidationResult(
            tool: spec.tool.rawValue,
            command: spec.command,
            params: ["idempotency_key": .string("registry-parser-proof")]
        ) == nil)

        for key in ["index", "target_ref", "__unregistered"] {
            let channel = SagaSurfaceWriteProbeChannel()
            let rejected = await dispatcher(
                command: "saga_status",
                params: [
                    "idempotency_key": .string("registry-parser-proof"),
                    key: .string("rejected"),
                ],
                channel: channel
            )
            let body = try resultObject(rejected)
            #expect(rejected.isError == true)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "invalid_params")
            #expect(body["journal_scope"] as? String == "session")
            #expect(await channel.writeCount() == 0)
            #expect(LogicProServer.strictParamValidationResult(
                tool: spec.tool.rawValue,
                command: spec.command,
                params: [key: .string("generic opt-out remains explicit")]
            ) == nil)
        }
    }

    @Test("status and cancel return typed missing-record failures")
    func missingJournalRecordIsTyped() async throws {
        for command in ["saga_status", "saga_cancel"] {
            let channel = SagaSurfaceWriteProbeChannel()
            let result = await dispatcher(
                command: command,
                params: ["idempotency_key": .string("missing-record")],
                channel: channel
            )
            let object = try resultObject(result)
            #expect(result.isError ?? false)
            #expect(object["state"] as? String == "C")
            #expect(object["error"] as? String == "element_not_found")
            #expect(object["journal_scope"] as? String == "session")
            #expect(!(try #require(object["journal_survives_process_restart"] as? Bool)))
            #expect(await channel.writeCount() == 0)
        }
    }

    @Test("logic_system documents the four saga commands and honest limits")
    func toolDescriptionDocumentsSagaContract() throws {
        let description = try #require(SystemDispatcher.tool.description)

        for command in ["saga_preflight", "saga_execute", "saga_status", "saga_cancel"] {
            #expect(description.contains(command))
        }
        #expect(description.contains("does not promise all-or-nothing completion or durable recovery"))
        #expect(description.contains("cleared when the server session ends"))
        #expect(description.contains("process restart"))
    }

    @Test("preflight reports per-step before-state availability and an unavailable issue")
    func preflightAvailabilityIsPerStepAndWriteFree() async throws {
        try await withSagaFeatures {
            let ready = await makeFixture()
            let readyResult = await dispatch(
                command: "saga_preflight",
                params: twoStepPlan(ready, key: "preflight-ready"),
                fixture: ready
            )
            let readyObject = try resultObject(readyResult)
            let readyAvailability = try #require(
                readyObject["before_state_availability"] as? [[String: Any]]
            )

            #expect(try #require(readyObject["ok"] as? Bool))
            #expect(readyAvailability.count == 2)
            #expect(readyAvailability.allSatisfy { ($0["available"] as? Bool) ?? false })
            #expect(await ready.channel.writeCount() == 0)

            let unavailable = await makeFixture(populateCache: false)
            let unavailableResult = await dispatch(
                command: "saga_preflight",
                params: plan(idempotencyKey: "preflight-unavailable", steps: [
                    step(
                        operationID: .tracksRename,
                        target: unavailable.targets[0],
                        valueParameter: "name",
                        value: .string("Lead")
                    ),
                ]),
                fixture: unavailable
            )
            let unavailableObject = try resultObject(unavailableResult)
            let issues = try #require(unavailableObject["issues"] as? [[String: Any]])
            let availability = try #require(
                unavailableObject["before_state_availability"] as? [[String: Any]]
            )
            let firstAvailability = try #require(availability.first)
            let isAvailable = try #require(firstAvailability["available"] as? Bool)

            #expect(!(try #require(unavailableObject["ok"] as? Bool)))
            #expect(issues.contains { $0["code"] as? String == "before_state_unavailable" })
            #expect(!isAvailable)
            #expect(await unavailable.channel.writeCount() == 0)
        }
    }

    @Test("two-step execute returns State A with per-step evidence")
    func executeSuccessReturnsEvidence() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture()
            let result = await dispatch(
                command: "saga_execute",
                params: twoStepPlan(fixture, key: "execute-success"),
                fixture: fixture
            )
            let object = try resultObject(result)
            let steps = try #require(object["steps"] as? [[String: Any]])
            let isError = result.isError ?? false

            #expect(!isError)
            #expect(object["state"] as? String == "A")
            #expect(try #require(object["success"] as? Bool))
            #expect(!(try #require(object["duplicate"] as? Bool)))
            #expect(steps.count == 2)
            for step in steps {
                let stepResult = try #require(step["result"] as? [String: Any])
                let evidence = try #require(step["evidence"] as? [String: Any])
                let verification = try #require(evidence["verification"] as? [String: Any])
                let readback = try #require(verification["readback"] as? [String: Any])
                #expect(stepResult["state"] as? String == "A")
                #expect(verification["disposition"] as? String == "applied")
                #expect(!(try #require(readback["evidence"] as? String)).isEmpty)
            }
            let volumeEvidence = try #require(steps[1]["evidence"] as? [String: Any])
            let volumeVerification = try #require(
                volumeEvidence["verification"] as? [String: Any]
            )
            let volumeReadback = try #require(
                volumeVerification["readback"] as? [String: Any]
            )
            #expect(volumeReadback["value"] is NSNumber)
            #expect(!(volumeReadback["value"] is String))
            #expect(await fixture.channel.recordedOperations() == [
                "track.rename", "mixer.set_volume",
            ])
        }
    }

    @Test("surface refreshes observed state after a verified channel write")
    func executeRefreshesBeforeEngineVerification() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(updatesCache: false)
            let result = try resultObject(await dispatch(
                command: "saga_execute",
                params: plan(idempotencyKey: "refresh-before-verify", steps: [
                    step(
                        operationID: .mixerSetVolume,
                        target: fixture.targets[1],
                        valueParameter: "value",
                        value: .double(0.75)
                    ),
                ]),
                fixture: fixture,
                sagaRefreshAfterWrite: {
                    await fixture.cache.updateTrack(at: 1) { $0.volume = 0.75 }
                }
            ))

            #expect(result["state"] as? String == "A")
            #expect(await fixture.channel.writeCount() == 1)
        }
    }

    @Test("second-step failure stays State C after reverse compensation")
    func executeFailureReturnsCompensationEvidence() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(failureCalls: [2])
            let result = await dispatch(
                command: "saga_execute",
                params: twoStepPlan(fixture, key: "execute-compensated"),
                fixture: fixture
            )
            let object = try resultObject(result)
            let compensation = try #require(object["compensation"] as? [String: Any])
            let readback = try #require(compensation["readback_evidence"] as? [[String: Any]])
            let summary = try #require(compensation["journal_summary"] as? [String: Any])

            #expect(result.isError ?? false)
            #expect(object["state"] as? String == "C")
            #expect(object["error"] as? String == "saga_execution_failed")
            #expect(compensation["status"] as? String == "fully_compensated")
            #expect(try #require(compensation["fully_compensated"] as? Bool))
            #expect(!readback.isEmpty)
            #expect(summary["record_count"] as? Int == 2)
            #expect(summary["write_boundary_count"] as? Int == 2)
            #expect(summary["forward_write_boundary_count"] as? Int == 1)
            #expect(summary["compensation_write_boundary_count"] as? Int == 1)
            #expect(await fixture.channel.recordedOperations() == [
                "track.rename", "mixer.set_volume", "track.rename",
            ])
            #expect((await fixture.cache.getTracks()).first?.name == "Bass")
        }
    }

    @Test("an idempotency key cannot replay a different plan")
    func idempotencyKeyIsBoundToCanonicalPlan() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture()
            let firstPlan = twoStepPlan(fixture, key: "plan-bound-key")
            let secondPlan = plan(idempotencyKey: "plan-bound-key", steps: [
                step(
                    operationID: .tracksRename,
                    target: fixture.targets[0],
                    valueParameter: "name",
                    value: .string("Different Name")
                ),
            ])

            let first = try resultObject(await dispatch(
                command: "saga_execute",
                params: firstPlan,
                fixture: fixture
            ))
            let preflight = try resultObject(await dispatch(
                command: "saga_preflight",
                params: secondPlan,
                fixture: fixture
            ))
            let conflict = try resultObject(await dispatch(
                command: "saga_execute",
                params: secondPlan,
                fixture: fixture
            ))
            let preflightIssues = try #require(preflight["issues"] as? [[String: Any]])

            #expect(first["state"] as? String == "A")
            #expect(!(try #require(preflight["ok"] as? Bool)))
            #expect(preflightIssues.contains {
                $0["code"] as? String == "idempotency_key_conflict"
            })
            #expect(preflight["before_state_availability"] != nil)
            #expect(conflict["state"] as? String == "C")
            #expect(conflict["error"] as? String == "idempotency_key_conflict")
            #expect(conflict["steps"] == nil)
            #expect(await fixture.channel.writeCount() == 2)
        }
    }

    @Test("execute classifies unavailable before-state separately from malformed input")
    func executeUnavailableBeforeStateIsReadbackUnavailable() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(populateCache: false)
            let result = try resultObject(await dispatch(
                command: "saga_execute",
                params: plan(idempotencyKey: "execute-no-before", steps: [
                    step(
                        operationID: .tracksRename,
                        target: fixture.targets[0],
                        valueParameter: "name",
                        value: .string("Lead")
                    ),
                ]),
                fixture: fixture
            ))

            #expect(result["state"] as? String == "C")
            #expect(result["error"] as? String == "readback_unavailable")
            #expect(await fixture.channel.writeCount() == 0)
        }
    }

    @Test("execute preserves feature-disabled and stale-target failure classes")
    func executePreflightFailureClassesAreTyped() async throws {
        let featureFixture = await makeFixture()
        let featureResult = try await FeatureFlags.withAdr004MutationSagaForTests(false) {
            try await FeatureFlags.withAdr002TargetRefForTests(true) {
                try resultObject(await dispatch(
                    command: "saga_execute",
                    params: twoStepPlan(featureFixture, key: "feature-disabled"),
                    fixture: featureFixture
                ))
            }
        }
        #expect(featureResult["error"] as? String == "not_supported")
        #expect(await featureFixture.channel.writeCount() == 0)

        try await withSagaFeatures {
            let staleFixture = await makeFixture()
            let stale = try resultObject(await dispatch(
                command: "saga_execute",
                params: plan(idempotencyKey: "stale-target", steps: [
                    step(
                        operationID: .tracksRename,
                        target: TargetReference(rawValue: "trk_missing"),
                        valueParameter: "name",
                        value: .string("Lead")
                    ),
                ]),
                fixture: staleFixture
            ))
            #expect(stale["error"] as? String == "stale_target_reference")
            #expect(await staleFixture.channel.writeCount() == 0)
        }
    }

    @Test("failed compensation returns State B with reconciliation evidence")
    func uncertainCompensationReturnsStateB() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture(failureCalls: [2, 3])
            let result = await dispatch(
                command: "saga_execute",
                params: twoStepPlan(fixture, key: "execute-reconcile"),
                fixture: fixture
            )
            let object = try resultObject(result)
            let compensation = try #require(object["compensation"] as? [String: Any])
            let evidence = try #require(compensation["readback_evidence"] as? [[String: Any]])
            let isError = result.isError ?? false

            #expect(!isError)
            #expect(object["state"] as? String == "B")
            #expect(object["reason"] as? String == "saga_reconciliation_required")
            #expect(compensation["status"] as? String == "compensation_failed")
            #expect(!(try #require(compensation["fully_compensated"] as? Bool)))
            #expect(!evidence.isEmpty)
        }
    }

    @Test("completed idempotency key returns the stored outcome and status without re-execution")
    func duplicateAndStatusUseSessionJournal() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture()
            let params = twoStepPlan(fixture, key: "duplicate-completed")
            let first = try resultObject(await dispatch(
                command: "saga_execute",
                params: params,
                fixture: fixture
            ))
            let duplicate = try resultObject(await dispatch(
                command: "saga_execute",
                params: params,
                fixture: fixture
            ))
            let status = try resultObject(await dispatch(
                command: "saga_status",
                params: ["idempotency_key": .string("duplicate-completed")],
                fixture: fixture
            ))
            let record = try #require(status["record"] as? [String: Any])
            let outcome = try #require(record["outcome"] as? [String: Any])

            #expect(!(try #require(first["duplicate"] as? Bool)))
            #expect(try #require(duplicate["duplicate"] as? Bool))
            #expect(duplicate["state"] as? String == "A")
            #expect(await fixture.channel.writeCount() == 2)
            #expect(record["status"] as? String == "completed")
            #expect(outcome["state"] as? String == "A")
            #expect(status["journal_scope"] as? String == "session")

            let cancel = try resultObject(await dispatch(
                command: "saga_cancel",
                params: ["idempotency_key": .string("duplicate-completed")],
                fixture: fixture
            ))
            #expect(cancel["state"] as? String == "C")
            #expect(cancel["error"] as? String == "unsupported_state")
        }
    }

    @Test("bounded journal rejects new keys without evicting completed outcomes")
    func journalCapacityFailsClosed() async throws {
        try await withSagaFeatures {
            let journal = SagaJournal(maxRecords: 1)
            let fixture = await makeFixture(journal: journal)
            let first = try resultObject(await dispatch(
                command: "saga_execute",
                params: twoStepPlan(fixture, key: "capacity-first"),
                fixture: fixture
            ))
            let second = try resultObject(await dispatch(
                command: "saga_execute",
                params: plan(idempotencyKey: "capacity-second", steps: [
                    step(
                        operationID: .mixerSetVolume,
                        target: fixture.targets[1],
                        valueParameter: "value",
                        value: .double(0.6)
                    ),
                ]),
                fixture: fixture
            ))

            #expect(first["state"] as? String == "A")
            #expect(second["state"] as? String == "C")
            #expect(second["error"] as? String == "saga_journal_capacity_exceeded")
            #expect(await fixture.channel.writeCount() == 2)
        }
    }

    @Test("session clear invalidates late journal completion")
    func journalGenerationRejectsLateCompletion() async throws {
        let journal = SagaJournal()
        let plan = SagaPlan(steps: [], idempotencyKey: "old-session")
        let begin = await journal.begin(plan)
        let claim: SagaJournal.Claim
        switch begin {
        case .started(let startedClaim): claim = startedClaim
        default:
            Issue.record("expected a new journal claim")
            return
        }
        await journal.clear()
        await journal.complete(
            claim,
            outcome: SagaJournal.StoredOutcome(
                body: HonestContract.encodeStateA(),
                isError: false
            )
        )

        #expect(await journal.record(for: "old-session") == nil)
    }

    @Test("an in-progress idempotency key remains bound to its original plan")
    func inProgressJournalClaimRejectsDifferentPlan() async throws {
        let journal = SagaJournal()
        let original = SagaPlan(steps: [], idempotencyKey: "plan-bound-running")
        let different = SagaPlan(
            steps: [SagaStep(
                operationID: .tracksRename,
                targetRef: nil,
                params: ["name": .string("Different")],
                expectedInverse: SagaExpectedInverse(
                    operationID: .tracksRename,
                    valueParameter: "name"
                )
            )],
            idempotencyKey: original.idempotencyKey
        )

        guard case .started = await journal.begin(original) else {
            Issue.record("expected a new journal claim")
            return
        }

        #expect(await journal.begin(different) == .conflict)
        #expect(await journal.disposition(for: different) == .conflict)
    }

    @Test("task cancellation prevents the next surface step dispatch")
    func cancelledSurfaceExecutorDoesNotDispatch() async {
        let base = SagaSurfaceCountingExecutor()
        let executor = SagaSurfaceStepExecutor(base: base)
        let step = SagaStep(
            operationID: .tracksRename,
            targetRef: nil,
            params: ["name": .string("Cancelled")],
            expectedInverse: SagaExpectedInverse(
                operationID: .tracksRename,
                valueParameter: "name"
            )
        )
        let task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return await executor.run(step)
        }
        task.cancel()

        let result = await task.value
        #expect(result.state == .stateC)
        #expect(!result.writeBoundaryCrossed)
        #expect(await base.runCount() == 0)
    }

    @Test("saga mutation gate is never stale-reclaimed before explicit release")
    func sagaGateClaimIsReleaseOnly() throws {
        let gate = LogicMutationGate(staleHolderTTL: 360, timedOutReclaimGrace: 15)
        let start = Date(timeIntervalSince1970: 1_000)
        let claim = try #require(gate.tryAcquire(
            operation: OperationID.systemSagaExecute.rawValue,
            now: start,
            reclaimPolicy: .releaseOnly
        ))

        gate.markTimedOut(claim, now: start.addingTimeInterval(300))
        #expect(gate.tryAcquire(
            operation: OperationID.tracksMute.rawValue,
            now: start.addingTimeInterval(361)
        ) == nil)

        gate.release(claim)
        #expect(gate.tryAcquire(
            operation: OperationID.tracksMute.rawValue,
            now: start.addingTimeInterval(362)
        ) != nil)
    }

    @Test("saga deadline responses preserve session journal disclosure")
    func sagaTimeoutsDiscloseJournalScope() throws {
        for command in ["saga_preflight", "saga_execute", "saga_status", "saga_cancel"] {
            let result = LogicProServer.deadlineTimeoutResult(
                tool: ToolID.logicSystem.rawValue,
                command: command,
                seconds: 1,
                mutationMayStillBeRunning: command == "saga_execute",
                mutationGateReclaimableAfterGrace: command != "saga_execute"
            )
            let object = try resultObject(result)

            #expect(object["journal_scope"] as? String == "session")
            #expect(!(try #require(object["journal_survives_process_restart"] as? Bool)))
        }
    }

    @Test("in-progress execute is typed and cancel is honestly unsupported")
    func inProgressAndCancelAreTyped() async throws {
        try await withSagaFeatures {
            let fixture = await makeFixture()
            let params = twoStepPlan(fixture, key: "running-key")
            let runningPlan = try SagaWire.plan(from: params)
            let begin = await fixture.journal.begin(runningPlan)
            guard case .started = begin else {
                Issue.record("expected a new in-progress journal claim")
                return
            }

            let execute = try resultObject(await dispatch(
                command: "saga_execute",
                params: params,
                fixture: fixture
            ))
            let status = try resultObject(await dispatch(
                command: "saga_status",
                params: ["idempotency_key": .string("running-key")],
                fixture: fixture
            ))
            let cancel = try resultObject(await dispatch(
                command: "saga_cancel",
                params: ["idempotency_key": .string("running-key")],
                fixture: fixture
            ))
            let record = try #require(status["record"] as? [String: Any])

            #expect(execute["state"] as? String == "C")
            #expect(execute["error"] as? String == "saga_in_progress")
            #expect(record["status"] as? String == "in_progress")
            #expect(cancel["state"] as? String == "C")
            #expect(cancel["error"] as? String == "not_supported")
            #expect(await fixture.channel.writeCount() == 0)
        }
    }

    @Test("execute trace crosses the surface boundary before first step dispatch")
    func executeTraceBoundaryPrecedesStepDispatch() async throws {
        try await withTraceEnabled {
            try await withSagaFeatures {
                await OperationTraceStore.shared.clear()
                let fixture = await makeFixture()
                let result = await dispatch(
                    command: "saga_execute",
                    params: plan(idempotencyKey: "trace-execute", steps: [
                        step(
                            operationID: .tracksRename,
                            target: fixture.targets[0],
                            valueParameter: "name",
                            value: .string("Trace Bass")
                        ),
                    ]),
                    fixture: fixture
                )
                let object = try resultObject(result)
                let trace = try #require(
                    await OperationTraceStore.shared.recent(limit: 128)
                        .first { $0.operationID == OperationID.systemSagaExecute.rawValue }
                )

                #expect(object["state"] as? String == "A")
                #expect(trace.events.contains { $0.phase == .writeBoundaryCrossed })
                #expect(await fixture.channel.sawSystemBoundaryAtFirstDispatch())
                await OperationTraceStore.shared.clear()
            }
        }
    }

    @Test("execute trace stays before the boundary when downstream validation refuses dispatch")
    func executeTraceDoesNotCrossForBlockingDialog() async throws {
        try await withTraceEnabled {
            try await withSagaFeatures {
                await OperationTraceStore.shared.clear()
                let fixture = await makeFixture()
                let result = await dispatch(
                    command: "saga_execute",
                    params: plan(idempotencyKey: "trace-no-dispatch", steps: [
                        step(
                            operationID: .tracksRename,
                            target: fixture.targets[0],
                            valueParameter: "name",
                            value: .string("Blocked")
                        ),
                    ]),
                    fixture: fixture,
                    dialogPresent: { true }
                )
                let trace = try #require(
                    await OperationTraceStore.shared.recent(limit: 128)
                        .first { $0.operationID == OperationID.systemSagaExecute.rawValue }
                )

                #expect(result.isError ?? false)
                #expect(!trace.events.contains { $0.phase == .writeBoundaryCrossed })
                #expect(await fixture.channel.writeCount() == 0)
                await OperationTraceStore.shared.clear()
            }
        }
    }

    @Test("MCP protocol routes saga commands through logic_system")
    func protocolSurfaceReturnsTypedSagaFailures() async throws {
        let journal = SagaJournal()
        let mutationGate = LogicMutationGate()
        let server = LogicProServer(sagaJournal: journal, mutationGate: mutationGate)
        let transport = MCPProtocolProbeTransport()
        try await server.startProtocolProbe(transport: transport)
        defer { Task { await server.stopProtocolProbe() } }

        await transport.queueJSON(probeInitializeFrame(id: 1))
        _ = try await waitForProbeResponse(transport, id: 1)

        let runningPlan = SagaPlan(steps: [], idempotencyKey: "protocol-running")
        guard case .started = await journal.begin(runningPlan) else {
            Issue.record("expected in-progress protocol journal record")
            return
        }
        let gateClaim = try #require(
            mutationGate.tryAcquire(operation: OperationID.systemSagaExecute.rawValue)
        )
        defer { mutationGate.release(gateClaim) }

        let cases: [(id: Int, command: String, params: String, error: String)] = [
            (
                2,
                "saga_preflight",
                #"{"steps":[],"idempotency_key":"protocol-invalid","unexpected":true}"#,
                "invalid_params"
            ),
            (3, "saga_status", #"{"idempotency_key":"protocol-missing"}"#, "element_not_found"),
            (
                4,
                "saga_execute",
                #"{"steps":[],"idempotency_key":"protocol-running"}"#,
                "saga_in_progress"
            ),
            (5, "saga_cancel", #"{"idempotency_key":"protocol-running"}"#, "not_supported"),
        ]

        for item in cases {
            await transport.queueJSON(probeToolCallFrame(
                id: item.id,
                name: SystemDispatcher.tool.name,
                command: item.command,
                params: item.params
            ))
            let response = try await waitForProbeResponse(transport, id: item.id)
            let result = try #require(response["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            let first = try #require(content.first)
            let text = try #require(first["text"] as? String)
            let body = try #require(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            )

            #expect(try #require(result["isError"] as? Bool))
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == item.error)
            #expect(body["journal_scope"] as? String == "session")
        }
        await server.stopProtocolProbe()
        #expect(await journal.record(for: "protocol-running") == nil)
    }
}
