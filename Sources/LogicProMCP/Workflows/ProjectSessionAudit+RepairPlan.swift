import CryptoKit
import Foundation
import MCP

extension ProjectSessionAudit {
    static let sessionRepairPlanSchema = "logic_pro_mcp_session_repair_plan.v1"

    struct ApprovedName: Sendable {
        let target: String
        let name: String
    }

    /// Names are explicit approved values, not inferred roles or a second naming policy.
    static func parseApprovedNames(_ value: Value?, policy: IntentPolicy) -> [ApprovedName]? {
        guard let value else { return [] }
        guard case .array(let entries) = value, entries.count <= 32 else { return nil }
        let handles = Set(policy.targets.map(\.handle))
        var seen = Set<String>()
        var result: [ApprovedName] = []
        for entry in entries {
            guard case .object(let fields) = entry,
                  Set(fields.keys) == ["target", "name"],
                  case .string(let target)? = fields["target"], handles.contains(target),
                  seen.insert(target).inserted,
                  case .string(let raw)? = fields["name"] else { return nil }
            guard TrackDispatcher.renameNameFailure(raw) == nil else { return nil }
            result.append(ApprovedName(target: target, name: raw))
        }
        return result.sorted { $0.target < $1.target }
    }

    /// ADR-021 section 3's planning inputs beside the policy. Each permits *planning* an effect,
    /// never executing it, and each defaults to the narrower choice. Neither ambiguity mode
    /// permits guessing: `ask` returns the questions, `report_only` returns the same report and
    /// marks the plan not executable whatever it holds.
    struct PlanningOptions: Equatable, Sendable {
        enum OnAmbiguity: String, Sendable {
            case ask
            case reportOnly = "report_only"
        }

        var onAmbiguity: OnAmbiguity = .ask
        var allowCreateAux = false
        var allowStackMembershipChange = false
        var allowReplaceSend = false

        static let parameterKeys: Set<String> = [
            "on_ambiguity", "allow_create_aux", "allow_stack_membership_change", "allow_replace_send",
        ]

        /// The options `params` names, or nil when one has the wrong type or an unknown value.
        static func parse(_ params: [String: Value]) -> PlanningOptions? {
            var options = PlanningOptions()
            if let raw = params["on_ambiguity"] {
                guard case .string(let word) = raw, let mode = OnAmbiguity(rawValue: word) else { return nil }
                options.onAmbiguity = mode
            }
            for (key, path) in [
                ("allow_create_aux", \PlanningOptions.allowCreateAux),
                ("allow_stack_membership_change", \PlanningOptions.allowStackMembershipChange),
                ("allow_replace_send", \PlanningOptions.allowReplaceSend),
            ] {
                guard let raw = params[key] else { continue }
                guard case .bool(let flag) = raw else { return nil }
                options[keyPath: path] = flag
            }
            return options
        }

        /// The form the canonical plan carries, so the digest binds the options it was planned under.
        var wire: Value {
            .object([
                "on_ambiguity": .string(onAmbiguity.rawValue),
                "allow_create_aux": .bool(allowCreateAux),
                "allow_stack_membership_change": .bool(allowStackMembershipChange),
                "allow_replace_send": .bool(allowReplaceSend),
            ])
        }
    }

    struct CanonicalRepairPlan: Sendable {
        let id: String
        let digest: String
        let json: String
    }

    private struct ProtectedPathRead {
        let targetRef: TargetReference
        let sinkNodeID: String
        let baseline: RoutingPathState
        var final: RoutingPathState
        var prefixes: [Value] = []
        var lost = false
        var unavailable: Bool { baseline == .unverified || final == .unverified
            || prefixes.contains { $0.objectValue?["state"]?.stringValue == RoutingPathState.unverified.rawValue } }

        var wire: Value {
            .object(["kind": .string("sink_path"), "target_ref": .string(targetRef.rawValue),
                "sink_node_id": .string(sinkNodeID), "baseline": .string(baseline.rawValue),
                "prefixes": .array(prefixes), "final": .string(final.rawValue),
                "status": .string(lost ? "violated" : unavailable || baseline != .connected ? "unverified" : "preserved")])
        }
    }

