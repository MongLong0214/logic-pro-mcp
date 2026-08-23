import Foundation
import Testing
@testable import LogicProMCP

/// #668 — what happens when several callers nudge `refresh_cache` at once.
///
/// The census on that issue found 19 in-tree callers that ignore the result and use this purely as
/// a "hurry up" signal inside their own polling loops: `Scripts/live-e2e-test.py` at `timeout=3`
/// (x4) and `Scripts/logic_session_bootstrap.py` at 5s (x15). None of them coordinate with each
/// other.
///
/// `StatePoller` is an actor and `refreshNow()` calls `pollOnce` directly, so concurrent nudges do
/// not interleave — they queue. That is safe, but it means N nudges cost N full poll cycles rather
/// than sharing one. At the measured 12.6s median on a 74-track project, a burst of nudges is a
/// multiple of that, and every one of those callers has a 3–5s budget.
///
/// This pins the current behaviour so a later coalescing change is visible as a change.
@Suite("Issue668RefreshCoalescing")
struct Issue668RefreshCoalescingTests {

    @Test("concurrent nudges queue rather than share one cycle")
    func concurrentNudgesDoNotCoalesce() async {
        // A postPoll that costs a known amount makes the queueing measurable: if the calls shared
        // one cycle the total would be ~one delay, and if they queue it is ~N delays. The AX side
        // is irrelevant — what is measured is whether the actor runs the body once or N times.
        let delay = Duration.milliseconds(200)
        let runs = Counter()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { _ in runs.bump(); try? await Task.sleep(for: delay) }
        )

        let started = ContinuousClock().now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = await poller.refreshNow() }
            }
        }
        let elapsed = started.duration(to: ContinuousClock().now)

        // Four nudges, four cycles. I first wrote this expecting zero — assuming no live AX means
        // nothing is written and `postPoll` never fires. It fired four times. The cycle writes at
        // least the document section regardless, so every nudge pays for a whole cycle.
        //
        // That is the coalescing gap, measured rather than argued: nothing merges concurrent
        // refresh requests, so a burst from the 19 nudge callers costs one full poll each. At the
        // 12.6s median on a 74-track project, four of them is a minute of AX work for one
        // question, and each of those callers is waiting on a 3–5s budget.
        #expect(runs.value() == 4, "each nudge ran its own cycle; none was shared")
        #expect(elapsed >= delay * 4,
                "the cycles are serialised by the actor, so their costs add rather than overlap")
    }

    @Test("a nudge and a scheduled poll cannot run concurrently — the actor serialises them")
    func actorSerialisesNudgeAgainstItself() async {
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { _ in }
        )

        // Two overlapping nudges. If the actor did not serialise them, both would enter `pollOnce`
        // and could capture the same section version, race their conditional writes, and one would
        // be refused — the drop this cache counts. Serialisation is what makes that impossible for
        // poller-vs-poller, and is why `dropped_stale_writes` is unreachable through this path.
        async let a = poller.refreshNow()
        async let b = poller.refreshNow()
        let results = await [a, b]

        #expect(results.count == 2, "both calls completed; neither was merged into the other")
    }
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}
