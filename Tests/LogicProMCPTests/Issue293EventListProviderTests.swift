import Foundation
import Testing
@testable import LogicProMCP

#if QUALIFICATION_FAULT_SEAM
@Suite struct Issue293EventListProviderTests {
    private static let region = MIDIRegionReference(
        targetRef: TargetReference(rawValue: "trk_issue_293"),
        regionIndex: 2
    )
    private static let identity = ResolvedRegionIdentity(
        name: "Issue 293 Region",
        ordinal: 2,
        startTick: 0
    )
    private static let positionColumn = AXColumnID(id: "position")
    private static let channelColumn = AXColumnID(id: "channel")
    private static let pitchColumn = AXColumnID(id: "pitch")
    private static let velocityColumn = AXColumnID(id: "velocity")
    private static let lengthColumn = AXColumnID(id: "length")

    private enum ProviderTestError: Error {
        case expectedProviderError
    }

    private static func rawRow(
        pitch: Double = 60,
        velocity: String = "100",
        channel: Double = 1,
        position: [Double] = [1, 1, 1, 1],
        length: [Double] = [0, 1, 0, 0]
    ) -> RawEventRow {
        [
            positionColumn: RawCell(groupSliderValues: position),
            channelColumn: RawCell(sliderValue: channel),
            pitchColumn: RawCell(sliderValue: pitch),
            velocityColumn: RawCell(valueDescription: velocity),
            lengthColumn: RawCell(groupSliderValues: length),
        ]
    }

    private static func completeFilter() -> FilterEvidence {
        FilterEvidence(checkboxes: [
            .init(id: "noteEvents", checked: true),
            .init(id: "programChange", checked: false),
            .init(id: "pitchBend", checked: false),
            .init(id: "controller", checked: false),
            .init(id: "aftertouch", checked: false),
            .init(id: "polyAftertouch", checked: false),
            .init(id: "systemExclusive", checked: false),
            .init(id: "additionalInfo", checked: false),
        ])
    }

