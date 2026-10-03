import Foundation
import MCP
import Testing
@testable import LogicProMCP

// #966 P1 (ADR-021). Every case drives the pure `parseIntentPolicy` / `assessIntent` on a #965
// Capture and a #291 RoutingGraph. One case reads a real StateCache and TargetRegistry through
// `SessionPopulationObservation.capture` and `routingGraph(capture:)`, and two publish a fixture
// capture through `routingGraph(capture:)`; every other graph is built by hand. Each test's leading
// comment names the mutation of the source that must make it fail.
//
// The hand-built graphs are `complete` in the two domains the rule reads. `publish` never yields
// that today: it leaves `main_output` and `strip_track_association` partial on every real read, so
// these graphs show what the rule decides once #291 can say more, and the real-path case shows what
// it decides now.

private typealias Audit = ProjectSessionAudit
private typealias Observation = SessionPopulationObservation

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let freshRead = fixedNow.addingTimeInterval(-1)

private let baselineVersions: [CacheSectionID: StateCache.SectionVersion] = [
    .tracks: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 7),
    .mixer: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 2),
    .project: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 1),
]
/// Explicit identity for constructed matching capture/graph fixtures, not a production revision ID.
private let baselineSnapshotId = "fixture_population_capture"
private let songReference = TargetReference(rawValue: "prj_song")

// MARK: - Capture fixtures (the #965 shape)

private func liveTrack(_ index: Int, name: String? = nil) -> TrackState {
    TrackState(id: index, name: name ?? "Track \(index + 1)", type: .audio)
}

private func trackRef(_ index: Int) -> TargetReference {
    TargetReference(rawValue: "trk_\(index)")
}

private func issuedReferences(for tracks: [TrackState]) -> IssuedTrackReferences {
    let references = tracks.map { trackRef($0.id) }
    return IssuedTrackReferences(
        byRow: references,
        byTrackIndex: Dictionary(uniqueKeysWithValues: zip(tracks.map(\.id), references)),
        ambiguousTrackIndices: []
    )
}

private func boundary(
    _ versions: [CacheSectionID: StateCache.SectionVersion] = baselineVersions,
    hasDocument: Bool = true,
    axOccluded: Bool = false
) -> StateCache.CaptureBoundary {
    StateCache.CaptureBoundary(versions: versions, occlusionRevision: 0, hasDocument: hasDocument, axOccluded: axOccluded)
}

private func makeCapture(
    tracks: [TrackState],
    issued: IssuedTrackReferences?,
    referencesEnabled: Bool? = nil,
    before: StateCache.CaptureBoundary = boundary(),
    after: StateCache.CaptureBoundary? = nil,
    projectIssuance: ProjectIssuance? = .issued(songReference)
) -> Observation.Capture {
    let enabled = referencesEnabled ?? (issued != nil)
    return Observation.Capture(
        before: before,
        after: after ?? before,
        projectEpoch: 3,
        project: ProjectInfo(name: "Song", filePath: "/Users/x/Song.logicx"),
        tracks: tracks,
        tracksFetchedAt: freshRead,
        channelStrips: [],
        mixerFetchedAt: freshRead,
        fileTrackCount: tracks.count,
        projectFileNotBound: false,
        requestedProjectMatches: nil,
        referencesEnabled: enabled,
        targetSnapshot: enabled ? TargetRegistrySnapshot(projectEpoch: 3, topologyGeneration: 0) : nil,
        issued: issued,
        projectIssuance: enabled ? projectIssuance : nil,
        beganAt: fixedNow.addingTimeInterval(-0.01),
        endedAt: fixedNow,
        // Constructed fixture identity shared with its matching graph fixtures.
        captureID: "fixture_population_capture"
    )
}

/// Kick / Snare / Tom, all three with issued references.
private let threeTracks = [liveTrack(0, name: "Kick"), liveTrack(1, name: "Snare"), liveTrack(2, name: "Tom")]
private let threeTrackCapture = makeCapture(tracks: threeTracks, issued: issuedReferences(for: threeTracks))

// MARK: - Graph fixtures (the #291 shape)

private func trackNode(
    _ index: Int,
    name: String? = nil,
    output: RoutingOutputClassification? = .bus
) -> RoutingNode {
    RoutingNode(
        id: "trk_\(index)",
        kind: .track,
        displayName: name ?? "Track \(index + 1)",
        busNumber: nil,
        targetRef: trackRef(index),
        observedOutputLabel: nil,
        outputClassification: output
    )
}

/// Node ids are opaque here on purpose: the bus number lives in `busNumber`, never in the id.
private func busNode(_ bus: Int, id: String) -> RoutingNode {
    RoutingNode(id: id, kind: .bus, displayName: "Bus \(bus)", busNumber: bus, targetRef: nil)
}

private func auxNode(_ id: String) -> RoutingNode {
    RoutingNode(id: id, kind: .aux, displayName: id, busNumber: nil, targetRef: nil)
}

private let drumBus = busNode(3, id: "aux_drum_bus")
private let reverbBus = busNode(4, id: "aux_reverb")

private func mainOutput(from index: Int, to destination: String) -> RoutingEdge {
    RoutingEdge(kind: .mainOutput, source: "trk_\(index)", destination: destination, send: nil, provenance: .axMixerStrip)
}

private func inputAssignment(from bus: RoutingNode, to receiver: RoutingNode) -> RoutingEdge {
    RoutingEdge(kind: .inputAssignment, source: bus.id, destination: receiver.id, send: nil, provenance: .axMixerStrip)
}

private func sendEdge(from index: Int, slot: Int, to destination: RoutingNode, level: Double?, enabled: Bool) -> RoutingEdge {
    RoutingEdge(
        kind: .send,
        source: "trk_\(index)",
        destination: destination.id,
        send: SendEdge(
            sourceTrackRef: trackRef(index),
            physicalSlot: slot,
            destinationBusNumber: destination.busNumber,
            destinationRef: nil,
            displayedName: destination.displayName,
            level: level,
            mode: "post-fader",
            enabled: enabled
        ),
        provenance: .axMixerStrip
    )
}

private let completeDomain = RoutingDomainCoverage(state: .complete, reasons: [])
private let completeCoverage = RoutingCoverage.uniform(completeDomain)

private func coverage(
    mainOutput: RoutingDomainCoverage = completeDomain,
    association: RoutingDomainCoverage = completeDomain,
    sends: RoutingDomainCoverage = completeDomain
) -> RoutingCoverage {
    RoutingCoverage(
        population: completeDomain,
        stripTrackAssociation: association,
        mainOutput: mainOutput,
        physicalOutput: completeDomain,
        busToAuxInput: completeDomain,
        sends: sends
    )
}

/// Both domains the rule reads complete, `sends` partial: the graph as a whole is partial, so
/// `isConsistent` returns before its duplicate-id check and an id two nodes carry passes the gate.
private let sendsPartialCoverage = coverage(sends: RoutingDomainCoverage(state: .partial, reasons: ["send slots unread"]))

/// A consistent graph for `baselineSnapshotId`. `complete` and `partialReason` follow the coverage
/// the way `publish` derives them, so `isConsistent` holds unless a test breaks it on purpose.
/// `projectReference` is the capture's project unless a test says otherwise; `publish` leaves it
/// nil whenever the capture issued none.
private func graph(
    projectReference: TargetReference? = songReference,
    projectEpoch: UInt64 = 3,
    snapshotId: String = baselineSnapshotId,
    coverage: RoutingCoverage = completeCoverage,
    nodes: [RoutingNode],
    edges: [RoutingEdge]
) -> RoutingGraph {
    let reasons = coverage.domains.filter { $0.state != .complete }.flatMap(\.reasons)
    return RoutingGraph(
        projectReference: projectReference,
        projectEpoch: projectEpoch,
        complete: coverage.isComplete,
        partialReason: coverage.isComplete ? nil : reasons.joined(separator: "; "),
        nodes: nodes,
        edges: edges,
        provenance: [.axMixerStrip],
        snapshotId: snapshotId,
        coverage: coverage
    )
}

/// Kick's main output observed on the drum bus (3): the already-correct case for a bus-3 policy.
private let correctGraph = graph(nodes: [trackNode(0), trackNode(1), drumBus, reverbBus], edges: [mainOutput(from: 0, to: drumBus.id)])
/// Kick's main output observed on the reverb bus (4): the wrong case for a bus-3 policy.
private let wrongGraph = graph(nodes: [trackNode(0), trackNode(1), drumBus, reverbBus], edges: [mainOutput(from: 0, to: reverbBus.id)])

// MARK: - Policy fixtures

private func targetEntry(_ handle: String, _ ref: String) -> Value {
    .object(["handle": .string(handle), "track_ref": .string(ref)])
}

private func memberEntry(_ handle: String, accepted: Bool) -> Value {
    .object(["handle": .string(handle), "accepted": .bool(accepted)])
}

private func roleEntry(_ role: String, members: [Value]) -> Value {
    .object(["role": .string(role), "members": .array(members)])
}

private func targetOutput(_ handle: String, bus: Int) -> Value {
    .object(["target": .string(handle), "bus": .int(bus)])
}

private func targetNoOutput(_ handle: String) -> Value {
    .object(["target": .string(handle), "output": .string("no_output")])
}

private func roleOutput(_ role: String, bus: Int) -> Value {
    .object(["role": .string(role), "bus": .int(bus)])
}

private func policyObject(
    projectRef: String? = nil,
    targets: [Value],
    roles: [Value]? = nil,
    outputs: [Value]? = nil
) -> [String: Value] {
    var object: [String: Value] = ["schema": .string(Audit.intentPolicySchema), "targets": .array(targets)]
    if let projectRef { object["project_ref"] = .string(projectRef) }
    if let roles { object["roles"] = .array(roles) }
    if let outputs { object["outputs"] = .array(outputs) }
    return object
}

private func accepted(_ parse: Audit.IntentPolicyParse) -> Audit.IntentPolicy? {
    if case .accepted(let policy) = parse { return policy }
    return nil
}

private func rejections(_ parse: Audit.IntentPolicyParse) -> [Audit.IntentPolicyRejection]? {
    if case .rejected(let list) = parse { return list }
    return nil
}

/// One exact target `kick` on trk_0 with an approved main output to `bus`.
private func kickPolicy(bus: Int = 3, projectRef: String? = nil) throws -> Audit.IntentPolicy {
    try #require(accepted(Audit.parseIntentPolicy(policyObject(
        projectRef: projectRef,
        targets: [targetEntry("kick", "trk_0")],
        outputs: [targetOutput("kick", bus: bus)]
    ))))
}

