import Foundation
import Testing
@testable import LogicProMCP

@Suite("RoutingGraphTests")
struct RoutingGraphTests {
    @Test func partialGraphNeverReportsCompleteAndConsistencyRejectsContradiction() {
        let partial = graph(complete: false, partialReason: "mixer scan interrupted")
        let contradictory = graph(complete: true, partialReason: "missing aux strips")

        #expect(!partial.complete)
        #expect(partial.isConsistent)
        #expect(!contradictory.isConsistent)
    }

    @Test func occupiedSlotWithoutReplacementRejectsWithoutWriteAttempt() {
        let decision = evaluate(request(), against: graph())

        #expect(!decision.allowed)
        #expect(decision.rejections == [.slotOccupied(slot: 0)])
        #expect(!decision.writeAttempted)
    }

    @Test func occupiedSlotWithReplacementIsAllowed() {
        let decision = evaluate(request(replaceExisting: true), against: graph())

        #expect(decision.allowed)
        #expect(decision.rejections.isEmpty)
    }

    @Test func staleEpochRejectsWithoutWriteAttempt() {
        let decision = evaluate(request(expectedProjectEpoch: 6), against: graph())

        #expect(!decision.allowed)
        #expect(decision.rejections.contains(.staleGraph(expected: 6, actual: 7)))
        #expect(!decision.writeAttempted)
    }

    @Test func duplicateAuxNamesResolveByBusNumberAndNameOnlyRejects() {
        let duplicateNameGraph = graph(
            nodes: [
                trackNode,
                RoutingNode(id: "bus-1", kind: .bus, displayName: "Reverb", busNumber: 1, targetRef: destinationRef(1)),
                RoutingNode(id: "bus-2", kind: .bus, displayName: "Reverb", busNumber: 2, targetRef: destinationRef(2)),
            ],
            edges: []
        )

        let distinguished = evaluate(
            request(physicalSlot: 1, destinationBusNumber: 2, destinationRef: destinationRef(2)),
            against: duplicateNameGraph
        )
        let nameOnly = evaluate(
            request(physicalSlot: 1, destinationBusNumber: nil, destinationRef: nil),
            against: duplicateNameGraph
        )

        #expect(distinguished.allowed)
        #expect(nameOnly.rejections.contains(.destinationNotBusDistinguished))
        #expect(!nameOnly.writeAttempted)
    }

    @Test func partialGraphRejectsWithoutWriteAttempt() {
        let decision = evaluate(
            request(replaceExisting: true),
            against: graph(complete: false, partialReason: "send slots unreadable")
        )

        #expect(decision.rejections.contains(.partialGraphUnsafe(reason: "send slots unreadable")))
        #expect(!decision.writeAttempted)
    }

    @Test func unknownDestinationBusRejectsWithoutWriteAttempt() {
        let decision = evaluate(
            request(physicalSlot: 1, destinationBusNumber: 99, destinationRef: nil),
            against: graph(edges: [])
        )

        #expect(decision.rejections.contains(.unknownDestination))
        #expect(!decision.writeAttempted)
    }

    @Test func missingSourceAndOutOfRangeSlotRejectWithoutWriteAttempt() {
        let decision = evaluate(
            RoutingWriteRequest(
                sourceTrackRef: TargetReference(rawValue: "trk_missing"),
                physicalSlot: 12,
                destinationBusNumber: 1,
                destinationRef: destinationRef(1),
                expectedProjectEpoch: 7
            ),
            against: graph()
        )

        #expect(decision.rejections.contains(.slotOutOfRange(slot: 12)))
        #expect(decision.rejections.contains(.sourceNotFound))
        #expect(!decision.writeAttempted)
    }

    @Test func graphDiffDetectsAddedRemovedAndChangedSends() {
        let unchanged = send(slot: 3, bus: 1, level: 0.25)
        let changedBefore = send(slot: 0, bus: 1, level: 0.5)
        let changedAfter = send(slot: 0, bus: 1, level: 0.75)
        let removed = send(slot: 1, bus: 1, level: 0.1)
        let added = send(slot: 2, bus: 2, level: 0.9)
        let before = graph(edges: [
            sendEdge(changedBefore, destination: "bus-1"),
            sendEdge(removed, destination: "bus-1"),
            sendEdge(unchanged, destination: "bus-1"),
        ])
        let after = graph(
            nodes: [trackNode, busNode(1), busNode(2)],
            edges: [
                sendEdge(changedAfter, destination: "bus-1"),
                sendEdge(added, destination: "bus-2"),
                sendEdge(unchanged, destination: "bus-1"),
            ]
        )

        let diff = routingDiff(before: before, after: after)

        #expect(diff.addedSends == [added])
        #expect(diff.removedSends == [removed])
        #expect(diff.changedSends == [SendChange(before: changedBefore, after: changedAfter)])
        #expect(diff.inputChanges.isEmpty)
        #expect(diff.outputChanges.isEmpty)
    }

