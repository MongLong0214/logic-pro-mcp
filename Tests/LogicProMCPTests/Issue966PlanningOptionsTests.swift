import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #966 ADR-021 section 3: `on_ambiguity` and the three `allow_*` inputs, and the receiving-aux
/// rule a bus destination needs before its output step can mean anything.
@Suite("Repair planning options and receiving auxes", .serialized)
struct Issue966PlanningOptionsTests {
    typealias Audit = ProjectSessionAudit

    // MARK: - Parsing

    /// Mutation this kills: an unknown mode or a non-Bool flag read as the default, which would
    /// plan under options the client did not send.
    @Test func optionsParseStrictlyAndDefaultToTheNarrowerChoice() throws {
        let defaults = try #require(Audit.PlanningOptions.parse([:]))
        #expect(defaults == Audit.PlanningOptions())
        let isAsk = defaults.onAmbiguity == .ask
        #expect(isAsk)
        #expect(!defaults.allowCreateAux && !defaults.allowStackMembershipChange && !defaults.allowReplaceSend)

        let all = try #require(Audit.PlanningOptions.parse([
            "on_ambiguity": .string("report_only"), "allow_create_aux": .bool(true),
            "allow_stack_membership_change": .bool(true), "allow_replace_send": .bool(true),
        ]))
        let isReportOnly = all.onAmbiguity == .reportOnly
        #expect(isReportOnly)
        #expect(all.allowCreateAux && all.allowStackMembershipChange && all.allowReplaceSend)

        for bad: [String: Value] in [
            ["on_ambiguity": .string("guess")], ["on_ambiguity": .bool(true)],
            ["allow_create_aux": .string("true")], ["allow_replace_send": .int(1)],
            ["allow_stack_membership_change": .null],
        ] {
            #expect(Audit.PlanningOptions.parse(bad) == nil, "\(bad)")
        }
    }

    // MARK: - Receiving aux

    private func busGraph(edges: [RoutingEdge], busToAux: RoutingCoverageState) -> RoutingGraph {
        let complete = RoutingDomainCoverage(state: .complete, reasons: [])
        let receiverDomain = RoutingDomainCoverage(state: busToAux, reasons: busToAux == .complete ? [] : ["fixture"])
        let coverage = RoutingCoverage(population: complete, stripTrackAssociation: complete, mainOutput: complete,
                                       physicalOutput: complete, busToAuxInput: receiverDomain, sends: complete)
        return RoutingGraph(
            projectReference: nil, projectEpoch: 1, complete: coverage.isComplete,
            partialReason: coverage.isComplete ? nil : "fixture",
            nodes: [
                RoutingNode(id: "aux_drum_bus", kind: .bus, displayName: "Bus 3", busNumber: 3, targetRef: nil),
                RoutingNode(id: "aux_1", kind: .aux, displayName: "Aux 1", busNumber: nil, targetRef: nil),
            ],
            edges: edges, provenance: [.axMixerStrip], snapshotId: "fixture", coverage: coverage)
    }

    private let receiverEdge = RoutingEdge(kind: .inputAssignment, source: "aux_drum_bus", destination: "aux_1",
                                           send: nil, provenance: .axMixerStrip)

    /// Absence is concluded only from a complete bus-to-aux reading. Mutations this kill: absence
    /// from a partial reading, a receiver missed because the bus node's id is not `bus_<n>`, and a
    /// receiver found on another bus.
    @Test func aReceiverIsPresentAbsentOnlyOnACompleteReadingOrElseUnverified() {
        #expect(Audit.receivingAux(bus: 3, graph: busGraph(edges: [receiverEdge], busToAux: .complete)) == .present)
        #expect(Audit.receivingAux(bus: 3, graph: busGraph(edges: [receiverEdge], busToAux: .partial)) == .present)
        #expect(Audit.receivingAux(bus: 3, graph: busGraph(edges: [], busToAux: .complete)) == .absent)
        for state: RoutingCoverageState in [.partial, .unavailable, .unstable, .notObserved] {
            #expect(Audit.receivingAux(bus: 3, graph: busGraph(edges: [], busToAux: state)) == .unverified, "\(state)")
        }
        #expect(Audit.receivingAux(bus: 4, graph: busGraph(edges: [receiverEdge], busToAux: .complete)) == .absent)
    }

    // MARK: - Through the dispatcher

    private func fixture() async throws -> (StateCache, TargetRegistry, String, String) {
        let cache = StateCache()
        let registry = TargetRegistry()
        await cache.updateProject(ProjectInfo(name: "Fixture", filePath: "/tmp/Fixture.logicx"))
        await cache.updateTracks([TrackState(id: 0, name: "Original", type: .audio)])
        let result = await ProjectDispatcher.handle(command: "inspect_session", params: [
            "domains": .array([.string("tracks"), .string("strips"), .string("routing")])
        ], router: ChannelRouter(), cache: cache, targetRegistry: registry,
           cleanupAuditFileReader: .unavailable)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let snapshot = try #require(body["snapshot_id"] as? String)
        let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        let reference = try #require(rows.first?["track_ref"] as? String)
        return (cache, registry, snapshot, reference)
    }

    private func policy(_ reference: String, bus: Int) -> Value {
        .object([
            "schema": .string(Audit.intentPolicySchema),
            "targets": .array([.object(["handle": .string("track"), "track_ref": .string(reference)])]),
            "roles": .array([]),
            "outputs": .array([.object(["target": .string("track"), "bus": .int(bus)])]),
        ])
    }

    private func plan(_ params: [String: Value], cache: StateCache, registry: TargetRegistry) async throws -> [String: Any]? {
        let result = await ProjectDispatcher.handle(command: "plan_session_repair", params: params,
            router: ChannelRouter(), cache: cache, targetRegistry: registry, cleanupAuditFileReader: .unavailable)
        if result.isError == true { return nil }
        return sharedJSONObject(sharedToolText(result))
    }

    /// The options are in the canonical plan, so the digest binds them; report_only can never be
    /// executable. Mutation this kills: options left out of the digested body.
    @Test func reportOnlyIsRecordedDigestedAndNeverExecutable() async throws {
        let (cache, registry, snapshot, reference) = try await fixture()
        let base: [String: Value] = ["snapshot_id": .string(snapshot), "policy": policy(reference, bus: 3)]
        let ask = try #require(try await plan(base, cache: cache, registry: registry))
        var reportParams = base
        reportParams["on_ambiguity"] = .string("report_only")
        let report = try #require(try await plan(reportParams, cache: cache, registry: registry))

        let reportOptions = try #require(report["planning_options"] as? [String: Any])
        #expect(reportOptions["on_ambiguity"] as? String == "report_only")
        let askOptions = try #require(ask["planning_options"] as? [String: Any])
        #expect(askOptions["on_ambiguity"] as? String == "ask")
        let digestsDiffer = (report["digest"] as? String) != (ask["digest"] as? String)
        #expect(digestsDiffer)
        let reportReasons = try #require(report["reasons"] as? [String])
        #expect(reportReasons.contains("report_only_requested"))
        let askReasons = try #require(ask["reasons"] as? [String])
        #expect(!askReasons.contains("report_only_requested"))
        let executable = try #require(report["executable"] as? Bool)
        #expect(!executable)
    }

    /// The capture's routing graph publishes no bus-to-aux reading, so a bus destination's step
    /// says its receiver is unverified rather than assuming one exists or is missing, and no aux
    /// is planned even when creation is allowed. Mutation this kills: a missing reading treated as
    /// an absent receiver, which would plan an aux nobody showed to be missing.
    @Test func aBusDestinationOverTodaysCaptureCarriesAnUnverifiedReceiver() async throws {
        let (cache, registry, snapshot, reference) = try await fixture()
        let body = try #require(try await plan([
            "snapshot_id": .string(snapshot), "policy": policy(reference, bus: 3),
            "allow_create_aux": .bool(true),
        ], cache: cache, registry: registry))
        let steps = try #require(body["steps"] as? [[String: Any]])
        let output = try #require(steps.first { $0["kind"] as? String == "main_output" })
        let blocked = try #require(output["blocked_reasons"] as? [String])
        #expect(blocked.contains("bus_receiver_unverified"))
        let createsAux = steps.contains { $0["kind"] as? String == "create_aux" }
        #expect(!createsAux)
        let inventory = try #require(body["new_object_inventory"] as? [Any])
        #expect(inventory.isEmpty)
    }

    /// A plan lookup cannot be reinterpreted with planning options, and a bad option refuses the
    /// whole request.
    @Test func lookupRefusesOptionsAndABadOptionRefusesThePlan() async throws {
        let (cache, registry, snapshot, reference) = try await fixture()
        let first = try #require(try await plan(["snapshot_id": .string(snapshot), "policy": policy(reference, bus: 3)],
                                                cache: cache, registry: registry))
        let id = try #require(first["plan_id"] as? String)
        let lookup = try await plan(["plan_id": .string(id), "on_ambiguity": .string("ask")], cache: cache, registry: registry)
        #expect(lookup == nil)
        let control = try await plan(["plan_id": .string(id)], cache: cache, registry: registry)
        #expect(control != nil)
        let bad = try await plan(["snapshot_id": .string(snapshot), "policy": policy(reference, bus: 3),
                                  "allow_create_aux": .string("yes")], cache: cache, registry: registry)
        #expect(bad == nil)
    }
}

