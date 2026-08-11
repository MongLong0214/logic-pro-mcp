import Foundation

/// Bridges Event List AX evidence into the shared MIDI note readback contract.
///
/// This adapter owns neither parsing nor completeness: `assessReadback` remains
/// the single sealed conversion chokepoint. Its closure initializer keeps the
/// live collector independently testable while the parameterized initializer
/// below calls `EventListReadbackCollector` directly.
struct EventListMIDINoteReadbackProvider: MIDINoteReadbackProvider {
    typealias Collector = @Sendable (
        _ target: MIDIRegionReference,
        _ context: ReadbackContext
    ) async throws -> EventListReadbackEvidence

    let provenance: MIDIReadbackProvenance = .eventListAX
    private let collector: Collector

    init(collector: @escaping Collector) {
        self.collector = collector
    }

    init(
        resolvedIdentity: RegistryResolvedIdentityProof,
        projectEpochBefore: UInt64,
        projectEpochAfter: UInt64,
        ppq: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) {
        self.collector = { target, _ in
            try EventListReadbackCollector.collect(
                requestedRegion: target,
                resolvedIdentity: resolvedIdentity,
                projectEpochBefore: projectEpochBefore,
                projectEpochAfter: projectEpochAfter,
                ppq: ppq,
                runtime: runtime
            )
        }
    }

    func readNotes(
        target: MIDIRegionReference,
        context: ReadbackContext
    ) async throws -> MIDIRegionNoteSnapshot {
        do {
            // Do not canonicalize or otherwise collapse this list here. The
            // assessment preserves harvested row order and multiplicity, which
            // lets a later diff distinguish a duplicated write from one note.
            return assessReadback(try await collector(target, context))
        } catch let error as EventListReadbackCollectorError {
            throw EventListMIDINoteReadbackProviderError(collectorError: error)
        }
    }
}

/// Provider-facing failures preserve the collector's individual recovery
/// semantics. In particular, a caller can navigate away from
/// `paneAtRegionLevel`, whereas `headerMismatch` is a Logic-layout drift that
/// must not be treated as a recoverable short read.
enum EventListMIDINoteReadbackProviderError: Error, Equatable, Sendable {
    case mainWindowUnavailable
    case eventTabNotFound
    case eventTabAmbiguous(count: Int)
    case eventTabStateUnavailable
    case eventTabActivationFailed
    case eventTableNotFound
    case eventTableAmbiguous(count: Int)
    case headerUnavailable
    case headerSortButtonsUnavailable
    case paneAtRegionLevel
    case headerMismatch(expected: String, actual: String?)
    case filterEvidenceIncomplete(title: String)
    case itemCountMissing
    case regionPathMissing
    case rowsUnavailable
    case rowSelectionFailed(index: Int)
    case rowCellCountMismatch(row: Int, expected: Int, actual: Int)
    case cellChildCountMismatch(row: Int, column: String, actual: Int)
    case harvestIncomplete(populated: Int, total: Int, passes: Int)
    case displayModeUnavailable
    case timeDisplayEnabled
    case displayModeDisagreement(markedAsTime: Bool, positionsAreBBT: Bool)

    init(collectorError: EventListReadbackCollectorError) {
        switch collectorError {
        case .mainWindowUnavailable:
            self = .mainWindowUnavailable
        case .eventTabNotFound:
            self = .eventTabNotFound
        case let .eventTabAmbiguous(count):
            self = .eventTabAmbiguous(count: count)
        case .eventTabStateUnavailable:
            self = .eventTabStateUnavailable
        case .eventTabActivationFailed:
            self = .eventTabActivationFailed
        case .eventTableNotFound:
            self = .eventTableNotFound
        case let .eventTableAmbiguous(count):
            self = .eventTableAmbiguous(count: count)
        case .headerUnavailable:
            self = .headerUnavailable
        case .headerSortButtonsUnavailable:
            self = .headerSortButtonsUnavailable
        case .paneAtRegionLevel:
            self = .paneAtRegionLevel
        case let .headerMismatch(expected, actual):
            self = .headerMismatch(expected: expected, actual: actual)
        case let .filterEvidenceIncomplete(title):
            self = .filterEvidenceIncomplete(title: title)
        case .itemCountMissing:
            self = .itemCountMissing
        case .regionPathMissing:
            self = .regionPathMissing
        case .rowsUnavailable:
            self = .rowsUnavailable
        case let .rowSelectionFailed(index):
            self = .rowSelectionFailed(index: index)
        case let .rowCellCountMismatch(row, expected, actual):
            self = .rowCellCountMismatch(row: row, expected: expected, actual: actual)
        case let .cellChildCountMismatch(row, column, actual):
            self = .cellChildCountMismatch(row: row, column: column, actual: actual)
        case let .harvestIncomplete(populated, total, passes):
            self = .harvestIncomplete(populated: populated, total: total, passes: passes)
        case .displayModeUnavailable:
            self = .displayModeUnavailable
        case .timeDisplayEnabled:
            self = .timeDisplayEnabled
        case let .displayModeDisagreement(markedAsTime, positionsAreBBT):
            self = .displayModeDisagreement(
                markedAsTime: markedAsTime,
                positionsAreBBT: positionsAreBBT
            )
        }
    }
}