private func onlyFinding(_ assessment: Audit.IntentAssessment) throws -> Audit.IntentFinding {
    #expect(assessment.findings.count == 1)
    return try #require(assessment.findings.first)
}

/// One role `kick` whose members `b` (trk_1) and `c` (trk_2) are both unaccepted, and no output
/// naming a target directly.
private func unresolvedRolePolicy(projectRef: String? = nil) throws -> Audit.IntentPolicy {
    try #require(accepted(Audit.parseIntentPolicy(policyObject(
        projectRef: projectRef,
        targets: [targetEntry("b", "trk_1"), targetEntry("c", "trk_2")],
        roles: [roleEntry("kick", members: [memberEntry("b", accepted: false), memberEntry("c", accepted: false)])],
        outputs: [roleOutput("kick", bus: 3)]
    ))))
}

/// `unresolvedRolePolicy` with a third unaccepted member `z` between them, whose `trk_9` no
/// capture here issues: a question offers `b` and `c` only, in that order.
private func unresolvedRolePolicyWithAnUnissuedMember() throws -> Audit.IntentPolicy {
    try #require(accepted(Audit.parseIntentPolicy(policyObject(
        targets: [targetEntry("b", "trk_1"), targetEntry("z", "trk_9"), targetEntry("c", "trk_2")],
        roles: [roleEntry("kick", members: [
            memberEntry("b", accepted: false),
            memberEntry("z", accepted: false),
            memberEntry("c", accepted: false),
        ])],
        outputs: [roleOutput("kick", bus: 3)]
    ))))
}

/// The question a `kick` role on bus 3 asks when its issued members are `b` and `c`.
private let kickQuestionOfferingBAndC = Audit.IntentQuestion(
    id: "role.kick",
    role: "kick",
    rule: "main_output_assignment",
    expected: .expected(.bus(3)),
    candidates: [
        Audit.IntentCandidate(handle: "b", trackRef: "trk_1"),
        Audit.IntentCandidate(handle: "c", trackRef: "trk_2"),
    ]
)

/// A case for one assessment gate: its token, the capture and graph that hit it alone, the policy's
/// `project_ref`, and the status it forces.
private typealias GateCase = (token: String, capture: Observation.Capture, graph: RoutingGraph, projectRef: String?, status: Audit.IntentStatus)

/// Every assessment gate, each hit alone. The graph for an unissued project reference carries none,
/// the way `publish` leaves it.
private func assessmentGateCases() -> [GateCase] {
    let moved = baselineVersions.merging([.mixer: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 3)]) { $1 }
    let inconsistent = RoutingGraph(
        projectReference: songReference,
        projectEpoch: 3,
        complete: true,
        partialReason: nil,
        nodes: correctGraph.nodes,
        edges: correctGraph.edges + [mainOutput(from: 0, to: "nowhere")],
        provenance: [.axMixerStrip],
        snapshotId: baselineSnapshotId,
        coverage: completeCoverage
    )
    let issued = issuedReferences(for: threeTracks)
    return [
        ("cache_moved_during_capture",
         makeCapture(tracks: threeTracks, issued: issued, after: boundary(moved)), correctGraph, nil, .unverified),
        ("graph_not_from_capture",
         threeTrackCapture, graph(snapshotId: "snap_3_t7_m1_p1", nodes: correctGraph.nodes, edges: correctGraph.edges), nil, .unverified),
        ("graph_project_mismatch",
         threeTrackCapture,
         graph(projectReference: TargetReference(rawValue: "prj_other"), nodes: correctGraph.nodes, edges: correctGraph.edges),
         nil, .unverified),
        ("routing_graph_inconsistent", threeTrackCapture, inconsistent, nil, .unverified),
        ("no_document",
         makeCapture(tracks: threeTracks, issued: issued, before: boundary(hasDocument: false)), correctGraph, nil, .unverified),
        ("ax_occluded",
         makeCapture(tracks: threeTracks, issued: issued, before: boundary(axOccluded: true)), correctGraph, nil, .unverified),
        ("project_reference_unavailable",
         makeCapture(tracks: threeTracks, issued: issued, projectIssuance: .unobserved(reason: "no path")),
         graph(projectReference: nil, nodes: correctGraph.nodes, edges: correctGraph.edges), "prj_song", .unverified),
        ("policy_project_mismatch", threeTrackCapture, correctGraph, "prj_other", .outsideScope),
    ]
}

@Suite("Issue966IntentAssessmentTests")
struct Issue966IntentAssessmentTests {
    // MARK: - Policy parsing

    // Mutation: remove the exact-key check (`rejectUnknownKeys`).
    @Test func policyUnknownTopLevelAndNestedKeysReject() throws {
        var object = policyObject(
            targets: [.object(["handle": "kick", "track_ref": "trk_0", "colour": "red"])],
            roles: [.object([
                "role": "drums",
                "members": .array([.object(["handle": "kick", "accepted": true, "why": "loud"])]),
                "note": "n",
            ])],
            outputs: [.object(["target": "kick", "bus": 3, "level": 0])]
        )
        object["requested_scope"] = .string("all")

        let rejected = try #require(rejections(Audit.parseIntentPolicy(object)))

        #expect(rejected.contains(.unknownKey(path: "policy", key: "requested_scope")))
        #expect(rejected.contains(.unknownKey(path: "policy.targets[0]", key: "colour")))
        #expect(rejected.contains(.unknownKey(path: "policy.roles[0]", key: "note")))
        #expect(rejected.contains(.unknownKey(path: "policy.roles[0].members[0]", key: "why")))
        #expect(rejected.contains(.unknownKey(path: "policy.outputs[0]", key: "level")))
        #expect(rejected.count == 5)
    }