@Suite("Receiving-aux steps over a graph that reads bus-to-aux inputs", .serialized)
struct Issue966ReceivingAuxStepTests {
    typealias Audit = ProjectSessionAudit

    private func graph(receiver: Bool) -> RoutingGraph {
        let complete = RoutingDomainCoverage(state: .complete, reasons: [])
        let coverage = RoutingCoverage.uniform(complete)
        return RoutingGraph(
            projectReference: nil, projectEpoch: 1, complete: true, partialReason: nil,
            nodes: [
                RoutingNode(id: "aux_drum_bus", kind: .bus, displayName: "Bus 3", busNumber: 3, targetRef: nil),
                RoutingNode(id: "aux_1", kind: .aux, displayName: "Aux 1", busNumber: nil, targetRef: nil),
            ],
            edges: receiver ? [RoutingEdge(kind: .inputAssignment, source: "aux_drum_bus", destination: "aux_1",
                                           send: nil, provenance: .axMixerStrip)] : [],
            provenance: [.axMixerStrip], snapshotId: "fixture", coverage: coverage)
    }

    /// Two tracks approved onto bus 3, no aux reads bus 3, and creation allowed: one create_aux
    /// step, before both outputs, each output depending on it, and one inventory entry.
    /// Mutations these kill: the aux step after its outputs, one aux per output, and the missing
    /// receiver ignored when creation is not allowed.
    private func build(receiver: Bool, allow: Bool) async throws -> [String: Any] {
        let cache = StateCache()
        let registry = TargetRegistry()
        await cache.updateProject(ProjectInfo(name: "Fixture", filePath: "/tmp/Fixture.logicx"))
        await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio), TrackState(id: 1, name: "Snare", type: .audio)])
        let inspected = await ProjectDispatcher.handle(command: "inspect_session", params: [
            "domains": .array([.string("tracks"), .string("strips"), .string("routing")])
        ], router: ChannelRouter(), cache: cache, targetRegistry: registry, cleanupAuditFileReader: .unavailable)
        let body = try #require(sharedJSONObject(sharedToolText(inspected)))
        let snapshot = try #require(body["snapshot_id"] as? String)
        let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
        let refs = rows.compactMap { $0["track_ref"] as? String }
        try #require(refs.count == 2)
        let inspection = try #require(await cache.retainedInspection(id: snapshot))
        let policyObject: [String: Value] = [
            "schema": .string(Audit.intentPolicySchema),
            "targets": .array([
                .object(["handle": .string("kick"), "track_ref": .string(refs[0])]),
                .object(["handle": .string("snare"), "track_ref": .string(refs[1])]),
            ]),
            "roles": .array([]),
            "outputs": .array([
                .object(["target": .string("kick"), "bus": .int(3)]),
                .object(["target": .string("snare"), "bus": .int(3)]),
            ]),
        ]
        guard case .accepted(let policy) = Audit.parseIntentPolicy(policyObject) else {
            Issue.record("the fixture policy was rejected")
            return [:]
        }
        var options = Audit.PlanningOptions()
        options.allowCreateAux = allow
        let plan = try Audit.buildCanonicalRepairPlan(
            policy: policy, policyValue: .object(policyObject), names: [],
            capture: inspection.capture, request: inspection.request, snapshotCurrent: true,
            options: options, graphOverride: graph(receiver: receiver))
        return try #require(sharedJSONObject(plan.json))
    }

    @Test func oneAuxIsPlannedBeforeEveryOutputThatNeedsIt() async throws {
        let body = try await build(receiver: false, allow: true)
        let steps = try #require(body["steps"] as? [[String: Any]])
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
        let reasons = try #require(body["reasons"] as? [String])
        #expect(reasons.contains("aux_creation_adapter_unavailable"))
    }

    @Test func aMissingReceiverBlocksTheOutputWhenCreationIsNotAllowed() async throws {
        let body = try await build(receiver: false, allow: false)
        let steps = try #require(body["steps"] as? [[String: Any]])
        let kinds = steps.compactMap { $0["kind"] as? String }
        #expect(kinds == ["main_output", "main_output"])
        for output in steps {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            #expect(blocked.contains("receiving_aux_missing"))
            #expect(blocked.contains("create_aux_not_allowed"))
        }
        let inventory = try #require(body["new_object_inventory"] as? [Any])
        #expect(inventory.isEmpty)
    }

    /// Control: an existing receiver adds no aux step and no receiver reason.
    @Test func anExistingReceiverAddsNothing() async throws {
        let body = try await build(receiver: true, allow: true)
        let steps = try #require(body["steps"] as? [[String: Any]])
        let kinds = steps.compactMap { $0["kind"] as? String }
        #expect(kinds == ["main_output", "main_output"])
        for output in steps {
            let blocked = try #require(output["blocked_reasons"] as? [String])
            let mentionsReceiver = blocked.contains { $0.contains("receiv") || $0.contains("aux") }
            #expect(!mentionsReceiver, "\(blocked)")
        }
    }
}
