import Foundation
import Testing
@testable import LogicProMCP

/// ADR-006 asks for bounded per-client subscription queues. There are no queues at all:
/// `ResourceSubscriptions.publishChangedResources` awaits `notify(uri)` inline, and that publish
/// runs as `StatePoller`'s `postPoll` callback (`LogicProServer.swift:387`), reached from
/// `finishPoll` — a private method, so it executes **inside the poller actor**.
///
/// The consequence is not the unbounded-queue growth the ADR anticipates. It is the opposite
/// shape: a slow subscriber holds the actor, and the poller cannot start its next cycle. No test
/// covered `postPoll` at all before this one, so the coupling was load-bearing and unpinned.
@Suite("Issue289PostPollCoupling")
struct Issue289PostPollCouplingTests {

    @Test("a slow postPoll delays the poll that follows it — the subscriber is in the poller's path")
    func aSlowPostPollBlocksTheNextPoll() async {
        let cache = StateCache()
        // The AX side is irrelevant here: what is measured is whether the poller's own actor is
        // held by postPoll, which happens whether or not the poll reads anything.
        let channel = AccessibilityChannel()

        let delay = Duration.milliseconds(300)
        let poller = StatePoller(
            axChannel: channel,
            cache: cache,
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { _ in try? await Task.sleep(for: delay) }
        )

        // A bare threshold on the slow run is not evidence: the poll itself costs time on this
        // machine (measured ~1.1s with an empty postPoll), so `elapsed >= 300ms` passes whether or
        // not postPoll contributes anything. The difference between the two runs is what isolates
        // it, so both are measured here and compared.
        let slowStart = ContinuousClock().now
        await poller.refreshNow()
        let slow = slowStart.duration(to: ContinuousClock().now)

        let fastPoller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { _ in }
        )
        let fastStart = ContinuousClock().now
        await fastPoller.refreshNow()
        let fast = fastStart.duration(to: ContinuousClock().now)

        // postPoll is awaited inside the actor-isolated finishPoll, so its cost lands on the
        // refresh. A design that handed the notification off would show no such difference.
        #expect(slow - fast >= delay / 2,
                "slow=\(slow) fast=\(fast) — postPoll should add ~\(delay) to the refresh")
    }

}
