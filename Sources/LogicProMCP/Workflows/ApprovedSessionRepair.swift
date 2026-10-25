@preconcurrency import ApplicationServices
import CryptoKit
import Foundation
import MCP

/// The native counterpart of retained canonical goals, including zero-write receiver KEEP. It is not a wire
/// token: only the retained capture supplies its process-local AX custody.
final class ApprovedSessionRepair: @unchecked Sendable {
    struct ApplyRequest: Sendable {
        let planID: String
        let digest: String
        let key: String

        private init(planID: String, digest: String, key: String) {
            self.planID = planID; self.digest = digest; self.key = key
        }

        static func parse(_ params: [String: Value]) -> ApplyRequest? {
            guard Set(params.keys) == ["plan_id", "digest", "confirmed", "idempotency_key"],
                  case .bool(true)? = params["confirmed"],
                  let id = params["plan_id"]?.stringValue, !id.isEmpty,
                  let digest = params["digest"]?.stringValue, digest.utf8.count == 64,
                  let key = try? SagaWire.idempotencyKey(from: ["idempotency_key": params["idempotency_key"] ?? .null]) else { return nil }
            return .init(planID: id, digest: digest, key: key)
        }

        static func refusal() -> CallTool.Result {
            toolInvalidParamsResult("apply_session_repair requires the exact retained plan_id and digest, confirmed:true, and an idempotency_key", extras: ["write_attempted": false])
        }
    }

    @TaskLocal static var current: ApprovedSessionRepair?
    @TaskLocal static var outputLeafPermission: (@Sendable (AXUIElement) -> Bool)?
    private struct MixerTask: Sendable {
        let before: Bool
        let desired: Bool
        let binding: SessionPopulationObservation.PresentationBinding
    }
    private struct NameGoal: Sendable {
        let reference: TargetReference
        let mixerRef: TargetReference?
        let before: String
        let name: String
        let binding: AXTrackBinding.Binding
    }
    private struct SortTask: Sendable {
        let policy: ProjectSessionAudit.IntentSort
        let before: [String]
        let rows: [TrackState]
        let binding: SessionPopulationObservation.PresentationBinding
        let snapshot: TargetRegistrySnapshot
    }
    private struct OutputTask: Sendable {
        let reference: TargetReference
        let mixerRef: TargetReference
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let before: OutputAssignment
        let desired: OutputAssignment
        let capture: SessionPopulationObservation.Capture
        let handle: String

        var prerequisiteBuses: [Int] {
            var numbers: [Int] = []
            for assignment in [before, desired] {
                if case .bus(let number) = assignment, !numbers.contains(number) { numbers.append(number) }
            }
            return numbers
        }
    }
    private struct SendTask: Sendable {
        let reference: TargetReference
        let mixerRef: TargetReference
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let control: AXLogicProElements.AssignedSendMenuControl
        let ordinal: Int
        let before: OutputAssignment
        let desired: OutputAssignment?
        let footprint: [SendSlotObservation]
        let capture: SessionPopulationObservation.Capture
        let goalID: String
        let handle: String
    }
    private struct InputTask: Sendable {
        let reference: TargetReference
        let mixerRef: TargetReference
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let control: AXMixerInputSlotBinding
        let before: Int
        let desired: Int
        let sink: OutputAssignment
        let capture: SessionPopulationObservation.Capture
        let handle: String
    }

    /// Name protection observes the input's checked sink; this adds no output goal or writer.
    private var nameFootprintTask: OutputTask? {
        if let outputTask { return outputTask }
        guard let input = inputTask, !changedNameGoals.isEmpty else { return nil }
        return .init(reference: input.reference, mixerRef: input.mixerRef, pair: input.pair,
            before: input.sink, desired: input.sink, capture: input.capture, handle: input.handle)
    }
    private struct ReceiverKeep: Sendable {
        let bus: Int
        let reference: TargetReference
        let input: AXMixerInputSlotBinding
        let label: AXMixerTypeLabelBinding
        let presentation: SessionPopulationObservation.PresentationBinding
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    }
    private struct ReceiverRenewal: Sendable {
        let source: AccessibilityChannel.OriginalHeaderSourceRenewal
        let input: AXMixerInputSlotBinding
        let label: AXMixerTypeLabelBinding
    }
    private struct CapturedGoals: Sendable {
        let projectRef: TargetReference
        let document: String
        let mixer: MixerTask?
        let names: [NameGoal]
        let renameCapture: SessionPopulationObservation.Capture?
        var selectionOrigin: AXTrackBinding.Binding? = nil
        var sort: SortTask? = nil
        var output: OutputTask? = nil
        var send: SendTask? = nil
        var input: InputTask? = nil
        var receivers: [ReceiverKeep] = []
    }

