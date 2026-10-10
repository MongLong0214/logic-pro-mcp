import CryptoKit
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Pure planning over an injected capture/graph, not native routing or execution evidence.
@Suite("Approved existing-bus output proposals (#966 P2)")
struct Issue966ApprovedRoutingDiffTests {
    private typealias Audit = ProjectSessionAudit
    private typealias Observation = SessionPopulationObservation
    private let project = TargetReference(rawValue: "prj_proposal")
    private let source = TargetReference(rawValue: "trk_proposal")
    private let other = TargetReference(rawValue: "trk_unrelated")
    private let complete = RoutingDomainCoverage(state: .complete, reasons: [])

    private func capture() -> Observation.Capture {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let boundary = StateCache.CaptureBoundary(versions: [
            .tracks: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 7),
            .mixer: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 2),
            .project: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 1),
        ], occlusionRevision: 0, hasDocument: true, axOccluded: false)
        return Observation.Capture(
            before: boundary, after: boundary, projectEpoch: 3,
            project: ProjectInfo(name: "Song", filePath: "/Users/x/Song.logicx"),
            tracks: [TrackState(id: 0, name: "Same", type: .audio), TrackState(id: 1, name: "Same", type: .audio)],
            tracksFetchedAt: now.addingTimeInterval(-1), channelStrips: [], mixerFetchedAt: now.addingTimeInterval(-1),
            fileTrackCount: 2, projectFileNotBound: false, requestedProjectMatches: nil,
            referencesEnabled: true, targetSnapshot: TargetRegistrySnapshot(projectEpoch: 3, topologyGeneration: 0),
            issued: IssuedTrackReferences(byRow: [source, other], byTrackIndex: [0: source, 1: other], ambiguousTrackIndices: []),
            projectIssuance: .issued(project), beganAt: now.addingTimeInterval(-0.01), endedAt: now,
            captureID: "proposal_fixture"
        )
    }

    private func nodes(output: RoutingOutputClassification = .bus) -> [RoutingNode] {
        [
            RoutingNode(id: "source_opaque", kind: .track, displayName: "Same", busNumber: nil,
                        targetRef: source, outputClassification: output),
            RoutingNode(id: "other_opaque", kind: .track, displayName: "Same", busNumber: nil,
                        targetRef: other, outputClassification: .bus),
            RoutingNode(id: "destination_opaque", kind: .bus, displayName: "Same", busNumber: 3, targetRef: nil),
            RoutingNode(id: "previous_opaque", kind: .bus, displayName: "Same", busNumber: 4, targetRef: nil),
            RoutingNode(id: "receiver_one", kind: .aux, displayName: "Same", busNumber: nil, targetRef: nil),
            RoutingNode(id: "receiver_two", kind: .aux, displayName: "Same", busNumber: nil, targetRef: nil),
        ]
    }

    private func edge(_ kind: RoutingEdgeKind, _ source: String, _ destination: String) -> RoutingEdge {
        RoutingEdge(kind: kind, source: source, destination: destination, send: nil, provenance: .axMixerStrip)
    }

    private func edges(correct: Bool = false) -> [RoutingEdge] {
        [
            edge(.mainOutput, "source_opaque", correct ? "destination_opaque" : "previous_opaque"),
            edge(.mainOutput, "other_opaque", "previous_opaque"),
            edge(.inputAssignment, "destination_opaque", "receiver_one"),
            edge(.inputAssignment, "destination_opaque", "receiver_two"),
            RoutingEdge(kind: .send, source: "source_opaque", destination: "previous_opaque", send: SendEdge(
                sourceTrackRef: source, physicalSlot: 5, destinationBusNumber: 4, destinationRef: nil,
                displayedName: "Same", level: -17.25, mode: "pre-fader", enabled: false
            ), provenance: .axMixerStrip),
        ]
    }

    private func graph(nodes: [RoutingNode]? = nil, edges: [RoutingEdge]? = nil,
                       coverage: RoutingCoverage? = nil, epoch: UInt64 = 3,
                       snapshot: String = "proposal_fixture", project: TargetReference? = nil) -> RoutingGraph {
        let coverage = coverage ?? RoutingCoverage.uniform(complete)
        return RoutingGraph(projectReference: project ?? self.project, projectEpoch: epoch,
                            complete: coverage.isComplete, partialReason: coverage.isComplete ? nil : "fixture partial domain",
                            nodes: nodes ?? self.nodes(), edges: edges ?? self.edges(), provenance: [.axMixerStrip],
                            snapshotId: snapshot, coverage: coverage)
    }

    private func plan(_ graph: RoutingGraph, bus: Int = 3, noOutput: Bool = false, sends: [Value]? = nil,
                      options: Audit.PlanningOptions = Audit.PlanningOptions(), snapshotCurrent: Bool = true,
                      policyExtras: [String: Value] = [:], names: [Audit.ApprovedName] = [],
                      request: Observation.Request = Observation.Request(domains: [.tracks, .strips, .routing])) throws -> [String: Value] {
        var raw: [String: Value] = [
            "schema": .string(Audit.intentPolicySchema), "project_ref": .string(project.rawValue),
            "targets": .array([.object(["handle": .string("approved"), "track_ref": .string(source.rawValue)])]),
            "outputs": .array([.object(noOutput
                ? ["target": .string("approved"), "output": .string("no_output")]
                : ["target": .string("approved"), "bus": .int(bus)])]),
        ]
        if let sends {
            raw["outputs"] = .array([])
            raw["sends"] = .array(sends)
        }
        raw.merge(policyExtras) { _, new in new }
        guard case .accepted(let policy) = Audit.parseIntentPolicy(raw) else {
            Issue.record("valid explicit policy rejected: \(String(describing: Audit.parseIntentPolicy(raw)))")
            throw CocoaError(.coderInvalidValue)
        }
        let result = try Audit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw), names: names,
                                                       capture: capture(), request: request, snapshotCurrent: snapshotCurrent, options: options,
                                                       graphOverride: graph)
        let wire = try JSONDecoder().decode(Value.self, from: Data(result.json.utf8))
        return try #require(wire.objectValue)
    }

    private func proposal(_ body: [String: Value]) throws -> [String: Value] {
        let steps = try #require(body["steps"]?.arrayValue)
        let step = try #require(steps.first?.objectValue)
        return try #require(step["proposed_routing_diff"]?.objectValue)
    }

    private func decodeEdge(_ value: Value) throws -> RoutingEdge {
        try JSONDecoder().decode(RoutingEdge.self, from: Data(encodeJSONStrict(value, compact: true).utf8))
    }

    @Test(arguments: ["output", "send", "intermediate", "acyclic"])
    func aNewStructuralCycleBlocksItsCanonicalPrefix(_ change: String) throws {
        // Abstract complete graph evidence, not a claim that these endpoints were acquired live.
        // The existing send returns from bus 4; replacing it with bus 3 closes the return path.
        var es = edges().filter { !($0.kind == .send && $0.source == "source_opaque") }
        es.append(RoutingEdge(kind: .send, source: "source_opaque", destination: "previous_opaque",
            send: SendEdge(sourceTrackRef: source, physicalSlot: 5,
                destinationBusNumber: 4, destinationRef: nil,
                displayedName: "Same", level: 0, mode: "pre-fader", enabled: false), provenance: .axMixerStrip))
        if change != "acyclic" && change != "intermediate" {
            es.append(edge(.inputAssignment, "receiver_one", "source_opaque"))
        }
        var ns = nodes()
        var extras: [String: Value] = [:]
        if change == "intermediate" {
            ns.append(RoutingNode(id: "safe_bus", kind: .bus, displayName: "Same", busNumber: 5, targetRef: nil))
            es.removeAll { $0.kind == .mainOutput || $0.kind == .send }
            es += [edge(.mainOutput, "source_opaque", "safe_bus"),
                edge(.mainOutput, "other_opaque", "safe_bus"),
                edge(.inputAssignment, "receiver_one", "other_opaque"),
                edge(.inputAssignment, "previous_opaque", "source_opaque")]
            es.append(RoutingEdge(kind: .send, source: "other_opaque", destination: "previous_opaque",
                send: SendEdge(sourceTrackRef: other, physicalSlot: 5, destinationBusNumber: 4,
                    destinationRef: nil, displayedName: "Same", level: 0, mode: "pre-fader", enabled: false), provenance: .axMixerStrip))
            extras["targets"] = .array([
                .object(["handle": .string("approved"), "track_ref": .string(source.rawValue)]),
                .object(["handle": .string("return"), "track_ref": .string(other.rawValue)])])
            // Removing the returning send cannot make an earlier cyclic prefix safe.
            extras["sends"] = .array([.object(["target": .string("return"),
                "physical_slot": .int(5), "remove": .bool(true)])])
        }
        let candidate = graph(nodes: ns, edges: es)
        #expect(candidate.isConsistent)
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let sendTask: [Value]? = change == "send" ? [.object(["target": .string("approved"),
            "physical_slot": .int(5), "bus": .int(3)])] : nil
        let body = try plan(candidate, sends: sendTask, options: options, policyExtras: extras)
        let steps = try #require(body["steps"]?.arrayValue).map { try #require($0.objectValue) }
        let first = try #require(steps.first)
        let blocked = try #require(first["blocked_reasons"]?.arrayValue)
        let reasons = try #require(body["reasons"]?.arrayValue)
        if change != "acyclic" {
            #expect(blocked.contains(.string("routing_prefix_cycle_detected")))
            #expect(reasons.contains(.string("routing_prefix_cycle_detected")))
        } else {
            #expect(!blocked.contains(.string("routing_prefix_cycle_detected")))
            #expect(!reasons.contains(.string("routing_prefix_cycle_detected")))
        }
        #expect(body["steps"] == body["preview"])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
        if change == "intermediate" { #expect(steps.count == 2) }
    }

    private func sendPolicy(_ sends: Value) -> [String: Value] {
        ["schema": .string(Audit.intentPolicySchema), "project_ref": .string(project.rawValue),
         "targets": .array([.object(["handle": .string("approved"), "track_ref": .string(source.rawValue)])]),
         "sends": sends]
    }

    private var finalPresentation: Value {
        .object(["mixer_visible": .bool(true), "sort": .object([
            "criterion": .string("track_name"),
            "expected_order": .array([.string(other.rawValue), .string(source.rawValue)]),
            "inverse_criterion": .string("creation_date")])])
    }

    @Test(arguments: ["one", "empty"])
    func explicitProtectedSinkPathsAreAcceptedAsPolicyData(_ kind: String) {
        var raw = sendPolicy(.array([]))
        raw["protected_paths"] = .array(kind == "empty" ? [] : [.object([
            "target": .string("approved"), "sink_node_id": .string("sink_opaque")])])
        let result = Audit.parseIntentPolicy(raw)
        guard case .accepted = result else {
            Issue.record("Explicit protected sink policy must be accepted, got \(result)")
            return
        }
    }

    @Test(arguments: ["not_array", "not_object", "unknown_key", "missing_target", "foreign_target",
        "missing_sink", "sink_type", "empty_sink", "duplicate", "too_many"])
    func malformedProtectedSinkPathsCannotBeSilentlyIgnored(_ fault: String) {
        var raw = sendPolicy(.array([]))
        var entry: [String: Value] = ["target": .string("approved"), "sink_node_id": .string("sink_opaque")]
        switch fault {
        case "unknown_key": entry["safe"] = .bool(true)
        case "missing_target": entry.removeValue(forKey: "target")
        case "foreign_target": entry["target"] = .string("unknown")
        case "missing_sink": entry.removeValue(forKey: "sink_node_id")
        case "sink_type": entry["sink_node_id"] = .int(0)
        case "empty_sink": entry["sink_node_id"] = .string(" ")
        default: break
        }
        raw["protected_paths"] = .array([.object(entry)])
        if fault == "not_array" { raw["protected_paths"] = .object(entry) }
        if fault == "not_object" { raw["protected_paths"] = .array([.string("sink_opaque")]) }
        if fault == "duplicate" { raw["protected_paths"] = .array([.object(entry), .object(entry)]) }
        if fault == "too_many" {
            raw["protected_paths"] = .array((0..<65).map { .object([
                "target": .string("approved"), "sink_node_id": .string("sink_\($0)")]) })
        }
        guard case .rejected(let reasons) = Audit.parseIntentPolicy(raw) else {
            Issue.record("Malformed protected path accepted: \(fault)"); return
        }
        #expect(!reasons.isEmpty)
    }

    private var protectedSink: [String: Value] {
        ["protected_paths": .array([.object([
            "target": .string("approved"), "sink_node_id": .string("sink_opaque")])])]
    }

    /// Two independently described receivers, not labels joined to infer a route. The bypassed,
    /// zero-level send remains a structural edge, not a claim of audible signal or native coverage.
    private func protectedGraph(backupReachesSink: Bool = true) -> RoutingGraph {
        let ns = nodes() + [RoutingNode(id: "sink_opaque", kind: .output, displayName: "Same", busNumber: nil, targetRef: nil)]
        var es = [edge(.mainOutput, "source_opaque", "previous_opaque"),
                  edge(.mainOutput, "other_opaque", "previous_opaque"),
                  edge(.inputAssignment, "previous_opaque", "receiver_one"),
                  edge(.inputAssignment, "destination_opaque", "receiver_two"),
                  edge(.mainOutput, "receiver_one", "sink_opaque")]
        if backupReachesSink { es.append(edge(.mainOutput, "receiver_two", "sink_opaque")) }
        es.append(RoutingEdge(kind: .send, source: "source_opaque", destination: "destination_opaque",
            send: SendEdge(sourceTrackRef: source, physicalSlot: 5, destinationBusNumber: 3, destinationRef: nil,
                displayedName: "Same", level: 0, mode: "pre-fader", enabled: false), provenance: .axMixerStrip))
        return graph(nodes: ns, edges: es)
    }

    @Test(arguments: ["output", "send", "both", "intermediate"])
    func protectedSinkChecksEveryComposedRoutingPrefix(_ kind: String) throws {
        let candidate = protectedGraph(backupReachesSink: kind != "intermediate")
        #expect(candidate.isConsistent)
        var extras = protectedSink
        if kind == "send" { extras["outputs"] = .array([]) }
        if kind != "output" {
            extras["sends"] = .array([.object(kind == "intermediate"
                ? ["target": .string("approved"), "physical_slot": .int(5), "bus": .int(4)]
                : ["target": .string("approved"), "physical_slot": .int(5), "remove": .bool(true)])])
        }
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let body = try plan(candidate, noOutput: kind != "intermediate", options: options, policyExtras: extras)
        let invariants = try #require(body["protected_invariants"]?.arrayValue)
        let invariant = try #require(invariants.first?.objectValue)
        #expect(invariants.count == 1)
        #expect(invariant["target_ref"]?.stringValue == source.rawValue)
        #expect(invariant["sink_node_id"]?.stringValue == "sink_opaque")
        #expect(invariant["baseline"]?.stringValue == "connected")
        let prefixes = try #require(invariant["prefixes"]?.arrayValue).map { try #require($0.objectValue) }
        let expectedStates = kind == "both" ? ["connected", "disconnected"]
            : kind == "intermediate" ? ["disconnected", "connected"] : ["connected"]
        #expect(prefixes.compactMap { $0["state"]?.stringValue } == expectedStates)
        let steps = try #require(body["steps"]?.arrayValue).map { try #require($0.objectValue) }
        #expect(prefixes.compactMap { $0["step_id"]?.stringValue } == steps.compactMap { $0["id"]?.stringValue })
        #expect(invariant["final"]?.stringValue == expectedStates.last)
        let violates = kind == "both" || kind == "intermediate"
        #expect(invariant["status"]?.stringValue == (violates ? "violated" : "preserved"))
        let reasons = try #require(body["reasons"]?.arrayValue)
        if violates { #expect(reasons.contains(.string("protected_path_lost"))) }
        else { #expect(!reasons.contains(.string("protected_path_lost"))) }
        #expect(reasons.contains(.string("protected_path_execution_verifier_unavailable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?); #expect(!executable)
        #expect(body["steps"] == body["preview"])
        let repeated = try plan(candidate, noOutput: kind != "intermediate", options: options, policyExtras: extras)
        #expect(body["digest"] == repeated["digest"])
        #expect(body["protected_invariants"] == repeated["protected_invariants"])
    }

    @Test func deliberateDisconnectionWithoutProtectionDoesNotInventMusicalIntent() throws {
        let body = try plan(protectedGraph(), noOutput: true, policyExtras: ["sends": .array([.object([
            "target": .string("approved"), "physical_slot": .int(5), "remove": .bool(true)])])])
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.objectValue?["proposed_routing_diff"]?.objectValue?["status"]?.stringValue == "proposed" })
        #expect(!body.keys.contains("protected_invariants"))
        let reasons = try #require(body["reasons"]?.arrayValue)
        #expect(!reasons.contains(.string("protected_path_lost")))
        #expect(body["preview"] == body["steps"])
    }

    @Test(arguments: ["snapshot", "epoch", "project", "stale", "unrequested", "population", "inputs", "sends",
        "physical_output", "missing_sink", "duplicate_sink", "missing_source", "duplicate_source_ref", "ambiguous_output",
        "sink_is_source", "source_not_track", "baseline_disconnected"])
    func protectedSinkRequiresCurrentBoundUniqueEndpointEvidence(_ fault: String) throws {
        let original = protectedGraph()
        var ns = original.nodes, es = original.edges
        var extras = protectedSink
        extras["outputs"] = .array([])
        switch fault {
        case "missing_sink": ns.removeAll { $0.id == "sink_opaque" }
        case "duplicate_sink": ns.append(try #require(ns.last))
        case "missing_source": ns.removeAll { $0.targetRef == source }
        case "duplicate_source_ref": ns.append(RoutingNode(id: "another_source", kind: .track,
            displayName: "Same", busNumber: nil, targetRef: source))
        case "ambiguous_output": es.append(edge(.mainOutput, "source_opaque", "destination_opaque"))
        case "sink_is_source": extras["protected_paths"] = .array([.object([
            "target": .string("approved"), "sink_node_id": .string("source_opaque")])])
        case "source_not_track": ns[0] = RoutingNode(id: "source_opaque", kind: .aux,
            displayName: "Same", busNumber: nil, targetRef: source)
        case "baseline_disconnected": es.removeAll { $0.destination == "sink_opaque" }
        default: break
        }
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["not measured"])
        let coverage = RoutingCoverage(population: fault == "population" ? partial : complete,
            stripTrackAssociation: complete, mainOutput: complete,
            physicalOutput: fault == "physical_output" ? partial : complete,
            busToAuxInput: fault == "inputs" ? partial : complete, sends: fault == "sends" ? partial : complete)
        let candidate = graph(nodes: ns, edges: es, coverage: coverage, epoch: fault == "epoch" ? 4 : 3,
            snapshot: fault == "snapshot" ? "another_capture" : original.snapshotId,
            project: fault == "project" ? TargetReference(rawValue: "prj_foreign") : project)
        let body = try plan(candidate, snapshotCurrent: fault != "stale", policyExtras: extras,
            request: Observation.Request(domains: fault == "unrequested" ? [.tracks] : [.tracks, .strips, .routing]))
        let invariant = try #require(body["protected_invariants"]?.arrayValue?.first?.objectValue)
        #expect(invariant["status"]?.stringValue == "unverified")
        #expect(invariant["baseline"]?.stringValue == (fault == "baseline_disconnected" ? "disconnected" : "unverified"))
        let reasons = try #require(body["reasons"]?.arrayValue)
        #expect(reasons.contains(.string(fault == "baseline_disconnected" ? "protected_path_not_observed"
            : "protected_path_evidence_unavailable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?); #expect(!executable)
    }

    @Test func unmodeledAuxCreationCannotCertifyALaterProtectedPrefix() throws {
        var extras = protectedSink
        extras["receivers"] = .array([.object(["bus": .int(9), "aux": .string("new")])])
        var options = Audit.PlanningOptions(); options.allowCreateAux = true
        let body = try plan(protectedGraph(), options: options, policyExtras: extras)
        let invariant = try #require(body["protected_invariants"]?.arrayValue?.first?.objectValue)
        #expect(invariant["baseline"]?.stringValue == "connected")
        let prefixes = try #require(invariant["prefixes"]?.arrayValue)
        #expect(prefixes.count == 2)
        #expect(prefixes.first?.objectValue?["step_id"]?.stringValue == "create_aux_bus_9")
        #expect(prefixes.allSatisfy { $0.objectValue?["state"]?.stringValue == "unverified" })
        #expect(invariant["final"]?.stringValue == "unverified")
        #expect(invariant["status"]?.stringValue == "unverified")
        let reasons = try #require(body["reasons"]?.arrayValue)
        #expect(reasons.contains(.string("protected_path_evidence_unavailable")))
        #expect(body["steps"] == body["preview"])
    }

    @Test func publicUnobservedProtectedSinkCannotExecuteAnOtherwiseSupportedViewSubset() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Issue971ApprovedMixerSagaTests.Fixture(showing: false)
                await f.router.register(f.view.channel())
                _ = f.installNameHeaders(["Bass"])
                let p = try await f.namesPlan(["Bass"], policyExtras: [
                    "protected_paths": .array([.object(["target": .string("t0"), "sink_node_id": .string("unobserved_sink")])]),
                    "presentation": .object(["mixer_visible": .bool(true)])])
                let executable = try #require(p["executable"] as? Bool); #expect(!executable)
                let key = "protected-sink-not-a-view-only-plan"
                let result = try await f.call("apply_session_repair", params: f.applyParameters(p, key: key))
                #expect(result["state"] as? String == "C")
                let attempted = try #require(result["write_attempted"] as? Bool); #expect(!attempted)
                #expect(f.view.events.isEmpty)
                #expect(await f.journal.record(for: key) == nil)
                let invariant = try #require((p["protected_invariants"] as? [[String: Any]])?.first)
                #expect(invariant["status"] as? String == "unverified")
                #expect(invariant["baseline"] as? String == "unverified")
                #expect(invariant["final"] as? String == "unverified")
                let reasons = try #require(p["reasons"] as? [String])
                #expect(reasons.contains("protected_path_evidence_unavailable"))
                let retained = try await f.call("plan_session_repair", params: [
                    "plan_id": .string(try #require(p["plan_id"] as? String)),
                    "digest": .string(try #require(p["digest"] as? String))])
                #expect(NSDictionary(dictionary: retained) == NSDictionary(dictionary: p))
            }
        }
    }

    /// Declared dependencies must agree with the canonical destination/repair/presentation order.
    /// The injected graph provides facts for planning, not runtime adapter or native qualification.
    @Test(arguments: ["output", "send", "both", "aux_only"])
    func finalPresentationDependsOnThePrecedingApprovedRepairs(_ kind: String) throws {
        var extras: [String: Value] = ["presentation": finalPresentation]
        if kind == "send" || kind == "aux_only" { extras["outputs"] = .array([]) }
        if kind == "send" || kind == "both" {
            extras["sends"] = .array([.object([
                "target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)])])
        }
        if kind == "aux_only" {
            extras["receivers"] = .array([.object(["bus": .int(3), "aux": .string("new")])])
        }
        var options = Audit.PlanningOptions(); options.allowCreateAux = true; options.allowReplaceSend = true
        let candidate = kind == "aux_only" ? graph(edges: []) : graph()
        let body = try plan(candidate, options: options, policyExtras: extras,
            names: [.init(target: "approved", name: "Approved, literal name 🎛️")])
        let steps = try #require(body["steps"]?.arrayValue).map { try #require($0.objectValue) }
        let topology = steps.filter { ["create_aux", "main_output", "send_assignment"].contains($0["kind"]?.stringValue ?? "") }
        let topologyIDs = try topology.map { try #require($0["id"]?.stringValue) }.sorted()
        #expect(topology.count == (kind == "both" ? 2 : 1))
        var preceding: [String] = []
        for step in steps {
            let id = try #require(step["id"]?.stringValue)
            let stepKind = try #require(step["kind"]?.stringValue)
            if ["name", "track_sort", "mixer_visibility"].contains(stepKind) {
                let dependencies = try #require(step["dependencies"]?.arrayValue).compactMap(\.stringValue)
                #expect(dependencies == (stepKind == "name" ? topologyIDs : preceding.sorted()))
                #expect(Set(dependencies).count == dependencies.count)
                #expect(!dependencies.contains(id))
            }
            preceding.append(id)
        }
        #expect(steps.suffix(3).compactMap { $0["kind"]?.stringValue } == ["name", "track_sort", "mixer_visibility"])
        #expect(body["preview"] == body["steps"])
        let executable = try #require(body["executable"]?.boolValue as Bool?); #expect(!executable)
        let reasons = try #require(body["reasons"]?.arrayValue)
        #expect(reasons.contains(.string(kind == "aux_only" ? "aux_creation_adapter_unavailable"
            : kind == "send" ? "exact_target_send_adapter_unavailable" : "exact_target_routing_adapter_unavailable")))
        let repeated = try plan(candidate, options: options, policyExtras: extras,
            names: [.init(target: "approved", name: "Approved, literal name 🎛️")])
        #expect(repeated["digest"] == body["digest"])
        #expect(repeated["steps"] == body["steps"])
    }

    @Test(arguments: ["output", "send", "receiver"])
    func unchangedTopologyCannotLeaveDanglingPresentationDependencies(_ kind: String) throws {
        var extras: [String: Value] = ["presentation": .object(["mixer_visible": .bool(true)])]
        if kind != "output" { extras["outputs"] = .array([]) }
        if kind == "send" {
            extras["sends"] = .array([.object([
                "target": .string("approved"), "physical_slot": .int(5), "bus": .int(4)])])
        }
        if kind == "receiver" {
            extras["receivers"] = .array([.object(["bus": .int(3), "aux": .string("keep")])])
        }
        let body = try plan(graph(edges: edges(correct: true)), policyExtras: extras)
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1)
        let view = try #require(steps.first?.objectValue)
        #expect(view["kind"]?.stringValue == "mixer_visibility")
        #expect(view["dependencies"]?.arrayValue == [])
        #expect(body["new_object_inventory"]?.arrayValue == [])
        if kind != "receiver" { #expect(body["unchanged_tasks"]?.arrayValue?.count == 1) }
        #expect(body["preview"] == body["steps"])
    }

    @Test(arguments: ["sort", "view"])
    func presentationOnlyDoesNotInventRepairDependencies(_ kind: String) throws {
        let all = try #require(finalPresentation.objectValue)
        let presentation: Value = .object(kind == "sort" ? ["sort": try #require(all["sort"])]
            : ["mixer_visible": .bool(true)])
        let body = try plan(graph(), policyExtras: ["outputs": .array([]), "presentation": presentation])
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1)
        let step = try #require(steps.first?.objectValue)
        #expect(step["kind"]?.stringValue == (kind == "sort" ? "track_sort" : "mixer_visibility"))
        #expect(step["dependencies"]?.arrayValue == [])
        #expect(body["preview"] == body["steps"])
        #expect(body["new_object_inventory"]?.arrayValue == [])
    }

    @Test func registeredPresentationDependenciesAreRetainedWithoutExecutingABlockedSubset() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Issue971ApprovedMixerSagaTests.Fixture(showing: false)
                await f.router.register(f.view.channel())
                _ = f.installNameHeaders(["Piano", "Bass"])
                let inspection = try await f.call("inspect_session", params: [
                    "domains": .array([.string("tracks"), .string("strips"), .string("routing")])])
                let snapshot = try #require(inspection["snapshot_id"] as? String)
                let projectRef = try #require((inspection["project"] as? [String: Any])?["project_ref"] as? String)
                let rows = try #require((inspection["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
                let refs = try rows.map { try #require($0["track_ref"] as? String) }
                #expect(refs.count == 2)
                let policy: Value = .object([
                    "schema": .string(Audit.intentPolicySchema), "project_ref": .string(projectRef),
                    "targets": .array(refs.enumerated().map { .object([
                        "handle": .string("t\($0.offset)"), "track_ref": .string($0.element)]) }),
                    "outputs": .array([.object(["target": .string("t0"), "bus": .int(3)])]),
                    "sends": .array([.object(["target": .string("t1"), "physical_slot": .int(5), "bus": .int(3)])]),
                    "presentation": .object(["mixer_visible": .bool(true), "sort": .object([
                        "criterion": .string("track_name"), "expected_order": .array(refs.reversed().map(Value.string)),
                        "inverse_criterion": .string("creation_date")])])])
                let plan = try await f.call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                    "policy": policy, "names": .array([.object(["target": .string("t0"), "name": .string("Keys")])])])
                let steps = try #require(plan["steps"] as? [[String: Any]])
                #expect(steps.compactMap { $0["kind"] as? String } == ["main_output", "send_assignment", "name", "track_sort", "mixer_visibility"])
                for index in 2..<steps.count {
                    let dependencies = try #require(steps[index]["dependencies"] as? [String])
                    #expect(dependencies == steps.prefix(index).compactMap { $0["id"] as? String }.sorted())
                }
                let preview = try #require(plan["preview"] as? [[String: Any]])
                #expect(NSDictionary(dictionary: ["steps": steps]) == NSDictionary(dictionary: ["steps": preview]))
                let retained = try await f.call("plan_session_repair", params: [
                    "plan_id": .string(try #require(plan["plan_id"] as? String)),
                    "digest": .string(try #require(plan["digest"] as? String))])
                #expect(NSDictionary(dictionary: retained) == NSDictionary(dictionary: plan))
                let executable = try #require(plan["executable"] as? Bool); #expect(!executable)
                let key = "blocked-final-presentation-dependencies"
                let result = try await f.call("apply_session_repair", params: f.applyParameters(plan, key: key))
                #expect(result["state"] as? String == "C")
                let attempted = try #require(result["write_attempted"] as? Bool); #expect(!attempted)
                #expect(await f.journal.record(for: key) == nil)
                #expect(f.view.events.isEmpty)
            }
        }
    }

    @Test(arguments: ["not_array", "not_object", "unknown", "missing_target", "foreign_target",
        "target_type", "missing_slot", "slot_type", "slot_low", "slot_high", "bus_type", "bus_low",
        "both", "neither", "remove_false", "remove_type", "duplicate", "conflict"])
    func exactSendParserRejectsMalformedOrConflictingTasks(_ fault: String) {
        var entry: [String: Value] = ["target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)]
        switch fault {
        case "unknown": entry["label"] = .string("Same")
        case "missing_target": entry.removeValue(forKey: "target")
        case "foreign_target": entry["target"] = .string("foreign")
        case "target_type": entry["target"] = .int(0)
        case "missing_slot": entry.removeValue(forKey: "physical_slot")
        case "slot_type": entry["physical_slot"] = .string("5")
        case "slot_low": entry["physical_slot"] = .int(-1)
        case "slot_high": entry["physical_slot"] = .int(12)
        case "bus_type": entry["bus"] = .string("3")
        case "bus_low": entry["bus"] = .int(0)
        case "both": entry["remove"] = .bool(true)
        case "neither": entry.removeValue(forKey: "bus")
        case "remove_false", "remove_type":
            entry.removeValue(forKey: "bus"); entry["remove"] = fault == "remove_false" ? .bool(false) : .string("true")
        default: break
        }
        var entries: [Value] = [.object(entry)]
        if fault == "duplicate" { entries.append(.object(entry)) }
        if fault == "conflict" { entry["bus"] = .int(4); entries.append(.object(entry)) }
        let value: Value = fault == "not_array" ? .string("send")
            : fault == "not_object" ? .array([.int(5)]) : .array(entries)
        guard case .rejected(let reasons) = Audit.parseIntentPolicy(sendPolicy(value)) else {
            Issue.record("malformed exact send policy was accepted: \(fault)"); return
        }
        #expect(!reasons.isEmpty)
    }

    @Test(arguments: [-17.25, 0.0])
    func connectedBypassedOrZeroLevelSendIsStillCompliantButNotExecutable(_ level: Double) throws {
        let old = try #require(edges().last), scalar = try #require(old.send)
        let actual = RoutingEdge(kind: .send, source: old.source, destination: old.destination,
            send: SendEdge(sourceTrackRef: scalar.sourceTrackRef, physicalSlot: scalar.physicalSlot,
                destinationBusNumber: 4, destinationRef: nil, displayedName: scalar.displayedName,
                level: level, mode: scalar.mode, enabled: false), provenance: old.provenance)
        let raw = sendPolicy(.array([.object(["target": .string("approved"), "physical_slot": .int(5), "bus": .int(4)])]))
        guard case .accepted(let policy) = Audit.parseIntentPolicy(raw) else { Issue.record("valid send rejected"); return }
        let assessment = Audit.assessIntent(policy: policy, capture: capture(), graph: graph(edges: edges().dropLast() + [actual]))
        #expect(!assessment.changeRequired)
        #expect(assessment.sendFindings?.count == 1)
        #expect(assessment.sendFindings?.first?.status == .compliant)
        #expect(assessment.sendFindings?.first?.observed == actual)
        let body = try plan(graph(edges: edges().dropLast() + [actual]), sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(4)])])
        #expect(body["steps"]?.arrayValue == [])
        #expect(body["unchanged_tasks"]?.arrayValue == [.string("send.target.approved.slot.5")])
        let reasons = try #require(body["reasons"]?.arrayValue)
        #expect(reasons.contains(.string("send_goal_verification_unavailable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?); #expect(!executable)
    }

    @Test(arguments: [false, true])
    func sendReplacementRequiresOptInWithoutLosingTheRequestedTask(_ allow: Bool) throws {
        var options = Audit.PlanningOptions(); options.allowReplaceSend = allow
        let body = try plan(graph(), sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)])], options: options)
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        let diff = try #require(step["proposed_routing_diff"]?.objectValue)
        #expect(diff["status"]?.stringValue == (allow ? "proposed" : "unverified"))
        if !allow {
            let blocked = try #require(step["blocked_reasons"]?.arrayValue)
            #expect(blocked.contains(.string("send_replacement_not_allowed")))
        }
        #expect(body["unchanged_tasks"]?.arrayValue == [])
    }

    @Test(arguments: [false, true])
    func absentSendRemovalNeedsCompleteCoverageAndCreationNeverInventsScalars(_ remove: Bool) throws {
        let action: [String: Value] = remove ? ["remove": .bool(true)] : ["bus": .int(3)]
        let entry = ["target": Value.string("approved"), "physical_slot": .int(5)].merging(action) { _, new in new }
        let body = try plan(graph(edges: Array(edges().dropLast())), sends: [.object(entry)])
        if remove {
            #expect(body["steps"]?.arrayValue == [])
            #expect(body["unchanged_tasks"]?.arrayValue?.count == 1)
        } else {
            let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
            #expect(step["before"] == .null)
            let reasons = try #require(step["blocked_reasons"]?.arrayValue)
            #expect(reasons.contains(.string("send_creation_metadata_unavailable")))
        }
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["send population incomplete"])
        let coverage = RoutingCoverage(population: complete, stripTrackAssociation: complete,
            mainOutput: complete, physicalOutput: complete, busToAuxInput: complete, sends: partial)
        let blocked = try plan(graph(edges: Array(edges().dropLast()), coverage: coverage), sends: [.object(entry)])
        #expect(blocked["unchanged_tasks"]?.arrayValue == [])
        #expect(blocked["steps"]?.arrayValue?.count == 1)
        #expect(blocked["findings"]?.arrayValue?.first?.objectValue?["status"]?.stringValue == "unverified")
    }

    @Test(arguments: ["population", "association", "sends", "snapshot", "epoch", "project", "source",
        "source_id", "duplicate_slot", "destination", "destination_id", "desired_bus"])
    func exactSendEvidenceLossOrAmbiguityCannotProduceAProposal(_ fault: String) throws {
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["incomplete"])
        var ns = nodes(), es = edges()
        let coverage = RoutingCoverage(population: fault == "population" ? partial : complete,
            stripTrackAssociation: fault == "association" ? partial : complete, mainOutput: complete,
            physicalOutput: complete, busToAuxInput: complete, sends: fault == "sends" ? partial : complete)
        if fault == "source" { ns.append(ns[0]) }
        if fault == "source_id" { ns.append(RoutingNode(id: ns[0].id, kind: .aux, displayName: "Same", busNumber: nil, targetRef: nil)) }
        if fault == "duplicate_slot" { es.append(es.last!) }
        if fault == "destination" { ns.removeAll { $0.id == "previous_opaque" } }
        if fault == "destination_id" { ns.append(RoutingNode(id: "previous_opaque", kind: .aux, displayName: "Same", busNumber: nil, targetRef: nil)) }
        if fault == "desired_bus" { ns.append(RoutingNode(id: "duplicate_bus", kind: .bus, displayName: "Same", busNumber: 3, targetRef: nil)) }
        // This is a pure captured-graph seam, never a claim of native complete routing.
        let candidate = graph(nodes: ns, edges: es, coverage: coverage, epoch: fault == "epoch" ? 4 : 3,
            snapshot: fault == "snapshot" ? "another_capture" : "proposal_fixture",
            project: fault == "project" ? TargetReference(rawValue: "prj_other") : project)
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let body = try plan(candidate, sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)])], options: options)
        #expect(body["unchanged_tasks"]?.arrayValue == [])
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        #expect(step["proposed_routing_diff"]?.objectValue?["status"]?.stringValue == "unverified")
        let reasons = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
    }

    @Test(arguments: [false, true])
    func exactSendDiffPreservesParallelSendsOutputsAndReceiverFanout(_ remove: Bool) throws {
        let untouched = RoutingEdge(kind: .send, source: "other_opaque", destination: "destination_opaque",
            send: SendEdge(sourceTrackRef: other, physicalSlot: 2, destinationBusNumber: 3, destinationRef: nil,
                displayedName: "Same", level: 0, mode: "post-fader", enabled: false), provenance: .axMixerStrip)
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let action: [String: Value] = remove ? ["remove": .bool(true)] : ["bus": .int(3)]
        let body = try plan(graph(edges: edges() + [untouched]), sends: [.object(
            ["target": Value.string("approved"), "physical_slot": .int(5)].merging(action) { _, new in new })], options: options)
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "proposed")
        for key in ["output_changes", "input_changes", "added_sends"] { #expect(delta[key]?.arrayValue == []) }
        #expect(delta["removed_sends"]?.arrayValue?.count == (remove ? 1 : 0))
        #expect(delta["changed_sends"]?.arrayValue?.count == (remove ? 0 : 1))
        let changed = try #require(remove ? delta["removed_sends"]?.arrayValue?.first
            : delta["changed_sends"]?.arrayValue?.first?.objectValue?["before"])
        let send = try JSONDecoder().decode(SendEdge.self, from: Data(encodeJSONStrict(changed, compact: true).utf8))
        #expect(send == edges().last?.send)
        #expect(send != untouched.send)
    }

    @Test func sendCanonicalDigestBindsActionsOptionsAndEveryTask() throws {
        let replace: Value = .object(["target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)])
        let remove: Value = .object(["target": .string("approved"), "physical_slot": .int(5), "remove": .bool(true)])
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let a = try plan(graph(), sends: [replace], options: options)
        let b = try plan(graph(), sends: [remove], options: options)
        let c = try plan(graph(), sends: [replace])
        #expect(a["digest"] != b["digest"]); #expect(a["digest"] != c["digest"])
        #expect(a["digest"] == (try plan(graph(), sends: [replace], options: options))["digest"])
        #expect(a["steps"] == a["preview"])
        let all = try plan(graph(), sends: [replace, .object([
            "target": .string("approved"), "physical_slot": .int(6), "remove": .bool(true)])], options: options)
        #expect(all["steps"]?.arrayValue?.count == 1)
        #expect(all["unchanged_tasks"]?.arrayValue?.count == 1)
        #expect(all["findings"]?.arrayValue?.count == 2)
        let baseline = try plan(graph())
        #expect(baseline["approved_policy"]?.objectValue?["sends"] == nil)
    }

    @Test(arguments: [false, true])
    func registeredSendPolicyRemainsAccountedAndCannotExecuteOnlyItsViewOrNames(_ remove: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let f = try Issue971ApprovedMixerSagaTests.Fixture(showing: false)
                await f.router.register(f.view.channel())
                _ = f.installNameHeaders(["Bass"])
                let action: [String: Value] = remove ? ["remove": .bool(true)] : ["bus": .int(3)]
                let p = try await f.namesPlan(["Bass"], policyExtras: [
                    "sends": .array([.object(["target": Value.string("t0"), "physical_slot": .int(5)]
                        .merging(action) { _, new in new })]),
                    "presentation": .object(["mixer_visible": .bool(true)])])
                let executable = try #require(p["executable"] as? Bool); #expect(!executable)
                let steps = try #require(p["steps"] as? [[String: Any]])
                #expect(steps.filter { $0["kind"] as? String == "send_assignment" }.count == 1)
                #expect(steps.filter { $0["kind"] as? String == "mixer_visibility" }.count == 1)
                let findings = try #require(p["findings"] as? [[String: Any]])
                #expect(findings.count == 1)
                #expect(findings.first?["status"] as? String == "unverified")
                let reasons = try #require(p["reasons"] as? [String])
                #expect(reasons.contains("send_goal_verification_unavailable"))
                let key = "never-execute-send-subset-\(remove)"
                let params = try f.applyParameters(p, key: key)
                let result = try await f.call("apply_session_repair", params: params)
                #expect(result["state"] as? String == "C")
                let attempted = try #require(result["write_attempted"] as? Bool); #expect(!attempted)
                #expect(f.view.events.isEmpty)
                #expect(await f.journal.record(for: key) == nil)
                #expect(await ApprovedSessionRepair.retained(id: try #require(p["plan_id"] as? String),
                    digest: try #require(p["digest"] as? String), key: key, cache: f.cache,
                    registry: f.registry, journal: f.journal) == nil)
            }
        }
    }

    @Test func sharedAssessmentAccountsOutputsAndEveryParallelSendWithoutChangingOldWire() throws {
        let second = RoutingEdge(kind: .send, source: "source_opaque", destination: "previous_opaque",
            send: SendEdge(sourceTrackRef: source, physicalSlot: 6, destinationBusNumber: 4, destinationRef: nil,
                displayedName: "Same", level: 0, mode: "post-fader", enabled: false), provenance: .axMixerStrip)
        var raw = sendPolicy(.array([
            .object(["target": .string("approved"), "physical_slot": .int(6), "remove": .bool(true)]),
            .object(["target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)])]))
        raw["outputs"] = .array([.object(["target": .string("approved"), "bus": .int(3)])])
        guard case .accepted(let policy) = Audit.parseIntentPolicy(raw) else { Issue.record("parallel tasks rejected"); return }
        let candidate = graph(edges: edges() + [second])
        let assessment = Audit.assessIntent(policy: policy, capture: capture(), graph: candidate)
        #expect(assessment.changeRequired)
        #expect(assessment.findings.count == 1)
        #expect(assessment.sendFindings?.map(\.physicalSlot) == [5, 6])
        #expect(assessment.sendFindings?.map(\.status) == [.violation, .violation])
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let canonical = try Audit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw), names: [],
            capture: capture(), request: Observation.Request(domains: [.tracks, .strips, .routing]),
            snapshotCurrent: true, options: options, graphOverride: candidate)
        let body = try #require(JSONDecoder().decode(Value.self, from: Data(canonical.json.utf8)).objectValue)
        #expect(body["steps"]?.arrayValue?.count == 3)
        #expect(body["findings"]?.arrayValue?.count == 3)
        #expect(body["preview"] == body["steps"])
        let executable = try #require(body["executable"]?.boolValue as Bool?); #expect(!executable)
        raw.removeValue(forKey: "sends")
        guard case .accepted(let originalPolicy) = Audit.parseIntentPolicy(raw) else { Issue.record("old policy rejected"); return }
        let original = Audit.assessIntent(policy: originalPolicy, capture: capture(), graph: candidate)
        let oldWire = try #require(JSONDecoder().decode(Value.self,
            from: Data(encodeJSONStrict(original, compact: true).utf8)).objectValue)
        #expect(oldWire["send_findings"] == nil)
        #expect(original.findings == assessment.findings)
    }

    @Test func registeredRoutingInspectionCarriesExactSendTaskAndActualProviderLimitations() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Issue971ApprovedMixerSagaTests.Fixture(showing: true)
            _ = f.installNameHeaders(["Bass"])
            let report = try await f.call("inspect_session", params: [
                "domains": .array([.string("tracks"), .string("strips"), .string("routing")])])
            let snapshot = try #require(report["snapshot_id"] as? String)
            let rows = try #require((report["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
            let reference = try #require(rows.first?["track_ref"] as? String)
            let projectRef = try #require((report["project"] as? [String: Any])?["project_ref"] as? String)
            let p = try await f.call("plan_session_repair", params: ["snapshot_id": .string(snapshot),
                "policy": .object(["schema": .string(Audit.intentPolicySchema), "project_ref": .string(projectRef),
                    "targets": .array([.object(["handle": .string("approved"), "track_ref": .string(reference)])]),
                    "sends": .array([.object(["target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)])])])])
            let findings = try #require(p["findings"] as? [[String: Any]])
            let finding = try #require(findings.first)
            #expect((finding["target"] as? [String: Any])?["track_ref"] as? String == reference)
            #expect(finding["physical_slot"] as? Int == 5)
            #expect(finding["status"] as? String == "unverified")
            let steps = try #require(p["steps"] as? [[String: Any]])
            let reasons = try #require(steps.first?["blocked_reasons"] as? [String])
            #expect(!reasons.contains("routing_not_requested"))
            #expect(reasons.contains("exact_target_send_adapter_unavailable"))
            let executable = try #require(p["executable"] as? Bool); #expect(!executable)
            let retained = try await f.call("plan_session_repair", params: [
                "plan_id": .string(try #require(p["plan_id"] as? String)),
                "digest": .string(try #require(p["digest"] as? String))])
            #expect(HonestContract.jsonString(retained) == HonestContract.jsonString(p))
            #expect(f.view.events.isEmpty)
        }
    }

    @Test(arguments: ["violation", "compliant", "unverified"])
    func sendFindingsDistinguishSeverityFromStatus(_ status: String) throws {
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["send evidence incomplete"])
        let coverage = RoutingCoverage(population: complete, stripTrackAssociation: complete,
            mainOutput: complete, physicalOutput: complete, busToAuxInput: complete,
            sends: status == "unverified" ? partial : complete)
        let body = try plan(graph(coverage: coverage), sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(status == "compliant" ? 4 : 3)
        ])])
        let finding = try #require(body["findings"]?.arrayValue?.first?.objectValue)
        #expect(finding["status"]?.stringValue == status)
        #expect(finding["severity"]?.stringValue == (status == "violation" ? "warn" : "info"))
    }

    @Test(arguments: [-Double.infinity, Double.infinity, Double.nan])
    func nonfiniteObservedSendLevelsRemainAccountedForWithoutInventedAbsence(_ level: Double) throws {
        let old = try #require(edges().last)
        let send = try #require(old.send)
        let actual = RoutingEdge(kind: .send, source: old.source, destination: old.destination,
            send: SendEdge(sourceTrackRef: send.sourceTrackRef, physicalSlot: send.physicalSlot,
                destinationBusNumber: send.destinationBusNumber, destinationRef: send.destinationRef,
                displayedName: send.displayedName, level: level, mode: send.mode, enabled: send.enabled), provenance: old.provenance)
        let candidate = graph(edges: edges().dropLast() + [actual])
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let body = try plan(candidate, sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(4)
        ])], options: options)
        #expect(body["unchanged_tasks"]?.arrayValue == [])
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        #expect(step["kind"]?.stringValue == "send_assignment")
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(blocked.contains(.string("send_scalar_unserializable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test(arguments: ["stale", "unrequested"])
    func matchingSendCannotBecomeUnchangedOverAStaleOrUnrequestedRead(_ fault: String) throws {
        let body = try plan(graph(), sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(4)
        ])], snapshotCurrent: fault != "stale", request: Observation.Request(
            domains: fault == "unrequested" ? [.tracks] : [.tracks, .strips, .routing]))
        #expect(body["unchanged_tasks"]?.arrayValue == [])
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        let delta = try #require(step["proposed_routing_diff"]?.objectValue)
        #expect(delta["status"]?.stringValue == "unverified")
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(blocked.contains(.string(fault == "stale" ? "snapshot_changed" : "routing_not_requested")))
    }

    @Test(arguments: [false, true])
    func unrelatedNonfiniteSendPreventsAnUnserializableSharedRoutingProposal(_ sendTask: Bool) throws {
        let unrelated = RoutingEdge(kind: .send, source: "other_opaque", destination: "previous_opaque",
            send: SendEdge(sourceTrackRef: other, physicalSlot: 2, destinationBusNumber: 4, destinationRef: nil,
                displayedName: "Same", level: .nan, mode: "post-fader", enabled: false), provenance: .axMixerStrip)
        var options = Audit.PlanningOptions(); options.allowReplaceSend = true
        let body = try plan(graph(edges: edges() + [unrelated]), sends: sendTask ? [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)
        ])] : nil, options: options)
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        let delta = try #require(step["proposed_routing_diff"]?.objectValue)
        #expect(delta["status"]?.stringValue == "unverified")
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(blocked.contains(.string("send_scalar_unserializable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    /// A newly approved receiver is a prerequisite of every send onto its bus, not of
    /// unrelated send replacements or removals. This is a pure draft, never native creation.
    @Test(arguments: ["new_receiver", "other_bus", "remove"])
    func sendReceiverDependenciesOnlyBindTheApprovedDestination(_ action: String) throws {
        let extraBus = RoutingNode(id: "another_bus", kind: .bus, displayName: "Same", busNumber: 7, targetRef: nil)
        var es = edges().filter { $0.kind != .inputAssignment }
        var sends: [Value] = [.object([
            "target": .string("approved"), "physical_slot": .int(5),
        ].merging(action == "remove" ? ["remove": .bool(true)]
            : ["bus": .int(action == "new_receiver" ? 3 : 7)]) { _, new in new })]
        if action == "new_receiver" {
            es.append(RoutingEdge(kind: .send, source: "source_opaque", destination: "previous_opaque",
                send: SendEdge(sourceTrackRef: source, physicalSlot: 6, destinationBusNumber: 4,
                    destinationRef: nil, displayedName: "Same", level: -20, mode: "post-fader", enabled: true),
                provenance: .axMixerStrip))
            sends.append(.object(["target": .string("approved"), "physical_slot": .int(6), "bus": .int(3)]))
        }
        var options = Audit.PlanningOptions()
        options.allowCreateAux = true
        options.allowReplaceSend = true
        let candidate = graph(nodes: nodes() + [extraBus], edges: es)
        #expect(candidate.isConsistent)
        let body = try plan(candidate, sends: sends, options: options, policyExtras: [
            "receivers": .array([.object(["bus": .int(3), "aux": .string("new")])]),
        ])
        let steps = try #require(body["steps"]?.arrayValue)
        let aux = try #require(steps.first?.objectValue)
        #expect(aux["kind"]?.stringValue == "create_aux")
        let auxID = try #require(aux["id"]?.stringValue)
        let assignments = steps.dropFirst().compactMap(\.objectValue)
        #expect(assignments.count == sends.count)
        for step in assignments {
            #expect(step["kind"]?.stringValue == "send_assignment")
            let dependencies = try #require(step["dependencies"]?.arrayValue)
            #expect(dependencies == (action == "new_receiver" ? [.string(auxID)] : []))
        }
        #expect(body["preview"] == body["steps"])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test(arguments: ["disallowed", "unknown", "ask", "none", "present"])
    func changedSendsRetainTheirReceiverDecision(_ situation: String) throws {
        let es = situation == "present" ? edges() : edges().filter { $0.kind != .inputAssignment }
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["receiver inputs unread"])
        let domains = RoutingCoverage(population: complete, stripTrackAssociation: complete,
            mainOutput: complete, physicalOutput: complete,
            busToAuxInput: situation == "unknown" ? partial : complete, sends: complete)
        var extras: [String: Value] = [:]
        if ["disallowed", "unknown", "none"].contains(situation) {
            extras["receivers"] = .array([.object([
                "bus": .int(3), "aux": .string(situation == "none" ? "none" : "new"),
            ])])
        }
        var options = Audit.PlanningOptions()
        options.allowCreateAux = situation != "disallowed"
        options.allowReplaceSend = true
        let body = try plan(graph(edges: es, coverage: domains), sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(3),
        ])], options: options, policyExtras: extras)
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1)
        let step = try #require(steps.first?.objectValue)
        #expect(step["kind"]?.stringValue == "send_assignment")
        #expect(step["dependencies"]?.arrayValue == [])
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        if situation == "disallowed" {
            #expect(blocked.contains(.string("receiving_aux_missing")))
            #expect(blocked.contains(.string("create_aux_not_allowed")))
        }
        if situation == "unknown" { #expect(blocked.contains(.string("bus_receiver_unverified"))) }
        let questions = try #require(body["receiver_questions"]?.arrayValue)
        #expect(questions.count == (situation == "ask" ? 1 : 0))
        if situation == "ask" {
            let question = try #require(questions.first?.objectValue)
            #expect(question["bus"]?.intValue == 3)
            #expect(question["observed"]?.stringValue == "no_receiver")
        }
        #expect(body["steps"] == body["preview"])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test func approvedExactSendReplacementUsesOneCanonicalPreservingDiff() throws {
        var options = Audit.PlanningOptions()
        options.allowReplaceSend = true
        let beforeGraph = graph()
        let body = try plan(beforeGraph, sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "bus": .int(3)
        ])], options: options)
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1)
        #expect(body["preview"] == body["steps"])
        let step = try #require(steps.first?.objectValue)
        #expect(step["kind"]?.stringValue == "send_assignment")
        #expect(step["target_ref"]?.stringValue == source.rawValue)
        #expect(step["physical_slot"]?.intValue == 5)
        let delta = try #require(step["proposed_routing_diff"]?.objectValue)
        #expect(delta["status"]?.stringValue == "proposed")
        #expect(delta["observation"]?.stringValue == "proposed_not_observed")
        for key in ["output_changes", "input_changes", "added_sends", "removed_sends"] {
            #expect(delta[key]?.arrayValue == [])
        }
        let changes = try #require(delta["changed_sends"]?.arrayValue)
        #expect(changes.count == 1)
        let change = try #require(changes.first?.objectValue)
        let before = try JSONDecoder().decode(SendEdge.self, from: Data(encodeJSONStrict(#require(change["before"]), compact: true).utf8))
        let after = try JSONDecoder().decode(SendEdge.self, from: Data(encodeJSONStrict(#require(change["after"]), compact: true).utf8))
        #expect(before == beforeGraph.edges.last?.send)
        #expect(after.sourceTrackRef == source && after.physicalSlot == 5)
        #expect(after.destinationBusNumber == 3 && after.destinationRef == nil)
        #expect(after.level == before.level && after.mode == before.mode && after.enabled == before.enabled)
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(blocked.contains(.string("exact_target_send_adapter_unavailable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test func approvedExactSendRemovalPreservesBusReceiversAndOtherRoutes() throws {
        let beforeGraph = graph()
        let body = try plan(beforeGraph, sends: [.object([
            "target": .string("approved"), "physical_slot": .int(5), "remove": .bool(true)
        ])])
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1 && body["steps"] == body["preview"])
        let step = try #require(steps.first?.objectValue)
        #expect(step["kind"]?.stringValue == "send_assignment")
        let delta = try #require(step["proposed_routing_diff"]?.objectValue)
        #expect(delta["status"]?.stringValue == "proposed")
        #expect(delta["observation"]?.stringValue == "proposed_not_observed")
        for key in ["output_changes", "input_changes", "added_sends", "changed_sends"] {
            #expect(delta[key]?.arrayValue == [])
        }
        let removed = try #require(delta["removed_sends"]?.arrayValue)
        #expect(removed.count == 1)
        let actual = try JSONDecoder().decode(SendEdge.self, from: Data(encodeJSONStrict(#require(removed.first), compact: true).utf8))
        #expect(actual == beforeGraph.edges.last?.send)
        #expect(step["after"]?.objectValue?["remove"] == .bool(true))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test func approvedBusFourToNoOutputHasOneMinimalProposedRemoval() throws {
        let body = try plan(graph(), noOutput: true)
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "proposed")
        #expect(delta["basis"]?.stringValue == "approved_policy")
        #expect(delta["observation"]?.stringValue == "proposed_not_observed")
        let changes = try #require(delta["output_changes"]?.arrayValue)
        #expect(changes.count == 1)
        let change = try #require(changes.first?.objectValue)
        #expect(try decodeEdge(#require(change["before"]))
                == edge(.mainOutput, "source_opaque", "previous_opaque"))
        #expect(change["after"] == .null)
        #expect(body["steps"] == body["preview"])
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        #expect(step["target_ref"]?.stringValue == source.rawValue)
        #expect(step["after"]?.objectValue?["output"]?.stringValue == "no_output")
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(blocked.contains(.string("exact_target_routing_adapter_unavailable")))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test func alreadyNoOutputRemainsUnchangedWithoutAProposedRemoval() throws {
        let assignments = edges().filter { $0.kind != .mainOutput || $0.source != "source_opaque" }
        let body = try plan(graph(nodes: nodes(output: .noOutput), edges: assignments), noOutput: true)
        #expect(body["steps"]?.arrayValue == [])
        #expect(body["preview"]?.arrayValue == [])
        #expect(body["unchanged_tasks"]?.arrayValue == [.string("main_output.target.approved")])
        #expect(body["new_object_inventory"]?.arrayValue == [])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable, "sampled compliance does not supply the retained routing-goal verifier")
        let reasons = try #require(body["reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
    }

    @Test(arguments: [false, true])
    func noOutputClassificationCannotHideObservedOutputEdges(duplicate: Bool) throws {
        var assignments = edges()
        if duplicate {
            assignments.append(edge(.mainOutput, "source_opaque", "destination_opaque"))
        }
        let candidate = graph(nodes: nodes(output: .noOutput), edges: assignments)
        #expect(candidate.isConsistent)
        let body = try plan(candidate, noOutput: true)
        let findings = try #require(body["findings"]?.arrayValue)
        let finding = try #require(findings.first?.objectValue)
        #expect(finding["status"]?.stringValue == "unverified")
        let reasons = try #require(finding["reasons"]?.arrayValue)
        #expect(reasons.contains(.string("output_edge_ambiguous")))
        #expect(body["unchanged_tasks"]?.arrayValue == [])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1)
        #expect(body["preview"] == body["steps"])
        let step = try #require(steps.first?.objectValue)
        #expect(step["target_ref"]?.stringValue == source.rawValue)
        let delta = try #require(step["proposed_routing_diff"]?.objectValue)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
    }

    @Test func noOutputClassificationRequiresUniqueSourceIdentity() throws {
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["unrelated send scope unread"])
        let coverage = RoutingCoverage(population: complete, stripTrackAssociation: complete,
            mainOutput: complete, physicalOutput: complete, busToAuxInput: complete, sends: partial)
        let candidates = nodes(output: .noOutput) + [RoutingNode(id: "source_opaque", kind: .physicalStrip,
            displayName: "Same", busNumber: nil, targetRef: nil)]
        let assignments = edges().filter { $0.kind != .mainOutput || $0.source != "source_opaque" }
        let candidate = graph(nodes: candidates, edges: assignments, coverage: coverage)
        #expect(candidate.isConsistent)
        let body = try plan(candidate, noOutput: true)
        let finding = try #require(body["findings"]?.arrayValue?.first?.objectValue)
        #expect(finding["status"]?.stringValue == "unverified")
        let reasons = try #require(finding["reasons"]?.arrayValue)
        #expect(reasons.contains(.string("source_node_ambiguous")))
        #expect(body["unchanged_tasks"]?.arrayValue == [])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
        let steps = try #require(body["steps"]?.arrayValue)
        #expect(steps.count == 1)
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
    }

    @Test func noOutputRemovalPreservesUnrelatedOutputSendAndReceiverFanout() throws {
        let before = graph()
        let delta = try proposal(plan(before, noOutput: true))
        for field in ["added_sends", "removed_sends", "changed_sends", "input_changes"] {
            #expect(delta[field]?.arrayValue == [])
        }
        let changes = try #require(delta["output_changes"]?.arrayValue)
        #expect(changes.count == 1)
        let change = try #require(changes.first?.objectValue)
        let removed = try decodeEdge(#require(change["before"]))
        #expect(change["after"] == .null)
        let proposedEdges = before.edges.filter { $0 != removed }
        #expect(proposedEdges.filter { $0.kind == .mainOutput }
                == [edge(.mainOutput, "other_opaque", "previous_opaque")])
        #expect(proposedEdges.filter { $0.kind == .inputAssignment }
                == before.edges.filter { $0.kind == .inputAssignment })
        #expect(proposedEdges.filter { $0.kind == .send } == before.edges.filter { $0.kind == .send })
    }

    @Test(arguments: ["missing_source", "duplicate_source_ref", "duplicate_source_id", "missing_output",
                      "duplicate_output", "duplicate_unrelated_output", "duplicate_send", "missing_before_bus",
                      "aux_before_bus", "contradictory_source_classification"])
    func noOutputDoesNotBypassAssignmentOrClassificationGuards(_ fault: String) throws {
        var candidates = nodes(output: fault == "contradictory_source_classification" ? .physicalOutput : .bus)
        var assignments = edges()
        switch fault {
        case "missing_source": candidates.removeAll { $0.targetRef == source }
        case "duplicate_source_ref":
            candidates.append(RoutingNode(id: "source_again", kind: .track, displayName: "Same", busNumber: nil,
                                          targetRef: source, outputClassification: .bus))
        case "duplicate_source_id":
            candidates.append(RoutingNode(id: "source_opaque", kind: .track, displayName: "Same", busNumber: nil,
                                          targetRef: other, outputClassification: .bus))
        case "missing_output": assignments.removeAll { $0.kind == .mainOutput && $0.source == "source_opaque" }
        case "duplicate_output": assignments.append(edge(.mainOutput, "source_opaque", "destination_opaque"))
        case "duplicate_unrelated_output": assignments.append(edge(.mainOutput, "other_opaque", "destination_opaque"))
        case "duplicate_send": assignments.append(try #require(assignments.last))
        case "missing_before_bus": candidates.removeAll { $0.id == "previous_opaque" }
        case "aux_before_bus":
            candidates.removeAll { $0.id == "previous_opaque" }
            candidates.append(RoutingNode(id: "previous_opaque", kind: .aux, displayName: "Bus 4",
                                          busNumber: 4, targetRef: nil))
        default: break
        }
        let body = try plan(graph(nodes: candidates, edges: assignments), noOutput: true)
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test(arguments: ["snapshot", "project", "epoch", "unrequested", "population", "association", "outputs", "inputs", "sends"])
    func noOutputRequiresFreshCompleteAffectedObservations(_ fault: String) throws {
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["not completely observed"])
        let coverage = RoutingCoverage(population: fault == "population" ? partial : complete,
                                       stripTrackAssociation: fault == "association" ? partial : complete,
                                       mainOutput: fault == "outputs" ? partial : complete,
                                       physicalOutput: complete,
                                       busToAuxInput: fault == "inputs" ? partial : complete,
                                       sends: fault == "sends" ? partial : complete)
        let candidate = graph(coverage: coverage, epoch: fault == "epoch" ? 4 : 3,
                              project: fault == "project" ? TargetReference(rawValue: "prj_foreign") : project)
        let body = try plan(candidate, noOutput: true, snapshotCurrent: fault != "snapshot",
                            request: Observation.Request(domains: fault == "unrequested" ? [.tracks] : [.tracks, .strips, .routing]))
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test(arguments: [false, true])
    func contradictoryPhysicalClassificationCannotSupplyABusBeforeEdge(noOutput: Bool) throws {
        let body = try plan(graph(nodes: nodes(output: .physicalOutput)), noOutput: noOutput)
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(reasons.contains(.string("proposed_before_output_not_bus")))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test func noOutputPreviewAndDigestBindTheExactRemoval() throws {
        let original = try plan(graph(), noOutput: true)
        var repeated = try plan(graph(), noOutput: true)
        let busAssignment = try plan(graph())
        #expect(original["digest"] == repeated["digest"])
        #expect(original["digest"] != busAssignment["digest"])
        #expect(original["steps"] == original["preview"])
        #expect(original["steps"] != busAssignment["steps"])
        let digest = try #require(repeated.removeValue(forKey: "digest")?.stringValue)
        repeated.removeValue(forKey: "plan_id")
        let bytes = try encodeJSONStrict(Value.object(repeated), compact: true)
        let calculated = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == calculated)
    }

    @Test func wrongBusFourToThreeHasOneMinimalProposedReplacementAndNoObservationClaim() throws {
        let body = try plan(graph())
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "proposed")
        #expect(delta["basis"]?.stringValue == "approved_policy")
        #expect(delta["observation"]?.stringValue == "proposed_not_observed")
        let changes = try #require(delta["output_changes"]?.arrayValue)
        #expect(changes.count == 1)
        let change = try #require(changes.first?.objectValue)
        let before = try decodeEdge(#require(change["before"]))
        let after = try decodeEdge(#require(change["after"]))
        #expect(before == edge(.mainOutput, "source_opaque", "previous_opaque"))
        #expect(after.kind == .mainOutput && after.source == before.source && after.destination == "destination_opaque")
        #expect(after.send == nil && after.provenance == .other)
        #expect(body["steps"] == body["preview"])
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
        let step = try #require(body["steps"]?.arrayValue?.first?.objectValue)
        #expect(step["target_ref"]?.stringValue == source.rawValue)
        let blocked = try #require(step["blocked_reasons"]?.arrayValue)
        #expect(blocked.contains(.string("exact_target_routing_adapter_unavailable")))
    }

    @Test func unrelatedOutputSendAndTwoReceiverFanoutRemainExactlyUnchanged() throws {
        let before = graph()
        let delta = try proposal(plan(before))
        for field in ["added_sends", "removed_sends", "changed_sends", "input_changes"] {
            #expect(delta[field]?.arrayValue == [])
        }
        let change = try #require(delta["output_changes"]?.arrayValue?.first?.objectValue)
        let old = try decodeEdge(#require(change["before"]))
        let desired = try decodeEdge(#require(change["after"]))
        let proposedEdges = before.edges.map { $0 == old ? desired : $0 }
        #expect(proposedEdges.filter { $0.source != old.source || $0.kind != .mainOutput }
                == before.edges.filter { $0.source != old.source || $0.kind != .mainOutput })
        #expect(proposedEdges.filter { $0.kind == .inputAssignment } == before.edges.filter { $0.kind == .inputAssignment })
        #expect(proposedEdges.filter { $0.kind == .send } == before.edges.filter { $0.kind == .send })
    }

    @Test func alreadyCorrectIsUnchangedWithoutAProposedDiff() throws {
        let body = try plan(graph(edges: edges(correct: true)))
        #expect(body["steps"]?.arrayValue == [])
        #expect(body["preview"]?.arrayValue == [])
        #expect(body["unchanged_tasks"]?.arrayValue == [.string("main_output.target.approved")])
    }

    @Test func duplicateLookingNamesDoNotChooseTheSourceOrTheDestination() throws {
        let forward = try plan(graph())
        let reverse = try plan(graph(nodes: nodes().reversed(), edges: edges().reversed()))
        #expect(forward["steps"] == reverse["steps"])
        #expect(forward["digest"] == reverse["digest"])
        let delta = try proposal(reverse)
        let change = try #require(delta["output_changes"]?.arrayValue?.first?.objectValue)
        let after = try decodeEdge(#require(change["after"]))
        #expect(after.source == "source_opaque" && after.destination == "destination_opaque")
    }

    @Test(arguments: ["missing_destination", "duplicate_destination", "aux_not_bus", "missing_source",
                      "duplicate_source_ref", "duplicate_source_id", "missing_output", "duplicate_output",
                      "duplicate_unrelated_output"])
    func missingOrAmbiguousAssignmentsNeverBecomeAnEmptySuccessDiff(_ fault: String) throws {
        var candidates = nodes()
        var assignments = edges()
        switch fault {
        case "missing_destination": candidates.removeAll { $0.id == "destination_opaque" }
        case "duplicate_destination":
            candidates.append(RoutingNode(id: "another_destination", kind: .bus, displayName: "Same", busNumber: 3, targetRef: nil))
        case "aux_not_bus":
            candidates.removeAll { $0.id == "destination_opaque" }
            candidates.append(RoutingNode(id: "destination_opaque", kind: .aux, displayName: "Bus 3", busNumber: 3, targetRef: nil))
        case "missing_source": candidates.removeAll { $0.targetRef == source }
        case "duplicate_source_ref":
            candidates.append(RoutingNode(id: "source_again", kind: .track, displayName: "Same", busNumber: nil,
                                          targetRef: source, outputClassification: .bus))
        case "duplicate_source_id":
            candidates.append(RoutingNode(id: "source_opaque", kind: .track, displayName: "Same", busNumber: nil,
                                          targetRef: other, outputClassification: .bus))
        case "missing_output": assignments.removeAll { $0.kind == .mainOutput && $0.source == "source_opaque" }
        case "duplicate_output": assignments.append(edge(.mainOutput, "source_opaque", "destination_opaque"))
        default: assignments.append(edge(.mainOutput, "other_opaque", "destination_opaque"))
        }
        let body = try plan(graph(nodes: candidates, edges: assignments))
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test(arguments: ["snapshot", "project", "epoch", "unrequested", "population", "association", "outputs", "inputs", "sends"])
    func staleOrPartialAffectedObservationsDoNotAuthorizeAProposal(_ fault: String) throws {
        let partial = RoutingDomainCoverage(state: .partial, reasons: ["not completely observed"])
        let coverage = RoutingCoverage(population: fault == "population" ? partial : complete,
                                       stripTrackAssociation: fault == "association" ? partial : complete,
                                       mainOutput: fault == "outputs" ? partial : complete,
                                       physicalOutput: complete,
                                       busToAuxInput: fault == "inputs" ? partial : complete,
                                       sends: fault == "sends" ? partial : complete)
        let graph = graph(coverage: coverage, epoch: fault == "epoch" ? 4 : 3,
                          project: fault == "project" ? TargetReference(rawValue: "prj_foreign") : project)
        let body = try plan(graph, snapshotCurrent: fault != "snapshot",
                            request: Observation.Request(domains: fault == "unrequested" ? [.tracks] : [.tracks, .strips, .routing]))
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }

    @Test func digestBindsTheActualDesiredEdgeAndTheSameCanonicalPreview() throws {
        let candidates = nodes() + [RoutingNode(id: "fifth_bus_opaque", kind: .bus, displayName: "Same", busNumber: 5, targetRef: nil)]
        let original = try plan(graph(nodes: candidates))
        var repeated = try plan(graph(nodes: candidates))
        let changed = try plan(graph(nodes: candidates), bus: 5)
        #expect(original["digest"] == repeated["digest"])
        #expect(original["digest"] != changed["digest"])
        #expect(original["steps"] != changed["steps"])
        #expect(original["plan_id"] != repeated["plan_id"])
        let digest = try #require(repeated.removeValue(forKey: "digest")?.stringValue)
        repeated.removeValue(forKey: "plan_id")
        let bytes = try encodeJSONStrict(Value.object(repeated), compact: true)
        let calculated = SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == calculated)
        #expect(changed["steps"] == changed["preview"])
        let change = try #require(proposal(changed)["output_changes"]?.arrayValue?.first?.objectValue)
        #expect(try decodeEdge(#require(change["after"])).destination == "fifth_bus_opaque")
    }

    @Test func foreignGraphSnapshotCannotSupplyAProposedAfterEdge() throws {
        let delta = try proposal(plan(graph(snapshot: "another_capture")))
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(!reasons.isEmpty)
    }

    @Test func referencedAuxNodeCannotBecomeATrackMainOutputProposal() throws {
        var candidates = nodes().filter { $0.id != "source_opaque" }
        candidates.append(RoutingNode(id: "source_opaque", kind: .aux, displayName: "Same", busNumber: nil,
                                      targetRef: source, outputClassification: .bus))
        let body = try plan(graph(nodes: candidates))
        let delta = try proposal(body)
        #expect(delta["status"]?.stringValue == "unverified")
        #expect(delta["output_changes"] == nil)
        let reasons = try #require(delta["reasons"]?.arrayValue)
        #expect(reasons.contains(.string("proposed_source_not_track")))
        let executable = try #require(body["executable"]?.boolValue as Bool?)
        #expect(!executable)
    }
}
