import Foundation
import Testing
@testable import LogicProMCP

/// ADR-006's commit rule has four conditions; `StateCache.accepts` implemented two of them
/// (project epoch, section revision). These cover the third: **source priority**.
///
/// The race the ADR names is not hypothetical. Two refreshes capture the same version and both
/// try to commit; the compare-and-swap lets whichever arrives first win, regardless of which one
/// is authoritative. `Issue289StaleRefreshTests.concurrentWritesFromSameObservationAllowOnlyOne`
/// asserted exactly that with `tempo == 101 || tempo == 202`. When the winner is a slow background
/// poll, a mutation verification's fresher read is thrown away — the ADR's
/// *"slow background polls must not overwrite mutation verification"*, inverted.
@Suite("Issue289RefreshPriority")
struct Issue289RefreshPriorityTests {

    @Test("a background poll cannot bury a mutation verification that observed the same revision")
    func mutationVerificationDisplacesABackgroundPollFromTheSameObservation() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        // The background poll wins the race to the actor and commits first.
        let pollApplied = await cache.updateTransport(
            transport(tempo: 90),
            ifCurrent: observed,
            source: .backgroundPoll
        )
        #expect(pollApplied)

        // The mutation verification started from the SAME observation and is strictly more
        // authoritative. Under a bare CAS it is refused and its value is lost.
        let verifyApplied = await cache.updateTransport(
            transport(tempo: 140),
            ifCurrent: observed,
            source: .mutationVerification
        )

        #expect(verifyApplied)
        #expect((await cache.getTransport()).tempo == 140)
    }

    @Test("the displacement is one-directional — a poll cannot overwrite a verification")
    func backgroundPollCannotDisplaceAMutationVerification() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        #expect(await cache.updateTransport(
            transport(tempo: 140), ifCurrent: observed, source: .mutationVerification
        ))

        let pollApplied = await cache.updateTransport(
            transport(tempo: 90), ifCurrent: observed, source: .backgroundPoll
        )

        #expect(!pollApplied)
        #expect((await cache.getTransport()).tempo == 140)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    @Test("equal priority keeps first-writer-wins — displacement needs a strictly higher rank")
    func equalPriorityDoesNotDisplace() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        #expect(await cache.updateTransport(
            transport(tempo: 90), ifCurrent: observed, source: .backgroundPoll
        ))
        let second = await cache.updateTransport(
            transport(tempo: 91), ifCurrent: observed, source: .backgroundPoll
        )

        #expect(!second)
        #expect((await cache.getTransport()).tempo == 90)
    }

    @Test("a higher-priority commit in the gap blocks displacement, even behind a lower one")
    func aHigherPriorityCommitInTheGapIsNotDiscarded() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        // Explicit read commits first, then a background poll lands on top of it.
        #expect(await cache.updateTransport(
            transport(tempo: 120), ifCurrent: observed, source: .explicitRead
        ))
        let afterRead = await cache.currentVersion(for: .transport)
        #expect(await cache.updateTransport(
            transport(tempo: 90), ifCurrent: afterRead, source: .backgroundPoll
        ))

        // A subscription refresh outranks the poll but NOT the explicit read it would erase.
        let applied = await cache.updateTransport(
            transport(tempo: 70), ifCurrent: observed, source: .subscription
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 90)
    }

    @Test("a stale project epoch still refuses, priority cannot override it")
    func priorityDoesNotOverrideAStaleProjectEpoch() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        await cache.advanceProjectEpoch()

        let applied = await cache.updateTransport(
            transport(tempo: 140), ifCurrent: observed, source: .mutationVerification
        )

        #expect(!applied)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
    }

    /// The previous epoch test never reached the displacement branch: it advanced the epoch
    /// without advancing the section revision, so the gap was empty and the branch returned early.
    /// Deleting the epoch guard from that branch changed nothing and no test noticed. This one
    /// puts a genuinely displaceable commit in the gap AND moves the epoch, so the epoch guard is
    /// the only thing standing between the write and the cache.
    @Test("a displaceable gap does not let a write from a previous project epoch through")
    func epochGuardHoldsInsideTheDisplacementBranch() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        let afterPoll = await cache.updateTransport(
            transport(tempo: 90), ifCurrent: observed, source: .backgroundPoll
        )
        #expect(afterPoll)
        await cache.advanceProjectEpoch()

        // Outranks everything in the gap, but describes a project that is no longer open.
        let applied = await cache.updateTransport(
            transport(tempo: 140), ifCurrent: observed, source: .mutationVerification
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 90)
    }

    /// The revision→source history is pruned to a bounded window. A revision whose author has been
    /// forgotten must not be assumed unimportant — treating an unknown as low-priority would let a
    /// late write erase an arbitrarily authoritative commit just because the cache aged past it.
    @Test("a commit whose source has been pruned from history is not displaceable")
    func prunedHistoryIsNotTreatedAsLowPriority() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        // Push the observed revision out of the retained window.
        for tempo in 0..<70 {
            _ = await cache.updateTransport(
                transport(tempo: Double(60 + tempo)),
                ifCurrent: await cache.currentVersion(for: .transport),
                source: .backgroundPoll
            )
        }
        let surviving = (await cache.getTransport()).tempo

        let applied = await cache.updateTransport(
            transport(tempo: 140), ifCurrent: observed, source: .mutationVerification
        )

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == surviving)
    }

    private func transport(tempo: Double) -> TransportState {
        var state = TransportState()
        state.tempo = tempo
        state.lastUpdated = Date()
        return state
    }
}
