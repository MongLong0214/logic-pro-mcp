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
        let canonicalNotesComplete: Bool
        let partialReason: PartialReason
        let writeAttempted: Bool
    }

    enum Refusal: Error, Equatable, Sendable {
        case selectionUnreadable
        case selectionScopeIncomplete
        case selectedRegionCount(Int)
        case selectionChanged
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
            collect: { try EventListReadbackCollector.observeNoteTable(runtime: runtime) }
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

        return PartialRead(
            selectedRegionObservation: region,
            rawRows: observation.rows,
            liveHeaderTitles: observation.liveHeaderTitles,
            rawItemCountText: observation.rawItemCountText,
            rawRegionPath: observation.rawRegionPath,
            canonicalNotesComplete: false,
            partialReason: .identityTimingAndTraversalUnproven,
            writeAttempted: false
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
            "event_list_owner_proven": false,
            "canonical_notes_complete": result.canonicalNotesComplete,
            "write_attempted": result.writeAttempted,
        ])
    }

    static func refusalJSON(_ error: Error) -> String {
        let reason: String
        switch error {
        case Refusal.selectionUnreadable:
            reason = "selection_unreadable"
        case Refusal.selectionScopeIncomplete:
            reason = "selection_scope_incomplete"
        case Refusal.selectedRegionCount:
            reason = "selected_region_count_not_one"
        case Refusal.selectionChanged:
            reason = "selection_changed_during_collection"
        default:
            reason = "event_list_observation_unavailable"
        }
        return HonestContract.jsonString([
            "success": false,
            "state": "C",
            "error": "selected_region_event_read_unavailable",
            "reason": reason,
            "write_attempted": false,
        ])
    }
}
