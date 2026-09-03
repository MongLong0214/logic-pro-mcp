import Foundation
import Testing
@testable import LogicProMCP

/// The rule that decides when the post-sort arrangement has settled.
///
/// It used to live inside a polling loop, take its first read with no delay, and accept the first
/// pair of equal observations. A sort landing slower than the poll therefore had its own PRE-sort
/// order accepted as settled — measured live on 2026-09-03, one drive in five under load, producing
/// a receipt whose `after_tracks` were sorted beside an `after_order` that was not, because the two
/// halves came from different reads.
///
/// What makes the corrected rule decidable is upstream: `TrackSortVerifier.execute` refuses
/// `beforeOrder == expectedOrder` as `alreadySortedCommandUnobservable`, so wherever State A is
/// reachable at all the arrangement must move.
@Suite struct Issue757SettleWitnessTests {
    private let before = ["trk_a", "trk_b", "trk_c"]
    private let moved = ["trk_c", "trk_a", "trk_b"]

    /// The regression. Two immediate equal reads of the unchanged order are what the old rule
    /// accepted, and accepting them is what reported a pre-sort order as settled.
    @Test("two equal reads of the unchanged order are not settled")
    func unchangedOrderIsNeverSettled() {
        #expect(!AccessibilityChannel.trackSortObservationIsSettled(
            current: before, previous: before, before: before
        ))
    }

    @Test("a moved order needs a second agreeing read before it counts")
    func movedOrderNeedsTwoReads() {
        #expect(!AccessibilityChannel.trackSortObservationIsSettled(
            current: moved, previous: nil, before: before
        ))
        #expect(!AccessibilityChannel.trackSortObservationIsSettled(
            current: moved, previous: before, before: before
        ))
    }

    @Test("a moved order observed twice in a row is settled")
    func movedOrderObservedTwiceIsSettled() {
        #expect(AccessibilityChannel.trackSortObservationIsSettled(
            current: moved, previous: moved, before: before
        ))
    }

    /// Mid-flight disagreement is not settled either — the rail can be read while Logic is still
    /// rewriting it, and two different partial orders must not be mistaken for a result.
    @Test("two different observations are not settled")
    func disagreeingObservationsAreNotSettled() {
        #expect(!AccessibilityChannel.trackSortObservationIsSettled(
            current: moved, previous: ["trk_b", "trk_c", "trk_a"], before: before
        ))
    }

    /// The rule is about the ORDER, not about how far it moved: any arrangement that is not the
    /// pre-sort one is eligible, including one the caller did not ask for. Deciding whether it is
    /// the RIGHT order belongs to `TrackSortVerifier.execute`, which compares it with
    /// `expectedOrder` and answers `afterOrderMismatch`. Settling here on a wrong order is what
    /// lets that mismatch be reported at all.
    @Test("an unexpected but changed order is settled, and left for the verifier to reject")
    func wrongOrderStillSettles() {
        let unexpected = ["trk_b", "trk_a", "trk_c"]
        #expect(AccessibilityChannel.trackSortObservationIsSettled(
            current: unexpected, previous: unexpected, before: before
        ))
    }
}
