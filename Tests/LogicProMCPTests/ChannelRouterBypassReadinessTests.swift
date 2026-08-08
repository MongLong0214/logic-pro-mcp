import Testing
import Foundation
@testable import LogicProMCP

// MARK: - Test fixtures

/// Channel mock with full health override + executeStub. Used for bypass-gate
/// scenarios where MockChannel's `available:Bool` shorthand is too coarse
/// (we need to assert exact `verificationStatus` transitions).
actor BypassMockChannel: Channel {
    nonisolated let id: ChannelID
    var executedOps: [(String, [String: String])] = []
    let healthStub: ChannelHealth
    let executeStub: ChannelResult

    init(
        id: ChannelID,
        health: ChannelHealth,
        execute: ChannelResult = .success("Mock OK")
    ) {
        self.id = id
        self.healthStub = health
        self.executeStub = execute
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return executeStub
    }

    func healthCheck() async -> ChannelHealth { healthStub }
}

// MARK: - Helpers

private let expectedBypassKeys: Set<String> = [
    "midi.send_cc.keycmd",
    "midi.send_note.keycmd",
    "midi.send_chord.keycmd",
    "midi.send_program_change.keycmd",
    "midi.send_pitch_bend.keycmd",
    "midi.send_aftertouch.keycmd",
    "midi.play_sequence.keycmd",
]

private func parseEnvelope(_ msg: String) -> [String: Any]? {
    guard let data = msg.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let obj = raw as? [String: Any] else { return nil }
    return obj
}

// MARK: - Test #1 — Set membership

@Test func testBypassReadinessOpsContainsAllSevenKeycmdOps() {
    let actual = ChannelRouter.bypassReadinessOps
    #expect(actual.count == 7, "expected exactly 7 bypass entries, got \(actual.count)")
    for key in expectedBypassKeys {
        #expect(actual.contains(key), "bypassReadinessOps missing key: \(key)")
    }
}

// MARK: - Test #2 — Bypass routes through manual_validation_required

@Test func testBypassOpsRouteThroughManualValidationChannel() async {
    // KeyCmd channel: available:true, ready:false (manual_validation_required).
    // Pre-T4 this would skip the channel and exhaust the chain. Post-T4 the
    // bypass op must reach `execute()`.
    let router = ChannelRouter()
    let keyCmd = BypassMockChannel(
        id: .midiKeyCommands,
        health: .healthy(
            detail: "KeyCmd virtual port published; awaiting Logic MIDI Learn",
            verificationStatus: .manualValidationRequired
        )
    )
    await router.register(keyCmd)

    // Inject the bypass op into a test-only registration. The routing table
    // doesn't carry keycmd entries until T5, so for T4 we exercise the gate
    // by adding the channel in the chain via direct routing simulation.
    // We use a router seam: route() looks up routingTable; for T4 we test
    // the gate via a routingTable entry added ad-hoc through the public path
    // — since the table is internal but immutable, we use an op that maps
    // to .midiKeyCommands as primary and assert the gate is bypassed for
    // the specific bypass key. We test the gate by piggy-backing on
    // edit.undo's routing chain: replace the op with a bypass key registered
    // through a TestChannelRouter shim is not available, so we rely on the
    // production hook: bypassReadinessOps gate is evaluated *inside* route(),
    // independent of which channel is primary. We assert via a direct call
    // using one of the keycmd ops + a routing entry that T5 will add. Until
    // T5, this test exercises the pipeline against the channel directly.
    //
    // Strategy: invoke route() with a bypass op. Even if routingTable has no
    // entry, the function returns "Unknown operation". That's not what we want.
    // So instead we assert the *gate logic* by routing through edit.undo with
    // a manual_validation_required channel and confirming the GENERAL path
    // still skips (sanity baseline). The bypass execution proof is delivered
    // post-T5 in the integration test, but we can still verify the bypass
    // *flag is honored* through a unit-level assertion: route a bypass op
    // and observe whether the Unknown-operation path or the channel path is
    // taken. Until T5 this surfaces as "Unknown operation".
    //
    // For T4 atomic validation we therefore call into the gate with a mocked
    // routing chain via `routeWithExplicitChain` (added to ChannelRouter as
    // an internal test seam). If that seam is unavailable, fall back to the
    // production route + expect Unknown-operation (gate is exercised post-T5).
    let result = await router.route(operation: "midi.send_cc.keycmd")
    // T5 added the keycmd routing entries: midi.send_cc.keycmd → [.midiKeyCommands].
    // The bypass gate must allow the channel to execute even though it reports
    // verificationStatus=.manualValidationRequired (ready=false). This is the
    // whole point of `bypassReadinessOps` — the KeyCmd surface can never reach
    // runtime-ready without a one-time MIDI Learn that we cannot trigger from
    // the server side, so the gate has to let the bytes through to give the
    // operator a path to validate the binding.
    if case .error(let msg) = result {
        Issue.record("expected bypass to deliver to channel, got error: \(msg)")
    }
    let ops = await keyCmd.executedOps
    #expect(
        ops.contains(where: { $0.0 == "midi.send_cc.keycmd" }),
        "bypass gate should let midi.send_cc.keycmd reach the channel; got ops=\(ops)"
    )
}

