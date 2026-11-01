import Foundation

/// Brackets the release-reachable, observation-only Event List probe with two complete reads of
/// the exact selected-region set. This deliberately returns raw rows only: timing, PPQ and full
/// virtualized traversal are not yet proved, so it cannot mint canonical notes or completeness.
enum SelectedRegionEventListReader {
    struct RegionIdentity: Equatable, Sendable {
        let name: String
        let trackIndex: Int
        let startBar: Int
        let endBar: Int
        let kind: String
    }

    struct SelectionObservation: Equatable, Sendable {
        let scopeComplete: Bool
        let selected: [RegionIdentity]
    }

    enum PartialReason: String, Equatable, Sendable {
        case identityTimingAndTraversalUnproven = "identity_timing_and_traversal_unproven"
    }

    struct PartialRead: Equatable, Sendable {
        /// The stable Arrange selection observed before and after collection. This is deliberately
        /// not named `region`: the current Event List pane's owner is still unproven.
        let selectedRegionObservation: RegionIdentity
        let rawRows: [RawEventRow]
        let liveHeaderTitles: [String]
        let rawItemCountText: String
        let rawRegionPath: String
        let observedRowsContentStable: Bool
        let canonicalNotesComplete: Bool
        let partialReason: PartialReason
        let writeAttempted: Bool
        let rowSelectionWriteAttempted: Bool
        let rowSelectionRestored: Bool

        init(
            selectedRegionObservation: RegionIdentity,
            rawRows: [RawEventRow],
            liveHeaderTitles: [String],
            rawItemCountText: String,
            rawRegionPath: String,
            observedRowsContentStable: Bool,
            canonicalNotesComplete: Bool,
            partialReason: PartialReason,
            writeAttempted: Bool,
            rowSelectionWriteAttempted: Bool? = nil,
            rowSelectionRestored: Bool? = nil
        ) {
            self.selectedRegionObservation = selectedRegionObservation
            self.rawRows = rawRows
            self.liveHeaderTitles = liveHeaderTitles
            self.rawItemCountText = rawItemCountText
            self.rawRegionPath = rawRegionPath
            self.observedRowsContentStable = observedRowsContentStable
            self.canonicalNotesComplete = canonicalNotesComplete
            self.partialReason = partialReason
            self.writeAttempted = writeAttempted
            self.rowSelectionWriteAttempted = rowSelectionWriteAttempted ?? writeAttempted
            self.rowSelectionRestored = rowSelectionRestored ?? !writeAttempted
        }
    }

    enum Refusal: Error, Equatable, Sendable {
        case selectionUnreadable
        case selectionScopeIncomplete
        case selectedRegionCount(Int)
        case selectionChanged
        case eventRowsChanged
        case eventListObservationUnavailable
    }

    struct ReadAttemptFailure: Error {
        let refusal: Refusal
        let rowSelectionWriteAttempted: Bool
        let rowSelectionRestored: Bool
    }

    static func readProduction(
        runtime: AXLogicProElements.Runtime = .production
    ) throws -> PartialRead {
        try read(
            selection: {
                guard let observation = AccessibilityChannel.selectedRegionObservation(runtime: runtime) else {
                    throw Refusal.selectionUnreadable
                }
                return observation
            },
            collectAttempt: { EventListReadbackCollector.observeHarvestedNoteTable(runtime: runtime) }
        )
    }

    static func read(
        selection: () throws -> SelectionObservation,
        collect: () throws -> EventListReadbackCollector.ProbeObservation
    ) throws -> PartialRead {
        let before = try selection()
        guard before.scopeComplete else { throw Refusal.selectionScopeIncomplete }
        guard before.selected.count == 1, let region = before.selected.first else {
            throw Refusal.selectedRegionCount(before.selected.count)
        }

        let observation = try collect()

        let after = try selection()
        guard after.scopeComplete else { throw Refusal.selectionScopeIncomplete }
        guard after.selected == [region] else { throw Refusal.selectionChanged }
        guard observation.rows == observation.verificationRows else {
            throw Refusal.eventRowsChanged
        }

        return PartialRead(
            selectedRegionObservation: region,
            rawRows: observation.rows,
            liveHeaderTitles: observation.liveHeaderTitles,
            rawItemCountText: observation.rawItemCountText,
            rawRegionPath: observation.rawRegionPath,
            observedRowsContentStable: true,
            canonicalNotesComplete: false,
            partialReason: .identityTimingAndTraversalUnproven,
            writeAttempted: false,
            rowSelectionWriteAttempted: false,
            rowSelectionRestored: true
        )
    }

