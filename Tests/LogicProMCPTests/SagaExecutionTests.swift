import Foundation
import MCP
import Testing
@testable import LogicProMCP

private final class SagaDialogProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return false
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor SagaRecordingChannel: Channel {
    nonisolated let id: ChannelID = .accessibility

    private let cache: StateCache
    private let surface: SagaLiveTrackSurface
    private let failureAt: Int?
    private let failureCode: String
    private let failureWriteAttempted: Bool?
    private let malformedWriteAttempted: Bool
    private let failureSuccess: Bool
    private var calls: [(operation: String, params: [String: String])] = []

    init(
        cache: StateCache,
        surface: SagaLiveTrackSurface,
        failureAt: Int? = nil,
        failureCode: String = "invalid_params",
        failureWriteAttempted: Bool? = nil,
        malformedWriteAttempted: Bool = false,
        failureSuccess: Bool = false
    ) {
        self.cache = cache
        self.surface = surface
        self.failureAt = failureAt
        self.failureCode = failureCode
        self.failureWriteAttempted = failureWriteAttempted
        self.malformedWriteAttempted = malformedWriteAttempted
        self.failureSuccess = failureSuccess
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append((operation, params))
        if calls.count == failureAt {
            var envelope: [String: Any] = [
                "success": failureSuccess,
                "state": "C",
                "error": failureCode,
                "operation": operation,
            ]
            if malformedWriteAttempted {
                envelope["write_attempted"] = "invalid"
            } else if let failureWriteAttempted {
                envelope["write_attempted"] = failureWriteAttempted
            }
            let encoded = HonestContract.jsonString(envelope)
            return failureSuccess ? .success(encoded) : .error(encoded)
        }

        guard let rawIndex = params["index"], let index = Int(rawIndex) else {
            return .error(HonestContract.encodeStateC(error: .invalidParams))
        }
        // A write lands on the LIVE surface (what Logic actually holds) and is
        // mirrored into the cache, exactly as production's refreshAfterWrite
        // eventually would. Tests that need a stale mirror desync them by hand.
        switch operation {
        case "track.rename":
            guard let name = params["name"] else {
                return .error(HonestContract.encodeStateC(error: .invalidParams))
            }
            surface.update(index) { $0.name = name }
            await cache.updateTrack(at: index) { $0.name = name }
        case "mixer.set_volume":
            guard let raw = params["volume"], let value = Double(raw) else {
                return .error(HonestContract.encodeStateC(error: .invalidParams))
            }
            surface.update(index) { $0.volume = value }
            await cache.updateTrack(at: index) { $0.volume = value }
        case "mixer.set_pan":
            guard let raw = params["pan"], let value = Double(raw) else {
                return .error(HonestContract.encodeStateC(error: .invalidParams))
            }
            surface.update(index) { $0.pan = value }
            await cache.updateTrack(at: index) { $0.pan = value }
        case "track.set_mute":
            surface.update(index) { $0.isMuted = params["enabled"] == "true" }
            await cache.updateTrack(at: index) { $0.isMuted = params["enabled"] == "true" }
        case "track.set_solo":
            surface.update(index) { $0.isSoloed = params["enabled"] == "true" }
            await cache.updateTrack(at: index) { $0.isSoloed = params["enabled"] == "true" }
        case "track.set_arm":
            surface.update(index) { $0.isArmed = params["enabled"] == "true" }
            await cache.updateTrack(at: index) { $0.isArmed = params["enabled"] == "true" }
        default:
            return .error(HonestContract.encodeStateC(error: .commandNotExposed))
        }
        return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "saga recording channel")
    }

    func recordedCalls() -> [(operation: String, params: [String: String])] {
        calls
    }
}

/// Fails the rename step AFTER its write boundary so the preceding volume
/// step's compensation runs — while leaving the live-read seams under test
/// entirely untouched.
private struct RenameFailingExecutor: SagaStepExecutor {
    let base: ProductionSagaStepExecutor