    /// One singleton Bus goal on an independently checked local sink.
    /// Retain the actual control; an equal label on a replacement is not this task.
    private static func capturedInput(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> InputTask? {
        guard FeatureFlags.adr002TargetRef, FeatureFlags.adr004MutationSaga,
              names.count <= 1, policy.targets.count == 1, policy.inputs.count == 1,
              policy.outputs.count <= 1, policy.sends.isEmpty, policy.roles.isEmpty,
              policy.receivers.isEmpty, policy.protectedPaths.isEmpty,
              policy.trackSort == nil, policy.mixerVisible == nil,
              let target = policy.targets.first, target.mixerRef == nil,
              names.allSatisfy({ $0.target == target.handle }),
              let input = policy.inputs.first, input.target == target.handle,
              OutputAssignment.busNumbers.contains(input.bus), request.allowUINavigation,
              Set([SessionPopulationObservation.Domain.tracks, .strips, .associations, .routing]).isSubset(of: request.domains),
              source.before == source.after, source.referencesEnabled, !source.referencesStale,
              source.requestedProjectMatches != false, !source.before.axOccluded,
              case .issued(let project)? = source.projectIssuance, policy.projectRef == project,
              let fresh = source.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
              let refs = source.issued, case .located(let index) = ProjectSessionAudit.locate(target.trackRef, in: refs),
              source.tracks.allSatisfy({ $0.selectionReadback != nil }),
              source.tracks.filter({ $0.selectionReadback == true }).count == 1 else { return nil }
        let rows = source.tracks.filter { $0.id == index }
        guard rows.count == 1, let row = rows.first, row.selectionReadback == true,
              let track = row.physicalBinding, track.exposure?.hasEnded != true,
              let path = source.project.filePath, track.projectPath?.utf8.elementsEqual(path.utf8) == true else { return nil }
        let pairs = fresh.selectionAssociations.filter { $0.track.matches(track) }
        guard pairs.count == 1, let pair = pairs.first,
              fresh.selectionAssociations.filter({ $0.strip.matches(pair.strip) }).count == 1,
              CFEqual(pair.track.window, pair.strip.window),
              pair.track.document.utf8.elementsEqual(pair.strip.document.utf8) else { return nil }
        let strips = source.channelStrips.indices.filter { source.channelStrips[$0].physicalBinding?.matches(pair.strip) == true }
        let checked = fresh.checkedInputs.filter { $0.receiver.matches(pair.strip) }
        let outputs = fresh.checkedOutputs.filter { $0.source.matches(pair.strip) && $0.sendOrdinal == nil }
        guard strips.count == 1, let stripIndex = strips.first, let mixerRef = source.mixerReference(at: stripIndex),
              checked.count == 1, case .bus(let before)? = checked.first?.assignment,
              OutputAssignment.busNumbers.contains(before),
              let control = source.channelStrips[stripIndex].inputSlotBinding, control.owner.matches(pair.strip),
              outputs.count == 1, let sink = outputs.first?.assignment, localAssignmentForBefore(sink) != nil,
              source.channelStrips.allSatisfy({ strip in
                  guard let owner = strip.physicalBinding, strip.name != nil, strip.nameReadError == nil,
                        strip.volumeReadback != nil, strip.panReadback != nil,
                        strip.pluginsSource == "ax", strip.pluginsReadError == nil, strip.pluginsFullyObserved == true,
                        let observedInput = strip.inputObservation, observedInput.state != .unreadable,
                        let sends = strip.sendSlots else { return false }
                  // Only a zero-write matching goal may preserve an occupied peer.
                  // Raw display/level/bypass observations are a protected baseline,
                  // never a Send destination, routing edge or writer capability.
                  let matchingReadOnlyPeer = before == input.bus && policy.outputs.isEmpty
                      && names.allSatisfy({ $0.name.utf8.elementsEqual(row.name.utf8) })
                      && !owner.matches(pair.strip)
                  guard sends.allSatisfy({ slot in
                      if slot.state == .observedEmpty { return true }
                      guard matchingReadOnlyPeer, slot.state == .occupiedUnknownDestination,
                            let display = slot.destinationDisplay, !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            let raw = slot.levelRaw, raw.isFinite,
                            let description = slot.levelDescription, !description.isEmpty,
                            slot.bypassed != nil else { return false }
                      return true
                  }) else { return false }
                  return source.channelStrips.filter { $0.physicalBinding?.matches(owner) == true }.count == 1
              }) else { return nil }
        if !policy.outputs.isEmpty {
            // A matching input remains a read-only goal beside one actual direct-output
            // change. Both tasks come from this capture's exact same native pair.
            guard names.isEmpty, before == input.bus,
                  let output = capturedOutput(policy: policy, names: names, source: source, request: request),
                  output.before != output.desired, output.before == sink,
                  output.reference == target.trackRef, output.mixerRef == mixerRef,
                  output.pair.track.matches(pair.track), output.pair.strip.matches(pair.strip) else { return nil }
        }
        if let name = names.first {
            if !row.name.utf8.elementsEqual(name.name.utf8) {
                guard ExactTrackNameAdapter.hasCapturedCoupledFootprint(.init(projectReference: project,
                    targetReference: target.trackRef, expectedBefore: row.name, desiredAfter: name.name), capture: source)
                else { return nil }
            }
        }
        return .init(reference: target.trackRef, mixerRef: mixerRef, pair: pair, control: control,
            before: before, desired: input.bus, sink: sink, capture: source, handle: target.handle)
    }

    static func capturedInputStep(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> Value? {
        guard let task = capturedInput(policy: policy, names: names, source: source, request: request),
              task.before != task.desired,
              let capturedName = source.tracks.first(where: { $0.physicalBinding?.matches(task.pair.track) == true })?.name
        else { return nil }
        return .object(["id": .string("input_" + task.handle), "kind": .string("input_assignment"),
            "target_ref": .string(task.reference.rawValue), "mixer_ref": .string(task.mixerRef.rawValue),
            "before": assignmentValue(.bus(task.before)), "after": assignmentValue(.bus(task.desired)),
            "dependencies": .array(names.filter { !$0.name.utf8.elementsEqual(capturedName.utf8) }
                .map { .string("name_" + $0.target) }), "blocked_reasons": .array([]),
            "required_invariants": .array(["captured_track_strip_pair", "original_input_control",
                "local_strip_footprint", "checked_input_readback", "conditional_owned_input_inverse"].map(Value.string))])
    }

    static func capturedMatchingInputID(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> String? {
        guard let task = capturedInput(policy: policy, names: names, source: source, request: request),
              task.before == task.desired else { return nil }
        return "input_" + task.handle
    }

    /// Positive own-control facts only. This does not enumerate every receiver of a bus.
    private static func capturedReceiverKeeps(policy: ProjectSessionAudit.IntentPolicy,
        source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> [ReceiverKeep]? {
        guard FeatureFlags.adr002TargetRef, FeatureFlags.adr004MutationSaga,
              !policy.receivers.isEmpty, policy.receivers.values.allSatisfy({ $0 == .keep }),
              policy.targets.isEmpty, policy.roles.isEmpty, policy.outputs.isEmpty, policy.sends.isEmpty,
              policy.protectedPaths.isEmpty, policy.mixerVisible == nil, policy.trackSort == nil,
              request.allowUINavigation, Set([SessionPopulationObservation.Domain.strips, .routing]).isSubset(of: request.domains),
              source.before == source.after, source.referencesEnabled, !source.referencesStale,
              source.requestedProjectMatches != false, !source.before.axOccluded,
              case .issued(let project)? = source.projectIssuance, policy.projectRef == project,
              let fresh = source.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
              let presentation = fresh.presentationBinding, let path = source.project.filePath,
              URL(string: presentation.document)?.path == path else { return nil }
        var goals: [ReceiverKeep] = []
        for bus in policy.receivers.keys.sorted() {
            guard OutputAssignment.busNumbers.contains(bus) else { return nil }
            let beforeCount = goals.count
            for (row, strip) in source.channelStrips.enumerated() {
                guard let owner = strip.physicalBinding else { continue }
                let checked = fresh.checkedInputs.filter { $0.receiver.matches(owner) }
                guard checked.contains(where: { $0.busNumber == bus }),
                      SessionPopulationObservation.reportedTypeLabel(of: strip, capture: source)?.observesAux == true else { continue }
                guard checked.count == 1, let label = strip.typeLabelBinding,
                      let input = strip.inputSlotBinding, input.owner.matches(owner),
                      let observedInput = strip.inputObservation, observedInput.state == .observedSource,
                      observedInput.source?.utf8.elementsEqual(input.source.utf8) == true,
                      let mixer = presentation.mixer,
                      CFEqual(presentation.window, owner.window), CFEqual(mixer, owner.mixer),
                      presentation.document.utf8.elementsEqual(owner.document.utf8),
                      fresh.strips?.filter({ $0.typeLabelBinding?.matches(label) == true
                          && $0.inputSlotBinding?.matches(input) == true }).count == 1,
                      let reference = source.mixerReference(at: row),
                      !goals.contains(where: { $0.reference == reference || $0.input.owner.matches(owner) }) else { return nil }
                let pairs = fresh.selectionAssociations.filter { $0.strip.matches(owner) }
                let pair = pairs.count == 1 && fresh.selectionAssociations.filter { candidate in
                    pairs.first.map { candidate.track.matches($0.track) } ?? false
                }.count == 1 ? pairs.first : nil
                goals.append(.init(bus: bus, reference: reference, input: input, label: label,
                    presentation: presentation, pair: pair))
            }
            guard goals.count > beforeCount else { return nil }
        }
        return goals.sorted { $0.bus == $1.bus ? $0.reference.rawValue < $1.reference.rawValue : $0.bus < $1.bus }
    }

    static func capturedReceiverKeepObservations(policy: ProjectSessionAudit.IntentPolicy,
        source: SessionPopulationObservation.Capture, request: SessionPopulationObservation.Request) -> [Value]? {
        guard let goals = capturedReceiverKeeps(policy: policy, source: source, request: request) else { return nil }
        return policy.receivers.keys.sorted().map { bus in
            .object(["bus": .int(bus), "state": .string("observed"),
                "scope": .string("approved_observed_receivers"), "exhaustive": .bool(false),
                "namespace_availability": .string("not_observed"),
                "candidates": .array(goals.filter { $0.bus == bus }.map { goal in
                    .object(["node_id": .string(goal.reference.rawValue), "target_ref": .string(goal.reference.rawValue),
                        "observed_type_label": .string(goal.label.label)])
                })])
        }
    }

    private static func localAssignment(_ destination: ProjectSessionAudit.IntentMainOutput) -> OutputAssignment? {
        switch destination {
        case .physical(let first, let second): return .physical(first, second)
        case .stereoOutput: return .stereoOutput
        case .bus(let number): return .bus(number)
        case .noOutput: return .noOutput
        }
    }

    private static func assignmentValue(_ assignment: OutputAssignment) -> Value {
        switch assignment {
        case .physical(let first, let second): return .object(["kind": .string("physical"), "ports": .array([.int(first), .int(second)])])
        case .stereoOutput: return .object(["kind": .string("stereo_output")])
        case .bus(let number): return .object(["kind": .string("bus"), "number": .int(number)])
        case .noOutput: return .object(["kind": .string("no_output")])
        }
    }

    /// A local direct-output contract, not a complete routing-graph claim. All observations
    /// are immutable facts from the same request; execution still renews their physical custody.
    private static func capturedOutput(policy: ProjectSessionAudit.IntentPolicy, names: [ProjectSessionAudit.ApprovedName],
                                       source: SessionPopulationObservation.Capture,
                                       request: SessionPopulationObservation.Request) -> OutputTask? {
        guard FeatureFlags.adr002TargetRef, FeatureFlags.adr004MutationSaga,
              policy.targets.count == 1, policy.outputs.count == 1,
              policy.roles.isEmpty, policy.sends.isEmpty, policy.receivers.isEmpty, policy.protectedPaths.isEmpty,
              policy.trackSort == nil, policy.mixerVisible == nil,
              let target = policy.targets.first, target.mixerRef == nil,
              names.isEmpty || (names.count == 1 && names.first?.target == target.handle),
              let output = policy.outputs.first, output.subject == .target(target.handle),
              let desired = localAssignment(output.destination), request.allowUINavigation,
              Set([SessionPopulationObservation.Domain.tracks, .strips, .associations, .routing]).isSubset(of: request.domains),
              source.before == source.after, source.referencesEnabled, !source.referencesStale,
              source.requestedProjectMatches != false, !source.before.axOccluded,
              case .issued(let project)? = source.projectIssuance, policy.projectRef == project,
              let fresh = source.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
              let refs = source.issued, case .located(let index) = ProjectSessionAudit.locate(target.trackRef, in: refs),
              source.tracks.allSatisfy({ $0.selectionReadback != nil }),
              source.tracks.filter({ $0.selectionReadback == true }).count == 1 else { return nil }
        let rows = source.tracks.filter { $0.id == index }
        guard rows.count == 1, let row = rows.first, row.selectionReadback == true,
              let track = row.physicalBinding, track.exposure?.hasEnded != true,
              let path = source.project.filePath, track.projectPath?.utf8.elementsEqual(path.utf8) == true else { return nil }
        let pairs = fresh.selectionAssociations.filter { $0.track.matches(track) }
        guard pairs.count == 1, let pair = pairs.first,
              fresh.selectionAssociations.filter({ $0.strip.matches(pair.strip) }).count == 1,
              CFEqual(pair.track.window, pair.strip.window),
              pair.track.document.utf8.elementsEqual(pair.strip.document.utf8) else { return nil }
        let strips = source.channelStrips.indices.filter { source.channelStrips[$0].physicalBinding?.matches(pair.strip) == true }
        let checked = fresh.checkedOutputs.filter { $0.source.matches(pair.strip) && $0.sendOrdinal == nil }
        guard strips.count == 1, let stripIndex = strips.first, let mixerRef = source.mixerReference(at: stripIndex),
              checked.count == 1, let before = checked.first?.assignment else { return nil }
        // Bus routes remain singleton output-only tasks. A positive
        // existing receiver is required; this grants no allocation/lifecycle
        // or shared input/name sink authority.
        let busDeparture: Bool
        if case .bus(let number) = before {
            busDeparture = OutputAssignment.busNumbers.contains(number) && names.isEmpty && policy.inputs.isEmpty
                && localAssignmentForBefore(desired) != nil
                && capturedExistingBusPrerequisites(number, source: source, sourceIndex: stripIndex)
        } else { busDeparture = false }
        let busArrival: Bool
        if case .bus(let number) = desired {
            busArrival = OutputAssignment.busNumbers.contains(number) && names.isEmpty && policy.inputs.isEmpty
                && localAssignmentForBefore(before) != nil
                && capturedExistingBusPrerequisites(number, source: source, sourceIndex: stripIndex)
        } else { busArrival = false }
        let busReplacement: Bool
        if case .bus(let old) = before, case .bus(let new) = desired {
            busReplacement = old != new && OutputAssignment.busNumbers.contains(old)
                && OutputAssignment.busNumbers.contains(new) && names.isEmpty && policy.inputs.isEmpty
                && capturedExistingBusPrerequisites(old, source: source, sourceIndex: stripIndex)
                && capturedExistingBusPrerequisites(new, source: source, sourceIndex: stripIndex)
        } else { busReplacement = false }
        guard localAssignmentForBefore(before) != nil || before == .noOutput || busDeparture || busReplacement,
              localAssignmentForBefore(desired) != nil || desired == .noOutput || busArrival || busReplacement,
              // No Output is initially one output-only task. In particular,
              // it does not expand the shared physical/stereo input-sink
              // contract or admit a preliminary name write in a mixed plan.
              (before != .noOutput && desired != .noOutput)
                || (names.isEmpty && policy.inputs.isEmpty
                    && ((before == .stereoOutput && desired == .noOutput)
                        || (before == .noOutput && desired == .stereoOutput))),
              source.channelStrips.allSatisfy({ strip in
                  guard let binding = strip.physicalBinding, strip.name != nil, strip.nameReadError == nil,
                        strip.volumeReadback != nil, strip.panReadback != nil,
                        strip.pluginsSource == "ax", strip.pluginsReadError == nil, strip.pluginsFullyObserved == true,
                        let input = strip.inputObservation, input.state != .unreadable,
                        let sends = strip.sendSlots else { return false }
                  if binding.matches(pair.strip) {
                      guard sends.allSatisfy({ $0.state == .observedEmpty }) else { return false }
                  } else {
                      // Peers are preserved observations, not destinations or writer targets.
                      // Unknown endpoint identity is honest; an unread level/display/bypass is
                      // not a complete peer baseline, nor is an ambiguous multi-knob run.
                      guard sends.allSatisfy({ send in
                          send.state == .observedEmpty || (send.state == .occupiedUnknownDestination
                              && send.levelRaw?.isFinite == true && send.bypassed != nil
                              && send.destinationDisplay?.isEmpty == false)
                      }) else { return false }
                  }
                  return source.channelStrips.filter { $0.physicalBinding?.matches(binding) == true }.count == 1
              }) else { return nil }
        return .init(reference: target.trackRef, mixerRef: mixerRef, pair: pair, before: before, desired: desired,
            capture: source, handle: target.handle)
    }

    private static func localAssignmentForBefore(_ assignment: OutputAssignment) -> OutputAssignment? {
        switch assignment { case .physical, .stereoOutput: return assignment; default: return nil }
    }

    private static func capturedExistingBusPrerequisites(_ bus: Int, source: SessionPopulationObservation.Capture,
                                                    sourceIndex: Int) -> Bool {
        func input(_ strip: ChannelStripState) -> AXLogicProElements.InputSlotReading {
            guard let observation = strip.inputObservation else { return .unreadable }
            switch observation.state {
            case .unreadable: return .unreadable
            case .noSlot:
                return observation.source == nil && strip.inputSlotBinding == nil ? .noSlot : .unreadable
            case .observedSource:
                guard let label = observation.source, let owner = strip.physicalBinding,
                      let binding = strip.inputSlotBinding, binding.owner.matches(owner),
                      binding.source.utf8.elementsEqual(label.utf8) else { return .unreadable }
                return .source(label)
            }
        }
        let own = input(source.channelStrips[sourceIndex])
        guard own != .unreadable else { return false }
        // Use the scalar loop check's non-Bus-input case only with a positive
        // physical-input menu fact. An unclassified display is not that proof.
        if case .source(let label) = own {
            guard RoutingGraphPublication.classifyOutputLabel(label).0 != .bus,
                  SessionPopulationObservation.reportedCheckedInput(of: source.channelStrips[sourceIndex],
                      capture: source, qualified: true)?.kind == "physical" else { return false }
        }
        return source.channelStrips.enumerated().contains { index, strip in
            guard index != sourceIndex, case .source(let label) = input(strip) else { return false }
            let (kind, number) = RoutingGraphPublication.classifyOutputLabel(label)
            guard kind == .bus && number == bus else { return false }
            // A captured checked contradiction cannot be overridden by its
            // caption. Unpaired peers are checked before the first write below.
            guard source.freshPopulation?.checkedInputs.contains(where: {
                strip.physicalBinding?.matches($0.receiver) == true
            }) == true else { return true }
            let checked = SessionPopulationObservation.reportedCheckedInput(of: strip, capture: source, qualified: true)
            return checked?.kind == "bus" && checked?.number == bus
        }
    }

    private static func capturedExistingSendBusChange(before: OutputAssignment, desired: OutputAssignment?,
        source: SessionPopulationObservation.Capture, sourceIndex: Int) -> Bool {
        guard case .bus(let original) = before,
              OutputAssignment.busNumbers.contains(original) else { return false }
        if desired == .stereoOutput {
            return capturedExistingBusPrerequisites(original, source: source, sourceIndex: sourceIndex)
        }
        guard case .bus(let requested)? = desired, original != requested,
              OutputAssignment.busNumbers.contains(requested) else { return false }
        return capturedExistingBusPrerequisites(original, source: source, sourceIndex: sourceIndex)
            && capturedExistingBusPrerequisites(requested, source: source, sourceIndex: sourceIndex)
    }

    static func supportsCapturedSendDirection(before: OutputAssignment, after: OutputAssignment) -> Bool {
        // Fresh scalar ownership does not supply canonical receiver/input prerequisites.
        if case .bus = before, after == .stereoOutput { return false }
        return AccessibilityChannel.supportsOccupiedSendChange(before: before, after: after)
    }

    /// Removal and typed local output endpoints need no receiver allocation. The ordinal
    /// selects this capture's original native control, which execution must still prove current.
    private static func capturedSend(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> SendTask? {
        guard FeatureFlags.adr002TargetRef, FeatureFlags.adr004MutationSaga,
              names.count <= 1, policy.targets.count == 1, policy.sends.count == 1,
              policy.roles.isEmpty, policy.outputs.isEmpty, policy.receivers.isEmpty,
              policy.protectedPaths.isEmpty, policy.trackSort == nil, policy.mixerVisible == nil,
              let target = policy.targets.first, target.mixerRef == nil,
              let intent = policy.sends.first, intent.target == target.handle,
              intent.isRemoval || intent.localOutput != nil || intent.bus != nil,
              let ordinal = intent.observedOrdinal, ordinal >= 0,
              request.allowUINavigation,
              Set([SessionPopulationObservation.Domain.tracks, .strips, .associations, .routing]).isSubset(of: request.domains),
              source.before == source.after, source.referencesEnabled, !source.referencesStale,
              source.requestedProjectMatches != false, !source.before.axOccluded,
              case .issued(let project)? = source.projectIssuance, policy.projectRef == project,
              let fresh = source.freshPopulation, fresh.stable, fresh.uiEffects.restoration == "restored",
              let refs = source.issued, case .located(let index) = ProjectSessionAudit.locate(target.trackRef, in: refs),
              source.tracks.filter({ $0.id == index }).count == 1,
              let track = source.tracks.first(where: { $0.id == index })?.physicalBinding,
              track.exposure?.hasEnded != true, let path = source.project.filePath,
              track.projectPath?.utf8.elementsEqual(path.utf8) == true else { return nil }
        let pairs = fresh.selectionAssociations.filter { $0.track.matches(track) }
        guard pairs.count == 1, let pair = pairs.first,
              fresh.selectionAssociations.filter({ $0.strip.matches(pair.strip) }).count == 1,
              CFEqual(pair.track.window, pair.strip.window),
              pair.track.document.utf8.elementsEqual(pair.strip.document.utf8) else { return nil }
        let rows = source.channelStrips.indices.filter { source.channelStrips[$0].physicalBinding?.matches(pair.strip) == true }
        let checked = fresh.checkedOutputs.filter { $0.source.matches(pair.strip) && $0.sendOrdinal == ordinal }
        let desired = intent.localOutput ?? intent.bus.map(OutputAssignment.bus)
        guard rows.count == 1, let row = rows.first, let mixerRef = source.mixerReference(at: row),
              checked.count == 1, let reading = checked.first else { return nil }
        let namedBusReplacement: Bool
        if case .bus(let before) = reading.assignment, case .bus(let after)? = desired {
            namedBusReplacement = names.count == 1 && before != after
        } else { namedBusReplacement = false }
        let capturedBusChange = (names.isEmpty || namedBusReplacement) && policy.inputs.isEmpty
            && capturedExistingSendBusChange(before: reading.assignment, desired: desired,
                source: source, sourceIndex: row)
        guard
              // Each involved Bus retains its positive existing receiver proof.
              // A source name also needs its exact coupled footprint below.
              intent.bus == nil || ((names.isEmpty || namedBusReplacement) && policy.inputs.isEmpty
                && (reading.assignment == desired || capturedBusChange)),
              desired.map({ reading.assignment == $0 || supportsCapturedSendDirection(before: reading.assignment, after: $0)
                || capturedBusChange })
                ?? (intent.isRemoval && reading.assignment == .stereoOutput),
              reading.sendNonRoutingChecks == ["Post Fader"] || reading.sendNonRoutingChecks == ["포스트 페이더"],
              let control = reading.sendControl, control.ordinal == ordinal,
              let slots = source.channelStrips[row].sendSlots, slots.count == 2,
              slots.filter({ $0.state == .observedEmpty }).count == 1,
              let occupied = slots.first(where: { $0.state == .occupiedUnknownDestination }),
              occupied.ordinal == ordinal, occupied.levelRaw == 0, occupied.bypassed == false else { return nil }
        if let name = names.first {
            guard name.target == target.handle, let desired,
                  intent.localOutput != nil || namedBusReplacement,
                  desired != reading.assignment,
                  let row = source.tracks.first(where: { $0.physicalBinding?.matches(pair.track) == true }),
                  !row.name.utf8.elementsEqual(name.name.utf8),
                  ExactTrackNameAdapter.hasCapturedCoupledFootprint(.init(projectReference: project,
                    targetReference: target.trackRef, expectedBefore: row.name, desiredAfter: name.name),
                    capture: source) else { return nil }
        }
        return .init(reference: target.trackRef, mixerRef: mixerRef, pair: pair,
            control: control, ordinal: ordinal, before: reading.assignment, desired: desired,
            footprint: slots, capture: source, goalID: "send.target.\(intent.target).\(intent.selectorID)", handle: target.handle)
    }

    static func capturedMatchingSendID(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> String? {
        guard let task = capturedSend(policy: policy, names: names, source: source, request: request),
              task.desired == task.before else { return nil }
        return task.goalID
    }

    static func capturedSendStep(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> Value? {
        guard let task = capturedSend(policy: policy, names: names, source: source, request: request),
              task.desired != task.before,
              var before = assignmentValue(task.before).objectValue else { return nil }
        before["mode"] = .string("post_fader")
        before["level_raw"] = .int(0)
        before["bypassed"] = .bool(false)
        return .object(["id": .string("send_" + task.handle),
            "kind": .string(task.desired == nil ? "local_send_removal" : "local_send_output"),
            "target_ref": .string(task.reference.rawValue), "mixer_ref": .string(task.mixerRef.rawValue),
            "observed_ordinal": .int(task.ordinal),
            "before": .object(before),
            "after": task.desired.map(assignmentValue) ?? .object(["kind": .string("no_send")]),
            "dependencies": .array(names.isEmpty ? [] : [.string("name_" + task.handle)]), "blocked_reasons": .array([]),
            "required_invariants": .array(["captured_track_strip_pair", "original_send_control",
                "checked_send_readback", "conditional_owned_send_inverse"].map(Value.string))])
    }

    static func capturedOutputStep(policy: ProjectSessionAudit.IntentPolicy, names: [ProjectSessionAudit.ApprovedName],
                                   source: SessionPopulationObservation.Capture,
                                   request: SessionPopulationObservation.Request) -> Value? {
        guard let task = capturedOutput(policy: policy, names: names, source: source, request: request) else { return nil }
        let nameChanged = names.first.map { name in
            source.tracks.first(where: { $0.physicalBinding?.matches(task.pair.track) == true })?.name
                .utf8.elementsEqual(name.name.utf8) == false
        } ?? false
        return .object(["id": .string("output_" + task.handle), "kind": .string("local_output"),
            "target_ref": .string(task.reference.rawValue), "mixer_ref": .string(task.mixerRef.rawValue),
            "before": assignmentValue(task.before), "after": assignmentValue(task.desired),
            "dependencies": .array(nameChanged ? [.string("name_" + task.handle)] : []), "blocked_reasons": .array([]),
            "required_invariants": .array(["captured_track_strip_pair", "local_strip_footprint",
                "checked_output_readback", "conditional_original_header_inverse"].map(Value.string))])
    }

    /// The existing adapter's finite scope and captured footprint, shared with planning.
    /// This reads no host state. Availability at this instant is not execution authority:
    /// retained application still revalidates the registry and independently reads AX.
    static func canVerifyCapturedGoals(policy: ProjectSessionAudit.IntentPolicy, policyValue: Value,
                                      names: [ProjectSessionAudit.ApprovedName],
                                      source: SessionPopulationObservation.Capture,
                                      request: SessionPopulationObservation.Request) -> Bool {
        FeatureFlags.adr002TargetRef && capturedGoals(policy: policy, policyValue: policyValue,
            names: names, source: source, request: request) != nil
    }

    private static func capturedGoals(policy originalPolicy: ProjectSessionAudit.IntentPolicy, policyValue: Value,
                                      names: [ProjectSessionAudit.ApprovedName],
                                      source: SessionPopulationObservation.Capture,
                                      request: SessionPopulationObservation.Request) -> CapturedGoals? {
        let input = capturedInput(policy: originalPolicy, names: names, source: source, request: request)
        guard originalPolicy.inputs.isEmpty || input != nil else { return nil }
        if let input, !originalPolicy.outputs.isEmpty {
            guard names.isEmpty,
                  let output = capturedOutput(policy: originalPolicy, names: names, source: source, request: request),
                  input.before == input.desired,
                  output.reference == input.reference, output.mixerRef == input.mixerRef,
                  output.pair.track.matches(input.pair.track), output.pair.strip.matches(input.pair.strip),
                  case .issued(let project)? = source.projectIssuance else { return nil }
            return .init(projectRef: project, document: input.pair.track.document, mixer: nil,
                names: [], renameCapture: nil, output: output, input: input)
        }
        if let input, names.isEmpty {
            guard case .issued(let project)? = source.projectIssuance else { return nil }
            return .init(projectRef: project, document: input.pair.track.document, mixer: nil,
                names: [], renameCapture: nil, input: input)
        }
        let naming = ProjectSessionAudit.normalizedMixerNaming(policy: originalPolicy, names: names,
            capture: source, request: request)
        guard naming.reasons.isEmpty else { return nil }
        let policy = naming.policy
        let send = capturedSend(policy: policy, names: names, source: source, request: request)
        if let send, names.isEmpty,
           case .issued(let project)? = source.projectIssuance {
            return .init(projectRef: project, document: send.pair.track.document, mixer: nil,
                names: [], renameCapture: nil, send: send)
        }
        if names.isEmpty, let receivers = capturedReceiverKeeps(policy: policy, source: source, request: request),
           case .issued(let project)? = source.projectIssuance, let document = receivers.first?.input.owner.document {
            return .init(projectRef: project, document: document, mixer: nil, names: [], renameCapture: nil,
                receivers: receivers)
        }
        let output = capturedOutput(policy: policy, names: names, source: source, request: request)
        if let output, names.isEmpty,
           case .issued(let project)? = source.projectIssuance {
            return .init(projectRef: project, document: output.pair.track.document, mixer: nil,
                names: [], renameCapture: nil, output: output)
        }
        if let sort = capturedSort(policy: policy, names: names, source: source, request: request),
           case .issued(let project)? = source.projectIssuance {
            var mixer: MixerTask?
            if let desired = policy.mixerVisible {
                guard let before = source.freshPopulation?.presentationObservation?.mixerVisible,
                      sort.binding.navigationBaseline != nil, sort.binding.focus != nil,
                      before == desired || sort.binding.finalVisibilityFocusQualified,
                      !(before && !desired && sort.binding.mixerFocusWouldBeRetired) else { return nil }
                mixer = .init(before: before, desired: desired, binding: sort.binding)
            }
            return .init(projectRef: project, document: sort.binding.document, mixer: mixer,
                names: [], renameCapture: nil, sort: sort)
        }
        guard policy.trackSort == nil, policy.roles.isEmpty, (policy.outputs.isEmpty || output != nil),
              (policy.sends.isEmpty || send != nil), policy.receivers.isEmpty, policy.protectedPaths.isEmpty,
              names.count == policy.targets.count,
              !names.isEmpty || policy.mixerVisible != nil,
              case .issued(let issued)? = source.projectIssuance, policy.projectRef == issued else { return nil }
        var goals: [NameGoal] = []
        if !names.isEmpty {
            guard request.domains.contains(.tracks), source.referencesEnabled,
                  SessionPopulationObservation.trackRowReadbackReasons(capture: source).isEmpty,
                  let references = source.issued, let projectPath = source.project.filePath,
                  source.freshPopulation?.stable == true else { return nil }
            for name in names {
                guard let target = policy.targets.first(where: { $0.handle == name.target }),
                      case .located(let index) = ProjectSessionAudit.locate(target.trackRef, in: references) else { return nil }
                let rows = source.tracks.filter { $0.id == index }
                guard rows.count == 1, let row = rows.first,
                      let binding = row.physicalBinding,
                      binding.exposure?.hasEnded != true,
                      binding.projectPath?.utf8.elementsEqual(projectPath.utf8) == true,
                      goals.allSatisfy({ !CFEqual($0.binding.header, binding.header) }) else { return nil }
                goals.append(.init(reference: target.trackRef, mixerRef: target.mixerRef,
                    before: row.name, name: name.name, binding: binding))
            }
            guard let document = goals.first?.binding.document,
                  goals.allSatisfy({ $0.binding.document.utf8.elementsEqual(document.utf8)
                      && CFEqual($0.binding.window, goals[0].binding.window) }) else { return nil }
        }
        let changed = goals.filter { !$0.before.utf8.elementsEqual($0.name.utf8) }
        guard changed.count <= SagaWire.maxPlanSteps else { return nil }
        var selectionOrigin: AXTrackBinding.Binding?
        if changed.count > 1 {
            // Display-name collisions do not retarget these exact physical pairs.
            // Earlier peer changes still require the adapter's own per-target receipts.
            guard source.tracks.allSatisfy({ $0.selectionReadback != nil }),
                  source.tracks.filter({ $0.selectionReadback == true }).count == 1,
                  let original = source.tracks.first(where: { $0.selectionReadback == true })?.physicalBinding,
                  source.channelStrips.allSatisfy({ $0.name != nil }) else { return nil }
            selectionOrigin = original
        }
        for goal in changed {
            guard FeatureFlags.adr004MutationSaga, policy.mixerVisible == nil,
                  request.domains.contains(.strips), request.domains.contains(.associations),
                  ExactTrackNameAdapter.hasCapturedCoupledFootprint(.init(projectReference: issued,
                    targetReference: goal.reference, expectedBefore: goal.before, desiredAfter: goal.name),
                    capture: source) else { return nil }
        }
        guard let desired = policy.mixerVisible else {
            guard policyValue.objectValue?["presentation"] == nil,
                  let document = goals.first?.binding.document else { return nil }
            return .init(projectRef: issued, document: document, mixer: nil, names: goals,
                renameCapture: changed.isEmpty && !goals.contains(where: { $0.mixerRef != nil }) ? nil : source,
                selectionOrigin: selectionOrigin, output: output, send: send, input: input)
        }
        guard policyValue.objectValue?["presentation"]?.objectValue.map({ Set($0.keys) == ["mixer_visible"] }) == true,
              let fresh = source.freshPopulation, fresh.stable,
              let before = fresh.presentationObservation?.mixerVisible,
              fresh.presentationObservation?.isPlaying == false,
              fresh.presentationObservation?.isRecording == false,
              let binding = fresh.presentationBinding,
              binding.navigationBaseline != nil, binding.transport != nil,
              binding.pid != nil, binding.app != nil, binding.focus != nil,
              goals.allSatisfy({ CFEqual($0.binding.window, binding.window)
                  && $0.binding.document.utf8.elementsEqual(binding.document.utf8) }) else { return nil }
        if before, !desired, binding.mixerFocusWouldBeRetired { return nil }
        if before != desired, !binding.finalVisibilityFocusQualified { return nil }
        return .init(projectRef: issued, document: binding.document,
            mixer: .init(before: before, desired: desired, binding: binding), names: goals, renameCapture: nil)
    }

    private static func capturedSort(policy: ProjectSessionAudit.IntentPolicy,
                                     names: [ProjectSessionAudit.ApprovedName],
                                     source: SessionPopulationObservation.Capture,
                                     request: SessionPopulationObservation.Request) -> SortTask? {
        guard FeatureFlags.adr004MutationSaga, let sort = policy.trackSort,
              names.isEmpty, policy.targets.isEmpty, policy.roles.isEmpty, policy.outputs.isEmpty,
              policy.sends.isEmpty, policy.receivers.isEmpty, policy.protectedPaths.isEmpty,
              request.scope == .wholeProject, request.domains == [.tracks],
              source.before == source.after, source.referencesEnabled, !source.referencesStale,
              case .issued(let project)? = source.projectIssuance, policy.projectRef == project,
              let fresh = source.freshPopulation, fresh.stable, fresh.hiddenTracksShown == true,
              SessionPopulationObservation.build(request: request, capture: source).tracks.coverage == .complete,
              !source.tracks.isEmpty, source.tracks.allSatisfy({ $0.isStackHeader == false && $0.physicalBinding != nil }),
              Set(source.tracks.map(\.name)).count == source.tracks.count,
              let issued = source.issued, let snapshot = source.targetSnapshot,
              let binding = fresh.presentationBinding, let transport = binding.transport,
              !transport.isPlaying, !transport.isRecording, binding.app != nil, binding.pid != nil,
              fresh.presentationObservation?.isPlaying == false, fresh.presentationObservation?.isRecording == false,
              fresh.presentationObservation?.uiLocale == binding.uiLocale,
              sort.criterion.measuredLabel(for: binding.uiLocale) != nil,
              sort.inverseCriterion.measuredLabel(for: binding.uiLocale) != nil else { return nil }
        let before = issued.byRow.compactMap { $0?.rawValue }
        guard before.count == source.tracks.count, Set(before).count == before.count,
              sort.expectedOrder.count == before.count, Set(sort.expectedOrder) == Set(before),
              source.tracks.allSatisfy({ row in row.physicalBinding.map {
                  CFEqual($0.window, binding.window) && $0.document.utf8.elementsEqual(binding.document.utf8)
                      && $0.exposure?.hasEnded != true
              } == true }) else { return nil }
        return .init(policy: sort, before: before, rows: source.tracks, binding: binding, snapshot: snapshot)
    }
    let plan: SagaPlan
    let projectRef: TargetReference
    private let mixerTask: MixerTask?
    private let nameGoals: [NameGoal]
    private let renameCapture: SessionPopulationObservation.Capture?
    private let selectionOrigin: AXTrackBinding.Binding?
    private let sortTask: SortTask?
    private let outputTask: OutputTask?
    private let sendTask: SendTask?
    private let inputTask: InputTask?
    private var outputPair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var outputRenewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
    private var outputProof: AccessibilityChannel.HeldSelectionAssociation?
    private var outputOriginalMixerGeometry: AccessibilityChannel.HeldSelectionAssociation.MixerViewportGeometry?
    private var outputGeometrySampled = false
    private var outputAttempted = false
    private var outputApplied = false
    private var outputInverseConsumed = false
    private var outputPeerReadbackUnavailable = false
    private var sendInputPeerHeaders: [AXTrackBinding.Binding]?
    private var sendInputPeerHeadersPrepared = false
    private var sortSnapshot: TargetRegistrySnapshot?
    private var sortProject: TargetReference?
    private var sortApplied = false
    private var sortInverseConsumed = false
    private var sortAttempted = false
    private var sortLeafOrder: [String]?
    private struct NameExecution {
        var ran = false
        var capturedRead: ExactTrackNameAdapter.CapturedCoupledRead?
        var inverse: ExactTrackNameAdapter.OwnedInverse?
        var restored: ExactTrackNameAdapter.OwnedInverse?
        var restoredInputControl: AXMixerInputSlotBinding?
    }
    private var nameExecutions: [TargetReference: NameExecution] = [:]
    private let document: String
    private let cache: StateCache
    private let registry: TargetRegistry
    private let journal: SagaJournal
    // Cache observations and issued references have independently owned epochs.
    private let cacheProjectEpoch: UInt64
    private let registryProjectEpoch: UInt64
    private let receiverKeeps: [ReceiverKeep]
    private var ran = false
    private var ownedVisibility: Bool?
    private var ownedMixer: AXUIElement?

    private init(plan: SagaPlan, projectRef: TargetReference, document: String,
                 mixerTask: MixerTask? = nil, nameGoals: [NameGoal] = [],
                 renameCapture: SessionPopulationObservation.Capture? = nil,
                 selectionOrigin: AXTrackBinding.Binding? = nil, cacheProjectEpoch: UInt64,
                 sortTask: SortTask? = nil,
                 outputTask: OutputTask? = nil,
                 sendTask: SendTask? = nil,
                 inputTask: InputTask? = nil,
                 receiverKeeps: [ReceiverKeep] = [],
                 registryProjectEpoch: UInt64,
                 cache: StateCache, registry: TargetRegistry, journal: SagaJournal) {
        self.plan = plan; self.projectRef = projectRef; self.document = document
        self.mixerTask = mixerTask; self.nameGoals = nameGoals
        self.renameCapture = renameCapture
        self.selectionOrigin = selectionOrigin
        self.sortTask = sortTask
        self.outputTask = outputTask
        self.sendTask = sendTask
        self.inputTask = inputTask
        self.receiverKeeps = receiverKeeps
        self.cacheProjectEpoch = cacheProjectEpoch; self.registryProjectEpoch = registryProjectEpoch
        self.cache = cache; self.registry = registry; self.journal = journal
    }

    static func retained(id: String, digest: String, key: String, cache: StateCache,
                         registry: TargetRegistry, journal: SagaJournal) async -> ApprovedSessionRepair? {
        guard FeatureFlags.adr002TargetRef,
              let (canonical, source) = await cache.retainedRepairSource(id: id, digest: digest),
              SessionPopulationObservation.captureMovementReason(capture: source.capture) == nil,
              let targetSnapshot = source.capture.targetSnapshot,
              let data = canonical.json.data(using: .utf8),
              var object = try? JSONDecoder().decode(Value.self, from: data).objectValue,
              object["executable"]?.boolValue == true,
              object["plan_id"]?.stringValue == id, object["digest"]?.stringValue == digest,
              let steps = object["steps"]?.arrayValue,
              object["preview"]?.arrayValue == steps else { return nil }
        object.removeValue(forKey: "plan_id"); object.removeValue(forKey: "digest")
        guard let encoded = try? encodeJSONStrict(Value.object(object), compact: true),
              SHA256.hash(data: Data(encoded.utf8)).map({ String(format: "%02x", $0) }).joined() == digest else { return nil }
        guard let policyObject = object["approved_policy"]?.objectValue,
              case .accepted(let originalPolicy) = ProjectSessionAudit.parseIntentPolicy(policyObject),
              let names = ProjectSessionAudit.parseApprovedNames(object["approved_names"], policy: originalPolicy),
              ["reasons", "questions", "receiver_questions", "findings", "new_object_inventory"].allSatisfy({
                  object[$0]?.arrayValue?.isEmpty == true
              }),
              let unchanged = object["unchanged_tasks"]?.arrayValue,
              let captured = capturedGoals(policy: originalPolicy, policyValue: .object(policyObject), names: names,
                  source: source.capture, request: source.request) else { return nil }
        let policy = ProjectSessionAudit.normalizedMixerNaming(policy: originalPolicy, names: names,
            capture: source.capture, request: source.request).policy
        let unchangedNames = names.filter { name in
            captured.names.contains { goal in
                policy.targets.first(where: { $0.handle == name.target })?.trackRef == goal.reference
                    && goal.before.utf8.elementsEqual(goal.name.utf8)
            }
        }
        var unchangedIDs = unchangedNames.map { "name_" + $0.target }
            + Set(captured.receivers.map(\.bus)).sorted().map { "receiver_keep_bus_\($0)" }
        if let send = captured.send, send.desired == send.before { unchangedIDs.append(send.goalID) }
        if let input = captured.input, input.desired == input.before { unchangedIDs.append("input_" + input.handle) }
        if let sort = captured.sort, sort.before == sort.policy.expectedOrder { unchangedIDs.append("track_sort") }
        guard unchanged.count == unchangedIDs.count,
              Set(unchanged.compactMap(\.stringValue)) == Set(unchangedIDs) else { return nil }
        let issued = captured.projectRef
        let goals = captured.names
        // Ordinary polls advance content revisions even for identical values.
        // This finite native adapter does not execute those cached rows: its
        // original physical goals are independently re-read before any effect.
        // Keep project/occlusion history strict; do not relax draft freshness.
        let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
        guard boundary.hasDocument, !boundary.axOccluded,
              boundary.occlusionRevision == source.capture.after.occlusionRevision,
              boundary.versions.values.allSatisfy({ $0.projectEpoch == source.capture.projectEpoch }),
              let currentProject = await registry.resolveCurrentProject(issued),
              currentProject.projectEpoch == targetSnapshot.projectEpoch else { return nil }
        for goal in goals {
            guard let current = await registry.resolve(goal.reference), current.kind == .track,
                  current.physicalTrack?.matches(goal.binding) == true else { return nil }
        }
        let changed = goals.filter { !$0.before.utf8.elementsEqual($0.name.utf8) }
        if let input = captured.input, changed.isEmpty, captured.output == nil {
            guard let current = await registry.resolve(input.reference), current.kind == .track,
                  current.physicalTrack?.matches(input.pair.track) == true,
                  let mixer = await registry.resolve(input.mixerRef), mixer.kind == .mixerStrip,
                  mixer.physicalMixerStrip?.matches(input.pair.strip) == true else { return nil }
            if input.before == input.desired {
                guard steps.isEmpty else { return nil }
                return .init(plan: .init(steps: [], idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest),
                    projectRef: issued, document: captured.document, nameGoals: goals,
                    cacheProjectEpoch: source.capture.projectEpoch, inputTask: input,
                    registryProjectEpoch: targetSnapshot.projectEpoch, cache: cache, registry: registry, journal: journal)
            }
            guard steps == [capturedInputStep(policy: policy, names: names, source: source.capture, request: source.request)] else { return nil }
            let saga = SagaPlan(steps: [inputSagaStep(input, project: issued)],
                idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
            return .init(plan: saga, projectRef: issued, document: captured.document, nameGoals: goals,
                cacheProjectEpoch: source.capture.projectEpoch, inputTask: input,
                registryProjectEpoch: targetSnapshot.projectEpoch, cache: cache, registry: registry, journal: journal)
        }
        if let send = captured.send, changed.isEmpty {
            guard let current = await registry.resolve(send.reference), current.kind == .track,
                  current.physicalTrack?.matches(send.pair.track) == true,
                  let mixer = await registry.resolve(send.mixerRef), mixer.kind == .mixerStrip,
                  mixer.physicalMixerStrip?.matches(send.pair.strip) == true else { return nil }
            if send.desired == send.before {
                guard steps.isEmpty else { return nil }
                return .init(plan: .init(steps: [], idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest),
                    projectRef: issued, document: captured.document,
                    cacheProjectEpoch: source.capture.projectEpoch, sendTask: send,
                    registryProjectEpoch: targetSnapshot.projectEpoch, cache: cache, registry: registry, journal: journal)
            }
            guard steps == [capturedSendStep(policy: policy, names: names, source: source.capture, request: source.request)] else { return nil }
            let saga = SagaPlan(steps: [.init(operationID: .mixerSetSendOutputVerified, targetRef: send.mixerRef,
                params: ["ordinal": .int(send.ordinal),
                    "destination": send.desired.map(assignmentValue) ?? .object(["kind": .string("no_send")]),
                    "expected_current": assignmentValue(send.before), "replace_existing": .bool(true),
                    "project_ref": .string(issued.rawValue)],
                expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination"))],
                idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
            return .init(plan: saga, projectRef: issued, document: captured.document,
                cacheProjectEpoch: source.capture.projectEpoch, sendTask: send,
                registryProjectEpoch: targetSnapshot.projectEpoch, cache: cache, registry: registry, journal: journal)
        }
        if let output = captured.output, changed.isEmpty {
            guard steps == [capturedOutputStep(policy: policy, names: names, source: source.capture, request: source.request)],
                  let current = await registry.resolve(output.reference), current.kind == .track,
                  current.physicalTrack?.matches(output.pair.track) == true,
                  let mixer = await registry.resolve(output.mixerRef), mixer.kind == .mixerStrip,
                  mixer.physicalMixerStrip?.matches(output.pair.strip) == true else { return nil }
            let saga = SagaPlan(steps: [.init(operationID: .mixerSetOutputVerified, targetRef: output.reference,
                params: ["destination": .string(output.desired.token)],
                expectedInverse: .init(operationID: .mixerSetOutputVerified, valueParameter: "destination"))],
                idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
            return .init(plan: saga, projectRef: issued, document: captured.document, nameGoals: goals,
                cacheProjectEpoch: source.capture.projectEpoch, outputTask: output, inputTask: captured.input,
                registryProjectEpoch: targetSnapshot.projectEpoch,
                cache: cache, registry: registry, journal: journal)
        }
        if let sort = captured.sort {
            let matching = sort.before == sort.policy.expectedOrder
            guard steps.count == (matching ? 0 : 1) + (captured.mixer == nil ? 0 : 1) else { return nil }
            var sagaSteps: [SagaStep] = []
            if !matching {
                guard let step = steps[0].objectValue,
                      step["kind"] == .string("track_sort"), step["target_ref"] == .string(issued.rawValue),
                      step["before"]?.objectValue?["order"] == .array(sort.before.map(Value.string)),
                      step["after"]?.objectValue?["criterion"] == .string(sort.policy.criterion.rawValue),
                      step["after"]?.objectValue?["order"] == .array(sort.policy.expectedOrder.map(Value.string)),
                      step["inverse"]?.objectValue?["criterion"] == .string(sort.policy.inverseCriterion.rawValue),
                      step["inverse"]?.objectValue?["expected_order"] == .array(sort.before.map(Value.string)),
                      step["blocked_reasons"]?.arrayValue?.isEmpty == true,
                      step["dependencies"]?.arrayValue?.isEmpty == true,
                      let orderValue = sortOrderValue(sort.policy.expectedOrder) else { return nil }
                sagaSteps.append(.init(operationID: .tracksSortVerified, targetRef: issued,
                    params: ["criterion": .string(sort.policy.criterion.rawValue),
                             "expected_order": orderValue],
                    expectedInverse: .init(operationID: .tracksSortVerified, valueParameter: "expected_order")))
            }
            if let mixer = captured.mixer {
                guard let view = steps[matching ? 0 : 1].objectValue, view["kind"] == .string("mixer_visibility"),
                      view["target_ref"] == .string(issued.rawValue),
                      view["before"]?.objectValue?["visible"] == .bool(mixer.before),
                      view["after"]?.objectValue?["visible"] == .bool(mixer.desired),
                      view["dependencies"] == .array(matching ? [] : [.string("track_sort")]),
                      view["blocked_reasons"]?.arrayValue?.isEmpty == true else { return nil }
                sagaSteps.append(.init(operationID: .navigateToggleView, targetRef: issued,
                    params: ["view": .string("mixer"), "visible": .bool(mixer.desired)],
                    expectedInverse: .init(operationID: .navigateToggleView, valueParameter: "visible")))
            }
            let saga = SagaPlan(steps: sagaSteps,
                idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
            return .init(plan: saga, projectRef: issued, document: captured.document,
                mixerTask: captured.mixer, cacheProjectEpoch: source.capture.projectEpoch, sortTask: sort,
                registryProjectEpoch: targetSnapshot.projectEpoch, cache: cache, registry: registry, journal: journal)
        }
        if let renameCapture = captured.renameCapture, !changed.isEmpty {
            let inputSteps = captured.input.map { $0.before == $0.desired ? 0 : 1 } ?? 0
            guard steps.count == changed.count + (captured.output == nil ? 0 : 1)
                + (captured.send == nil ? 0 : 1) + inputSteps else { return nil }
            for (value, goal) in zip(steps, changed) {
                guard let step = value.objectValue,
                      step["kind"] == .string("name"), step["target_ref"] == .string(goal.reference.rawValue),
                      step["before"]?.objectValue?["name"] == .string(goal.before),
                      step["after"]?.objectValue?["name"] == .string(goal.name),
                      step["blocked_reasons"]?.arrayValue?.isEmpty == true,
                      step["dependencies"]?.arrayValue?.isEmpty == true else { return nil }
                if let origin = policy.targets.first(where: { $0.trackRef == goal.reference })?.mixerRef {
                    guard step["requested_mixer_ref"] == .string(origin.rawValue),
                          step["coupled_after"] == .array([goal.reference, origin].map {
                              .object(["target_ref": .string($0.rawValue), "name": .string(goal.name)])
                          }) else { return nil }
                }
            }
            var sagaSteps: [SagaStep] = changed.map { goal in .init(operationID: .tracksRename, targetRef: goal.reference,
                params: ["name": .string(goal.name)],
                expectedInverse: .init(operationID: .tracksRename, valueParameter: "name")) }
            if let output = captured.output {
                guard steps.last == capturedOutputStep(policy: policy, names: names, source: source.capture, request: source.request),
                      let current = await registry.resolve(output.reference), current.kind == .track,
                      current.physicalTrack?.matches(output.pair.track) == true,
                      let mixer = await registry.resolve(output.mixerRef), mixer.kind == .mixerStrip,
                      mixer.physicalMixerStrip?.matches(output.pair.strip) == true else { return nil }
                sagaSteps.append(.init(operationID: .mixerSetOutputVerified, targetRef: output.reference,
                    params: ["destination": .string(output.desired.token)],
                    expectedInverse: .init(operationID: .mixerSetOutputVerified, valueParameter: "destination")))
            }
            if let send = captured.send {
                guard steps.last == capturedSendStep(policy: policy, names: names, source: source.capture, request: source.request),
                      let current = await registry.resolve(send.reference), current.kind == .track,
                      current.physicalTrack?.matches(send.pair.track) == true,
                      let mixer = await registry.resolve(send.mixerRef), mixer.kind == .mixerStrip,
                      mixer.physicalMixerStrip?.matches(send.pair.strip) == true,
                      let desired = send.desired else { return nil }
                sagaSteps.append(.init(operationID: .mixerSetSendOutputVerified, targetRef: send.mixerRef,
                    params: ["ordinal": .int(send.ordinal), "destination": assignmentValue(desired),
                        "expected_current": assignmentValue(send.before), "replace_existing": .bool(true),
                        "project_ref": .string(issued.rawValue)],
                    expectedInverse: .init(operationID: .mixerSetSendOutputVerified, valueParameter: "destination")))
            }
            if let input = captured.input {
                guard let current = await registry.resolve(input.reference), current.kind == .track,
                      current.physicalTrack?.matches(input.pair.track) == true,
                      let mixer = await registry.resolve(input.mixerRef), mixer.kind == .mixerStrip,
                      mixer.physicalMixerStrip?.matches(input.pair.strip) == true else { return nil }
                if input.before != input.desired {
                    guard steps.last == capturedInputStep(policy: policy, names: names, source: source.capture, request: source.request) else { return nil }
                    sagaSteps.append(inputSagaStep(input, project: issued))
                }
            }
            let saga = SagaPlan(steps: sagaSteps,
                idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
            return .init(plan: saga, projectRef: issued, document: captured.document, nameGoals: goals,
                renameCapture: renameCapture, selectionOrigin: captured.selectionOrigin,
                cacheProjectEpoch: source.capture.projectEpoch, outputTask: captured.output, sendTask: captured.send, inputTask: captured.input,
                registryProjectEpoch: targetSnapshot.projectEpoch, cache: cache, registry: registry, journal: journal)
        }
        if steps.isEmpty {
            guard captured.mixer == nil else { return nil }
            if !captured.receivers.isEmpty {
                guard let observed = capturedReceiverKeepObservations(policy: policy, source: source.capture, request: source.request),
                      object["existing_receiver_observations"] == .array(observed) else { return nil }
            }
            return .init(plan: .init(steps: [], idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest),
                projectRef: issued, document: captured.document, nameGoals: goals,
                renameCapture: captured.renameCapture,
                cacheProjectEpoch: source.capture.projectEpoch, receiverKeeps: captured.receivers,
                registryProjectEpoch: targetSnapshot.projectEpoch,
                cache: cache, registry: registry, journal: journal)
        }
        guard steps.count == 1,
              let step = steps[0].objectValue, step["kind"]?.stringValue == "mixer_visibility",
              step["blocked_reasons"]?.arrayValue?.isEmpty == true,
              let rawRef = step["target_ref"]?.stringValue,
              issued.rawValue == rawRef,
              let before = step["before"]?.objectValue?["visible"]?.boolValue,
              let desired = step["after"]?.objectValue?["visible"]?.boolValue,
              let mixer = captured.mixer, mixer.before == before, mixer.desired == desired
        else { return nil }
        let saga = SagaPlan(steps: [.init(operationID: .navigateToggleView, targetRef: issued,
            params: ["view": .string("mixer"), "visible": .bool(desired)],
            expectedInverse: .init(operationID: .navigateToggleView, valueParameter: "visible"))],
            idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
        return .init(plan: saga, projectRef: issued, document: captured.document,
            mixerTask: mixer, nameGoals: goals,
            cacheProjectEpoch: source.capture.projectEpoch, registryProjectEpoch: targetSnapshot.projectEpoch,
            cache: cache, registry: registry, journal: journal)
    }

    func supports(_ step: SagaStep) -> Bool {
        if inputTask != nil, step.operationID == .mixerSetInputBusVerified { return plan.steps.contains(step) }
        if sendTask != nil, step.operationID == .mixerSetSendOutputVerified { return plan.steps.contains(step) }
        if let task = outputTask, step.operationID == .mixerSetOutputVerified {
            return step.operationID == .mixerSetOutputVerified && step.targetRef == task.reference
                && Set(step.params.keys) == ["destination"]
                && [task.before.token, task.desired.token].contains(step.params["destination"]?.stringValue ?? "")
                && step.expectedInverse.operationID == .mixerSetOutputVerified
                && step.expectedInverse.valueParameter == "destination"
        }
        if let sort = sortTask, step.operationID == .tracksSortVerified {
            return step.operationID == .tracksSortVerified && step.targetRef == projectRef
                && Set(step.params.keys) == ["criterion", "expected_order"]
                && step.params["criterion"] == .string(sort.policy.criterion.rawValue)
                && [Self.sortOrderValue(sort.before), Self.sortOrderValue(sort.policy.expectedOrder)].contains(step.params["expected_order"] ?? .null)
                && step.expectedInverse.operationID == .tracksSortVerified
                && step.expectedInverse.valueParameter == "expected_order"
        }
        if let goal = changedNameGoals.first(where: { $0.reference == step.targetRef }) {
            return step.operationID == .tracksRename && step.targetRef == goal.reference
                && Set(step.params.keys) == ["name"]
                && (step.params["name"] == .string(goal.name) || step.params["name"] == .string(goal.before))
                && step.expectedInverse.operationID == .tracksRename && step.expectedInverse.valueParameter == "name"
        }
        return mixerTask != nil && step.operationID == .navigateToggleView && step.targetRef == projectRef
            && Set(step.params.keys) == ["view", "visible"] && step.params["view"] == .string("mixer")
            && step.params["visible"]?.boolValue != nil
            && step.expectedInverse.operationID == .navigateToggleView && step.expectedInverse.valueParameter == "visible"
    }

    /// Only a successfully retained, digest-checked canonical approval can supply this native
    /// witness. The public Saga parser cannot construct an ApprovedSessionRepair.
    func inputCustody(for step: SagaStep) -> (AccessibilityChannel.HeldSelectionAssociation.Pair,
        AXMixerInputSlotBinding, SessionPopulationObservation.Capture)? {
        guard let task = inputTask, step.operationID == .mixerSetInputBusVerified,
              supports(step), plan.steps.last == step,
              plan.steps.count == 1 || (plan.steps.count == 2 && changedNameGoals.count == 1
                && plan.steps.first?.operationID == .tracksRename), plan.canonicalPlanID != nil,
              plan.canonicalDigest != nil else { return nil }
        return (task.pair, task.control, task.capture)
    }

    private static func inputSagaStep(_ task: InputTask, project: TargetReference) -> SagaStep {
        .init(operationID: .mixerSetInputBusVerified, targetRef: task.reference,
            params: ["destination": assignmentValue(.bus(task.desired)),
                "expected_current": assignmentValue(.bus(task.before)), "replace_existing": .bool(true),
                "project_ref": .string(project.rawValue)],
            expectedInverse: .init(operationID: .mixerSetInputBusVerified, valueParameter: "destination"))
    }

    func matchingInputReadCustody() -> (SagaStep, AccessibilityChannel.HeldSelectionAssociation.Pair,
        AXMixerInputSlotBinding, SessionPopulationObservation.Capture)? {
        guard hasMatchingInputGoal, let task = inputTask,
              plan.canonicalPlanID != nil, plan.canonicalDigest != nil else { return nil }
        let selector = SagaStep(operationID: .mixerSetInputBusVerified, targetRef: task.reference,
            params: ["destination": Self.assignmentValue(.bus(task.desired)),
                "expected_current": Self.assignmentValue(.bus(task.before)), "replace_existing": .bool(true),
                "project_ref": .string(projectRef.rawValue)],
            expectedInverse: .init(operationID: .mixerSetInputBusVerified, valueParameter: "destination"))
        return (selector, task.pair, task.control, task.capture)
    }

    /// The retained approval, not discovery or a caller token, owns this one
    /// output-only Stereo/No Output step and its already-verified inverse.
    /// The scalar still checks the live source and protected footprint at its leaf.
    func ownsCanonicalNoOutputChange(before: OutputAssignment, destination: OutputAssignment,
                                    pair: AccessibilityChannel.HeldSelectionAssociation.Pair) -> Bool {
        guard Self.current === self, Self.outputLeafPermission != nil,
              nameGoals.isEmpty, inputTask == nil, sendTask == nil,
              let task = outputTask, plan.canonicalPlanID != nil, plan.canonicalDigest != nil,
              plan.steps.count == 1, let step = plan.steps.first, supports(step),
              (task.before == .stereoOutput && task.desired == .noOutput)
                || (task.before == .noOutput && task.desired == .stereoOutput) else { return false }
        let held = outputPair ?? task.pair
        guard held.track.matches(pair.track), held.strip.matches(pair.strip),
              pair.track.document.utf8.elementsEqual(document.utf8),
              pair.strip.document.utf8.elementsEqual(document.utf8) else { return false }
        if outputAttempted {
            // performOutput consumes the single inverse before entering the
            // scalar; an acknowledgement without independent verification is not enough.
            return outputApplied && outputInverseConsumed
                && before == task.desired && destination == task.before
        }
        return !outputInverseConsumed && before == task.before && destination == task.desired
    }

    /// A matching input may observe only this same pair's independently verified output effect.
    /// This is not an input write/inverse capsule, and an output acknowledgement is insufficient.
    func verifiedMatchingInputOutput(at pair: AccessibilityChannel.HeldSelectionAssociation.Pair) -> OutputAssignment? {
        guard hasMatchingInputGoal, nameGoals.isEmpty, let input = inputTask, let output = outputTask,
              outputAttempted, outputApplied, !outputInverseConsumed,
              plan.steps.count == 1, plan.steps.first?.operationID == .mixerSetOutputVerified,
              input.reference == output.reference, input.mixerRef == output.mixerRef,
              input.pair.track.matches(pair.track),
              (outputPair ?? output.pair).track.matches(pair.track),
              (outputPair ?? output.pair).strip.matches(pair.strip) else { return nil }
        return output.desired
    }

    /// Read continuity only, after the output's mandatory independent verification.
    /// The reader must still establish the current input control and checked Bus.
    func verifiedMatchingInputOutputRenewal() -> AccessibilityChannel.OriginalHeaderSourceRenewal? {
        guard let source = outputRenewal,
              verifiedMatchingInputOutput(at: source.pair) != nil,
              source.permits(runtime: source.pair.track.runtime) else { return nil }
        return source
    }

    func sendRemovalCustody(for step: SagaStep) -> (AccessibilityChannel.HeldSelectionAssociation.Pair,
        AXLogicProElements.AssignedSendMenuControl)? {
        guard let task = sendTask, step.operationID == .mixerSetSendOutputVerified,
              supports(step), plan.canonicalPlanID != nil,
              plan.canonicalDigest != nil else { return nil }
        return (task.pair, task.control)
    }

    /// Discover header witnesses in the existing independent read budget, not
    /// the route-write budget. These are hints for a later actual input read,
    /// never cached Bus values, renewed public references or write authority.
    func prepareSendInputPeerHeaders(at original: AccessibilityChannel.HeldSelectionAssociation.Pair) async -> Bool {
        let parentHelpGuard = AXHelpers.HelpReadGuard.current
        guard parentHelpGuard?.stopped != true else { return false }
        guard let task = sendTask, case .bus(let before) = task.before else { return true }
        let buses: [Int]
        if case .bus(let after)? = task.desired, before != after { buses = [before, after] }
        else if task.desired == .stereoOutput { buses = [before] }
        else { return true }
        if sendInputPeerHeadersPrepared { return true }
        sendInputPeerHeadersPrepared = true
        guard original.track.matches(task.pair.track), await projectIsCurrent(allowPendingCancellation: true) else { return false }
        let runtime = original.track.runtime
        guard let proof = AccessibilityChannel.HeldSelectionAssociation(window: original.track.window,
            logic: runtime, expectedProject: nil, requiresProjectReference: false,
            allowsSelectedChildRailEntry: true, retainedMixerSource: original.strip), proof.permitsRead() else { return true }
        let focus = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
        focus.retainAssociation(proof)
        let observed = await AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: {
            parentHelpGuard?.permits() == false || !focus.permits()
        })) {
            await AccessibilityChannel.renewSourceThroughOriginalHeader(original, original: original.strip,
                runtime: runtime, sourceDisposition: .readObservation,
                observingReadFocus: { focus.retainAssociation($0) })
        }
        guard observed.effects.restoration == "restored", let renewed = observed.source,
              renewed.pair.strip.matches(original.strip), renewed.pair.track.matches(original.track),
              renewed.permits(runtime: runtime) else { return observed.effects.attempted.isEmpty }
        var headers: [AXTrackBinding.Binding] = []
        var covered = Set<Int>()
        for row in task.capture.channelStrips {
            guard let slot = row.inputSlotBinding, !slot.owner.matches(task.pair.strip),
                  RoutingGraphPublication.classifyOutputLabel(slot.source).0 == .bus,
                  let bus = RoutingGraphPublication.classifyOutputLabel(slot.source).1, buses.contains(bus),
                  slot.owner.currentIndex(runtime: runtime) != nil else { continue }
            // Only exact native owner correspondence identifies its original
            // header. A missing/ambiguous pair leaves ordinary discovery intact.
            let pairs = renewed.observedPairs.filter { $0.strip.matches(slot.owner) }
            guard pairs.count == 1, let pair = pairs.first else { return true }
            if !headers.contains(where: { $0.matches(pair.track) }) { headers.append(pair.track) }
            covered.insert(bus)
        }
        if buses.allSatisfy({ covered.contains($0) }) { sendInputPeerHeaders = headers }
        return true
    }

    /// A caption admits only a candidate. All involved Bus endpoints and the source's
    /// loop-safety input must be independently checked before either route press.
    /// A read may retire native controls. Only its actual original-header
    /// renewal plus complete singleton correspondence can carry read custody;
    /// this is not a route effect, inverse or registry/reference renewal.
    struct SendReadCustody: Sendable {
        let pair: AccessibilityChannel.HeldSelectionAssociation.Pair
        let control: AXLogicProElements.AssignedSendMenuControl
        let renewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
        var continuedChange: AccessibilityChannel.ChangedSendObservation? = nil
    }

    func sendBusInputsCurrent(at originalPair: AccessibilityChannel.HeldSelectionAssociation.Pair,
        control: AXLogicProElements.AssignedSendMenuControl,
        expected: OutputAssignment,
        ownedChange: AccessibilityChannel.ChangedSendObservation? = nil,
        corroboratingBeforeInWriter: SendRemovalSagaAdapter.RequiredBeforeState? = nil) async -> SendReadCustody? {
        guard let task = sendTask, case .bus(let before) = task.before else {
            return .init(pair: originalPair, control: control, renewal: nil)
        }
        let buses: [Int]
        if case .bus(let after)? = task.desired, before != after { buses = [before, after] }
        else if task.desired == .stereoOutput { buses = [before] }
        else { return .init(pair: originalPair, control: control, renewal: nil) }
        // Both admitted Bus departures must renew the actual original input
        // owner after popup cleanup; the destination kind does not preserve it.
        var stage = "initial_custody", accepted = false
        var sourceCheckpoint = "not_checked"
        defer {
            if !accepted {
                Log.info("Canonical Send input read refused at \(stage), source_current=\(sourceCheckpoint)", subsystem: "saga")
            }
        }
        let priorSource = ownedChange?.source
        guard ownedChange.map({ $0.permits(runtime: originalPair.track.runtime)
            && $0.control.matches(control) && $0.checkedBefore == task.before && $0.checkedAfter == expected
            && expected == task.desired
            && AccessibilityChannel.ChangedSendObservation.protectedSlots($0.footprint, ordinal: task.ordinal)
                == AccessibilityChannel.ChangedSendObservation.protectedSlots(task.footprint, ordinal: task.ordinal)
        }) ?? true else { return nil }
        guard priorSource.map({ $0.pair.strip.matches(originalPair.strip)
                && $0.pair.track.matches(originalPair.track) && $0.originalTrack.matches(task.pair.track)
                && $0.permits(runtime: originalPair.track.runtime) }) ?? true,
              [task.before, task.desired].contains(expected),
              await projectIsCurrent(allowPendingCancellation: true), originalPair.track.matches(task.pair.track),
              let capturedSource = task.capture.channelStrips.first(where: {
                  $0.physicalBinding?.matches(task.pair.strip) == true
              }), let own = capturedSource.inputObservation,
              let proof = AccessibilityChannel.HeldSelectionAssociation(window: originalPair.track.window,
                logic: originalPair.track.runtime, expectedProject: nil, requiresProjectReference: false,
                allowsSelectedChildRailEntry: true),
              CFEqual(proof.headers[proof.originalIndex], originalPair.track.header),
              CFEqual(proof.mixer, originalPair.strip.mixer), proof.document.utf8.elementsEqual(document.utf8),
              proof.permitsRead() else { return nil }
        var pair = originalPair
        var renewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
        var roster = priorSource
        let runtime = originalPair.track.runtime
        func accept(_ observed: AccessibilityChannel.OriginalHeaderSourceRenewal,
                    from prior: AccessibilityChannel.HeldSelectionAssociation.Pair) -> Bool {
            // The handoff itself checks this exact renewal before and after
            // its current native header/strip reads. No native observation or
            // action separates that entry check from these pure CF matches.
            guard observed.original.matches(prior.strip), observed.originalTrack.matches(prior.track),
                  let primary = observed.sourceForOriginalHeader(originalPair, runtime: runtime) else { return false }
            pair = primary.pair; renewal = primary; roster = primary
            return true
        }
        func sourceCurrent() -> Bool {
            do { try SessionPopulationObservation.requireOwnedAcquisition() }
            catch { sourceCheckpoint = "acquisition:\(error)"; return false }
            sourceCheckpoint = "source_header"
            guard pair.track.currentIndex(in: roster?.observation ?? proof) != nil else { return false }
            sourceCheckpoint = "source_strip"
            guard pair.strip.currentIndex(in: roster?.observation ?? proof) != nil else { return false }
            sourceCheckpoint = "complete_population"
            guard let census = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: pair.strip.mixer,
                    runtime: runtime.ax)?.strips, census.count == task.capture.channelStrips.count else { return false }
            if let roster {
                sourceCheckpoint = "read_renewal"
                guard roster.permits(runtime: runtime) else { return false }
                sourceCheckpoint = "renewed_population"
                guard census.count == roster.observation.strips.count,
                      zip(census, roster.observation.strips).allSatisfy({ CFEqual($0, $1) }) else { return false }
                sourceCheckpoint = "current"
                return true
            }
            sourceCheckpoint = "captured_control"
            guard let current = AXLogicProElements.assignedSendMenuControl(in: pair.strip.strip,
                    ordinal: task.ordinal, runtime: runtime.ax), control.matches(current) else { return false }
            sourceCheckpoint = "captured_population"
            guard zip(census, task.capture.channelStrips).allSatisfy({ current, captured in
                    guard let owner = captured.physicalBinding else { return false }
                    return CFEqual(current, owner.matches(task.pair.strip) ? pair.strip.strip : owner.strip)
                  }) else { return false }
            sourceCheckpoint = "original_read_scope"
            guard proof.permitsRead() else { return false }
            sourceCheckpoint = "current"
            return true
        }
        let inputFocus = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
        return await AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: {
            !inputFocus.permits() && !proof.permitsRead()
        }), operation: { [self] in
            guard sourceCurrent() else { return nil }
            let originalMixerGeometry = proof.observedMixerViewportGeometry()
            switch own.state {
            case .unreadable: return nil
            case .noSlot:
                guard AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax).reading == .noSlot else { return nil }
            case .observedSource:
                stage = "source_input"
                let held = task.capture.freshPopulation?.checkedInputs.filter { $0.receiver.matches(task.pair.strip) } ?? []
                guard held.count == 1, let expectedInput = held.first?.assignment, case .physical = expectedInput,
                      let original = capturedSource.inputSlotBinding else { return nil }
                let slot = AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax)
                guard case .source(let label) = slot.reading, let nativeControl = slot.control,
                      label.utf8.elementsEqual(original.source.utf8),
                      !pair.strip.matches(task.pair.strip) || CFEqual(nativeControl, original.control) else { return nil }
                let prior = pair
                let current = AXMixerInputSlotBinding(owner: pair.strip, control: nativeControl, source: label)
                let inputReadScope = roster?.observation ?? proof
                let read = await AXMixerStripBinding.$current.withValue(pair.strip) {
                    await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                        await AccessibilityChannel.getCheckedInputObservation(runtime: runtime,
                            restoringMixerGeometry: originalMixerGeometry,
                            observingPopupFocus: { inputFocus.retainRoutingPopupFocus($0) },
                            observingRenewedFocus: { inputFocus.retainAssociation($0) },
                            refreshingOriginalSourceAfterCleanup: true,
                            observingPeerHeaders: sendInputPeerHeaders,
                            readingOriginalScope: inputReadScope)
                    }
                }
                stage = "source_input_assignment"
                guard read.inputAssignment == expectedInput else {
                    Log.info("Canonical Send source checked input refused: \(read.result.message)", subsystem: "saga")
                    return nil
                }
                if let observed = read.inputRenewal {
                    stage = "source_input_renewal"
                    guard accept(observed, from: prior),
                          read.inputSlot?.owner.matches(pair.strip) == true,
                          read.inputSlot?.source.utf8.elementsEqual(original.source.utf8) == true else { return nil }
                } else {
                    stage = "source_input_control"
                    guard read.inputSlot?.matches(current) == true else { return nil }
                }
                stage = "source_input_bookend"
                guard sourceCurrent() else { return nil }
            }
            for bus in buses {
                stage = "receiver_\(bus)"
                var checked = false
                var candidates: [(AccessibilityChannel.HeldSelectionAssociation.Pair?, AXMixerInputSlotBinding)] = []
                // A still-current captured control needs no adoption. A selected-
                // scope capture may have no association for any other header.
                for receiver in task.capture.channelStrips {
                    guard let slot = receiver.inputSlotBinding, !slot.owner.matches(task.pair.strip),
                          RoutingGraphPublication.classifyOutputLabel(slot.source).0 == .bus,
                          RoutingGraphPublication.classifyOutputLabel(slot.source).1 == bus,
                          slot.owner.currentIndex(runtime: runtime) != nil else { continue }
                    // Keep a current roster pair for this exact native owner
                    // before deduplicating candidates. Its input read can retire
                    // it even when the selected capture never associated it.
                    let observed = roster?.observedPairs.filter { $0.strip.matches(slot.owner) } ?? []
                    guard observed.count <= 1 else { return nil }
                    let prior = observed.first
                        ?? task.capture.freshPopulation?.selectionAssociations.first { $0.strip.matches(slot.owner) }
                    stage = "receiver_\(bus)_captured_control"
                    let native = AXLogicProElements.inputSlotRead(in: slot.owner.strip, runtime: runtime.ax)
                    guard case .source(let label) = native.reading, label.utf8.elementsEqual(slot.source.utf8),
                          let nativeControl = native.control, CFEqual(nativeControl, slot.control) else { return nil }
                    candidates.append((prior, slot))
                }
                var inputPeerHeaders = candidates.compactMap { $0.0?.track }
                if let roster {
                    stage = "receiver_\(bus)_roster"
                    guard roster.permits(runtime: runtime) else { return nil }
                    for current in roster.observedPairs {
                        guard !current.track.matches(task.pair.track),
                              !candidates.contains(where: { $0.1.owner.matches(current.strip) }),
                              roster.observedPairs.filter({ $0.strip.matches(current.strip) }).count == 1 else { continue }
                        let native = AXLogicProElements.inputSlotRead(in: current.strip.strip, runtime: runtime.ax)
                        guard case .source(let label) = native.reading, let nativeControl = native.control,
                              RoutingGraphPublication.classifyOutputLabel(label).0 == .bus,
                              let peerBus = RoutingGraphPublication.classifyOutputLabel(label).1,
                              buses.contains(peerBus) else { continue }
                        // These headers already have actual native pair witnesses.
                        // Their current input labels only choose needed discovery;
                        // the checked input readers still decide every Bus fact.
                        if !inputPeerHeaders.contains(where: { $0.matches(current.track) }) {
                            inputPeerHeaders.append(current.track)
                        }
                        guard peerBus == bus else { continue }
                        // This is an actual current positive receiver candidate,
                        // not a label join to a retired peer ref. Its owned menu
                        // must independently prove the Bus before it is usable.
                        candidates.append((current, .init(owner: current.strip, control: nativeControl, source: label)))
                    }
                }
                stage = "receiver_\(bus)_candidates"
                Log.info("Canonical Send receiver \(bus): candidates=\(candidates.count),paired=\(candidates.filter { $0.0 != nil }.count),roster=\(roster?.observedPairs.count ?? 0)", subsystem: "saga")
                for (currentPair, currentSlot) in candidates {
                    stage = "receiver_\(bus)_pre_read"
                    guard sourceCurrent(), currentSlot.owner.currentIndex(runtime: runtime) != nil else { return nil }
                    let owner = currentSlot.owner
                    let inputReadScope = roster?.observation ?? proof
                    stage = "receiver_\(bus)_native_read"
                    let read = await AXMixerStripBinding.$current.withValue(owner) {
                        await AXMixerStripBinding.$outputAssociation.withValue(currentPair) {
                            await AccessibilityChannel.getInputBusObservation(runtime: runtime,
                                requiringOriginalInputControl: currentSlot,
                                restoringMixerGeometry: originalMixerGeometry,
                                observingPopupFocus: { inputFocus.retainRoutingPopupFocus($0) },
                                observingRenewedFocus: { inputFocus.retainAssociation($0) },
                                refreshingOriginalSourceAfterCleanup: currentPair != nil,
                                observingPeerHeaders: inputPeerHeaders.isEmpty ? nil : inputPeerHeaders,
                                readingOriginalScope: inputReadScope)
                        }
                    }
                    stage = "receiver_\(bus)_assignment"
                    guard read.assignment == .bus(bus) else {
                        Log.info("Canonical Send receiver checked input refused: \(read.result.message)", subsystem: "saga")
                        return nil
                    }
                    if let observed = read.inputRenewal {
                        stage = "receiver_\(bus)_renewal"
                        guard let currentPair, accept(observed, from: currentPair),
                              read.inputSlot?.owner.matches(observed.pair.strip) == true else { return nil }
                    } else {
                        stage = "receiver_\(bus)_control"
                        guard read.inputSlot?.matches(currentSlot) == true else { return nil }
                    }
                    stage = "receiver_\(bus)_source_bookend"
                    guard sourceCurrent() else { return nil }
                    checked = true
                    break
                }
                guard checked else { return nil }
            }
            guard sourceCurrent() else { return nil }
            let finalControl: AXLogicProElements.AssignedSendMenuControl
            var continuedChange: AccessibilityChannel.ChangedSendObservation?
            if let renewal {
                // Input cleanup may propagate the name already written by this
                // plan. Continue that actual owned effect before comparing the
                // footprint or asking the deciding Send leaf to corroborate it.
                stage = "renewed_owned_name"
                if hasMatchingNameGoals, !(await renewNameAfterSend(renewal)) { return nil }
                stage = "renewed_footprint"
                // The actual whole-census renewal authenticates new physical owners;
                // frozen complete values still decide their preservation.
                outputPair = pair; outputRenewal = renewal; outputProof = renewal.observation
                guard let label = capturedSource.output, let sink = OutputAssignment.observed(slotLabel: label),
                      outputFootprintHeld(pair: pair, assignment: sink,
                        taskOverride: .init(reference: task.reference, mixerRef: task.mixerRef, pair: task.pair,
                            before: sink, desired: sink, capture: task.capture, handle: task.handle),
                        ownedSendChange: ownedChange),
                      let current = AXLogicProElements.assignedSendMenuControl(in: pair.strip.strip,
                        ordinal: task.ordinal, runtime: runtime.ax),
                      let slots = AXLogicProElements.sendSlotObservations(in: pair.strip.strip, runtime: runtime.ax),
                      slots == (ownedChange?.footprint ?? task.footprint),
                      slots.count == 2, slots.filter({ $0.state == .occupiedUnknownDestination }).count == 1,
                      slots.filter({ $0.state == .observedEmpty }).count == 1 else { return nil }
                if let ownedChange {
                    // The verified forward effect, complete protected footprint
                    // and actual original-header Input renewal retain only its
                    // native custody. The deciding inverse already checks the
                    // expected destination and mode at this exact control before
                    // every leaf boundary; do not first open/Cancel another reader.
                    stage = "continued_native_effect"
                    guard let continued = ownedChange.continuingForDecidingInverse(after: renewal,
                        control: current, slots: slots, runtime: runtime) else { return nil }
                    continuedChange = continued
                    finalControl = current
                    Log.info("Canonical Send inverse retained its owned effect for the deciding popup", subsystem: "saga")
                } else if let before = corroboratingBeforeInWriter,
                   sendNameUsesInputFootprint, expected == task.before {
                    // These are the actual independent Saga read's expectations,
                    // not write authority. The deciding writer checks them again
                    // in its own popup at this exact renewed native control.
                    stage = "deciding_send_before_state"
                    guard before.footprint == slots,
                          before.nonRoutingChecks == ["Post Fader"] || before.nonRoutingChecks == ["포스트 페이더"],
                          sourceCurrent() else { return nil }
                    finalControl = current
                } else {
                    let read = await AXMixerStripBinding.$current.withValue(pair.strip) {
                        await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                            await AccessibilityChannel.getOutputObservation(runtime: runtime, sendOrdinal: task.ordinal,
                                requiringOriginalSendControl: current,
                                readingOriginalScope: renewal.observation,
                                observingPopupFocus: { inputFocus.retainRoutingPopupFocus($0) })
                        }
                    }
                    stage = "renewed_checked_send"
                    guard read.assignment == expected, read.sendControl?.matches(current) == true,
                          read.sendNonRoutingChecks == ["Post Fader"] || read.sendNonRoutingChecks == ["포스트 페이더"],
                          let final = AXLogicProElements.assignedSendMenuControl(in: pair.strip.strip,
                            ordinal: task.ordinal, runtime: runtime.ax), current.matches(final),
                          AXLogicProElements.sendSlotObservations(in: pair.strip.strip, runtime: runtime.ax) == slots,
                          sourceCurrent() else { return nil }
                    finalControl = final
                }
            } else { finalControl = control }
            stage = "final_custody"
            guard await projectIsCurrent(allowPendingCancellation: true), sourceCurrent() else { return nil }
            accepted = true
            return .init(pair: pair, control: finalControl, renewal: renewal, continuedChange: continuedChange)
        })
    }


    /// Continue this plan's already-owned name through its original-header
    /// Send custody. The registry's original strip is never rebound.
    func renewNameAfterSend(_ source: AccessibilityChannel.OriginalHeaderSourceRenewal) async -> Bool {
        guard let task = sendTask else { return false }
        return await renewNameAfterRouting(source, reference: task.reference, pair: task.pair)
    }

    func renewNameAfterInput(_ source: AccessibilityChannel.OriginalHeaderSourceRenewal) async -> Bool {
        guard let task = inputTask else { return false }
        if let goal = changedNameGoals.first, nameExecutions[goal.reference]?.ran != true {
            guard changedNameGoals.count == 1, goal.reference == task.reference,
                  source.originalTrack.matches(task.pair.track), let capture = renameCapture,
                  let read = await ExactTrackNameAdapter.renewingCapturedCoupledRead(nameAction(goal), capture: capture,
                    registry: registry, prior: nameExecutions[goal.reference]?.capturedRead, through: source) else { return false }
            nameExecutions[goal.reference, default: .init()].capturedRead = read
        } else {
            guard await renewNameAfterRouting(source, reference: task.reference, pair: task.pair) else { return false }
        }
        if nameFootprintTask != nil {
            outputPair = source.pair; outputRenewal = source; outputProof = source.observation
        }
        return true
    }

    private func renewNameAfterRouting(_ source: AccessibilityChannel.OriginalHeaderSourceRenewal,
        reference: TargetReference, pair: AccessibilityChannel.HeldSelectionAssociation.Pair) async -> Bool {
        guard source.originalTrack.matches(pair.track) else { return false }
        guard let goal = changedNameGoals.first else { return true }
        guard changedNameGoals.count == 1, goal.reference == reference,
              let proof = nameExecutions[goal.reference]?.inverse,
              let renewed = await ExactTrackNameAdapter.renewingOwnedCoupledName(proof, through: source) else { return false }
        nameExecutions[goal.reference, default: .init()].inverse = renewed
        return true
    }

    func inputNameEffect(at source: AccessibilityChannel.HeldSelectionAssociation.Pair) -> ExactTrackNameAdapter.VerifiedNameEffect? {
        guard let task = inputTask, changedNameGoals.count == 1, let goal = changedNameGoals.first,
              goal.reference == task.reference, source.track.matches(task.pair.track),
              let effect = nameExecutions[goal.reference]?.inverse.flatMap(ExactTrackNameAdapter.recordedNameEffect),
              effect.matches(source), effect.trackName.utf8.elementsEqual(goal.name.utf8),
              case .success(let name?) = AXValueExtractors.extractTrackNameResult(from: source.track.header, runtime: source.track.runtime.ax),
              name.utf8.elementsEqual(effect.trackName.utf8),
              case .success(let stripName?) = AXPluginInstanceIdentity.stripNameResult(source.strip.strip, runtime: source.track.runtime.ax),
              stripName.utf8.elementsEqual(effect.stripName.utf8),
              source.track.currentIndex() != nil, source.strip.currentIndex(runtime: source.track.runtime) != nil else { return nil }
        return effect
    }

    func inputNameHeld(at source: AccessibilityChannel.HeldSelectionAssociation.Pair) -> Bool {
        guard hasMatchingNameGoals else { return true }
        if !changedNameGoals.isEmpty { return inputNameEffect(at: source) != nil }
        // The input adapter still proves the original source/control and full
        // captured footprint. An unchanged name is corroboration, not an effect
        // receipt or permission to replace the name baseline.
        guard nameGoals.count == 1, let goal = nameGoals.first, let task = inputTask,
              goal.reference == task.reference, source.track.matches(goal.binding),
              goal.before.utf8.elementsEqual(goal.name.utf8),
              case .success(let name?) = AXValueExtractors.extractTrackNameResult(
                from: source.track.header, runtime: source.track.runtime.ax),
              name.utf8.elementsEqual(goal.name.utf8) else { return false }
        return source.track.currentIndex() != nil && source.strip.currentIndex(runtime: source.track.runtime) != nil
    }

    /// Historical inspection expiry does not erase an actual coupled name effect.
    /// This supplies only the original read pair; Send state and receivers still
    /// need their independent reads and deciding checks.
    func sendReadPairAfterOwnedName(reference: TargetReference, source: AXMixerStripBinding.Binding) async
        -> AccessibilityChannel.HeldSelectionAssociation.Pair? {
        guard let task = sendTask, reference == task.mixerRef,
              case .bus(let before) = task.before, case .bus(let after)? = task.desired, before != after,
              changedNameGoals.count == 1, let goal = changedNameGoals.first, goal.reference == task.reference,
              let owned = nameExecutions[goal.reference]?.inverse,
              ExactTrackNameAdapter.recordedNameEffect(owned)?.matches(task.pair) == true,
              await cache.retainedInspection(id: task.capture.captureID) == nil,
              task.capture.targetSnapshot == (await registry.currentSnapshot),
              let track = await registry.resolve(task.reference), track.kind == .track,
              track.physicalTrack?.matches(task.pair.track) == true,
              await projectIsCurrent(allowPendingCancellation: true), sendNameHeld(at: source) else { return nil }
        return task.pair
    }

    var sendNameUsesInputFootprint: Bool {
        guard nameGoals.count == 1, changedNameGoals.count == 1,
              let goal = changedNameGoals.first, let task = sendTask,
              goal.reference == task.reference, goal.binding.matches(task.pair.track),
              case .bus(let before) = task.before, case .bus(let after)? = task.desired else { return false }
        return before != after
    }

    /// Check this plan's actual name effect before read-only Input acquisition.
    /// Its complete protected footprint is checked in the resulting native
    /// renewal; without that renewal the caller must keep the full name read.
    func sendNameSourceCurrent(at pair: AccessibilityChannel.HeldSelectionAssociation.Pair) async -> Bool {
        guard sendNameUsesInputFootprint, FeatureFlags.adr004MutationSaga,
              let task = sendTask, let goal = changedNameGoals.first,
              pair.track.matches(task.pair.track),
              await projectIsCurrent(), await registry.resolveCurrentProject(projectRef) != nil,
              let target = await registry.resolve(goal.reference), target.kind == .track,
              target.physicalTrack?.matches(goal.binding) == true,
              target.descriptor.trackName.utf8.elementsEqual(goal.name.utf8),
              originalSelectionHeld(), sendNameHeld(at: pair.strip),
              let effect = nameExecutions[goal.reference]?.inverse.flatMap(ExactTrackNameAdapter.recordedNameEffect),
              goal.mixerRef == nil || effect.stripName.utf8.elementsEqual(goal.name.utf8),
              let after = await registry.resolve(goal.reference),
              after.physicalTrack?.matches(goal.binding) == true,
              after.descriptor.trackName.utf8.elementsEqual(goal.name.utf8),
              await projectIsCurrent(), originalSelectionHeld() else { return false }
        return true
    }

    /// Corroborate the owned name at the actual Send leaf, not just before
    /// dispatch. The caller still proves the original source/control and gate.
    func sendNameHeld(at source: AXMixerStripBinding.Binding) -> Bool {
        guard hasMatchingNameGoals else { return true }
        guard let task = sendTask, changedNameGoals.count == 1,
              let goal = changedNameGoals.first, goal.reference == task.reference,
              let effect = nameExecutions[goal.reference]?.inverse.flatMap(ExactTrackNameAdapter.recordedNameEffect),
              // An actual Input renewal can retire the captured strip. Match
              // the owned effect at this exact source and the original header.
              effect.matches(.init(track: task.pair.track, strip: source)),
              effect.trackName.utf8.elementsEqual(goal.name.utf8),
              task.pair.track.currentIndex() != nil,
              case .success(let name?) = AXValueExtractors.extractTrackNameResult(
                from: task.pair.track.header, runtime: task.pair.track.runtime.ax),
              name.utf8.elementsEqual(effect.trackName.utf8),
              case .success(let stripName?) = AXPluginInstanceIdentity.stripNameResult(
                source.strip, runtime: task.pair.track.runtime.ax),
              stripName.utf8.elementsEqual(effect.stripName.utf8) else { return false }
        return task.pair.track.currentIndex() != nil
            && source.currentIndex(runtime: task.pair.track.runtime) != nil
    }

    private var changedNameGoals: [NameGoal] {
        guard renameCapture != nil else { return [] }
        return nameGoals.filter { !$0.before.utf8.elementsEqual($0.name.utf8) }
    }

    private var ownedNameEffects: [ExactTrackNameAdapter.OwnedInverse] {
        nameExecutions.values.compactMap(\.inverse)
    }

    private func originalSelectionHeld() -> Bool {
        guard let origin = selectionOrigin else { return true }
        guard let index = origin.currentIndex(),
              AccessibilityChannel.selectionIsExclusive(index: index, runtime: origin.runtime) else { return false }
        return origin.currentIndex() == index
    }

    private func nameAction(_ goal: NameGoal) -> ExactTrackNameAdapter.Action {
        .init(projectReference: projectRef, targetReference: goal.reference,
            expectedBefore: goal.before, desiredAfter: goal.name)
    }

    private func projectIsCurrent(allowPendingCancellation: Bool = false) async -> Bool {
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
        if !allowPendingCancellation, await journal.record(for: plan.idempotencyKey) == .cancellationRequested {
            return false
        }
        if sortTask != nil, !(await sortRegistryHeld()) { return false }
        guard let target = await registry.resolve(sortProject ?? projectRef), target.kind == .project,
              target.projectEpoch == registryProjectEpoch,
              let url = URL(string: document), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              target.descriptor.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true,
              await cache.getProject().filePath?.utf8.elementsEqual(url.path.utf8) == true,
              await cache.currentProjectIdentity()?.epoch == cacheProjectEpoch,
              (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return false }
        return true
    }

    private func navigation(runtime: AXLogicProElements.Runtime, allowPendingCancellation: Bool = false) async -> AccessibilityChannel.OwnedMixerObservationNavigation? {
        let sortedRows: [TrackState]?
        if sortTask != nil {
            guard let read = sortReading(), read.order == currentSortOrder else { return nil }
            // Only the owned sort's independently verified whole footprint
            // permits the new physical order/selection, not a fresh baseline.
            sortedRows = read.rows
        } else { sortedRows = nil }
        guard let binding = mixerTask?.binding,
              await projectIsCurrent(allowPendingCancellation: allowPendingCancellation), let pid = binding.pid, runtime.logicProPID() == pid,
              let app = binding.app, let currentApp = AXLogicProElements.appRoot(runtime: runtime), CFEqual(app, currentApp),
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String, runtime: runtime.ax),
              let originalFocus = binding.focus, CFEqual(focus, originalFocus),
              let target = await registry.resolve(sortProject ?? projectRef),
              let original = binding.navigationBaseline,
              let navigation = AccessibilityChannel.OwnedMixerObservationNavigation(window: binding.window, runtime: runtime,
                expectedProject: target.descriptor, requiresProjectReference: true,
                referenceIsCurrent: { [self] in await projectIsCurrent(allowPendingCancellation: allowPendingCancellation) }),
              navigation.title.utf8.elementsEqual(binding.title.utf8), navigation.document.utf8.elementsEqual(binding.document.utf8),
              navigation.headers.count == original.headers.count,
              zip(navigation.headers, sortedRows?.compactMap { $0.physicalBinding?.header } ?? original.headers)
                .allSatisfy({ CFEqual($0, $1) }),
              navigation.selected == (sortedRows?.compactMap(\.selectionReadback) ?? original.selected),
              await projectIsCurrent(allowPendingCancellation: allowPendingCancellation) else { return nil }
        return navigation
    }

    private func stop(runtime: AXLogicProElements.Runtime) -> Bool {
        guard (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil,
              let app = mixerTask?.binding.app,
              let focus: AXUIElement = AXHelpers.getAttribute(app, kAXFocusedUIElementAttribute as String,
                  runtime: runtime.ax) else { return true }
        // Each census check still reads and classifies fresh focus. The outer
        // navigation boundaries independently revalidate the retained app/PID.
        return StatePoller.backgroundTickYields(to: AccessibilityChannel.readLogicKeyboardFocus(of: focus, runtime: runtime))
    }

    /// Sort's old reference strings annotate the observed permutation only.
    /// They never become mutation authority after the scalar invalidates topology.
    private static func sortOrderValue(_ order: [String]) -> Value? {
        // Existing inverse ownership accepts exact scalars, not arrays. This
        // JSON string is an annotation of an actual read, never a binding token.
        guard let json = try? encodeJSONStrict(Value.array(order.map(Value.string)), compact: true) else { return nil }
        return .string(json)
    }

    private func sortReading() -> (rows: [TrackState], order: [String])? {
        guard let sort = sortTask, (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
        let binding = sort.binding, runtime = binding.runtime
        func scopeHeld() -> Bool {
            guard runtime.logicProPID() == binding.pid, runtime.focusedApplicationPID() == binding.pid,
                  let app = AXLogicProElements.appRoot(runtime: runtime), binding.app.map({ CFEqual($0, app) }) == true,
                  let window = AXLogicProElements.mainWindow(runtime: runtime), CFEqual(window, binding.window),
                  AXHelpers.getTitle(window, runtime: runtime.ax)?.utf8.elementsEqual(binding.title.utf8) == true,
                  case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(window, runtime: runtime)
            else { return false }
            return document.utf8.elementsEqual(binding.document.utf8)
        }
        guard scopeHeld(), case .read(let headers) = AXLogicProElements.allTrackHeadersVerifiedRead(in: binding.window, runtime: runtime),
              headers.count == sort.rows.count,
              sort.rows.allSatisfy({ row in row.physicalBinding.map { original in
                  headers.filter { CFEqual($0, original.header) }.count == 1
              } == true }),
              AXLogicProElements.hiddenTrackViewRead(headers: headers, in: binding.window, runtime: runtime)?.shown == true,
              let rows = AccessibilityChannel.readTrackStates(from: headers, in: binding.window,
                runtime: runtime, readingTypeHelp: false,
                stoppingWhen: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil }).states,
              rows.count == sort.rows.count,
              rows.allSatisfy({ $0.isStackHeader == false && $0.physicalBinding != nil }),
              Set(rows.map(\.name)).count == rows.count,
              let transport = try? AXLogicProElements.observedTransportActivity(in: binding.window, runtime: runtime,
                checking: { try SessionPopulationObservation.requireOwnedAcquisition() }),
              !transport.isPlaying, !transport.isRecording,
              let originalTransport = binding.transport,
              CFEqual(transport.controlBar, originalTransport.controlBar), CFEqual(transport.play, originalTransport.play),
              CFEqual(transport.record, originalTransport.record),
              case .locale(let locale) = AXLogicProElements.logicUILocaleIdentifierRead(runtime: runtime),
              locale == binding.uiLocale else { return nil }
        func footprint(_ row: TrackState) -> Data? {
            guard let data = try? JSONEncoder().encode(row),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            object.removeValue(forKey: "id")
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        var order: [String] = []
        for row in rows {
            let matches = sort.rows.indices.filter { sort.rows[$0].name.utf8.elementsEqual(row.name.utf8) }
            guard matches.count == 1, let index = matches.first,
                  let before = footprint(sort.rows[index]), let after = footprint(row), before == after else { return nil }
            order.append(sort.before[index])
        }
        guard scopeHeld(), (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil else { return nil }
        return (rows, order)
    }

    private func sortRegistryHeld() async -> Bool {
        guard let sort = sortTask, await registry.currentSnapshot == (sortSnapshot ?? sort.snapshot),
              await cache.currentProjectIdentity()?.epoch == cacheProjectEpoch,
              let project = await registry.resolveCurrentProject(sortProject ?? projectRef),
              let url = URL(string: document), url.isFileURL,
              project.descriptor.projectFilePath?.utf8.elementsEqual(url.path.utf8) == true,
              await cache.getProject().filePath?.utf8.elementsEqual(url.path.utf8) == true else { return false }
        return true
    }

    private var currentSortOrder: [String]? {
        guard let sort = sortTask, !sortAttempted || sortApplied else { return nil }
        return sortApplied && !sortInverseConsumed ? sort.policy.expectedOrder : sort.before
    }

    private func sortFootprintHeld() -> Bool {
        guard let expected = currentSortOrder else { return false }
        return sortReading()?.order == expected
    }

    /// The existing sort calls this immediately before its actual measured menu leaf.
    /// It is inert for scalar callers and cannot authorize another sort/plan.
    func permitsSortLeaf() -> Bool {
        guard let expected = sortLeafOrder else { return false }
        return sortReading()?.order == expected
    }

    private func readSortState(_ step: SagaStep) async -> ObservedState? {
            guard supports(step), !sortAttempted || sortApplied, await sortRegistryHeld(),
                  let reading = sortReading(), await sortRegistryHeld() else { return nil }
            guard let value = Self.sortOrderValue(reading.order) else { return nil }
            let evidence = SagaReadEvidence(readSource: .axTrackOrder, provenance: .liveIndependent,
                trackIndex: nil, projectReference: (sortProject ?? projectRef).rawValue, field: "track_order_json",
                observed: value, sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
            return .init(read: evidence)
    }

    func performSort(_ step: SagaStep, router: ChannelRouter) async -> CallTool.Result {
        let restoring = sortAttempted
            guard let sort = sortTask, supports(step), await sortRegistryHeld(),
                  (!restoring || (sortApplied && !sortInverseConsumed)),
                  let before = sortReading(), before.order == (restoring ? sort.policy.expectedOrder : sort.before),
                  step.params["expected_order"] == Self.sortOrderValue(restoring ? sort.before : sort.policy.expectedOrder),
                  await sortRegistryHeld() else { return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false]) }
            let snapshot = await registry.currentSnapshot
            let project = ProjectInfo(name: AccessibilityChannel.projectName(fromWindowTitle: sort.binding.title),
                filePath: URL(string: document)?.path)
            guard case .issued(let currentProject) = await ProjectReferenceIssuance.issue(cached: project, registry: registry, snapshot: snapshot),
                  let issued = await TrackReferenceIssuance.issue(for: before.rows, registry: registry, snapshot: snapshot) else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
            let desired = restoring ? sort.before : sort.policy.expectedOrder
            var freshReferences: [String] = []
            for reference in desired {
                guard let index = before.order.firstIndex(of: reference), let current = issued.byRow[index] else {
                    return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
                }
                freshReferences.append(current.rawValue)
            }
            guard await registry.currentSnapshot == snapshot, await sortRegistryHeld() else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
            if restoring { sortInverseConsumed = true }
            sortLeafOrder = before.order
            defer { sortLeafOrder = nil }
            let result = await AXHelpers.HelpReadGuard.$current.withValue(
                .init(allowHelpReads: false, stop: { (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil })) {
                await ApprovedSessionRepair.$current.withValue(self) {
                    await TrackDispatcher.handle(command: "sort_verified", params: [
                        "criterion": .string((restoring ? sort.policy.inverseCriterion : sort.policy.criterion).rawValue),
                        "expected_order": .array(freshReferences.map(Value.string)), "confirmed": .bool(true)],
                        router: router, cache: cache, targetRegistry: registry)
                }
            }
            let text: String
            if case .text(let value, _, _) = result.content.first { text = value } else { text = "" }
            let body = decodedJSONObject(text)
            let attempted = body?["write_attempted"] as? Bool == true
            guard attempted else { return result }
            sortAttempted = true
            let afterSnapshot = await registry.currentSnapshot
            guard afterSnapshot.projectEpoch == snapshot.projectEpoch,
                  afterSnapshot.topologyGeneration == snapshot.topologyGeneration + 1,
                  body?["state"] as? String == "A", let after = sortReading(), after.order == desired,
                  case .issued(let renewedProject) = await ProjectReferenceIssuance.issue(cached: project,
                    registry: registry, snapshot: afterSnapshot),
                  await TrackReferenceIssuance.issue(for: after.rows, registry: registry, snapshot: afterSnapshot) != nil,
                  await registry.currentSnapshot == afterSnapshot else {
                sortApplied = false
                return toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable,
                    extras: ["write_attempted": true]), isError: true)
            }
            sortSnapshot = afterSnapshot; sortProject = renewedProject; sortApplied = true
            _ = currentProject
            return result
    }

    private func reading() async -> (Bool, AXUIElement?)? {
        guard let binding = mixerTask?.binding else { return nil }
        let runtime = binding.runtime
        // Pending journal cancellation must not suppress the independent reads
        // needed to verify a forward effect or conditionally restore our own one.
        guard let navigation = await navigation(runtime: runtime, allowPendingCancellation: true) else { return nil }
        if let task = mixerTask, task.before != task.desired,
           !navigation.hasQualifiedFinalVisibilityFocus() { return nil }
        let observed = await navigation.approvedVisibility(expectedTransport: binding.transport,
            stoppingWhen: { [self] in stop(runtime: runtime) })
        if sortTask != nil {
            guard sortFootprintHeld(), await sortRegistryHeld() else { return nil }
        }
        return observed
    }

    func readState(_ step: SagaStep) async -> ObservedState? {
        if step.operationID == .mixerSetOutputVerified, outputTask != nil { return await readOutputState(step) }
        if step.operationID == .tracksSortVerified, sortTask != nil { return await readSortState(step) }
        if let goal = changedNameGoals.first(where: { $0.reference == step.targetRef }), let capture = renameCapture {
            guard supports(step), await projectIsCurrent(allowPendingCancellation: true),
                  originalSelectionHeld() else { return nil }
            let execution = nameExecutions[goal.reference]
            let observed: String?
            if let proof = execution?.inverse {
                observed = await ExactTrackNameAdapter.readOwnedCoupledName(proof,
                    preserveCurrentPeers: step.params["name"] == .string(goal.before), ownedPeerEffects: ownedNameEffects)
            } else if execution?.ran == true, execution?.inverse == nil, step.params["name"] == .string(goal.before) {
                guard let proof = execution?.restored else { return nil }
                observed = await ExactTrackNameAdapter.readOwnedCoupledName(proof)
            } else {
                observed = await ExactTrackNameAdapter.readCapturedCoupledName(nameAction(goal),
                    capture: capture, registry: registry,
                    preserveCurrentPeers: execution?.inverse != nil && step.params["name"] == .string(goal.before),
                    capturedRead: execution?.capturedRead,
                    ownedPeerEffects: step.params["name"] == .string(goal.before) ? [] : ownedNameEffects)
            }
            guard let name = observed,
                  let initialIndex = goal.binding.currentIndex(),
                  await projectIsCurrent(allowPendingCancellation: true), originalSelectionHeld() else { return nil }
            var index = initialIndex
            if step.params["name"] == .string(goal.before), let original = execution?.restoredInputControl {
                guard original.owner.currentIndex(runtime: goal.binding.runtime) != nil else { return nil }
                // The deciding name read can itself redraw native controls.
                // Corroborate the actual retained input after that final read.
                let input = AXLogicProElements.inputSlotRead(in: original.owner.strip, runtime: goal.binding.runtime.ax)
                guard case .source(let label) = input.reading, let control = input.control,
                      original.matches(.init(owner: original.owner, control: control, source: label)),
                      original.owner.currentIndex(runtime: goal.binding.runtime) != nil,
                      let currentIndex = goal.binding.currentIndex(),
                      await projectIsCurrent(allowPendingCancellation: true), originalSelectionHeld(),
                      case .success(.some(let currentDocument)) = AXLogicProElements.projectPickerDocumentRead(
                        original.owner.window, runtime: goal.binding.runtime),
                      currentDocument.utf8.elementsEqual(document.utf8) else { return nil }
                index = currentIndex
            }
            let evidence = SagaReadEvidence(readSource: .axTrackName, provenance: .liveIndependent,
                trackIndex: index, projectReference: projectRef.rawValue, field: "name",
                observed: .string(name), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
            return .init(value: .string(name), evidence: evidence.summary, read: evidence)
        }
        guard supports(step), let (value, _) = await reading() else { return nil }
        let evidence = SagaReadEvidence(readSource: .axProjectMixerVisibility, provenance: .liveIndependent,
            trackIndex: nil, projectReference: (sortProject ?? projectRef).rawValue, field: "mixer_visible",
            observed: .bool(value), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        return .init(value: .bool(value), evidence: evidence.summary, read: evidence)
    }

    private func heldOutputProof(_ pair: AccessibilityChannel.HeldSelectionAssociation.Pair,
                                 restorationBaseline: AccessibilityChannel.HeldSelectionAssociation? = nil) -> AccessibilityChannel.HeldSelectionAssociation? {
        guard let task = nameFootprintTask,
              pair.track.matches(task.pair.track), pair.track.currentIndex() != nil,
              let proof = AccessibilityChannel.HeldSelectionAssociation(window: pair.track.window,
                logic: pair.track.runtime, expectedProject: nil, requiresProjectReference: false,
                allowsSelectedChildRailEntry: true, restorationBaseline: restorationBaseline),
              CFEqual(proof.headers[proof.originalIndex], pair.track.header),
              CFEqual(proof.mixer, pair.strip.mixer),
              proof.document.utf8.elementsEqual(document.utf8),
              proof.strips.filter({ CFEqual($0, pair.strip.strip) }).count == 1,
              proof.permitsRead() else { return nil }
        return proof
    }

    /// Preserve every captured field and peer owner. Only this task's independently checked
    /// output may differ. Unrequested unknown routing displays need two fresh agreeing
    /// observations; no already-known field or native source may become a new baseline.
    private func outputFootprintHeld(pair: AccessibilityChannel.HeldSelectionAssociation.Pair,
                                     assignment: OutputAssignment, popup: AXUIElement? = nil,
                                     ownedNamePreview: [String]? = nil, ownedNameEditor: AXUIElement? = nil,
                                     ownedStripNamePreview: [String]? = nil,
                                     verifiedNameEffect: ExactTrackNameAdapter.VerifiedNameEffect? = nil,
                                     taskOverride: OutputTask? = nil,
                                     ownedSendChange: AccessibilityChannel.ChangedSendObservation? = nil) -> Bool {
        outputPeerReadbackUnavailable = false
        var stage = "retained_task", accepted = false
        defer {
            if !accepted, popup != nil || taskOverride != nil {
                Log.info("Canonical output footprint refused at \(stage)", subsystem: "saga")
            }
        }
        guard let task = taskOverride ?? nameFootprintTask, let proof = outputProof else { return false }
        let runtime = pair.track.runtime
        @Sendable func permitted() -> Bool {
            guard let proof = self.outputProof else { return false }
            if let editor = ownedNameEditor, let names = ownedNamePreview {
                return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                    && ExactTrackNameAdapter.permitsCoupledEditorRead(editor, pair: pair, names: names, transportProof: proof)
            }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                && (popup.map { proof.permitsOwnedPopupRead($0,
                    nativeSource: assignment == .noOutput ? pair.strip : nil) } ?? proof.permitsRead())
        }
        stage = "initial_custody"
        guard permitted(), pair.track.matches(task.pair.track),
              outputRenewal.map { renewal in
                  renewal.pair.strip.matches(pair.strip) && renewal.pair.track.matches(task.pair.track)
                      && (ownedNameEditor != nil || renewal.permits(runtime: runtime, ownedPopup: popup,
                        nativeOutputPopup: assignment == .noOutput))
              } ?? true,
              proof.headers.count == task.capture.tracks.count,
              zip(proof.headers, task.capture.tracks).allSatisfy({ header, row in
                  row.physicalBinding.map { CFEqual($0.header, header) } == true
              }) else { return false }
        // Non-Help rows share the fresh complete custody bookends below/above.
        // Keep cancellation/gate/deadline checks per row and full fresh custody
        // before every actual Help read, rather than recensus the whole host per row.
        let metadataStopped: @Sendable () -> Bool = {
            (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil
        }
        func sampleFields() -> ([TrackState]?, [ChannelStripState]?) {
            return AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: { !permitted() })) {
                let tracks = AccessibilityChannel.readTrackStates(from: proof.headers, in: pair.track.window,
                    runtime: runtime, readingTypeHelp: false, stoppingWhen: metadataStopped).states
                let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: pair.strip.mixer, runtime: runtime.ax)
                    .flatMap { AccessibilityChannel.readChannelStrips(from: $0.strips, runtime: runtime,
                        window: pair.strip.window, mixer: pair.strip.mixer, readingScalarHelp: false,
                        stoppingWhen: metadataStopped) }
                return (tracks, strips)
            }
        }
        let fields = sampleFields()
        stage = "sampled_owners_counts_output"
        guard let tracks = fields.0, let strips = fields.1, permitted(),
              tracks.count == task.capture.tracks.count,
              zip(tracks, task.capture.tracks).allSatisfy({ current, original in
                  // JSON intentionally omits native custody. A later restored
                  // scope cannot authenticate an earlier foreign/unknown sample.
                  // This non-navigating reader does not create a new exposure;
                  // preserve the original lifetime instead of adopting another.
                  guard let owner = original.physicalBinding, let observed = current.physicalBinding,
                        owner.exposure?.isCurrent ?? true else { return false }
                  return CFEqual(observed.window, owner.window) && CFEqual(observed.header, owner.header)
                      && observed.document.utf8.elementsEqual(owner.document.utf8)
              }),
              strips.count == task.capture.channelStrips.count,
              let index = task.capture.channelStrips.firstIndex(where: { $0.physicalBinding?.matches(task.pair.strip) == true }),
              strips[index].physicalBinding?.matches(pair.strip) == true,
              strips[index].output.flatMap(OutputAssignment.observed(slotLabel:)) == assignment else { return false }
        if let renewal = outputRenewal {
            stage = "renewed_census"
            // This owned original-header receipt holds the entire new census.
            // It corroborates aggregate preserved values; it neither rebinds
            // retired peer references nor grants any peer mutation authority.
            guard strips.count == renewal.observation.strips.count,
                  zip(strips, renewal.observation.strips).allSatisfy({ row, held in
                      row.physicalBinding?.matches(.init(window: renewal.pair.strip.window,
                          mixer: renewal.pair.strip.mixer, strip: held, document: renewal.pair.strip.document)) == true
                  }) else { return false }
        }
        for row in strips.indices {
            stage = "protected_scalars_plugins_\(row)"
            if outputRenewal == nil, row != index,
               strips[row].physicalBinding?.matches(task.capture.channelStrips[row].physicalBinding ?? pair.strip) != true { return false }
            guard strips[row].volumeReadback == task.capture.channelStrips[row].volumeReadback,
                  strips[row].panReadback == task.capture.channelStrips[row].panReadback,
                  strips[row].volumeReadback != nil, strips[row].panReadback != nil,
                  strips[row].pluginsFullyObserved == true else {
                if taskOverride != nil {
                    Log.info("Canonical Send protected row \(row): volume_read=\(strips[row].volumeReadback != nil),volume_held=\(task.capture.channelStrips[row].volumeReadback != nil),volume_equal=\(strips[row].volumeReadback == task.capture.channelStrips[row].volumeReadback),pan_read=\(strips[row].panReadback != nil),pan_held=\(task.capture.channelStrips[row].panReadback != nil),pan_equal=\(strips[row].panReadback == task.capture.channelStrips[row].panReadback),plugins_read=\(strips[row].pluginsFullyObserved == true)", subsystem: "saga")
                }
                return false
            }
        }
        var expected = task.capture.channelStrips
        if assignment != task.before { expected[index].output = strips[index].output }
        if let ownedSendChange {
            stage = "owned_send_effect"
            guard taskOverride != nil, let sendTask,
                  ownedSendChange.checkedBefore == sendTask.before,
                  ownedSendChange.checkedAfter == sendTask.desired,
                  ownedSendChange.source.pair.track.matches(pair.track),
                  let captured = expected[index].sendSlots, let current = strips[index].sendSlots,
                  AccessibilityChannel.ChangedSendObservation.protectedSlots(captured, ordinal: sendTask.ordinal)
                    == AccessibilityChannel.ChangedSendObservation.protectedSlots(ownedSendChange.footprint, ordinal: sendTask.ordinal),
                  current == ownedSendChange.footprint else { return false }
            // Only the already-owned destination display can differ. All
            // scalars, slots, peer fields and the fresh checked menu stay exact.
            expected[index].sendSlots = captured.map { slot in
                var value = slot
                if slot.ordinal == sendTask.ordinal {
                    value.destinationDisplay = current.first { $0.ordinal == slot.ordinal }?.destinationDisplay
                }
                return value
            }
        }
        var expectedTrackRows = task.capture.tracks
        func effectMatchesSource(_ effect: ExactTrackNameAdapter.VerifiedNameEffect) -> Bool {
            if effect.matches(pair) { return true }
            // A name receipt predates this plan's own output replacement. Only
            // its original-header renewal can carry those frozen name bytes to
            // the new source; labels and equal ordinals cannot establish it.
            guard let renewal = outputRenewal,
                  renewal.original.matches(task.pair.strip),
                  renewal.pair.track.matches(pair.track), renewal.pair.strip.matches(pair.strip),
                  effect.matches(.init(track: renewal.originalTrack, strip: renewal.original)) else { return false }
            return renewal.permits(runtime: runtime, ownedPopup: popup)
        }
        if let effect = verifiedNameEffect {
            guard effectMatchesSource(effect),
                  let goal = changedNameGoals.first(where: { $0.reference == task.reference }),
                  let row = expectedTrackRows.firstIndex(where: { $0.physicalBinding?.matches(goal.binding) == true }),
                  [goal.before, goal.name].contains(where: { effect.trackName.utf8.elementsEqual($0.utf8) }),
                  [goal.before, goal.name].contains(where: { effect.stripName.utf8.elementsEqual($0.utf8) }),
                  tracks[row].name.utf8.elementsEqual(effect.trackName.utf8),
                  strips[index].name?.utf8.elementsEqual(effect.stripName.utf8) == true else { return false }
            expectedTrackRows[row].name = effect.trackName
            expected[index].name = effect.stripName
        } else if let allowed = ownedNamePreview {
            let stripAllowed = ownedStripNamePreview ?? allowed
            guard let goal = changedNameGoals.first(where: { $0.reference == task.reference }),
                  allowed.allSatisfy({ $0.utf8.elementsEqual(goal.before.utf8) || $0.utf8.elementsEqual(goal.name.utf8) }),
                  stripAllowed.allSatisfy({ $0.utf8.elementsEqual(goal.before.utf8) || $0.utf8.elementsEqual(goal.name.utf8) }),
                  let row = expectedTrackRows.firstIndex(where: { $0.physicalBinding?.matches(goal.binding) == true }),
                  allowed.contains(where: { tracks[row].name.utf8.elementsEqual($0.utf8) }),
                  let stripName = strips[index].name,
                  stripAllowed.contains(where: { stripName.utf8.elementsEqual($0.utf8) }) else { return false }
            // The existing writer alone admits its exact name preview. All
            // non-name fields and every peer still match the captured baseline.
            expectedTrackRows[row].name = tracks[row].name
            expected[index].name = stripName
        } else if let goal = changedNameGoals.first(where: { $0.reference == task.reference }),
           let execution = nameExecutions[goal.reference] {
            // Only this adapter's actual coupled-name receipt may revise the
            // protected baseline. Current labels never manufacture that receipt.
            if let receipt = execution.inverse ?? execution.restored {
                guard let effect = ExactTrackNameAdapter.recordedNameEffect(receipt), effectMatchesSource(effect),
                      effect.trackName.utf8.elementsEqual((execution.inverse != nil ? goal.name : goal.before).utf8),
                      let row = expectedTrackRows.firstIndex(where: { $0.physicalBinding?.matches(goal.binding) == true }) else { return false }
                expectedTrackRows[row].name = effect.trackName
                expected[index].name = effect.stripName
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        stage = "encoded_values"
        guard let expectedTracks = try? encoder.encode(expectedTrackRows),
              let currentTracks = try? encoder.encode(tracks),
              let expectedStrips = try? encoder.encode(expected), let currentStrips = try? encoder.encode(strips) else { return false }
        var valuesAgree = expectedTracks == currentTracks && expectedStrips == currentStrips
        if !valuesAgree, expectedTracks == currentTracks, taskOverride != nil, let sendTask,
           case .bus = sendTask.before, case .bus? = sendTask.desired,
           changedNameGoals.count == 1, outputRenewal != nil {
            // This bounded named Send owns only its source. Protect every captured
            // selected/checked row through the already-validated ordered renewal;
            // a newly readable peer supplies no receiver or write authority.
            var protected = [task.pair.strip, pair.strip]
            if let population = task.capture.freshPopulation {
                protected += population.selectionAssociations.map(\.strip)
                protected += population.checkedOutputs.map(\.source)
                protected += population.checkedInputs.map(\.receiver)
            }
            for row in expected.indices {
                if let owner = expected[row].physicalBinding,
                   protected.contains(where: { $0.matches(owner) }), let current = strips[row].physicalBinding {
                    protected.append(current)
                }
            }
            if AccessibilityChannel.onlyPeerDisplaysBecameReadable(before: expected, after: strips, protecting: protected) {
                stage = "corroborating_peer_displays"
                let corroborated = sampleFields()
                guard let nextTracks = corroborated.0, let nextStrips = corroborated.1, permitted(),
                      nextTracks.count == tracks.count, nextStrips.count == strips.count,
                      (try? encoder.encode(nextTracks)) == currentTracks,
                      (try? encoder.encode(nextStrips)) == currentStrips,
                      zip(tracks, nextTracks).allSatisfy({ old, new in
                          guard let a = old.physicalBinding, let b = new.physicalBinding,
                                a.exposure?.isCurrent ?? true, b.exposure?.isCurrent ?? true else { return false }
                          return a.matches(b)
                      }),
                      zip(strips, nextStrips).allSatisfy({ old, new in
                          guard let owner = old.physicalBinding, new.physicalBinding?.matches(owner) == true,
                                old.volumeReadback == new.volumeReadback, old.panReadback == new.panReadback,
                                new.pluginsFullyObserved == true else { return false }
                          switch (old.inputSlotBinding, new.inputSlotBinding) {
                          case (nil, nil): return true
                          case (.some(let a), .some(let b)): return a.matches(b)
                          default: return false
                          }
                      }) else { return false }
                valuesAgree = true
            }
        }
        if !valuesAgree {
            // Compare already-sampled schema fields only; no extra host reads
            // or value/name disclosure, and no acceptance change.
            var changed: [String] = []
            var onlyMissingPeerRouting = expectedTracks == currentTracks
            var missingPeerRouting = false
            for (domain, oldData, newData) in [("tracks", expectedTracks, currentTracks), ("strips", expectedStrips, currentStrips)] {
                guard let old = try? JSONSerialization.jsonObject(with: oldData) as? [[String: Any]],
                      let new = try? JSONSerialization.jsonObject(with: newData) as? [[String: Any]] else {
                    onlyMissingPeerRouting = false; continue
                }
                for (row, pair) in zip(old, new).enumerated() {
                    let keys = Set(pair.0.keys).union(pair.1.keys).filter {
                        (pair.0[$0] as? NSObject)?.isEqual(pair.1[$0]) != true
                    }.sorted()
                    if !keys.isEmpty {
                        if changed.count < 4 { changed.append("\(domain)[\(row)]:\(keys.joined(separator: ","))") }
                        missingPeerRouting = true
                        guard domain == "strips", row != index else { onlyMissingPeerRouting = false; continue }
                        for key in keys {
                            switch key {
                            case "output":
                                if expected[row].output.flatMap(OutputAssignment.observed(slotLabel:)) == nil
                                    || strips[row].output.flatMap(OutputAssignment.observed(slotLabel:)) != nil {
                                    onlyMissingPeerRouting = false
                                }
                            case "input", "input_observation":
                                if expected[row].input == nil || strips[row].input != nil { onlyMissingPeerRouting = false }
                            default: onlyMissingPeerRouting = false
                            }
                        }
                    }
                }
            }
            // This permits only another owned UI observation, never acceptance
            // of unknown fields. Every captured value must match on the reread.
            outputPeerReadbackUnavailable = missingPeerRouting && onlyMissingPeerRouting
            Log.info("Canonical output footprint fields changed: \(changed.joined(separator: ";"))", subsystem: "saga")
            return false
        }
        stage = "final_custody"
        guard permitted(),
              ownedNameEditor != nil || (outputRenewal.map { $0.permits(runtime: runtime, ownedPopup: popup,
                nativeOutputPopup: assignment == .noOutput) } ?? true),
              pair.strip.currentIndex(runtime: runtime) == index,
              case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(pair.strip.window, runtime: runtime),
              finalDocument.utf8.elementsEqual(document.utf8) else { return false }
        if let editor = ownedNameEditor {
            accepted = ExactTrackNameAdapter.coupledWriteFocusMatches(editor, runtime: runtime)
            return accepted
        }
        accepted = true
        return true
    }

    /// Bus output or restoration needs current checked prerequisites, not capture-time
    /// captions. These read-only menus run before forward/inverse ownership is
    /// established; neither an input write nor receiver creation is authorized.
    private func busOutputInputsCurrent(
        inputFocus: AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope
    ) async -> Bool {
        guard let task = outputTask, !task.prerequisiteBuses.isEmpty else { return true }
        var stage = "captured_source", accepted = false
        defer {
            if !accepted { Log.info("Canonical Bus prerequisite refused at \(stage)", subsystem: "saga") }
        }
        let pair = outputPair ?? task.pair, runtime = pair.track.runtime
        stage = "entry_footprint"
        guard let label = AXLogicProElements.outputSlotDestination(in: pair.strip.strip, runtime: runtime.ax),
              let assignment = OutputAssignment.observed(slotLabel: label),
              assignment == task.before || (outputAttempted && assignment == task.desired),
              outputFootprintHeld(pair: pair, assignment: assignment) else { return false }
        guard let source = task.capture.channelStrips.first(where: {
            $0.physicalBinding?.matches(task.pair.strip) == true
        }), let own = source.inputObservation else { return false }
        switch own.state {
        case .unreadable: return false
        case .noSlot:
            stage = "source_absence"
            guard AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax).reading == .noSlot else { return false }
        case .observedSource:
            stage = "source_checked_baseline"
            let held = task.capture.freshPopulation?.checkedInputs.filter { $0.receiver.matches(task.pair.strip) } ?? []
            guard held.count == 1, case .physical? = held.first?.assignment,
                  let expected = held.first?.assignment,
                  let original = source.inputSlotBinding else { return false }
            stage = "source_native_slot"
            let slot = AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax)
            guard let control = slot.control, case .source(let label) = slot.reading,
                  label.utf8.elementsEqual(original.source.utf8),
                  !pair.strip.matches(task.pair.strip) || CFEqual(control, original.control) else { return false }
            let current = AXMixerInputSlotBinding(owner: pair.strip, control: control, source: label)
            let read = await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                    await AccessibilityChannel.getCheckedInputObservation(runtime: runtime,
                        observingPopupFocus: { inputFocus.retainRoutingPopupFocus($0) },
                        observingRenewedFocus: { inputFocus.retainAssociation($0) })
                }
            }
            stage = "source_checked_read"
            guard read.inputAssignment == expected else {
                Log.info("Canonical Bus input read: assignment_present=\(read.inputAssignment != nil),slot_present=\(read.inputSlot != nil),renewed=\(read.inputRenewal != nil)", subsystem: "saga")
                return false
            }
            if let renewal = read.inputRenewal {
                stage = "source_input_renewal"
                guard renewal.original.matches(pair.strip), renewal.originalTrack.matches(task.pair.track),
                      renewal.pair.track.matches(task.pair.track), renewal.permits(runtime: runtime),
                      let renewed = read.inputSlot, renewed.owner.matches(renewal.pair.strip),
                      renewed.source.utf8.elementsEqual(original.source.utf8) else { return false }
                outputPair = renewal.pair; outputRenewal = renewal; outputProof = renewal.observation
            } else {
                stage = "source_input_control"
                guard read.inputSlot?.matches(current) == true else { return false }
            }
        }
        // Observe current positive receivers through the owned original-header
        // census. A menu can retire all strips, not just its own source. These
        // native pairs supply read custody only; no cached reference is rebound.
        if outputRenewal?.observedPairs.isEmpty != false {
            stage = "receiver_header_observation"
            let current = outputPair ?? task.pair
            let observed = await AccessibilityChannel.renewSourceThroughOriginalHeader(current, original: current.strip,
                runtime: runtime, sourceDisposition: .survivingOriginal,
                observingReadFocus: { inputFocus.retainAssociation($0) })
            guard let renewal = observed.source, renewal.permits(runtime: runtime) else { return false }
            outputPair = renewal.pair; outputRenewal = renewal; outputProof = renewal.observation
        }
        for bus in task.prerequisiteBuses {
            // A checked input excursion can retire the full native census. Each
            // distinct Bus uses the latest actual original-header observation.
            guard let roster = outputRenewal, roster.permits(runtime: runtime) else { return false }
            var receiverVerified = false
            for receiver in roster.observedPairs {
                let owner = receiver.strip
                guard !receiver.track.matches(task.pair.track),
                      roster.observedPairs.filter({ $0.strip.matches(owner) }).count == 1 else { continue }
                stage = "receiver_owner"
                guard owner.currentIndex(runtime: runtime) != nil else { return false }
                let current = AXLogicProElements.inputSlotRead(in: owner.strip, runtime: runtime.ax)
                guard case .source(let label) = current.reading, let control = current.control,
                      RoutingGraphPublication.classifyOutputLabel(label).0 == .bus,
                      RoutingGraphPublication.classifyOutputLabel(label).1 == bus else { continue }
                let slot = AXMixerInputSlotBinding(owner: owner, control: control, source: label)
                let read = await AXMixerStripBinding.$current.withValue(owner) {
                    await AXMixerStripBinding.$outputAssociation.withValue(receiver) {
                        await AccessibilityChannel.getInputBusObservation(runtime: runtime, requiringOriginalInputControl: slot,
                            observingPopupFocus: { inputFocus.retainRoutingPopupFocus($0) },
                            observingRenewedFocus: { inputFocus.retainAssociation($0) })
                    }
                }
                stage = "receiver_checked_read"
                guard read.assignment == .bus(bus) else {
                    Log.info("Canonical Bus receiver read: assignment_present=\(read.assignment != nil),slot_present=\(read.inputSlot != nil),renewed=\(read.inputRenewal != nil)", subsystem: "saga")
                    return false
                }
                if let renewal = read.inputRenewal {
                    stage = "receiver_original_header_renewal"
                    guard renewal.original.matches(owner), renewal.originalTrack.matches(receiver.track),
                          read.inputSlot?.owner.matches(renewal.pair.strip) == true,
                          let primary = renewal.sourceForOriginalHeader(task.pair, runtime: runtime) else { return false }
                    outputPair = primary.pair; outputRenewal = primary; outputProof = primary.observation
                } else {
                    guard read.inputSlot?.matches(slot) == true, owner.currentIndex(runtime: runtime) != nil else { return false }
                }
                stage = "final_project"
                guard await projectIsCurrent(allowPendingCancellation: true) else { return false }
                receiverVerified = true
                break
            }
            guard receiverVerified else { stage = "no_retained_receiver"; return false }
        }
        accepted = true
        return true
    }

    private func outputReading() async -> OutputAssignment? {
        var stage = "initial_context", accepted = false
        defer {
            if !accepted, let task = outputTask, case .bus = task.before {
                Log.info("Canonical Bus output reading refused at \(stage)", subsystem: "saga")
            }
        }
        guard let task = nameFootprintTask, await projectIsCurrent(allowPendingCancellation: true),
              let target = await registry.resolve(task.reference), target.kind == .track,
              target.physicalTrack?.matches(task.pair.track) == true else { return nil }
        var pair = outputPair ?? task.pair
        let runtime = pair.track.runtime
        stage = "initial_native_proof"
        guard let proof = heldOutputProof(pair) else { return nil }
        outputProof = proof
        if !outputGeometrySampled, outputTask?.prerequisiteBuses.isEmpty == false, changedNameGoals.isEmpty {
            // Earlier owned input excursions may move the custom Mixer canvas.
            // Its first native geometry remains the restoration duty, never a
            // peer identity or a later replacement baseline. An unread first
            // sample stays unavailable rather than being retried after a move.
            outputGeometrySampled = true
            outputOriginalMixerGeometry = proof.observedMixerViewportGeometry()
            if let first = outputOriginalMixerGeometry?.frames.first {
                Log.info("Canonical output restoration baseline retained: first_x=\(first.minX)", subsystem: "saga")
            }
        }
        let originalMixerGeometry = outputOriginalMixerGeometry
        if let outputTask, !outputTask.prerequisiteBuses.isEmpty {
            stage = "input_prerequisites"
            let inputFocus = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
            guard await AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: { [self] in
                // The reader publishes only its exact owned search path and
                // clears it on exit. Check that temporary custody before an
                // original-focus proof that irreversibly records focus loss.
                !inputFocus.permits() && outputProof?.permitsRead() != true
            }), operation: { [self] in await busOutputInputsCurrent(inputFocus: inputFocus) }) else { return nil }
            // The input reader may legitimately renew this original header's
            // source. Its receipt is not a replacement for fresh native proof.
            pair = outputPair ?? task.pair
            stage = "native_proof_after_inputs"
            guard let renewedProof = heldOutputProof(pair) else { return nil }
            outputProof = renewedProof
        }
        stage = "checked_output_and_footprint"
        let reading = await AXMixerStripBinding.$current.withValue(pair.strip) {
            await AccessibilityChannel.getOutputObservation(runtime: runtime)
        }
        guard let assignment = reading.assignment,
              assignment == task.before || (outputAttempted && assignment == task.desired) else { return nil }
        if !outputFootprintHeld(pair: pair, assignment: assignment) {
            stage = "unavailable_peer_recovery"
            guard outputPeerReadbackUnavailable, changedNameGoals.isEmpty,
                  let originalMixerGeometry, let currentProof = outputProof,
                  await currentProof.recoverMixerReadability(restoring: originalMixerGeometry,
                    referenceIsCurrent: { [self] in
                        guard await projectIsCurrent(allowPendingCancellation: true),
                              let target = await registry.resolve(task.reference), target.kind == .track,
                              target.physicalTrack?.matches(task.pair.track) == true else { return false }
                        return true
                    }, stoppingWhen: {
                        (try? SessionPopulationObservation.requireOwnedAcquisition()) == nil
                    }) else { return nil }
            // Recovery is another causal UI excursion. Its refreshed captions
            // cannot authenticate the checkmark sampled before that excursion.
            stage = "checked_output_after_recovery"
            let recoveredReading = await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AccessibilityChannel.getOutputObservation(runtime: runtime)
            }
            guard recoveredReading.assignment == assignment,
                  outputFootprintHeld(pair: pair, assignment: assignment) else { return nil }
        }
        guard
              await projectIsCurrent(allowPendingCancellation: true) else { return nil }
        accepted = true
        return assignment
    }

    private func readOutputState(_ step: SagaStep) async -> ObservedState? {
        guard supports(step), let task = outputTask, let assignment = await outputReading() else { return nil }
        if changedNameGoals.isEmpty {
            // The existing Saga's independent readback establishes whether our
            // attempted output is applied; a scalar acknowledgement does not.
            outputApplied = outputAttempted && assignment == task.desired
        }
        let evidence = SagaReadEvidence(readSource: .axOutputMenuCheckmark, provenance: .liveIndependent,
            trackIndex: task.pair.track.currentIndex(), projectReference: projectRef.rawValue, field: "output",
            observed: .string(assignment.token), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        return .init(read: evidence)
    }

    func performOutput(_ step: SagaStep, router: ChannelRouter) async -> CallTool.Result {
        guard let task = outputTask, supports(step) else { return toolStateCResult(.unsupportedState, extras: ["write_attempted": false]) }
        let inverse = outputAttempted
        let expected = inverse ? task.desired : task.before
        let desired = inverse ? task.before : task.desired
        guard (!inverse || (outputApplied && !outputInverseConsumed)),
              step.params["destination"] == .string(desired.token) else {
            return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
        }
        if changedNameGoals.isEmpty {
            // The Saga just read the owned before-state. The scalar writer
            // independently checks expected_current and the full protected
            // footprint at its final leaf boundary; do not repeat that scan.
            guard outputProof?.permitsRead() == true else {
                Log.info("Canonical output refused: retained before-read custody expired", subsystem: "saga")
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
        } else {
            guard let before = await outputReading(), before == expected else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
        }
        guard await projectIsCurrent(allowPendingCancellation: inverse) else {
            Log.info("Canonical output refused: project or operation custody changed before routing", subsystem: "saga")
            return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
        }
        let pair = outputPair ?? task.pair, runtime = pair.track.runtime
        guard let index = pair.strip.currentIndex(runtime: runtime) else {
            Log.info("Canonical output refused: retained source is no longer uniquely current", subsystem: "saga")
            return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
        }
        if inverse { outputInverseConsumed = true }
        let response = await Self.$outputLeafPermission.withValue({ [self] popup in
            outputFootprintHeld(pair: pair, assignment: expected, popup: popup)
        }) {
            await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                    await Self.$current.withValue(self) {
                        await OperationTraceWriteBoundaryArm.armed(OperationTraceContext.current?.traceID) {
                            await routedTextResult(router, operation: "mixer.set_output_verified",
                                params: ["index": String(index), "destination": desired.token, "expected_current": expected.token])
                        }
                    }
                }
            }
        }
        let text = sharedOutputText(response)
        guard let body = decodedJSONObject(text), body["write_attempted"] as? Bool == true else { return response }
        outputAttempted = true
        var renewedThisOutput: AccessibilityChannel.OriginalHeaderSourceRenewal?
        let priorCensus = outputRenewal?.observation.strips
            ?? task.capture.channelStrips.compactMap { $0.physicalBinding?.strip }
        let currentCensus = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: pair.strip.mixer, runtime: runtime.ax)?.strips
        let sourceRetired = pair.strip.currentIndex(runtime: runtime) == nil
        // A committed output can redraw an existing peer without retiring the
        // source. Renew only through the original header and its actual inverse;
        // the unchanged protected-value comparison still decides acceptance.
        // A response that is still State B can have crossed the actual write
        // boundary. Renew observation as for a retired source; only the fresh
        // checked assignment and protected footprint can establish its effect.
        let peerRedrawn = !sourceRetired
            && priorCensus.count == task.capture.channelStrips.count
            && currentCensus.map { current in
                current.count == priorCensus.count
                    && !zip(current, priorCensus).allSatisfy { CFEqual($0, $1) }
            } == true
        if sourceRetired || peerRedrawn {
            let renewal = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair, original: pair.strip, runtime: runtime,
                sourceDisposition: sourceRetired ? .retiredOriginal : .survivingOriginal)
            guard let owned = renewal.source, owned.permits(runtime: runtime) else {
                return toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: ["write_attempted": true]), isError: true)
            }
            outputPair = owned.pair
            outputRenewal = owned
            renewedThisOutput = owned
        }
        // A single-output step is verified by the Saga's mandatory independent
        // read below. Coupled naming retains its separate renewal/read contract.
        if changedNameGoals.isEmpty { return response }
        if let after = await outputReading(), after == desired {
            if let renewal = renewedThisOutput,
               let goal = changedNameGoals.first(where: { $0.reference == task.reference }),
               let nameProof = nameExecutions[goal.reference]?.inverse {
                guard let renewed = await ExactTrackNameAdapter.renewingOwnedCoupledName(nameProof, through: renewal) else {
                    return toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: ["write_attempted": true]), isError: true)
                }
                nameExecutions[goal.reference, default: .init()].inverse = renewed
            }
            outputApplied = !inverse
        }
        return response
    }

    private func sharedOutputText(_ response: CallTool.Result) -> String {
        if case .text(let text, _, _) = response.content.first { return text }
        return ""
    }

    var verifiesMatchingNamesOnly: Bool { !nameGoals.isEmpty && mixerTask == nil && inputTask == nil && plan.steps.isEmpty }
    var verifiesReceiverKeepsOnly: Bool { !receiverKeeps.isEmpty && nameGoals.isEmpty && mixerTask == nil && plan.steps.isEmpty }
    var verifiesMatchingSendOnly: Bool { sendTask.map { $0.desired == $0.before } == true && plan.steps.isEmpty }
    var hasMatchingInputGoal: Bool { inputTask.map { $0.desired == $0.before } ?? false }
    var verifiesMatchingInputOnly: Bool { hasMatchingInputGoal && plan.steps.isEmpty }
    var verifiesMatchingSortOnly: Bool {
        sortTask.map { $0.before == $0.policy.expectedOrder } == true && mixerTask == nil && plan.steps.isEmpty
    }
    var hasMatchingNameGoals: Bool { !nameGoals.isEmpty }

    /// The same issued-name proof is used before a composed forward action and
    /// for the final whole-goal receipt. It never supplies inverse permission.
    var hasMixerGoal: Bool { mixerTask != nil }

    func nameGoalEvidence(requiringMixerGoal: Bool = false, afterExecution: Bool = false) async -> [[String: Any]]? {
        guard hasMatchingNameGoals, FeatureFlags.adr004MutationSaga,
              await projectIsCurrent(), await registry.resolveCurrentProject(projectRef) != nil else {
            return nil
        }
        func independentRead(_ goal: NameGoal) async -> SagaReadEvidence? {
            let expected = afterExecution ? goal.name : goal.before
            guard await projectIsCurrent(),
                  let target = await registry.resolve(goal.reference), target.kind == .track,
                  target.physicalTrack?.matches(goal.binding) == true,
                  target.descriptor.trackName.utf8.elementsEqual(expected.utf8),
                  let index = goal.binding.currentIndex(),
                  case .success(let name?) = AXValueExtractors.extractTrackNameResult(
                    from: goal.binding.header, runtime: goal.binding.runtime.ax),
                  name.utf8.elementsEqual(expected.utf8),
                  goal.binding.currentIndex() == index,
                  let after = await registry.resolve(goal.reference), after.physicalTrack?.matches(goal.binding) == true,
                  await projectIsCurrent(), originalSelectionHeld() else {
                return nil
            }
            if let capture = renameCapture,
               goal.mixerRef != nil || changedNameGoals.contains(where: { $0.reference == goal.reference }) {
                let observed: String?
                if afterExecution, let proof = nameExecutions[goal.reference]?.inverse {
                    // Track-origin aliases may leave the Mixer name unchanged.
                    // An explicitly approved Mixer-origin coupled_after may not.
                    // Frozen receipt data is corroborated by the native read below;
                    // it cannot turn an unsatisfied Mixer goal into completion.
                    if goal.mixerRef != nil {
                        guard let effect = ExactTrackNameAdapter.recordedNameEffect(proof),
                              effect.stripName.utf8.elementsEqual(expected.utf8) else { return nil }
                    }
                    observed = await ExactTrackNameAdapter.readOwnedCoupledName(proof, ownedPeerEffects: ownedNameEffects)
                } else {
                    observed = await ExactTrackNameAdapter.readCapturedCoupledName(nameAction(goal),
                        capture: capture, registry: registry, capturedRead: nameExecutions[goal.reference]?.capturedRead,
                        ownedPeerEffects: afterExecution ? ownedNameEffects : [])
                }
                guard let coupled = observed,
                    coupled.utf8.elementsEqual(expected.utf8),
                    await projectIsCurrent() else { return nil }
            }
            return SagaReadEvidence(readSource: .axTrackName, provenance: .liveIndependent,
                trackIndex: index, projectReference: projectRef.rawValue, field: "name",
                observed: .string(name), sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        }
        // Bookend the entire approved set, not just each row: a later deciding
        // read must not silently invalidate an earlier row's name or object.
        var before: [SagaReadEvidence] = []
        for goal in nameGoals {
            guard let read = await independentRead(goal) else {
                return nil
            }
            before.append(read)
        }
        if requiringMixerGoal {
            guard let task = mixerTask, let observed = await reading(), observed.0 == task.desired else { return nil }
        }
        var evidence: [[String: Any]] = []
        for (offset, goal) in nameGoals.enumerated() {
            guard let read = await independentRead(goal),
                  let first = before[offset].observed.stringValue,
                  read.observed.stringValue?.utf8.elementsEqual(first.utf8) == true else {
                return nil
            }
            guard let data = try? JSONEncoder().encode(read),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let beforeData = try? JSONEncoder().encode(before[offset]),
                  let beforeObject = try? JSONSerialization.jsonObject(with: beforeData) else {
                return nil
            }
            evidence.append(["target_ref": goal.reference.rawValue, "before": beforeObject, "read": object])
        }
        if requiringMixerGoal {
            guard let task = mixerTask, let observed = await reading(), observed.0 == task.desired else { return nil }
        }
        guard await projectIsCurrent(), await registry.resolveCurrentProject(projectRef) != nil,
              originalSelectionHeld() else {
            return nil
        }
        return evidence
    }

    func performName(_ step: SagaStep, router: ChannelRouter,
        restoredInput: AccessibilityChannel.ChangedInputObservation? = nil) async -> CallTool.Result {
        guard supports(step), let goal = changedNameGoals.first(where: { $0.reference == step.targetRef }),
              let capture = renameCapture else {
            return toolStateCResult(.unsupportedState, extras: ["write_attempted": false])
        }
        let execution = nameExecutions[goal.reference]
        let restoring = execution?.ran == true && execution?.inverse != nil && step.params["name"] == .string(goal.before)
        guard await projectIsCurrent(allowPendingCancellation: restoring) else {
            return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
        }
        let runtime = goal.binding.runtime
        let preserving: (@Sendable (Bool, AXUIElement?) -> Bool)?
        let afterVerifiedWrite: ExactTrackNameAdapter.PostVerifiedWrite?
        if let task = nameFootprintTask {
            guard await outputReading() == task.before else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
            let beforeName = restoring ? goal.name : goal.before
            let afterName = restoring ? goal.before : goal.name
            let baseline = outputProof
            let previousEffect = execution?.inverse.flatMap(ExactTrackNameAdapter.recordedNameEffect)
            preserving = { [self] preview, editor in
                let pair = outputPair ?? task.pair
                if restoring, previousEffect?.matches(pair) != true { return false }
                let names = preview ? [beforeName, afterName] : [beforeName]
                let stripNames = previousEffect.map { effect in
                    effect.stripName.utf8.elementsEqual(beforeName.utf8) ? names : [effect.stripName]
                }
                return outputFootprintHeld(pair: pair, assignment: task.before,
                    ownedNamePreview: names, ownedNameEditor: editor, ownedStripNamePreview: stripNames)
            }
            afterVerifiedWrite = { [self] transport, effect in
                let pair = outputPair ?? task.pair
                // The writer has already verified its own name effect. A pending
                // journal cancellation must not abandon this owned UI cleanup or
                // its inverse receipt; all native custody/gate/deadline checks stay.
                guard let effect, effect.matches(pair), effect.trackName.utf8.elementsEqual(afterName.utf8),
                      let baseline, await projectIsCurrent(allowPendingCancellation: true),
                      let renewed = heldOutputProof(pair, restorationBaseline: baseline) else { return false }
                if let source = outputRenewal {
                    // The verified own menu commit may move focus to the held
                    // rail. Continue the same native source/census with the new
                    // owner, never consult and then revive its prior focus proof.
                    guard source.pair.strip.matches(pair.strip), source.pair.track.matches(pair.track),
                          source.observation.strips.count == renewed.strips.count,
                          zip(source.observation.strips, renewed.strips).allSatisfy({ CFEqual($0, $1) }) else { return false }
                    outputRenewal = .init(pair: source.pair, index: source.index, original: source.original,
                        originalTrack: source.originalTrack, observation: renewed)
                }
                // This new owner validates the same original population and
                // old UI baseline. The old owner is never consulted/revived.
                outputProof = renewed
                guard outputFootprintHeld(pair: pair, assignment: task.before, verifiedNameEffect: effect),
                      await renewed.restoreCommittedFocus(source: pair.strip, expectedName: effect.stripName,
                        transport: transport, preservingFootprint: { [self] in
                            outputFootprintHeld(pair: pair, assignment: task.before, verifiedNameEffect: effect)
                        }, referenceIsCurrent: { [self] in
                          await projectIsCurrent(allowPendingCancellation: true)
                              && pair.track.currentIndex() != nil && pair.strip.currentIndex(runtime: runtime) != nil
                      }, stoppingWhen: { !ExactTrackNameAdapter.operationPermitted() }) else { return false }
                return true
            }
        } else { preserving = nil; afterVerifiedWrite = nil }
        let receipt: ExactTrackNameAdapter.Receipt
        if restoring, let proof = execution?.inverse {
            nameExecutions[goal.reference, default: .init()].inverse = nil
            nameExecutions[goal.reference, default: .init()].restoredInputControl = nil
            receipt = await ExactTrackNameAdapter.inverse(proof, router: router,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }, preservingFootprint: preserving,
                afterVerifiedWrite: afterVerifiedWrite)
            Log.info("Restored-name inverse receipt: status=\(receipt.status),proof_present=\(receipt.inverse != nil)", subsystem: "saga")
            nameExecutions[goal.reference, default: .init()].restored = receipt.inverse
            if receipt.status == .applied, let task = inputTask, let owned = restoredInput,
               goal.reference == task.reference {
                func unavailable(_ stage: String) -> CallTool.Result {
                    Log.info("Restored-name presentation refused at \(stage)", subsystem: "saga")
                    // A later scalar name read must not turn failed native
                    // presentation/protection verification into full compensation.
                    nameExecutions[goal.reference, default: .init()].restored = nil
                    nameExecutions[goal.reference, default: .init()].restoredInputControl = nil
                    return toolTextResult(HonestContract.encodeStateB(reason: .readbackUnavailable,
                        extras: ["write_attempted": true,
                            "hint": "The restored name's original input presentation could not be independently refreshed."]), isError: true)
                }
                let pair = owned.current
                guard let proof = receipt.inverse,
                      let effect = ExactTrackNameAdapter.recordedNameEffect(proof), effect.matches(pair),
                      pair.track.matches(goal.binding), owned.after == task.before, owned.permits(),
                      await projectIsCurrent(allowPendingCancellation: true) else { return unavailable("receipt_scope") }
                func aliases() -> [String] {
                    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute in
                        AXHelpers.getAttribute(pair.strip.strip, attribute as String, runtime: runtime.ax) as String?
                    }
                }
                // Logic can retain the forward name on the physical group/focus
                // after the inverse editor commit. Refresh only this observed
                // stale alias; redundant popup cycles can retire unrelated peers.
                if !effect.stripName.utf8.elementsEqual(goal.name.utf8),
                   aliases().contains(where: { $0.utf8.elementsEqual(goal.name.utf8) }) {
                    // The inverse input was already independently checked. Try
                    // the existing original-header presentation excursion first:
                    // another input popup can retire that verified native control.
                    let initial = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair,
                        original: pair.strip, runtime: runtime, sourceDisposition: .survivingOriginal)
                    guard let current = initial.source, current.pair.strip.matches(pair.strip),
                          current.originalTrack.matches(pair.track), current.permits(runtime: runtime),
                          let currentProof = await ExactTrackNameAdapter.renewingOwnedCoupledName(proof, through: current)
                    else { return unavailable("initial_header_observation") }
                    nameExecutions[goal.reference, default: .init()].restored = currentProof
                    outputPair = current.pair; outputRenewal = current; outputProof = current.observation
                    guard outputFootprintHeld(pair: current.pair, assignment: task.sink),
                          case .success(let trackName?) = AXValueExtractors.extractTrackNameResult(
                            from: pair.track.header, runtime: runtime.ax),
                          trackName.utf8.elementsEqual(goal.before.utf8),
                          case .success(let stripName?) = AXPluginInstanceIdentity.stripNameResult(pair.strip.strip, runtime: runtime.ax),
                          stripName.utf8.elementsEqual(effect.stripName.utf8)
                    else { return unavailable("initial_header_footprint") }
                    let currentAliases = aliases()
                    let retainedInput = AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax)
                    guard case .source(let retainedLabel) = retainedInput.reading, let retainedControl = retainedInput.control,
                          owned.control.matches(.init(owner: pair.strip, control: retainedControl, source: retainedLabel)),
                          await projectIsCurrent(allowPendingCancellation: true), current.permits(runtime: runtime)
                    else { return unavailable("initial_header_input_control") }
                    if currentAliases.contains(where: { $0.utf8.elementsEqual(effect.stripName.utf8) }),
                       !currentAliases.contains(where: { $0.utf8.elementsEqual(goal.name.utf8) }) {
                        nameExecutions[goal.reference, default: .init()].restoredInputControl = owned.control
                        return receipt.result
                    }
                    guard currentAliases.contains(where: { $0.utf8.elementsEqual(goal.name.utf8) })
                    else { return unavailable("initial_header_alias") }
                    let read = await AXMixerStripBinding.$current.withValue(pair.strip) {
                        await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                            await AccessibilityChannel.getInputBusObservation(runtime: runtime,
                                requiringOriginalInputControl: owned.control)
                        }
                    }
                    let message = decodedJSONObject(read.result.message)
                    Log.info("Restored-name input popup receipt: success=\(read.result.isSuccess),assignment_matches=\(read.assignment == .bus(task.before)),control_matches=\(read.inputSlot.map(owned.control.matches) == true),popup=\(message?["popup_menu_state"] as? String ?? "unknown"),focus=\(message?["focus_restoration"] as? String ?? "unknown"),error=\(message?["error"] as? String ?? "none")", subsystem: "saga")
                    Log.info("Restored-name input popup detail: pressed=\(message?["popup_press_succeeded"] as? Bool ?? false),cancelled=\(message?["popup_cancel_succeeded"] as? Bool ?? false),hint=\(message?["hint"] as? String ?? "none")", subsystem: "saga")
                    guard read.result.isSuccess, read.assignment == .bus(task.before),
                          read.inputSlot.map(owned.control.matches) == true,
                          let message,
                          message["popup_menu_state"] as? String == "closed",
                          message["focus_restoration"] as? String == "restored",
                          pair.strip.currentIndex(runtime: runtime) != nil,
                          await projectIsCurrent(allowPendingCancellation: true) else { return unavailable("input_popup") }
                    // The exact source/control survived, but this owned popup can
                    // retire a peer in the name receipt's census. Continue through
                    // the existing original-header observer, never revive that
                    // old census or adopt a replacement source by its name.
                    let observed = await AccessibilityChannel.renewSourceThroughOriginalHeader(pair,
                        original: pair.strip, runtime: runtime, sourceDisposition: .survivingOriginal)
                    guard let source = observed.source, source.pair.strip.matches(pair.strip),
                          source.originalTrack.matches(pair.track), source.permits(runtime: runtime),
                          let renewed = await ExactTrackNameAdapter.renewingOwnedCoupledName(currentProof, through: source)
                    else { return unavailable("original_header_observation") }
                    nameExecutions[goal.reference, default: .init()].restored = renewed
                    outputPair = source.pair; outputRenewal = source; outputProof = source.observation
                    guard outputFootprintHeld(pair: source.pair, assignment: task.sink),
                          case .success(let trackName?) = AXValueExtractors.extractTrackNameResult(
                            from: pair.track.header, runtime: runtime.ax),
                          trackName.utf8.elementsEqual(goal.before.utf8),
                          case .success(let stripName?) = AXPluginInstanceIdentity.stripNameResult(pair.strip.strip, runtime: runtime.ax),
                          stripName.utf8.elementsEqual(effect.stripName.utf8),
                          aliases().contains(where: { $0.utf8.elementsEqual(effect.stripName.utf8) }),
                          !aliases().contains(where: { $0.utf8.elementsEqual(goal.name.utf8) }),
                          await projectIsCurrent(allowPendingCancellation: true), source.permits(runtime: runtime)
                    else { return unavailable("restored_footprint") }
                    let currentInput = AXLogicProElements.inputSlotRead(in: pair.strip.strip, runtime: runtime.ax)
                    guard case .source(let label) = currentInput.reading, let control = currentInput.control,
                          owned.control.matches(.init(owner: pair.strip, control: control, source: label)),
                          await projectIsCurrent(allowPendingCancellation: true), source.permits(runtime: runtime)
                    else { return unavailable("retained_input_control") }
                    nameExecutions[goal.reference, default: .init()].restoredInputControl = owned.control
                }
            }
        } else {
            guard execution?.ran != true, step.params["name"] == .string(goal.name) else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
            nameExecutions[goal.reference, default: .init()].ran = true
            receipt = await ExactTrackNameAdapter.applyCoupled(nameAction(goal), capture: capture,
                router: router, cache: cache, registry: registry,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                capturedRead: execution?.capturedRead,
                ownedPeerEffects: ownedNameEffects, selectionOrigin: selectionOrigin, preservingFootprint: preserving,
                afterVerifiedWrite: afterVerifiedWrite, restoringMixerFocus: sendNameUsesInputFootprint)
            nameExecutions[goal.reference, default: .init()].inverse = receipt.inverse
        }
        return receipt.result
    }

    /// A matching canonical sort is a fresh goal observation, not an unobservable
    /// sort command. Keep the original complete native footprint and registry custody.
    func verifyMatchingSort() async -> SagaJournal.StoredOutcome {
        func refused() -> SagaJournal.StoredOutcome {
            SagaWire.storedOutcome(from: SagaWire.scopedStateC(.staleTargetReference,
                hint: "The approved track order or its retained native footprint could not be independently verified.",
                extras: ["idempotency_key": plan.idempotencyKey,
                    "goal_verification_failure": "approved_matching_sort_unverified",
                    "write_attempted": false, "writes_performed": 0]))
        }
        guard verifiesMatchingSortOnly, let sort = sortTask, await projectIsCurrent(),
              let reading = sortReading(), reading.order == sort.policy.expectedOrder,
              await projectIsCurrent(), let value = Self.sortOrderValue(reading.order) else { return refused() }
        let evidence = SagaReadEvidence(readSource: .axTrackOrder, provenance: .liveIndependent,
            trackIndex: nil, projectReference: projectRef.rawValue, field: "track_order_json",
            observed: value, sampledAt: ISO8601DateFormatter.cacheFormatter.string(from: Date()))
        guard let data = try? JSONEncoder().encode(evidence),
              let read = try? JSONSerialization.jsonObject(with: data) else { return refused() }
        let outcome = SagaOutcome(idempotencyKey: plan.idempotencyKey, state: .completed, complete: true,
            journal: [], stateHistory: [.validated, .running, .completed], preflightIssues: [])
        let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
        guard var body = decodedJSONObject(stored.body) else { return refused() }
        body["write_attempted"] = false; body["writes_performed"] = 0
        body["goal_evidence"] = [["target_ref": projectRef.rawValue, "read": read]]
        return .init(body: HonestContract.jsonString(body), isError: stored.isError)
    }

    /// No scalar operation is dispatched for the names-only case.
    func verifyMatchingNames() async -> SagaJournal.StoredOutcome {
        guard verifiesMatchingNamesOnly, let evidence = await nameGoalEvidence() else {
            return nameGoalRefusal()
        }
        let outcome = SagaOutcome(idempotencyKey: plan.idempotencyKey, state: .completed, complete: true,
            journal: [], stateHistory: [.validated, .running, .completed], preflightIssues: [])
        let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
        guard var body = decodedJSONObject(stored.body) else { return nameGoalRefusal() }
        body["write_attempted"] = false
        body["writes_performed"] = 0
        body["goal_evidence"] = evidence
        return .init(body: HonestContract.jsonString(body), isError: stored.isError)
    }

    func nameGoalRefusal() -> SagaJournal.StoredOutcome {
        SagaWire.storedOutcome(from: SagaWire.scopedStateC(.staleTargetReference,
            hint: "The whole approved name set or its originally issued track custody could not be independently verified.",
            extras: ["idempotency_key": plan.idempotencyKey,
                "plan_id": plan.canonicalPlanID as Any, "digest": plan.canonicalDigest as Any,
                "goal_verification_failure": "approved_name_set_unverified",
                "write_attempted": false, "writes_performed": 0]))
    }

    /// A read-only goal failure before the execution journal has applied any step.
    func matchingInputGoalRefusal(reader: InputBusSagaAdapter?) -> SagaJournal.StoredOutcome {
        var extras: [String: Any] = ["goal_verification_failure": "approved_matching_input_unverified",
            "idempotency_key": plan.idempotencyKey, "write_attempted": false, "writes_performed": 0]
        if let receipt = reader?.matchingReadReceipt.flatMap(decodedJSONObject) { extras["input_read_receipt"] = receipt }
        return SagaWire.storedOutcome(from: SagaWire.scopedStateC(.staleTargetReference,
            hint: "The approved input's original native control, protected footprint or checked Bus no longer agrees.", extras: extras))
    }

    /// Reuse the same actual reader across an owned name or verified output step. This returns
    /// observations, never a completed execution or a setter capability.
    func matchingInputGoalEvidence(using reader: InputBusSagaAdapter, afterExecution: Bool = false) async -> [[String: Any]]? {
        guard hasMatchingInputGoal, let task = inputTask else { return nil }
        func current() async -> Bool {
            guard await projectIsCurrent(),
                  let track = await registry.resolve(task.reference), track.kind == .track,
                  track.physicalTrack?.matches(task.pair.track) == true,
                  let mixer = await registry.resolve(task.mixerRef), mixer.kind == .mixerStrip,
                  mixer.physicalMixerStrip?.matches(task.pair.strip) == true,
                  await projectIsCurrent() else { return false }
            return true
        }
        if hasMatchingNameGoals {
            guard await nameGoalEvidence(afterExecution: afterExecution) != nil else { return nil }
        }
        var outputRead: SagaReadEvidence?
        if afterExecution, let output = outputTask {
            guard outputApplied, let step = plan.steps.first, plan.steps.count == 1,
                  let checked = await readOutputState(step), checked.value == .string(output.desired.token),
                  let read = checked.read else { return nil }
            outputRead = read
        }
        guard await current(), var observed = await reader.readMatchingGoal(cache: cache, registry: registry),
              observed.value == .string("bus:\(task.before)") else { return nil }
        var names: [[String: Any]] = []
        if hasMatchingNameGoals {
            guard let evidence = await nameGoalEvidence(afterExecution: afterExecution),
                  let afterNames = await reader.readMatchingGoal(cache: cache, registry: registry),
                  afterNames.value == observed.value else { return nil }
            // The final input read also corroborates the complete original name
            // footprint after the independent name samples. Neither reader can
            // turn an unchanged goal into a writer or an inverse capsule.
            names = evidence; observed = afterNames
        }
        if outputRead != nil, let output = outputTask {
            // The output's actual checked menu bookends the independent input read.
            // Never turn an old display label or attempted leaf into final goal evidence.
            guard let step = plan.steps.first,
                  let checked = await readOutputState(step), checked.value == .string(output.desired.token),
                  let read = checked.read else { return nil }
            outputRead = read
        }
        guard observed.value == .string("bus:\(task.before)"),
              let evidence = observed.read, evidence.readSource == .axInputMenuCheckmark,
              evidence.provenance == .liveIndependent,
              let data = try? JSONEncoder().encode(evidence),
              let read = try? JSONSerialization.jsonObject(with: data),
              await current() else { return nil }
        var goalEvidence: [[String: Any]] = [["target_ref": task.reference.rawValue, "mixer_ref": task.mixerRef.rawValue, "read": read]] + names
        if let outputRead, let output = outputTask {
            guard let encoded = try? JSONEncoder().encode(outputRead),
                  let outputEvidence = try? JSONSerialization.jsonObject(with: encoded) else { return nil }
            goalEvidence.append(["target_ref": output.reference.rawValue, "mixer_ref": output.mixerRef.rawValue,
                                 "read": outputEvidence])
        }
        return goalEvidence
    }

    /// Only an empty plan can turn these read-only observations into completion.
    func verifyMatchingInput() async -> SagaJournal.StoredOutcome {
        let reader = InputBusSagaAdapter(matchingInput: self)
        guard verifiesMatchingInputOnly, let reader,
              let evidence = await matchingInputGoalEvidence(using: reader) else {
            return matchingInputGoalRefusal(reader: reader)
        }
        let outcome = SagaOutcome(idempotencyKey: plan.idempotencyKey, state: .completed, complete: true,
            journal: [], stateHistory: [.validated, .running, .completed], preflightIssues: [])
        let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
        guard var body = decodedJSONObject(stored.body) else { return matchingInputGoalRefusal(reader: reader) }
        body["write_attempted"] = false; body["writes_performed"] = 0
        body["goal_evidence"] = evidence
        return .init(body: HonestContract.jsonString(body), isError: stored.isError)
    }

    /// A matching destination is a goal observation, never a scalar no-op or inverse capsule.
    func verifyMatchingSend() async -> SagaJournal.StoredOutcome {
        func refused(_ read: AccessibilityChannel.CheckedOutputReading? = nil) -> SagaJournal.StoredOutcome {
            var extras: [String: Any] = ["goal_verification_failure": "approved_matching_send_unverified",
                "idempotency_key": plan.idempotencyKey, "write_attempted": false, "writes_performed": 0]
            if let read, let receipt = decodedJSONObject(read.result.message) { extras["send_read_receipt"] = receipt }
            return SagaWire.storedOutcome(from: SagaWire.scopedStateC(.staleTargetReference,
                hint: "The approved Send's original native control or independently checked destination no longer agrees.", extras: extras))
        }
        guard verifiesMatchingSendOnly, let task = sendTask else { return refused() }
        func current() async -> Bool {
            let runtime = task.pair.track.runtime
            guard await projectIsCurrent(),
                  let track = await registry.resolve(task.reference), track.kind == .track,
                  track.physicalTrack?.matches(task.pair.track) == true,
                  let mixer = await registry.resolve(task.mixerRef), mixer.kind == .mixerStrip,
                  mixer.physicalMixerStrip?.matches(task.pair.strip) == true,
                  task.pair.track.currentIndex() != nil, task.pair.strip.currentIndex(runtime: runtime) != nil,
                  let control = AXLogicProElements.assignedSendMenuControl(in: task.pair.strip.strip,
                    ordinal: task.ordinal, runtime: runtime.ax), task.control.matches(control),
                  AXLogicProElements.sendSlotObservations(in: task.pair.strip.strip, runtime: runtime.ax) == task.footprint,
                  await projectIsCurrent() else { return false }
            return true
        }
        guard await current() else { return refused() }
        let read = await AXMixerStripBinding.$current.withValue(task.pair.strip) {
            await AXMixerStripBinding.$outputAssociation.withValue(task.pair) {
                await AccessibilityChannel.getOutputObservation(runtime: task.pair.track.runtime, sendOrdinal: task.ordinal,
                    requiringOriginalSendControl: task.control)
            }
        }
        guard read.result.isSuccess, let receipt = decodedJSONObject(read.result.message),
              receipt["popup_menu_state"] as? String == "closed",
              receipt["focus_restoration"] as? String == "restored",
              read.assignment == task.before, read.sendControl?.matches(task.control) == true,
              read.sendNonRoutingChecks == ["Post Fader"] || read.sendNonRoutingChecks == ["포스트 페이더"],
              await current() else { return refused(read) }
        let outcome = SagaOutcome(idempotencyKey: plan.idempotencyKey, state: .completed, complete: true,
            journal: [], stateHistory: [.validated, .running, .completed], preflightIssues: [])
        let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
        guard var body = decodedJSONObject(stored.body) else { return refused() }
        body["write_attempted"] = false; body["writes_performed"] = 0
        body["goal_evidence"] = [["target_ref": task.reference.rawValue, "mixer_ref": task.mixerRef.rawValue,
            "observed_ordinal": task.ordinal, "read": ["read_source": "ax_send_menu_checkmark",
                "provenance": "live_independent", "observed": task.before.token]]]
        return .init(body: HonestContract.jsonString(body), isError: stored.isError)
    }

    private func receiverCurrent(_ goal: ReceiverKeep, renewal: ReceiverRenewal? = nil) async -> Bool {
        let original = goal.input.owner, runtime = goal.presentation.runtime
        let inputBinding = renewal?.input ?? goal.input
        let labelBinding = renewal?.label ?? goal.label
        let owner = inputBinding.owner
        func renewalHeld() -> Bool {
            guard let renewal else { return true }
            guard let pair = goal.pair, pair.strip.matches(original),
                  renewal.source.original.matches(original), renewal.source.originalTrack.matches(pair.track),
                  renewal.source.pair.track.matches(pair.track), renewal.source.pair.strip.matches(owner),
                  renewal.label.owner.matches(owner),
                  renewal.input.source.utf8.elementsEqual(goal.input.source.utf8),
                  renewal.label.label.utf8.elementsEqual(goal.label.label.utf8) else { return false }
            return renewal.source.permits(runtime: runtime)
        }
        // The registry still names the originally approved object. A request-held
        // original-header renewal can verify continuity, never rebind that reference.
        guard await projectIsCurrent(), let reference = await registry.resolve(goal.reference),
              reference.kind == .mixerStrip, reference.physicalMixerStrip?.matches(original) == true,
              renewalHeld(), owner.currentIndex(runtime: runtime) != nil,
              let label = AXLogicProElements.typeNumberLabel(in: owner.strip, runtime: runtime.ax),
              CFEqual(label.control, labelBinding.control), label.label.utf8.elementsEqual(labelBinding.label.utf8) else { return false }
        let input = AXLogicProElements.inputSlotRead(in: owner.strip, runtime: runtime.ax)
        guard let control = input.control, CFEqual(control, inputBinding.control),
              case .source(let source) = input.reading, source.utf8.elementsEqual(inputBinding.source.utf8),
              owner.currentIndex(runtime: runtime) != nil, await projectIsCurrent(), renewalHeld() else { return false }
        return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
    }

    /// Re-observe these approved native receivers without assigning an input or creating anything.
    func verifyReceiverKeeps() async -> SagaJournal.StoredOutcome {
        func refused(_ read: AccessibilityChannel.CheckedOutputReading? = nil) -> SagaJournal.StoredOutcome {
            var extras: [String: Any] = ["goal_verification_failure": "approved_receiver_keep_unverified",
                "idempotency_key": plan.idempotencyKey, "write_attempted": false, "writes_performed": 0]
            if let read, let receipt = decodedJSONObject(read.result.message) {
                // Read-only popup/focus cleanup uncertainty must survive this wrapper.
                // The receipt is diagnostic data, never a substitute for typed native custody.
                extras["receiver_read_receipt"] = receipt
            }
            return SagaWire.storedOutcome(from: SagaWire.scopedStateC(.staleTargetReference,
                hint: "The approved observed receiver's original type/input custody or checked Bus no longer agrees.",
                extras: extras))
        }
        guard verifiesReceiverKeepsOnly else { return refused() }
        var evidence: [[String: Any]] = []
        var renewals: [TargetReference: ReceiverRenewal] = [:]
        for goal in receiverKeeps {
            guard await receiverCurrent(goal) else { return refused() }
            let read = await AXMixerStripBinding.$current.withValue(goal.input.owner) {
                await AXMixerStripBinding.$outputAssociation.withValue(goal.pair) {
                    await AccessibilityChannel.getInputBusObservation(runtime: goal.presentation.runtime)
                }
            }
            guard read.assignment == .bus(goal.bus) else { return refused(read) }
            if let source = read.inputRenewal {
                guard let input = read.inputSlot, input.owner.matches(source.pair.strip),
                      source.permits(runtime: goal.presentation.runtime),
                      let label = AXLogicProElements.typeNumberLabel(in: input.owner.strip,
                        runtime: goal.presentation.runtime.ax) else { return refused(read) }
                let renewal = ReceiverRenewal(source: source, input: input,
                    label: .init(owner: input.owner, control: label.control, label: label.label))
                guard await receiverCurrent(goal, renewal: renewal) else { return refused(read) }
                renewals[goal.reference] = renewal
            } else {
                guard read.inputSlot?.matches(goal.input) == true, await receiverCurrent(goal) else { return refused(read) }
            }
            evidence.append(["target_ref": goal.reference.rawValue, "bus": goal.bus,
                "scope": "approved_observed_receiver", "namespace_availability": "not_observed",
                "read": ["read_source": "ax_input_menu_checkmark", "provenance": "live_independent",
                    "observed_bus": goal.bus, "observed_type_label": goal.label.label]])
        }
        // A later receiver's popup can invalidate an earlier observation's native custody.
        for goal in receiverKeeps {
            guard await receiverCurrent(goal, renewal: renewals[goal.reference]) else { return refused() }
        }
        let outcome = SagaOutcome(idempotencyKey: plan.idempotencyKey, state: .completed, complete: true,
            journal: [], stateHistory: [.validated, .running, .completed], preflightIssues: [])
        let stored = SagaWire.storedOutcome(plan: plan, outcome: outcome)
        guard var body = decodedJSONObject(stored.body) else { return refused() }
        body["write_attempted"] = false; body["writes_performed"] = 0
        body["goal_evidence"] = evidence
        return .init(body: HonestContract.jsonString(body), isError: stored.isError)
    }

    func perform(_ desired: Bool, runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        guard let task = mixerTask else {
            return .error(HonestContract.encodeStateC(error: .unsupportedState, extras: ["write_attempted": false]))
        }
        let before = task.before, binding = task.binding
        let ownedInverse = ran && ownedVisibility != nil && desired == before
        let expected: Bool?
        let expectedMixer: AXUIElement?
        if !ran { expected = before; expectedMixer = binding.mixer }
        else { expected = ownedVisibility ?? (before == task.desired ? before : nil); expectedMixer = ownedMixer ?? binding.mixer }
        guard let expected, desired == task.desired || desired == before,
              // Journal cancellation still denies each new forward boundary below.
              // It must not revoke owned cleanup or the independent post-write
              // proof needed to retain custody for the existing conditional inverse.
              let navigation = await navigation(runtime: runtime, allowPendingCancellation: true) else {
            return .error(HonestContract.encodeStateC(error: .staleTargetReference,
                hint: "The retained view custody or conditional inverse is unavailable.", extras: ["write_attempted": false]))
        }
        let result = await navigation.setFinalVisibility(desired, expectedBefore: expected,
            expectedMixer: expectedMixer, permittingVisibilityChange: { [self] in
                if !ownedInverse, hasMatchingNameGoals, await nameGoalEvidence() == nil { return false }
                guard await projectIsCurrent(allowPendingCancellation: ownedInverse) else { return false }
                if sortTask != nil, !sortFootprintHeld() { return false }
                guard let observed = await navigation.approvedVisibility(expectedTransport: binding.transport,
                    stoppingWhen: { [self] in stop(runtime: runtime) }), observed.0 == expected else { return false }
                if expected {
                    guard let mixer = observed.1, let expectedMixer,
                          CFEqual(mixer, expectedMixer) else { return false }
                }
                if sortTask != nil {
                    guard sortFootprintHeld(),
                          await projectIsCurrent(allowPendingCancellation: ownedInverse) else { return false }
                }
                return true
            }, stoppingWhen: { [self] in stop(runtime: runtime) })
        ran = true
        if case .success(let text) = result, let body = decodedJSONObject(text), body["state"] as? String == "A",
           body["write_attempted"] as? Bool == true, body["before_visible"] as? Bool != desired,
           body["after_visible"] as? Bool == desired,
           let observed = await navigation.approvedVisibility(expectedTransport: binding.transport,
               stoppingWhen: { [self] in stop(runtime: runtime) }), observed.0 == desired {
            if desired {
                guard let mixer = observed.1, let verifiedMixer = navigation.revealedMixer,
                      CFEqual(mixer, verifiedMixer) else { return result }
            }
            ownedVisibility = desired; ownedMixer = observed.1
        }
        return result
    }

    static func apply(request: ApplyRequest, dependencies: HandlerDependencies) async -> CallTool.Result {
        let id = request.planID, digest = request.digest, key = request.key
        if let replay = await dependencies.sagaJournal.canonicalReplay(key: key, planID: id, digest: digest) {
            switch replay {
            case .completed(let outcome):
                let duplicate = SagaWire.duplicateOutcome(outcome)
                return toolTextResult(duplicate.body, isError: duplicate.isError)
            case .conflict: return SagaWire.idempotencyConflict(key)
            case .outcomeEvicted(let terminal): return SagaWire.outcomeUnavailable(key, terminal: terminal)
            default: return SagaWire.scopedStateC(.sagaInProgress,
                hint: "This immutable plan key is already running, cancelling or cancelled; it cannot be re-executed.",
                extras: ["idempotency_key": key, "write_attempted": false])
            }
        }
        guard let approval = await retained(id: id, digest: digest, key: key, cache: dependencies.cache,
            registry: dependencies.targetRegistry, journal: dependencies.sagaJournal) else {
            return toolStateCResult(.staleTargetReference,
                hint: "The exact retained plan, required native goal evidence, or its original project is unavailable; no replacement plan was generated.",
                extras: ["write_attempted": false, "verified": false])
        }
        return await SystemDispatcher.handle(command: "saga_execute", params: [:], router: dependencies.router,
            cache: dependencies.cache, targetRegistry: dependencies.targetRegistry,
            dialogPresent: dependencies.dialogPresent, sagaJournal: dependencies.sagaJournal,
            mutationGate: dependencies.mutationGate, sagaRefreshAfterWrite: {},
            sagaLifecycleDeadline: dependencies.sagaLifecycleDeadline, approvedSessionRepair: approval)
    }
}
