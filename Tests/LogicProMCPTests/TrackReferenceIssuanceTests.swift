import Foundation
import Testing
@testable import LogicProMCP

/// #291 R0: the one issuance path both `logic://tracks` and `logic://mixer` use.
@Suite("#291 track reference issuance")
struct TrackReferenceIssuanceTests {
    @Test("a snapshot captured before a topology bump issues nothing")
    func aStaleSnapshotIssuesNothing() async {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        await registry.bumpTopologyGeneration()

        let issued = await TrackReferenceIssuance.issue(
            for: [TrackState(id: 0, name: "Source", type: .audio)],
            registry: registry,
            snapshot: snapshot
        )

        #expect(issued == nil)
    }

    @Test("two issues over the same rows in one snapshot return the same references")
    func theSameObservedRowIssuesTheSameReference() async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let inventory = [
            TrackState(id: 0, name: "Source", type: .audio),
            TrackState(id: 1, name: "Destination", type: .audio),
        ]

        let first = try #require(await TrackReferenceIssuance.issue(for: inventory, registry: registry, snapshot: snapshot))
        let second = try #require(await TrackReferenceIssuance.issue(for: inventory, registry: registry, snapshot: snapshot))

        #expect(first.byRow == second.byRow)
        #expect(first.byTrackIndex == second.byTrackIndex)
        #expect(first.byTrackIndex.count == 2)
        for (index, reference) in first.byTrackIndex {
            let binding = try #require(await registry.resolve(reference))
            #expect(binding.kind == .track)
            #expect(binding.descriptor == TargetDescriptor(trackIndex: index, trackName: inventory[index].name))
        }
    }

    @Test("a duplicated id is ambiguous: each row keeps its own reference but the id joins none")
    func aDuplicatedIdIsAmbiguous() async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let inventory = [
            TrackState(id: 0, name: "First", type: .audio),
            TrackState(id: 0, name: "Second", type: .audio),
            TrackState(id: 1, name: "Unique", type: .audio),
        ]

        let issued = try #require(await TrackReferenceIssuance.issue(for: inventory, registry: registry, snapshot: snapshot))

        #expect(issued.byRow.count == 3)
        #expect(issued.byRow.allSatisfy { $0 != nil })
        #expect(issued.byRow[0] != issued.byRow[1])
        #expect(issued.byTrackIndex[0] == nil)
        #expect(issued.byTrackIndex[1] == issued.byRow[2])
        #expect(issued.ambiguousTrackIndices == [0])
    }

    @Test("placeholder and non-live rows are ineligible and issue nothing")
    func ineligibleRowsIssueNothing() async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let inventory = [
            TrackState(id: 0, name: "Track 1", type: .unknown, placeholder: true),
            TrackState(id: 1, name: "Untitled", type: .unknown, liveIdentityBacked: false),
            TrackState(id: 2, name: "Live", type: .audio),
        ]

        let issued = try #require(await TrackReferenceIssuance.issue(for: inventory, registry: registry, snapshot: snapshot))

        #expect(!TrackReferenceIssuance.isEligible(inventory[0]))
        #expect(!TrackReferenceIssuance.isEligible(inventory[1]))
        #expect(TrackReferenceIssuance.isEligible(inventory[2]))
        #expect(issued.byRow[0] == nil)
        #expect(issued.byRow[1] == nil)
        #expect(issued.byRow[2] != nil)
        #expect(Set(issued.byTrackIndex.keys) == [2])
        #expect(issued.ambiguousTrackIndices.isEmpty)
    }

    @Test("an inspector-contaminated inventory is dropped; a single colon-suffixed name is not")
    func inspectorContaminationDropsTheInventory() {
        let contaminated = [
            TrackState(id: 0, name: "Region:", type: .unknown),
            TrackState(id: 1, name: "Track:", type: .unknown),
            TrackState(id: 2, name: "Channel Strip:", type: .unknown),
        ]
        let legitimate = [
            TrackState(id: 0, name: "MyMix:", type: .audio),
            TrackState(id: 1, name: "Bass", type: .audio),
        ]

        #expect(TrackReferenceIssuance.isInspectorContaminated(contaminated))
        #expect(TrackReferenceIssuance.liveInventory(contaminated).isEmpty)
        #expect(!TrackReferenceIssuance.isInspectorContaminated(legitimate))
        #expect(TrackReferenceIssuance.liveInventory(legitimate).map(\.name) == ["MyMix:", "Bass"])
    }
}
