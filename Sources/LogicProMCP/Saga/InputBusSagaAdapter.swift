@preconcurrency import ApplicationServices
import Foundation
import MCP

/// The scalar input executor and its capture-bound, read-only matching-goal reader.
final class InputBusSagaAdapter: @unchecked Sendable {
    typealias WritePermission = @Sendable (AccessibilityChannel.HeldSelectionAssociation.Pair,
        AccessibilityChannel.OriginalHeaderSourceRenewal?, AXMixerInputSlotBinding, AXUIElement?) -> Bool
    typealias SourceRenewalObserver = @Sendable (AccessibilityChannel.OriginalHeaderSourceRenewal) async -> Bool
    @TaskLocal static var requiredInputControl: AXMixerInputSlotBinding?
    @TaskLocal static var writePermission: WritePermission?
    @TaskLocal static var heldWriteFocus: AccessibilityChannel.HeldSelectionAssociation?
    @TaskLocal static var sourceRenewalObserver: SourceRenewalObserver?
    let forward: SagaStep
    private let capture: SessionPopulationObservation.Capture?
    private let approved: ApprovedSessionRepair?
    private let matchingOnly: Bool
    private(set) var matchingReadReceipt: String?
    private var footprintProof: AccessibilityChannel.HeldSelectionAssociation?
    private var pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var readControl: AXMixerInputSlotBinding?
    private var readRenewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
    private var effect: AccessibilityChannel.ChangedInputObservation?
    private var restored: AccessibilityChannel.ChangedInputObservation?
    private var attempted = false
    private var inverseConsumed = false

    static func bus(_ value: Value?) -> Int? {
        guard let object = value?.objectValue, Set(object.keys) == ["kind", "number"],
              object["kind"] == .string("bus"), let number = object["number"]?.intValue,
              (1...256).contains(number) else { return nil }
        return number
    }

    static func accepts(_ plan: SagaPlan) -> Bool {
        guard plan.steps.count == 1, plan.canonicalPlanID == nil, plan.canonicalDigest == nil,
              let step = plan.steps.first, step.operationID == .mixerSetInputBusVerified, step.targetRef != nil,
              Set(step.params.keys).subtracting(["destination", "expected_current", "replace_existing", "project_ref"]).isEmpty,
              let before = bus(step.params["expected_current"]), let after = bus(step.params["destination"]), before != after,
              step.params["replace_existing"] == .bool(true),
              step.expectedInverse == .init(operationID: .mixerSetInputBusVerified, valueParameter: "destination") else { return false }
        if let project = step.params["project_ref"] {
            guard let value = project.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        return true
    }

    init?(plan: SagaPlan) {
        guard Self.accepts(plan), let forward = plan.steps.first else { return nil }
        self.forward = forward
        capture = nil; approved = nil; matchingOnly = false
    }

    init?(approved: ApprovedSessionRepair) {
        guard let forward = approved.plan.steps.first(where: { $0.operationID == .mixerSetInputBusVerified }),
              let (pair, control, capture) = approved.inputCustody(for: forward) else { return nil }
        self.forward = forward; self.pair = pair; readControl = control; self.capture = capture; self.approved = approved; matchingOnly = false
    }

    /// This selector is never a plan step or a setter capability.
    init?(matchingInput approved: ApprovedSessionRepair) {
        guard let (selector, pair, control, capture) = approved.matchingInputReadCustody() else { return nil }
        forward = selector; self.pair = pair; readControl = control; self.capture = capture; self.approved = approved; matchingOnly = true
    }

    func readMatchingGoal(cache: StateCache, registry: TargetRegistry) async -> ObservedState? {
        guard matchingOnly else { return nil }
        return await read(forward, cache: cache, registry: registry)
    }

    /// Observation custody from this adapter's actual owned inverse, never from a plan or wire value.
    func restoredInputForNamePresentation() -> AccessibilityChannel.ChangedInputObservation? {
        guard approved != nil, inverseConsumed, let restored, restored.creation == nil else { return nil }
        return restored
    }

    func supports(_ step: SagaStep) -> Bool {
        if step == forward { return true }
        var inverse = forward.params
        inverse["destination"] = Self.bus(forward.params["expected_current"]).map { .string("bus:\($0)") }
        return effect != nil && step.operationID == forward.operationID && step.targetRef == forward.targetRef
            && step.params == inverse && step.expectedInverse == forward.expectedInverse
    }

    static func journalValue(_ step: SagaStep) -> Value? {
        bus(step.params["destination"]).map { .string("bus:\($0)") }
    }

    private func beforeStillCurrent() -> Bool {
        guard let pair, let readControl,
              pair.track.currentIndex() != nil, pair.strip.currentIndex(runtime: pair.track.runtime) != nil,
              readRenewal.map({ $0.pair.strip.matches(pair.strip) && $0.pair.track.matches(pair.track)
                && $0.permits(runtime: pair.track.runtime) }) ?? true else { return false }
        let input = AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: pair.track.runtime.ax)
        guard case .source(let label) = input.reading, let control = input.control else { return false }
        return readControl.matches(.init(owner: pair.strip, control: control, source: label))
    }