    @Test func graphDiffDetectsInputAndOutputChanges() {
        let input = RoutingNode(id: "input-1", kind: .input, displayName: "Input 1", busNumber: nil, targetRef: nil)
        let outputA = RoutingNode(id: "output-1", kind: .output, displayName: "Stereo Out", busNumber: nil, targetRef: nil)
        let outputB = RoutingNode(id: "output-2", kind: .output, displayName: "Output 3-4", busNumber: nil, targetRef: nil)
        let beforeInput = assignment(.inputAssignment, source: "track-1", destination: "input-1")
        let beforeOutput = assignment(.mainOutput, source: "track-1", destination: "output-1")
        let afterOutput = assignment(.mainOutput, source: "track-1", destination: "output-2")
        let before = graph(nodes: [trackNode, input, outputA], edges: [beforeInput, beforeOutput])
        let after = graph(nodes: [trackNode, outputB], edges: [afterOutput])

        let diff = routingDiff(before: before, after: after)

        #expect(diff.inputChanges == [RoutingEdgeChange(before: beforeInput, after: nil)])
        #expect(diff.outputChanges == [RoutingEdgeChange(before: beforeOutput, after: afterOutput)])
    }

    @Test func routingGraphCodableRoundTrip() throws {
        let original = graph()
        let decoded = try JSONDecoder().decode(
            RoutingGraph.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }

    @Test func adr008FeatureFlagDefaultsToFalse() {
        let key = "LOGIC_MCP_ADR008_ROUTING_GRAPH"
        let previous = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        #expect(!FeatureFlags.adr008RoutingGraph)
    }

    private let projectRef = TargetReference(rawValue: "prj_test")
    private let sourceRef = TargetReference(rawValue: "trk_source")

    private var trackNode: RoutingNode {
        RoutingNode(id: "track-1", kind: .track, displayName: "Vocal", busNumber: nil, targetRef: sourceRef)
    }

    private func destinationRef(_ bus: Int) -> TargetReference {
        TargetReference(rawValue: "mix_bus_\(bus)")
    }

    private func busNode(_ bus: Int) -> RoutingNode {
        RoutingNode(
            id: "bus-\(bus)",
            kind: .bus,
            displayName: "Bus \(bus)",
            busNumber: bus,
            targetRef: destinationRef(bus)
        )
    }

    private func send(slot: Int, bus: Int, level: Double?) -> SendEdge {
        SendEdge(
            sourceTrackRef: sourceRef,
            physicalSlot: slot,
            destinationBusNumber: bus,
            destinationRef: destinationRef(bus),
            displayedName: "Bus \(bus)",
            level: level,
            mode: "post-fader",
            enabled: true
        )
    }

    private func sendEdge(_ send: SendEdge, destination: String) -> RoutingEdge {
        RoutingEdge(
            kind: .send,
            source: "track-1",
            destination: destination,
            send: send,
            provenance: .axMixerStrip
        )
    }

    private func assignment(
        _ kind: RoutingEdgeKind,
        source: String,
        destination: String
    ) -> RoutingEdge {
        RoutingEdge(
            kind: kind,
            source: source,
            destination: destination,
            send: nil,
            provenance: .axMixerStrip
        )
    }

    private func graph(
        complete: Bool = true,
        partialReason: String? = nil,
        nodes: [RoutingNode]? = nil,
        edges: [RoutingEdge]? = nil
    ) -> RoutingGraph {
        RoutingGraph(
            projectReference: projectRef,
            projectEpoch: 7,
            complete: complete,
            partialReason: partialReason,
            nodes: nodes ?? [trackNode, busNode(1)],
            edges: edges ?? [sendEdge(send(slot: 0, bus: 1, level: 0.5), destination: "bus-1")],
            provenance: [.axMixerStrip]
        )
    }

    private func request(
        physicalSlot: Int = 0,
        destinationBusNumber: Int? = 1,
        destinationRef: TargetReference? = TargetReference(rawValue: "mix_bus_1"),
        replaceExisting: Bool = false,
        expectedProjectEpoch: UInt64 = 7
    ) -> RoutingWriteRequest {
        RoutingWriteRequest(
            sourceTrackRef: sourceRef,
            physicalSlot: physicalSlot,
            destinationBusNumber: destinationBusNumber,
            destinationRef: destinationRef,
            replaceExisting: replaceExisting,
            expectedProjectEpoch: expectedProjectEpoch
        )
    }
}
