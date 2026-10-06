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

    private func nodes() -> [RoutingNode] {
        [
            RoutingNode(id: "source_opaque", kind: .track, displayName: "Same", busNumber: nil,
                        targetRef: source, outputClassification: .bus),
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

    private func plan(_ graph: RoutingGraph, bus: Int = 3, snapshotCurrent: Bool = true,
                      request: Observation.Request = Observation.Request(domains: [.tracks, .strips, .routing])) throws -> [String: Value] {
        let raw: [String: Value] = [
            "schema": .string(Audit.intentPolicySchema), "project_ref": .string(project.rawValue),
            "targets": .array([.object(["handle": .string("approved"), "track_ref": .string(source.rawValue)])]),
            "outputs": .array([.object(["target": .string("approved"), "bus": .int(bus)])]),
        ]
        guard case .accepted(let policy) = Audit.parseIntentPolicy(raw) else {
            Issue.record("valid explicit policy rejected")
            throw CocoaError(.coderInvalidValue)
        }
        let result = try Audit.buildCanonicalRepairPlan(policy: policy, policyValue: .object(raw), names: [],
                                                       capture: capture(), request: request, snapshotCurrent: snapshotCurrent,
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