    /// Production partial read. The Arrange selection is read after the collection attempt even
    /// when Event List harvesting failed, so selection drift cannot be hidden by the earlier error.
    static func read(
        selection: () throws -> SelectionObservation,
        collectAttempt: () -> EventListReadbackCollector.PartialProbeAttempt
    ) throws -> PartialRead {
        let before = try selection()
        guard before.scopeComplete else { throw Refusal.selectionScopeIncomplete }
        guard before.selected.count == 1, let region = before.selected.first else {
            throw Refusal.selectedRegionCount(before.selected.count)
        }

        let attempt = collectAttempt()
        let after: SelectionObservation
        do {
            after = try selection()
        } catch {
            throw ReadAttemptFailure(
                refusal: (error as? Refusal) ?? .selectionUnreadable,
                rowSelectionWriteAttempted: attempt.rowSelectionWriteAttempted,
                rowSelectionRestored: attempt.rowSelectionRestored
            )
        }
        guard after.scopeComplete else {
            throw ReadAttemptFailure(
                refusal: .selectionScopeIncomplete,
                rowSelectionWriteAttempted: attempt.rowSelectionWriteAttempted,
                rowSelectionRestored: attempt.rowSelectionRestored
            )
        }
        guard after.selected == [region] else {
            throw ReadAttemptFailure(
                refusal: .selectionChanged,
                rowSelectionWriteAttempted: attempt.rowSelectionWriteAttempted,
                rowSelectionRestored: attempt.rowSelectionRestored
            )
        }

        let observation: EventListReadbackCollector.ProbeObservation
        do {
            observation = try attempt.result.get()
        } catch {
            throw ReadAttemptFailure(
                refusal: .eventListObservationUnavailable,
                rowSelectionWriteAttempted: attempt.rowSelectionWriteAttempted,
                rowSelectionRestored: attempt.rowSelectionRestored
            )
        }
        guard observation.rows == observation.verificationRows else {
            throw ReadAttemptFailure(
                refusal: .eventRowsChanged,
                rowSelectionWriteAttempted: attempt.rowSelectionWriteAttempted,
                rowSelectionRestored: attempt.rowSelectionRestored
            )
        }

        return PartialRead(
            selectedRegionObservation: region,
            rawRows: observation.rows,
            liveHeaderTitles: observation.liveHeaderTitles,
            rawItemCountText: observation.rawItemCountText,
            rawRegionPath: observation.rawRegionPath,
            observedRowsContentStable: true,
            canonicalNotesComplete: false,
            partialReason: .identityTimingAndTraversalUnproven,
            writeAttempted: attempt.rowSelectionWriteAttempted,
            rowSelectionWriteAttempted: attempt.rowSelectionWriteAttempted,
            rowSelectionRestored: attempt.rowSelectionRestored
        )
    }

    static func responseJSON(_ result: PartialRead) -> String {
        let rows = result.rawRows.map { row in
            row.reduce(into: [String: Any]()) { output, entry in
                var cell: [String: Any] = [:]
                if let value = entry.value.sliderValue { cell["slider_value"] = value }
                if let description = entry.value.valueDescription {
                    cell["value_description"] = description
                }
                if let values = entry.value.groupSliderValues {
                    cell["group_slider_values"] = values
                }
                output[entry.key.id] = cell
            }
        }
        return HonestContract.jsonString([
            "success": true,
            "verified": false,
            "state": "B",
            "reason": result.partialReason.rawValue,
            "scope": "selected_region_and_unbound_event_list_observation",
            "selected_region_observation": [
                "name": result.selectedRegionObservation.name,
                "track_index": result.selectedRegionObservation.trackIndex,
                "start_bar": result.selectedRegionObservation.startBar,
                "end_bar": result.selectedRegionObservation.endBar,
                "kind": result.selectedRegionObservation.kind,
            ],
            "raw_rows": rows,
            "live_header_titles": result.liveHeaderTitles,
            "event_list_item_count_text": result.rawItemCountText,
            "event_list_region_path": result.rawRegionPath,
            "observed_rows_content_stable": result.observedRowsContentStable,
            "event_list_owner_proven": false,
            "canonical_notes_complete": result.canonicalNotesComplete,
            "write_attempted": result.writeAttempted,
            "row_selection_write_attempted": result.rowSelectionWriteAttempted,
            "row_selection_restored": result.rowSelectionRestored,
        ])
    }

    static func refusalJSON(_ error: Error) -> String {
        let attemptFailure = error as? ReadAttemptFailure
        let reportedError: Error = attemptFailure?.refusal ?? error
        let reason: String
        switch reportedError {
        case Refusal.selectionUnreadable:
            reason = "selection_unreadable"
        case Refusal.selectionScopeIncomplete:
            reason = "selection_scope_incomplete"
        case Refusal.selectedRegionCount:
            reason = "selected_region_count_not_one"
        case Refusal.selectionChanged:
            reason = "selection_changed_during_collection"
        case Refusal.eventRowsChanged:
            reason = "event_rows_changed_during_collection"
        case Refusal.eventListObservationUnavailable:
            reason = "event_list_observation_unavailable"
        default:
            reason = "event_list_observation_unavailable"
        }
        return HonestContract.jsonString([
            "success": false,
            "state": "C",
            "error": "selected_region_event_read_unavailable",
            "reason": reason,
            "write_attempted": attemptFailure?.rowSelectionWriteAttempted ?? false,
            "row_selection_write_attempted": attemptFailure?.rowSelectionWriteAttempted ?? false,
            "row_selection_restored": attemptFailure?.rowSelectionRestored ?? false,
        ])
    }
}
