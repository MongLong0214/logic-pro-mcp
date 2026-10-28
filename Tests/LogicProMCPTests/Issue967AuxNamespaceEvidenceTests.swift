import Testing
@testable import LogicProMCP

@Suite("#967 Aux namespace evidence")
struct Issue967AuxNamespaceEvidenceTests {
    private let project = TargetReference(rawValue: "prj_namespace")

    private func binding(snapshot: String = "snapshot_1", generation: UInt64 = 7) -> AuxNamespaceEvidence.Binding {
        .init(projectReference: project, projectEpoch: 3, snapshotID: snapshot,
              namespaceGeneration: generation)
    }

    private func consumer(_ id: String, bus: Int, kind: AuxNamespaceEvidence.Consumer.Kind = .auxReceiver,
                          hidden: Bool = false, mixerOnly: Bool = false,
                          sharedStrip: Bool = false, name: String = "Same") -> AuxNamespaceEvidence.Consumer {
        .init(id: id, targetReference: TargetReference(rawValue: "mix_\(id)"), busNumber: bus,
              kind: kind, displayName: name, hidden: hidden, mixerOnly: mixerOnly,
              sharedStrip: sharedStrip)
    }

    @Test func duplicateNamedHiddenSharedAndInstrumentConsumersAreRetainedDeterministically() throws {
        let expected = binding()
        let consumers = [
            consumer("instrument", bus: 3, kind: .instrumentMultiOutput),
            consumer("aux_b", bus: 3, sharedStrip: true),
            consumer("aux_a", bus: 3, hidden: true, mixerOnly: true),
        ]
        let snapshot = AuxNamespaceEvidence.Snapshot(
            binding: expected, namespaceAvailabilityComplete: true,
            consumerCoverageComplete: true, availableBusNumbers: [4, 5], consumers: consumers)

        let decision = AuxNamespaceEvidence.decision(for: 3, expected: expected, snapshot: snapshot)
        guard case .reuse(let reuse) = decision else {
            Issue.record("bus 3 should retain its exact Aux candidates and every other consumer")
            return
        }
        #expect(reuse.busNumber == 3)
        #expect(reuse.auxCandidates.map(\.id) == ["aux_a", "aux_b"])
        #expect(reuse.consumers.map(\.id) == ["aux_a", "aux_b", "instrument"])
        #expect(reuse.auxCandidates[0].hidden)
        #expect(reuse.auxCandidates[0].mixerOnly)
        #expect(reuse.auxCandidates[1].sharedStrip)
        #expect(reuse.consumers[2].kind == .instrumentMultiOutput)

        let reordered = AuxNamespaceEvidence.Snapshot(
            binding: expected, namespaceAvailabilityComplete: true,
            consumerCoverageComplete: true, availableBusNumbers: [5, 4],
            consumers: Array(consumers.reversed()))
        #expect(AuxNamespaceEvidence.decision(for: 3, expected: expected, snapshot: reordered) == decision)
    }

    @Test func completeEmptyAvailableBusProducesOnlyTheRequestedAllocation() throws {
        let expected = binding()
        let snapshot = AuxNamespaceEvidence.Snapshot(
            binding: expected, namespaceAvailabilityComplete: true,
            consumerCoverageComplete: true, availableBusNumbers: [3],
            consumers: [consumer("existing", bus: 4)])

        let decision = AuxNamespaceEvidence.decision(for: 3, expected: expected, snapshot: snapshot)
        guard case .allocate(let allocation) = decision else {
            Issue.record("bus 3 should be the one exact allocation")
            return
        }
        #expect(allocation.busNumber == 3)
        #expect(allocation.binding == expected)
    }

    @Test(arguments: [
        "project", "epoch", "snapshot", "namespace", "consumers", "duplicate_id",
        "duplicate_ref", "unavailable", "occupied_without_aux", "invalid_bus",
    ])
    func incompleteStaleOrAmbiguousEvidenceRefuses(_ fault: String) {
        let expected = binding()
        var actual = expected
        var namespaceComplete = true
        var consumersComplete = true
        var available = [3]
        var consumers: [AuxNamespaceEvidence.Consumer] = []
        var requestedBus = 3
        switch fault {
        case "project":
            actual = .init(projectReference: TargetReference(rawValue: "prj_other"), projectEpoch: 3,
                           snapshotID: "snapshot_1", namespaceGeneration: 7)
        case "epoch":
            actual = .init(projectReference: project, projectEpoch: 4,
                           snapshotID: "snapshot_1", namespaceGeneration: 7)
        case "snapshot":
            actual = binding(snapshot: "snapshot_2")
        case "namespace": namespaceComplete = false
        case "consumers": consumersComplete = false
        case "duplicate_id":
            consumers = [consumer("same", bus: 3), consumer("same", bus: 4)]
        case "duplicate_ref":
            consumers = [consumer("first", bus: 3), consumer("second", bus: 4)]
            consumers[1] = .init(id: "second", targetReference: consumers[0].targetReference,
                                 busNumber: 4, kind: .auxReceiver, displayName: "Same",
                                 hidden: false, mixerOnly: false, sharedStrip: false)
        case "unavailable": available = [4]
        case "occupied_without_aux":
            available = [4]
            consumers = [consumer("instrument", bus: 3, kind: .instrumentMultiOutput)]
        case "invalid_bus": requestedBus = 0
        default: break
        }
        let snapshot = AuxNamespaceEvidence.Snapshot(
            binding: actual, namespaceAvailabilityComplete: namespaceComplete,
            consumerCoverageComplete: consumersComplete, availableBusNumbers: available,
            consumers: consumers)

        guard case .unavailable(let reasons) = AuxNamespaceEvidence.decision(
            for: requestedBus, expected: expected, snapshot: snapshot
        ) else {
            Issue.record("fault \(fault) must remain unavailable")
            return
        }
        #expect(!reasons.isEmpty)
    }

    @Test func revalidationConflictNeverSubstitutesAnotherAvailableBus() throws {
        let previewBinding = binding()
        let preview = AuxNamespaceEvidence.Snapshot(
            binding: previewBinding, namespaceAvailabilityComplete: true,
            consumerCoverageComplete: true, availableBusNumbers: [3, 4], consumers: [])
        let planned = AuxNamespaceEvidence.decision(for: 3, expected: previewBinding, snapshot: preview)
        guard case .allocate = planned else {
            Issue.record("preview must allocate the explicitly requested bus")
            return
        }

        let currentBinding = binding(snapshot: "snapshot_2", generation: 8)
        let current = AuxNamespaceEvidence.Snapshot(
            binding: currentBinding, namespaceAvailabilityComplete: true,
            consumerCoverageComplete: true, availableBusNumbers: [4],
            consumers: [consumer("human_aux", bus: 3)])
        let result = AuxNamespaceEvidence.revalidate(
            planned, requestedBus: 3, expected: currentBinding, snapshot: current)
        guard case .conflict(let conflict) = result else {
            Issue.record("the previewed allocation must conflict after human occupation")
            return
        }
        #expect(conflict.requestedBus == 3)
        #expect(conflict.currentDecision != .allocate(.init(busNumber: 4, binding: currentBinding)))
    }
}
