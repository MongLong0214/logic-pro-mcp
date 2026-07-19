import ApplicationServices
import Foundation
import MCP

/// The track-header toggle a saga step addresses.
enum SagaToggleField: String, Sendable {
    case mute
    case solo
    case arm
}

/// LPMCP-PRD-004 — independent LIVE read seams for saga decisions.
///
/// The saga used to source its before-state, verification readback, and
/// compensation proof from `StateCache`. The cache is a poller-refreshed
/// MIRROR: it can be stale by a poll interval, and it is refreshed by the very
/// write the saga is trying to judge. A stale mirror means the saga can capture
/// the WRONG before-state and then "restore" a value the operator never had —
/// a rollback that is itself a mutation.
///
/// Every reader here calls the SAME AX primitive the corresponding dispatcher
/// uses for its State-A verification, and every one returns `nil` rather than a
/// fabricated default when the surface is unreadable — an unreadable fader must
/// become `unknown`, never `0.0`.
struct SagaLiveReadback: Sendable {
    let readTrackName: @Sendable (Int) async -> String?
    let readTrackVolume: @Sendable (Int) async -> Double?
    let readTrackPan: @Sendable (Int) async -> Double?
    let readTrackToggle: @Sendable (Int, SagaToggleField) async -> Bool?

    /// Fail-closed seam: every read is unavailable, so every saga decision
    /// resolves to `unknown` and every plan rejects at before-state capture.
    /// A construction site that forgets the real reader loses the saga — it
    /// does NOT silently fall back to a cache value.
    static let unavailable = SagaLiveReadback(
        readTrackName: { _ in nil },
        readTrackVolume: { _ in nil },
        readTrackPan: { _ in nil },
        readTrackToggle: { _, _ in nil }
    )
}

extension SagaLiveReadback {
    /// Production seam. Each reader mirrors a dispatcher's State-A verification
    /// primitive exactly:
    /// - name: `AXLogicProElements.trackName(at:)` — the same live-identity-gated
    ///   read the ADR-002 F5 mutation-boundary check uses.
    /// - volume/pan: the header fader/pan slider + the same contract mapping
    ///   `AccessibilityChannel.defaultSetMixerValue` reads back through.
    /// - toggles: the M/S/R checkbox AXValue that
    ///   `AccessibilityChannel.defaultSetTrackToggle` verifies against.
    static let production = SagaLiveReadback(
        readTrackName: { index in
            AXLogicProElements.trackName(at: index)
        },
        readTrackVolume: { index in
            guard let fader = AXLogicProElements.findTrackHeaderVolumeFader(at: index) else {
                return nil
            }
            return AXValueExtractors.extractLogicMixerFaderValue(fader)
        },
        readTrackPan: { index in
            guard let slider = AXLogicProElements.findTrackHeaderPanControl(at: index),
                  let range = AXValueExtractors.extractSliderRange(slider),
                  range.max > range.min else {
                return nil
            }
            return AXValueExtractors.headerPanContract(slider, range: range)
        },
        readTrackToggle: { index, field in
            let button: AXUIElement? = switch field {
            case .mute: AXLogicProElements.findTrackMuteButton(trackIndex: index)
            case .solo: AXLogicProElements.findTrackSoloButton(trackIndex: index)
            case .arm: AXLogicProElements.findTrackArmButton(trackIndex: index)
            }
            guard let button else { return nil }
            return AXValueExtractors.extractButtonState(button)
        }
    )
}

/// ADR-004 / issue #287 — a QUALIFICATION-ONLY saga fault seam.
///
/// This is a test affordance, NOT a product feature. It is a completely dead
/// branch unless `LOGIC_PRO_MCP_FAULT_INJECT=partial_state` is explicitly set:
/// `resolve(environment:stepCount:)` returns nil in every other case, so the
/// executor holds no seam and `run` takes its normal path unchanged.
///
/// When engaged it fails EXACTLY ONE forward saga step BEFORE that step's real
/// write — the returned StepResult is State C with `writeBoundaryCrossed=false`,
/// and no dispatch happens, so the injected step mutates nothing. Earlier steps
/// really apply, so the saga's own `compensate()` runs REAL reverse-order
/// compensation over them: exercising that path is the whole reason this seam
/// exists. It NEVER touches `readState`, so the before-state a rollback restores
/// stays truthful.
///
/// Mirrors `QualificationFaultInjection(environment:)`'s nil-unless-set contract
/// exactly: same env key, same `partial_state` mode. Only that mode engages the
/// saga — `.timeout` belongs to the transport probe and leaves the saga inert.
///
/// #399 (CEO audit P0) — compiled solely in debug via `QUALIFICATION_FAULT_SEAM`
/// (see Package.swift), so the release binary carries neither this seam nor its
/// env-key strings.
#if QUALIFICATION_FAULT_SEAM
final class SagaPartialStateFaultSeam: @unchecked Sendable {
    /// Optional operator override pinning WHICH forward step fails. Zero-based;
    /// an absent, unparseable, or out-of-range value falls back to the LAST
    /// step so the affordance stays predictable.
    static let stepEnvironmentKey = "LOGIC_PRO_MCP_FAULT_INJECT_STEP"

