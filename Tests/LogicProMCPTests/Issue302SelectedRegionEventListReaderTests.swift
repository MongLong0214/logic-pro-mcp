@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite struct Issue302SelectedRegionEventListReaderTests {
    private static let region = SelectedRegionEventListReader.RegionIdentity(
        name: "Selected MIDI",
        trackIndex: 3,
        startBar: 9,
        endBar: 12,
        kind: "midi"
    )

    private static let position = AXColumnID(id: "Position")
    private static let channel = AXColumnID(id: "Ch")
    private static let number = AXColumnID(id: "Num")
    private static let value = AXColumnID(id: "Val")
    private static let length = AXColumnID(id: "Length/Info")

    private static func row(pitch: Double = 60) -> RawEventRow {
        [
            position: RawCell(groupSliderValues: [9, 1, 1, 1]),
            channel: RawCell(sliderValue: 1),
            number: RawCell(sliderValue: pitch),
            value: RawCell(valueDescription: "100"),
            length: RawCell(groupSliderValues: [0, 1, 0, 0]),
        ]
    }

    @Test func stableSingleSelectionReturnsOnlyPartialRawRows() throws {
        let selection = SelectedRegionEventListReader.SelectionObservation(
            scopeComplete: true,
            selected: [Self.region]
        )
        let observed = EventListReadbackCollector.ProbeObservation(
            liveHeaderTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"],
            rows: [Self.row()],
            firstRowCellChildren: ["Position": 4, "Ch": 1, "Num": 1, "Val": 1, "Length/Info": 4]
        )

        let result = try SelectedRegionEventListReader.read(
            selection: { selection },
            collect: { observed }
        )

        #expect(result.selectedRegionObservation == Self.region)
        #expect(result.rawRows == [Self.row()])
        #expect(result.liveHeaderTitles == observed.liveHeaderTitles)
        #expect(result.canonicalNotesComplete == false)
        #expect(result.partialReason == .identityTimingAndTraversalUnproven)
        #expect(result.writeAttempted == false)
    }

    @Test func incompleteSelectionScopeRefusesBeforeCollection() {
        var collected = false

        #expect(throws: SelectedRegionEventListReader.Refusal.selectionScopeIncomplete) {
            _ = try SelectedRegionEventListReader.read(
                selection: {
                    .init(scopeComplete: false, selected: [Self.region])
                },
                collect: {
                    collected = true
                    return .init(liveHeaderTitles: [], rows: [], firstRowCellChildren: [:])
                }
            )
        }
        #expect(collected == false)
    }

    @Test func nonUniqueSelectionRefusesBeforeCollection() {
        var collected = false

        #expect(throws: SelectedRegionEventListReader.Refusal.selectedRegionCount(2)) {
            _ = try SelectedRegionEventListReader.read(
                selection: {
                    .init(scopeComplete: true, selected: [Self.region, Self.region])
                },
                collect: {
                    collected = true
                    return .init(liveHeaderTitles: [], rows: [], firstRowCellChildren: [:])
                }
            )
        }
        #expect(collected == false)
    }

    @Test func selectionDriftDuringCollectionRefuses() {
        var reads = 0
        let changed = SelectedRegionEventListReader.RegionIdentity(
            name: "Another MIDI Region",
            trackIndex: 4,
            startBar: 13,
            endBar: 16,
            kind: "midi"
        )

        #expect(throws: SelectedRegionEventListReader.Refusal.selectionChanged) {
            _ = try SelectedRegionEventListReader.read(
                selection: {
                    defer { reads += 1 }
                    return .init(
                        scopeComplete: true,
                        selected: [reads == 0 ? Self.region : changed]
                    )
                },
                collect: {
                    .init(liveHeaderTitles: [], rows: [], firstRowCellChildren: [:])
                }
            )
        }
        #expect(reads == 2)
    }

    @Test func axSelectionObservationCarriesMeasuredCoverageAndExactIdentity() throws {
        let builder = FakeAXRuntimeBuilder()
        let selectedItem = builder.element(302_001)
        builder.setAttribute(selectedItem, kAXSelectedAttribute as String, true)
        let info = RegionInfo(
            name: Self.region.name,
            trackIndex: Self.region.trackIndex,
            startBar: Self.region.startBar,
            endBar: Self.region.endBar,
            kind: Self.region.kind,
            rawHelp: "measured fixture"
        )
        let enumeration = AccessibilityChannel.RegionEnumerationResult(
            regions: [(selectedItem, info)],
            layoutItemCount: 1,
            nonRegionCount: 0,
            trackHeaderCount: 4,
            trackHeadersWithinViewport: 4,
            regionItemsOutsideViewport: 0,
            trackHeadersWithStackVisibilityGaps: 0
        )

        let observed = try #require(AccessibilityChannel.selectedRegionObservation(
            from: enumeration,
            runtime: builder.makeAXRuntime()
        ))

        #expect(observed.scopeComplete)
        #expect(observed.selected == [Self.region])
    }

    @Test func logicMIDIPublishesTheReachablePartialReadContract() async throws {
        let partial = SelectedRegionEventListReader.PartialRead(
            selectedRegionObservation: Self.region,
            rawRows: [Self.row()],
            liveHeaderTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"],
            canonicalNotesComplete: false,
            partialReason: .identityTimingAndTraversalUnproven,
            writeAttempted: false
        )

        let result = await MIDIDispatcher.handle(
            command: "read_selected_region_events",
            params: [:],
            router: ChannelRouter(),
            cache: StateCache(),
            selectedRegionEventRead: { partial }
        )

        #expect(result.isError == false)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "B")
        #expect(body["reason"] as? String == "identity_timing_and_traversal_unproven")
        #expect(body["canonical_notes_complete"] as? Bool == false)
        #expect(body["event_list_owner_proven"] as? Bool == false)
        #expect(body["write_attempted"] as? Bool == false)
        #expect(body["region"] == nil)
        let region = try #require(body["selected_region_observation"] as? [String: Any])
        #expect(region["name"] as? String == Self.region.name)
        #expect(region["track_index"] as? Int == Self.region.trackIndex)
        let rows = try #require(body["raw_rows"] as? [[String: Any]])
        let first = try #require(rows.first)
        let pitch = try #require(first["Num"] as? [String: Any])
        #expect(pitch["slider_value"] as? Double == 60)

        let spec = try #require(OperationRegistry.spec(
            tool: "logic_midi",
            command: "read_selected_region_events"
        ))
        #expect(spec.id == .midiReadSelectedRegionEvents)
        #expect(spec.mutability == .readOnly)
        #expect(spec.verification == .none)
        #expect(spec.allowedParams.isEmpty)
    }
}
