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

    // MARK: - ADR-004 / issue #287 qualification-only partial-state fault seam
    //
    // #399 (CEO audit P0) — the partial-state fault seam is a debug-only test
    // affordance compiled solely under `QUALIFICATION_FAULT_SEAM` (see
    // Package.swift). Everything below references the excluded
    // `SagaPartialStateFaultSeam` and/or the `faultSeam:` executor initializer, so
    // it compiles/runs only in the debug test build and is absent from a
    // `-c release` test build.
    #if QUALIFICATION_FAULT_SEAM

    private struct SeamFixture: Sendable {
        let executor: ProductionSagaStepExecutor
        let channel: SagaRecordingChannel
        let surface: SagaLiveTrackSurface
        let registry: TargetRegistry
        let targets: [TargetReference]
    }

    /// Builds a one-step-per-track saga environment, optionally arming the
    /// qualification fault seam. `faultSeam` is nil in the control (env unset)
    /// case, so the executor is byte-for-byte the production one.
    private func makeSeamFixture(
        tracks: [TrackState],
        faultSeam: SagaPartialStateFaultSeam? = nil
    ) async -> SeamFixture {
        let cache = StateCache()
        await cache.updateTracks(tracks)
        let surface = SagaLiveTrackSurface(tracks)
        let registry = TargetRegistry()
        var targets: [TargetReference] = []
        for track in tracks {
            let descriptor = TargetDescriptor(trackIndex: track.id, trackName: track.name)
            targets.append(await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            ))
        }
        let channel = SagaRecordingChannel(cache: cache, surface: surface)
        let router = ChannelRouter()
        await router.register(channel)
        return SeamFixture(
            executor: ProductionSagaStepExecutor(
                router: router,
                cache: cache,
                targetRegistry: registry,
                dialogPresent: { false },
                liveReadback: surface.readback,
                faultSeam: faultSeam
            ),
            channel: channel,
            surface: surface,
            registry: registry,
            targets: targets
        )
    }

    private func twoStepTracks() -> [TrackState] {
        [
            TrackState(id: 0, name: "Bass", type: .audio, volume: 0.25),
            TrackState(id: 1, name: "Keys", type: .softwareInstrument),
        ]
    }

    /// TEST (c): the seam is a completely dead branch unless the fault env is
    /// explicitly `partial_state`. Resolution — the ONLY place a seam is
    /// constructed — returns nil for an unset env, for the transport-only
    /// `timeout` mode, and for an empty plan; it constructs a seam only for
    /// `partial_state` with a non-empty plan.
    @Test("fault seam resolves nil unless partial_state env is explicitly set")
    func faultSeamResolvesNilUnlessPartialStateEnvSet() async {
        #expect(SagaPartialStateFaultSeam.resolve(environment: [:], stepCount: 2) == nil)
        #expect(SagaPartialStateFaultSeam.resolve(
            environment: ["UNRELATED": "partial_state"],
            stepCount: 2
        ) == nil)
        // `timeout` is the transport probe's mode; it must leave the saga inert.
        #expect(SagaPartialStateFaultSeam.resolve(
            environment: ["LOGIC_PRO_MCP_FAULT_INJECT": "timeout"],
            stepCount: 2
        ) == nil)
        #expect(SagaPartialStateFaultSeam.resolve(
            environment: ["LOGIC_PRO_MCP_FAULT_INJECT": "partial_state"],
            stepCount: 0
        ) == nil)
        #expect(SagaPartialStateFaultSeam.resolve(
            environment: ["LOGIC_PRO_MCP_FAULT_INJECT": "partial_state"],
            stepCount: 2
        ) != nil)
    }

    /// TEST (c): even when armed the seam yields a State-C result for EXACTLY
    /// one run — the targeted forward step — and nil for every run before and
    /// after it, so the compensation inverses (which run after) dispatch for
    /// real. This is what keeps the seam inert on every non-target run.
    @Test("armed seam injects exactly once at the target forward run")
    func faultSeamInjectsExactlyOnceAtTargetForwardRun() async throws {
        let probeStep = SagaStep(
            operationID: .mixerSetVolume,
            targetRef: nil,
            params: [:],
            expectedInverse: SagaExpectedInverse(
                operationID: .mixerSetVolume,
                valueParameter: "value"
            )
        )

        // Default target is the LAST step (index 1 of a 2-step plan).
        let lastSeam = try #require(SagaPartialStateFaultSeam.resolve(
            environment: ["LOGIC_PRO_MCP_FAULT_INJECT": "partial_state"],
            stepCount: 2
        ))
        #expect(lastSeam.injectionResult(for: probeStep) == nil) // cursor 0 ≠ 1
        let injected = try #require(lastSeam.injectionResult(for: probeStep)) // cursor 1
        #expect(injected.state == .stateC)
        #expect(!injected.writeBoundaryCrossed)
        #expect(injected.detail.contains("qualification_fault_injected_partial_state"))
        #expect(lastSeam.injectionResult(for: probeStep) == nil) // cursor 2 (a compensation run)
        #expect(lastSeam.injectionResult(for: probeStep) == nil) // cursor 3

        // Explicit override pins the FIRST step (index 0).
        let firstSeam = try #require(SagaPartialStateFaultSeam.resolve(
            environment: [
                "LOGIC_PRO_MCP_FAULT_INJECT": "partial_state",
                "LOGIC_PRO_MCP_FAULT_INJECT_STEP": "0",
            ],
            stepCount: 3
        ))
        #expect(try #require(firstSeam.injectionResult(for: probeStep)).state == .stateC) // cursor 0
        #expect(firstSeam.injectionResult(for: probeStep) == nil) // cursor 1

        // An out-of-range override falls back to the LAST step.
        let clampedSeam = try #require(SagaPartialStateFaultSeam.resolve(
            environment: [
                "LOGIC_PRO_MCP_FAULT_INJECT": "partial_state",
                "LOGIC_PRO_MCP_FAULT_INJECT_STEP": "99",
            ],
            stepCount: 2
        ))
        #expect(clampedSeam.injectionResult(for: probeStep) == nil) // cursor 0 ≠ 1
        #expect(try #require(clampedSeam.injectionResult(for: probeStep)).state == .stateC) // cursor 1
    }

    /// TEST (a): with the seam absent (env unset) the exact same 2-step plan
    /// completes normally — both steps apply, nothing compensates. This is the
    /// control the injected run in the next test is measured against.
    @Test("seam-absent plan completes normally and applies both steps")
    func faultSeamAbsentCompletesTwoStepPlanNormally() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = await makeSeamFixture(tracks: twoStepTracks())
            let plan = SagaPlan(
                steps: [
                    step(.mixerSetVolume, target: fixture.targets[0], value: .double(0.75)),
                    step(.tracksRename, target: fixture.targets[1], value: .string("Lead")),
                ],
                idempotencyKey: "seam-absent-control"
            )

            let outcome = await MutationSaga(
                targetRegistry: fixture.registry,
                enabled: true,
                routeAvailable: { _ in true }
            ).execute(plan, executor: fixture.executor)

            #expect(outcome.state == .completed)
            #expect(outcome.complete)
            let appliedVolume = try #require(outcome.journal[0].executionResult)
            #expect(appliedVolume.state == .stateA)
            let appliedRename = try #require(outcome.journal[1].executionResult)
            #expect(appliedRename.state == .stateA)
            #expect(await fixture.channel.recordedCalls().map(\.operation)
                == ["mixer.set_volume", "track.rename"])
            #expect(fixture.surface.snapshot(0)?.volume == 0.75)
            #expect(fixture.surface.snapshot(1)?.name == "Lead")
        }
    }

    /// TEST (b): with `partial_state` armed on the SAME 2-step plan, the first
    /// step really applies, the last (injected) step returns State C BEFORE its
    /// write (no dispatch, no mutation), and the saga's own compensate() runs a
    /// real inverse over the applied first step — restoring the live surface and
    /// recording CompensationEvidence for it.
    @Test("partial_state fault drives real compensation of the applied prefix")
    func partialStateFaultDrivesRealCompensationOnTwoStepPlan() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let seam = SagaPartialStateFaultSeam.resolve(
                environment: ["LOGIC_PRO_MCP_FAULT_INJECT": "partial_state"],
                stepCount: 2
            )
            let fixture = await makeSeamFixture(tracks: twoStepTracks(), faultSeam: seam)
            let plan = SagaPlan(
                steps: [
                    step(.mixerSetVolume, target: fixture.targets[0], value: .double(0.75)),
                    step(.tracksRename, target: fixture.targets[1], value: .string("Lead")),
                ],
                idempotencyKey: "partial-state-two-step"
            )

            let outcome = await MutationSaga(
                targetRegistry: fixture.registry,
                enabled: true,
                routeAvailable: { _ in true }
            ).execute(plan, executor: fixture.executor)

            // The applied first step, then its inverse — the injected rename
            // NEVER reached the channel (no "track.rename" forward call).
            #expect(await fixture.channel.recordedCalls().map(\.operation)
                == ["mixer.set_volume", "mixer.set_volume"])

            #expect(outcome.state == .fullyCompensated)
            let applied = try #require(outcome.journal[0].executionResult)
            #expect(applied.state == .stateA)
            #expect(outcome.journal[0].verificationEvidence?.disposition == .applied)
            #expect(outcome.journal[0].compensationEvidence?.disposition == .verified)

            let injected = try #require(outcome.journal[1].executionResult)
            #expect(injected.state == .stateC)
            #expect(!injected.writeBoundaryCrossed)
            #expect(injected.detail.contains("qualification_fault_injected_partial_state"))
            #expect(outcome.journal[1].verificationEvidence?.disposition == .notApplied)
            #expect(outcome.journal[1].compensationEvidence?.disposition == .notNeeded)

            // Live surface: volume rolled back, the injected rename never landed.
            #expect(fixture.surface.snapshot(0)?.volume == 0.25)
            #expect(fixture.surface.snapshot(1)?.name == "Keys")
        }
    }

    /// TEST (b), reverse-order rigor: a 3-step plan with two applied steps proves
    /// compensation dispatches the inverses in REVERSE order and that the
    /// injected last step never dispatched (no "mixer.set_pan" anywhere).
    @Test("partial_state fault compensates the applied prefix in reverse order")
    func partialStateFaultCompensatesAppliedPrefixInReverse() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let tracks = [
                TrackState(id: 0, name: "Lead", type: .audio),
                TrackState(id: 1, name: "Pad", type: .softwareInstrument, volume: 0.2),
                TrackState(id: 2, name: "FX", type: .audio, pan: 0),
            ]
            let seam = SagaPartialStateFaultSeam.resolve(
                environment: ["LOGIC_PRO_MCP_FAULT_INJECT": "partial_state"],
                stepCount: 3
            )
            let fixture = await makeSeamFixture(tracks: tracks, faultSeam: seam)
            let plan = SagaPlan(
                steps: [
                    step(.tracksRename, target: fixture.targets[0], value: .string("Lead Vox")),
                    step(.mixerSetVolume, target: fixture.targets[1], value: .double(0.9)),
                    step(.mixerSetPan, target: fixture.targets[2], value: .double(-0.5)),
                ],
                idempotencyKey: "partial-state-three-step"
            )

            let outcome = await MutationSaga(
                targetRegistry: fixture.registry,
                enabled: true,
                routeAvailable: { _ in true }
            ).execute(plan, executor: fixture.executor)

            // Forward rename + volume, then inverses in REVERSE order (volume
            // before rename). The injected pan step is absent from the channel.
            #expect(await fixture.channel.recordedCalls().map(\.operation) == [
                "track.rename",
                "mixer.set_volume",
                "mixer.set_volume",
                "track.rename",
            ])

            #expect(outcome.state == .fullyCompensated)
            #expect(outcome.journal[0].compensationEvidence?.disposition == .verified)
            #expect(outcome.journal[1].compensationEvidence?.disposition == .verified)
            #expect(outcome.journal[2].compensationEvidence?.disposition == .notNeeded)
            let injected = try #require(outcome.journal[2].executionResult)
            #expect(injected.state == .stateC)
            #expect(!injected.writeBoundaryCrossed)

            // Live surface fully restored; the injected pan never landed.
            #expect(fixture.surface.snapshot(0)?.name == "Lead")
            #expect(fixture.surface.snapshot(1)?.volume == 0.2)
            #expect(fixture.surface.snapshot(2)?.pan == 0)
        }
    }
    #endif
}
