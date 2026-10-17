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
        let goalID: String
        let handle: String
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
        var receivers: [ReceiverKeep] = []
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
        default: return nil
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
              checked.count == 1, let before = checked.first?.assignment,
              localAssignmentForBefore(before) != nil,
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

    /// Removal and typed local output endpoints need no receiver allocation. The ordinal
    /// selects this capture's original native control, which execution must still prove current.
    private static func capturedSend(policy: ProjectSessionAudit.IntentPolicy,
        names: [ProjectSessionAudit.ApprovedName], source: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request) -> SendTask? {
        guard FeatureFlags.adr002TargetRef, FeatureFlags.adr004MutationSaga,
              names.isEmpty, policy.targets.count == 1, policy.sends.count == 1,
              policy.roles.isEmpty, policy.outputs.isEmpty, policy.receivers.isEmpty,
              policy.protectedPaths.isEmpty, policy.trackSort == nil, policy.mixerVisible == nil,
              let target = policy.targets.first, target.mixerRef == nil,
              let intent = policy.sends.first, intent.target == target.handle, intent.bus == nil,
              intent.isRemoval || intent.localOutput != nil,
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
        guard rows.count == 1, let row = rows.first, let mixerRef = source.mixerReference(at: row),
              checked.count == 1, let reading = checked.first,
              intent.localOutput.map({ reading.assignment == $0 || AccessibilityChannel.supportsOccupiedSendChange(before: reading.assignment, after: $0) })
                ?? (intent.isRemoval && reading.assignment == .stereoOutput),
              reading.sendNonRoutingChecks == ["Post Fader"] || reading.sendNonRoutingChecks == ["포스트 페이더"],
              let control = reading.sendControl, control.ordinal == ordinal,
              let slots = source.channelStrips[row].sendSlots, slots.count == 2,
              slots.filter({ $0.state == .observedEmpty }).count == 1,
              let occupied = slots.first(where: { $0.state == .occupiedUnknownDestination }),
              occupied.ordinal == ordinal, occupied.levelRaw == 0, occupied.bypassed == false else { return nil }
        return .init(reference: target.trackRef, mixerRef: mixerRef, pair: pair,
            control: control, ordinal: ordinal, before: reading.assignment, desired: intent.localOutput,
            footprint: slots, goalID: "send.target.\(intent.target).\(intent.selectorID)", handle: target.handle)
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
            "dependencies": .array([]), "blocked_reasons": .array([]),
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
        let naming = ProjectSessionAudit.normalizedMixerNaming(policy: originalPolicy, names: names,
            capture: source, request: request)
        guard naming.reasons.isEmpty else { return nil }
        let policy = naming.policy
        if let send = capturedSend(policy: policy, names: names, source: source, request: request),
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
                      !(before && !desired && sort.binding.mixerFocusWouldBeRetired) else { return nil }
                mixer = .init(before: before, desired: desired, binding: sort.binding)
            }
            return .init(projectRef: project, document: sort.binding.document, mixer: mixer,
                names: [], renameCapture: nil, sort: sort)
        }
        guard policy.trackSort == nil, policy.roles.isEmpty, (policy.outputs.isEmpty || output != nil),
              policy.sends.isEmpty, policy.receivers.isEmpty, policy.protectedPaths.isEmpty,
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
                selectionOrigin: selectionOrigin, output: output)
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
    private var outputPair: AccessibilityChannel.HeldSelectionAssociation.Pair?
    private var outputRenewal: AccessibilityChannel.OriginalHeaderSourceRenewal?
    private var outputProof: AccessibilityChannel.HeldSelectionAssociation?
    private var outputAttempted = false
    private var outputApplied = false
    private var outputInverseConsumed = false
    private var sortSnapshot: TargetRegistrySnapshot?
    private var sortProject: TargetReference?
    private var sortApplied = false
    private var sortInverseConsumed = false
    private var sortAttempted = false
    private var sortLeafOrder: [String]?
    private struct NameExecution {
        var ran = false
        var inverse: ExactTrackNameAdapter.OwnedInverse?
        var restored: ExactTrackNameAdapter.OwnedInverse?
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
        let unchangedIDs = unchangedNames.map { "name_" + $0.target }
            + Set(captured.receivers.map(\.bus)).sorted().map { "receiver_keep_bus_\($0)" }
            + (captured.send.flatMap { $0.desired == $0.before ? $0.goalID : nil }.map { [$0] } ?? [])
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
        if let send = captured.send {
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
                cacheProjectEpoch: source.capture.projectEpoch, outputTask: output, registryProjectEpoch: targetSnapshot.projectEpoch,
                cache: cache, registry: registry, journal: journal)
        }
        if let sort = captured.sort {
            guard steps.count == (captured.mixer == nil ? 1 : 2), let step = steps[0].objectValue,
                  step["kind"] == .string("track_sort"), step["target_ref"] == .string(issued.rawValue),
                  step["before"]?.objectValue?["order"] == .array(sort.before.map(Value.string)),
                  step["after"]?.objectValue?["criterion"] == .string(sort.policy.criterion.rawValue),
                  step["after"]?.objectValue?["order"] == .array(sort.policy.expectedOrder.map(Value.string)),
                  step["inverse"]?.objectValue?["criterion"] == .string(sort.policy.inverseCriterion.rawValue),
                  step["inverse"]?.objectValue?["expected_order"] == .array(sort.before.map(Value.string)),
                  step["blocked_reasons"]?.arrayValue?.isEmpty == true,
                  step["dependencies"]?.arrayValue?.isEmpty == true,
                  let orderValue = sortOrderValue(sort.policy.expectedOrder) else { return nil }
            var sagaSteps: [SagaStep] = [.init(operationID: .tracksSortVerified, targetRef: issued,
                params: ["criterion": .string(sort.policy.criterion.rawValue),
                         "expected_order": orderValue],
                expectedInverse: .init(operationID: .tracksSortVerified, valueParameter: "expected_order"))]
            if let mixer = captured.mixer {
                guard let view = steps[1].objectValue, view["kind"] == .string("mixer_visibility"),
                      view["target_ref"] == .string(issued.rawValue),
                      view["before"]?.objectValue?["visible"] == .bool(mixer.before),
                      view["after"]?.objectValue?["visible"] == .bool(mixer.desired),
                      view["dependencies"] == .array([.string("track_sort")]),
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
            guard steps.count == changed.count + (captured.output == nil ? 0 : 1) else { return nil }
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
            let saga = SagaPlan(steps: sagaSteps,
                idempotencyKey: key, canonicalPlanID: id, canonicalDigest: digest)
            return .init(plan: saga, projectRef: issued, document: captured.document, nameGoals: goals,
                renameCapture: renameCapture, selectionOrigin: captured.selectionOrigin,
                cacheProjectEpoch: source.capture.projectEpoch, outputTask: captured.output,
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
        if sendTask != nil { return plan.steps == [step] }
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
    func sendRemovalCustody(for step: SagaStep) -> (AccessibilityChannel.HeldSelectionAssociation.Pair,
        AXLogicProElements.AssignedSendMenuControl)? {
        guard let task = sendTask, supports(step), plan.canonicalPlanID != nil,
              plan.canonicalDigest != nil else { return nil }
        return (task.pair, task.control)
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
                    ownedPeerEffects: step.params["name"] == .string(goal.before) ? [] : ownedNameEffects)
            }
            guard let name = observed,
                  let index = goal.binding.currentIndex(),
                  await projectIsCurrent(allowPendingCancellation: true), originalSelectionHeld() else { return nil }
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
        guard let task = outputTask,
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
    /// output may differ; neither a fresh row nor a displayed label becomes a new baseline.
    private func outputFootprintHeld(pair: AccessibilityChannel.HeldSelectionAssociation.Pair,
                                     assignment: OutputAssignment, popup: AXUIElement? = nil,
                                     ownedNamePreview: [String]? = nil, ownedNameEditor: AXUIElement? = nil,
                                     ownedStripNamePreview: [String]? = nil,
                                     verifiedNameEffect: ExactTrackNameAdapter.VerifiedNameEffect? = nil) -> Bool {
        guard let task = outputTask, let proof = outputProof else { return false }
        let runtime = pair.track.runtime
        @Sendable func permitted() -> Bool {
            guard let proof = self.outputProof else { return false }
            if let editor = ownedNameEditor, let names = ownedNamePreview {
                return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                    && ExactTrackNameAdapter.permitsCoupledEditorRead(editor, pair: pair, names: names, transportProof: proof)
            }
            return (try? SessionPopulationObservation.requireOwnedAcquisition()) != nil
                && (popup.map { proof.permitsOwnedPopupRead($0) } ?? proof.permitsRead())
        }
        guard permitted(), pair.track.matches(task.pair.track),
              outputRenewal.map { renewal in
                  renewal.pair.strip.matches(pair.strip) && renewal.pair.track.matches(task.pair.track)
                      && (ownedNameEditor != nil || renewal.permits(runtime: runtime, ownedPopup: popup))
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
        let fields = AXHelpers.HelpReadGuard.$current.withValue(.init(allowHelpReads: true, stop: { !permitted() })) {
            let tracks = AccessibilityChannel.readTrackStates(from: proof.headers, in: pair.track.window,
                runtime: runtime, readingTypeHelp: false, stoppingWhen: metadataStopped).states
            let strips = AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: pair.strip.mixer, runtime: runtime.ax)
                .flatMap { AccessibilityChannel.readChannelStrips(from: $0.strips, runtime: runtime,
                    window: pair.strip.window, mixer: pair.strip.mixer, readingScalarHelp: false,
                    stoppingWhen: metadataStopped) }
            return (tracks, strips)
        }
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
            if outputRenewal == nil, row != index,
               strips[row].physicalBinding?.matches(task.capture.channelStrips[row].physicalBinding ?? pair.strip) != true { return false }
            guard strips[row].volumeReadback == task.capture.channelStrips[row].volumeReadback,
                  strips[row].panReadback == task.capture.channelStrips[row].panReadback,
                  strips[row].volumeReadback != nil, strips[row].panReadback != nil,
                  strips[row].pluginsFullyObserved == true else { return false }
        }
        var expected = task.capture.channelStrips
        if assignment != task.before { expected[index].output = strips[index].output }
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
        guard let expectedTracks = try? encoder.encode(expectedTrackRows),
              let currentTracks = try? encoder.encode(tracks), expectedTracks == currentTracks,
              let expectedStrips = try? encoder.encode(expected), let currentStrips = try? encoder.encode(strips),
              expectedStrips == currentStrips, permitted(),
              ownedNameEditor != nil || (outputRenewal.map { $0.permits(runtime: runtime, ownedPopup: popup) } ?? true),
              pair.strip.currentIndex(runtime: runtime) == index,
              case .success(.some(let finalDocument)) = AXLogicProElements.projectPickerDocumentRead(pair.strip.window, runtime: runtime),
              finalDocument.utf8.elementsEqual(document.utf8) else { return false }
        if let editor = ownedNameEditor {
            return ExactTrackNameAdapter.coupledWriteFocusMatches(editor, runtime: runtime)
        }
        return true
    }

    private func outputReading() async -> OutputAssignment? {
        guard let task = outputTask, await projectIsCurrent(allowPendingCancellation: true),
              let target = await registry.resolve(task.reference), target.kind == .track,
              target.physicalTrack?.matches(task.pair.track) == true else { return nil }
        let pair = outputPair ?? task.pair, runtime = pair.track.runtime
        guard let proof = heldOutputProof(pair) else { return nil }
        outputProof = proof
        let reading = await AXMixerStripBinding.$current.withValue(pair.strip) {
            await AccessibilityChannel.getOutputObservation(runtime: runtime)
        }
        guard let assignment = reading.assignment,
              assignment == task.before || (outputAttempted && assignment == task.desired),
              outputFootprintHeld(pair: pair, assignment: assignment),
              await projectIsCurrent(allowPendingCancellation: true) else { return nil }
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
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
        } else {
            guard let before = await outputReading(), before == expected else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
        }
        guard await projectIsCurrent(allowPendingCancellation: inverse) else {
            return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
        }
        let pair = outputPair ?? task.pair, runtime = pair.track.runtime
        guard let index = pair.strip.currentIndex(runtime: runtime) else { return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false]) }
        if inverse { outputInverseConsumed = true }
        let response = await Self.$outputLeafPermission.withValue({ [self] popup in
            outputFootprintHeld(pair: pair, assignment: expected, popup: popup)
        }) {
            await AXMixerStripBinding.$current.withValue(pair.strip) {
                await AXMixerStripBinding.$outputAssociation.withValue(pair) {
                    await OperationTraceWriteBoundaryArm.armed(OperationTraceContext.current?.traceID) {
                        await routedTextResult(router, operation: "mixer.set_output_verified",
                            params: ["index": String(index), "destination": desired.token, "expected_current": expected.token])
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

    var verifiesMatchingNamesOnly: Bool { !nameGoals.isEmpty && mixerTask == nil && plan.steps.isEmpty }
    var verifiesReceiverKeepsOnly: Bool { !receiverKeeps.isEmpty && nameGoals.isEmpty && mixerTask == nil && plan.steps.isEmpty }
    var verifiesMatchingSendOnly: Bool { sendTask.map { $0.desired == $0.before } == true && plan.steps.isEmpty }
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
                        capture: capture, registry: registry, ownedPeerEffects: afterExecution ? ownedNameEffects : [])
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

    func performName(_ step: SagaStep, router: ChannelRouter) async -> CallTool.Result {
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
        if let task = outputTask {
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
            receipt = await ExactTrackNameAdapter.inverse(proof, router: router,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) }, preservingFootprint: preserving,
                afterVerifiedWrite: afterVerifiedWrite)
            nameExecutions[goal.reference, default: .init()].restored = receipt.inverse
        } else {
            guard execution?.ran != true, step.params["name"] == .string(goal.name) else {
                return toolStateCResult(.staleTargetReference, extras: ["write_attempted": false])
            }
            nameExecutions[goal.reference, default: .init()].ran = true
            receipt = await ExactTrackNameAdapter.applyCoupled(nameAction(goal), capture: capture,
                router: router, cache: cache, registry: registry,
                liveTrackName: { AXLogicProElements.trackName(at: $0, runtime: runtime) },
                liveTrackNames: { AXLogicProElements.trackNames(runtime: runtime) },
                ownedPeerEffects: ownedNameEffects, selectionOrigin: selectionOrigin, preservingFootprint: preserving,
                afterVerifiedWrite: afterVerifiedWrite)
            nameExecutions[goal.reference, default: .init()].inverse = receipt.inverse
        }
        return receipt.result
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