    // Mutation: skip the role expansion before conflict detection (read only direct target outputs).
    @Test func policyConflictingOutputsAcrossTargetAndRoleReject() throws {
        let drums = roleEntry("drums", members: [memberEntry("kick", accepted: true), memberEntry("snare", accepted: true)])
        let targets = [targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1")]

        let conflicting = Audit.parseIntentPolicy(policyObject(
            targets: targets,
            roles: [drums],
            outputs: [targetOutput("kick", bus: 3), roleOutput("drums", bus: 4)]
        ))
        let rejected = try #require(rejections(conflicting))
        #expect(rejected == [.conflictingOutputs(subject: "kick", outputs: [.bus(3), .bus(4)])])

        // Positive control: the same handle reached twice with ONE bus is one intent, not a conflict,
        // and the assessment carries one finding per resolved target.
        let agreeing = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: targets,
            roles: [drums],
            outputs: [targetOutput("kick", bus: 3), roleOutput("drums", bus: 3)]
        ))))
        let assessment = Audit.assessIntent(policy: agreeing, capture: threeTrackCapture, graph: correctGraph)
        #expect(assessment.findings.map(\.id) == ["main_output.target.kick", "main_output.target.snare"])
        #expect(assessment.findings.map(\.target.role) == [nil, "drums"])
    }

    // Mutation: drop the duplicate checks (`duplicates(in:)` returns []).
    @Test func policyDuplicateHandleAndDuplicateTrackRefReject() throws {
        let rejected = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0"), targetEntry("kick", "trk_1"), targetEntry("snare", "trk_0")]
        ))))

        #expect(rejected == [.duplicateHandle("kick"), .duplicateTrackRef("trk_0")])
    }

    // Mutation: drop the range check (`bus < 1`).
    @Test func policyBusBelowOneRejects() throws {
        let zero = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0")],
            outputs: [targetOutput("kick", bus: 0)]
        ))))
        #expect(zero == [.busBelowOne(path: "policy.outputs[0].bus", value: 0)])

        let negative = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0")],
            outputs: [targetOutput("kick", bus: -7)]
        ))))
        #expect(negative == [.busBelowOne(path: "policy.outputs[0].bus", value: -7)])

        // Positive control: bus 1 is the lowest bus and is accepted; no upper bound is guessed here.
        let one = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0")],
            outputs: [targetOutput("kick", bus: 1)]
        ))))
        #expect(one.outputs == [Audit.IntentOutput(subject: .target("kick"), destination: .bus(1))])
    }

    // Mutation: drop the both-or-neither check in `parseOutputs`.
    @Test func policyOutputNamingBothOrNeitherRejects() throws {
        let rejected = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0")],
            roles: [roleEntry("drums", members: [memberEntry("kick", accepted: true)])],
            outputs: [
                .object(["target": "kick", "role": "drums", "bus": 3]),
                .object(["bus": 3]),
            ]
        ))))

        #expect(rejected == [
            .outputNamesBothOrNeither(path: "policy.outputs[0]"),
            .outputNamesBothOrNeither(path: "policy.outputs[1]"),
        ])
    }

    // A main output is a bus or `no_output`, exactly one, and `no_output` is the only non-bus value.
    // Mutation: drop the bus-or-output check in `parseDestination`, or accept any `output` string.
    @Test func policyOutputDestinationIsExactlyOneBusOrNoOutput() throws {
        let rejected = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1"), targetEntry("tom", "trk_2")],
            outputs: [
                .object(["target": "kick", "bus": 3, "output": "no_output"]),
                .object(["target": "snare"]),
                .object(["target": "tom", "output": "physical_output"]),
            ]
        ))))
        #expect(rejected == [
            .outputDestinationBothOrNeither(path: "policy.outputs[0]"),
            .outputDestinationBothOrNeither(path: "policy.outputs[1]"),
            .unsupportedOutput(path: "policy.outputs[2].output", value: "physical_output"),
        ])

        // A target named directly with no output and again through a role with a bus is one
        // contradiction, reported with no_output first.
        let conflicting = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0")],
            roles: [roleEntry("drums", members: [memberEntry("kick", accepted: true)])],
            outputs: [targetNoOutput("kick"), roleOutput("drums", bus: 3)]
        ))))
        #expect(conflicting == [.conflictingOutputs(subject: "kick", outputs: [.noOutput, .bus(3)])])

        let silent = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0")],
            outputs: [targetNoOutput("kick")]
        ))))
        #expect(silent.outputs == [Audit.IntentOutput(subject: .target("kick"), destination: .noOutput)])
    }

    // Mutation: drop the `trk_` prefix check.
    @Test func policyNonTrackReferenceRejects() throws {
        let rejected = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "mix_0"), targetEntry("song", "prj_song")]
        ))))

        #expect(rejected == [
            .unsupportedTargetRef(handle: "kick", ref: "mix_0"),
            .unsupportedTargetRef(handle: "song", ref: "prj_song"),
        ])
    }

    // Mutation: drop the `prj_` prefix check on `project_ref`.
    @Test func policyProjectRefMustBeAProjectReference() throws {
        let rejected = try #require(rejections(Audit.parseIntentPolicy(policyObject(
            projectRef: "trk_0",
            targets: [targetEntry("kick", "trk_0")]
        ))))
        #expect(rejected == [.unsupportedProjectRef("trk_0")])

        let named = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            projectRef: "prj_song",
            targets: [targetEntry("kick", "trk_0")]
        ))))
        #expect(named.projectRef == songReference)
    }

    // Positive control for the parser: a well-formed policy is accepted, twice, equal, with its content.
    @Test func policyAcceptedRoundTripsAndIsEquatable() throws {
        let object = policyObject(
            targets: [targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1")],
            roles: [roleEntry("drums", members: [memberEntry("kick", accepted: true), memberEntry("snare", accepted: false)])],
            outputs: [targetOutput("kick", bus: 3), roleOutput("drums", bus: 3)]
        )

        let first = try #require(accepted(Audit.parseIntentPolicy(object)))
        let second = try #require(accepted(Audit.parseIntentPolicy(object)))

        #expect(first == second)
        #expect(first.projectRef == nil)
        #expect(first.targets == [
            Audit.IntentTarget(handle: "kick", trackRef: trackRef(0)),
            Audit.IntentTarget(handle: "snare", trackRef: trackRef(1)),
        ])
        #expect(first.roles == [Audit.IntentRole(role: "drums", members: [
            Audit.IntentRoleMember(handle: "kick", accepted: true),
            Audit.IntentRoleMember(handle: "snare", accepted: false),
        ])])
        #expect(first.outputs == [
            Audit.IntentOutput(subject: .target("kick"), destination: .bus(3)),
            Audit.IntentOutput(subject: .role("drums"), destination: .bus(3)),
        ])

        let minimal = try #require(accepted(Audit.parseIntentPolicy(policyObject(targets: [targetEntry("kick", "trk_0")]))))
        #expect(minimal.roles.isEmpty)
        #expect(minimal.outputs.isEmpty)
    }

    // ADR-021 section 1 / #30 boundary: a creative session plan is not a repair policy and cannot be handed in
    // as one. Mutation: accept any schema string.
    @Test func aCreativeSessionPlanShapedObjectIsNotAPolicy() throws {
        let plan: [String: Value] = [
            "schema": .string(SessionPlanGenerator.schema),
            "prompt": .string("make a lofi beat with a warm kick"),
            "parsed_intent": .object(["genre": "lofi", "key": "C minor"]),
            "track_plan": .array([.object(["name": "Kick", "role": "kick"])]),
        ]

        let rejected = try #require(rejections(Audit.parseIntentPolicy(plan)))

        #expect(rejected.contains(.unsupportedSchema(SessionPlanGenerator.schema)))
        #expect(rejected.contains(.unknownKey(path: "policy", key: "prompt")))
        #expect(rejected.contains(.unknownKey(path: "policy", key: "parsed_intent")))
        #expect(rejected.contains(.unknownKey(path: "policy", key: "track_plan")))
        #expect(rejected.contains(.missingKey(path: "policy", key: "targets")))
    }

    // MARK: - The real path: publish never yields complete today

    // A real StateCache and TargetRegistry, captured with the inert file reader and published by
    // `routingGraph(capture:)`. The strip's own slot reads `Bus 3` and the policy expects bus 3, so
    // every per-target check agrees; only the coverage publish leaves partial stands between this
    // and `compliant`. Mutation: accept partial coverage (drop both domain checks).
    @Test func theRealPathIsUnverifiedWhilePublishLeavesCoveragePartial() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Song", filePath: "/Users/x/Song.logicx"))
            await cache.updateTracks([liveTrack(0, name: "Kick"), liveTrack(1, name: "Bus 3")])
            await cache.updateChannelStrips([ChannelStripState(trackIndex: 0, output: "Bus 3")])
            let registry = TargetRegistry()

            let capture = await Observation.capture(
                cache: cache,
                targetRegistry: registry,
                fileReader: .unavailable,
                now: { fixedNow }
            )
            let routing = Observation.routingGraph(capture: capture)
            let kickRef = try #require(capture.issued?.byTrackIndex[0])
            guard case .issued(let projectRef)? = capture.projectIssuance else {
                Issue.record("the capture issued no project reference")
                return
            }
            #expect(routing.snapshotId == Observation.snapshotID(for: capture))
            #expect(routing.isConsistent)
            #expect(routing.coverage.mainOutput.state == .partial)
            #expect(routing.coverage.stripTrackAssociation.state == .partial)

            let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
                projectRef: projectRef.rawValue,
                targets: [targetEntry("kick", kickRef.rawValue)],
                outputs: [targetOutput("kick", bus: 3)]
            ))))
            let finding = try onlyFinding(Audit.assessIntent(policy: policy, capture: capture, graph: routing))

            #expect(finding.status == .unverified)
            #expect(finding.reasons == [.mainOutputCoverageIncomplete, .stripTrackAssociationIncomplete])
            #expect(finding.coverage.mainOutput.reasons.contains(RoutingGraphPublication.busIdentityReason))
            #expect(finding.coverage.mainOutput == routing.coverage.mainOutput)
            #expect(finding.coverage.stripTrackAssociation == routing.coverage.stripTrackAssociation)
            // The observation itself is carried as evidence: the graph did see bus 3.
            #expect(finding.observed?.busNumber == 3)
            #expect(finding.observed?.output == .bus)
        }
    }

    // MARK: - The main-output rule on complete graphs

    // Mutation: read the bus from the destination node id instead of `busNumber`.
    @Test func wrongBusAssignmentIsAViolationWithObservedAndExpected() throws {
        let assessment = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: wrongGraph)
        let finding = try onlyFinding(assessment)

        #expect(finding.id == "main_output.target.kick")
        #expect(finding.rule == "main_output_assignment")
        #expect(finding.status == .violation)
        #expect(finding.severity == .warn)
        #expect(finding.basis == .approvedPolicy)
        #expect(finding.target == Audit.IntentTargetEvidence(handle: "kick", role: nil, trackRef: "trk_0", trackIndex: 0))
        let observed = try #require(finding.observed)
        #expect(observed.nodeId == "aux_reverb")
        #expect(observed.busNumber == 4)
        #expect(observed.output == .bus)
        #expect(finding.expected == Audit.IntentEndpoint(nodeId: nil, displayName: nil, busNumber: 3, output: .bus))
        #expect(finding.coverage.outputEdgeObserved)
        #expect(finding.coverage.destinationBusObserved)
        let expectedBusObserved = try #require(finding.coverage.expectedBusObserved)
        #expect(expectedBusObserved)
        #expect(finding.coverage.graphComplete)
        #expect(finding.reasons.isEmpty)
        #expect(assessment.changeRequired)
        #expect(assessment.questions.isEmpty)
        #expect(assessment.findings.filter { $0.status == .violation }.count == 1)
    }

    // When the expected bus is nowhere in the graph the violation says so. Mutation: never add the reason.
    @Test func wrongBusAssignmentToAnUnobservedBusNamesThatToo() throws {
        let assessment = Audit.assessIntent(policy: try kickPolicy(bus: 9), capture: threeTrackCapture, graph: wrongGraph)
        let finding = try onlyFinding(assessment)

        #expect(finding.status == .violation)
        #expect(finding.reasons == [.expectedBusNotObserved])
        let expectedBusObserved = try #require(finding.coverage.expectedBusObserved)
        #expect(!expectedBusObserved)
        #expect(assessment.changeRequired)
    }

    // Mutation: invert the status of the equal-bus branch.
    @Test func correctAssignmentIsCompliantAndRequiresNoChange() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            projectRef: "prj_song",
            targets: [targetEntry("kick", "trk_0")],
            outputs: [targetOutput("kick", bus: 3)]
        ))))
        let assessment = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: correctGraph)
        let finding = try onlyFinding(assessment)

        #expect(finding.status == .compliant)
        #expect(finding.severity == .info)
        #expect(finding.basis == .approvedPolicy)
        let observed = try #require(finding.observed)
        #expect(observed.nodeId == "aux_drum_bus")
        #expect(observed.busNumber == 3)
        #expect(finding.expected.busNumber == 3)
        #expect(finding.coverage.outputEdgeObserved)
        #expect(finding.coverage.destinationBusObserved)
        let expectedBusObserved = try #require(finding.coverage.expectedBusObserved)
        #expect(expectedBusObserved)
        #expect(finding.reasons.isEmpty)
        #expect(!assessment.changeRequired)
        #expect(assessment.findings.allSatisfy { $0.status != .violation })
        #expect(assessment.questions.isEmpty)
    }

    // A source classified as a bus with no `mainOutput` edge, two edges, or an edge to a node that
    // carries no bus number does not say where its output goes. Mutation: treat a missing edge as a
    // violation, or take the first of several edges.
    @Test func aBusSourceWithoutExactlyOneBusEdgeIsUnverified() throws {
        let trackDestination = trackNode(1, name: "Drum Bus")
        let cases: [(RoutingGraph, Bool)] = [
            (graph(nodes: [trackNode(0), drumBus], edges: []), false),
            (graph(nodes: [trackNode(0), drumBus, reverbBus],
                   edges: [mainOutput(from: 0, to: drumBus.id), mainOutput(from: 0, to: reverbBus.id)]), true),
            (graph(nodes: [trackNode(0), trackDestination], edges: [mainOutput(from: 0, to: trackDestination.id)]), true),
        ]
        for (routing, edgeObserved) in cases {
            let assessment = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing)
            let finding = try onlyFinding(assessment)

            #expect(finding.status == .unverified)
            #expect(finding.severity == .info)
            #expect(finding.reasons == [.outputEdgeAmbiguous])
            #expect(finding.observed == nil)
            #expect(finding.target.trackIndex == 0)
            #expect(finding.coverage.outputEdgeObserved == edgeObserved)
            #expect(!finding.coverage.destinationBusObserved)
            #expect(!assessment.changeRequired)
        }
    }

    // An output the graph did not classify is not evidence of any route. Mutation: treat a nil or
    // `unclassified` classification as `no_output`.
    @Test func anUnclassifiedOutputIsUnverified() throws {
        for output in [nil, RoutingOutputClassification.unclassified] {
            let routing = graph(nodes: [trackNode(0, output: output), drumBus], edges: [])
            let bus = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing)
            let silent = try #require(accepted(Audit.parseIntentPolicy(policyObject(
                targets: [targetEntry("kick", "trk_0")],
                outputs: [targetNoOutput("kick")]
            ))))
            let none = Audit.assessIntent(policy: silent, capture: threeTrackCapture, graph: routing)

            #expect(try onlyFinding(bus).reasons == [.outputUnclassified])
            #expect(try onlyFinding(bus).status == .unverified)
            #expect(try onlyFinding(none).reasons == [.outputUnclassified])
            #expect(try onlyFinding(none).status == .unverified)
        }
    }

    // Intentional silence is an intent: expected no_output and observed no_output is compliant, a bus
    // expected where the strip has no output is a violation, and a no-output track the policy does
    // not name produces nothing. Mutation: treat an observed no_output as unverified.
    @Test func noOutputIsAnIntentTheRuleCanConfirmOrContradict() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1"), targetEntry("tom", "trk_2")],
            outputs: [targetNoOutput("kick"), targetOutput("snare", bus: 3), targetNoOutput("tom")]
        ))))
        let routing = graph(
            nodes: [
                trackNode(0, output: .noOutput),
                trackNode(1, output: .noOutput),
                trackNode(2, output: .bus),
                trackNode(3, output: .noOutput),
                drumBus,
            ],
            edges: [mainOutput(from: 2, to: drumBus.id)]
        )

        let assessment = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: routing)

        #expect(assessment.findings.map(\.id) == [
            "main_output.target.kick", "main_output.target.snare", "main_output.target.tom",
        ])
        #expect(assessment.findings.map(\.status) == [.compliant, .violation, .violation])
        let kick = assessment.findings[0]
        #expect(kick.expected == Audit.IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .noOutput))
        #expect(kick.observed == Audit.IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .noOutput))
        #expect(kick.coverage.expectedBusObserved == nil)
        #expect(!kick.coverage.outputEdgeObserved)
        let snare = assessment.findings[1]
        #expect(snare.observed?.output == .noOutput)
        #expect(snare.reasons.isEmpty)
        let tom = assessment.findings[2]
        #expect(tom.observed?.busNumber == 3)
        #expect(assessment.changeRequired)
    }

    // A physical output where a bus is expected is a route the graph did classify, and it is not the
    // bus. Mutation: treat an observed physical output as unverified.
    @Test func aPhysicalOutputWhereABusIsExpectedIsAViolation() throws {
        let routing = graph(nodes: [trackNode(0, output: .physicalOutput), drumBus], edges: [])
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

        #expect(finding.status == .violation)
        #expect(finding.observed == Audit.IntentEndpoint(nodeId: nil, displayName: nil, busNumber: nil, output: .physicalOutput))
    }

    // A track named "Bus 3" that outputs to bus 4, beside a real bus 3 and another track named "Bus 3"
    // on it: identity is the reference, never the name. Mutation: key the source by displayName.
    @Test func identicalNamesAreDecidedByReference() throws {
        let namedLikeABus = [liveTrack(0, name: "Bus 3"), liveTrack(1, name: "Bus 3")]
        let capture = makeCapture(tracks: namedLikeABus, issued: issuedReferences(for: namedLikeABus))
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("a", "trk_0"), targetEntry("b", "trk_1")],
            outputs: [targetOutput("a", bus: 3), targetOutput("b", bus: 3)]
        ))))
        let routing = graph(
            nodes: [trackNode(0, name: "Bus 3"), trackNode(1, name: "Bus 3"), busNode(3, id: "aux_x"), busNode(4, id: "aux_y")],
            edges: [mainOutput(from: 0, to: "aux_y"), mainOutput(from: 1, to: "aux_x")]
        )

        let assessment = Audit.assessIntent(policy: policy, capture: capture, graph: routing)

        #expect(assessment.findings.map(\.status) == [.violation, .compliant])
        #expect(assessment.findings[0].observed?.nodeId == "aux_y")
        #expect(assessment.findings[1].observed?.nodeId == "aux_x")
    }

    // Two nodes carrying one reference cannot both be its source. Mutation: take the first.
    @Test func twoNodesWithOneReferenceAreAmbiguous() throws {
        let twin = RoutingNode(id: "strip_0b", kind: .track, displayName: "Kick", busNumber: nil,
                               targetRef: trackRef(0), outputClassification: .bus)
        let routing = graph(nodes: [trackNode(0), twin, drumBus], edges: [mainOutput(from: 0, to: drumBus.id)])
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.sourceNodeAmbiguous])
    }

    // `sends` partial is enough for `isConsistent` to skip its duplicate-id check, so two destination
    // nodes sharing one id, on buses 3 and 4, reach the rule. Node order must not pick the verdict,
    // and the same graph with unique ids still decides. Mutation: resolve the destination with
    // `first(where:)` in `observeMainOutput`.
    @Test func aDestinationIdTwoNodesCarryIsUnverifiedInEitherOrder() throws {
        let onThree = busNode(3, id: "aux_shared")
        let onFour = busNode(4, id: "aux_shared")
        for destinations in [[onThree, onFour], [onFour, onThree]] {
            let order = destinations.compactMap(\.busNumber).map(String.init).joined(separator: ",")
            let routing = graph(
                coverage: sendsPartialCoverage,
                nodes: [trackNode(0)] + destinations,
                edges: [mainOutput(from: 0, to: "aux_shared")]
            )
            #expect(routing.isConsistent, "\(order)")
            let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

            #expect(finding.status == .unverified, "\(order)")
            #expect(finding.reasons.map(\.rawValue) == ["output_destination_ambiguous"], "\(order)")
            #expect(finding.observed == nil, "\(order)")
            #expect(finding.coverage.outputEdgeObserved, "\(order)")
            #expect(!finding.coverage.destinationBusObserved, "\(order)")
        }

        // Positive control: unique ids, the capture's project, the same partial `sends`.
        let toThree = graph(coverage: sendsPartialCoverage, nodes: [trackNode(0), drumBus, reverbBus], edges: [mainOutput(from: 0, to: drumBus.id)])
        let toFour = graph(coverage: sendsPartialCoverage, nodes: [trackNode(0), drumBus, reverbBus], edges: [mainOutput(from: 0, to: reverbBus.id)])
        #expect(try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: toThree)).status == .compliant)
        #expect(try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: toFour)).status == .violation)
    }

    // The source's edges are found by its id, so an id another node also carries cannot say whose
    // edge it is. Mutation: drop the source-id check in `observeMainOutput`.
    @Test func aSourceIdAnotherNodeCarriesIsAmbiguous() throws {
        let routing = graph(
            coverage: sendsPartialCoverage,
            nodes: [trackNode(0), auxNode("trk_0"), drumBus],
            edges: [mainOutput(from: 0, to: drumBus.id)]
        )
        #expect(routing.isConsistent)
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.sourceNodeAmbiguous])
        #expect(finding.observed == nil)
    }

    // Two nodes on one bus number: the number the verdict compares names no single destination.
    // Mutation: drop the bus-number check in `observeMainOutput`.
    @Test func aBusNumberTwoNodesCarryIsUnverified() throws {
        let routing = graph(
            nodes: [trackNode(0), drumBus, busNode(3, id: "aux_other")],
            edges: [mainOutput(from: 0, to: drumBus.id)]
        )
        #expect(routing.isConsistent)
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

        #expect(finding.status == .unverified)
        #expect(finding.reasons.map(\.rawValue) == ["output_destination_ambiguous"])
        #expect(finding.observed == nil)
        #expect(finding.coverage.outputEdgeObserved)
    }

    // A reference the capture carries for two rows cannot say which row is the target. Mutation: take
    // the lowest track index that carries it.
    @Test func aReferenceTwoCapturedRowsCarryIsUnverified() throws {
        let doubled = IssuedTrackReferences(
            byRow: [trackRef(0), trackRef(0), trackRef(2)],
            byTrackIndex: [0: trackRef(0), 1: trackRef(0), 2: trackRef(2)],
            ambiguousTrackIndices: []
        )
        let capture = makeCapture(tracks: threeTracks, issued: doubled)
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: capture, graph: correctGraph))

        #expect(finding.status == .unverified)
        #expect(finding.reasons.map(\.rawValue) == ["target_ambiguous_in_snapshot"])
        #expect(finding.target.trackIndex == nil)
        #expect(finding.observed == nil)
    }

    // A role with no accepted member is a question whose candidates are the proposed ones only. The
    // capture's track named "Kick" is not among them and must not appear. Mutation: derive candidates
    // from track names.
    @Test func unacceptedRoleIsAQuestionWithOnlyProposedCandidates() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("a", "trk_0"), targetEntry("b", "trk_1"), targetEntry("c", "trk_2")],
            roles: [roleEntry("kick", members: [memberEntry("b", accepted: false), memberEntry("c", accepted: false)])],
            outputs: [roleOutput("kick", bus: 3)]
        ))))
        // threeTrackCapture row 0 is the track named "Kick"; handle `a` (trk_0) is deliberately not a member.

        let assessment = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: correctGraph)
        let finding = try onlyFinding(assessment)

        #expect(finding.id == "main_output.role.kick")
        #expect(finding.status == .needsInput)
        #expect(finding.severity == .info)
        #expect(finding.target == Audit.IntentTargetEvidence(handle: nil, role: "kick", trackRef: nil, trackIndex: nil))
        #expect(finding.observed == nil)
        #expect(finding.expected.busNumber == 3)
        #expect(finding.reasons == [.roleHasNoAcceptedMember])
        #expect(assessment.questions == [Audit.IntentQuestion(
            id: "role.kick",
            role: "kick",
            rule: "main_output_assignment",
            expected: .expected(.bus(3)),
            candidates: [
                Audit.IntentCandidate(handle: "b", trackRef: "trk_1"),
                Audit.IntentCandidate(handle: "c", trackRef: "trk_2"),
            ]
        )])
        #expect(!assessment.questions[0].candidates.contains { $0.trackRef == "trk_0" })
        #expect(!assessment.changeRequired)
    }

    // A role with no accepted member is a question only while the gate is open. Asked about another
    // project, or over a graph that cannot be read against this capture, it would be answered for the
    // wrong project; the role's finding carries the gate's status and token instead. Mutation: emit
    // the role's `needs_input` finding and question before the gate is consulted.
    @Test func anUnresolvedRoleIsGatedLikeADirectTarget() throws {
        for (token, capture, routing, projectRef, status) in assessmentGateCases() {
            let assessment = Audit.assessIntent(
                policy: try unresolvedRolePolicy(projectRef: projectRef),
                capture: capture,
                graph: routing
            )
            let finding = try onlyFinding(assessment)

            #expect(finding.id == "main_output.role.kick", "\(token)")
            #expect(finding.status == status, "\(token)")
            #expect(finding.reasons.map(\.rawValue) == [token])
            #expect(finding.target == Audit.IntentTargetEvidence(handle: nil, role: "kick", trackRef: nil, trackIndex: nil), "\(token)")
            #expect(finding.observed == nil, "\(token)")
            #expect(assessment.questions.isEmpty, "\(token)")
            #expect(!assessment.changeRequired, "\(token)")
        }

        // Positive control: with the gate open the same policy asks, and the candidates are exactly
        // the proposed members.
        let open = Audit.assessIntent(policy: try unresolvedRolePolicy(projectRef: "prj_song"), capture: threeTrackCapture, graph: correctGraph)
        let finding = try onlyFinding(open)
        #expect(finding.status == .needsInput)
        #expect(finding.reasons == [.roleHasNoAcceptedMember])
        #expect(open.questions.map(\.id) == ["role.kick"])
        #expect(open.questions.first?.candidates == [
            Audit.IntentCandidate(handle: "b", trackRef: "trk_1"),
            Audit.IntentCandidate(handle: "c", trackRef: "trk_2"),
        ])
    }

    // A role's candidates carry the policy's references. While the capture's own references are off
    // or stale, a question could name a track this capture does not have, so the role reads the
    // per-target check a direct target reads: `unverified` with that check's token, and nothing
    // asked. Mutation: skip that check in the role branch.
    @Test func anUnresolvedRoleIsUnverifiedWhileTrackReferencesAreOffOrStale() throws {
        // With references off `publish` binds no project, so the graph carries none either.
        let unbound = graph(projectReference: nil, nodes: correctGraph.nodes, edges: correctGraph.edges)
        let cases: [(token: String, capture: Observation.Capture, graph: RoutingGraph)] = [
            ("references_unavailable", makeCapture(tracks: threeTracks, issued: nil), unbound),
            ("target_snapshot_stale", makeCapture(tracks: threeTracks, issued: nil, referencesEnabled: true), correctGraph),
        ]
        for (token, capture, routing) in cases {
            let assessment = Audit.assessIntent(policy: try unresolvedRolePolicy(), capture: capture, graph: routing)
            let finding = try onlyFinding(assessment)

            #expect(finding.id == "main_output.role.kick", "\(token)")
            #expect(finding.status == .unverified, "\(token)")
            #expect(finding.reasons.map(\.rawValue) == [token])
            #expect(finding.target == Audit.IntentTargetEvidence(handle: nil, role: "kick", trackRef: nil, trackIndex: nil), "\(token)")
            #expect(finding.observed == nil, "\(token)")
            #expect(assessment.questions.isEmpty, "\(token)")
            #expect(!assessment.changeRequired, "\(token)")

            // The same capture and graph give a direct target the same status and token.
            let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: capture, graph: routing))
            #expect(direct.status == .unverified, "\(token)")
            #expect(direct.reasons.map(\.rawValue) == [token])
        }

        // Positive control: with references on and current the same policy asks, and the candidates
        // are exactly the proposed members.
        let open = Audit.assessIntent(policy: try unresolvedRolePolicy(), capture: threeTrackCapture, graph: correctGraph)
        let finding = try onlyFinding(open)
        #expect(finding.status == .needsInput)
        #expect(finding.reasons == [.roleHasNoAcceptedMember])
        #expect(open.questions.map(\.id) == ["role.kick"])
        #expect(open.questions.first?.candidates == [
            Audit.IntentCandidate(handle: "b", trackRef: "trk_1"),
            Audit.IntentCandidate(handle: "c", trackRef: "trk_2"),
        ])
    }

    // A role's candidates carry the policy's references, so each is looked up in the capture the way
    // a direct target is. The reviewer's trk_9 is not in the three-track capture: alone, the role gets
    // the direct target's status and token and nothing is asked; beside an issued track, only the
    // issued one is offered. Mutation: offer every unaccepted member without looking it up.
    @Test func aRoleOffersOnlyCandidatesTheCaptureIssued() throws {
        let absentOnly = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("ghost", "trk_9")],
            roles: [roleEntry("kick", members: [memberEntry("ghost", accepted: false)])],
            outputs: [roleOutput("kick", bus: 3)]
        ))))
        let absent = Audit.assessIntent(policy: absentOnly, capture: threeTrackCapture, graph: correctGraph)
        let absentFinding = try onlyFinding(absent)
        #expect(absentFinding.id == "main_output.role.kick")
        #expect(absentFinding.status == .outsideScope)
        #expect(absentFinding.reasons == [.targetNotInSnapshot])
        #expect(absentFinding.target == Audit.IntentTargetEvidence(handle: nil, role: "kick", trackRef: nil, trackIndex: nil))
        #expect(absentFinding.observed == nil)
        #expect(absent.questions.isEmpty)
        #expect(!absent.changeRequired)

        // trk_9 named as a direct target, against the same capture and graph.
        let ghostTarget = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("ghost", "trk_9")],
            outputs: [targetOutput("ghost", bus: 3)]
        ))))
        let direct = try onlyFinding(Audit.assessIntent(policy: ghostTarget, capture: threeTrackCapture, graph: correctGraph))
        #expect(direct.status == .outsideScope)
        #expect(direct.reasons == [.targetNotInSnapshot])

        let mixedRole = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("ghost", "trk_9"), targetEntry("b", "trk_1")],
            roles: [roleEntry("kick", members: [memberEntry("ghost", accepted: false), memberEntry("b", accepted: false)])],
            outputs: [roleOutput("kick", bus: 3)]
        ))))
        let mixed = Audit.assessIntent(policy: mixedRole, capture: threeTrackCapture, graph: correctGraph)
        let mixedFinding = try onlyFinding(mixed)
        #expect(mixedFinding.status == .needsInput)
        #expect(mixedFinding.reasons == [.roleHasNoAcceptedMember])
        #expect(mixed.questions == [Audit.IntentQuestion(
            id: "role.kick",
            role: "kick",
            rule: "main_output_assignment",
            expected: .expected(.bus(3)),
            candidates: [Audit.IntentCandidate(handle: "b", trackRef: "trk_1")]
        )])
    }

    // A reference the capture carries for two rows names no one track, so a direct target with it is
    // unverified, and as a candidate it is dropped too. When every candidate is dropped, the role is
    // `outside_scope` only if every dropped one was. Mutation: drop only the candidates the capture
    // did not issue at all (killed by the first two cases); take the first dropped candidate's status
    // for the role (killed by the third).
    @Test func aRoleDropsACandidateTheCaptureCarriesForTwoRows() throws {
        let doubled = IssuedTrackReferences(
            byRow: [trackRef(0), trackRef(0), trackRef(2)],
            byTrackIndex: [0: trackRef(0), 1: trackRef(0), 2: trackRef(2)],
            ambiguousTrackIndices: []
        )
        let capture = makeCapture(tracks: threeTracks, issued: doubled)
        func rolePolicy(_ members: [(handle: String, ref: String)]) throws -> Audit.IntentPolicy {
            try #require(accepted(Audit.parseIntentPolicy(policyObject(
                targets: members.map { targetEntry($0.handle, $0.ref) },
                roles: [roleEntry("kick", members: members.map { memberEntry($0.handle, accepted: false) })],
                outputs: [roleOutput("kick", bus: 3)]
            ))))
        }

        let beside = Audit.assessIntent(
            policy: try rolePolicy([("a", "trk_0"), ("c", "trk_2")]),
            capture: capture,
            graph: correctGraph
        )
        #expect(try onlyFinding(beside).status == .needsInput)
        #expect(beside.questions.first?.candidates == [Audit.IntentCandidate(handle: "c", trackRef: "trk_2")])

        let alone = Audit.assessIntent(policy: try rolePolicy([("a", "trk_0")]), capture: capture, graph: correctGraph)
        let aloneFinding = try onlyFinding(alone)
        #expect(aloneFinding.status == .unverified)
        #expect(aloneFinding.reasons == [.targetAmbiguousInSnapshot])
        #expect(alone.questions.isEmpty)
        let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: capture, graph: correctGraph))
        #expect(direct.status == .unverified)
        #expect(direct.reasons == [.targetAmbiguousInSnapshot])

        let neither = Audit.assessIntent(
            policy: try rolePolicy([("ghost", "trk_9"), ("a", "trk_0")]),
            capture: capture,
            graph: correctGraph
        )
        let neitherFinding = try onlyFinding(neither)
        #expect(neitherFinding.status == .unverified)
        #expect(neitherFinding.reasons == [.targetNotInSnapshot, .targetAmbiguousInSnapshot])
        #expect(neither.questions.isEmpty)
    }

    // Track references are issued before the project reference, so a capture can hold issued tracks
    // while its project reference went stale. `routingGraph(capture:)` publishes that capture with
    // every domain `unstable` and no project reference, so with no policy `project_ref` the gate
    // stays open. A direct target stops at the domain coverage, and the role reads the same check:
    // nothing is asked. Mutation: skip the domain-coverage check in the role branch.
    @Test func aStaleProjectReferenceStopsARoleWhereItStopsADirectTarget() throws {
        let issued = issuedReferences(for: threeTracks)
        let stale = makeCapture(tracks: threeTracks, issued: issued, projectIssuance: .stale)
        let routing = Observation.routingGraph(capture: stale)
        #expect(stale.issued != nil)
        #expect(routing.projectReference == nil)
        #expect(routing.isConsistent)
        #expect(routing.coverage.domains.allSatisfy { $0.state == .unstable })
        #expect(routing.coverage.mainOutput.reasons == [RoutingGraphPublication.projectMovedReason])

        let assessment = Audit.assessIntent(policy: try unresolvedRolePolicy(), capture: stale, graph: routing)
        let finding = try onlyFinding(assessment)
        #expect(finding.id == "main_output.role.kick")
        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.mainOutputCoverageIncomplete, .stripTrackAssociationIncomplete])
        #expect(finding.coverage.mainOutput == routing.coverage.mainOutput)
        #expect(finding.observed == nil)
        #expect(assessment.questions.isEmpty)
        #expect(!assessment.changeRequired)

        // A direct target in the same capture: the same two tokens, then its own node's, which the
        // empty graph does not have.
        let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: stale, graph: routing))
        #expect(direct.status == .unverified)
        #expect(direct.reasons == [.mainOutputCoverageIncomplete, .stripTrackAssociationIncomplete, .trackNotInGraph])

        // Fresh-issuance control: the same tracks with the project reference issued, over a graph
        // whose two domains are complete, ask, with candidates exactly the proposed members.
        let fresh = makeCapture(tracks: threeTracks, issued: issued, projectIssuance: .issued(songReference))
        let open = Audit.assessIntent(policy: try unresolvedRolePolicy(), capture: fresh, graph: correctGraph)
        #expect(try onlyFinding(open).status == .needsInput)
        #expect(open.questions.first?.candidates == [
            Audit.IntentCandidate(handle: "b", trackRef: "trk_1"),
            Audit.IntentCandidate(handle: "c", trackRef: "trk_2"),
        ])
    }

    // A direct target's verdict is about routing, so it is unverified while either domain is short
    // of complete. A role's question asks which captured track fills the role, which a `partial`
    // domain does not put in doubt, so the role asks there, offering only the members the capture
    // issued. An `unstable` domain means the capture moved under its own read, and there the role
    // stops as a direct target does. A `main_output` that is `unstable` publishes no edge of its own,
    // so that graph has none. Mutations: let a `partial` domain stop the role; let an `unstable` one
    // not stop it.
    @Test func aRoleAsksWhileADomainIsPartialButNotWhileOneIsUnstable() throws {
        let partialMainOutput = RoutingDomainCoverage(state: .partial, reasons: [RoutingGraphPublication.busIdentityReason])
        let partialAssociation = RoutingDomainCoverage(state: .partial, reasons: [RoutingGraphPublication.positionalAssociationReason])
        let unstable = RoutingDomainCoverage(state: .unstable, reasons: [RoutingGraphPublication.projectMovedReason])
        let asks: [(label: String, graph: RoutingGraph, directReasons: [Audit.IntentReason])] = [
            ("main_output partial",
             graph(coverage: coverage(mainOutput: partialMainOutput), nodes: wrongGraph.nodes, edges: wrongGraph.edges),
             [.mainOutputCoverageIncomplete]),
            ("strip_track_association partial",
             graph(coverage: coverage(association: partialAssociation), nodes: wrongGraph.nodes, edges: wrongGraph.edges),
             [.stripTrackAssociationIncomplete]),
            ("both partial",
             graph(coverage: coverage(mainOutput: partialMainOutput, association: partialAssociation), nodes: wrongGraph.nodes, edges: wrongGraph.edges),
             [.mainOutputCoverageIncomplete, .stripTrackAssociationIncomplete]),
        ]
        for (label, routing, directReasons) in asks {
            #expect(routing.isConsistent, "\(label)")
            let assessment = Audit.assessIntent(policy: try unresolvedRolePolicyWithAnUnissuedMember(), capture: threeTrackCapture, graph: routing)
            let finding = try onlyFinding(assessment)
            #expect(finding.status == .needsInput, "\(label)")
            #expect(finding.reasons == [.roleHasNoAcceptedMember], "\(label)")
            #expect(assessment.questions == [kickQuestionOfferingBAndC], "\(label)")

            let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))
            #expect(direct.status == .unverified, "\(label)")
            #expect(direct.reasons == directReasons, "\(label)")
        }

        let stops: [(label: String, graph: RoutingGraph, reasons: [Audit.IntentReason], directReasons: [Audit.IntentReason])] = [
            ("main_output unstable",
             graph(coverage: coverage(mainOutput: unstable), nodes: wrongGraph.nodes, edges: []),
             [.mainOutputCoverageIncomplete], [.mainOutputCoverageIncomplete, .outputEdgeAmbiguous]),
            ("strip_track_association unstable",
             graph(coverage: coverage(association: unstable), nodes: wrongGraph.nodes, edges: wrongGraph.edges),
             [.stripTrackAssociationIncomplete], [.stripTrackAssociationIncomplete]),
            ("strip_track_association unstable, main_output partial",
             graph(coverage: coverage(mainOutput: partialMainOutput, association: unstable), nodes: wrongGraph.nodes, edges: wrongGraph.edges),
             [.stripTrackAssociationIncomplete], [.mainOutputCoverageIncomplete, .stripTrackAssociationIncomplete]),
        ]
        for (label, routing, reasons, directReasons) in stops {
            #expect(routing.isConsistent, "\(label)")
            let assessment = Audit.assessIntent(policy: try unresolvedRolePolicyWithAnUnissuedMember(), capture: threeTrackCapture, graph: routing)
            let finding = try onlyFinding(assessment)
            #expect(finding.status == .unverified, "\(label)")
            #expect(finding.reasons == reasons, "\(label)")
            #expect(assessment.questions.isEmpty, "\(label)")

            let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))
            #expect(direct.status == .unverified, "\(label)")
            #expect(direct.reasons == directReasons, "\(label)")
        }
    }

    // REMEDIATION-01's witness: a fresh capture published through `routingGraph(capture:)`, which
    // leaves both domains the rule reads `partial` as every real read does today. The direct target
    // stops at the coverage; the role asks, and offers only the members the capture issued.
    // Mutation: let a `partial` domain stop the role.
    @Test func aRoleAsksOnAFreshCaptureWhosePublishedDomainsArePartial() throws {
        let routing = Observation.routingGraph(capture: threeTrackCapture)
        #expect(routing.isConsistent)
        #expect(routing.projectReference == songReference)
        #expect(routing.coverage.mainOutput.state == .partial)
        #expect(routing.coverage.stripTrackAssociation.state == .partial)

        let assessment = Audit.assessIntent(policy: try unresolvedRolePolicyWithAnUnissuedMember(), capture: threeTrackCapture, graph: routing)
        let finding = try onlyFinding(assessment)
        #expect(finding.id == "main_output.role.kick")
        #expect(finding.status == .needsInput)
        #expect(finding.reasons == [.roleHasNoAcceptedMember])
        #expect(finding.coverage.mainOutput == routing.coverage.mainOutput)
        #expect(assessment.questions == [kickQuestionOfferingBAndC])
        #expect(!assessment.changeRequired)

        let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))
        #expect(direct.status == .unverified)
        #expect(direct.reasons == [.mainOutputCoverageIncomplete, .stripTrackAssociationIncomplete, .trackNotInGraph])
    }

    // A graph stamped with another registry epoch cannot be read against this capture, for a direct
    // target or a role. Mutation: skip the epoch check in the role branch.
    @Test func anUnresolvedRoleIsUnverifiedOnAGraphOfAnotherEpoch() throws {
        let moved = graph(projectEpoch: 4, nodes: correctGraph.nodes, edges: correctGraph.edges)
        let assessment = Audit.assessIntent(policy: try unresolvedRolePolicy(), capture: threeTrackCapture, graph: moved)
        let finding = try onlyFinding(assessment)
        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.graphEpochMismatch])
        #expect(assessment.questions.isEmpty)

        let direct = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: moved))
        #expect(direct.status == .unverified)
        #expect(direct.reasons == [.graphEpochMismatch])
    }

    // Mutation: collapse the references-unavailable and target-not-in-snapshot branches into one.
    @Test func targetOutsideTheSnapshotIsOutsideScope() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("ghost", "trk_9")],
            outputs: [targetOutput("ghost", bus: 3)]
        ))))
        let assessment = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: correctGraph)
        let finding = try onlyFinding(assessment)

        #expect(finding.status == .outsideScope)
        #expect(finding.reasons == [.targetNotInSnapshot])
        #expect(finding.target == Audit.IntentTargetEvidence(handle: "ghost", role: nil, trackRef: "trk_9", trackIndex: nil))
        #expect(finding.observed == nil)
        #expect(!assessment.changeRequired)
    }

    // Mutation: collapse the references-unavailable and target-not-in-snapshot branches into one.
    @Test func referencesUnavailableIsUnverifiedNotOutsideScope() throws {
        let noReferences = makeCapture(tracks: threeTracks, issued: nil)
        // With references off `publish` binds no project, so the graph carries none either.
        let unbound = graph(projectReference: nil, nodes: correctGraph.nodes, edges: correctGraph.edges)
        let assessment = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: noReferences, graph: unbound)
        let finding = try onlyFinding(assessment)

        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.referencesUnavailable])
        #expect(finding.target.trackIndex == nil)
        #expect(finding.observed == nil)
        #expect(!assessment.changeRequired)
    }

    // Many sources on one bus and many receivers of it are no finding of their own and move no
    // target's status; the finding count is the output count. Mutation: count sources or receivers
    // on the destination.
    @Test func twoSourcesAndTwoReceiversOnOneBusMakeNoFanFinding() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1")],
            outputs: [targetOutput("kick", bus: 3), targetOutput("snare", bus: 3)]
        ))))
        let minimal = graph(
            nodes: [trackNode(0), trackNode(1), drumBus],
            edges: [mainOutput(from: 0, to: drumBus.id), mainOutput(from: 1, to: drumBus.id)]
        )
        let receiverA = auxNode("aux_a")
        let receiverB = auxNode("aux_b")
        let enlarged = graph(
            nodes: [trackNode(0), trackNode(1), trackNode(2), drumBus, reverbBus, receiverA, receiverB],
            edges: [
                mainOutput(from: 0, to: drumBus.id),
                mainOutput(from: 1, to: drumBus.id),
                mainOutput(from: 2, to: drumBus.id),
                inputAssignment(from: drumBus, to: receiverA),
                inputAssignment(from: drumBus, to: receiverB),
            ]
        )
        #expect(enlarged.isConsistent)

        let onMinimal = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: minimal)
        let onEnlarged = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: enlarged)

        #expect(onMinimal == onEnlarged)
        #expect(onMinimal.findings.count == policy.outputs.count)
        #expect(onMinimal.findings.map(\.status) == [.compliant, .compliant])
        #expect(!onMinimal.changeRequired)
    }

    // ADR-021 section 4 P1: a send edge, an enabled flag, a send level, minus infinity or an automation state
    // is neither a route nor proof a connection is absent. Mutation: read `.send` edges as main
    // outputs, or read `SendEdge.enabled` / `level` / `automationMode`.
    @Test func aSendEdgeNeverChangesAVerdict() throws {
        var automated = threeTracks
        automated[0].automationMode = .read
        automated[0].isMuted = true
        let automatedCapture = makeCapture(tracks: automated, issued: issuedReferences(for: automated))
        let withSends = graph(
            nodes: [trackNode(0), trackNode(1), drumBus, reverbBus],
            edges: [
                mainOutput(from: 0, to: drumBus.id),
                sendEdge(from: 0, slot: 0, to: reverbBus, level: -.infinity, enabled: false),
                sendEdge(from: 0, slot: 1, to: drumBus, level: nil, enabled: false),
            ]
        )
        #expect(withSends.isConsistent)

        let plain = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: correctGraph)
        let noisy = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: automatedCapture, graph: withSends)

        #expect(plain == noisy)
        #expect(noisy.findings.map(\.status) == [.compliant])
        #expect(!noisy.changeRequired)

        // A send to bus 4 beside a main output to bus 3 is not a wrong route either.
        let sendOnly = graph(
            nodes: [trackNode(0), drumBus, reverbBus],
            edges: [mainOutput(from: 0, to: drumBus.id), sendEdge(from: 0, slot: 0, to: reverbBus, level: 0.5, enabled: true)]
        )
        #expect(try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: sendOnly)).status == .compliant)
    }

    // Mutation: drop the epoch comparison.
    @Test func graphEpochMismatchIsUnverified() throws {
        let moved = graph(projectEpoch: 4, nodes: correctGraph.nodes, edges: correctGraph.edges)
        let assessment = Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: moved)
        let finding = try onlyFinding(assessment)

        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.graphEpochMismatch])
        #expect(finding.observed == nil)
        #expect(assessment.projectEpoch == 3)
        #expect(assessment.graphProjectEpoch == 4)
        #expect(!assessment.changeRequired)
    }

    // MARK: - Coverage and validity gates

    // Only the association domain is partial: the main output reads cleanly, and still nothing may be
    // decided about it. Mutation: drop the association check.
    @Test func associationOnlyPartialIsUnverified() throws {
        let association = RoutingDomainCoverage(state: .partial, reasons: [RoutingGraphPublication.positionalAssociationReason])
        let routing = graph(
            coverage: coverage(association: association),
            nodes: wrongGraph.nodes,
            edges: wrongGraph.edges
        )
        #expect(routing.isConsistent)
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.stripTrackAssociationIncomplete])
        #expect(finding.coverage.stripTrackAssociation == association)
        #expect(finding.observed?.busNumber == 4)
    }

    // Mutation: drop the main-output check (keep the association one).
    @Test func mainOutputOnlyPartialIsUnverifiedAndCarriesItsReasonsVerbatim() throws {
        let partial = RoutingDomainCoverage(state: .partial, reasons: [
            RoutingGraphPublication.busIdentityReason, RoutingGraphPublication.labelRenameReason,
        ])
        let routing = graph(coverage: coverage(mainOutput: partial), nodes: wrongGraph.nodes, edges: wrongGraph.edges)
        let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: routing))

        #expect(finding.status == .unverified)
        #expect(finding.reasons == [.mainOutputCoverageIncomplete])
        #expect(finding.coverage.mainOutput == partial)
        #expect(finding.coverage.stripTrackAssociation == completeDomain)
    }

    // Each gate that says the graph cannot be read against this capture, one literal token each.
    // Mutation: drop the snapshot-id gate (or any other gate named here).
    @Test func eachValidityGateHasItsToken() throws {
        let cases = assessmentGateCases() + [
            ("target_snapshot_stale",
             makeCapture(tracks: threeTracks, issued: nil, referencesEnabled: true), correctGraph, nil, .unverified),
        ]
        #expect(cases.filter { !$0.graph.isConsistent }.map(\.token) == ["routing_graph_inconsistent"])
        for (token, capture, routing, projectRef, status) in cases {
            let finding = try onlyFinding(Audit.assessIntent(
                policy: try kickPolicy(bus: 3, projectRef: projectRef),
                capture: capture,
                graph: routing
            ))
            #expect(finding.status == status, "\(token)")
            #expect(finding.reasons.map(\.rawValue) == [token])
            #expect(finding.observed == nil, "\(token)")
        }
        // Positive control: the same capture and graph with no gate hit decide.
        let control = try onlyFinding(Audit.assessIntent(
            policy: try kickPolicy(bus: 3, projectRef: "prj_song"),
            capture: threeTrackCapture,
            graph: correctGraph
        ))
        #expect(control.status == .compliant)
    }

    // The snapshot id names cache revisions, not graph contents, so only the project reference ties a
    // graph to the capture's project, and a reference on one side alone is no tie. Mutation: drop the
    // project comparison from the gate.
    @Test func aGraphOfAnotherProjectIsUnverified() throws {
        let unobserved = makeCapture(
            tracks: threeTracks,
            issued: issuedReferences(for: threeTracks),
            projectIssuance: .unobserved(reason: "no path")
        )
        let cases: [(String, Observation.Capture, TargetReference?)] = [
            ("another project", threeTrackCapture, TargetReference(rawValue: "prj_other")),
            ("the graph names none", threeTrackCapture, nil),
            ("the capture issued none", unobserved, songReference),
        ]
        for (label, capture, graphProject) in cases {
            let routing = graph(projectReference: graphProject, nodes: correctGraph.nodes, edges: correctGraph.edges)
            #expect(routing.isConsistent, "\(label)")
            let finding = try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: capture, graph: routing))

            #expect(finding.status == .unverified, "\(label)")
            #expect(finding.reasons.map(\.rawValue) == ["graph_project_mismatch"], "\(label)")
            #expect(finding.observed == nil, "\(label)")
        }

        // Positive controls: one project on both sides, and none on either.
        let unbound = graph(projectReference: nil, nodes: correctGraph.nodes, edges: correctGraph.edges)
        #expect(try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: threeTrackCapture, graph: correctGraph)).status == .compliant)
        #expect(try onlyFinding(Audit.assessIntent(policy: try kickPolicy(bus: 3), capture: unobserved, graph: unbound)).status == .compliant)
    }

    // Every finding, whatever its status, says which aspects nothing observed. Mutation: emit an empty
    // `not_verified` on the compliant branch.
    @Test func everyFindingNamesWhatWasNotVerified() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [
                targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1"),
                targetEntry("tom", "trk_2"), targetEntry("ghost", "trk_9"),
            ],
            roles: [roleEntry("bass", members: [memberEntry("tom", accepted: false)])],
            outputs: [
                targetOutput("kick", bus: 3), targetOutput("snare", bus: 3),
                targetOutput("tom", bus: 3), targetOutput("ghost", bus: 3),
                roleOutput("bass", bus: 6),
            ]
        ))))
        let mixed = graph(
            nodes: [trackNode(0), trackNode(1), trackNode(2), drumBus, reverbBus],
            edges: [mainOutput(from: 0, to: drumBus.id), mainOutput(from: 1, to: reverbBus.id)]
        )

        let assessment = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: mixed)

        #expect(assessment.findings.map(\.id) == [
            "main_output.role.bass",
            "main_output.target.ghost",
            "main_output.target.kick",
            "main_output.target.snare",
            "main_output.target.tom",
        ])
        #expect(assessment.findings.map(\.status) == [.needsInput, .outsideScope, .compliant, .violation, .unverified])
        #expect(Audit.IntentAspect.withoutObservationSource == [.sends, .sidechain, .monitoring])
        for finding in assessment.findings {
            #expect(finding.coverage.notVerified == [.sends, .sidechain, .monitoring])
            #expect(finding.coverage.graphComplete == mixed.complete)
        }
        #expect(assessment.changeRequired)
    }

    // ADR-021 section 4 P1: a soloed, armed, duplicate-named or unnamed track with a correct route is no repair.
    // Mutation: read `isSoloed`, `isArmed` or the name when setting a status.
    @Test func legacyWarningsAreNotConvertedIntoRepairs() throws {
        var soloedKick = liveTrack(0, name: "Kick")
        soloedKick.isSoloed = true
        soloedKick.isArmed = true
        var duplicateKick = liveTrack(1, name: "Kick")
        duplicateKick.isMuted = true
        let unnamed = liveTrack(2, name: "")
        let messy = [soloedKick, duplicateKick, unnamed]
        let capture = makeCapture(tracks: messy, issued: issuedReferences(for: messy))
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("a", "trk_0"), targetEntry("b", "trk_1"), targetEntry("c", "trk_2")],
            outputs: [targetOutput("a", bus: 3), targetOutput("b", bus: 3), targetOutput("c", bus: 3)]
        ))))
        let routed = graph(
            nodes: [trackNode(0, name: "Kick"), trackNode(1, name: "Kick"), trackNode(2, name: ""), drumBus],
            edges: [mainOutput(from: 0, to: drumBus.id), mainOutput(from: 1, to: drumBus.id), mainOutput(from: 2, to: drumBus.id)]
        )

        let assessment = Audit.assessIntent(policy: policy, capture: capture, graph: routed)

        #expect(assessment.findings.count == 3)
        #expect(assessment.findings.allSatisfy { $0.status == .compliant })
        #expect(assessment.findings.allSatisfy { $0.reasons.isEmpty })
        #expect(!assessment.changeRequired)
        #expect(assessment.questions.isEmpty)
    }

    // Mutation: sort findings by status, or rename a CodingKey.
    @Test func assessmentIsDeterministicSortedAndEncodesSnakeCase() throws {
        let policy = try #require(accepted(Audit.parseIntentPolicy(policyObject(
            targets: [targetEntry("zulu", "trk_2"), targetEntry("alpha", "trk_0"), targetEntry("mike", "trk_1")],
            roles: [roleEntry("bass", members: [memberEntry("mike", accepted: false)])],
            outputs: [targetOutput("zulu", bus: 3), targetOutput("alpha", bus: 3), targetOutput("mike", bus: 4), roleOutput("bass", bus: 6)]
        ))))
        let routed = graph(
            nodes: [trackNode(0), trackNode(1), trackNode(2), drumBus, reverbBus],
            edges: [mainOutput(from: 0, to: drumBus.id), mainOutput(from: 1, to: drumBus.id), mainOutput(from: 2, to: reverbBus.id)]
        )

        let first = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: routed)
        let second = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: routed)
        let firstText = try encodeJSONStrict(first, compact: true)
        let secondText = try encodeJSONStrict(second, compact: true)

        #expect(first == second)
        #expect(firstText == secondText)
        #expect(first.findings.map(\.id) == [
            "main_output.role.bass",
            "main_output.target.alpha",
            "main_output.target.mike",
            "main_output.target.zulu",
        ])
        #expect(first.questions.map(\.id) == ["role.bass"])
        #expect(first.snapshotId == baselineSnapshotId)

        let json = try #require(sharedJSONObject(firstText))
        #expect(Set(json.keys) == [
            "schema", "read_only", "snapshot_id", "project_epoch", "graph_project_epoch",
            "findings", "questions", "change_required",
        ])
        #expect(json["schema"] as? String == "logic_pro_mcp_intent_assessment.v1")
        #expect(try #require(json["read_only"] as? Bool))
        #expect(try #require(json["change_required"] as? Bool))
        #expect(json["snapshot_id"] as? String == baselineSnapshotId)

        let findings = try #require(json["findings"] as? [[String: Any]])
        let compliant = try #require(findings.first { $0["id"] as? String == "main_output.target.alpha" })
        #expect(Set(compliant.keys) == [
            "id", "rule", "basis", "severity", "status", "target", "observed", "expected", "coverage", "reasons",
        ])
        #expect(compliant["basis"] as? String == "approved_policy")
        #expect(compliant["status"] as? String == "compliant")
        let target = try #require(compliant["target"] as? [String: Any])
        #expect(Set(target.keys) == ["handle", "track_ref", "track_index"])
        let observed = try #require(compliant["observed"] as? [String: Any])
        #expect(Set(observed.keys) == ["node_id", "display_name", "bus_number", "output"])
        #expect(observed["output"] as? String == "bus")
        let expected = try #require(compliant["expected"] as? [String: Any])
        #expect(Set(expected.keys) == ["bus_number", "output"])
        let coverage = try #require(compliant["coverage"] as? [String: Any])
        #expect(Set(coverage.keys) == [
            "output_edge_observed", "destination_bus_observed", "expected_bus_observed", "graph_complete",
            "main_output", "strip_track_association", "not_verified",
        ])
        #expect(coverage["not_verified"] as? [String] == ["sends", "sidechain", "monitoring"])
        let mainOutputCoverage = try #require(coverage["main_output"] as? [String: Any])
        #expect(Set(mainOutputCoverage.keys) == ["state", "reasons"])
        #expect(mainOutputCoverage["state"] as? String == "complete")

        let needsInput = try #require(findings.first { $0["id"] as? String == "main_output.role.bass" })
        #expect(needsInput["status"] as? String == "needs_input")
        let violation = try #require(findings.first { $0["id"] as? String == "main_output.target.mike" })
        #expect(violation["status"] as? String == "violation")
        #expect(violation["severity"] as? String == "warn")

        let questions = try #require(json["questions"] as? [[String: Any]])
        let question = try #require(questions.first)
        #expect(Set(question.keys) == ["id", "role", "rule", "expected", "candidates"])
        let candidates = try #require(question["candidates"] as? [[String: Any]])
        #expect(candidates.map { Set($0.keys) } == [["handle", "track_ref"]])
    }
}

