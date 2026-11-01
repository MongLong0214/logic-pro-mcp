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
            verificationRows: [Self.row()],
            firstRowCellChildren: ["Position": 4, "Ch": 1, "Num": 1, "Val": 1, "Length/Info": 4],
            rawItemCountText: "1 Event",
            rawRegionPath: "Selected MIDI"
        )

        let result = try SelectedRegionEventListReader.read(
            selection: { selection },
            collect: { observed }
        )

        #expect(result.selectedRegionObservation == Self.region)
        #expect(result.rawRows == [Self.row()])
        #expect(result.liveHeaderTitles == observed.liveHeaderTitles)
        #expect(result.rawItemCountText == "1 Event")
        #expect(result.rawRegionPath == "Selected MIDI")
        #expect(result.observedRowsContentStable)
        #expect(!result.canonicalNotesComplete)
        #expect(result.partialReason == .identityTimingAndTraversalUnproven)
        #expect(!result.writeAttempted)
        #expect(!result.rowSelectionWriteAttempted)
        #expect(result.rowSelectionRestored)
    }

    @Test func harvestedAttemptPublishesWriteAndRestoreTelemetryWithoutClaimingCompleteness() throws {
        let selection = SelectedRegionEventListReader.SelectionObservation(
            scopeComplete: true,
            selected: [Self.region]
        )
        let observed = EventListReadbackCollector.ProbeObservation(
            liveHeaderTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"],
            rows: [Self.row()],
            verificationRows: [Self.row()],
            firstRowCellChildren: [:],
            rawItemCountText: "1 Event",
            rawRegionPath: "Selected MIDI"
        )

        let result = try SelectedRegionEventListReader.read(
            selection: { selection },
            collectAttempt: {
                .init(
                    result: .success(observed),
                    rowSelectionWriteAttempted: true,
                    rowSelectionRestored: true
                )
            }
        )

        #expect(result.writeAttempted)
        #expect(result.rowSelectionWriteAttempted)
        #expect(result.rowSelectionRestored)
        #expect(!result.canonicalNotesComplete)
    }

    @Test func selectionDriftOverridesFailedHarvestAfterUnconditionalReadback() {
        var reads = 0
        let changed = SelectedRegionEventListReader.RegionIdentity(
            name: "Another MIDI Region",
            trackIndex: 4,
            startBar: 13,
            endBar: 16,
            kind: "midi"
        )

        do {
            _ = try SelectedRegionEventListReader.read(
                selection: {
                    defer { reads += 1 }
                    return .init(
                        scopeComplete: true,
                        selected: [reads == 0 ? Self.region : changed]
                    )
                },
                collectAttempt: {
                    .init(
                        result: .failure(EventListReadbackCollectorError.rowsUnavailable),
                        rowSelectionWriteAttempted: true,
                        rowSelectionRestored: true
                    )
                }
            )
            Issue.record("Expected the changed Arrange selection to refuse the partial read")
        } catch let failure as SelectedRegionEventListReader.ReadAttemptFailure {
            #expect(failure.refusal == .selectionChanged)
            #expect(failure.rowSelectionWriteAttempted)
            #expect(failure.rowSelectionRestored)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(reads == 2)
    }

    @Test func refusalJSONPreservesHarvestWriteAndRestoreTelemetry() throws {
        let failure = SelectedRegionEventListReader.ReadAttemptFailure(
            refusal: .eventListObservationUnavailable,
            rowSelectionWriteAttempted: true,
            rowSelectionRestored: false
        )

        let body = try #require(sharedJSONObject(
            SelectedRegionEventListReader.refusalJSON(failure)
        ))

        #expect(body["state"] as? String == "C")
        #expect(body["reason"] as? String == "event_list_observation_unavailable")
        #expect(try #require(body["write_attempted"] as? Bool))
        #expect(try #require(body["row_selection_write_attempted"] as? Bool))
        #expect(!(try #require(body["row_selection_restored"] as? Bool)))
    }

    @Test func rowContentDriftDuringCollectionRefuses() {
        let selection = SelectedRegionEventListReader.SelectionObservation(
            scopeComplete: true,
            selected: [Self.region]
        )
        let observed = EventListReadbackCollector.ProbeObservation(
            liveHeaderTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info"],
            rows: [Self.row(pitch: 60)],
            verificationRows: [Self.row(pitch: 61)],
            firstRowCellChildren: ["Position": 4, "Ch": 1, "Num": 1, "Val": 1, "Length/Info": 4],
            rawItemCountText: "1 Event",
            rawRegionPath: "Selected MIDI"
        )

        #expect(throws: SelectedRegionEventListReader.Refusal.eventRowsChanged) {
            _ = try SelectedRegionEventListReader.read(
                selection: { selection },
                collect: { observed }
            )
        }
        let refusal = sharedJSONObject(SelectedRegionEventListReader.refusalJSON(
            SelectedRegionEventListReader.Refusal.eventRowsChanged
        ))
        #expect(refusal?["reason"] as? String == "event_rows_changed_during_collection")
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
                    return .init(
                        liveHeaderTitles: [], rows: [], verificationRows: [], firstRowCellChildren: [:],
                        rawItemCountText: "0 Events", rawRegionPath: "Selected MIDI"
                    )
                }
            )
        }
        #expect(!collected)
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
                    return .init(
                        liveHeaderTitles: [], rows: [], verificationRows: [], firstRowCellChildren: [:],
                        rawItemCountText: "0 Events", rawRegionPath: "Selected MIDI"
                    )
                }
            )
        }
        #expect(!collected)
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
                    .init(
                        liveHeaderTitles: [], rows: [], verificationRows: [], firstRowCellChildren: [:],
                        rawItemCountText: "0 Events", rawRegionPath: "Selected MIDI"
                    )
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
            rawItemCountText: "1 Event",
            rawRegionPath: "Selected MIDI",
            observedRowsContentStable: true,
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

        let isError = try #require(result.isError as Bool?)
        #expect(!isError)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "B")
        #expect(body["reason"] as? String == "identity_timing_and_traversal_unproven")
        let canonicalNotesComplete = try #require(body["canonical_notes_complete"] as? Bool)
        let eventListOwnerProven = try #require(body["event_list_owner_proven"] as? Bool)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!canonicalNotesComplete)
        #expect(!eventListOwnerProven)
        #expect(!writeAttempted)
        let rowSelectionWriteAttempted = try #require(body["row_selection_write_attempted"] as? Bool)
        let rowSelectionRestored = try #require(body["row_selection_restored"] as? Bool)
        #expect(!rowSelectionWriteAttempted)
        #expect(rowSelectionRestored)
        #expect(body["event_list_item_count_text"] as? String == "1 Event")
        #expect(body["event_list_region_path"] as? String == "Selected MIDI")
        let observedRowsContentStable = try #require(body["observed_rows_content_stable"] as? Bool)
        #expect(observedRowsContentStable)
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
