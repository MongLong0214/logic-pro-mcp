import Foundation
import Testing
@testable import LogicProMCP

/// The rule that decides `sort_verified`'s verdict, and the one thing about it that had no test.
///
/// `trackSortAfterOrder` used to join the after-read to the before-read on `AXUIElement` identity.
/// It was `private` and took `[AXUIElement]`, so nothing in the deterministic suite could reach it;
/// every test above it passed while the join underneath returned the identity permutation for every
/// sort. Driven live on Logic Pro 12.3 (2026-09-03), that is exactly what live Logic produces: the
/// header objects stay at their rail positions and their CONTENT moves, so `CFEqual` matched
/// after[i] to before[i] on a sort that had visibly reordered the tracks.
///
/// These tests exist against values rather than element handles, which is the point of the change.
@Suite struct Issue448TrackSortAfterOrderTests {
    /// The live shape: the rows moved, so the references must move with them.
    @Test("a permuted after-read carries each reference to the row that now holds that track")
    func permutationCarriesReferences() throws {
        let order = AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Yankee", "Bravo", "Zulu"],
            beforeNames: ["Bravo", "Yankee", "Zulu"],
            beforeReferences: ["trk_bravo", "trk_yankee", "trk_zulu"]
        )
        let resolved = try #require(order)
        #expect(resolved == ["trk_yankee", "trk_bravo", "trk_zulu"])
    }

    /// The regression this file is named after. Under the old identity join this input produced
    /// `["trk_bravo", "trk_yankee", "trk_zulu"]` — the before-order, unchanged — because the element
    /// at each index was the same object before and after. Anything that returns the before-order
    /// for a moved list has reintroduced the defect.
    @Test("a sort that moved the rows does not answer with the before-order")
    func movedRowsDoNotAnswerWithBeforeOrder() throws {
        let before = ["trk_bravo", "trk_yankee", "trk_zulu"]
        let order = AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Yankee", "Bravo", "Zulu"],
            beforeNames: ["Bravo", "Yankee", "Zulu"],
            beforeReferences: before
        )
        let resolved = try #require(order)
        #expect(resolved != before)
    }

    /// An unmoved list is still an answer, and it is the before-order — the case the old join got
    /// right by accident and the new one has to keep getting right on purpose.
    @Test("an unmoved after-read answers with the same order")
    func unmovedListIsUnchanged() throws {
        let order = AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Alpha", "Bravo"],
            beforeNames: ["Alpha", "Bravo"],
            beforeReferences: ["trk_a", "trk_b"]
        )
        let resolved = try #require(order)
        #expect(resolved == ["trk_a", "trk_b"])
    }

    /// Names carry the join only because the operation has already refused a project whose names
    /// are not unique. If one reaches here that guard did not hold, and picking either reference
    /// would be a guess — so there is no order at all.
    @Test("duplicate names in the before-read produce no order rather than an arbitrary one")
    func duplicateBeforeNamesRefuse() {
        let order = AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Same", "Same"],
            beforeNames: ["Same", "Same"],
            beforeReferences: ["trk_1", "trk_2"]
        )
        #expect(order == nil)
    }

    @Test("a name that was not present before produces no order")
    func unknownAfterNameRefuses() {
        let order = AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Alpha", "Renamed"],
            beforeNames: ["Alpha", "Bravo"],
            beforeReferences: ["trk_a", "trk_b"]
        )
        #expect(order == nil)
    }

    @Test("a length disagreement between the two reads produces no order")
    func lengthMismatchRefuses() {
        #expect(AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Alpha"],
            beforeNames: ["Alpha", "Bravo"],
            beforeReferences: ["trk_a", "trk_b"]
        ) == nil)
        #expect(AccessibilityChannel.trackSortAfterOrder(
            afterNames: ["Alpha", "Bravo"],
            beforeNames: ["Alpha", "Bravo"],
            beforeReferences: ["trk_a"]
        ) == nil)
    }
}