// MARK: - Receiving-aux steps over a graph bound to its capture (#1090 review R1090-001)

/// Kick (trk_0) and Snare (trk_1) observed on the reverb bus (4), both approved onto the drum bus
/// (3): two wrong-route findings over a graph published for this capture, with every domain read.
private func receiverGraph(receiver: Bool, snapshotId: String = baselineSnapshotId, projectEpoch: UInt64 = 3) -> RoutingGraph {
    let aux = auxNode("aux_drum_return")
    var edges = [mainOutput(from: 0, to: reverbBus.id), mainOutput(from: 1, to: reverbBus.id)]
    if receiver { edges.append(inputAssignment(from: drumBus, to: aux)) }
    return graph(projectEpoch: projectEpoch, snapshotId: snapshotId,
                 nodes: [trackNode(0), trackNode(1), drumBus, reverbBus, aux], edges: edges)
}

private func twoTargetPolicy(receiver: String? = nil) throws -> (Audit.IntentPolicy, Value) {
    var object = policyObject(
        targets: [targetEntry("kick", "trk_0"), targetEntry("snare", "trk_1")],
        outputs: [targetOutput("kick", bus: 3), targetOutput("snare", bus: 3)]
    )
    if let receiver {
        object["receivers"] = .array([.object(["bus": .int(3), "aux": .string(receiver)])])
    }
    let policy = try #require(accepted(Audit.parseIntentPolicy(object)))
    return (policy, .object(object))
}

