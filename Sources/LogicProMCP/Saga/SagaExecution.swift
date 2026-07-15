import MCP

struct ProductionSagaStepExecutor: SagaStepExecutor {
    private static let allowlist: Set<OperationID> = [
        .tracksRename,
        .mixerSetVolume,
        .mixerSetPan,
        .tracksMute,
        .tracksSolo,
        .tracksArm,
    ]

    private let router: ChannelRouter
    private let cache: StateCache
    private let targetRegistry: TargetRegistry
    private let dialogPresent: @Sendable () -> Bool
    // ADR-002 F5 — live AX track-header reader, threaded to the dispatchers so
    // saga-replayed / compensated track/mixer target_ref mutations fail closed
    // on an out-of-band reorder. nil by default (saga tests stay deterministic);
    // production construction supplies the real reader.
    private let liveTrackName: (@Sendable (Int) -> String?)?
    private let liveTrackNames: (@Sendable () -> [Int: String]?)?

    init(
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry,
        dialogPresent: @escaping @Sendable () -> Bool,
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil
    ) {
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.dialogPresent = dialogPresent
        self.liveTrackName = liveTrackName
        self.liveTrackNames = liveTrackNames
    }

    func run(_ step: SagaStep) async -> StepResult {
        guard Self.allowlist.contains(step.operationID) else {
            return StepResult(
                state: .stateC,
                writeBoundaryCrossed: false,
                detail: "operation not saga-allowlisted"
            )
        }

        if step.targetRef != nil, !FeatureFlags.adr002TargetRef {
            return StepResult(
                state: .stateC,
                writeBoundaryCrossed: false,
                detail: "\(step.operationID.rawValue): error=target_reference_resolution_unavailable"
            )
        }

        var params = step.params
        if let targetRef = step.targetRef {
            params["target_ref"] = .string(targetRef.rawValue)
        }

        let response: CallTool.Result
        switch step.operationID {
        case .tracksRename:
            response = await TrackDispatcher.handle(
                command: "rename",
                params: params,
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                dialogPresent: dialogPresent,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
        case .mixerSetVolume:
            response = await MixerDispatcher.handle(
                command: "set_volume",
                params: params,
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
        case .mixerSetPan:
            response = await MixerDispatcher.handle(
                command: "set_pan",
                params: params,
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
        case .tracksMute:
            response = await TrackDispatcher.handle(
                command: "mute",
                params: params,
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                dialogPresent: dialogPresent,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
        case .tracksSolo:
            response = await TrackDispatcher.handle(
                command: "solo",
                params: params,
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                dialogPresent: dialogPresent,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
        case .tracksArm:
            response = await TrackDispatcher.handle(
                command: "arm",
                params: params,
                router: router,
                cache: cache,
                targetRegistry: targetRegistry,
                dialogPresent: dialogPresent,
                liveTrackName: liveTrackName,
                liveTrackNames: liveTrackNames
            )
        default:
            return StepResult(
                state: .stateC,
                writeBoundaryCrossed: false,
                detail: "operation not saga-allowlisted"
            )
        }

        return Self.mapResponse(response, operationID: step.operationID)
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        guard Self.allowlist.contains(step.operationID),
              let targetRef = step.targetRef,
              let binding = await targetRegistry.resolve(targetRef),
              binding.kind == .track
        else {
            return nil
        }

        let tracks = await cache.getTracks()
        guard let track = tracks.first(where: { $0.id == binding.descriptor.trackIndex }),
              TargetDescriptor(trackIndex: track.id, trackName: track.name).fingerprint
                == binding.observedFingerprint
        else {
            return nil
        }

        let value: Value
        let field: String
        switch step.operationID {
        case .tracksRename:
            value = .string(track.name)
            field = "name"
        case .mixerSetVolume:
            value = .double(track.volume)
            field = "volume"
        case .mixerSetPan:
            value = .double(track.pan)
            field = "pan"
        case .tracksMute:
            value = .bool(track.isMuted)
            field = "isMuted"
        case .tracksSolo:
            value = .bool(track.isSoloed)
            field = "isSoloed"
        case .tracksArm:
            value = .bool(track.isArmed)
            field = "isArmed"
        default:
            return nil
        }
        return ObservedState(
            value: value,
            evidence: "state_cache tracks[\(track.id)].\(field)"
        )
    }

    private static func mapResponse(
        _ response: CallTool.Result,
        operationID: OperationID
    ) -> StepResult {
        guard case .text(let rawJSON, _, _) = response.content.first,
              let object = decodedJSONObject(rawJSON),
              let rawState = object["state"] as? String,
              let state = StepResultState(rawValue: rawState),
              validEnvelope(object, state: state)
        else {
            return StepResult(
                state: .stateC,
                writeBoundaryCrossed: true,
                detail: "\(operationID.rawValue): error=malformed_hc_response"
            )
        }

        switch state {
        case .stateA, .stateB:
            let verified = object["verified"] as? Bool
            return StepResult(
                state: state,
                writeBoundaryCrossed: true,
                detail: "\(operationID.rawValue): verified=\(verified.map(String.init) ?? "unknown")"
            )
        case .stateC:
            let error = object["error"] as? String
            return StepResult(
                state: .stateC,
                writeBoundaryCrossed: writeBoundaryCrossed(
                    forStateCError: error,
                    object: object
                ),
                detail: "\(operationID.rawValue): error=\(safeErrorSummary(error))"
            )
        }
    }

    private static func validEnvelope(
        _ object: [String: Any],
        state: StepResultState
    ) -> Bool {
        guard let success = object["success"] as? Bool else { return false }
        switch state {
        case .stateA:
            guard let verified = object["verified"] as? Bool else { return false }
            return success && verified
        case .stateB:
            guard let verified = object["verified"] as? Bool,
                  let reason = object["reason"] as? String else { return false }
            return success && !verified && !reason.isEmpty
        case .stateC:
            if let verified = object["verified"] as? Bool, verified { return false }
            if object["write_attempted"] != nil,
               object["write_attempted"] as? Bool == nil { return false }
            return !success && !(object["error"] as? String ?? "").isEmpty
        }
    }

    private static func writeBoundaryCrossed(
        forStateCError error: String?,
        object: [String: Any]
    ) -> Bool {
        if let writeAttempted = object["write_attempted"] as? Bool {
            return writeAttempted
        }
        return switch error {
        case HonestContract.FailureError.invalidParams.rawValue,
             HonestContract.FailureError.staleTargetReference.rawValue,
             HonestContract.FailureError.commandNotExposed.rawValue:
            false
        default:
            true
        }
    }

    private static func safeErrorSummary(_ error: String?) -> String {
        guard let error,
              HonestContract.FailureError(rawValue: error) != nil else {
            return "unknown"
        }
        return error
    }
}

extension SagaStepExecutor {
    func captureBeforeState(plan: SagaPlan) async -> [Int: ObservedState] {
        var captured: [Int: ObservedState] = [:]
        for (index, step) in plan.steps.enumerated() {
            guard let state = await readState(step) else { return [:] }
            captured[index] = state
        }
        return captured
    }
}

struct SagaBeforeStateAvailability: Sendable {
    let stepIndex: Int
    let state: ObservedState?
}

extension SagaStepExecutor {
    func captureBeforeStateAvailability(plan: SagaPlan) async -> [SagaBeforeStateAvailability] {
        let captured = await captureBeforeState(plan: plan)
        if captured.count == plan.steps.count {
            return plan.steps.indices.map {
                SagaBeforeStateAvailability(stepIndex: $0, state: captured[$0])
            }
        }
        var availability: [SagaBeforeStateAvailability] = []
        for (index, step) in plan.steps.enumerated() {
            let singleStepPlan = SagaPlan(
                steps: [step],
                idempotencyKey: "\(plan.idempotencyKey)#before-state-\(index)"
            )
            let state = await captureBeforeState(plan: singleStepPlan)[0]
            availability.append(SagaBeforeStateAvailability(stepIndex: index, state: state))
        }
        return availability
    }
}

actor SagaFirstWriteBoundary {
    private var crossed = false

    func cross(_ action: @Sendable () async -> Void) async {
        guard !crossed else { return }
        crossed = true
        await action()
    }
}

struct SagaSurfaceStepExecutor<Base: SagaStepExecutor>: SagaStepExecutor {
    private let base: Base
    private let refreshAfterWrite: @Sendable () async -> Void

    init(
        base: Base,
        refreshAfterWrite: @escaping @Sendable () async -> Void = {}
    ) {
        self.base = base
        self.refreshAfterWrite = refreshAfterWrite
    }

    func run(_ step: SagaStep) async -> StepResult {
        guard !Task.isCancelled else {
            return StepResult(
                state: .stateC,
                writeBoundaryCrossed: false,
                detail: "saga execution cancelled before step dispatch"
            )
        }
        let result = await base.run(step)
        if result.writeBoundaryCrossed {
            await refreshAfterWrite()
        }
        return result
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        await base.readState(step)
    }
}