    /// A canonical draft accounts for approved tasks even when their observation or adapter
    /// footprint is unavailable. It never turns a logical track index into a physical strip.
    static func buildCanonicalRepairPlan(
        policy: IntentPolicy, policyValue: Value, names: [ApprovedName],
        capture: SessionPopulationObservation.Capture,
        request: SessionPopulationObservation.Request,
        snapshotCurrent: Bool,
        options: PlanningOptions = PlanningOptions(),
        graphOverride: RoutingGraph? = nil
    ) throws -> CanonicalRepairPlan {
        // `graphOverride` is a test seam: today's capture publishes no bus-to-aux reading, so the
        // receiving-aux branches are reachable only through a graph that carries one.
        let graph = graphOverride ?? SessionPopulationObservation.routingGraph(capture: capture)
        let assessment = assessIntent(policy: policy, capture: capture, graph: graph)
        let viewOnly = policy.mixerVisible != nil && policy.trackSort == nil && policy.targets.isEmpty && policy.roles.isEmpty
            && policy.outputs.isEmpty && policy.sends.isEmpty && policy.receivers.isEmpty && names.isEmpty && policy.protectedPaths.isEmpty
        var reasons = Set<String>()
        if !snapshotCurrent { reasons.insert("snapshot_changed") }
        if !viewOnly && request.scope != .wholeProject { reasons.insert("whole_project_scope_required") }
        let gate = assessmentGate(policy: policy, capture: capture, graph: graph)
        if !viewOnly, let gate { reasons.insert(gate.reason.rawValue) }
        // The whole binding the assessor applies: the gate, and the registry epoch it checks per
        // finding (#1090 review R2, R1090-002). Receiver evidence is read only from a graph both pass.
        let epochMismatch = graphEpochMismatch(graph, capture: capture)
        if !viewOnly, let epochMismatch { reasons.insert(epochMismatch.rawValue) }
        let graphBound = gate == nil && epochMismatch == nil
        var proposalReadReasons = reasons
        if !request.domains.contains(.routing) { proposalReadReasons.insert("routing_not_requested") }
        // These constraints are a required task, not an optional property that a supported view
        // subset can ignore. The current apply provider has no fresh protected-path verifier.
        if !policy.protectedPaths.isEmpty { reasons.insert("protected_path_execution_verifier_unavailable") }
        var proposedGraph = graph
        var proposedGraphKnown = true
        let pathEvidenceBound = graphBound && snapshotCurrent && request.scope == .wholeProject
            && request.domains.contains(.routing) && capture.referencesEnabled
        func pathState(_ target: TargetReference, _ sink: String, in candidate: RoutingGraph) -> RoutingPathState {
            guard pathEvidenceBound, let issued = capture.issued,
                  case .located(let index) = locate(target, in: issued),
                  capture.tracks.filter({ $0.id == index }).count == 1,
                  candidate.nodes.filter({ $0.targetRef == target }).count == 1,
                  candidate.nodes.first(where: { $0.targetRef == target })?.kind == .track else { return .unverified }
            return routingPath(from: target, to: sink, in: candidate)
        }
        var protectedReads = policy.protectedPaths.compactMap { path -> ProtectedPathRead? in
            guard let target = policy.targets.first(where: { $0.handle == path.target }) else { return nil }
            let baseline = pathState(target.trackRef, path.sinkNodeID, in: graph)
            if baseline == .unverified { reasons.insert("protected_path_evidence_unavailable") }
            if baseline == .disconnected { reasons.insert("protected_path_not_observed") }
            return .init(targetRef: target.trackRef, sinkNodeID: path.sinkNodeID, baseline: baseline, final: baseline)
        }
        func recordRoutingPrefix(_ id: String, after: RoutingGraph?) {
            if let after { proposedGraph = after } else { proposedGraphKnown = false }
            for index in protectedReads.indices {
                let current = proposedGraphKnown ? pathState(protectedReads[index].targetRef,
                    protectedReads[index].sinkNodeID, in: proposedGraph) : .unverified
                protectedReads[index].final = current
                protectedReads[index].prefixes.append(.object(["step_id": .string(id), "state": .string(current.rawValue)]))
                if current == .disconnected, protectedReads[index].baseline == .connected {
                    protectedReads[index].lost = true
                    reasons.insert("protected_path_lost")
                }
                if current == .unverified { reasons.insert("protected_path_evidence_unavailable") }
            }
        }
        // Even an unchanged send needs a fresh exact-slot verifier which the retained apply
        // provider does not have. A pure graph fixture cannot advertise runtime availability.
        if !policy.sends.isEmpty { reasons.insert("send_goal_verification_unavailable") }
        if options.onAmbiguity == .reportOnly { reasons.insert("report_only_requested") }
        // Steps that create a receiving aux come before the outputs that need one
        // (destination before source), and each bus gets at most one.
        var auxSteps: [Value] = []
        var inventory: [Value] = []
        var auxStepForBus: [Int: String] = [:]
        // A question per bus whose receiver the policy does not settle, or settles against what
        // was observed. Each offers only answers that settle it on a rebuild (#1090 supplementary
        // review S002): an absence is answered with `new` or `none`, a present receiver with `keep`.
        var receiverQuestions: [Int: Value] = [:]
        func receiverQuestion(_ bus: Int, observed: ReceivingAux) {
            let answers: [String] = observed == .present ? ["keep"] : ["new", "none"]
            receiverQuestions[bus] = .object([
                "id": .string("receiver_bus_\(bus)"), "bus": .int(bus),
                "observed": .string(observed == .present ? "receiver_present" : "no_receiver"),
                "answers": .array(answers.map { word in
                    .object(["receivers": .array([.object(["bus": .int(bus), "aux": .string(word)])])])
                })
            ])
            reasons.insert("receiver_intent_unresolved")
        }
        // A graph the binding rejected (another capture, another project, another registry epoch,
        // inconsistent) is not evidence about this session's receivers, so neither presence nor
        // absence is read from it (#1090 review R1090-001, R1090-002).
        func observedReceiver(_ bus: Int) -> ReceivingAux {
            graphBound ? receivingAux(bus: bus, graph: graph) : .unverified
        }
        // Blocked reasons an output onto `bus` inherits from the receiver decision for that bus.
        var receiverBlocks: [Int: Set<String>] = [:]
        func planAux(_ bus: Int) {
            guard auxStepForBus[bus] == nil else { return }
            let auxID = "create_aux_bus_\(bus)"
            auxStepForBus[bus] = auxID
            let handle = "new:aux_bus_\(bus)"
            let auxBlocked = ["aux_creation_adapter_unavailable"]
            reasons.formUnion(auxBlocked)
            auxSteps.append(.object([
                "id": .string(auxID), "kind": .string("create_aux"),
                "handle": .string(handle),
                "before": .object([:]), "after": .object(["input_bus": .int(bus)]),
                "blocked_reasons": .array(auxBlocked.map(Value.string)),
                "dependencies": .array([]),
                "required_invariants": .array([
                    "bus_namespace_evidence", "existing_routing_preservation", "inverse_remove_created_aux"
                ].map(Value.string))
            ]))
            inventory.append(.object([
                "handle": .string(handle), "kind": .string("aux"),
                "input_bus": .int(bus), "created_by": .string(auxID)
            ]))
        }
        // Every approved receiver intent is a task of its own, assessed whether or not an output
        // onto its bus needs changing (#1090 supplementary review S001).
        for bus in policy.receivers.keys.sorted() {
            guard let intent = policy.receivers[bus] else { continue }
            let observed = observedReceiver(bus)
            switch (observed, intent) {
            case (.unverified, _):
                reasons.insert("bus_receiver_unverified")
                receiverBlocks[bus] = ["bus_receiver_unverified"]
            case (.present, .keep), (.absent, .noReceiver):
                break
            case (.present, .new), (.present, .noReceiver), (.absent, .keep):
                receiverQuestion(bus, observed: observed)
            case (.absent, .new) where options.allowCreateAux:
                planAux(bus)
            case (.absent, .new):
                reasons.formUnion(["receiving_aux_missing", "create_aux_not_allowed"])
                receiverBlocks[bus] = ["receiving_aux_missing", "create_aux_not_allowed"]
            }
        }
        // Output and send assignments consume the same approved receiving-aux decision.
        // A destination dependency is local to its bus; removal has no destination to create.
        func receiverRequirements(_ bus: Int) -> (blocked: Set<String>, dependencies: [String]) {
            if policy.receivers[bus] != nil {
                return (receiverBlocks[bus] ?? [], auxStepForBus[bus].map { [$0] } ?? [])
            }
            switch observedReceiver(bus) {
            case .unverified: return (["bus_receiver_unverified"], [])
            case .absent: receiverQuestion(bus, observed: .absent)
            case .present: break
            }
            return ([], [])
        }
        var steps: [Value] = []
        var unchanged: [Value] = []
        var routingIDs: [String] = []
        // The current aux adapter supplies no factual predicted graph. Do not claim a protected
        // path survived a fabricated new-object topology or silently skip that canonical prefix.
        for aux in auxSteps {
            if let id = aux.objectValue?["id"]?.stringValue { recordRoutingPrefix(id, after: nil) }
        }
        for finding in assessment.findings {
            if finding.status == .compliant {
                unchanged.append(.string(finding.id))
                continue
            }
            let id = "output_" + finding.id
            routingIDs.append(id)
            var blocked = Set(finding.reasons.map(\.rawValue))
            if !request.domains.contains(.routing) { blocked.insert("routing_not_requested") }
            // The scalar operation takes a physical strip index; the current publication
            // explicitly has no verified track-to-strip association or preservation adapter.
            blocked.insert("exact_target_routing_adapter_unavailable")
            if OperationRegistry.spec(tool: "logic_mixer", command: "set_output_verified") == nil {
                blocked.insert("routing_operation_unregistered")
            }
            var dependencies: [String] = []
            if finding.expected.output == .bus, let bus = finding.expected.busNumber {
                // An output approves only the bus (#1090 review R3, R1090-004). With a `receivers`
                // entry the decision above applies; without one an observed absence is a question,
                // never a planned aux, and an unverified receiver blocks the output.
                let receiver = receiverRequirements(bus)
                blocked.formUnion(receiver.blocked)
                dependencies = receiver.dependencies
            }
            var proposalReasons = proposalReadReasons
            if blocked.contains("bus_receiver_unverified") { proposalReasons.insert("bus_receiver_unverified") }
            let proposal = try proposedExistingBusOutput(finding: finding, graph: proposedGraph, readReasons: proposalReasons)
            recordRoutingPrefix(id, after: proposal.after)
            blocked.formUnion(proposal.reasons)
            reasons.formUnion(blocked)
            var before: Value = .object([:])
            if let observed = finding.observed { before = try repairPlanValue(observed) }
            var step: [String: Value] = [
                "id": .string(id), "kind": .string("main_output"),
                "before": before, "after": try repairPlanValue(finding.expected),
                "proposed_routing_diff": proposal.wire,
                "blocked_reasons": .array(blocked.sorted().map(Value.string)),
                "dependencies": .array(dependencies.map(Value.string)),
                "required_invariants": .array([
                    "exact_strip_identity", "receiver_fanout", "intermediate_audio_paths",
                    "sidechain_and_monitoring_preservation", "inverse_output_assignment"
                ].map(Value.string))
            ]
            if let ref = finding.target.trackRef { step["target_ref"] = .string(ref) }
            steps.append(.object(step))
        }
        if !assessment.questions.isEmpty { reasons.insert("unresolved_intent") }

        for finding in assessment.sendFindings ?? [] {
            if finding.status == .compliant, proposalReadReasons.isEmpty {
                unchanged.append(.string(finding.id))
                continue
            }
            let id = "send_" + finding.id
            routingIDs.append(id)
            var blocked = Set(finding.reasons.map(\.rawValue))
            var dependencies: [String] = []
            var proposalReasons = proposalReadReasons
            if let bus = finding.expected.bus {
                let receiver = receiverRequirements(bus)
                blocked.formUnion(receiver.blocked)
                dependencies = receiver.dependencies
                if blocked.contains("bus_receiver_unverified") { proposalReasons.insert("bus_receiver_unverified") }
            }
            let proposal = try proposedExistingSend(finding: finding, graph: proposedGraph,
                readReasons: proposalReasons, allowReplace: options.allowReplaceSend)
            recordRoutingPrefix(id, after: proposal.after)
            blocked.formUnion(proposal.reasons)
            blocked.formUnion(["exact_target_send_adapter_unavailable", "send_preservation_adapter_unavailable"])
            reasons.formUnion(blocked)
            steps.append(.object([
                "id": .string(id), "kind": .string("send_assignment"),
                "target_ref": finding.target.trackRef.map(Value.string) ?? .null,
                "physical_slot": .int(finding.physicalSlot),
                "before": try finding.observed.map { try repairPlanValue($0) } ?? .null,
                "after": try repairPlanValue(finding.expected),
                "proposed_routing_diff": proposal.wire,
                "dependencies": .array(dependencies.map(Value.string)), "blocked_reasons": .array(blocked.sorted().map(Value.string)),
                "required_invariants": .array(["exact_strip_identity", "exact_send_slot_and_destination",
                    "preserved_send_scalars", "receiver_fanout", "protected_and_intermediate_audio_paths",
                    "channel_format_preservation", "sidechain_and_monitoring_preservation", "conditional_inverse_send"].map(Value.string))
            ]))
        }
        // Standalone approved receiver creation is topology work too, even with no source assignment.
        let topologyIDs = (Array(auxStepForBus.values) + routingIDs).sorted()
        // Matching names still require the same opted-in execution lifecycle for fresh verification.
        if !names.isEmpty, !FeatureFlags.adr004MutationSaga { reasons.insert("mutation_saga_unavailable") }
        for desired in names {
            guard let target = policy.targets.first(where: { $0.handle == desired.target }) else {
                throw CocoaError(.coderInvalidValue)
            }
            var blocked = Set<String>()
            if !request.domains.contains(.tracks) { blocked.insert("tracks_not_requested") }
            blocked.formUnion(SessionPopulationObservation.trackRowReadbackReasons(capture: capture).map(\.rawValue))
            var before: [String: Value] = [:]
            if capture.referencesEnabled, let issued = capture.issued,
               case .located(let index) = locate(target.trackRef, in: issued) {
                let rows = capture.tracks.filter { $0.id == index }
                if rows.count == 1, let row = rows.first {
                    before["name"] = .string(row.name)
                    // Only identical UTF-8 bytes represent an unchanged approved name, and only
                    // over a requested, current read. A stale or unrequested row matching the
                    // approved name is missing evidence, so it stays a task carrying its reasons.
                    if blocked.isEmpty, row.name.utf8.elementsEqual(desired.name.utf8) {
                        unchanged.append(.string("name_" + desired.target))
                        continue
                    }
                } else { blocked.insert("target_ambiguous_in_snapshot") }
            } else { blocked.insert("target_not_in_snapshot") }
            // Legacy rename does not accept the approved plan's coupled-name/inverse footprint.
            // Its existence alone cannot make this richer task executable.
            blocked.insert("naming_preservation_adapter_unavailable")
            if OperationRegistry.spec(tool: "logic_tracks", command: "rename") == nil {
                blocked.insert("naming_operation_unregistered")
            }
            reasons.formUnion(blocked)
            steps.append(.object([
                "id": .string("name_" + desired.target), "kind": .string("name"),
                "target_ref": .string(target.trackRef.rawValue),
                "before": .object(before), "after": .object(["name": .string(desired.name)]),
                "blocked_reasons": .array(blocked.sorted().map(Value.string)),
                "dependencies": .array(topologyIDs.map(Value.string)),
                "required_invariants": .array([
                    "exact_track_identity", "coupled_name_preservation", "inverse_name"
                ].map(Value.string))
            ]))
        }
        let approvedNames: [Value] = names.map { .object([
            "target": .string($0.target), "name": .string($0.name)
        ]) }
        steps = auxSteps + steps
        if let sort = policy.trackSort {
            let tracks = SessionPopulationObservation.build(request: request, capture: capture).tracks
            let originalOrder = tracks.rows.compactMap(\.trackRef)
            // A readable rail is not proof of the whole project. Preserve that scope in the
            // proposed inverse; no live locale/footprint/adapter is invented by this draft.
            var blocked: Set<String> = ["sort_coupled_footprint_unavailable", "sort_preservation_adapter_unavailable"]
            let locale = capture.freshPopulation?.presentationObservation?.uiLocale
            if locale != capture.freshPopulation?.presentationBinding?.uiLocale
                || sort.criterion.measuredLabel(for: locale) == nil
                || sort.inverseCriterion.measuredLabel(for: locale) == nil {
                blocked.insert("sort_locale_measurement_unavailable")
            }
            if tracks.coverage != .complete { blocked.insert("track_population_incomplete") }
            if originalOrder.count != tracks.rows.count || Set(originalOrder).count != originalOrder.count {
                blocked.insert("sort_track_references_unavailable")
            }
            if originalOrder.count != sort.expectedOrder.count || Set(originalOrder) != Set(sort.expectedOrder) {
                blocked.insert("sort_expected_order_not_capture_permutation")
            }
            if case .issued(let reference)? = capture.projectIssuance {
                if policy.projectRef != reference { blocked.insert("approved_project_reference_required") }
            } else { blocked.insert("approved_project_reference_required") }
            let observation = capture.freshPopulation?.presentationObservation
            if observation?.isPlaying == nil || observation?.isRecording == nil {
                blocked.insert("transport_state_unobserved")
            } else if observation?.isPlaying != false || observation?.isRecording != false {
                blocked.insert("transport_not_stopped")
            }
            reasons.formUnion(blocked)
            // Sort the approved final names/topology, not an independently schedulable earlier state.
            let dependencies = steps.compactMap { $0.objectValue?["id"]?.stringValue }.sorted()
            steps.append(.object([
                "id": .string("track_sort"), "kind": .string("track_sort"),
                "target_ref": policy.projectRef.map { .string($0.rawValue) } ?? .null,
                "before": .object(["order": .array(originalOrder.map(Value.string)),
                    "coverage": .string(tracks.coverage.rawValue)]),
                "after": .object(["criterion": .string(sort.criterion.rawValue),
                    "order": .array(sort.expectedOrder.map(Value.string))]),
                "inverse": .object(["criterion": .string(sort.inverseCriterion.rawValue),
                    "expected_order": .array(originalOrder.map(Value.string))]),
                "dependencies": .array(dependencies.map(Value.string)), "blocked_reasons": .array(blocked.sorted().map(Value.string)),
                "required_invariants": .array(["complete_issued_track_order", "observed_stopped_non_recording",
                    "measured_sort_menu", "conditional_inverse_order", "coupled_sort_preservation"].map(Value.string))
            ]))
        }
        if let desired = policy.mixerVisible {
            var blocked = Set<String>()
            if !FeatureFlags.adr004MutationSaga { blocked.insert("mutation_saga_unavailable") }
            let observation = capture.freshPopulation?.presentationObservation
            if capture.freshPopulation?.stable != true || capture.freshPopulation?.presentationBinding == nil {
                blocked.insert("project_view_binding_unavailable")
            }
            if observation?.mixerVisible == nil { blocked.insert("mixer_visibility_unobserved") }
            if observation?.isPlaying == nil || observation?.isRecording == nil {
                blocked.insert("transport_state_unobserved")
            } else if observation?.isPlaying != false || observation?.isRecording != false {
                blocked.insert("transport_not_stopped")
            }
            if case .issued(let reference)? = capture.projectIssuance {
                if policy.projectRef != reference { blocked.insert("approved_project_reference_required") }
            } else { blocked.insert("approved_project_reference_required") }
            reasons.formUnion(blocked)
            let dependencies = steps.compactMap { $0.objectValue?["id"]?.stringValue }.sorted()
            steps.append(.object([
                "id": .string("mixer_visibility"), "kind": .string("mixer_visibility"),
                "target_ref": policy.projectRef.map { .string($0.rawValue) } ?? .null,
                "before": .object(["visible": observation?.mixerVisible.map(Value.bool) ?? .null]),
                "after": .object(["visible": .bool(desired)]),
                "dependencies": .array(dependencies.map(Value.string)), "blocked_reasons": .array(blocked.sorted().map(Value.string)),
                "required_invariants": .array(["project_bound_view", "observed_stopped_non_recording",
                    "conditional_inverse_visibility", "menu_cleanup"].map(Value.string))
            ]))
        }
        // Sampled compliance is not a provider. The retained adapter owns its finite scope
        // and required captured footprint; execution repeats freshness/registry/AX checks.
        if reasons.isEmpty, !ApprovedSessionRepair.canVerifyCapturedGoals(policy: policy, policyValue: policyValue,
            names: names, source: capture, request: request) {
            reasons.insert("retained_goal_verification_unavailable")
        }
        // Preview is this canonical step array; no independently generated preview can drift.
        var body: [String: Value] = [
            "schema": .string(sessionRepairPlanSchema), "read_only": .bool(true),
            "baseline_snapshot_id": .string(capture.captureID),
            "requires_plan_confirmation": .bool(true),
            "approved_policy": policyValue, "approved_names": .array(approvedNames),
            "steps": .array(steps), "preview": .array(steps),
            "unchanged_tasks": .array(unchanged), "questions": try repairPlanValue(assessment.questions),
            "receiver_questions": .array(receiverQuestions.keys.sorted().compactMap { receiverQuestions[$0] }),
            "findings": .array(try assessment.findings.map { try repairPlanValue($0) }
                + (assessment.sendFindings ?? []).map { try repairPlanValue($0) }),
            "new_object_inventory": .array(inventory),
            "planning_options": options.wire,
            "executable": .bool(reasons.isEmpty),
            "reasons": .array(reasons.sorted().map(Value.string))
        ]
        if !protectedReads.isEmpty { body["protected_invariants"] = .array(protectedReads.map(\.wire)) }
        let canonical = try encodeJSONStrict(Value.object(body), compact: true)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = "plan_" + UUID().uuidString
        body["digest"] = .string(digest)
        body["plan_id"] = .string(id)
        return CanonicalRepairPlan(id: id, digest: digest,
            json: try encodeJSONStrict(Value.object(body), compact: true))
    }