private func receiverPlan(receiver: Bool, allow: Bool, snapshotId: String = baselineSnapshotId,
                          projectEpoch: UInt64 = 3, intent: String? = "new") throws -> [String: Any] {
    let (policy, value) = try twoTargetPolicy(receiver: intent)
    var options = Audit.PlanningOptions()
    options.allowCreateAux = allow
    let plan = try Audit.buildCanonicalRepairPlan(
        policy: policy, policyValue: value, names: [], capture: threeTrackCapture,
        request: Observation.Request(domains: [.tracks, .strips, .routing]), snapshotCurrent: true,
        options: options, graphOverride: receiverGraph(receiver: receiver, snapshotId: snapshotId, projectEpoch: projectEpoch))
    return try #require(sharedJSONObject(plan.json))
}

private func planSteps(_ body: [String: Any]) throws -> [[String: Any]] {
    try #require(body["steps"] as? [[String: Any]])
}

@Suite("Receiving-aux steps over a bound graph (#966 P2)")
struct Issue966ReceivingAuxBoundGraphTests {
    /// Control for the fixture: the gate accepts this graph for this capture and both outputs are
    /// violations, so the receiver branches below run over evidence the planner may use.
    @Test func theFixtureGraphIsBoundToItsCaptureAndBothRoutesAreWrong() throws {
        let (policy, _) = try twoTargetPolicy()
        let bound = Audit.assessmentGate(policy: policy, capture: threeTrackCapture, graph: receiverGraph(receiver: false))
        #expect(bound == nil)
        let assessment = Audit.assessIntent(policy: policy, capture: threeTrackCapture, graph: receiverGraph(receiver: false))
        let violations = assessment.findings.filter { $0.status == .violation }.count
        #expect(violations == 2)
    }

