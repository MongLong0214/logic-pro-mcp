import Foundation
import Testing
@testable import LogicProMCP

@Suite("#291 captured checked-output graph", .serialized)
struct Issue291CheckedOutputGraphTests {
    private func preparedFixture() throws -> Issue291PhysicalStripReferenceTests.Fixture {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let stereo = f.b.element(2_919_001)
        f.b.setRole(stereo, "AXMenuItem")
        f.b.setAttribute(stereo, "AXTitle", "Stereo Output")
        f.b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
        f.b.setChildren(stereo, [])
        let parent = f.b.element(2_919_002)
        let menu = f.b.element(2_919_003)
        let leaf = f.b.element(2_919_004)
        f.b.setRole(parent, "AXMenuItem"); f.b.setAttribute(parent, "AXTitle", "Output")
        f.b.setRole(menu, "AXMenu")
        f.b.setRole(leaf, "AXMenuItem"); f.b.setAttribute(leaf, "AXTitle", "Stereo Output")
        f.b.setAttribute(leaf, "AXMenuItemMarkChar", "✓"); f.b.setChildren(leaf, [])
        f.b.setChildren(menu, [leaf]); f.b.setChildren(parent, [menu])
        f.b.setChildren(f.root, [stereo, parent])
        return f
    }

    @Test("The existing owned reader supplies a typed observation without parsing its receipt")
    func ownedOutputReadSuppliesTypedAssignment() async throws {
        let f = try preparedFixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let owner = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let read = await AXMixerStripBinding.$current.withValue(owner) {
            await AccessibilityChannel.getOutputObservation(runtime: f.logic, timing: .immediate)
        }
        #expect(read.assignment == .stereoOutput)
        #expect(try #require(sharedJSONObject(read.result.message))["state"] as? String == "A")
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
    }

    @Test("Fresh inspection acquires checked outputs only with explicit navigation permission", arguments: [false, true])
    func freshInspectionOwnsCheckedOutputs(navigation: Bool) async throws {
        let f = try preparedFixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: navigation), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        #expect(try #require(population.strips).count == 2)
        #expect(population.checkedOutputs.count == (navigation ? 2 : 0))
        #expect(population.checkedOutputs.allSatisfy { $0.assignment == .stereoOutput })
        #expect(f.mutations.map { $0.1 } == (navigation ? ["AXPress", "AXCancel", "AXPress", "AXCancel"] : []))
    }

    @Test("Only request-held checked output contributes a physical-source bus edge",
          arguments: ["held", "absent", "other_owner", "conflict", "unstable"])
    func checkedOutputUsesTheCapturedPhysicalOwner(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Issue291PhysicalStripReferenceTests.Fixture()
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let cache = StateCache(); let registry = TargetRegistry()
            let states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let owner = try #require(states[0].physicalBinding)
            let source = try #require(base.mixerReference(at: 0))
            var fresh = SessionPopulationObservation.FreshPopulation(project: base.project,
                tracks: base.tracks, strips: states, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            if fault != "absent" {
                fresh.checkedOutputs = [.init(source: fault == "other_owner"
                    ? try #require(states[1].physicalBinding) : owner, assignment: .bus(1))]
                if fault == "conflict" { fresh.checkedOutputs.append(.init(source: owner, assignment: .bus(2))) }
            }
            let capture = SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: base.channelStrips,
                mixerFetchedAt: base.mixerFetchedAt, fileTrackCount: base.fileTrackCount,
                projectFileNotBound: base.projectFileNotBound,
                requestedProjectMatches: base.requestedProjectMatches,
                referencesEnabled: base.referencesEnabled, targetSnapshot: base.targetSnapshot,
                issued: base.issued, projectIssuance: base.projectIssuance,
                beganAt: base.beganAt, endedAt: base.endedAt, captureID: base.captureID,
                freshPopulation: fresh, mixerReferences: base.mixerReferences)
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let edges = graph.edges.filter { $0.source == source.rawValue }
            if fault == "held" {
                let edge = try #require(edges.first)
                #expect(edges.count == 1)
                #expect(edge.kind == .mainOutput)
                #expect(edge.destination == "bus_1")
                #expect(graph.nodes.first { $0.id == "bus_1" }?.kind == .bus)
                #expect(graph.nodes.first { $0.id == "bus_1" }?.targetRef == nil)
            } else { #expect(edges.isEmpty) }
            #expect(!graph.complete)
            #expect(graph.snapshotId == base.captureID)
            #expect(graph.coverage.stripTrackAssociation.state != .complete)
            #expect(!graph.edges.contains { $0.kind == .inputAssignment })
            let section = SessionPopulationObservation.routingSection(capture: capture, moved: false)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(section)) as? [String: Any])
            let publishedEdges = try #require(object["edges"] as? [[String: Any]])
            #expect(publishedEdges.count == graph.edges.count)
            #expect(object["snapshot_id"] as? String == graph.snapshotId)
            #expect(f.mutations.isEmpty)
        }
    }

    @Test("Interrupted acquisition retains the already restored popup effects", arguments: [false, true])
    func interruptedReadRetainsKnownEffects(revoked: Bool) async throws {
        let f = try preparedFixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        do {
            _ = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: true), fileReader: .unavailable,
                    navigationReferenceIsCurrent: { !revoked || f.mutations.count < 2 },
                    stoppingWhen: { !revoked && f.mutations.count >= 2 })
            }
            Issue.record("The interrupted acquisition must not publish a population")
        } catch let error as SessionPopulationObservation.NavigationAcquisitionError {
            #expect(error.effects.navigationPerformed)
            #expect(error.effects.attempted.contains("routing_popup"))
            #expect(error.effects.changed.contains("routing_popup"))
            #expect(error.effects.restoration == "restored")
        }
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
    }

    @Test("An observed popup that cannot be cancelled remains an explicit UI change")
    func unclosedPopupWithholdsCheckedOutputs() async throws {
        let f = try preparedFixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        f.b.setActionNames(f.root, [])
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: true), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(!population.stable)
        #expect(population.checkedOutputs.isEmpty)
        #expect(population.uiEffects.navigationPerformed)
        #expect(population.uiEffects.restoration == "partially_restored")
        #expect(population.uiEffects.changed.contains("routing_popup"))
        #expect(f.mutations.map { $0.1 } == ["AXPress"])
    }
}
