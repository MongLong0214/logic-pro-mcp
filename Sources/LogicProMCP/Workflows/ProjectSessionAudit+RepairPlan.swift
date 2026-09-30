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
        snapshotCurrent: Bool
    ) throws -> CanonicalRepairPlan {
        let graph = SessionPopulationObservation.routingGraph(capture: capture)
        let assessment = assessIntent(policy: policy, capture: capture, graph: graph)
        var reasons = Set<String>()
        if !snapshotCurrent { reasons.insert("snapshot_changed") }
        if request.scope != .wholeProject { reasons.insert("whole_project_scope_required") }
        if let gate = assessmentGate(policy: policy, capture: capture, graph: graph) {
            reasons.insert(gate.reason.rawValue)
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
            reasons.formUnion(blocked)
            var before: Value = .object([:])
            if let observed = finding.observed { before = try repairPlanValue(observed) }
            var step: [String: Value] = [
                "id": .string(id), "kind": .string("main_output"),
                "before": before, "after": try repairPlanValue(finding.expected),
                "blocked_reasons": .array(blocked.sorted().map(Value.string)),
                "dependencies": .array([]),
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
            var before: [String: Value] = [:]
            if capture.referencesEnabled, let issued = capture.issued,
               case .located(let index) = locate(target.trackRef, in: issued) {
                let rows = capture.tracks.filter { $0.id == index }
                if rows.count == 1, let row = rows.first {
                    before["name"] = .string(row.name)
                    // Only identical UTF-8 bytes represent an unchanged approved name.
                    if row.name.utf8.elementsEqual(desired.name.utf8) {
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
        // Preview is this canonical step array; no independently generated preview can drift.
        var body: [String: Value] = [
            "schema": .string(sessionRepairPlanSchema), "read_only": .bool(true),
            "baseline_snapshot_id": .string(capture.captureID),
            "requires_plan_confirmation": .bool(true),
            "approved_policy": policyValue, "approved_names": .array(approvedNames),
            "steps": .array(steps), "preview": .array(steps),
            "unchanged_tasks": .array(unchanged), "questions": try repairPlanValue(assessment.questions),
            "findings": try repairPlanValue(assessment.findings),
            "new_object_inventory": .array([]),
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

    private static func repairPlanValue<T: Encodable>(_ value: T) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(encodeJSONStrict(value, compact: true).utf8))
    }
}