    private let injectedStepIndex: Int
    private let lock = NSLock()
    private var forwardCursor = 0

    private init(injectedStepIndex: Int) {
        self.injectedStepIndex = injectedStepIndex
    }

    /// Returns nil unless `LOGIC_PRO_MCP_FAULT_INJECT=partial_state` is set —
    /// the dead-branch guard. `stepCount` (the plan's step count, known only at
    /// construction) resolves the default LAST target.
    static func resolve(
        environment: [String: String],
        stepCount: Int
    ) -> SagaPartialStateFaultSeam? {
        guard stepCount > 0,
              let injection = QualificationFaultInjection(environment: environment),
              injection.mode == .partialState else {
            return nil
        }
        let injectedStepIndex: Int
        if let raw = environment[stepEnvironmentKey]?.trimmingCharacters(in: .whitespaces),
           let parsed = Int(raw),
           parsed >= 0,
           parsed < stepCount {
            injectedStepIndex = parsed
        } else {
            injectedStepIndex = stepCount - 1
        }
        return SagaPartialStateFaultSeam(injectedStepIndex: injectedStepIndex)
    }

    /// Advances the run cursor and, iff this run is the injected step, returns a
    /// State-C result that short-circuits the executor BEFORE the real write.
    /// Monotonic and single-shot by construction: the cursor only equals
    /// `injectedStepIndex` on the intended forward step; every later run —
    /// including the compensation inverses — sees a higher cursor and returns
    /// nil, so real compensation dispatches for real.
    func injectionResult(for step: SagaStep) -> StepResult? {
        lock.lock()
        let cursor = forwardCursor
        forwardCursor += 1
        lock.unlock()
        guard cursor == injectedStepIndex else { return nil }
        return StepResult(
            state: .stateC,
            writeBoundaryCrossed: false,
            detail: "\(step.operationID.rawValue): error=qualification_fault_injected_partial_state"
        )
    }
}
#endif

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
    // LPMCP-PRD-004: the cache is threaded to the DISPATCHERS (the write path's
    // own resolution and the resource mirror they refresh) — it is never read
    // for a saga decision. `readState` uses `liveReadback` only.
    private let cache: StateCache
    private let targetRegistry: TargetRegistry
    private let dialogPresent: @Sendable () -> Bool
    /// LPMCP-PRD-004 — live AX reads for saga before-state / verification /
    /// compensation proof. Explicit and non-optional: a saga that cannot read
    /// the live surface must fail closed loudly, so callers name their seam
    /// (`.production`, `.unavailable`, or a fake) at the construction site.
    private let liveReadback: SagaLiveReadback
    // ADR-002 F5 — live AX track-header reader, threaded to the dispatchers so
    // saga-replayed / compensated track/mixer target_ref mutations fail closed
    // on an out-of-band reorder. nil by default (saga tests stay deterministic);
    // production construction supplies the real reader.
    private let liveTrackName: (@Sendable (Int) -> String?)?
    private let liveTrackNames: (@Sendable () -> [Int: String]?)?
    /// Evidence timestamp source. Injectable so evidence assertions stay
    /// deterministic; `sampled_at` is provenance metadata and never an input to
    /// a saga decision.
    private let now: @Sendable () -> Date
    /// ADR-004 / issue #287 — qualification-only fault seam. nil in all normal
    /// operation (env unset); non-nil ONLY when the operator explicitly set
    /// `LOGIC_PRO_MCP_FAULT_INJECT=partial_state` to qualify compensation. A
    /// test affordance, never a product code path — see SagaPartialStateFaultSeam.
    ///
    /// #399 (CEO audit P0) — the seam property, its init parameter, and the
    /// branch that consults it are compiled solely in debug via
    /// `QUALIFICATION_FAULT_SEAM`. The release executor has no seam at all.
    #if QUALIFICATION_FAULT_SEAM
    private let faultSeam: SagaPartialStateFaultSeam?

    init(
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry,
        dialogPresent: @escaping @Sendable () -> Bool,
        liveReadback: SagaLiveReadback,
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        faultSeam: SagaPartialStateFaultSeam? = nil
    ) {
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.dialogPresent = dialogPresent
        self.liveReadback = liveReadback
        self.liveTrackName = liveTrackName
        self.liveTrackNames = liveTrackNames
        self.now = now
        self.faultSeam = faultSeam
    }
    #else
    init(
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry,
        dialogPresent: @escaping @Sendable () -> Bool,
        liveReadback: SagaLiveReadback,
        liveTrackName: (@Sendable (Int) -> String?)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.dialogPresent = dialogPresent
        self.liveReadback = liveReadback
        self.liveTrackName = liveTrackName
        self.liveTrackNames = liveTrackNames
        self.now = now
    }
    #endif

    func run(_ step: SagaStep) async -> StepResult {
        // ADR-004 / issue #287 — QUALIFICATION-ONLY fault seam. Completely dead
        // unless `LOGIC_PRO_MCP_FAULT_INJECT=partial_state` was set at
        // construction (faultSeam is nil otherwise, so this whole branch is
        // skipped and the path below is byte-for-byte today's behaviour). When
        // engaged for the injected step it returns State C BEFORE any dispatch —
        // no trace scope, no write, no mutation — so earlier steps' real
        // compensation can be exercised. Never a product code path.
        #if QUALIFICATION_FAULT_SEAM
        if let faultSeam, let injected = faultSeam.injectionResult(for: step) {
            return injected
        }
        #endif
        // ADR-005: each saga step dispatch gets a NESTED trace context
        // carrying the parent saga trace ID — without it a child's trace
        // start would clobber the parent's registration in the shared box,
        // and child traces would be uncorrelated orphans.
        let parentTraceID = OperationTraceContext.current?.traceID
        return await OperationTraceContext.$current.withValue(
            OperationTraceContext(parentTraceID: parentTraceID)
        ) {
            await runInChildTraceScope(step)
        }
    }

    private func runInChildTraceScope(_ step: SagaStep) async -> StepResult {
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

    /// LPMCP-PRD-004: every value returned here is an INDEPENDENT live AX read.
    /// There is deliberately no cache fallback — a surface we cannot read
    /// returns nil, which the engine treats as `unknown` (fail-closed), rather
    /// than a mirror value that could be stale by a poll interval.
    func readState(_ step: SagaStep) async -> ObservedState? {
        guard Self.allowlist.contains(step.operationID),
              let targetRef = step.targetRef,
              let binding = await targetRegistry.resolve(targetRef),
              binding.kind == .track
        else {
            return nil
        }

        let index = binding.descriptor.trackIndex
        // Per-step identity fingerprint gate, unchanged in shape but now
        // LIVE-sourced: the cache name it used to compare could agree with the
        // binding while the live track at `index` was a different track after
        // an out-of-band reorder — the gate would pass and the saga would read
        // (and later restore) the wrong track. `trackName(at:)` is itself
        // live-identity-gated and returns nil for an unreadable header.
        guard let liveName = await liveReadback.readTrackName(index),
              TargetDescriptor(trackIndex: index, trackName: liveName).fingerprint
                == binding.observedFingerprint
        else {
            return nil
        }

        let value: Value
        let field: String
        let readSource: SagaReadSource
        switch step.operationID {
        case .tracksRename:
            value = .string(liveName)
            field = "name"
            readSource = .axTrackName
        case .mixerSetVolume:
            guard let volume = await liveReadback.readTrackVolume(index) else { return nil }
            value = .double(volume)
            field = "volume"
            readSource = .axTrackHeaderFader
        case .mixerSetPan:
            guard let pan = await liveReadback.readTrackPan(index) else { return nil }
            value = .double(pan)
            field = "pan"
            readSource = .axTrackHeaderPan
        case .tracksMute:
            guard let muted = await liveReadback.readTrackToggle(index, .mute) else { return nil }
            value = .bool(muted)
            field = "isMuted"
            readSource = .axTrackToggle
        case .tracksSolo:
            guard let soloed = await liveReadback.readTrackToggle(index, .solo) else { return nil }
            value = .bool(soloed)
            field = "isSoloed"
            readSource = .axTrackToggle
        case .tracksArm:
            guard let armed = await liveReadback.readTrackToggle(index, .arm) else { return nil }
            value = .bool(armed)
            field = "isArmed"
            readSource = .axTrackToggle
        default:
            return nil
        }

        return ObservedState(read: SagaReadEvidence(
            readSource: readSource,
            provenance: .liveIndependent,
            trackIndex: index,
            field: field,
            observed: value,
            sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: now())
        ))
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