    private static func evidence(
        rows: [RawEventRow],
        observedRegion: ObservedRegionIdentityProof = .proven(identity),
        itemCount: Int? = nil
    ) -> EventListReadbackEvidence {
        let keyedRows = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (RowKey(index: index), row)
        })
        return EventListReadbackEvidence(
            requestedRegion: region,
            resolvedIdentity: RegionIdentityRegistrySeam.mint(
                boundRegion: region,
                identity: identity
            ),
            observedRegion: observedRegion,
            projectEpochBefore: 17,
            projectEpochAfter: 17,
            ppq: 480,
            columnBinding: .headerIdentity(.proven([
                .position: positionColumn,
                .channel: channelColumn,
                .pitch: pitchColumn,
                .velocity: velocityColumn,
                .length: lengthColumn,
            ])),
            filter: completeFilter(),
            itemCount: ItemCountEvidence(
                rawCountText: "\(itemCount ?? rows.count) Events",
                semanticsProof: .provenAllEventsInRegion
            ),
            harvest: RowHarvest(
                orderedRowKeys: rows.indices.map(RowKey.init(index:)),
                passA: keyedRows,
                passB: keyedRows,
                exhaustion: .proven
            ),
            timing: .proven,
            calibration: CalibrationTriple(pitch: 60, velocity: 100, startTickValue: 1)
        )
    }

    private static func provider(
        returning evidence: EventListReadbackEvidence
    ) -> EventListMIDINoteReadbackProvider {
        EventListMIDINoteReadbackProvider { _, _ in evidence }
    }

    private static func thrownProviderError(
        for collectorError: EventListReadbackCollectorError
    ) async throws -> EventListMIDINoteReadbackProviderError {
        let provider = EventListMIDINoteReadbackProvider { _, _ in
            throw collectorError
        }
        do {
            _ = try await provider.readNotes(target: region, context: ReadbackContext())
        } catch let error as EventListMIDINoteReadbackProviderError {
            return error
        } catch {
            throw ProviderTestError.expectedProviderError
        }
        throw ProviderTestError.expectedProviderError
    }

    @Test func completeEvidenceProducesCompleteOrderedSnapshot() async throws {
        let rows = [
            Self.rawRow(),
            Self.rawRow(
                pitch: 64,
                velocity: "90",
                channel: 2,
                position: [1, 1, 1, 2],
                length: [0, 1, 0, 1]
            ),
        ]

        let snapshot = try await Self.provider(returning: Self.evidence(rows: rows)).readNotes(
            target: Self.region,
            context: ReadbackContext(localeIdentifier: "en_US", viewIdentifier: "event-list")
        )

        #expect(snapshot.complete)
        #expect(snapshot.provenance == MIDIReadbackProvenance.eventListAX)
        #expect(snapshot.notes == [
            MIDINoteEvent(
                pitch: 60,
                startTicks: 4,
                durationTicks: 1,
                velocity: 100,
                channel: 1
            ),
            MIDINoteEvent(
                pitch: 64,
                startTicks: 5,
                durationTicks: 2,
                velocity: 90,
                channel: 2
            ),
        ])
    }

    @Test func duplicateNotesArePreservedWithTheirCount() async throws {
        let duplicate = Self.rawRow()
        let snapshot = try await Self.provider(returning: Self.evidence(rows: [duplicate, duplicate])).readNotes(
            target: Self.region,
            context: ReadbackContext()
        )

        #expect(snapshot.complete)
        #expect(snapshot.notes.count == 2)
        #expect(snapshot.notes == [
            MIDINoteEvent(
                pitch: 60,
                startTicks: 4,
                durationTicks: 1,
                velocity: 100,
                channel: 1
            ),
            MIDINoteEvent(
                pitch: 60,
                startTicks: 4,
                durationTicks: 1,
                velocity: 100,
                channel: 1
            ),
        ])
    }

    @Test func partialEvidenceProducesIncompleteSnapshot() async throws {
        let partialEvidence = Self.evidence(
            rows: [Self.rawRow()],
            itemCount: 2
        )

        let snapshot = try await Self.provider(returning: partialEvidence).readNotes(
            target: Self.region,
            context: ReadbackContext()
        )

        #expect(!snapshot.complete)
        #expect(snapshot.noteCompleteness.partialReason == PartialReason.countMismatch)
        #expect(snapshot.notes.isEmpty)
    }

    @Test func collectorFailuresRemainTypedAndDistinct() async throws {
        let collectorErrors: [EventListReadbackCollectorError] = [
            .mainWindowUnavailable,
            .eventTabNotFound,
            .eventTabAmbiguous(count: 2),
            .eventTabStateUnavailable,
            .eventTabActivationFailed,
            .eventTableNotFound,
            .eventTableAmbiguous(count: 2),
            .headerUnavailable,
            .headerSortButtonsUnavailable,
            .paneAtRegionLevel,
            .headerMismatch(expected: "Val", actual: "Velocity"),
            .filterEvidenceIncomplete(title: "Notes"),
            .itemCountMissing,
            .regionPathMissing,
            .rowsUnavailable,
            .rowSelectionFailed(index: 3),
            .rowCellCountMismatch(row: 3, expected: 8, actual: 7),
            .cellChildCountMismatch(row: 3, column: "Val", actual: 2),
            .harvestIncomplete(populated: 4, total: 5, passes: 64),
            .displayModeUnavailable,
            .timeDisplayEnabled,
            .displayModeDisagreement(markedAsTime: true, positionsAreBBT: true),
        ]
        let expectedProviderErrors: [EventListMIDINoteReadbackProviderError] = [
            .mainWindowUnavailable,
            .eventTabNotFound,
            .eventTabAmbiguous(count: 2),
            .eventTabStateUnavailable,
            .eventTabActivationFailed,
            .eventTableNotFound,
            .eventTableAmbiguous(count: 2),
            .headerUnavailable,
            .headerSortButtonsUnavailable,
            .paneAtRegionLevel,
            .headerMismatch(expected: "Val", actual: "Velocity"),
            .filterEvidenceIncomplete(title: "Notes"),
            .itemCountMissing,
            .regionPathMissing,
            .rowsUnavailable,
            .rowSelectionFailed(index: 3),
            .rowCellCountMismatch(row: 3, expected: 8, actual: 7),
            .cellChildCountMismatch(row: 3, column: "Val", actual: 2),
            .harvestIncomplete(populated: 4, total: 5, passes: 64),
            .displayModeUnavailable,
            .timeDisplayEnabled,
            .displayModeDisagreement(markedAsTime: true, positionsAreBBT: true),
        ]

        var mappedErrors: [EventListMIDINoteReadbackProviderError] = []
        for collectorError in collectorErrors {
            mappedErrors.append(try await Self.thrownProviderError(for: collectorError))
        }

        #expect(mappedErrors == expectedProviderErrors)
        for index in mappedErrors.indices {
            for priorIndex in 0..<index {
                #expect(mappedErrors[index] != mappedErrors[priorIndex])
            }
        }
    }
}
#endif