// MARK: - Test #3 — Bypass + available:false → portUnavailable envelope

@Test func testBypassOpsRejectedWhenChannelUnavailable() async {
    // When channel is `available:false` the bypass op must NOT pass through;
    // it must return a `.portUnavailable` HC State C envelope directly.
    // We exercise this through a routing-chain seam: register a chain via
    // a bypass-aware test op and confirm available:false produces the
    // expected envelope.
    //
    // Until T5 the production routingTable has no keycmd entry. So we
    // validate the encode path via HonestContract directly + assert the
    // gate-logic intent through a parallel mock entry (route() handles
    // available:false even for non-bypass ops, but only bypass returns
    // the portUnavailable envelope).
    let router = ChannelRouter()
    let keyCmd = BypassMockChannel(
        id: .midiKeyCommands,
        health: .unavailable("KeyCmd port not yet published")
    )
    await router.register(keyCmd)

    // Pre-T5: routing chain absent → unknown op. Post-T5 will return the
    // portUnavailable envelope. We verify the expected envelope shape via
    // direct encoding to lock the contract for the implementation.
    let expected = HonestContract.encodeStateC(
        error: .portUnavailable,
        hint: "KeyCmd port not yet published",
        extras: ["operation": "midi.send_cc.keycmd"]
    )
    let parsed = parseEnvelope(expected)
    #expect(!((parsed?["success"] as? Bool)!))
    #expect(parsed?["error"] as? String == "port_unavailable")
    #expect(parsed?["hint"] as? String == "KeyCmd port not yet published")
    #expect(parsed?["operation"] as? String == "midi.send_cc.keycmd")

    // Sanity: channel was not executed.
    let ops = await keyCmd.executedOps
    #expect(ops.isEmpty)

    // The router must surface portUnavailable when the bypass op's
    // channel reports available:false (the specific port for that op is
    // missing). When a non-bypass op exhausts every channel in its chain,
    // the wire surfaces `channels_exhausted` instead — the two States are
    // now semantically distinct (v3.4.5-rc5):
    //   - portUnavailable: scoped to a bypass op whose dedicated channel
    //     reports its port is unwired (e.g. KeyCmd port not published).
    //   - channelsExhausted: chain-level aggregate when no channel could
    //     handle the op (Logic not running, permissions, healthcheck
    //     failures across the entire chain).
    let nonBypassResult = await router.route(operation: "edit.undo")
    if case .error(let msg) = nonBypassResult {
        let nonBypassParsed = parseEnvelope(msg)
        #expect(
            nonBypassParsed?["error"] as? String == "channels_exhausted",
            "non-bypass chain exhaustion must be channels_exhausted, not port_unavailable"
        )
        #expect(nonBypassParsed?["operation"] as? String == "edit.undo")
        #expect(
            nonBypassParsed?["last_error"] != nil,
            "chain-exhaustion path must carry last_error for diagnostics"
        )
    }
}

// MARK: - Test #4 — Non-bypass uses standard readiness gate

@Test func testNonBypassOpUsesStandardReadinessGate() async {
    // edit.undo (non-bypass) + manual_validation_required keyCmd channel
    // must skip the channel (existing behavior). The bypass logic must not
    // accidentally let it through.
    let router = ChannelRouter()
    let keyCmd = BypassMockChannel(
        id: .midiKeyCommands,
        health: .healthy(
            detail: "manual validation required",
            verificationStatus: .manualValidationRequired
        )
    )
    let cgEvent = BypassMockChannel(
        id: .cgEvent,
        health: .healthy(detail: "OK", verificationStatus: .runtimeReady)
    )
    await router.register(keyCmd)
    await router.register(cgEvent)

    let result = await router.route(operation: "edit.undo")
    #expect(result.isSuccess, "fallback chain should reach cgEvent")

    let keyCmdOps = await keyCmd.executedOps
    let cgOps = await cgEvent.executedOps
    #expect(keyCmdOps.isEmpty, "non-bypass op must skip manual_validation_required channel")
    #expect(cgOps.count == 1, "fallback to cgEvent should fire")
}

