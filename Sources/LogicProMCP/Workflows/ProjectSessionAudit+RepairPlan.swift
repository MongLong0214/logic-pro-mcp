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
        var reasons = Set<String>()
        if !snapshotCurrent { reasons.insert("snapshot_changed") }
        if request.scope != .wholeProject { reasons.insert("whole_project_scope_required") }
        let gate = assessmentGate(policy: policy, capture: capture, graph: graph)
        if let gate { reasons.insert(gate.reason.rawValue) }
        // The whole binding the assessor applies: the gate, and the registry epoch it checks per
        // finding (#1090 review R2, R1090-002). Receiver evidence is read only from a graph both pass.
        let epochMismatch = graphEpochMismatch(graph, capture: capture)
        if let epochMismatch { reasons.insert(epochMismatch.rawValue) }
        let graphBound = gate == nil && epochMismatch == nil
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
        var steps: [Value] = []
        var unchanged: [Value] = []
        var routingIDs: [String] = []
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
                if policy.receivers[bus] != nil {
                    blocked.formUnion(receiverBlocks[bus] ?? [])
                    if let auxID = auxStepForBus[bus] { dependencies.append(auxID) }
                } else {
                    switch observedReceiver(bus) {
                    case .unverified: blocked.insert("bus_receiver_unverified")
                    case .absent: receiverQuestion(bus, observed: .absent)
                    case .present: break
                    }
                }
            }
            reasons.formUnion(blocked)
            var before: Value = .object([:])
            if let observed = finding.observed { before = try repairPlanValue(observed) }
            var step: [String: Value] = [
                "id": .string(id), "kind": .string("main_output"),
                "before": before, "after": try repairPlanValue(finding.expected),
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
                "dependencies": .array(routingIDs.sorted().map(Value.string)),
                "required_invariants": .array([
                    "exact_track_identity", "coupled_name_preservation", "inverse_name"
                ].map(Value.string))
            ]))
        }
        let approvedNames: [Value] = names.map { .object([
            "target": .string($0.target), "name": .string($0.name)
        ]) }
        steps = auxSteps + steps
        // Preview is this canonical step array; no independently generated preview can drift.
        var body: [String: Value] = [
            "schema": .string(sessionRepairPlanSchema), "read_only": .bool(true),
            "baseline_snapshot_id": .string(capture.captureID),
            "requires_plan_confirmation": .bool(true),
            "approved_policy": policyValue, "approved_names": .array(approvedNames),
            "steps": .array(steps), "preview": .array(steps),
            "unchanged_tasks": .array(unchanged), "questions": try repairPlanValue(assessment.questions),
            "receiver_questions": .array(receiverQuestions.keys.sorted().compactMap { receiverQuestions[$0] }),
            "findings": try repairPlanValue(assessment.findings),
            "new_object_inventory": .array(inventory),
            "planning_options": options.wire,
            "executable": .bool(reasons.isEmpty),
            "reasons": .array(reasons.sorted().map(Value.string))
        ]
        let canonical = try encodeJSONStrict(Value.object(body), compact: true)
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = "plan_" + UUID().uuidString
        body["digest"] = .string(digest)
        body["plan_id"] = .string(id)
        return CanonicalRepairPlan(id: id, digest: digest,
            json: try encodeJSONStrict(Value.object(body), compact: true))
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
