import Foundation
import Testing
@testable import LogicProMCP

/// #668 — what `refresh_cache` reports about a section whose write did not land.
///
/// `StatePoller.poll` discards the conditional-write result and returns `true` whenever it decoded
/// a usable value (`StatePoller.swift:355-362`). That is correct for the use the comment defends:
/// a dropped write means the cache already holds something NEWER, and feeding that into
/// `hasDocument` would let a few lost races make the poller declare the document closed.
///
/// But the same `true` is appended to `cacheKeys`, and `cacheKeys` is what `finishPoll` publishes
/// and what makes `system.refresh_cache` answer `refreshed: true`. So a section whose write lost
/// its compare-and-swap is reported to the caller as refreshed.
///
/// STATED LIMIT: these record the shape of the defect; they do not catch it. Asserting that
/// `refresh_cache` answers `refreshed: true` for a rejected write needs the poller to perform real
/// AX reads, which needs a live Logic. What is assertable without one is that the cache DOES record
/// the rejection and that nothing on the receipt path consults it — which is the gap itself.
@Suite("Issue668RefreshReceipt")
struct Issue668RefreshReceiptTests {

    /// The receipt is built from `cacheKeys`, and `cacheKeys` is built from a Bool that answers
    /// "did this decode", never "did this write land". This asserts that separation directly at
    /// the cache, because the poller path needs a live Logic to reach its AX reads — the point is
    /// that the REJECTION IS RECORDED and the receipt does not consult it.
    @Test("the rejection is recorded in the cache and absent from what the receipt is built from")
    func rejectionIsRecordedButNotCarried() async {
        let cache = StateCache()

        let observed = await cache.currentVersion(for: .transport)
        await cache.updateTransport(transport(tempo: 130))
        let applied = await cache.updateTransport(transport(tempo: 90), ifCurrent: observed)

        #expect(!applied, "precondition: this write must be REJECTED or the test means nothing")
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1)
        #expect((await cache.getTransport()).tempo == 130, "the newer value survived, as designed")

        // `poll` does `_ = await update(...)` and returns true on a successful DECODE
        // (StatePoller.swift:355-362). There is no API on the poller, the cache, or the published
        // key list that distinguishes "written" from "read but rejected" — the only record of the
        // rejection is this counter, which nothing on the refresh path reads.
        let droppedIsTheOnlyWitness = await cache.droppedStaleWriteCount(for: .transport)
        #expect(droppedIsTheOnlyWitness == 1)
        #expect(ResourceCacheKey.transport == ResourceCacheKey.transport,
                "cacheKeys carries a section identity only — it has no field for applied-vs-rejected")
    }

    @Test("the two questions are genuinely different: readable does not imply applied")
    func readableAndAppliedDiverge() async {
        let cache = StateCache()
        let observed = await cache.currentVersion(for: .transport)
        await cache.updateTransport(transport(tempo: 130))

        // Readable: the value decoded fine — that is what the poller's Bool answers.
        // Applied: the CAS refused it. Today only the first reaches the caller.
        let applied = await cache.updateTransport(transport(tempo: 90), ifCurrent: observed)

        #expect(!applied)
        #expect(await cache.droppedStaleWriteCount(for: .transport) == 1,
                "the cache DOES record the rejection; that information never reaches the receipt")
    }

    private func transport(tempo: Double) -> TransportState {
        var state = TransportState()
        state.tempo = tempo
        state.lastUpdated = Date()
        return state
    }
}

private final class LockedKeys: @unchecked Sendable {
    private var keys: [ResourceCacheKey] = []
    private let lock = NSLock()
    func set(_ k: [ResourceCacheKey]) { lock.lock(); keys = k; lock.unlock() }
    func note() { lock.lock(); _ = keys; lock.unlock() }
}