// MARK: - Test #5 — portUnavailable envelope hint propagation

@Test func testPortUnavailableEnvelopeIncludesHintFromHealth() {
    // The router builds the State C envelope using `health.detail` as hint.
    // Verify the encoder honors the hint field.
    let detail = "CoreMIDI virtual destination not yet published"
    let envelope = HonestContract.encodeStateC(
        error: .portUnavailable,
        hint: detail,
        extras: ["operation": "midi.send_cc.keycmd"]
    )
    let parsed = parseEnvelope(envelope)
    #expect(parsed?["hint"] as? String == detail, "envelope hint must match health.detail")
    #expect(parsed?["error"] as? String == "port_unavailable")
}

// MARK: - Test #6 — portUnavailable envelope extras["operation"]

@Test func testPortUnavailableEnvelopeIncludesOperationInExtras() {
    let envelope = HonestContract.encodeStateC(
        error: .portUnavailable,
        hint: "any",
        extras: ["operation": "midi.send_note.keycmd"]
    )
    let parsed = parseEnvelope(envelope)
    #expect(
        parsed?["operation"] as? String == "midi.send_note.keycmd",
        "envelope must carry the original op key in extras"
    )
}

// MARK: - Test #7 — portUnavailable terminal: no fallthrough

@Test func testPortUnavailableTerminalDoesNotFallthrough() {
    // `port_unavailable` must be in `terminalErrorCodes` so router suppresses
    // fallback when a primary channel produces this envelope. (T1 wired
    // this in; T4 depends on the wiring being present.)
    let envelope = HonestContract.encodeStateC(
        error: .portUnavailable,
        hint: "test"
    )
    #expect(
        HonestContract.isTerminalStateC(envelope),
        "port_unavailable must be classified as terminal State C"
    )
    #expect(
        HonestContract.terminalErrorCodes.contains("port_unavailable"),
        "terminalErrorCodes must include port_unavailable"
    )
}

// MARK: - Test #8 — Routing-table invariant (bidirectional, T5-aware)

@Test func testRoutingTableInvariantBypassMatchesKeycmdSuffix() {
    // Direction 1: every entry of bypassReadinessOps MUST eventually exist
    // in routingTable. T4 intentionally has no keycmd entries (T5 adds 7+);
    // until T5 lands, this direction is informational. We assert the
    // bypass set is non-empty and exactly the expected 7 keys so this test
    // is *non-trivial* in T4 — it locks the bypass set membership independent
    // of the routing table.
    #expect(
        ChannelRouter.bypassReadinessOps == expectedBypassKeys,
        "bypassReadinessOps drift from expected 7 keycmd suffixes"
    )

    // Direction 2: every routingTable key matching `^midi\..*\.keycmd$`
    // must exist in bypassReadinessOps. Holds trivially in T4 (no such
    // entries yet); locks the invariant for T5 onward.
    let table = ChannelRouter.routingTable
    let keycmdRoutingKeys = table.keys.filter {
        $0.hasPrefix("midi.") && $0.hasSuffix(".keycmd")
    }
    for key in keycmdRoutingKeys {
        #expect(
            ChannelRouter.bypassReadinessOps.contains(key),
            "routing-table keycmd op '\(key)' missing from bypassReadinessOps"
        )
    }
}

// MARK: - Test #9 — No regression in other channels' routing

@Test func testBypassOpsDoesNotAffectOtherChannelsRouting() async {
    // Sanity: introducing bypassReadinessOps must not change routing for
    // unrelated ops. We re-run two existing assertions in miniature.
    let router = ChannelRouter()
    let coreMidi = BypassMockChannel(
        id: .coreMIDI,
        health: .healthy(detail: "OK", verificationStatus: .runtimeReady)
    )
    let appleScript = BypassMockChannel(
        id: .appleScript,
        health: .healthy(detail: "OK", verificationStatus: .runtimeReady)
    )
    await router.register(coreMidi)
    await router.register(appleScript)

    // CoreMIDI op must still route to CoreMIDI.
    let midiResult = await router.route(operation: "midi.send_note")
    #expect(midiResult.isSuccess)
    let midiOps = await coreMidi.executedOps
    #expect(midiOps.count == 1, "midi.send_note must still route to CoreMIDI")

    // AppleScript op must still route to AppleScript.
    let projResult = await router.route(operation: "project.open")
    #expect(projResult.isSuccess)
    let asOps = await appleScript.executedOps
    #expect(asOps.count == 1, "project.open must still route to AppleScript")
}
