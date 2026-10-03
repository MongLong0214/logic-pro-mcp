import Testing
@testable import LogicProMCP

/// #1029: under `LOGIC_MCP_DEBUG_ONLY_CHANNEL`, the operations named in
/// `LOGIC_MCP_DEBUG_ONLY_CHANNEL_PASS` walk their table chain when it does not hold the restricted
/// channel. An operation whose chain holds the channel keeps that channel alone even when named, so
/// the list cannot widen the operation under test.
@Suite struct Issue1029DebugPassOperationsTests {
    typealias Router = ChannelRouter

    /// Mutation this kills: the list read without trimming or without dropping empty names.
    @Test func theListIsReadAsCommaSeparatedNames() {
        #expect(Router.debugPassOperations(from: [:]).isEmpty)
        #expect(Router.debugPassOperations(from: [Router.debugPassOperationsEnvironmentKey: ""]).isEmpty)
        #expect(Router.debugPassOperations(from: [
            Router.debugPassOperationsEnvironmentKey: "transport.get_state, track.rename,,",
        ]) == ["transport.get_state", "track.rename"])
    }

    /// The control is the same chain unnamed, which is refused as #1039 left it. Mutation this
    /// kills: every chain without the channel walked whether named or not.
    @Test func aNamedChainWithoutTheChannelIsWalkedAsTheTableHasIt() throws {
        let operation = "transport.get_state"
        let chain = try #require(Router.routingTable[operation])
        #expect(!chain.contains(.cgEvent))
        let walked = try Router.effectiveChain(
            chain, operation: operation, restriction: .only(.cgEvent), pass: [operation]
        ).get()
        #expect(walked == chain)
        let unnamed = Router.effectiveChain(
            chain, operation: operation, restriction: .only(.cgEvent), pass: ["track.rename"]
        )
        guard case let .failure(refusal) = unnamed else {
            Issue.record("expected a refusal, got \(unnamed)")
            return
        }
        #expect(refusal.message.contains(operation))
    }

    /// Mutation this kills: a named operation widened even when its chain holds the channel, which
    /// would let the harness route an op under test through Accessibility first.
    @Test(arguments: ["transport.record", "transport.toggle_cycle", "transport.toggle_metronome"])
    func aNamedChainHoldingTheChannelKeepsItAlone(_ operation: String) throws {
        let chain = try #require(Router.routingTable[operation])
        #expect(chain.count > 1)
        let kept = try Router.effectiveChain(
            chain, operation: operation, restriction: .only(.cgEvent), pass: [operation]
        ).get()
        #expect(kept == [.cgEvent])
    }

    /// Mutation this kills: the list consulted before an invalid restriction refuses.
    @Test func anInvalidRestrictionRefusesANamedOperation() {
        let result = Router.effectiveChain(
            [.accessibility], operation: "transport.get_state", restriction: .invalid("CGEvnt"),
            pass: ["transport.get_state"]
        )
        guard case .failure = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
    }
}