    /// The capture is a protected baseline, never a new target lookup. Only the
    /// original header's actual owned renewal can corroborate a redrawn census.
    private func footprintHeld(_ pair: AccessibilityChannel.HeldSelectionAssociation.Pair,
        renewal: AccessibilityChannel.OriginalHeaderSourceRenewal?, assignment: InputAssignment,
        control: AXMixerInputSlotBinding,
        popup: AXUIElement? = nil) -> Bool {
        guard let capture else { return true }
        let runtime = pair.track.runtime
        guard let original = capture.freshPopulation?.selectionAssociations.first(where: { $0.track.matches(pair.track) }),
              let index = capture.channelStrips.firstIndex(where: { $0.physicalBinding?.matches(original.strip) == true }),
              assignment == Self.bus(forward.params["expected_current"]).map(InputAssignment.bus)
                || assignment == Self.bus(forward.params["destination"]).map(InputAssignment.bus),
              pair.track.matches(original.track), pair.track.currentIndex() != nil else { return false }
        let proof: AccessibilityChannel.HeldSelectionAssociation
        if let renewal {
            guard renewal.pair.strip.matches(pair.strip), renewal.pair.track.matches(pair.track),
                  renewal.permits(runtime: runtime, ownedPopup: popup) else { return false }
            proof = renewal.observation
        } else if popup != nil {
            guard let held = footprintProof else { return false }
            proof = held
        } else {
            guard pair.strip.matches(original.strip),
                  let held = AccessibilityChannel.HeldSelectionAssociation(window: pair.track.window,
                    logic: runtime, expectedProject: nil, requiresProjectReference: false,
                    allowsSelectedChildRailEntry: true) else { return false }
            proof = held
        }
        guard CFEqual(proof.window, pair.track.window), CFEqual(proof.window, pair.strip.window),
              CFEqual(proof.mixer, pair.strip.mixer),
              proof.document.utf8.elementsEqual(pair.track.document.utf8),
              proof.document.utf8.elementsEqual(pair.strip.document.utf8),
              CFEqual(proof.headers[proof.originalIndex], pair.track.header),
              proof.strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1 else { return false }
        @Sendable func permitted() -> Bool {
            (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                && (popup.map { proof.permitsOwnedPopupRead($0) } ?? proof.permitsRead())
        }
        guard permitted(), proof.headers.count == capture.tracks.count,
              zip(proof.headers, capture.tracks).allSatisfy({ header, row in
                  row.physicalBinding.map { CFEqual($0.header, header) && $0.exposure?.hasEnded != true } == true
              }) else { return false }
        let stop: @Sendable () -> Bool = { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil }
        let fields = AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: { !permitted() })) {
            let tracks = AccessibilityChannel.soloPresentationSafeTrackStates(
                AccessibilityChannel.readTrackStates(from: proof.headers, in: pair.track.window,
                    runtime: runtime, readingTypeHelp: false, stoppingWhen: stop).states)
            let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: pair.strip.mixer, runtime: runtime.ax)
                .flatMap { AccessibilityChannel.readChannelStrips(from: $0.strips, runtime: runtime,
                    window: pair.strip.window, mixer: pair.strip.mixer, readingScalarHelp: false, stoppingWhen: stop) }
            return (tracks, strips)
        }
        guard let tracks = fields.0, let strips = fields.1, permitted(),
              tracks.count == capture.tracks.count, strips.count == capture.channelStrips.count,
              strips.indices.contains(index), strips[index].physicalBinding?.matches(pair.strip) == true,
              strips[index].inputSlotBinding?.matches(control) == true,
              strips[index].input?.utf8.elementsEqual(control.source.utf8) == true,
              zip(tracks, capture.tracks).allSatisfy({ row, old in
                  guard let owner = old.physicalBinding, let current = row.physicalBinding else { return false }
                  return CFEqual(current.header, owner.header) && CFEqual(current.window, owner.window)
                      && current.document.utf8.elementsEqual(owner.document.utf8) && owner.exposure?.hasEnded != true
              }) else { return false }
        for row in strips.indices {
            guard strips[row].volumeReadback != nil, strips[row].panReadback != nil,
                  strips[row].volumeReadback == capture.channelStrips[row].volumeReadback,
                  strips[row].panReadback == capture.channelStrips[row].panReadback,
                  strips[row].pluginsFullyObserved == true else { return false }
            if let renewal {
                guard renewal.observation.strips.count == strips.count,
                      strips[row].physicalBinding?.matches(.init(window: pair.strip.window, mixer: pair.strip.mixer,
                        strip: renewal.observation.strips[row], document: pair.strip.document)) == true else { return false }
            } else {
                guard let owner = capture.channelStrips[row].physicalBinding,
                      strips[row].physicalBinding?.matches(owner) == true else { return false }
            }
        }
        var expected = capture.channelStrips
        var expectedTracks = capture.tracks
        if let name = approved?.inputNameEffect(at: pair) {
            guard let trackIndex = expectedTracks.firstIndex(where: { $0.physicalBinding?.matches(pair.track) == true }) else { return false }
            expectedTracks[trackIndex].name = name.trackName
            expected[index].name = name.stripName
        }
        expected[index].input = strips[index].input
        expected[index].inputObservation = strips[index].inputObservation
        if matchingOnly, let output = approved?.verifiedMatchingInputOutput(at: pair) {
            guard strips[index].output.flatMap(OutputAssignment.observed(slotLabel:)) == output else { return false }
            expected[index].output = strips[index].output
            expected[index].outputObservation = strips[index].outputObservation
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let input = AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: { !permitted() })) {
            AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax)
        }
        guard let a = try? encoder.encode(expectedTracks), let b = try? encoder.encode(tracks), a == b,
              let c = try? encoder.encode(expected), let d = try? encoder.encode(strips), c == d,
              case .source(let label) = input.reading, let currentControl = input.control,
              control.matches(.init(owner: pair.strip, control: currentControl, source: label)),
              permitted(), pair.strip.currentIndex(runtime: runtime) == index,
              case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(pair.strip.window, runtime: runtime),
              document.utf8.elementsEqual(pair.strip.document.utf8) else { return false }
        footprintProof = proof
        return true
    }

    private func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        let parent = OperationTraceContext.current
        let limit = ContinuousClock.now.advanced(by: .seconds(
            OperationRegistry.spec(tool: "logic_mixer", command: "set_input_bus_verified")!.deadline.seconds))
        let child = OperationTraceContext(parentTraceID: parent?.traceID,
            mutationGateAcquired: parent?.mutationGateAcquired ?? false, ownsGate: { parent?.ownsGate() ?? false },
            deadline: min(parent?.deadline ?? limit, limit),
            cancellationRequested: { Task.isCancelled || parent?.cancellationRequested() == true })
        return await OperationTraceContext.$current.withValue(child) { await body() }
    }

    func read(_ step: SagaStep, cache: StateCache, registry: TargetRegistry) async -> ObservedState? {
        await scope {
            guard FeatureFlags.adr002TargetRef, self.supports(step),
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.input_bus") == nil else { return nil }
            if self.matchingOnly, let renewal = self.approved?.verifiedMatchingInputOutputRenewal() {
                guard let prior = self.pair, let priorControl = self.readControl,
                      renewal.originalTrack.matches(prior.track), renewal.pair.track.matches(prior.track),
                      renewal.original.matches(prior.strip) || renewal.pair.strip.matches(prior.strip) else { return nil }
                let input = AXHelpers.HelpReadGuard.$current.withValue(
                    .init(allowHelpReads: true, stop: { !renewal.observation.permitsRead() })) {
                        AXLogicProElements.inputSlotRead(in: renewal.pair.strip.strip, runtime: prior.track.runtime.ax)
                    }
                guard case .source(let label) = input.reading, let current = input.control,
                      label.utf8.elementsEqual(priorControl.source.utf8),
                      renewal.permits(runtime: prior.track.runtime) else { return nil }
                let control = AXMixerInputSlotBinding(owner: renewal.pair.strip, control: current, source: label)
                // A surviving source does not authorize replacing its input control.
                guard !renewal.pair.strip.matches(prior.strip) || priorControl.matches(control) else { return nil }
                self.pair = renewal.pair; self.readControl = control; self.readRenewal = renewal
            }
            let held: AccessibilityChannel.HeldSelectionAssociation.Pair
            let proof = self.restored ?? self.effect
            if let proof {
                guard !self.inverseConsumed || self.restored != nil,
                      let reading = proof.retainedCheckedRead(), case .bus(let actual)? = reading.assignment,
                      self.footprintHeld(proof.current, renewal: proof.renewal, assignment: .bus(actual), control: proof.control),
                      await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                        operation: "saga.input_bus") == nil else { return nil }
                return .init(read: .init(readSource: .axInputMenuCheckmark, provenance: .liveIndependent,
                    trackIndex: proof.current.track.currentIndex(), field: "input_bus", observed: .string("bus:\(actual)"),
                    sampledAt: proof.sampledAt))
            } else if let captured = self.pair {
                guard !self.attempted, self.beforeStillCurrent() else { return nil }
                held = captured
            } else {
                guard !self.attempted, let reference = self.forward.targetRef,
                      let binding = await registry.resolve(reference) else { return nil }
                let captured: AccessibilityChannel.HeldSelectionAssociation.Pair
                if binding.kind == .mixerStrip, let physical = binding.physicalMixerStrip,
                   let candidate = await cache.retainedMixerAssociation(reference: reference, source: physical,
                    snapshot: await registry.currentSnapshot) {
                    // An initially stale physical reference is never adopted or rebound.
                    guard physical.currentIndex(runtime: candidate.track.runtime) != nil else { return nil }
                    captured = candidate
                } else if binding.kind == .track, let track = binding.physicalTrack,
                          let candidate = await cache.retainedTrackMixerAssociation(reference: reference, track: track,
                            snapshot: await registry.currentSnapshot), track.currentIndex() != nil {
                    captured = candidate
                } else { return nil }
                if captured.strip.currentIndex(runtime: captured.track.runtime) == nil {
                    // A Track intent addresses this exact original header, not the retired mix_ ref.
                    let renewal = await AccessibilityChannel.renewSourceThroughOriginalHeader(captured,
                        original: captured.strip, runtime: captured.track.runtime)
                    guard let source = renewal.source, source.permits(runtime: captured.track.runtime) else {
                        Log.info("Input Saga source renewal unavailable: restoration=\(renewal.effects.restoration),reason=\(renewal.effects.reason ?? "none")", subsystem: "saga")
                        return nil
                    }
                    held = source.pair; self.readRenewal = source
                } else { held = captured }
            }
            let originalFocusProof: AccessibilityChannel.HeldSelectionAssociation?
            if self.matchingOnly {
                guard let control = self.readControl, let before = Self.bus(self.forward.params["expected_current"]),
                      self.footprintHeld(held, renewal: self.readRenewal, assignment: .bus(before), control: control)
                else { return nil }
                originalFocusProof = self.footprintProof
            } else { originalFocusProof = nil }
            let reading = await AXMixerStripBinding.$current.withValue(held.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(held) {
                    await AccessibilityChannel.getInputBusObservation(runtime: held.track.runtime,
                        requiringOriginalInputControl: self.capture == nil ? nil : self.readControl)
                }
            }
            let current = reading.inputRenewal?.pair ?? held
            if let approved = self.approved, approved.hasMatchingNameGoals || self.matchingOnly, let source = reading.inputRenewal,
               !(await approved.renewNameAfterInput(source)) { return nil }
            let receipt = decodedJSONObject(reading.result.message)
            if self.matchingOnly { self.matchingReadReceipt = reading.result.message }
            guard reading.result.isSuccess, let receipt,
                  receipt["state"] as? String == "A", receipt["popup_menu_state"] as? String == "closed",
                  !self.matchingOnly || receipt["focus_restoration"] as? String == "restored" || {
                      guard let originalFocusProof, let renewal = reading.inputRenewal else { return false }
                      return renewal.restoresOriginalFocus(of: originalFocusProof, source: held.strip,
                          runtime: held.track.runtime)
                  }(),
                  case .bus(let actual)? = reading.assignment,
                  actual == Self.bus(self.forward.params["expected_current"]),
                  let control = reading.inputSlot, control.owner.matches(current.strip),
                  current.track.matches(held.track), current.track.currentIndex() != nil,
                  current.strip.currentIndex(runtime: held.track.runtime) != nil,
                  reading.inputRenewal.map({ $0.original.matches(held.strip) && $0.originalTrack.matches(held.track)
                    && $0.permits(runtime: held.track.runtime) }) ?? current.strip.matches(held.strip),
                  await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                    operation: "saga.input_bus") == nil else {
                // Only existing bounded status fields, never project/target data.
                let effects = receipt?["ui_effects"] as? [String: Any]
                let status = ["state", "error", "hint", "popup_menu_state", "focus_restoration", "source_custody_after_cleanup"]
                    .map { "\($0)=\(receipt?[$0].map(String.init(describing:)) ?? "unavailable")" }.joined(separator: ",")
                Log.info("Input Saga before-state unavailable: \(status),restoration=\(effects?["restoration"] as? String ?? "unavailable"),reason=\(effects?["reason"] as? String ?? "none")", subsystem: "saga")
                return nil
            }
            self.pair = current; self.readControl = control
            self.readRenewal = reading.inputRenewal ?? self.readRenewal
            guard self.footprintHeld(current, renewal: self.readRenewal, assignment: .bus(actual), control: control) else { return nil }
            return .init(read: .init(readSource: .axInputMenuCheckmark, provenance: .liveIndependent,
                trackIndex: current.track.currentIndex(), field: "input_bus",
                observed: .string("bus:\(actual)"),
                sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date())))
        }
    }

    func run(_ step: SagaStep, router: ChannelRouter, cache: StateCache, registry: TargetRegistry) async -> StepResult {
        guard !matchingOnly else {
            return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Matching input custody is read-only")
        }
        let permission: WritePermission?
        if capture == nil { permission = nil }
        else { permission = { [self] pair, renewal, control, popup in
            guard let held = effect?.current ?? self.pair,
                  pair.track.matches(held.track), control.owner.matches(pair.strip) else { return false }
            if !pair.strip.matches(held.strip) {
                guard let renewal, renewal.original.matches(held.strip),
                      renewal.originalTrack.matches(held.track), renewal.pair.strip.matches(pair.strip) else { return false }
            } else {
                guard let original = effect?.control ?? readControl, control.matches(original) else { return false }
            }
            let assignment = effect.map { InputAssignment.bus($0.after) }
                ?? Self.bus(forward.params["expected_current"]).map(InputAssignment.bus)
            guard let assignment else { return false }
            return footprintHeld(pair, renewal: renewal ?? effect?.renewal ?? readRenewal,
                assignment: assignment, control: control, popup: popup)
                && (approved?.inputNameHeld(at: pair) ?? true)
        } }
        let onRenewal: SourceRenewalObserver?
        if let approved, approved.hasMatchingNameGoals {
            onRenewal = { source in await approved.renewNameAfterInput(source) }
        } else { onRenewal = nil }
        return await Self.$sourceRenewalObserver.withValue(onRenewal) {
            await Self.$requiredInputControl.withValue(capture == nil ? nil : readControl) {
                await Self.$writePermission.withValue(permission) {
                    await Self.$heldWriteFocus.withValue(capture == nil ? nil : footprintProof) {
                        await runWithCustody(step, router: router, cache: cache, registry: registry)
                    }
                }
            }
        }
    }

    private func runWithCustody(_ step: SagaStep, router: ChannelRouter, cache: StateCache, registry: TargetRegistry) async -> StepResult {
        await scope {
            guard self.supports(step), FeatureFlags.adr002TargetRef,
                  (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else {
                return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Native input custody unavailable")
            }
            let response: CallTool.Result
            if let effect = self.effect {
                guard !self.inverseConsumed, case .bus(let originalBus) = effect.before, effect.creation == nil, effect.permits(),
                      await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                        operation: "saga.input_bus") == nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Owned changed input is no longer current")
                }
                self.inverseConsumed = true
                let result = await AXMixerStripBinding.$current.withValue(effect.current.strip) {
                    await AXMixerStripBinding.$outputAssociation.withValue(effect.current) {
                        await AccessibilityChannel.$inputChangeObserver.withValue({ proof in
                            if proof.original.strip.matches(effect.current.strip), proof.original.track.matches(effect.current.track),
                               proof.before == .bus(effect.after), proof.after == originalBus, proof.sink == effect.sink {
                                self.restored = proof
                            }
                        }) {
                            await AccessibilityChannel.setInputBusVerified(params: ["destination": "bus:\(originalBus)",
                                "expected_current": "bus:\(effect.after)", "replace_existing": "true"],
                                runtime: effect.current.track.runtime, ownedInverse: effect)
                        }
                    }
                }
                response = toolTextResult(result)
            } else {
                guard !self.attempted, self.beforeStillCurrent(), let held = self.pair,
                      self.approved?.inputNameHeld(at: held) ?? true,
                      await TargetRefResolver.validateProjectReference(self.forward.params, targetRegistry: registry,
                        operation: "saga.input_bus") == nil else {
                    return .init(state: .stateC, writeBoundaryCrossed: false, detail: "Before input source changed")
                }
                self.attempted = true
                let upstream = AccessibilityChannel.inputChangeObserver
                let traceID = await MixerDispatcher.startTraceIfEnabled(command: "set_input_bus_verified")
                response = await AccessibilityChannel.$inputChangeObserver.withValue({ proof in
                    if proof.original.strip.matches(held.strip), proof.original.track.matches(held.track),
                       proof.before == Self.bus(self.forward.params["expected_current"]).map(InputAssignment.bus),
                       proof.creation == nil, proof.after == Self.bus(self.forward.params["destination"]) {
                        self.effect = proof; upstream?(proof)
                    }
                }) {
                    let result = await MixerDispatcher.withWriteBoundaryArmed(traceID) {
                        await AXMixerStripBinding.$current.withValue(held.strip) {
                            await AXMixerStripBinding.$outputAssociation.withValue(held) {
                                await router.route(operation: "mixer.set_input_bus_verified", params: [
                                    "destination": "bus:\(Self.bus(self.forward.params["destination"])!)",
                                    "expected_current": "bus:\(Self.bus(self.forward.params["expected_current"])!)", "replace_existing": "true"])
                            }
                        }
                    }
                    return await MixerDispatcher.finalizeTrace(toolTextResult(result), traceID: traceID)
                }
            }
            if let approved = self.approved, approved.hasMatchingNameGoals,
               let current = self.inverseConsumed ? self.restored?.current : self.effect?.current,
               !approved.inputNameHeld(at: current) {
                return .init(state: .stateB, writeBoundaryCrossed: true, detail: "Owned name continuity after input is unverified")
            }
            let mapped = ProductionSagaStepExecutor.mapResponse(response, operationID: step.operationID)
            if case .text(let text, _, _) = response.content.first,
               let body = decodedJSONObject(text), let attempted = body["write_attempted"] as? Bool {
                return .init(state: mapped.state, writeBoundaryCrossed: attempted, detail: mapped.detail)
            }
            return mapped
        }
    }
}
