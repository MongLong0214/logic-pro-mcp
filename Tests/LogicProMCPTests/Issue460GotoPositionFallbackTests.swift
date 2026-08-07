import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #460 — goto_position must fall through after an AX element miss
//
// `transport.goto_position` declares four routing candidates
// (Accessibility -> MCU -> CoreMIDI -> CGEvent), but an Accessibility
// `element_not_found` stopped the chain before any later candidate ran. A real
// default-install workflow whose first action was `goto_position` therefore
// failed while three usable channels sat behind the miss (Discussion #455).
//
// `element_not_found` is a PRE-WRITE miss: the AX control was never located, so
// nothing was actuated and no partial write can be stranded. The later channels
// all position the playhead, so falling through cannot change what the caller
// asked for. Those are the same conditions that already admitted the transport
// toggles, which is why the fallback set is keyed on that predicate rather than
// on "is a toggle".
//
// These tests lock both directions: the op falls through, and the fallthrough is
// still gated — an unrelated error code must NOT resume the chain, or the set
// would silently become "retry everything".

@Suite("Issue #460 — goto_position AX fallback")
struct Issue460GotoPositionFallbackTests {
    /// The regression: a ruler-element miss must not strand three usable channels.
    @Test("goto_position falls through to a later channel after AX element_not_found")
    func gotoPositionFallsThroughOnElementNotFound() async {
        let router = ChannelRouter()
        let ax = TerminalStateCChannel(
            id: .accessibility,
            envelope: HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "playhead position field not located in the visible Logic ruler",
                extras: ["element": "playhead_position"]
            )
        )
        let mcu = MockChannel(id: .mcu)
        await router.register(ax)
        await router.register(mcu)

        let result = await router.route(operation: "transport.goto_position")

        #expect(result.isSuccess, "goto_position should fall through when the AX ruler lookup misses")
        let executed = await mcu.executedOps
        #expect(executed.count == 1)
        #expect(executed[0].0 == "transport.goto_position")
    }

    /// The gate must stay closed for anything that is not a pre-write miss,
    /// otherwise the allowlist degrades into blanket retry.
    @Test("a non-element_not_found terminal State C still stops the chain")
    func unrelatedTerminalErrorDoesNotResumeChain() async {
        let router = ChannelRouter()
        let ax = TerminalStateCChannel(
            id: .accessibility,
            envelope: HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "position out of range",
                extras: [:]
            )
        )
        let mcu = MockChannel(id: .mcu)
        await router.register(ax)
        await router.register(mcu)

        let result = await router.route(operation: "transport.goto_position")

        #expect(!result.isSuccess, "a rejected request must not be retried on another channel")
        let executed = await mcu.executedOps
        #expect(executed.isEmpty, "no later channel may run after a non-pre-write failure")
    }

    /// The toggles that already relied on this branch must keep working, so the
    /// rename from a toggle-shaped set to a predicate-shaped one is behaviour-safe.
    /// Each op is paired with a channel its own routing table actually lists —
    /// `transport.play` reaches AppleScript, the toggles reach Key Commands — so a
    /// failure here means the fallback broke, not that the candidate was wrong.
    @Test("existing transport ops still fall through after an AX element miss")
    func togglesStillFallThrough() async {
        let cases: [(operation: String, fallback: ChannelID)] = [
            ("transport.play", .appleScript),
            ("transport.toggle_metronome", .midiKeyCommands),
            ("transport.toggle_cycle", .midiKeyCommands),
        ]
        for testCase in cases {
            let router = ChannelRouter()
            let ax = TerminalStateCChannel(
                id: .accessibility,
                envelope: HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "control not located",
                    extras: [:]
                )
            )
            let fallback = MockChannel(id: testCase.fallback)
            await router.register(ax)
            await router.register(fallback)

            let result = await router.route(operation: testCase.operation)
            #expect(result.isSuccess, "\(testCase.operation) must still fall through")
            let executed = await fallback.executedOps
            #expect(executed.count == 1, "\(testCase.operation) must reach its fallback exactly once")
        }
    }
}
