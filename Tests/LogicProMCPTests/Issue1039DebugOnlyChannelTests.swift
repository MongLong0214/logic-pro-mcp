import Testing
@testable import LogicProMCP

/// #1039: a debug build started with `LOGIC_MCP_DEBUG_ONLY_CHANNEL` keeps one channel in every
/// chain, so a live check can drive an operation through CGEventChannel alone. The variable is read
/// once at launch, so these drive the two pure halves; that `route` walks the restricted chain is
/// shown live, by an operation whose first rung is Accessibility replying from CGEvent.
@Suite struct Issue1039DebugOnlyChannelTests {
    typealias Router = ChannelRouter

    /// Mutation this kills: a lowercase or misspelt value read as unset, which would walk the full
    /// chain while the caller believes it restricted.
    @Test func theVariableIsReadAsUnsetOneChannelOrInvalid() {
        #expect(Router.debugOnlyChannel(from: [:]) == .unrestricted)
        #expect(Router.debugOnlyChannel(from: [Router.debugOnlyChannelEnvironmentKey: "CGEvent"]) == .only(.cgEvent))
        #expect(Router.debugOnlyChannel(from: [Router.debugOnlyChannelEnvironmentKey: "cgevent"]) == .invalid("cgevent"))
        #expect(Router.debugOnlyChannel(from: [Router.debugOnlyChannelEnvironmentKey: ""]) == .invalid(""))
    }

    /// The three transport operations #1039 names reach Accessibility first; restricted, only
    /// CGEvent is left. Mutation this kills: keeping the chain from the restricted channel on
    /// (`drop(while:)`), which would leave the MCU rung after CGEvent in toggle_cycle's chain.
    @Test(arguments: ["transport.record", "transport.toggle_cycle", "transport.toggle_metronome"])
    func aTransportChainKeepsCGEventAlone(_ operation: String) throws {
        let chain = try #require(Router.routingTable[operation])
        #expect(chain.first == .accessibility)
        let kept = try Router.effectiveChain(chain, operation: operation, restriction: .only(.cgEvent)).get()
        #expect(kept == [.cgEvent])
    }

    @Test func unrestrictedKeepsTheTableChain() throws {
        let chain = try #require(Router.routingTable["transport.toggle_cycle"])
        #expect(try Router.effectiveChain(chain, operation: "transport.toggle_cycle", restriction: .unrestricted).get() == chain)
    }

    /// Mutation this kills: an empty restricted chain walked as "no channel required", which the
    /// router answers with success.
    @Test func aChainWithoutTheChannelIsRefused() {
        let result = Router.effectiveChain([.accessibility, .mcu], operation: "transport.play", restriction: .only(.cgEvent))
        guard case let .failure(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.message.contains("transport.play"))
        #expect(refusal.message.contains(Router.debugOnlyChannelEnvironmentKey))
    }

    /// Mutation this kills: an invalid value walked as unrestricted.
    @Test func anInvalidValueRefusesEveryOperation() {
        let result = Router.effectiveChain([.accessibility, .cgEvent], operation: "transport.toggle_cycle", restriction: .invalid("CGEvnt"))
        guard case let .failure(refusal) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(refusal.message.contains("CGEvnt"))
    }

    /// Review R1, R-1039-03: the operations whose chain is empty answered before the restriction
    /// was consulted. Every one of them in the table is checked, so a new one is covered too.
    /// Mutation this kills: the empty-chain answer given without asking the restriction. The
    /// control is the same operations unrestricted and under a restriction that names a channel.
    @Test func anInvalidValueRefusesTheOperationsThatNeedNoChannel() {
        let empty = Router.routingTable.filter { $0.value.isEmpty }.map(\.key).sorted()
        #expect(empty.contains("system.health"), "the table has no empty chain where one was read")
        for operation in empty {
            let refused = Router.emptyChainResult(operation: operation, restriction: .invalid("CGEvnt"))
            guard case let .error(message) = refused else {
                Issue.record("\(operation) answered \(refused) under an invalid restriction")
                continue
            }
            #expect(message.contains("CGEvnt"))
            for restriction in [Router.DebugOnlyChannel.unrestricted, .only(.cgEvent)] {
                let answered = Router.emptyChainResult(operation: operation, restriction: restriction)
                guard case .success = answered else {
                    Issue.record("\(operation) answered \(answered) under \(restriction)")
                    continue
                }
            }
        }
    }
}
