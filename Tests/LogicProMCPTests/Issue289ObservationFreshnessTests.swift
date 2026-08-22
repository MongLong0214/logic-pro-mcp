import Foundation
import Testing
@testable import LogicProMCP

/// Characterisation tests: four safety properties the compare-and-swap already provides, pinned so
/// they cannot be removed silently by a later change that adds displacement.
///
/// These were written to FAIL first, as the specification for a freshness mechanism. Four of the
/// five passed against unmodified `main`, which is how the mechanism turned out to be unnecessary —
/// the CAS refuses any stale-revision refresh without consulting time at all.
///
/// A previous attempt ranked the requester (mutation verification > explicit read > subscription >
/// background poll) and let a higher rank displace a committed lower one. Review killed it with an
/// interleaving that is not hypothetical:
///
///     V(verify)  captures rev 0, reads tempo 140, is delayed, commits last
///     P(poll)    captures rev 0, reads LATER (tempo 160 after a real change), commits first
///
/// Rank says V outranks P, so V overwrote the newer 160 with the older 140. Authority is not
/// recency. `StatePoller` captures the version BEFORE the AX read for exactly this reason and says
/// so in a comment; revision equality is this design's freshness proof, and rank threw it away.
///
/// `TransportState.lastUpdated` is stamped at extraction (`AXValueExtractors.swift:592`) — the
/// moment the read completed, not the moment the version was captured. Both refreshes above
/// capture at t0, so a capture-time stamp would reproduce the same failure; an extraction-time
/// stamp separates them.
@Suite("Issue289ObservationFreshness")
struct Issue289ObservationFreshnessTests {

    @Test("a delayed read that observed EARLIER cannot displace a newer committed value")
    func anOlderObservationDoesNotDisplaceANewerOne() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        // P read at t2 and commits first.
        let poll = transport(tempo: 160, observedAt: Date(timeIntervalSince1970: 2_000))
        #expect(await cache.updateTransport(poll, ifCurrent: observed))

        // V captured the same revision but read at t1 < t2. It is stale despite arriving later.
        let verify = transport(tempo: 140, observedAt: Date(timeIntervalSince1970: 1_000))
        let applied = await cache.updateTransport(verify, ifCurrent: observed)

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 160)
    }

    // NOT asserted, deliberately: that a read which observed LATER displaces the value it raced.
    // That assertion fails on main, and it is the only one of these five that does. Everything
    // above is already guaranteed by the compare-and-swap, which refuses any refresh whose observed
    // revision is stale — without needing to know the time at all. So the missing behaviour is not
    // a safety hole; it is a freshness one: a genuinely newer read is also refused and the section
    // stays one poll interval out of date.
    //
    // Implementing it means allowing writes the current design refuses, and every such write is a
    // chance to be wrong in a way live evidence cannot detect — the probe on this issue records
    // `counter_reachable_on_demand: false`. Buying a latency improvement with an unverifiable
    // weakening of a guard that currently cannot be wrong is the bargain the withdrawn #664 made.

    @Test("an unstamped read is never treated as fresher — .distantPast is not a timestamp")
    func anUnstampedObservationCannotDisplace() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        let stamped = transport(tempo: 160, observedAt: Date(timeIntervalSince1970: 1_000))
        #expect(await cache.updateTransport(stamped, ifCurrent: observed))

        // Default-constructed: lastUpdated is .distantPast. Comparing it as a real instant would
        // make it infinitely old, which is only safe in one direction -- it must not be able to
        // win, and it must not be able to claim freshness either.
        var unstamped = TransportState()
        unstamped.tempo = 40
        let applied = await cache.updateTransport(unstamped, ifCurrent: observed)

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 160)
    }

    @Test("equal observation times keep first-writer-wins rather than thrashing")
    func equalObservationTimesDoNotDisplace() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        let t = Date(timeIntervalSince1970: 1_500)

        #expect(await cache.updateTransport(transport(tempo: 100, observedAt: t), ifCurrent: observed))
        let second = await cache.updateTransport(transport(tempo: 101, observedAt: t), ifCurrent: observed)

        #expect(!second)
        #expect((await cache.getTransport()).tempo == 100)
    }

    /// The epoch guard is isolated here on purpose. An earlier version of this test wrote once
    /// BEFORE advancing the epoch, which left the observation stale on BOTH counts — so deleting
    /// the epoch guard changed nothing and the mutation went undetected, the revision guard
    /// refusing on its own. A check that two guards can each satisfy tests neither of them.
    @Test("a stale project epoch refuses on its own, with the section revision untouched")
    func aStaleProjectEpochRefusesWithoutHelpFromTheRevisionGuard() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)

        await cache.advanceProjectEpoch()
        let current = await cache.currentVersion(for: .transport)
        // The ONLY difference is the epoch; the revision guard cannot account for this refusal.
        #expect(current.sectionRevision == observed.sectionRevision)
        #expect(current.projectEpoch > observed.projectEpoch)

        let applied = await cache.updateTransport(
            transport(tempo: 140, observedAt: Date(timeIntervalSince1970: 9_000)), ifCurrent: observed)

        #expect(!applied)
        #expect((await cache.getTransport()).tempo == 120)
    }

    private func transport(tempo: Double, observedAt: Date) -> TransportState {
        var state = TransportState()
        state.tempo = tempo
        state.lastUpdated = observedAt
        return state
    }
}
