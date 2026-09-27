import Foundation
import MCP

// #966 P1 (ADR-021): a finite intent model over #28's audit and one deterministic rule.
//
// Everything here lives inside `ProjectSessionAudit` so the namespace is extended, not
// paralleled, and nothing here touches the legacy `Finding`, `buildAudit` or the cleanup plan: a
// #28 client keeps the wire contract ProjectSessionAuditTests pins. The assessor consumes a #965
// `Capture` and the #291 `RoutingGraph` published from that same capture as immutable data. It
// never sees a cache, a router, a registry or the host, and the same inputs always encode to the
// same bytes.
//
// What the rule reads: the capture's boundaries and issued references, the graph's snapshot id,
// consistency, epoch and the `main_output` / `strip_track_association` coverage states, the source
// node found by `targetRef`, its `outputClassification`, its `.mainOutput` edges and the
// destination's `busNumber`. What it never reads: a track name, type or output label, a coverage
// reason string, any `SendEdge` field, a `.send` or `.inputAssignment` edge, a level, an enabled
// flag, or a track's automation or mute state. ADR-021 section 2: none of those proves a route right, and
// none proves a connection absent. `displayName` and the coverage reasons are copied into the
// finding as evidence for the reader; no decision is taken on them.

extension ProjectSessionAudit {
    static let intentPolicySchema = "logic_pro_mcp_repair_policy.v1"
    static let intentAssessmentSchema = "logic_pro_mcp_intent_assessment.v1"
    static let mainOutputAssignmentRule = "main_output_assignment"

    // MARK: - Approved intent (input)

    /// An exact existing track the client names. `handle` is local to the policy; `trackRef` is a
    /// reference the #965 capture issued, which is the only binding to an observed host object.
    struct IntentTarget: Equatable, Sendable {
        let handle: String
        let trackRef: TargetReference
    }

    struct IntentRoleMember: Equatable, Sendable {
        let handle: String
        let accepted: Bool
    }

    /// A proposed role. Members the client has not accepted are candidates, and a role with no
    /// accepted member stays a question (ADR-021 section 2): the rule never picks one from a name.
    struct IntentRole: Equatable, Sendable {
        let role: String
        let members: [IntentRoleMember]
    }

    enum IntentSubject: Equatable, Sendable {
        case target(String)
        case role(String)
    }

    /// Where a subject's main output is meant to go: an existing bus, or deliberately nowhere. P1
    /// accepts `bus >= 1` only; the bus namespace (its upper bound, what is allocated) is evidence
    /// #291/#967 own, not a guess made here.
    enum IntentMainOutput: Hashable, Sendable {
        case bus(Int)
        case noOutput

        /// The wire form a conflict is reported and sorted by.
        var token: String {
            switch self {
            case .bus(let number): return "bus_\(number)"
            case .noOutput: return RoutingOutputClassification.noOutput.rawValue
            }
        }

        /// `no_output` before every bus, buses ascending.
        static func ordered(_ outputs: Set<IntentMainOutput>) -> [IntentMainOutput] {
            outputs.sorted { lhs, rhs in
                switch (lhs, rhs) {
                case (.noOutput, .bus): return true
                case (.bus(let left), .bus(let right)): return left < right
                default: return false
                }
            }
        }
    }

    struct IntentOutput: Equatable, Sendable {
        let subject: IntentSubject
        let destination: IntentMainOutput
    }

    /// Only `parseIntentPolicy` constructs this, so `assessIntent` never sees an unvalidated policy.
    /// `projectRef`, when present, is the project the policy was written for.
    struct IntentPolicy: Equatable, Sendable {
        let projectRef: TargetReference?
        let targets: [IntentTarget]
        let roles: [IntentRole]
        let outputs: [IntentOutput]

        fileprivate init(
            projectRef: TargetReference?,
            targets: [IntentTarget],
            roles: [IntentRole],
            outputs: [IntentOutput]
        ) {
            self.projectRef = projectRef
            self.targets = targets
            self.roles = roles
            self.outputs = outputs
        }
    }

    enum IntentPolicyRejection: Equatable, Sendable {
        case unsupportedSchema(String)
        case unknownKey(path: String, key: String)
        case missingKey(path: String, key: String)
        case wrongType(path: String, expected: String)
        case invalidHandle(path: String)
        case duplicateHandle(String)
        case duplicateTrackRef(String)
        case unsupportedTargetRef(handle: String, ref: String)
        case unsupportedProjectRef(String)
        case unknownSubject(path: String, subject: String)
        case outputNamesBothOrNeither(path: String)
        case outputDestinationBothOrNeither(path: String)
        case unsupportedOutput(path: String, value: String)
        case conflictingOutputs(subject: String, outputs: [IntentMainOutput])
        case busBelowOne(path: String, value: Int)

