import ApplicationServices
import Foundation

// Logic's own Navigate > Create Marker makes the new marker the selection, and that clears the
// Arrange region selection. Measured on Logic 13 (Korean UI) with one MIDI region selected: the
// menu command alone, with the Marker List closed, leaves no region selected; activating Logic,
// and opening and closing the Marker List, each leave it selected. `nav.create_marker` was asked to
// create a marker. The region selection is the user's, and the next region operation acts on it,
// so the operation reads it before the press and writes it back after.
//
// An AXSelected write on an Arrange region TOGGLES it (measured: writing true to a selected region
// deselected it). So a region is written only when it reads unselected, and only when the
// selection the press left is empty: a different selection cannot be put back by toggles that are
// each justified on their own.

extension AccessibilityChannel {
    /// What the restore did, carried in the reply as `region_selection`.
    enum RegionSelectionRestoreOutcome: String, Sendable, Equatable {
        /// The selection could not be read before the press, so nothing is known to put back and
        /// nothing was written.
        case beforeUnread = "before_unread"
        /// The selection after the press equals the one before it. Nothing was written.
        case unchanged
        /// The prior selection was written back and read back equal.
        case restored
        /// The prior selection is not what the Arrange area reads now.
        case notRestored = "not_restored"
        /// The visible selection reads back equal, but at least one read did not cover the whole
        /// arrangement, so regions outside it are not accounted for.
        case scopeIncomplete = "scope_incomplete"
    }

    /// One read of the Arrange regions and their AXSelected flags.
    struct RegionSelectionReading<Item> {
        let scopeComplete: Bool
        let regions: [(item: Item, info: RegionInfo, selected: Bool)]
    }

    /// The identity a region is matched by across two reads. AX elements are not reused across a
    /// redraw, so the element read before the press is not trusted after it.
    struct RegionSelectionKey: Hashable, Comparable {
        let name: String
        let trackIndex: Int
        let startBar: Int
        let endBar: Int
        let kind: String

        init(_ info: RegionInfo) {
            name = info.name
            trackIndex = info.trackIndex
            startBar = info.startBar
            endBar = info.endBar
            kind = info.kind
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.trackIndex, lhs.startBar, lhs.endBar, lhs.name, lhs.kind)
                < (rhs.trackIndex, rhs.startBar, rhs.endBar, rhs.name, rhs.kind)
        }
    }

    /// Put back the region selection `before` read, verifying it by a fresh read.
    ///
    /// Every target is resolved before any write: a selected identity that does not match exactly
    /// one unselected region now is refused with nothing written, because a partial restore cannot
    /// be told apart from the selection the user had.
    static func restoreRegionSelection<Item>(
        before: RegionSelectionReading<Item>?,
        read: () -> RegionSelectionReading<Item>?,
        select: (Item) -> Bool,
        settle: () -> Void
    ) -> RegionSelectionRestoreOutcome {
        guard let before else { return .beforeUnread }
        func keys(_ reading: RegionSelectionReading<Item>) -> [RegionSelectionKey] {
            reading.regions.filter(\.selected).map { RegionSelectionKey($0.info) }.sorted()
        }
        func verdict(_ after: RegionSelectionReading<Item>, wrote: Bool) -> RegionSelectionRestoreOutcome {
            guard keys(after) == keys(before) else { return .notRestored }
            guard before.scopeComplete, after.scopeComplete else { return .scopeIncomplete }
            return wrote ? .restored : .unchanged
        }
        guard let now = read() else { return .notRestored }
        let wanted = keys(before)
        if keys(now) == wanted { return verdict(now, wrote: false) }
        guard keys(now).isEmpty else { return .notRestored }

        var targets: [Item] = []
        for key in Set(wanted) {
            let candidates = now.regions.filter { RegionSelectionKey($0.info) == key }
            guard candidates.count == wanted.filter({ $0 == key }).count,
                  candidates.allSatisfy({ !$0.selected }) else { return .notRestored }
            targets.append(contentsOf: candidates.map(\.item))
        }
        for target in targets { _ = select(target) }
        settle()
        guard let after = read() else { return .notRestored }
        return verdict(after, wrote: true)
    }

    /// The production read: the product's region enumeration and each region's AXSelected. An
    /// AXSelected read that fails for any reason other than a definitive absence makes the whole
    /// read unreadable; an unread flag is not "not selected".
    static func regionSelectionReading(
        runtime: AXLogicProElements.Runtime
    ) -> RegionSelectionReading<AXUIElement>? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime) else { return nil }
        var regions: [(item: AXUIElement, info: RegionInfo, selected: Bool)] = []
        for entry in result.regions {
            let read: Result<NSNumber?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                entry.item, kAXSelectedAttribute, runtime: runtime.ax
            )
            switch read {
            case .success(let flag):
                regions.append((entry.item, entry.info, flag?.boolValue == true))
            case .failure(let error) where error.isDefinitiveAbsence:
                regions.append((entry.item, entry.info, false))
            case .failure:
                return nil
            }
        }
        return RegionSelectionReading(scopeComplete: result.coversWholeArrangement, regions: regions)
    }
}
