import Foundation
import Testing
@testable import LogicProMCP

/// #668 — what happens when several callers nudge `refresh_cache` at once.
///
/// The census on that issue found 19 in-tree callers that ignore the result and use this purely as
/// a "hurry up" signal inside their own polling loops: `Scripts/live-e2e-test.py` at `timeout=3`
/// (x4) and `Scripts/logic_session_bootstrap.py` at 5s (x15). None of them coordinate.
///
/// I first wrote these tests asserting that `StatePoller` being an actor means concurrent nudges
/// queue rather than interleave. **That is wrong, and measuring it is what corrected me.** Swift
/// actors are re-entrant across `await`: `pollOnce` suspends on every AX read and on `postPoll`, so
/// concurrent nudges enter the poll body, all capture the same section version before any of them
/// writes, and then race their conditional writes. One wins and the rest are refused.
///
/// Two consequences follow, and both contradict what I had recorded on #668 and #289:
///
///  1. Poller-vs-poller compare-and-swap rejection is **reachable**, not structurally impossible.
///     Four concurrent nudges produce three dropped writes, deterministically, with no live Logic
///     involved at all. `dropped_stale_writes` — the counter I could not make move — moves here.
///
///  2. The wasted work is the real cost. All four cycles pay for the full AX walk; three of them
///     then have their result thrown away. At the 12.6s median measured on a 74-track project that
///     is roughly 38s of AX work discarded to answer one question, while each caller waits on a
///     3-5s budget. Coalescing would collapse those four cycles into one.
@Suite("Issue668RefreshCoalescing")
struct Issue668RefreshCoalescingTests {

    @Test("concurrent nudges race their writes; the losers are refused, not queued")
    func concurrentNudgesRaceRatherThanQueue() async {
        let cache = StateCache()
        let emissions = Recorder()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: cache,
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { keys in emissions.add(keys.count) }
        )

        let droppedBefore = await cache.droppedStaleWriteCount(for: .tracks)
        var receipts: [Bool] = []
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 { group.addTask { await poller.refreshNow() } }
            for await didAdvance in group { receipts.append(didAdvance) }
        }
        let dropped = await cache.droppedStaleWriteCount(for: .tracks) - droppedBefore

        // Measured 3 dropped / 1 emission on four consecutive runs. The count is asserted as a
        // property rather than as the exact 3: the interleaving is structural (every task suspends
        // on the AX read before any write lands) but how many land is not something this test can
        // guarantee on every machine, and a test that pins a timing-shaped number is a test that
        // fails for reasons unrelated to the code.
        #expect(dropped >= 1,
                "no write was refused, so the concurrent nudges did not actually overlap (measured 3)")
        #expect(receipts.contains(false),
                "every nudge claimed the cache advanced, but they cannot all have won the race")
        #expect(emissions.count() < receipts.count,
                "postPoll fired once per nudge, so no write was dropped after all (measured 1 of 4)")

        // The wasted work is the point: the losers did the whole AX walk before being refused.
        #expect(receipts.count == 4, "all four cycles ran; nothing merged them")
    }

    @Test("a refused write still leaves the section readable")
    func refusedWriteDoesNotMakeTheDocumentLookClosed() async {
        let cache = StateCache()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: cache,
            runtime: .init(hasVisibleWindow: { true }),
            postPoll: { _ in }
        )

        // `hasDocument` defaults to true, so asserting it after a poll would pass whether or not
        // the poll did anything. Drive it false first: then the assertion is answering "did the
        // poll set it", not "was it already set".
        await cache.updateDocumentState(false)
        #expect(!(await cache.getHasDocument()), "precondition not established")

        // Losing the race must not read as "the document went away". This is the asymmetry the
        // receipt fix rests on: `hasDocument` is built from readability, the receipt from the write
        // outcome, and only the second one is allowed to go false when a race is lost.
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 { group.addTask { await poller.refreshNow() } }
            for await _ in group {}
        }

        #expect(await cache.droppedStaleWriteCount(for: .tracks) >= 1, "no race occurred to test")
        #expect(await cache.getHasDocument(),
                "refused writes made the poller declare the document closed")

        // STATED LIMIT: this does not catch `hasDocument = projectReady.applied || …`. In a race
        // one write always wins, so that mutation would still leave the flag true here. What pins
        // the readable/applied asymmetry is `Issue668RefreshReceiptTests`; this pins that the
        // combination of a refused write and a live document does not close the document.
    }
}

private final class Recorder: @unchecked Sendable {
    private var counts: [Int] = []
    private let lock = NSLock()
    func add(_ n: Int) { lock.lock(); counts.append(n); lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return counts.count }
}