        /// The deterministic form the rejection list is sorted by.
        var sortKey: String {
            switch self {
            case .unsupportedSchema(let schema):
                return "unsupported_schema \(schema)"
            case .unknownKey(let path, let key):
                return "unknown_key \(path).\(key)"
            case .missingKey(let path, let key):
                return "missing_key \(path).\(key)"
            case .wrongType(let path, let expected):
                return "wrong_type \(path) expected \(expected)"
            case .invalidHandle(let path):
                return "invalid_handle \(path)"
            case .duplicateHandle(let handle):
                return "duplicate_handle \(handle)"
            case .duplicateTrackRef(let ref):
                return "duplicate_track_ref \(ref)"
            case .unsupportedTargetRef(let handle, let ref):
                return "unsupported_target_ref \(handle) \(ref)"
            case .unsupportedProjectRef(let ref):
                return "unsupported_project_ref \(ref)"
            case .unknownSubject(let path, let subject):
                return "unknown_subject \(path) \(subject)"
            case .outputNamesBothOrNeither(let path):
                return "output_names_both_or_neither \(path)"
            case .outputDestinationBothOrNeither(let path):
                return "output_destination_both_or_neither \(path)"
            case .unsupportedOutput(let path, let value):
                return "unsupported_output \(path) \(value)"
            case .conflictingOutputs(let subject, let outputs):
                return "conflicting_outputs \(subject) \(outputs.map(\.token))"
            case .busBelowOne(let path, let value):
                return "bus_below_one \(path) \(value)"
            }
        }
    }

    enum IntentPolicyParse: Equatable, Sendable {
        case accepted(IntentPolicy)
        case rejected([IntentPolicyRejection])
    }

    // MARK: - Assessment (output)

    enum IntentStatus: String, Codable, Sendable {
        case compliant
        case violation
        case needsInput = "needs_input"
        case unverified
        case outsideScope = "outside_scope"
    }

    /// Every P1 finding rests on `approved_policy`. The other two are declared so a later phase
    /// keeps observed facts, approved intent and preference distinguishable on the wire.
    enum IntentBasis: String, Codable, Sendable {
        case observedStructure = "observed_structure"
        case approvedPolicy = "approved_policy"
        case preference
    }

    enum IntentReason: String, Codable, Sendable {
        // Capture and graph validity: the graph cannot be read against this capture at all.
        case cacheMovedDuringCapture = "cache_moved_during_capture"
        case graphNotFromCapture = "graph_not_from_capture"
        case routingGraphInconsistent = "routing_graph_inconsistent"
        case noDocument = "no_document"
        case axOccluded = "ax_occluded"
        // The policy's project and the target's reference.
        case projectReferenceUnavailable = "project_reference_unavailable"
        case policyProjectMismatch = "policy_project_mismatch"
        case referencesUnavailable = "references_unavailable"
        case targetSnapshotStale = "target_snapshot_stale"
        case targetNotInSnapshot = "target_not_in_snapshot"
        case graphEpochMismatch = "graph_epoch_mismatch"
        // Domain coverage: compliant and violation need both domains complete.
        case mainOutputCoverageIncomplete = "main_output_coverage_incomplete"
        case stripTrackAssociationIncomplete = "strip_track_association_incomplete"
        // The source's own output.
        case trackNotInGraph = "track_not_in_graph"
        case sourceNodeAmbiguous = "source_node_ambiguous"
        case outputUnclassified = "output_unclassified"
        case outputEdgeAmbiguous = "output_edge_ambiguous"
        case expectedBusNotObserved = "expected_bus_not_observed"
        case roleHasNoAcceptedMember = "role_has_no_accepted_member"
    }

    enum IntentAspect: String, Codable, Sendable {
        case sends
        case sidechain
        case monitoring

        /// The main-output rule reads none of these: #291 publishes no send edge (send slots
        /// answer occupancy, not destination), and sidechain and monitoring have no reader at all.
        /// Every finding names all three as not verified, so a consumer cannot mistake silence for
        /// coverage.
        static let withoutObservationSource: [IntentAspect] = [.sends, .sidechain, .monitoring]
    }

    /// `main_output` and `strip_track_association` are the graph's two domain coverages copied
    /// verbatim, reasons included, as evidence: the status reads their `state` only.
    /// `expected_bus_observed` is absent when the policy expects no output.
    struct IntentCoverage: Encodable, Equatable, Sendable {
        let outputEdgeObserved: Bool
        let destinationBusObserved: Bool
        let expectedBusObserved: Bool?
        let graphComplete: Bool
        let mainOutput: RoutingDomainCoverage
        let stripTrackAssociation: RoutingDomainCoverage
        let notVerified: [IntentAspect]