    /// No aux reads bus 3 and creation is allowed: one create_aux step, before both outputs, each
    /// output depending on it, one inventory entry. Mutations this kills: the aux step after its
    /// outputs, one aux per output.
    @Test func oneAuxIsPlannedBeforeEveryOutputThatNeedsIt() throws {
        let body = try receiverPlan(receiver: false, allow: true)
        let steps = try planSteps(body)
        let kinds = steps.compactMap { $0["kind"] as? String }
        #expect(kinds == ["create_aux", "main_output", "main_output"])
        let auxID = try #require(steps.first?["id"] as? String)
        for output in steps.dropFirst() {
            let dependencies = try #require(output["dependencies"] as? [String])
            #expect(dependencies == [auxID])
        }
        let inventory = try #require(body["new_object_inventory"] as? [[String: Any]])
        #expect(inventory.count == 1)
        #expect(inventory.first?["created_by"] as? String == auxID)
    }

    /// Mutation this kills: a missing receiver ignored when creation is not allowed.
    @Test func aMissingReceiverBlocksTheOutputsWhenCreationIsNotAllowed() throws {
        let body = try receiverPlan(receiver: false, allow: false)
        let steps = try planSteps(body)
        let kinds = steps.compactMap { $0["kind"] as? String }
        #expect(kinds == ["main_output", "main_output"])
        for output in steps {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            #expect(blocked.contains("receiving_aux_missing"))
            #expect(blocked.contains("create_aux_not_allowed"))
        }
    }