    func run(_ step: SagaStep) async -> StepResult {
        guard step.operationID == .tracksRename else { return await base.run(step) }
        return StepResult(
            state: .stateC,
            writeBoundaryCrossed: true,
            detail: "tracks.rename: error=ax_write_failed"
        )
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        await base.readState(step)
    }
}

@Suite("Production saga execution", .serialized)
struct SagaExecutionTests {
    private struct Scenario: Sendable {
        let before: Value
        let desired: Value
        let evidence: String
        let channelOperation: String
    }

    private struct Fixture: Sendable {
        let executor: ProductionSagaStepExecutor
        let channel: SagaRecordingChannel
        let cache: StateCache
        let surface: SagaLiveTrackSurface
        let registry: TargetRegistry
        let target: TargetReference
    }

    private func makeFixture(
        failureAt: Int? = nil,
        failureCode: String = "invalid_params",
        failureWriteAttempted: Bool? = nil,
        malformedWriteAttempted: Bool = false,
        failureSuccess: Bool = false,
        dialogPresent: @escaping @Sendable () -> Bool = { false }
    ) async -> Fixture {
        let track = TrackState(
            id: 0,
            name: "Bass",
            type: .audio,
            isMuted: false,
            isSoloed: true,
            isArmed: false,
            volume: 0.25,
            pan: -0.5
        )
        let cache = StateCache()
        await cache.updateTracks([track])
        let surface = SagaLiveTrackSurface([track])
        let registry = TargetRegistry()
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Bass")
        let target = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let channel = SagaRecordingChannel(
            cache: cache,
            surface: surface,
            failureAt: failureAt,
            failureCode: failureCode,
            failureWriteAttempted: failureWriteAttempted,
            malformedWriteAttempted: malformedWriteAttempted,
            failureSuccess: failureSuccess
        )
        let router = ChannelRouter()
        await router.register(channel)
        return Fixture(
            executor: ProductionSagaStepExecutor(
                router: router,
                cache: cache,
                targetRegistry: registry,
                dialogPresent: dialogPresent,
                liveReadback: surface.readback
            ),
            channel: channel,
            cache: cache,
            surface: surface,
            registry: registry,
            target: target
        )
    }

    private func scenario(for operationID: OperationID) -> Scenario? {
        switch operationID {
        case .tracksRename:
            Scenario(
                before: .string("Bass"),
                desired: .string("Lead"),
                evidence: "ax_live tracks[0].name (track_name)",
                channelOperation: "track.rename"
            )
        case .mixerSetVolume:
            Scenario(
                before: .double(0.25),
                desired: .double(0.75),
                evidence: "ax_live tracks[0].volume (header_fader)",
                channelOperation: "mixer.set_volume"
            )
        case .mixerSetPan:
            Scenario(
                before: .double(-0.5),
                desired: .double(0.5),
                evidence: "ax_live tracks[0].pan (header_pan)",
                channelOperation: "mixer.set_pan"
            )
        case .tracksMute:
            Scenario(
                before: .bool(false),
                desired: .bool(true),
                evidence: "ax_live tracks[0].isMuted (track_toggle)",
                channelOperation: "track.set_mute"
            )
        case .tracksSolo:
            Scenario(
                before: .bool(true),
                desired: .bool(false),
                evidence: "ax_live tracks[0].isSoloed (track_toggle)",
                channelOperation: "track.set_solo"
            )
        case .tracksArm:
            Scenario(
                before: .bool(false),
                desired: .bool(true),
                evidence: "ax_live tracks[0].isArmed (track_toggle)",
                channelOperation: "track.set_arm"
            )
        default:
            nil
        }
    }

    private func step(
        _ operationID: OperationID,
        target: TargetReference?,
        value: Value
    ) -> SagaStep {
        let valueParameter: String
        switch operationID {
        case .tracksRename:
            valueParameter = "name"
        case .tracksMute, .tracksSolo, .tracksArm:
            valueParameter = "enabled"
        default:
            valueParameter = "value"
        }
        return SagaStep(
            operationID: operationID,
            targetRef: target,
            params: [valueParameter: value],
            expectedInverse: SagaExpectedInverse(
                operationID: operationID,
                valueParameter: valueParameter
            )
        )
    }