        enum CodingKeys: String, CodingKey {
            case outputEdgeObserved = "output_edge_observed"
            case destinationBusObserved = "destination_bus_observed"
            case expectedBusObserved = "expected_bus_observed"
            case graphComplete = "graph_complete"
            case mainOutput = "main_output"
            case stripTrackAssociation = "strip_track_association"
            case notVerified = "not_verified"
        }
    }

    /// `expected` carries `output` (`bus` with its `bus_number`, or `no_output`) and no node
    /// fields: intent names a bus, not a node. `observed` carries the source's classified `output`
    /// and, for a bus, the destination node the one `mainOutput` edge reaches.
    struct IntentEndpoint: Encodable, Equatable, Sendable {
        let nodeId: String?
        let displayName: String?
        let busNumber: Int?
        let output: RoutingOutputClassification

        enum CodingKeys: String, CodingKey {
            case nodeId = "node_id"
            case displayName = "display_name"
            case busNumber = "bus_number"
            case output
        }

        static func expected(_ destination: IntentMainOutput) -> IntentEndpoint {
            switch destination {
            case .bus(let number):
                return IntentEndpoint(nodeId: nil, displayName: nil, busNumber: number, output: .bus)
            case .noOutput:
                return IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .noOutput)
            }
        }
    }

    struct IntentTargetEvidence: Encodable, Equatable, Sendable {
        let handle: String?
        let role: String?
        let trackRef: String?
        let trackIndex: Int?

        enum CodingKeys: String, CodingKey {
            case handle
            case role
            case trackRef = "track_ref"
            case trackIndex = "track_index"
        }
    }

    struct IntentFinding: Encodable, Equatable, Sendable {
        let id: String
        let rule: String
        let basis: IntentBasis
        let severity: Severity
        let status: IntentStatus
        let target: IntentTargetEvidence
        let observed: IntentEndpoint?
        let expected: IntentEndpoint
        let coverage: IntentCoverage
        let reasons: [IntentReason]
    }

    struct IntentCandidate: Encodable, Equatable, Sendable {
        let handle: String
        let trackRef: String

        enum CodingKeys: String, CodingKey {
            case handle
            case trackRef = "track_ref"
        }
    }

    /// Candidates are exactly the role's unaccepted members as the client proposed them. No track
    /// name, type or label is consulted to add or remove one.
    struct IntentQuestion: Encodable, Equatable, Sendable {
        let id: String
        let role: String
        let rule: String
        let expected: IntentEndpoint
        let candidates: [IntentCandidate]
    }

    struct IntentAssessment: Encodable, Equatable, Sendable {
        let schema: String
        let readOnly: Bool
        let snapshotId: String
        let projectEpoch: UInt64
        let graphProjectEpoch: UInt64
        let findings: [IntentFinding]
        let questions: [IntentQuestion]
        let changeRequired: Bool

        enum CodingKeys: String, CodingKey {
            case schema
            case readOnly = "read_only"
            case snapshotId = "snapshot_id"
            case projectEpoch = "project_epoch"
            case graphProjectEpoch = "graph_project_epoch"
            case findings
            case questions
            case changeRequired = "change_required"
        }
    }

    // MARK: - Policy parsing

    private static let maxHandleBytes = 128
    private static let trackReferencePrefix = "trk_"
    private static let projectReferencePrefix = "prj_"

    /// Parses a wire policy. Every rejection is collected, so a client sees the whole list at
    /// once, and the list is sorted by `sortKey` so two parses of one object are equal.
    static func parseIntentPolicy(_ object: [String: Value]) -> IntentPolicyParse {
        var rejections: [IntentPolicyRejection] = []
        rejectUnknownKeys(
            object,
            allowed: ["schema", "project_ref", "targets", "roles", "outputs"],
            path: "policy",
            into: &rejections
        )

        if let rawSchema = object["schema"] {
            if let schema = rawSchema.stringValue {
                if schema != intentPolicySchema {
                    rejections.append(.unsupportedSchema(schema))
                }
            } else {
                rejections.append(.wrongType(path: "policy.schema", expected: "string"))
            }
        } else {
            rejections.append(.missingKey(path: "policy", key: "schema"))
        }

        let projectRef = optionalString(object, key: "project_ref", path: "policy", into: &rejections)
        if let projectRef, !projectRef.hasPrefix(projectReferencePrefix) {
            rejections.append(.unsupportedProjectRef(projectRef))
        }
        let targets = parseTargets(object, into: &rejections)
        let roles = parseRoles(object, into: &rejections)
        let outputs = parseOutputs(object, into: &rejections)
        validate(targets: targets, roles: roles, outputs: outputs, into: &rejections)

        guard rejections.isEmpty else {
            var unique: [IntentPolicyRejection] = []
            for rejection in rejections.sorted(by: { $0.sortKey < $1.sortKey }) where !unique.contains(rejection) {
                unique.append(rejection)
            }
            return .rejected(unique)
        }
        return .accepted(IntentPolicy(
            projectRef: projectRef.map(TargetReference.init(rawValue:)),
            targets: targets,
            roles: roles,
            outputs: outputs
        ))
    }

    private static func parseTargets(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentTarget] {
        guard let rawTargets = object["targets"] else {
            rejections.append(.missingKey(path: "policy", key: "targets"))
            return []
        }
        guard let array = rawTargets.arrayValue else {
            rejections.append(.wrongType(path: "policy.targets", expected: "array"))
            return []
        }
        var targets: [IntentTarget] = []
        for (index, element) in array.enumerated() {
            let path = "policy.targets[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            rejectUnknownKeys(entry, allowed: ["handle", "track_ref"], path: path, into: &rejections)
            let handle = requiredString(entry, key: "handle", path: path, into: &rejections)
            let trackRef = requiredString(entry, key: "track_ref", path: path, into: &rejections)
            guard let handle, let trackRef else { continue }
            targets.append(IntentTarget(handle: handle, trackRef: TargetReference(rawValue: trackRef)))
        }
        return targets
    }

    private static func parseRoles(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentRole] {
        guard let rawRoles = object["roles"] else { return [] }
        guard let array = rawRoles.arrayValue else {
            rejections.append(.wrongType(path: "policy.roles", expected: "array"))
            return []
        }
        var roles: [IntentRole] = []
        for (index, element) in array.enumerated() {
            let path = "policy.roles[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            rejectUnknownKeys(entry, allowed: ["role", "members"], path: path, into: &rejections)
            let role = requiredString(entry, key: "role", path: path, into: &rejections)
            let members = parseMembers(entry, path: path, into: &rejections)
            guard let role, let members else { continue }
            roles.append(IntentRole(role: role, members: members))
        }
        return roles
    }

    private static func parseMembers(
        _ entry: [String: Value],
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentRoleMember]? {
        guard let rawMembers = entry["members"] else {
            rejections.append(.missingKey(path: path, key: "members"))
            return nil
        }
        guard let array = rawMembers.arrayValue else {
            rejections.append(.wrongType(path: "\(path).members", expected: "array"))
            return nil
        }
        var members: [IntentRoleMember] = []
        for (index, element) in array.enumerated() {
            let memberPath = "\(path).members[\(index)]"
            guard let member = element.objectValue else {
                rejections.append(.wrongType(path: memberPath, expected: "object"))
                continue
            }
            rejectUnknownKeys(member, allowed: ["handle", "accepted"], path: memberPath, into: &rejections)
            let handle = requiredString(member, key: "handle", path: memberPath, into: &rejections)
            let accepted = requiredBool(member, key: "accepted", path: memberPath, into: &rejections)
            guard let handle, let accepted else { continue }
            members.append(IntentRoleMember(handle: handle, accepted: accepted))
        }
        return members
    }

    private static func parseOutputs(
        _ object: [String: Value],
        into rejections: inout [IntentPolicyRejection]
    ) -> [IntentOutput] {
        guard let rawOutputs = object["outputs"] else { return [] }
        guard let array = rawOutputs.arrayValue else {
            rejections.append(.wrongType(path: "policy.outputs", expected: "array"))
            return []
        }
        var outputs: [IntentOutput] = []
        for (index, element) in array.enumerated() {
            let path = "policy.outputs[\(index)]"
            guard let entry = element.objectValue else {
                rejections.append(.wrongType(path: path, expected: "object"))
                continue
            }
            rejectUnknownKeys(entry, allowed: ["target", "role", "bus", "output"], path: path, into: &rejections)
            let target = optionalString(entry, key: "target", path: path, into: &rejections)
            let role = optionalString(entry, key: "role", path: path, into: &rejections)
            let destination = parseDestination(entry, path: path, into: &rejections)
            let subject: IntentSubject?
            switch (target, role) {
            case (.some(let handle), .none):
                subject = .target(handle)
            case (.none, .some(let name)):
                subject = .role(name)
            default:
                // Both or neither: the wire carried a shape this rule cannot read, or a key whose
                // type was already rejected above.
                if entry["target"] != nil, entry["role"] != nil {
                    rejections.append(.outputNamesBothOrNeither(path: path))
                } else if entry["target"] == nil, entry["role"] == nil {
                    rejections.append(.outputNamesBothOrNeither(path: path))
                }
                subject = nil
            }
            guard let subject, let destination else { continue }
            outputs.append(IntentOutput(subject: subject, destination: destination))
        }
        return outputs
    }

    /// Exactly one of `bus` (an int >= 1) or `output` (`"no_output"`, the one non-bus main output
    /// P1 accepts: a track deliberately routed nowhere).
    private static func parseDestination(
        _ entry: [String: Value],
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> IntentMainOutput? {
        guard (entry["bus"] == nil) != (entry["output"] == nil) else {
            rejections.append(.outputDestinationBothOrNeither(path: path))
            return nil
        }
        if entry["bus"] != nil {
            guard let bus = requiredInt(entry, key: "bus", path: path, into: &rejections) else { return nil }
            guard bus >= 1 else {
                rejections.append(.busBelowOne(path: "\(path).bus", value: bus))
                return nil
            }
            return .bus(bus)
        }
        guard let output = optionalString(entry, key: "output", path: path, into: &rejections) else { return nil }
        guard output == RoutingOutputClassification.noOutput.rawValue else {
            rejections.append(.unsupportedOutput(path: "\(path).output", value: output))
            return nil
        }
        return .noOutput
    }

    /// Semantic checks after the shape is read: identifiers, uniqueness, reference kind, subject
    /// existence, and conflicting buses once roles are expanded to their accepted members.
    private static func validate(
        targets: [IntentTarget],
        roles: [IntentRole],
        outputs: [IntentOutput],
        into rejections: inout [IntentPolicyRejection]
    ) {
        for (index, target) in targets.enumerated() where !isValidHandle(target.handle) {
            rejections.append(.invalidHandle(path: "policy.targets[\(index)].handle"))
        }
        for (index, role) in roles.enumerated() {
            if !isValidHandle(role.role) {
                rejections.append(.invalidHandle(path: "policy.roles[\(index)].role"))
            }
            for (memberIndex, member) in role.members.enumerated() where !isValidHandle(member.handle) {
                rejections.append(.invalidHandle(path: "policy.roles[\(index)].members[\(memberIndex)].handle"))
            }
        }

        for handle in duplicates(in: targets.map(\.handle)) {
            rejections.append(.duplicateHandle(handle))
        }
        for ref in duplicates(in: targets.map(\.trackRef.rawValue)) {
            rejections.append(.duplicateTrackRef(ref))
        }
        // Role names and member handles within one role share the rule: one name, one meaning.
        for name in duplicates(in: roles.map(\.role)) {
            rejections.append(.duplicateHandle(name))
        }
        for role in roles {
            for handle in duplicates(in: role.members.map(\.handle)) {
                rejections.append(.duplicateHandle(handle))
            }
        }

        for target in targets where !target.trackRef.rawValue.hasPrefix(trackReferencePrefix) {
            rejections.append(.unsupportedTargetRef(handle: target.handle, ref: target.trackRef.rawValue))
        }

        let handles = Set(targets.map(\.handle))
        let roleNames = Set(roles.map(\.role))
        for (index, role) in roles.enumerated() {
            for (memberIndex, member) in role.members.enumerated() where !handles.contains(member.handle) {
                rejections.append(.unknownSubject(
                    path: "policy.roles[\(index)].members[\(memberIndex)]",
                    subject: member.handle
                ))
            }
        }
        for (index, output) in outputs.enumerated() {
            switch output.subject {
            case .target(let handle) where !handles.contains(handle):
                rejections.append(.unknownSubject(path: "policy.outputs[\(index)]", subject: handle))
            case .role(let name) where !roleNames.contains(name):
                rejections.append(.unknownSubject(path: "policy.outputs[\(index)]", subject: name))
            default:
                break
            }
        }

        // Roles expand to their accepted members before conflicts are read, so a target named
        // directly and again through a role with another bus is one contradiction, not two intents.
        var destinationsByHandle: [String: Set<IntentMainOutput>] = [:]
        var destinationsByRole: [String: Set<IntentMainOutput>] = [:]
        for output in outputs {
            switch output.subject {
            case .target(let handle):
                destinationsByHandle[handle, default: []].insert(output.destination)
            case .role(let name):
                destinationsByRole[name, default: []].insert(output.destination)
                for role in roles where role.role == name {
                    for member in role.members where member.accepted {
                        destinationsByHandle[member.handle, default: []].insert(output.destination)
                    }
                }
            }
        }
        for (handle, destinations) in destinationsByHandle where destinations.count > 1 {
            rejections.append(.conflictingOutputs(subject: handle, outputs: IntentMainOutput.ordered(destinations)))
        }
        for (name, destinations) in destinationsByRole where destinations.count > 1 {
            rejections.append(.conflictingOutputs(subject: name, outputs: IntentMainOutput.ordered(destinations)))
        }
    }

    private static func isValidHandle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.utf8.count <= maxHandleBytes
    }

    private static func duplicates(in values: [String]) -> [String] {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for value in values where !seen.insert(value).inserted {
            repeated.insert(value)
        }
        return repeated.sorted()
    }

    private static func rejectUnknownKeys(
        _ object: [String: Value],
        allowed: Set<String>,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) {
        for key in Set(object.keys).subtracting(allowed).sorted() {
            rejections.append(.unknownKey(path: path, key: key))
        }
    }

    private static func requiredString(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> String? {
        guard object[key] != nil else {
            rejections.append(.missingKey(path: path, key: key))
            return nil
        }
        return optionalString(object, key: key, path: path, into: &rejections)
    }

    private static func optionalString(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> String? {
        guard let raw = object[key] else { return nil }
        guard let value = raw.stringValue else {
            rejections.append(.wrongType(path: "\(path).\(key)", expected: "string"))
            return nil
        }
        return value
    }

    private static func requiredBool(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> Bool? {
        guard let raw = object[key] else {
            rejections.append(.missingKey(path: path, key: key))
            return nil
        }
        guard let value = raw.boolValue else {
            rejections.append(.wrongType(path: "\(path).\(key)", expected: "bool"))
            return nil
        }
        return value
    }

    private static func requiredInt(
        _ object: [String: Value],
        key: String,
        path: String,
        into rejections: inout [IntentPolicyRejection]
    ) -> Int? {
        guard let raw = object[key] else {
            rejections.append(.missingKey(path: path, key: key))
            return nil
        }
        guard let value = raw.intValue else {
            rejections.append(.wrongType(path: "\(path).\(key)", expected: "int"))
            return nil
        }
        return value
    }

    // MARK: - Assessment

    private struct ResolvedOutput {
        let destination: IntentMainOutput
        var namedDirectly: Bool
        var roles: Set<String>
    }

    /// A reason that holds for every target of one assessment, with the status it forces.
    private struct AssessmentGate {
        let status: IntentStatus
        let reason: IntentReason
    }

    /// What the graph shows for one source, before intent is compared with it: where its main
    /// output goes, or why the graph does not say.
    private enum MainOutputObservation {
        case observed(IntentEndpoint)
        case unobserved(IntentReason, edgeObserved: Bool)

        var endpoint: IntentEndpoint? {
            if case .observed(let endpoint) = self { return endpoint }
            return nil
        }

        var failure: IntentReason? {
            if case .unobserved(let reason, _) = self { return reason }
            return nil
        }

        var edgeObserved: Bool {
            switch self {
            case .observed(let endpoint): return endpoint.output == .bus
            case .unobserved(_, let edgeObserved): return edgeObserved
            }
        }
    }

    /// Assesses an approved policy against one capture and the graph published from it. Pure: no
    /// host, cache or registry, and byte-identical output for identical inputs.
    static func assessIntent(
        policy: IntentPolicy,
        capture: SessionPopulationObservation.Capture,
        graph: RoutingGraph
    ) -> IntentAssessment {
        var targetsByHandle: [String: IntentTarget] = [:]
        for target in policy.targets {
            targetsByHandle[target.handle] = target
        }
        var rolesByName: [String: IntentRole] = [:]
        for role in policy.roles {
            rolesByName[role.role] = role
        }

        // The parser guarantees one destination per handle and per role, so a handle reached twice
        // (once directly, once through a role, or through two roles) is one finding.
        var resolved: [String: ResolvedOutput] = [:]
        var unresolvedRoles: [String: IntentMainOutput] = [:]
        for output in policy.outputs {
            switch output.subject {
            case .target(let handle):
                var entry = resolved[handle]
                    ?? ResolvedOutput(destination: output.destination, namedDirectly: false, roles: [])
                entry.namedDirectly = true
                resolved[handle] = entry
            case .role(let name):
                guard let role = rolesByName[name] else { continue }
                let accepted = role.members.filter(\.accepted)
                if accepted.isEmpty {
                    unresolvedRoles[name] = output.destination
                    continue
                }
                for member in accepted {
                    var entry = resolved[member.handle]
                        ?? ResolvedOutput(destination: output.destination, namedDirectly: false, roles: [])
                    entry.roles.insert(name)
                    resolved[member.handle] = entry
                }
            }
        }

        let gate = assessmentGate(policy: policy, capture: capture, graph: graph)
        var findings: [IntentFinding] = []
        var questions: [IntentQuestion] = []
        for (handle, entry) in resolved.sorted(by: { $0.key < $1.key }) {
            guard let target = targetsByHandle[handle] else { continue }
            findings.append(assessMainOutput(
                handle: handle,
                role: entry.namedDirectly ? nil : entry.roles.sorted().first,
                trackRef: target.trackRef,
                destination: entry.destination,
                gate: gate,
                capture: capture,
                graph: graph
            ))
        }
        for (name, destination) in unresolvedRoles.sorted(by: { $0.key < $1.key }) {
            guard let role = rolesByName[name] else { continue }
            findings.append(IntentFinding(
                id: "main_output.role.\(name)",
                rule: mainOutputAssignmentRule,
                basis: .approvedPolicy,
                severity: .info,
                status: .needsInput,
                target: IntentTargetEvidence(handle: nil, role: name, trackRef: nil, trackIndex: nil),
                observed: nil,
                expected: .expected(destination),
                coverage: coverage(edgeObserved: false, destinationBusObserved: false, expected: destination, graph: graph),
                reasons: [.roleHasNoAcceptedMember]
            ))
            let candidates = role.members
                .filter { !$0.accepted }
                .compactMap { member -> IntentCandidate? in
                    guard let target = targetsByHandle[member.handle] else { return nil }
                    return IntentCandidate(handle: member.handle, trackRef: target.trackRef.rawValue)
                }
            questions.append(IntentQuestion(
                id: "role.\(name)",
                role: name,
                rule: mainOutputAssignmentRule,
                expected: .expected(destination),
                candidates: candidates
            ))
        }
        findings.sort { $0.id < $1.id }
        questions.sort { $0.id < $1.id }

        return IntentAssessment(
            schema: intentAssessmentSchema,
            readOnly: true,
            snapshotId: SessionPopulationObservation.snapshotID(for: capture),
            projectEpoch: capture.projectEpoch,
            graphProjectEpoch: graph.projectEpoch,
            findings: findings,
            questions: questions,
            changeRequired: findings.contains { $0.status == .violation }
        )
    }

    /// Whether this graph can be read against this capture at all, and whether the policy is for
    /// the captured project. In a fixed order, first hit wins.
    private static func assessmentGate(
        policy: IntentPolicy,
        capture: SessionPopulationObservation.Capture,
        graph: RoutingGraph
    ) -> AssessmentGate? {
        if capture.before != capture.after {
            return AssessmentGate(status: .unverified, reason: .cacheMovedDuringCapture)
        }
        // The graph must be the one published from this capture's cache revision, not another read.
        if graph.snapshotId != SessionPopulationObservation.snapshotID(for: capture) {
            return AssessmentGate(status: .unverified, reason: .graphNotFromCapture)
        }
        if !graph.isConsistent {
            return AssessmentGate(status: .unverified, reason: .routingGraphInconsistent)
        }
        if !capture.before.hasDocument {
            return AssessmentGate(status: .unverified, reason: .noDocument)
        }
        if capture.before.axOccluded {
            return AssessmentGate(status: .unverified, reason: .axOccluded)
        }
        if let wanted = policy.projectRef {
            guard case .issued(let captured)? = capture.projectIssuance else {
                return AssessmentGate(status: .unverified, reason: .projectReferenceUnavailable)
            }
            if captured != wanted {
                return AssessmentGate(status: .outsideScope, reason: .policyProjectMismatch)
            }
        }
        return nil
    }

    /// The one P1 rule, in a fixed order. `compliant` and `violation` need a capture and graph that
    /// pass every gate, a target the capture issued, both the `main_output` and the
    /// `strip_track_association` domains complete, and a source whose output the graph classifies
    /// unambiguously. Every weaker reading is `unverified` or `outside_scope`, because what was not
    /// observed is not evidence of a wrong route.
    private static func assessMainOutput(
        handle: String,
        role: String?,
        trackRef: TargetReference,
        destination: IntentMainOutput,
        gate: AssessmentGate?,
        capture: SessionPopulationObservation.Capture,
        graph: RoutingGraph
    ) -> IntentFinding {
        func finding(
            _ status: IntentStatus,
            _ observation: MainOutputObservation?,
            trackIndex: Int?,
            reasons: [IntentReason]
        ) -> IntentFinding {
            IntentFinding(
                id: "main_output.target.\(handle)",
                rule: mainOutputAssignmentRule,
                basis: .approvedPolicy,
                severity: status == .violation ? .warn : .info,
                status: status,
                target: IntentTargetEvidence(
                    handle: handle,
                    role: role,
                    trackRef: trackRef.rawValue,
                    trackIndex: trackIndex
                ),
                observed: observation?.endpoint,
                expected: .expected(destination),
                coverage: coverage(
                    edgeObserved: observation?.edgeObserved ?? false,
                    destinationBusObserved: observation?.endpoint?.busNumber != nil,
                    expected: destination,
                    graph: graph
                ),
                reasons: reasons
            )
        }

        if let gate {
            return finding(gate.status, nil, trackIndex: nil, reasons: [gate.reason])
        }
        guard capture.referencesEnabled else {
            return finding(.unverified, nil, trackIndex: nil, reasons: [.referencesUnavailable])
        }
        guard let issued = capture.issued else {
            return finding(.unverified, nil, trackIndex: nil, reasons: [.targetSnapshotStale])
        }
        guard let trackIndex = issued.byTrackIndex.filter({ $0.value == trackRef }).keys.min() else {
            return finding(.outsideScope, nil, trackIndex: nil, reasons: [.targetNotInSnapshot])
        }
        // The graph carries the epoch of the registry snapshot the capture issued under.
        guard graph.projectEpoch == capture.targetSnapshot?.projectEpoch else {
            return finding(.unverified, nil, trackIndex: trackIndex, reasons: [.graphEpochMismatch])
        }

        let observation = observeMainOutput(of: trackRef, in: graph)
        var coverageReasons: [IntentReason] = []
        if graph.coverage.mainOutput.state != .complete {
            coverageReasons.append(.mainOutputCoverageIncomplete)
        }
        if graph.coverage.stripTrackAssociation.state != .complete {
            coverageReasons.append(.stripTrackAssociationIncomplete)
        }
        if !coverageReasons.isEmpty {
            return finding(
                .unverified,
                observation,
                trackIndex: trackIndex,
                reasons: coverageReasons + [observation.failure].compactMap { $0 }
            )
        }
        let observed: IntentEndpoint
        switch observation {
        case .unobserved(let reason, _):
            return finding(.unverified, observation, trackIndex: trackIndex, reasons: [reason])
        case .observed(let endpoint):
            observed = endpoint
        }

        switch destination {
        case .bus(let bus):
            if observed.output == .bus, observed.busNumber == bus {
                return finding(.compliant, observation, trackIndex: trackIndex, reasons: [])
            }
            var reasons: [IntentReason] = []
            if !graph.nodes.contains(where: { $0.busNumber == bus }) {
                reasons.append(.expectedBusNotObserved)
            }
            return finding(.violation, observation, trackIndex: trackIndex, reasons: reasons)
        case .noOutput:
            if observed.output == .noOutput {
                return finding(.compliant, observation, trackIndex: trackIndex, reasons: [])
            }
            return finding(.violation, observation, trackIndex: trackIndex, reasons: [])
        }
    }

    /// The source is the one node carrying the target's reference, never a node found by name.
    /// Only its `outputClassification` and its `.mainOutput` edges are read.
    private static func observeMainOutput(of trackRef: TargetReference, in graph: RoutingGraph) -> MainOutputObservation {
        func classified(_ output: RoutingOutputClassification) -> MainOutputObservation {
            .observed(IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: output))
        }

        let sources = graph.nodes.filter { $0.targetRef == trackRef }
        guard let source = sources.first else { return .unobserved(.trackNotInGraph, edgeObserved: false) }
        guard sources.count == 1 else { return .unobserved(.sourceNodeAmbiguous, edgeObserved: false) }

        switch source.outputClassification {
        case nil, .unclassified?:
            return .unobserved(.outputUnclassified, edgeObserved: false)
        case .noOutput?:
            return classified(.noOutput)
        case .physicalOutput?:
            return classified(.physicalOutput)
        case .bus?:
            let edges = graph.edges.filter { $0.kind == .mainOutput && $0.source == source.id }
            guard edges.count == 1,
                  let edge = edges.first,
                  let busNode = graph.nodes.first(where: { $0.id == edge.destination }),
                  let busNumber = busNode.busNumber
            else {
                return .unobserved(.outputEdgeAmbiguous, edgeObserved: !edges.isEmpty)
            }
            return .observed(IntentEndpoint(
                nodeId: busNode.id,
                displayName: busNode.displayName,
                busNumber: busNumber,
                output: .bus
            ))
        }
    }

    private static func coverage(
        edgeObserved: Bool,
        destinationBusObserved: Bool,
        expected: IntentMainOutput,
        graph: RoutingGraph
    ) -> IntentCoverage {
        var expectedBusObserved: Bool?
        if case .bus(let bus) = expected {
            expectedBusObserved = graph.nodes.contains { $0.busNumber == bus }
        }
        return IntentCoverage(
            outputEdgeObserved: edgeObserved,
            destinationBusObserved: destinationBusObserved,
            expectedBusObserved: expectedBusObserved,
            graphComplete: graph.complete,
            mainOutput: graph.coverage.mainOutput,
            stripTrackAssociation: graph.coverage.stripTrackAssociation,
            notVerified: IntentAspect.withoutObservationSource
        )
    }
}