    /// Control: an observed receiver adds no aux step and no receiver reason.
    @Test func anObservedReceiverAddsNothing() throws {
        let steps = try planSteps(try receiverPlan(receiver: true, allow: true))
        let kinds = steps.compactMap { $0["kind"] as? String }
        #expect(kinds == ["main_output", "main_output"])
        for output in steps {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            let mentionsReceiver = blocked.contains { $0.contains("receiv") || $0.contains("aux") }
            #expect(!mentionsReceiver, "\(blocked)")
        }
    }

    /// R1090-001: a graph the gate rejects as another capture's says nothing about this session's
    /// receivers. Mutation this kills: receiver evidence read from a rejected graph, which planned
    /// an aux from it.
    @Test func aGraphFromAnotherCapturePlansNoAux() throws {
        let body = try receiverPlan(receiver: false, allow: true, snapshotId: "another_capture")
        let steps = try planSteps(body)
        let createsAux = steps.contains { $0["kind"] as? String == "create_aux" }
        #expect(!createsAux)
        let inventory = try #require(body["new_object_inventory"] as? [Any])
        #expect(inventory.isEmpty)
        for output in steps where output["kind"] as? String == "main_output" {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            #expect(blocked.contains("bus_receiver_unverified"))
            #expect(!blocked.contains("receiving_aux_missing"))
        }
        let reasons = try #require(body["reasons"] as? [String])
        #expect(reasons.contains("graph_not_from_capture"))
    }