    @Test(arguments: [
        OperationID.tracksRename,
        .mixerSetVolume,
        .mixerSetPan,
        .tracksMute,
        .tracksSolo,
        .tracksArm,
    ])
    func allowlistedOperationRunsThroughDispatcherAndReadsCorrectField(
        _ operationID: OperationID
    ) async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            guard let scenario = scenario(for: operationID) else {
                Issue.record("missing scenario for \(operationID.rawValue)")
                return
            }
            let fixture = await makeFixture()
            let sagaStep = step(operationID, target: fixture.target, value: scenario.desired)

            let observed = await fixture.executor.readState(sagaStep)
            #expect(observed?.value == scenario.before)
            #expect(observed?.evidence == scenario.evidence)

            let result = await fixture.executor.run(sagaStep)
            #expect(result.state == .stateA)
            #expect(result.writeBoundaryCrossed)
            #expect(result.detail.contains(operationID.rawValue))

            let calls = await fixture.channel.recordedCalls()
            #expect(calls.count == 1)
            #expect(calls.first?.operation == scenario.channelOperation)
            #expect(calls.first?.params["index"] == "0")
        }
    }

    @Test("non-allowlisted operations fail closed without dispatch")
    func nonAllowlistedOperationFailsClosedWithoutDispatch() async {
        let fixture = await makeFixture()
        let result = await fixture.executor.run(
            step(.transportPlay, target: fixture.target, value: .bool(true))
        )

        #expect(result.state == .stateC)
        #expect(!result.writeBoundaryCrossed)
        #expect(result.detail == "operation not saga-allowlisted")
        #expect(await fixture.channel.recordedCalls().isEmpty)
    }

    @Test("target references fail closed when ADR-002 resolution is disabled")
    func targetReferenceRequiresAdr002Resolution() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = await makeFixture()
            let result = await fixture.executor.run(
                step(.tracksMute, target: fixture.target, value: .bool(true))
            )

            #expect(result.state == .stateC)
            #expect(!result.writeBoundaryCrossed)
            #expect(result.detail.contains("target_reference_resolution_unavailable"))
            #expect(await fixture.channel.recordedCalls().isEmpty)
        }
    }

    @Test("track dispatcher receives the injected dialog dependency")
    func trackDispatcherReceivesDialogDependency() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let probe = SagaDialogProbe()
            let fixture = await makeFixture(dialogPresent: { probe.check() })
            let result = await fixture.executor.run(
                step(.tracksMute, target: fixture.target, value: .bool(true))
            )

            #expect(result.state == .stateA)
            #expect(probe.callCount() == 1)
            #expect(await fixture.channel.recordedCalls().count == 1)
        }
    }

    @Test("State C mapping table is explicit and conservative")
    func stateCMappingTableIsConservative() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cases: [(String, Bool?, Bool)] = [
                ("invalid_params", nil, false),
                ("invalid_params", true, true),
                ("stale_target_reference", nil, false),
                ("element_not_found", false, false),
                ("element_not_found", nil, true),
                ("command_not_exposed", nil, false),
                ("future_error", nil, true),
            ]
            for (errorCode, writeAttempted, expectedBoundary) in cases {
                let fixture = await makeFixture(
                    failureAt: 1,
                    failureCode: errorCode,
                    failureWriteAttempted: writeAttempted
                )
                var sagaStep = step(
                    .mixerSetVolume,
                    target: fixture.target,
                    value: .double(0.75)
                )
                sagaStep = SagaStep(
                    operationID: sagaStep.operationID,
                    targetRef: sagaStep.targetRef,
                    params: sagaStep.params.merging(["token": .string("secret-token")]) { current, _ in current },
                    expectedInverse: sagaStep.expectedInverse
                )

                let result = await fixture.executor.run(sagaStep)
                #expect(result.state == .stateC, "\(errorCode)")
                #expect(result.writeBoundaryCrossed == expectedBoundary, "\(errorCode)")
                if errorCode == "future_error" {
                    #expect(result.detail.contains("error=unknown"))
                    #expect(!result.detail.contains(errorCode))
                } else {
                    #expect(result.detail.contains(errorCode), "\(errorCode)")
                }
                #expect(!result.detail.contains("secret-token"), "\(errorCode)")
            }
        }
    }

    @Test("malformed HC envelopes are treated as ambiguous failures")
    func contradictoryEnvelopeFailsConservatively() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let contradictory = await makeFixture(
                failureAt: 1,
                failureCode: "invalid_params",
                failureSuccess: true
            )
            let contradictoryResult = await contradictory.executor.run(
                step(.mixerSetVolume, target: contradictory.target, value: .double(0.75))
            )
            #expect(contradictoryResult.state == .stateC)
            #expect(contradictoryResult.writeBoundaryCrossed)
            #expect(contradictoryResult.detail.contains("malformed_hc_response"))

            let malformedEvidence = await makeFixture(
                failureAt: 1,
                failureCode: "invalid_params",
                malformedWriteAttempted: true
            )
            let malformedResult = await malformedEvidence.executor.run(
                step(.mixerSetVolume, target: malformedEvidence.target, value: .double(0.75))
            )
            #expect(malformedResult.state == .stateC)
            #expect(malformedResult.writeBoundaryCrossed)
            #expect(malformedResult.detail.contains("malformed_hc_response"))
        }
    }

    @Test("invalid params and stale target fail before dispatcher write")
    func dispatcherPreWriteFailuresRemainBoundaryFalse() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let invalidFixture = await makeFixture()
            let invalidStep = SagaStep(
                operationID: .tracksRename,
                targetRef: invalidFixture.target,
                params: [:],
                expectedInverse: SagaExpectedInverse(
                    operationID: .tracksRename,
                    valueParameter: "name"
                )
            )
            let invalid = await invalidFixture.executor.run(invalidStep)
            #expect(invalid.state == .stateC)
            #expect(!invalid.writeBoundaryCrossed)
            #expect(invalid.detail.contains("invalid_params"))
            #expect(await invalidFixture.channel.recordedCalls().isEmpty)

            let staleFixture = await makeFixture()
            await staleFixture.registry.bumpTopologyGeneration()
            let staleStep = step(
                .tracksMute,
                target: staleFixture.target,
                value: .bool(true)
            )
            let stale = await staleFixture.executor.run(staleStep)
            #expect(stale.state == .stateC)
            #expect(!stale.writeBoundaryCrossed)
            #expect(stale.detail.contains("stale_target_reference"))
            #expect(await staleFixture.executor.readState(staleStep) == nil)
            #expect(await staleFixture.channel.recordedCalls().isEmpty)
        }
    }

    @Test("before-state capture is all-or-nothing")
    func captureBeforeStateReturnsEmptyWhenAnyStepCannotBeRead() async {
        let tracks = [
            TrackState(id: 0, name: "Bass", type: .audio, volume: 0.25),
            TrackState(id: 1, name: "Keys", type: .softwareInstrument, pan: -0.25),
        ]
        let cache = StateCache()
        await cache.updateTracks(tracks)
        let surface = SagaLiveTrackSurface(tracks)
        let registry = TargetRegistry()
        let staleDescriptor = TargetDescriptor(trackIndex: 1, trackName: "Keys")
        let stale = await registry.bind(
            kind: .track,
            descriptor: staleDescriptor,
            fingerprint: staleDescriptor.fingerprint
        )
        await registry.bumpTopologyGeneration()
        let validDescriptor = TargetDescriptor(trackIndex: 0, trackName: "Bass")
        let valid = await registry.bind(
            kind: .track,
            descriptor: validDescriptor,
            fingerprint: validDescriptor.fingerprint
        )
        let channel = SagaRecordingChannel(cache: cache, surface: surface)
        let router = ChannelRouter()
        await router.register(channel)
        let executor = ProductionSagaStepExecutor(
            router: router,
            cache: cache,
            targetRegistry: registry,
            dialogPresent: { false },
            liveReadback: surface.readback
        )

        let validPlan = SagaPlan(
            steps: [
                step(.tracksRename, target: valid, value: .string("Lead")),
                step(.mixerSetVolume, target: valid, value: .double(0.75)),
            ],
            idempotencyKey: "capture-valid"
        )
        let captured = await executor.captureBeforeState(plan: validPlan)
        #expect(captured.count == 2)
        #expect(captured[0]?.value == .string("Bass"))
        #expect(captured[1]?.value == .double(0.25))

        let invalidPlan = SagaPlan(
            steps: validPlan.steps + [
                step(.mixerSetPan, target: stale, value: .double(0.5)),
            ],
            idempotencyKey: "capture-stale"
        )
        #expect(await executor.captureBeforeState(plan: invalidPlan).isEmpty)
    }

    /// LPMCP-PRD-004 (the debt itself). The cache is a poller mirror; it can be
    /// stale by a poll interval. Pre-fix, `readState` read it — so a saga whose
    /// mirror still said 0.25 while the operator had already moved the fader to
    /// 0.80 would capture 0.25 as the before-state and, on rollback, "restore"
    /// a value the operator never had. That is a rollback that is itself a
    /// destructive mutation. The before-state must come from the live surface.
    @Test("stale cache never sources the before-state a rollback restores")
    func staleCacheNeverSourcesBeforeState() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = await makeFixture()
            // Live truth diverges from the mirror: the operator moved the
            // fader out-of-band and the poller has not caught up.
            fixture.surface.update(0) { $0.volume = 0.80 }
            #expect(await fixture.cache.getTracks().first?.volume == 0.25)

            let before = await fixture.executor.readState(
                step(.mixerSetVolume, target: fixture.target, value: .double(0.5))
            )
            #expect(before?.value == .double(0.80))
            #expect(before?.value != .double(0.25))
            #expect(before?.read?.provenance == .liveIndependent)
            #expect(before?.read?.readSource == .axTrackHeaderFader)

            // And end-to-end: the compensation restores the LIVE 0.80, not the
            // cached 0.25.
            let plan = SagaPlan(
                steps: [
                    step(.mixerSetVolume, target: fixture.target, value: .double(0.5)),
                    step(.tracksRename, target: fixture.target, value: .string("Nope")),
                ],
                idempotencyKey: "stale-cache-before-state"
            )
            let outcome = await MutationSaga(
                targetRegistry: fixture.registry,
                enabled: true,
                routeAvailable: { _ in true }
            ).execute(plan, executor: RenameFailingExecutor(base: fixture.executor))

            #expect(outcome.journal[0].beforeState?.value == .double(0.80))
            #expect(outcome.journal[0].compensationEvidence?.disposition == .verified)
            #expect(fixture.surface.snapshot(0)?.volume == 0.80)
        }
    }

    /// LPMCP-PRD-004: saga evidence must name a live, independent read — and
    /// must never claim the cache. `state_cache` appearing anywhere in a saga
    /// journal is the bug this debt closed.
    @Test("saga evidence is live-provenanced and never cache-provenanced")
    func sagaEvidenceIsLiveProvenanced() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = await makeFixture()
            let observed = try #require(await fixture.executor.readState(
                step(.mixerSetVolume, target: fixture.target, value: .double(0.5))
            ))
            #expect(observed.evidence == "ax_live tracks[0].volume (header_fader)")
            #expect(!observed.evidence.contains("state_cache"))

            let read = try #require(observed.read)
            #expect(read.provenance.rawValue == "live_independent")
            #expect(read.readSource.rawValue == "ax_track_header_fader")
            #expect(read.trackIndex == 0)
            #expect(read.field == "volume")
            #expect(read.observed == .double(0.25))
            #expect(!read.sampledAt.isEmpty)
        }
    }

    /// The live seam is the ONLY source: with the seam unavailable there is no
    /// cache fallback to quietly answer from, even though the cache is
    /// populated and the binding resolves.
    @Test("unreadable live surface fails closed instead of falling back to cache")
    func unreadableLiveSurfaceFailsClosed() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = await makeFixture()
            let blindExecutor = ProductionSagaStepExecutor(
                router: ChannelRouter(),
                cache: fixture.cache,
                targetRegistry: fixture.registry,
                dialogPresent: { false },
                liveReadback: .unavailable
            )
            #expect(await fixture.cache.getTracks().first?.volume == 0.25)
            #expect(await blindExecutor.readState(
                step(.mixerSetVolume, target: fixture.target, value: .double(0.5))
            ) == nil)
        }
    }

    @Test("engine compensates every applied prefix in reverse")
    func mutationSagaFailurePositionMatrix() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            for failureAt in 1...3 {
                let tracks = [
                    TrackState(id: 0, name: "Lead", type: .audio),
                    TrackState(id: 1, name: "Pad", type: .softwareInstrument, volume: 0.2),
                    TrackState(id: 2, name: "FX", type: .audio, pan: 0),
                ]
                let cache = StateCache()
                await cache.updateTracks(tracks)
                let surface = SagaLiveTrackSurface(tracks)
                let registry = TargetRegistry()
                var targets: [TargetReference] = []
                for track in await cache.getTracks() {
                    let descriptor = TargetDescriptor(trackIndex: track.id, trackName: track.name)
                    targets.append(await registry.bind(
                        kind: .track,
                        descriptor: descriptor,
                        fingerprint: descriptor.fingerprint
                    ))
                }
                let channel = SagaRecordingChannel(
                    cache: cache,
                    surface: surface,
                    failureAt: failureAt
                )
                let router = ChannelRouter()
                await router.register(channel)
                let executor = ProductionSagaStepExecutor(
                    router: router,
                    cache: cache,
                    targetRegistry: registry,
                    dialogPresent: { false },
                    liveReadback: surface.readback
                )
                let plan = SagaPlan(
                    steps: [
                        step(.tracksRename, target: targets[0], value: .string("Lead Vox")),
                        step(.mixerSetVolume, target: targets[1], value: .double(0.9)),
                        step(.mixerSetPan, target: targets[2], value: .double(-0.5)),
                    ],
                    idempotencyKey: "production-failure-\(failureAt)"
                )

                let outcome = await MutationSaga(targetRegistry: registry, enabled: true, routeAvailable: { _ in true })
                    .execute(plan, executor: executor)
                let operations = await channel.recordedCalls().map(\.operation)
                let expectedOperations: [String]
                if failureAt == 1 {
                    #expect(outcome.state == .partiallyApplied)
                    expectedOperations = ["track.rename"]
                } else if failureAt == 2 {
                    #expect(outcome.state == .fullyCompensated)
                    expectedOperations = ["track.rename", "mixer.set_volume", "track.rename"]
                } else {
                    #expect(outcome.state == .fullyCompensated)
                    expectedOperations = [
                        "track.rename",
                        "mixer.set_volume",
                        "mixer.set_pan",
                        "mixer.set_volume",
                        "track.rename",
                    ]
                }
                #expect(operations == expectedOperations, "failure position \(failureAt)")

                // Assert on the LIVE surface: it, not the cache mirror, is what
                // the operator's Logic actually holds after compensation.
                #expect(surface.snapshot(0)?.name == "Lead", "failure position \(failureAt)")
                #expect(surface.snapshot(1)?.volume == 0.2, "failure position \(failureAt)")
                #expect(surface.snapshot(2)?.pan == 0, "failure position \(failureAt)")
                for index in 0..<failureAt - 1 {
                    #expect(
                        outcome.journal[index].compensationEvidence?.disposition == .verified,
                        "failure position \(failureAt), journal \(index)"
                    )
                }
                #expect(outcome.journal[failureAt - 1].compensationEvidence?.disposition == .notNeeded)
            }
        }
    }
}
