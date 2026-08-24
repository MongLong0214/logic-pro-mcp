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

    @Test("the initiator returns without waiting for the callers it queued")
    func initiatorIsNotHeldByTheDrain() async {
        let cycles = Counter()
        let poller = Self.makePoller(cache: StateCache(), cycles: cycles)
        let waiterFinished = Flag()

        // The caller that finds the poller idle runs the cycle. Its own answer is ready when that
        // cycle ends — but a first draft served the queued callers before returning, so the
        // initiator paid for their cycles too. Measured at ~1.4x its solo latency under a stream of
        // nudges, against a 25s deadline the cycle already overruns on a 74-track project. Whole
        // extra cycles on the critical path make #668 worse, not better.
        async let initiator: Bool = poller.refreshNow()
        try? await Task.sleep(for: .milliseconds(300))  // land inside the initiator's cycle
        let queued = Task { _ = await poller.refreshNow(); waiterFinished.set() }
        _ = await initiator

        // The queued caller is owed a FRESH cycle, which cannot have finished yet. If the initiator
        // had drained before returning, that cycle would be complete and this flag set.
        #expect(!waiterFinished.isSet(), "the initiator waited for the queued caller's cycle")
        _ = await queued.value
    }

    @Test("stop() still waits for the cycles it is documented to wait for")
    func stopCoversTheHandedOffDrain() async {
        let resolved = Counter()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { true },
                           sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }),
            postPoll: { _ in try? await Task.sleep(for: .seconds(1)) }
        )
        await poller.start()
        let waiters = (0..<3).map { _ in Task { _ = await poller.refreshNow(); resolved.bump() } }
        try? await Task.sleep(for: .milliseconds(400))

        // Handing the drain to its own task let AX polling outlive a `stop()` whose own
        // documentation says it waits for the current cycle. It usually finished in time anyway,
        // because it shares this actor and `stop()` suspends — but that is scheduling luck, and a
        // stop guarantee resting on luck is not a guarantee. Measured over three runs each:
        // unawaited left 3 of 3 callers unresolved every time; awaited left 0, 1, 1.
        let pendingBefore = 3 - resolved.value()
        await poller.stop()
        let unresolved = 3 - resolved.value()

        #expect(pendingBefore > 0, "no drain was outstanding, so this measured nothing")
        #expect(unresolved < pendingBefore,
                "stop() returned without waiting for any of the drain it handed off")
        for waiter in waiters { _ = await waiter.value }
    }

    @Test("stop() returns while nudges keep arriving")
    func stopIsBoundedUnderContinuousNudges() async {
        let poller = Self.makePoller(cache: StateCache(), cycles: Counter())
        await poller.start()
        let halt = Flag()
        // Fire-and-forget on a timer, which is the shape the 15 bootstrap callers actually have:
        // nothing waits for a previous result, so a nudge lands while the drain's own cycle is
        // still running. My first attempt at this test had each sender await its own result, which
        // left a gap where the queue was briefly empty — and it passed against the defect.
        let sender = Task {
            while !halt.isSet() {
                Task { _ = await poller.refreshNow() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        try? await Task.sleep(for: .milliseconds(400))

        // The drain kept accepting new batches and `refreshNow` stays callable after the loop task
        // is gone, so one nudge per cycle held `stop()` open indefinitely — measured at over 20s
        // with no sign of returning, ending only when the nudges did.
        let returned = Flag()
        let stopper = Task { await poller.stop(); returned.set() }
        try? await Task.sleep(for: .seconds(12))
        let stoppedInTime = returned.isSet()

        halt.set()
        sender.cancel()
        _ = await stopper.value
        #expect(stoppedInTime, "stop() was still waiting after 12s of continuous nudges")
    }

    @Test("stopImmediately() does not leave a cycle about to start")
    func stopImmediatelyStartsNoNewCycle() async {
        let cycles = Counter()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { cycles.bump(); return true },
                           sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }),
            postPoll: { _ in try? await Task.sleep(for: .milliseconds(200)) }
        )
        // An external nudge takes the flag first, so the loop reaches the gate while a cycle runs.
        let nudge = Task { _ = await poller.refreshNow() }
        try? await Task.sleep(for: .milliseconds(50))
        await poller.start()
        try? await Task.sleep(for: .milliseconds(300))

        // A queued loop suspends in a continuation cancellation cannot wake, so it used to be
        // served by a whole AX cycle that began AFTER stopImmediately() had returned — work done
        // purely for a loop that was already cancelled. The loop now skips a redundant tick
        // instead of queueing.
        await poller.stopImmediately()
        let atReturn = cycles.value()
        // Long enough for the in-flight cycle to END and any drain it spawns to run. An earlier
        // 3s window closed before the initiator had even finished, so the test reported "no new
        // cycles" about a stretch of time in which nothing had happened yet.
        try? await Task.sleep(for: .seconds(8))

        #expect(cycles.value() == atReturn,
                "\(cycles.value() - atReturn) cycle(s) began after stopImmediately() returned")
        _ = await nudge.value
    }

    @Test("a debounced write is not reported as a refresh")
    func debouncedWriteIsNotReportedAsRefreshed() async {
        // The occlusion debounce absorbs the first two empty track reads while a document is open
        // and the cache is non-empty, returning without touching tracks, timestamp, or revision.
        // The older `updateTracks(_:ifCurrent:)` still answers `true` there, because the
        // compare-and-swap DID accept — and that `true` used to reach `refresh_cache`'s
        // `refreshed`. "CAS accepted" is not "the cache advanced", and the receipt claims the
        // second. `applyTracks` is the fix, so it is what this measures.
        //
        // This drove the poller through a real `AccessibilityChannel` until 2026-08-24, which made
        // it a statement about the machine rather than about the code: the debounce only engages
        // when the AX read comes back empty, so the test passed with Logic closed and failed with a
        // project open. It failed exactly that way in a ship gate while CI, which has no Logic,
        // stayed green — an environmental accident encoded as a contract.
        let cache = StateCache()
        await cache.updateTracks([TrackState(id: 0, name: "Kept", type: .audio)])
        await cache.updateDocumentState(true)
        let observed = await cache.currentVersion(for: .tracks)

        let applied = await cache.applyTracks([], ifCurrent: observed)

        #expect(!applied, "the CAS accepted but the cache did not advance; that is not a refresh")
        #expect(await cache.currentVersion(for: .tracks) == observed, "the revision moved")
        #expect(await cache.getTracks().first?.name == "Kept", "the cache was overwritten")

        // The negative above is only worth something if the same call can answer `true`. A read
        // that genuinely carries new content is not absorbed, and must be reported as a refresh.
        let advanced = await cache.applyTracks(
            [TrackState(id: 0, name: "Replaced", type: .audio)], ifCurrent: observed)
        #expect(advanced, "a write that changed the cache was not reported as a refresh")
        #expect(await cache.currentVersion(for: .tracks) != observed)
    }

    /// NOT covered here: that `applied == false` stops the poller emitting a `tracks` cache key.
    /// `StatePoller` takes a concrete `AccessibilityChannel`, so there is no seam to hand it a
    /// controlled read, and the only way to reach that link is to walk whatever Logic is doing —
    /// which is what made the test above environment-coupled. Stating the gap rather than
    /// re-introducing a check that passes for the wrong reason.

    @Test("no cycle begins once a stop is requested, including from a cycle stop does not own")
    func stopQuiescesACycleItDoesNotOwn() async {
        let cycles = Counter()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { cycles.bump(); return true },
                           sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }),
            postPoll: { _ in try? await Task.sleep(for: .milliseconds(200)) }
        )
        // An external nudge owns the cycle, so the loop skips its tick and sleeps. Cancelling the
        // loop then leaves `drainTask` nil, and stop() used to await nothing and return — after
        // which the external cycle would find the queued callers and hand off a fresh,
        // uncancelled drain, running AX work past the stop.
        let owner = Task { _ = await poller.refreshNow() }
        try? await Task.sleep(for: .milliseconds(50))
        await poller.start()
        let queued = (0..<2).map { _ in Task { _ = await poller.refreshNow() } }
        try? await Task.sleep(for: .milliseconds(250))

        // Sampled when stop is REQUESTED, not when it returns. Measuring after the return hides
        // the defect: stop parks on the cycle it does not own, so a drain spawned in the meantime
        // finishes inside the wait and its cycle is invisible to an after-the-fact comparison.
        let atRequest = cycles.value()
        await poller.stop()
        try? await Task.sleep(for: .seconds(6))

        #expect(cycles.value() == atRequest,
                "\(cycles.value() - atRequest) cycle(s) began after the stop was requested")
        _ = await owner.value
        for q in queued { _ = await q.value }
    }

    @Test("stop() does not return while a cycle it does not own is still running")
    func stopWaitsForACycleItDoesNotOwn() async {
        let cycleEnded = Flag()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { true },
                           sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }),
            postPoll: { _ in
                try? await Task.sleep(for: .seconds(1))
                cycleEnded.set()
            }
        )
        // Cancelling the loop covers only cycles the loop owns. An external `refreshNow` holding
        // the gate keeps running AX after stop() has cancelled everything it can see, so stop()
        // parks until the cycle releases — otherwise it reports the poller stopped while the
        // poller is mid-walk.
        let owner = Task { _ = await poller.refreshNow() }
        try? await Task.sleep(for: .milliseconds(50))
        await poller.start()
        try? await Task.sleep(for: .milliseconds(200))

        await poller.stop()
        #expect(cycleEnded.isSet(), "stop() returned while a cycle was still running")
        _ = await owner.value
    }

    @Test("a nudge arriving after stop() does not restart AX work")
    func nudgeAfterStopIsRefused() async {
        let cycles = Counter()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { cycles.bump(); return true },
                           sleep: { _ in try await Task.sleep(nanoseconds: 1_000) }),
            postPoll: { _ in }
        )
        await poller.start()
        try? await Task.sleep(for: .milliseconds(200))
        await poller.stop()

        // `refresh_cache` stays reachable after the poller stops — the tool does not know about
        // the lifecycle. Serving it would walk AX on a poller that has been told to stop, which is
        // the work stop exists to end, so it is refused and answers honestly that nothing advanced.
        let atStop = cycles.value()
        let advanced = await poller.refreshNow()

        #expect(!advanced, "a nudge after stop() claimed the cache advanced")
        #expect(cycles.value() == atStop, "a nudge after stop() started a cycle")
    }

    @Test("callers arriving during a cycle are batched rather than served one cycle each")
    func drainingTerminates() async {
        let cycles = Counter()
        let entered = Counter()
        let hold = OneShotGate()
        let poller = StatePoller(
            axChannel: AccessibilityChannel(),
            cache: StateCache(),
            runtime: .init(hasVisibleWindow: { cycles.bump(); return true }),
            // Holding the cycle open here is what makes the overlap a fact instead of a hope.
            postPoll: { _ in entered.bump(); await hold.wait() }
        )

        // The first draft spread twelve nudges 20ms apart and asserted the cycle count came out
        // under twelve. That assumed a cycle outlasts the gaps between arrivals — and it does, on a
        // machine where the AX walk takes a second. It failed in the ship gate at 0.235s for the
        // whole test: with AX answering instantly, nothing overlapped, and twelve nudges each
        // getting their own cycle is *correct* behaviour, not a batching failure. The assertion was
        // demanding sharing in a run where there was nothing to share.
        let callers = (0..<12).map { _ in Task { _ = await poller.refreshNow() } }

        // Once one cycle is parked inside postPoll the gate is held, so every later arrival must
        // queue. No sleep decides that; the gate does.
        while entered.value() == 0 { await Task.yield() }
        while cycles.value() < 2 && entered.value() == 1 {
            // Give the queued callers a chance to register before releasing. They cannot start a
            // cycle while the first is held, so this cannot race ahead of the property.
            await Task.yield()
            if entered.value() > 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
            break
        }
        hold.open()
        for caller in callers { _ = await caller.value }

        // Eleven callers queued behind one held cycle share the drain rather than each running
        // their own. The bound is generous because how many land in the first batch is scheduling;
        // twelve would mean nothing was shared at all.
        #expect(cycles.value() < 12,
                "\(cycles.value()) cycles for 12 nudges; nothing was batched")
        #expect(cycles.value() >= 1, "no cycle ran")
    }
}

private final class KeyRecorder: @unchecked Sendable {
    private var seen: [ResourceCacheKey] = []
    private let lock = NSLock()
    func add(_ k: [ResourceCacheKey]) { lock.lock(); seen.append(contentsOf: k); lock.unlock() }
    func sawTracks() -> Bool { lock.lock(); defer { lock.unlock() }; return seen.contains(.tracks) }
}

private final class OneShotGate: @unchecked Sendable {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    func open() {
        lock.lock()
        guard !isOpen else { lock.unlock(); return }
        isOpen = true
        let parked = waiters; waiters = []
        lock.unlock()
        for w in parked { w.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            waiters.append(c); lock.unlock()
        }
    }
}

private final class Flag: @unchecked Sendable {
    private var v = false
    private let lock = NSLock()
    func set() { lock.lock(); v = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}