    /// A desired-policy delta, not an observed after-state or an audio-safety verdict. All
    /// unrelated edges are copied unchanged; receiving-aux fanout is not a main-output duplicate.
    private static func proposedExistingBusOutput(
        finding: IntentFinding, graph: RoutingGraph, readReasons: Set<String>
    ) throws -> (wire: Value, reasons: Set<String>, after: RoutingGraph?) {
        var reasons = readReasons
        if finding.status != .violation {
            reasons.formUnion(finding.reasons.map(\.rawValue))
            reasons.insert("main_output_proposal_unverified")
        }
        for (name, domain) in [
            ("population", graph.coverage.population),
            ("strip_track_association", graph.coverage.stripTrackAssociation),
            ("main_output", graph.coverage.mainOutput),
            ("bus_to_aux_input", graph.coverage.busToAuxInput),
            ("sends", graph.coverage.sends),
        ] where domain.state != .complete {
            reasons.insert("proposed_\(name)_coverage_incomplete")
        }
        func unverified(_ reason: String? = nil) -> (Value, Set<String>, RoutingGraph?) {
            if let reason { reasons.insert(reason) }
            return (.object([
                "status": .string("unverified"), "basis": .string("approved_policy"),
                "observation": .string("proposed_not_observed"),
                "reasons": .array(reasons.sorted().map(Value.string)),
            ]), reasons, nil)
        }
        guard reasons.isEmpty else { return unverified() }
        guard graph.edges.allSatisfy({ $0.send?.level?.isFinite ?? true }) else {
            return unverified("send_scalar_unserializable")
        }
        guard finding.expected.output == .bus || finding.expected.output == .noOutput else {
            return unverified("main_output_proposal_unsupported")
        }
        guard let rawRef = finding.target.trackRef else { return unverified("proposed_source_unavailable") }
        let sources = graph.nodes.filter { $0.targetRef?.rawValue == rawRef }
        guard sources.count == 1, let source = sources.first,
              graph.nodes.filter({ $0.id == source.id }).count == 1 else {
            return unverified("proposed_source_ambiguous")
        }
        guard source.kind == .track else { return unverified("proposed_source_not_track") }
        guard source.outputClassification == .bus else {
            return unverified("proposed_before_output_not_bus")
        }
        var destination: RoutingNode?
        if finding.expected.output == .bus {
            guard let bus = finding.expected.busNumber else {
                return unverified("main_output_proposal_unsupported")
            }
            let destinations = graph.nodes.filter { $0.kind == .bus && $0.busNumber == bus }
            guard destinations.count == 1, let unique = destinations.first,
                  graph.nodes.filter({ $0.id == unique.id }).count == 1 else {
                return unverified("proposed_destination_not_unique_bus")
            }
            destination = unique
        }
        // routingDiff keys outputs by source (and sends by reference/slot), with last-wins
        // dictionaries. Reject ambiguity before invoking it, including unrelated output keys.
        let outputs = graph.edges.filter { $0.kind == .mainOutput }
        guard Dictionary(grouping: outputs, by: \.source).values.allSatisfy({ $0.count == 1 }),
              outputs.allSatisfy({ $0.send == nil }) else {
            return unverified("proposed_output_assignments_ambiguous")
        }
        var sendSlots: [TargetReference: Set<Int>] = [:]
        for edge in graph.edges where edge.kind == .send {
            guard let send = edge.send,
                  sendSlots[send.sourceTrackRef, default: []].insert(send.physicalSlot).inserted else {
                return unverified("proposed_send_assignments_ambiguous")
            }
        }
        let sourceOutputs = outputs.filter { $0.source == source.id }
        guard sourceOutputs.count == 1, let before = sourceOutputs.first else {
            return unverified("proposed_source_output_unavailable")
        }
        // The assessor already checks the observed bus number, but the proposal additionally
        // requires an actual bus node: an aux's label/number cannot supply either endpoint.
        let previousNodes = graph.nodes.filter { $0.id == before.destination }
        guard previousNodes.count == 1, let previous = previousNodes.first, previous.kind == .bus else {
            return unverified("proposed_before_destination_not_unique_bus")
        }
        // An approved no-output intent removes this exact observed edge, not its bus or receivers.
        let desired = destination.map {
            RoutingEdge(kind: .mainOutput, source: source.id, destination: $0.id,
                        send: nil, provenance: .other)
        }
        let after = RoutingGraph(
            projectReference: graph.projectReference, projectEpoch: graph.projectEpoch,
            complete: graph.complete, partialReason: graph.partialReason, nodes: graph.nodes,
            edges: graph.edges.compactMap { $0 == before ? desired : $0 },
            provenance: graph.provenance.contains(.other) ? graph.provenance : graph.provenance + [.other],
            snapshotId: graph.snapshotId, coverage: graph.coverage
        )
        return (try proposedRoutingDiffValue(routingDiff(before: graph, after: after)), [], after)
    }

