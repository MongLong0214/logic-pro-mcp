import Foundation
import Testing

@testable import LogicProMCP

/// The MCU staleness rule used to be written twice: `MCUChannel.health` compared
/// `age > 5.0` behind an early return on `!isConnected`, and `SystemDispatcher`
/// compared `isConnected && age > 5.0` inline for the `feedback_stale` wire
/// field. Both spellings agreed, so no behaviour test could have told them apart
/// — which is exactly why the duplication survived. These rows pin the single
/// predicate they now share, including the two rows that separate the guard from
/// the threshold.
@Suite("MCU feedback staleness is one rule")
struct MCUFeedbackStalenessRuleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func state(connected: Bool, feedbackAgo seconds: TimeInterval?) -> MCUConnectionState {
        MCUConnectionState(
            isConnected: connected,
            lastFeedbackAt: seconds.map { now.addingTimeInterval(-$0) }
        )
    }

    @Test("a disconnected port is never stale, however old its last feedback")
    func disconnectedIsNeverStale() {
        #expect(!state(connected: false, feedbackAgo: 3600).isFeedbackStale(now: now))
        #expect(!state(connected: false, feedbackAgo: nil).isFeedbackStale(now: now))
    }

    @Test("a connected port that has never received feedback is stale, not fresh")
    func connectedWithoutFeedbackIsStale() {
        #expect(state(connected: true, feedbackAgo: nil).isFeedbackStale(now: now))
    }

    @Test("a connected port inside the window is fresh")
    func connectedAndRecentIsFresh() {
        #expect(!state(connected: true, feedbackAgo: 0).isFeedbackStale(now: now))
        #expect(!state(connected: true, feedbackAgo: 4.9).isFeedbackStale(now: now))
    }

    @Test("a connected port past the window is stale")
    func connectedAndSilentIsStale() {
        #expect(state(connected: true, feedbackAgo: 5.1).isFeedbackStale(now: now))
        #expect(state(connected: true, feedbackAgo: 600).isFeedbackStale(now: now))
    }

    /// The threshold is exclusive on both former sites (`> 5.0`, never `>= 5.0`).
    /// Pinned so a later rewrite through `lastFeedbackAgeMs` — which truncates to
    /// whole milliseconds — cannot move the boundary unnoticed.
    @Test("the boundary is exclusive and survives sub-millisecond ages")
    func boundaryIsExclusive() {
        let threshold = MCUConnectionState.feedbackStaleAfter
        #expect(!state(connected: true, feedbackAgo: threshold).isFeedbackStale(now: now))
        #expect(state(connected: true, feedbackAgo: threshold + 0.0005).isFeedbackStale(now: now))
    }

    /// A backwards system-clock adjustment must not read as silence.
    @Test("a clock that ran backwards is not stale")
    func negativeAgeIsNotStale() {
        #expect(!state(connected: true, feedbackAgo: -120).isFeedbackStale(now: now))
    }

    // MARK: - #851: the rule is evaluated once per payload, not once per surface

    /// The prose clause and the wire boolean now come from ONE argument, so the health payload
    /// cannot contradict itself. This pins that the clause is a function of that argument alone —
    /// the renderer takes no cache, no clock and no connection state it could re-read.
    @Test("the staleness clause is a function of the published boolean and nothing else")
    func stalenessClauseIsAFunctionOfTheBoolean() {
        #expect(SystemDispatcher.mcuStalenessClause(connected: true, stale: true) == ", feedback stale")
        #expect(SystemDispatcher.mcuStalenessClause(connected: true, stale: false) == ", feedback active")
    }

    /// A disconnected port is NOT stale under the rule, and it is not active either. Calling it
    /// active — which a naive `stale ? … : …` does — would be a claim the surface cannot support,
    /// so the clause is omitted. Both values of `stale` are pinned here because the interesting
    /// failure is a renderer that reads only `stale` and reports "feedback active" on a dead port.
    @Test("a disconnected port gets no staleness clause at all, under either boolean")
    func disconnectedPortGetsNoClause() {
        #expect(SystemDispatcher.mcuStalenessClause(connected: false, stale: false).isEmpty)
        #expect(SystemDispatcher.mcuStalenessClause(connected: false, stale: true).isEmpty)
    }

    /// The channel no longer renders staleness at all. Asserted on a state that IS stale under the
    /// rule, so a regression that re-adds the second derivation fails here rather than passing by
    /// happening to be fresh — and asserted as "no staleness vocabulary" rather than against one
    /// spelling, because a reworded duplicate is the same defect.
    @Test("MCUChannel.healthCheck renders no staleness word, so there is no second derivation")
    func channelHealthCarriesNoStalenessWord() async {
        let cache = StateCache()
        var conn = MCUConnectionState()
        conn.isConnected = true
        conn.registeredAsDevice = true
        conn.lastFeedbackAt = Date(timeIntervalSinceNow: -600)
        await cache.updateMCUConnection(conn)

        let detail = await MCUChannel(transport: MockMCUTransport(), cache: cache)
            .healthCheck()
            .detail
        #expect(!detail.contains("stale"))
        #expect(!detail.contains("feedback active"))
        #expect(detail.contains("device registration confirmed"))
    }
}