    /// R1090-002: the gate passes a graph from another registry epoch, which the assessor rejects
    /// per finding. Neither the absence nor the presence of a receiver is read from it. Mutation
    /// this kills: receiver evidence read past an epoch mismatch.
    @Test(arguments: [false, true])
    func aGraphFromAnotherRegistryEpochDecidesNoReceiver(receiver: Bool) throws {
        let body = try receiverPlan(receiver: receiver, allow: true, projectEpoch: 4)
        let steps = try planSteps(body)
        let createsAux = steps.contains { $0["kind"] as? String == "create_aux" }
        #expect(!createsAux)
        let inventory = try #require(body["new_object_inventory"] as? [Any])
        #expect(inventory.isEmpty)
        for output in steps where output["kind"] as? String == "main_output" {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            #expect(blocked.contains("bus_receiver_unverified"))
        }
        let reasons = try #require(body["reasons"] as? [String])
        #expect(reasons.contains("graph_epoch_mismatch"))
    }

    /// R1090-004: an output approves the bus, not what reads it. With no `receivers` entry an
    /// absent receiver plans no aux and blocks no output; it asks. Mutation this kills: an aux
    /// planned, or the output blocked, from absence alone.
    @Test func anAbsentReceiverWithoutApprovedIntentAsksAndPlansNothing() throws {
        let body = try receiverPlan(receiver: false, allow: true, intent: nil)
        let steps = try planSteps(body)
        let kinds = steps.compactMap { $0["kind"] as? String }
        #expect(kinds == ["main_output", "main_output"])
        for output in steps {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            let mentionsReceiver = blocked.contains { $0.contains("receiv") || $0.contains("aux") }
            #expect(!mentionsReceiver, "\(blocked)")
        }
        let questions = try #require(body["receiver_questions"] as? [[String: Any]])
        #expect(questions.count == 1)
        #expect(questions.first?["observed"] as? String == "no_receiver")
        let reasons = try #require(body["reasons"] as? [String])
        #expect(reasons.contains("receiver_intent_unresolved"))
        let inventory = try #require(body["new_object_inventory"] as? [Any])
        #expect(inventory.isEmpty)
    }

    /// Control for the question: a sidechain-only bus approved as `none` is answered, and an
    /// absent receiver there is correct.
    @Test func aBusApprovedWithNoReceiverIsSettled() throws {
        let body = try receiverPlan(receiver: false, allow: true, intent: "none")
        let questions = try #require(body["receiver_questions"] as? [Any])
        #expect(questions.isEmpty)
        let reasons = try #require(body["reasons"] as? [String])
        #expect(!reasons.contains("receiver_intent_unresolved"))
        let createsAux = try planSteps(body).contains { $0["kind"] as? String == "create_aux" }
        #expect(!createsAux)
    }

    /// An observed receiver contradicting an approved `none` is asked about, not overridden.
    @Test func anObservedReceiverAgainstApprovedNoneAsks() throws {
        let body = try receiverPlan(receiver: true, allow: true, intent: "none")
        let questions = try #require(body["receiver_questions"] as? [[String: Any]])
        #expect(questions.first?["observed"] as? String == "receiver_present")
    }
}