    private static func proposedExistingSend(finding: IntentSendFinding, graph: RoutingGraph,
                                             readReasons: Set<String>, allowReplace: Bool) throws -> (wire: Value, reasons: Set<String>, after: RoutingGraph?) {
        var reasons = readReasons.union(finding.reasons.map(\.rawValue))
        func unverified(_ reason: String? = nil) -> (Value, Set<String>, RoutingGraph?) {
            if let reason { reasons.insert(reason) }
            return (.object(["status": .string("unverified"), "basis": .string("approved_policy"),
                "observation": .string("proposed_not_observed"), "reasons": .array(reasons.sorted().map(Value.string))]), reasons, nil)
        }
        guard reasons.isEmpty, finding.status == .violation else { return unverified() }
        guard graph.edges.allSatisfy({ $0.send?.level?.isFinite ?? true }) else {
            return unverified("send_scalar_unserializable")
        }
        guard let before = finding.observed, let observed = before.send,
              let rawRef = finding.target.trackRef else {
            // An empty slot has no observed scalar defaults to preserve. Account for that task,
            // but don't invent a level, mode or enabled state for a new connection.
            return unverified("send_creation_metadata_unavailable")
        }
        let request = RoutingWriteRequest(sourceTrackRef: TargetReference(rawValue: rawRef),
            physicalSlot: finding.physicalSlot, destinationBusNumber: finding.expected.bus ?? observed.destinationBusNumber,
            destinationRef: finding.expected.bus == nil ? observed.destinationRef : nil,
            replaceExisting: finding.expected.bus == nil || allowReplace, expectedProjectEpoch: graph.projectEpoch)
        let decision = evaluate(request, against: graph)
        guard decision.allowed else {
            for rejection in decision.rejections {
                if case .slotOccupied = rejection { reasons.insert("send_replacement_not_allowed") }
                else { reasons.insert("send_graph_unsafe_\(String(describing: rejection))") }
            }
            return unverified()
        }
        // routingDiff's assignment maps are last-wins; don't use that behavior to conceal
        // contradictory unrelated output facts while proposing a send delta.
        let outputs = graph.edges.filter { $0.kind == .mainOutput }
        guard Dictionary(grouping: outputs, by: \.source).values.allSatisfy({ $0.count == 1 }),
              outputs.allSatisfy({ $0.send == nil }) else { return unverified("proposed_output_assignments_ambiguous") }
        var desired: RoutingEdge?
        if let bus = finding.expected.bus {
            let destinations = graph.nodes.filter { $0.kind == .bus && $0.busNumber == bus }
            guard destinations.count == 1, let destination = destinations.first else {
                return unverified("proposed_destination_not_unique_bus")
            }
            desired = RoutingEdge(kind: .send, source: before.source, destination: destination.id,
                send: SendEdge(sourceTrackRef: observed.sourceTrackRef, physicalSlot: observed.physicalSlot,
                    destinationBusNumber: bus, destinationRef: destination.targetRef,
                    displayedName: observed.displayedName, level: observed.level, mode: observed.mode, enabled: observed.enabled),
                provenance: .other)
        }
        let after = RoutingGraph(projectReference: graph.projectReference, projectEpoch: graph.projectEpoch,
            complete: graph.complete, partialReason: graph.partialReason, nodes: graph.nodes,
            edges: graph.edges.compactMap { $0 == before ? desired : $0 },
            provenance: graph.provenance.contains(.other) ? graph.provenance : graph.provenance + [.other],
            snapshotId: graph.snapshotId, coverage: graph.coverage)
        return (try proposedRoutingDiffValue(routingDiff(before: graph, after: after)), [], after)
    }

