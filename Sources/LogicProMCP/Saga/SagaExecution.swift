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
    /// Match reference issuance's raw name bytes, refusing an unreadable or
    /// ambiguous header instead of using the legacy display-name trimming shim.
    static func productionTrackName(
        at index: Int, runtime: AXLogicProElements.Runtime = .production
    ) -> String? {
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              case .success(.some(let name)) = AXValueExtractors.extractTrackNameResult(
                from: header, runtime: runtime.ax
              ) else { return nil }
        return name
    }

    /// Production seam. Name identity preserves reference issuance's raw bytes;
    /// the scalar readers mirror the dispatchers' State-A readback primitives:
    /// - name: the status-preserving, unambiguous track-header Name reading.
    /// - volume/pan: the header fader/pan slider + the same contract mapping
    ///   `AccessibilityChannel.defaultSetMixerValue` reads back through.
    /// - toggles: the M/S/R checkbox AXValue that
    ///   `AccessibilityChannel.defaultSetTrackToggle` verifies against.
    static let production = SagaLiveReadback(
        readTrackName: { index in
            productionTrackName(at: index)
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
/// Mirrors `FaultInjectionSeam(environment:)`'s nil-unless-set contract
/// exactly: same env key, same `partial_state` mode. Only that mode engages the
/// saga — `.timeout` belongs to the transport probe and leaves the saga inert.
///
/// #399 (CEO audit P0) — compiled solely in debug via `FAULT_TEST_SEAM`
/// (see Package.swift), so the release binary carries neither this seam nor its
/// env-key strings.
#if FAULT_TEST_SEAM
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
              let injection = FaultInjectionSeam(environment: environment),
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

/// One execution's native removal custody, never persisted in the journal.
/// The journal records checked scalar facts; those facts cannot recreate this capsule.
final class SendRemovalSagaAdapter: @unchecked Sendable {
    struct RequiredBeforeState: Sendable {
        let footprint: [SendSlotObservation]
        let nonRoutingChecks: [String]
    }
    @TaskLocal static var requiredSendControl: AXLogicProElements.AssignedSendMenuControl?
    @TaskLocal static var requiredBeforeState: RequiredBeforeState?
    @TaskLocal static var requiredNameCheck: (@Sendable (AXMixerStripBinding.Binding) -> Bool)?
    // The deciding before-read already checked this native pair under this
    // operation's gate. Inspection-cache eviction cannot erase that tether.
    @TaskLocal static var checkedSourcePair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    @TaskLocal static var checkedReadRenewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
    // Receivers with actual checked inputs in this invocation supply only
    // discovery hints; post-write source custody is observed again.
    @TaskLocal static var checkedReadPeerHeaders: [AXTrackBinding.Binding]?
    let forward: SagaStep
    private let capturedControl: AXLogicProElements.AssignedSendMenuControl?
    private let approved: ApprovedSessionRepair?
    private var pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var footprint: [SendSlotObservation]?
    private var checkedBeforeNonRouting: [String]?
    private var removal: AccessibilityChannel.RemovedSendObservation?
    private var change: AccessibilityChannel.ChangedSendObservation?
    private var creation: AccessibilityChannel.CreatedSendObservation?
    private var creationRemoval: AccessibilityChannel.RemovedSendObservation?
    private var restored: AccessibilityChannel.CheckedOutputReading?
    private var attempted = false
    private var inverseConsumed = false

    static func accepts(_ plan: SagaPlan) -> Bool {
        guard plan.steps.count == 1, plan.canonicalPlanID == nil, plan.canonicalDigest == nil,
              let step = plan.steps.first, step.operationID == .mixerSetSendOutputVerified,
              step.targetRef != nil,
              Set(step.params.keys).subtracting(["ordinal", "destination", "expected_current", "replace_existing", "project_ref"]).isEmpty,
              step.params["ordinal"]?.intValue.map({ $0 >= 0 }) == true,
              isCreation(step) || (expectedBefore(step) != nil && step.params["replace_existing"] == .bool(true)),
              step.expectedInverse == .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination") else { return false }
        if let project = step.params["project_ref"] {
            guard let value = project.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }

    private static func isCreation(_ step: SagaStep) -> Bool {
        step.params["ordinal"] == .int(0)
            && step.params["destination"] == .object(["kind": .string("stereo_output")])
            && step.params["expected_current"] == .object(["kind": .string("no_send")])
            && step.params["replace_existing"] == .bool(false)
    }

    private static func changeAssignments(_ step: SagaStep) -> (before: OutputAssignment, after: OutputAssignment)? {
        guard let rawBefore = step.params["expected_current"], let rawAfter = step.params["destination"],
              let before = MixerDispatcher.outputAssignmentParam(rawBefore, field: "expected_current").assignment,
              let after = MixerDispatcher.outputAssignmentParam(rawAfter, field: "destination").assignment,
              AccessibilityChannel.supportsOccupiedSendChange(before: before, after: after) else { return nil }
        // Preserve the existing Bus wire contract; the shared physical parser also
        // accepts exact floating-point integers, which Bus admission never allowed.
        if case .bus = after, rawAfter.objectValue?["number"]?.intValue == nil { return nil }
        if case .bus = before, rawBefore.objectValue?["number"]?.intValue == nil { return nil }
        return (before, after)
    }

    private static func expectedBefore(_ step: SagaStep) -> OutputAssignment? {
        if step.params["destination"] == .object(["kind": .string("no_send")]),
           step.params["expected_current"] == .object(["kind": .string("stereo_output")]) { return .stereoOutput }
        return changeAssignments(step)?.before
    }

    init?(plan: SagaPlan) {
        guard Self.accepts(plan), let forward = plan.steps.first else { return nil }
        self.forward = forward
        self.capturedControl = nil
        self.approved = nil
    }

    init?(approved: ApprovedSessionRepair) {
        let sends = approved.plan.steps.filter { $0.operationID == .mixerSetSendOutputVerified }
        guard sends.count == 1, let forward = sends.first,
              let (pair, control) = approved.sendRemovalCustody(for: forward) else { return nil }
        self.forward = forward
        self.pair = pair
        self.capturedControl = control
        self.approved = approved
    }

    /// Only an internally constructed inverse may carry the checked scalar.
    func supports(_ step: SagaStep) -> Bool {
        if step == forward { return true }
        var inverse = forward.params
        inverse["destination"] = .string(Self.isCreation(forward) ? "no_send" : Self.expectedBefore(forward)?.token ?? "")
        return (removal != nil || change != nil || creation != nil) && step.operationID == forward.operationID
            && step.targetRef == forward.targetRef && step.params == inverse
            && step.expectedInverse == forward.expectedInverse
    }

    static func journalValue(_ step: SagaStep) -> Value? {
        if isCreation(step) { return .string("stereo_output") }
        if step.params["destination"] == .object(["kind": .string("no_send")]) { return .string("no_send") }
        return changeAssignments(step).map { .string($0.after.token) }
    }

    private func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let parent = OperationTraceContext.current
        let deadline = min(parent?.deadline ?? ContinuousClock.now.advanced(by: .seconds(25)),
            ContinuousClock.now.advanced(by: .seconds(OperationRegistry.spec(tool: "logic_mixer", command: "set_send_output_verified")!.deadline.seconds)))
        let child = OperationTraceContext(parentTraceID: parent?.traceID,
            mutationGateAcquired: parent?.mutationGateAcquired ?? false,
            ownsGate: { parent?.ownsGate() ?? false }, deadline: deadline,
            cancellationRequested: { Task.isCancelled || parent?.cancellationRequested() == true })
        return await OperationTraceContext.$current.withValue(child) { await body() }
    }

    func read(_ step: SagaStep, cache: StateCache, registry: TargetRegistry) async -> ObservedState? {
        await scope {
            guard FeatureFlags.adr002TargetRef, self.supports(step), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.send_removal") == nil else { return nil }
            let token: String
            let source: SagaReadSource
            if let created = self.creation {
                if self.inverseConsumed {
                    guard let removed = self.creationRemoval,
                          created.permitsRemoval(removed, runtime: created.source.pair.track.runtime) else { return nil }
                    token = "no_send"; source = .axSendSlotFootprint
                } else {
                    guard await AccessibilityChannel.readCreatedSendObservation(created,
                        runtime: created.source.pair.track.runtime) != nil else { return nil }
                    token = "stereo_output"; source = .axSendMenuCheckmark
                }
            } else if let restored = self.restored, let pair = self.pair,
               let original = self.removal?.source.pair.strip ?? self.change?.source.pair.strip {
                let checked = await AccessibilityChannel.readRestoredSendObservation(restored,
                    original: original, runtime: pair.track.runtime)
                guard let assignment = checked.assignment else { return nil }
                token = assignment.token; source = .axSendMenuCheckmark
            } else if let changed = self.change {
                guard !self.inverseConsumed else { return nil }
                let checked = await AccessibilityChannel.readChangedSendObservation(changed,
                    runtime: changed.source.pair.track.runtime)
                guard let assignment = checked.assignment else { return nil }
                token = assignment.token; source = .axSendMenuCheckmark
            } else if let removed = self.removal {
                guard !self.inverseConsumed, removed.permits(runtime: removed.source.pair.track.runtime) else { return nil }
                token = "no_send"; source = .axSendSlotFootprint
            } else {
                guard !self.attempted, let reference = step.targetRef,
                      let binding = await registry.resolve(reference), binding.kind == .mixerStrip,
                      let physical = binding.physicalMixerStrip else { return nil }
                let held: AccessibilityChannel.HeldSelectionAssociation.Pair
                if let captured = await cache.retainedMixerAssociation(reference: reference, source: physical,
                    snapshot: await registry.currentSnapshot) {
                    held = captured
                } else if let owned = await self.approved?.sendReadPairAfterOwnedName(reference: reference, source: physical) {
                    held = owned
                    Log.info("Send before-read continued through its owned source-name effect", subsystem: "saga")
                } else { return nil }
                guard self.pair.map({ $0.strip.matches(held.strip) && $0.track.matches(held.track) }) ?? true,
                      let ordinal = self.forward.params["ordinal"]?.intValue else { return nil }
                let runtime = held.track.runtime
                if Self.isCreation(self.forward) {
                    guard ordinal == 0, AccessibilityChannel.soleEmptySend(in: physical.strip, runtime: runtime.ax) != nil,
                          let slots = AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax),
                          slots == [.init(ordinal: 0, state: .observedEmpty)],
                          self.footprint.map({ $0 == slots }) ?? true,
                          held.track.currentIndex() != nil, physical.currentIndex(runtime: runtime) != nil,
                          (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
                    self.pair = held; self.footprint = slots
                    token = "no_send"; source = .axSendSlotFootprint
                } else {
                    if let captured = self.capturedControl {
                        guard let current = AXLogicProElements.assignedSendMenuControl(in: physical.strip,
                            ordinal: ordinal, runtime: runtime.ax), captured.matches(current) else { return nil }
                    }
                    if let approved = self.approved {
                        guard await approved.prepareSendInputPeerHeaders(at: held) else { return nil }
                    }
                    let checked = await AXMixerStripBinding.$current.withValue(physical) {
                        await AXMixerStripBinding.$outputAssociation.withValue(held) {
                            await AccessibilityChannel.getOutputObservation(runtime: runtime, sendOrdinal: ordinal)
                        }
                    }
                    guard let before = Self.expectedBefore(self.forward), checked.assignment == before,
                          self.capturedControl.map({ captured in checked.sendControl.map(captured.matches) == true }) ?? true,
                          checked.sendNonRoutingChecks == ["Post Fader"] || checked.sendNonRoutingChecks == ["포스트 페이더"],
                          let slots = AXLogicProElements.sendSlotObservations(in: physical.strip, runtime: runtime.ax),
                          slots.count == 2, slots.filter({ $0.state == .observedEmpty }).count == 1,
                          let occupied = slots.first(where: { $0.state == .occupiedUnknownDestination }),
                          occupied.ordinal == ordinal, occupied.levelRaw == 0, occupied.bypassed == false,
                          self.footprint.map({ $0 == slots }) ?? true,
                          physical.currentIndex(runtime: runtime) != nil else { return nil }
                    self.pair = held; self.footprint = slots
                    self.checkedBeforeNonRouting = checked.sendNonRoutingChecks
                    token = before.token; source = .axSendMenuCheckmark
                }
            }
            let evidence = SagaReadEvidence(readSource: source, provenance: .liveIndependent,
                trackIndex: self.pair?.track.currentIndex(), field: "send_destination",
                observed: .string(token), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
            return .init(read: evidence)
        }
    }

    func run(_ step: SagaStep, router: ChannelRouter, cache: StateCache, registry: TargetRegistry) async -> StepResult {
        await scope {
            guard FeatureFlags.adr002TargetRef, self.supports(step), var held = self.pair,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Native removal custody unavailable")
            }
            let response: CallTool.Result
            if let created = self.creation {
                guard !self.inverseConsumed, created.permits(runtime: held.track.runtime),
                      await self.read(step, cache: cache, registry: registry) != nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "The owned created Send is no longer current")
                }
                self.inverseConsumed = true
                let result = await AccessibilityChannel.removeCreatedSendObservation(created, runtime: held.track.runtime)
                self.creationRemoval = result.removedSend
                response = toolTextResult(result.result)
            } else if var changed = self.change {
                guard !self.inverseConsumed else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed send is no longer current")
                }
                if let approved = self.approved {
                    guard let custody = await approved.sendBusInputsCurrent(at: changed.source.pair,
                        control: changed.control, expected: changed.checkedAfter,
                        ownedChange: changed) else {
                        return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed Send read continuity is unavailable")
                    }
                    if custody.renewal != nil {
                        guard let continued = custody.continuedChange else {
                            return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed Send effect continuity is unavailable")
                        }
                        changed = continued; self.change = continued; self.pair = custody.pair
                    }
                }
                // Prerequisite input reads validate this actual effect on entry.
                // The restoration function checks its complete current custody
                // again before any inverse popup or action; repeating that same
                // scan here adds no intervening observation or action boundary.
                self.inverseConsumed = true
                let restored = await AccessibilityChannel.restoreChangedSendObservation(changed, runtime: held.track.runtime)
                self.restored = restored
                response = toolTextResult(restored.result)
            } else if let removed = self.removal {
                guard !self.inverseConsumed, removed.permits(runtime: held.track.runtime) else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned empty send is no longer current")
                }
                self.inverseConsumed = true
                let restored = await AccessibilityChannel.restoreRemovedSendObservation(removed, runtime: held.track.runtime)
                self.restored = restored
                response = toolTextResult(restored.result)
            } else {
                guard !self.attempted else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Send was already attempted")
                }
                let requiredBefore: RequiredBeforeState?
                if Self.isCreation(self.forward) {
                    guard await self.read(self.forward, cache: cache, registry: registry) != nil else {
                        return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Before send footprint changed")
                    }
                    requiredBefore = nil
                } else {
                    guard let footprint = self.footprint, let checks = self.checkedBeforeNonRouting else {
                        return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Independent before Send observation unavailable")
                    }
                    // Expected data from the independent Saga read, not permission.
                    // The deciding writer corroborates this tuple inside its own
                    // existing popup instead of opening and cancelling a second one.
                    requiredBefore = .init(footprint: footprint, nonRoutingChecks: checks)
                }
                let nameUsesInputFootprint = self.approved?.sendNameUsesInputFootprint == true
                if let approved = self.approved, approved.hasMatchingNameGoals {
                    let current = nameUsesInputFootprint
                        ? await approved.sendNameSourceCurrent(at: held)
                        : await approved.nameGoalEvidence(afterExecution: true) != nil
                    guard current else {
                        return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Approved name changed before Send")
                    }
                }
                var readRenewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
                var checkedPeerHeaders: [AXTrackBinding.Binding]?
                var requiredControl = self.capturedControl
                if let approved = self.approved, let control = requiredControl,
                   let expected = Self.expectedBefore(self.forward) {
                    guard let custody = await approved.sendBusInputsCurrent(at: held, control: control, expected: expected,
                        corroboratingBeforeInWriter: nameUsesInputFootprint ? requiredBefore : nil) else {
                        return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Checked Bus input prerequisites changed before Send")
                    }
                    held = custody.pair; self.pair = held
                    requiredControl = custody.control; readRenewal = custody.renewal
                    checkedPeerHeaders = custody.checkedPeerHeaders
                }
                if nameUsesInputFootprint, readRenewal == nil,
                   let approved = self.approved, await approved.nameGoalEvidence(afterExecution: true) == nil {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Approved name footprint unavailable before Send")
                }
                self.attempted = true
                let nameCheck: (@Sendable (AXMixerStripBinding.Binding) -> Bool)?
                if let approved = self.approved { nameCheck = { source in approved.sendNameHeld(at: source) } }
                else { nameCheck = nil }
                var params = self.forward.params
                params["target_ref"] = .string(self.forward.targetRef!.rawValue)
                let routedHeld = held
                let upstream = AccessibilityChannel.sendRemovalObserver
                let upstreamChange = AccessibilityChannel.sendChangeObserver
                let upstreamCreation = AccessibilityChannel.sendCreationObserver
                response = await AccessibilityChannel.$sendCreationObserver.withValue({ proof in
                    if Self.isCreation(self.forward), proof.source.original.matches(routedHeld.strip),
                       proof.source.originalTrack.matches(routedHeld.track) {
                        self.creation = proof; upstreamCreation?(proof)
                    }
                }) {
                    await AccessibilityChannel.$sendChangeObserver.withValue({ proof in
                        if proof.source.original.matches(routedHeld.strip) && proof.source.originalTrack.matches(routedHeld.track),
                           proof.checkedBefore == Self.changeAssignments(self.forward)?.before,
                           proof.checkedAfter == Self.changeAssignments(self.forward)?.after {
                            self.change = proof
                            upstreamChange?(proof)
                        }
                    }) {
                        await AccessibilityChannel.$sendRemovalObserver.withValue({ proof in
                            if proof.source.original.matches(routedHeld.strip) && proof.source.originalTrack.matches(routedHeld.track) {
                                self.removal = proof
                                upstream?(proof)
                            }
                        }) {
                            await Self.$requiredSendControl.withValue(requiredControl) {
                                await Self.$requiredNameCheck.withValue(nameCheck) {
                                    await Self.$checkedSourcePair.withValue(held) {
                                        await Self.$checkedReadRenewal.withValue(readRenewal) {
                                            await Self.$checkedReadPeerHeaders.withValue(checkedPeerHeaders) {
                                                await Self.$requiredBeforeState.withValue(requiredBefore) {
                                                    await MixerDispatcher.handle(command: "set_send_output_verified", params: params,
                                                        router: router, cache: cache, targetRegistry: registry)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if let approved = self.approved, approved.hasMatchingNameGoals,
               let source = self.inverseConsumed ? self.restored?.restoredSend?.source : self.change?.source,
               !(await approved.renewNameAfterSend(source)) {
                return .init(state: .stateB, writeBoundaryCrossed: true, detail: "Owned name continuity after Send is unverified")
            }
            let mapped = ProductionSagaStepExecutor.mapResponse(response, operationID: step.operationID)
            if case .text(let text, _, _) = response.content.first,
               let body = decodedJSONObject(text) {
                if self.approved != nil, mapped.state == .stateC, let hint = body["hint"] as? String {
                    Log.info("Canonical Send dispatch refused: \(hint)", subsystem: "saga")
                }
                if let attempted = body["write_attempted"] as? Bool {
                    return .init(state: mapped.state, writeBoundaryCrossed: attempted, detail: mapped.detail)
                }
            }
            return mapped
        }
    }
}

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
    private let approvedSessionRepair: ApprovedSessionRepair?
    private let confirmedCompressorPlan: Bool
    private let confirmedSelectedEQPlan: Bool
    private let sendRemoval: SendRemovalSagaAdapter?
    private let sendMode: SendModeSagaAdapter?
    private let sendLevel: SendLevelSagaAdapter?
    private let inputBus: InputBusSagaAdapter?
    /// ADR-004 / issue #287 — qualification-only fault seam. nil in all normal
    /// operation (env unset); non-nil ONLY when the operator explicitly set
    /// `LOGIC_PRO_MCP_FAULT_INJECT=partial_state` to qualify compensation. A
    /// test affordance, never a product code path — see SagaPartialStateFaultSeam.
    ///
    /// #399 (CEO audit P0) — the seam property, its init parameter, and the
    /// branch that consults it are compiled solely in debug via
    /// `FAULT_TEST_SEAM`. The release executor has no seam at all.
    #if FAULT_TEST_SEAM
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
        faultSeam: SagaPartialStateFaultSeam? = nil,
        approvedSessionRepair: ApprovedSessionRepair? = nil,
        confirmedCompressorPlan: Bool = false,
        confirmedSelectedEQPlan: Bool = false,
        sendRemoval: SendRemovalSagaAdapter? = nil,
        sendMode: SendModeSagaAdapter? = nil,
        sendLevel: SendLevelSagaAdapter? = nil,
        inputBus: InputBusSagaAdapter? = nil
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
        self.approvedSessionRepair = approvedSessionRepair
        self.confirmedCompressorPlan = confirmedCompressorPlan
        self.confirmedSelectedEQPlan = confirmedSelectedEQPlan
        self.sendRemoval = sendRemoval
        self.sendMode = sendMode
        self.sendLevel = sendLevel
        self.inputBus = inputBus
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
        now: @escaping @Sendable () -> Date = { Date() },
        approvedSessionRepair: ApprovedSessionRepair? = nil,
        confirmedCompressorPlan: Bool = false,
        confirmedSelectedEQPlan: Bool = false,
        sendRemoval: SendRemovalSagaAdapter? = nil,
        sendMode: SendModeSagaAdapter? = nil,
        sendLevel: SendLevelSagaAdapter? = nil,
        inputBus: InputBusSagaAdapter? = nil
    ) {
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.dialogPresent = dialogPresent
        self.liveReadback = liveReadback
        self.liveTrackName = liveTrackName
        self.liveTrackNames = liveTrackNames
        self.now = now
        self.approvedSessionRepair = approvedSessionRepair
        self.confirmedCompressorPlan = confirmedCompressorPlan
        self.confirmedSelectedEQPlan = confirmedSelectedEQPlan
        self.sendRemoval = sendRemoval
        self.sendMode = sendMode
        self.sendLevel = sendLevel
        self.inputBus = inputBus
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
        #if FAULT_TEST_SEAM
        if let faultSeam, let injected = faultSeam.injectionResult(for: step) {
            return injected
        }
        #endif
        // ADR-005: each saga step dispatch gets a NESTED trace context
        // carrying the parent saga trace ID — without it a child's trace
        // start would clobber the parent's registration in the shared box,
        // and child traces would be uncorrelated orphans.
        let parent = OperationTraceContext.current
        let parentTraceID = parent?.traceID ?? parent?.parentTraceID
        let child: OperationTraceContext
        if approvedSessionRepair == nil && sendRemoval == nil && sendMode == nil && sendLevel == nil && inputBus == nil && step.operationID != .pluginsSetParamVerified && step.operationID != .pluginsSetEQBandVerified {
            child = OperationTraceContext(parentTraceID: parentTraceID)
        }
        else {
            child = OperationTraceContext(parentTraceID: parentTraceID,
                mutationGateAcquired: parent?.mutationGateAcquired ?? false,
                ownsGate: { parent?.ownsGate() ?? false }, deadline: parent?.deadline,
                cancellationRequested: { parent?.cancellationRequested() ?? true })
        }
        return await OperationTraceContext.$current.withValue(child) {
            await runInChildTraceScope(step)
        }
    }

    private func runInChildTraceScope(_ step: SagaStep) async -> StepResult {
        if let inputBus, inputBus.supports(step) {
            return await inputBus.run(step, router: router, cache: cache, registry: targetRegistry)
        }
        if let sendLevel, sendLevel.supports(step) {
            return await sendLevel.run(step, router: router, cache: cache, registry: targetRegistry)
        }
        if let sendMode, sendMode.supports(step) {
            return await sendMode.run(step, router: router, cache: cache, registry: targetRegistry)
        }
        if let sendRemoval, sendRemoval.supports(step) {
            return await sendRemoval.run(step, router: router, cache: cache, registry: targetRegistry)
        }
        guard Self.allowlist.contains(step.operationID) || approvedSessionRepair?.supports(step) == true
            || (step.operationID == .pluginsSetParamVerified && confirmedCompressorPlan)
            || (step.operationID == .pluginsSetEQBandVerified && confirmedSelectedEQPlan) else {
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
        if let targetRef = step.targetRef, approvedSessionRepair?.supports(step) != true {
            params["target_ref"] = .string(targetRef.rawValue)
        }

        let response: CallTool.Result
        switch step.operationID {
        case .pluginsSetEQBandVerified:
            guard confirmedSelectedEQPlan,
                  let (binding, project) = await SelectedEQParameterSaga.binding(step, registry: targetRegistry),
                  let parameter = step.params["parameter"]?.stringValue,
                  let metadata = ChannelEQBandCatalog.parameter(bandName: "Peak 1", parameterName: parameter),
                  let before = step.params["expected_before"], let path = project.projectFilePath,
                  let insert = binding.pluginInsertIndex,
                  (try? SelectedEQParameterSaga.canonicalParams(step.params, inverse: true)) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Selected EQ binding/before-state unavailable")
            }
            params.removeValue(forKey: "expected_before"); params.removeValue(forKey: "recommendation")
            params["mode"] = .string("duplicate_applyback"); params["project_expected_path"] = .string(path)
            let expected = PluginSagaExpectedBefore(track: binding.descriptor.trackIndex, insert: insert,
                projectPath: path, param: metadata.id, observed: before, pluginID: SelectedEQParameterSaga.pluginID)
            let writeParams = params
            response = await PluginSagaExpectedBefore.$current.withValue(expected) {
                await CompressorParameterSaga.bounded(command: "set_eq_band_verified") {
                    await PluginsDispatcher.handle(command: "set_eq_band_verified", params: writeParams,
                        router: router, cache: cache, targetRegistry: targetRegistry)
                }
            }
        case .pluginsSetParamVerified:
            guard confirmedCompressorPlan,
                  let (binding, project) = await CompressorParameterSaga.binding(step, registry: targetRegistry),
                  let param = step.params["param"]?.stringValue,
                  let before = step.params["expected_before"], let path = project.projectFilePath,
                  let insert = binding.pluginInsertIndex,
                  (try? CompressorParameterSaga.canonicalParams(step.params)) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Compressor binding/before-state unavailable")
            }
            params.removeValue(forKey: "expected_before")
            if case .bool(let value) = params["value"] { params["value"] = .double(value ? 1 : 0) }
            params["plugin"] = .string(CompressorParameterSaga.pluginID)
            params["mode"] = .string("duplicate_applyback")
            params["project_expected_path"] = .string(path)
            let expected = PluginSagaExpectedBefore(track: binding.descriptor.trackIndex, insert: insert,
                projectPath: path, param: param, observed: before)
            let writeParams = params
            response = await PluginSagaExpectedBefore.$current.withValue(expected) {
                await CompressorParameterSaga.bounded(command: "set_param_verified") {
                    await PluginsDispatcher.handle(command: "set_param_verified", params: writeParams,
                        router: router, cache: cache, targetRegistry: targetRegistry)
                }
            }
        case .navigateToggleView where approvedSessionRepair?.supports(step) == true:
            response = await ApprovedSessionRepair.$current.withValue(approvedSessionRepair) {
                await NavigateDispatcher.handle(command: "toggle_view", params: params, router: router, cache: cache)
            }
        case .tracksRename where approvedSessionRepair?.supports(step) == true:
            response = await approvedSessionRepair!.performName(step, router: router,
                restoredInput: inputBus?.restoredInputForNamePresentation())
        case .tracksSortVerified where approvedSessionRepair?.supports(step) == true:
            response = await approvedSessionRepair!.performSort(step, router: router)
        case .mixerSetOutputVerified where approvedSessionRepair?.supports(step) == true:
            let traceID = await MixerDispatcher.startTraceIfEnabled(command: "set_output_verified")
            let output = await approvedSessionRepair!.performOutput(step, router: router)
            response = await MixerDispatcher.finalizeTrace(output, traceID: traceID)
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

        let mapped = Self.mapResponse(response, operationID: step.operationID)
        if approvedSessionRepair?.supports(step) == true || step.operationID == .pluginsSetParamVerified,
           case .text(let text, _, _) = response.content.first,
           let body = decodedJSONObject(text), let attempted = body["write_attempted"] as? Bool {
            var detail = mapped.detail
            if step.operationID == .tracksRename, approvedSessionRepair?.supports(step) == true,
               let effects = body["track_selection_effects"] as? [String: Any],
               let restoration = effects["restoration"] as? String {
                detail += "; track_selection_restoration=\(restoration)"
            }
            return .init(state: mapped.state, writeBoundaryCrossed: attempted, detail: detail)
        }
        return mapped
    }

    /// LPMCP-PRD-004: every value returned here is an INDEPENDENT live AX read.
    /// There is deliberately no cache fallback — a surface we cannot read
    /// returns nil, which the engine treats as `unknown` (fail-closed), rather
    /// than a mirror value that could be stale by a poll interval.
    func readState(_ step: SagaStep) async -> ObservedState? {
        if let inputBus, inputBus.supports(step) {
            return await inputBus.read(step, cache: cache, registry: targetRegistry)
        }
        if let sendLevel, sendLevel.supports(step) {
            return await sendLevel.read(step, cache: cache, registry: targetRegistry)
        }
        if let sendMode, sendMode.supports(step) {
            return await sendMode.read(step, cache: cache, registry: targetRegistry)
        }
        if let sendRemoval, sendRemoval.supports(step) {
            return await sendRemoval.read(step, cache: cache, registry: targetRegistry)
        }
        if step.operationID == .pluginsSetEQBandVerified {
            return await SelectedEQParameterSaga.read(step, router: router, cache: cache,
                registry: targetRegistry, now: now())
        }
        if step.operationID == .pluginsSetParamVerified {
            return await CompressorParameterSaga.read(step, router: router, cache: cache,
                registry: targetRegistry, now: now())
        }
        if let approvedSessionRepair, approvedSessionRepair.supports(step) {
            return await approvedSessionRepair.readState(step)
        }
        guard Self.allowlist.contains(step.operationID),
              let targetRef = step.targetRef,
              let binding = await targetRegistry.resolve(targetRef),
              binding.kind == .track
        else {
            return nil
        }

        let index = binding.descriptor.trackIndex
        guard binding.physicalTrack.map({ $0.currentIndex() == index }) ?? true else { return nil }
        // Per-step identity fingerprint gate, unchanged in shape but now
        // LIVE-sourced: the cache name it used to compare could agree with the
        // binding while the live track at `index` was a different track after
        // an out-of-band reorder — the gate would pass and the saga would read
        // (and later restore) the wrong track. The production reader preserves
        // raw Name bytes and refuses an unreadable or ambiguous header. Swift's
        // canonical String equality must not join byte-distinct identities.
        guard let liveName = await liveReadback.readTrackName(index),
              TargetDescriptor(trackIndex: index, trackName: liveName).fingerprint
                .utf8.elementsEqual(binding.observedFingerprint.utf8)
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

        guard binding.physicalTrack.map({ $0.currentIndex() == index }) ?? true else { return nil }
        return ObservedState(read: SagaReadEvidence(
            readSource: readSource,
            provenance: .liveIndependent,
            trackIndex: index,
            field: field,
            observed: value,
            sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: now())
        ))
    }

    static func mapResponse(
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
            if step.operationID == .pluginsSetParamVerified,
               !CompressorParameterSaga.beforeMatches(state, step) { return [:] }
            if step.operationID == .pluginsSetEQBandVerified,
               !SelectedEQParameterSaga.beforeMatches(state, step) { return [:] }
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
                idempotencyKey: "\(plan.idempotencyKey)#before-state-\(index)",
                canonicalPlanID: plan.canonicalPlanID, canonicalDigest: plan.canonicalDigest
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
