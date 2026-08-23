import Foundation
import Testing
@testable import LogicProMCP

/// #668 — concurrent `refresh_cache` nudges share cycles instead of each starting one.
///
/// The census on that issue found 19 in-tree callers that ignore the result and use this purely as
/// a "hurry up" signal inside their own polling loops: `Scripts/live-e2e-test.py` at `timeout=3`
/// (x4) and `Scripts/logic_session_bootstrap.py` at 5s (x15). None of them coordinate.
///
/// Before coalescing, this suite pinned the damage: four concurrent nudges entered the poll body
/// together, all captured the same section version, and three had their conditional writes refused
/// after paying for the whole AX walk. `actor` did not prevent that — actors are re-entrant across
/// `await`, and the poll body suspends on every AX read. The assertions below are the same
/// measurements inverted, which is what makes the change visible rather than merely claimed.
@Suite("Issue668RefreshCoalescing")
struct Issue668RefreshCoalescingTests {

    /// Counts cycles at `hasVisibleWindow`, which the poll body calls exactly once per cycle before
    /// its first suspension.
    ///
    /// It must NOT be counted at `postPoll`. `postPoll` fires only when a section was written, so
    /// under the racing behaviour this suite exists to detect, three of four cycles are refused,
    /// emit nothing, and go uncounted — the counter reads "2 cycles" for four full AX walks and the
    /// test passes for the wrong reason. That is exactly what happened: the cycle-count assertion
    /// below stayed green against a mutant with coalescing removed, and only re-aiming the
    /// instrument exposed it.
    private static func makePoller(cache: StateCache, cycles: Counter) -> StatePoller {
        StatePoller(
            axChannel: AccessibilityChannel(),
            cache: cache,
            runtime: .init(hasVisibleWindow: { cycles.bump(); return true }),
            postPoll: { _ in }
        )
    }

    @Test("concurrent nudges no longer race: no write is refused")
    func concurrentNudgesDoNotDropWrites() async {
        let cache = StateCache()
        let poller = Self.makePoller(cache: cache, cycles: Counter())

        let droppedBefore = await cache.droppedStaleWriteCount(for: .tracks)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 { group.addTask { await poller.refreshNow() } }
            for await _ in group {}
        }
        let dropped = await cache.droppedStaleWriteCount(for: .tracks) - droppedBefore

        // This is the assertion that inverted. Measured at 3 before coalescing, deterministically
        // over four runs; the cycles cannot overlap now, so no two capture the same version.
        #expect(dropped == 0, "a write was refused, so two cycles still overlapped")
    }

    @Test("four concurrent nudges cost two cycles, not four")
    func concurrentNudgesShareACycle() async {
        let cycles = Counter()
        let poller = Self.makePoller(cache: StateCache(), cycles: cycles)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 { group.addTask { await poller.refreshNow() } }
            for await _ in group {}
        }

        // One cycle for whoever arrived first, one shared by the three that arrived during it.
        // The bound is what matters, not the exact 2: which callers land inside the first cycle
        // depends on scheduling, and a test that pins a timing-shaped number fails for reasons
        // unrelated to the code. Four would mean nothing was shared.
        #expect(cycles.value() <= 2, "\(cycles.value()) cycles ran; the nudges did not share one")
        #expect(cycles.value() >= 1, "no cycle ran at all")
    }

    @Test("a late caller is served a cycle that began after its request, not the one in flight")
    func lateCallerIsNotServedStaleReads() async {
        let cycles = Counter()
        let poller = Self.makePoller(cache: StateCache(), cycles: cycles)

        // The hazard this guards is concrete: `refreshAfterWrite` on the saga path nudges the
        // poller immediately after a write. If a late caller were handed the in-flight cycle's
        // result, it would receive AX reads taken BEFORE its own write and the saga would proceed
        // on state that predates it — the staleness the compare-and-swap exists to prevent, with
        // nothing left to count it. So arrivals wait for a fresh cycle.
        async let first: Bool = poller.refreshNow()
        try? await Task.sleep(for: .milliseconds(300))  // land inside the first cycle
        async let second: Bool = poller.refreshNow()
        _ = await [first, second]

        #expect(cycles.value() == 2,
                "the late caller was served the in-flight cycle instead of a fresh one")
    }

    @Test("a refused write still leaves the section readable")
    func refusedWriteDoesNotMakeTheDocumentLookClosed() async {
        let cache = StateCache()
        let poller = Self.makePoller(cache: cache, cycles: Counter())

        // `hasDocument` defaults to true, so asserting it after a poll would pass whether or not
        // the poll did anything. Drive it false first: then the assertion answers "did the poll
        // set it", not "was it already set".
        await cache.updateDocumentState(false)
        #expect(!(await cache.getHasDocument()), "precondition not established")

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 { group.addTask { await poller.refreshNow() } }
            for await _ in group {}
        }

        #expect(await cache.getHasDocument(), "the poller declared the document closed")
    }

    @Test("a steady stream of nudges does not starve the initiator")
    func drainingTerminates() async {
        let cycles = Counter()
        let poller = Self.makePoller(cache: StateCache(), cycles: cycles)

        // The drain loop serves waiters in batches, so callers arriving during the shared cycle
        // form the next batch rather than extending the current one. If it instead served each
        // arrival individually, a continuous stream would keep the first caller suspended.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(20 * i))
                    _ = await poller.refreshNow()
                }
            }
        }

        // Twelve nudges spread across the run, batched into far fewer cycles. The point is that it
        // finished at all and did not run one cycle per caller.
        #expect(cycles.value() < 12, "\(cycles.value()) cycles for 12 nudges; batching did nothing")
    }
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}