    private static func proposedRoutingDiffValue(_ diff: RoutingDiff) throws -> Value {
        func changeValue(_ change: RoutingEdgeChange) throws -> Value {
            .object([
                "before": try change.before.map { try repairPlanValue($0) } ?? .null,
                "after": try change.after.map { try repairPlanValue($0) } ?? .null,
            ])
        }
        return .object([
            "status": .string("proposed"), "basis": .string("approved_policy"),
            "observation": .string("proposed_not_observed"),
            "output_changes": .array(try diff.outputChanges.map(changeValue)),
            "input_changes": .array(try diff.inputChanges.map(changeValue)),
            "added_sends": .array(try diff.addedSends.map { try repairPlanValue($0) }),
            "removed_sends": .array(try diff.removedSends.map { try repairPlanValue($0) }),
            "changed_sends": .array(try diff.changedSends.map {
                .object(["before": try repairPlanValue($0.before), "after": try repairPlanValue($0.after)])
            }),
        ])
    }

    enum ReceivingAux: Equatable {
        case present
        case absent
        case unverified
    }

    /// Whether bus `bus` feeds an aux input in `graph`. Absence is concluded only from a complete
    /// bus-to-aux reading; anything less is unverified, never absent (ADR-021 section 4).
    ///
    /// Each endpoint must be attributable (#1090 review R3, R1090-003): at most one node may carry
    /// bus `bus`, and its id no other node. Only the input edges leaving that node are examined;
    /// each must end at exactly one node, an aux, or the answer is unverified. A bus no node
    /// carries has no edge leaving it, so a complete bus-to-aux reading reads it as absent: nothing
    /// is observed reading it (#1090 supplementary review S003).
    static func receivingAux(bus: Int, graph: RoutingGraph) -> ReceivingAux {
        let nodesByID = Dictionary(grouping: graph.nodes, by: \.id)
        let busNodes = graph.nodes.filter { $0.kind == .bus && $0.busNumber == bus }
        guard busNodes.count <= 1, busNodes.allSatisfy({ nodesByID[$0.id]?.count == 1 }) else {
            return .unverified
        }
        let busIDs = Set(busNodes.map(\.id))
        let receivers = graph.edges.filter { $0.kind == .inputAssignment && busIDs.contains($0.source) }
        for edge in receivers {
            guard let ends = nodesByID[edge.destination], ends.count == 1, ends[0].kind == .aux else {
                return .unverified
            }
        }
        if !receivers.isEmpty { return .present }
        return graph.coverage.busToAuxInput.state == .complete ? .absent : .unverified
    }

    private static func repairPlanValue<T: Encodable>(_ value: T) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(encodeJSONStrict(value, compact: true).utf8))
    }
}
