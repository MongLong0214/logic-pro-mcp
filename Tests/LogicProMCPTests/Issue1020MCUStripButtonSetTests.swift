import Foundation
import Testing
@testable import LogicProMCP

// The Mackie Control Mute, Solo and Rec buttons TOGGLE on a press: #862 measured how Logic handles
// a button, and #1020 followed that to the strip buttons, where `enabled: true` on an already-muted
// track unmuted it and `enabled: false` sent a bare release Logic ignored. So `track.set_mute` /
// `set_solo` / `set_arm` on MCU are a SET only if the channel reads the track first, presses once
// when it differs, and confirms by reading again. These tests drive MCUChannel with a surface that
// behaves as Logic does — a press flips the state it holds — and an AXReadback that reads that
// surface, so a handler that presses without reading, presses twice, or answers State A without
// confirming is seen doing it. Nothing here reads a clock: waits go through CountingSleeper.

// MARK: - Fixtures

private struct FlagKey: Hashable {
    let function: MCUProtocol.ButtonFunction
    let track: Int
}

/// A Logic that toggles. `.toggles`: a strip press flips the state held for that track.
/// `.ignoresPress`: the press is recorded and nothing moves. `.unreadableAfterPress`: the press
/// lands and the state can no longer be read. A track with no entry reads nil, which is
/// "could not read", not "off".
///
/// A strip press names `bank * 8 + strip`, where `bank` is the window THIS surface is showing, not
/// the one the channel believes it is showing: a press that lands in the wrong bank toggles the
/// wrong track here as it does in Logic. With `windows` set, the bank is Logic's as measured on
/// 12.3 (#862): each bank press moves one window and redraws the LCD upper row it lands on through
/// the channel's own feedback path (`LCDBankSurface.lcdFrame`, delivered reentrantly from inside
/// `send` as `LCDBankSurface` does), and a press past either end redraws the row it is already on.
/// A bank press whose 1-based ordinal is in `absorbedBankPresses` neither moves nor redraws: the
/// second of two presses that Logic took as one (#1020 review round 1). With `windows` nil every
/// bank press moves and nothing redraws, so a walk has no readback at all.
private actor ToggleSurface: MCUTransportProtocol {
    enum Response: Sendable { case toggles, ignoresPress, unreadableAfterPress }

    private(set) var sentBytes: [[UInt8]] = []
    private(set) var bank = 0
    private var states: [FlagKey: Bool]
    private let response: Response
    private let windows: [String]?
    private let absorbedBankPresses: Set<Int>
    private var bankPressesSeen = 0
    private var channel: MCUChannel?

    init(
        response: Response = .toggles,
        states: [FlagKey: Bool] = [:],
        windows: [String]? = nil,
        absorbedBankPresses: Set<Int> = []
    ) {
        self.response = response
        self.states = states
        self.windows = windows
        self.absorbedBankPresses = absorbedBankPresses
    }

    func attach(channel: MCUChannel) {
        self.channel = channel
    }

    /// What Logic does on connect: one full upper-row write of the window it is showing.
    func seedUpperRow() async {
        guard let windows else { return }
        await deliverUpperRow(windows[bank])
    }

    func send(_ bytes: [UInt8]) async {
        sentBytes.append(bytes)
        guard let button = MCUProtocol.decodeButton(bytes), button.on else { return }
        switch button.function {
        case .bankLeft, .bankRight:
            bankPressesSeen += 1
            let step = button.function == .bankRight ? 1 : -1
            guard let windows else {
                bank = max(0, bank + step)
                return
            }
            guard !absorbedBankPresses.contains(bankPressesSeen) else { return }
            bank = min(max(bank + step, 0), windows.count - 1)
            await deliverUpperRow(windows[bank])
        case .mute, .solo, .recArm:
            let key = FlagKey(function: button.function, track: bank * 8 + button.strip)
            switch response {
            case .toggles:
                if let current = states[key] { states[key] = !current }
            case .ignoresPress:
                break
            case .unreadableAfterPress:
                states[key] = nil
            }
        default:
            break
        }
    }

    func read(_ function: MCUProtocol.ButtonFunction, track: Int) -> Bool? {
        states[FlagKey(function: function, track: track)]
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {}
    func stop() {}
    func endpointCensus() -> VirtualMIDIEndpointCensus { .none }

    private func deliverUpperRow(_ row: String) async {
        guard let channel else { return }
        await channel.handleFeedback(.sysEx(LCDBankSurface.lcdFrame(row, offset: 0)))
    }
}

private struct SetRig {
    let channel: MCUChannel
    let surface: ToggleSurface
    let sleeper: CountingSleeper
}

private func readback(of surface: ToggleSurface) -> MCUChannel.AXReadback {
    MCUChannel.AXReadback(
        readVolume: { _ in nil },
        readPan: { _ in nil },
        readMuted: { track in await surface.read(.mute, track: track) },
        readSoloed: { track in await surface.read(.solo, track: track) },
        readArmed: { track in await surface.read(.recArm, track: track) }
    )
}

private func makeSetRig(response: ToggleSurface.Response = .toggles, states: [FlagKey: Bool]) -> SetRig {
    let surface = ToggleSurface(response: response, states: states)
    let sleeper = CountingSleeper()
    let channel = MCUChannel(
        transport: surface,
        cache: StateCache(),
        axReadback: readback(of: surface),
        sleep: sleeper.closure
    )
    return SetRig(channel: channel, surface: surface, sleeper: sleeper)
}

/// Eight distinct six-character names per window, so every bank move redraws a different row.
private func windowRow(_ bank: Int) -> String {
    (0..<8).map { "B\(bank)S\($0)".padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
}

/// Three windows: tracks 0-7, 8-15 and 16-23.
private let threeWindows = (0..<3).map(windowRow)

/// A rig whose surface banks the way Logic 12.3 does, with the upper row already drawn unless
/// `seedUpperRow` is false (a server that has never received the row).
private func makeBankedSetRig(
    states: [FlagKey: Bool],
    absorbedBankPresses: Set<Int> = [],
    seedUpperRow: Bool = true
) async -> SetRig {
    let surface = ToggleSurface(states: states, windows: threeWindows, absorbedBankPresses: absorbedBankPresses)
    let sleeper = CountingSleeper()
    let channel = MCUChannel(
        transport: surface,
        cache: StateCache(),
        axReadback: readback(of: surface),
        sleep: sleeper.closure
    )
    await surface.attach(channel: channel)
    if seedUpperRow { await surface.seedUpperRow() }
    return SetRig(channel: channel, surface: surface, sleeper: sleeper)
}

/// Every Mute, Solo or Rec strip byte on the wire, press or release.
private func stripToggleBytes(_ sent: [[UInt8]]) -> [[UInt8]] {
    sent.filter { bytes in
        guard let button = MCUProtocol.decodeButton(bytes) else { return false }
        switch button.function {
        case .mute, .solo, .recArm: return true
        default: return false
        }
    }
}

/// Twenty-one strips with distinct six-character names: bank 0 is strips 0-7, bank 1 is 8-15, and
/// Logic's last bank stops at the last strip, so "bank 2" shows strips 13-20.
private let twentyOneDistinct = (0..<21).map { String(format: "Trk%02d", $0) }

/// The measured Korean fixture's upper rows (2026-09-27, 19 tracks + St Out + Master): nine
/// `DelCls` and eight `StdGrn` in a row, so a bank step's new row repeats names from the old one.
private let measuredKoStrips = ["AbsZer", "Audio1"] + Array(repeating: "DelCls", count: 9)
    + Array(repeating: "StdGrn", count: 8) + ["St Out", "Master"]

/// Which tracks read armed on a clamped-bank surface: those armed at the start, each flipped by
/// every Rec press that landed on it (the surface records the track a strip named when pressed).
private func armedTracks(on surface: LCDBankSurface, initially: Set<Int>) async -> Set<Int> {
    var armed = initially
    for press in await surface.buttonPresses where press.function == .recArm {
        if armed.contains(press.track) { armed.remove(press.track) } else { armed.insert(press.track) }
    }
    return armed
}

private struct ClampRig {
    let channel: MCUChannel
    let surface: LCDBankSurface
}

/// A rig on Logic's clamped bank model (`LCDBankSurface.strips`), upper row drawn at strip 0, with
/// an arm reading that follows the presses.
private func makeClampRig(names: [String], armed: Set<Int> = []) async -> ClampRig {
    let surface = LCDBankSurface(response: .strips(names))
    let stripCount = names.count
    let channel = MCUChannel(
        transport: surface,
        cache: StateCache(),
        axReadback: MCUChannel.AXReadback(
            readVolume: { _ in nil },
            readPan: { _ in nil },
            readArmed: { track in
                track < stripCount ? await armedTracks(on: surface, initially: armed).contains(track) : nil
            }
        ),
        sleep: CountingSleeper().closure
    )
    await surface.attach(channel: channel)
    await surface.seedUpperRow(LCDBankSurface.stripsRow(names, from: 0))
    return ClampRig(channel: channel, surface: surface)
}

/// A momentary press: Note On velocity 127, then velocity 0, on the strip's note.
private func pressPair(_ function: MCUProtocol.ButtonFunction, strip: Int) -> [[UInt8]] {
    [
        MCUProtocol.encodeButton(function, strip: strip, on: true),
        MCUProtocol.encodeButton(function, strip: strip, on: false),
    ]
}

/// A Boolean, or its absence, as text. On this toolchain `#expect(<Bool> == <Bool>)` passes
/// whatever the operands are (#393), so two states are compared through this projection.
private func bit(_ value: Bool?) -> String {
    value.map { $0 ? "on" : "off" } ?? "unread"
}

private func setEnvelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

struct Issue1020Toggle: Sendable, CustomTestStringConvertible {
    let operation: String
    let function: MCUProtocol.ButtonFunction
    var testDescription: String { operation }
}

private let toggles: [Issue1020Toggle] = [
    Issue1020Toggle(operation: "track.set_mute", function: .mute),
    Issue1020Toggle(operation: "track.set_solo", function: .solo),
    Issue1020Toggle(operation: "track.set_arm", function: .recArm),
]

/// The wait between readback polls, and how many waits a press that never confirms takes: the
/// budget is ten polls, and there is no wait after the last one.
private let pollWait: Duration = .milliseconds(50)
private let waitsForAnUnconfirmedPress = 9

// MARK: - Tests

@Suite("Issue1020MCUStripButtonSetTests")
struct Issue1020MCUStripButtonSetTests {
    @Test(arguments: toggles, [true, false])
    func alreadyInTheRequestedStateSendsNothingAndAnswersStateA(_ toggle: Issue1020Toggle, enabled: Bool) async throws {
        let rig = makeSetRig(states: [FlagKey(function: toggle.function, track: 2): enabled])

        let result = await rig.channel.execute(
            operation: toggle.operation, params: ["index": "2", "enabled": "\(enabled)"]
        )

        #expect(await rig.surface.sentBytes.isEmpty)
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(verified)
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!attempted)
        let observed = try #require(obj["observed"] as? Bool)
        #expect(bit(observed) == bit(enabled))
        #expect(obj["track"] as? Int == 2)
        let echoed = try #require(obj["enabled"] as? Bool)
        #expect(bit(echoed) == bit(enabled))
        #expect(obj["verification_source"] as? String == "ax_value")
        #expect(await rig.sleeper.requested.isEmpty)
        // The surface still holds what it held: nothing toggled it.
        #expect(bit(await rig.surface.read(toggle.function, track: 2)) == bit(enabled))
    }

    @Test(arguments: toggles, [true, false])
    func differsAndTheReadbackFlipsIsOnePressAndStateA(_ toggle: Issue1020Toggle, enabled: Bool) async throws {
        let rig = makeSetRig(states: [FlagKey(function: toggle.function, track: 2): !enabled])

        let result = await rig.channel.execute(
            operation: toggle.operation, params: ["index": "2", "enabled": "\(enabled)"]
        )

        // Exactly one press and its release, on this strip's note, and nothing else.
        #expect(await rig.surface.sentBytes == pressPair(toggle.function, strip: 2))
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(verified)
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(attempted)
        let observed = try #require(obj["observed"] as? Bool)
        #expect(bit(observed) == bit(enabled))
        #expect(obj["write_source"] as? String == "mcu")
        #expect(obj["verification_source"] as? String == "ax_value")
        // The first read after the press confirmed it, so no wait was taken.
        #expect(await rig.sleeper.requested.isEmpty)
        #expect(bit(await rig.surface.read(toggle.function, track: 2)) == bit(enabled))
    }

    /// The bytes of the case #1020 named: clearing a lit mute is a press with its release, not
    /// the bare velocity-0 note the old branch sent.
    @Test func enabledFalseOnAMutedTrackSendsAPressNotABareRelease() async throws {
        let rig = makeSetRig(states: [FlagKey(function: .mute, track: 3): true])

        let result = await rig.channel.execute(operation: "track.set_mute", params: ["index": "3", "enabled": "false"])

        let sent = await rig.surface.sentBytes
        // Mute strip 3 is note 0x13.
        #expect(sent == [[0x90, 0x13, 0x7F], [0x90, 0x13, 0x00]])
        #expect(sent.first != [0x90, 0x13, 0x00], "a bare release is not a press")
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        let observed = try #require(obj["observed"] as? Bool)
        #expect(!observed)
        let held = try #require(await rig.surface.read(.mute, track: 3))
        #expect(!held)
    }

    @Test(arguments: toggles, [true, false])
    func unreadableBeforeThePressSendsNothingAndRefusesNonTerminally(_ toggle: Issue1020Toggle, enabled: Bool) async throws {
        // No entry for track 2: the read answers nil, which is not "off".
        let rig = makeSetRig(states: [:])

        let result = await rig.channel.execute(
            operation: toggle.operation, params: ["index": "2", "enabled": "\(enabled)"]
        )

        #expect(await rig.surface.sentBytes.isEmpty)
        #expect(!result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "C")
        #expect(obj["error"] as? String == "track_state_unreadable")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(obj["observed"] is NSNull)
        #expect(obj["track"] as? Int == 2)
        #expect(obj["operation"] as? String == toggle.operation)
        let hint = try #require(obj["hint"] as? String)
        #expect(hint.contains("sent nothing"))
        // The shape ChannelRouter walks past (ChannelRouter.swift, the `.error` arm after the
        // fallback-unsafe and terminal checks): a typed State C whose code is not terminal.
        #expect(HonestContract.stateCErrorCode(result.message) == "track_state_unreadable")
        #expect(!HonestContract.isTerminalStateC(result.message))
        #expect(!HonestContract.isFallbackUnsafeStateC(result.message))
        #expect(await rig.sleeper.requested.isEmpty)
    }

    /// Through the real router: with no Accessibility channel registered, MCU is the first channel
    /// that runs; its refusal is walked past, the next channel is tried, and the refusal rides
    /// along on that channel's answer as the one the router walked past.
    @Test func theRouterWalksPastTheUnreadableRefusalToTheNextChannel() async throws {
        let surface = ToggleSurface(states: [:])
        let sleeper = CountingSleeper()
        let channel = MCUChannel(
            transport: surface, cache: StateCache(), axReadback: readback(of: surface), sleep: sleeper.closure
        )
        // Health is earned the way a live server earns it: from a received feedback frame.
        await channel.handleFeedback(.noteOn(channel: 0, note: 0x5E, velocity: 0x7F))
        let health = await channel.healthCheck()
        #expect(health.ready, "the router must execute MCU, not skip it: \(health.detail)")

        let router = ChannelRouter()
        let cgEvent = MockChannel(id: .cgEvent, successEnvelope: HonestContract.encodeStateA(extras: ["track": 2]))
        await router.register(channel)
        await router.register(cgEvent)

        let result = await router.route(operation: "track.set_mute", params: ["index": "2", "enabled": "true"])

        #expect(await surface.sentBytes.isEmpty)
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["fallback_from_channel"] as? String == ChannelID.mcu.rawValue)
        #expect(obj["fallback_from_error"] as? String == "track_state_unreadable")
        let executed = await cgEvent.executedOps
        #expect(executed.count == 1)
        #expect(executed.first?.0 == "track.set_mute")
        #expect(executed.first?.1 == ["index": "2", "enabled": "true"])
    }

    @Test(arguments: toggles, [true, false])
    func differsAndTheReadbackNeverFlipsIsOnePressAndStateB(_ toggle: Issue1020Toggle, enabled: Bool) async throws {
        let rig = makeSetRig(response: .ignoresPress, states: [FlagKey(function: toggle.function, track: 2): !enabled])

        let result = await rig.channel.execute(
            operation: toggle.operation, params: ["index": "2", "enabled": "\(enabled)"]
        )

        // One press and its release, and NOT a second press: on a toggle that is the opposite write.
        #expect(await rig.surface.sentBytes == pressPair(toggle.function, strip: 2))
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "B")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(!verified)
        #expect(obj["reason"] as? String == "readback_mismatch")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(attempted)
        let observed = try #require(obj["observed"] as? Bool)
        #expect(observed == !enabled)
        // The whole poll budget was spent, waiting between polls and not after the last.
        #expect(await rig.sleeper.count(of: pollWait) == waitsForAnUnconfirmedPress)
        #expect(await rig.sleeper.requested.count == waitsForAnUnconfirmedPress)
    }

    @Test(arguments: toggles)
    func unreadableAfterThePressIsOnePressAndStateBUnavailable(_ toggle: Issue1020Toggle) async throws {
        let rig = makeSetRig(response: .unreadableAfterPress, states: [FlagKey(function: toggle.function, track: 2): false])

        let result = await rig.channel.execute(operation: toggle.operation, params: ["index": "2", "enabled": "true"])

        #expect(await rig.surface.sentBytes == pressPair(toggle.function, strip: 2))
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "B")
        #expect(obj["reason"] as? String == "readback_unavailable")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(attempted)
        #expect(obj["observed"] is NSNull)
        #expect(await rig.sleeper.count(of: pollWait) == waitsForAnUnconfirmedPress)
    }

    /// The reading is keyed by TRACK and the press by strip: a track in another bank is read as
    /// itself and pressed as its strip, inside the bank walk every strip-relative write takes.
    @Test func aTrackInAnotherBankIsReadAsItselfAndPressedAsItsStrip() async throws {
        // Track 11 → bank 1, strip 3.
        let rig = await makeBankedSetRig(states: [FlagKey(function: .mute, track: 11): false])

        let result = await rig.channel.execute(operation: "track.set_mute", params: ["index": "11", "enabled": "true"])

        let expected = [pressPair(.bankRight, strip: 0), pressPair(.mute, strip: 3), pressPair(.bankLeft, strip: 0)]
            .flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["track"] as? Int == 11)
        let held = try #require(await rig.surface.read(.mute, track: 11))
        #expect(held)
    }

    // MARK: - The bank walk under a strip write (#1020 review round 1, R1-001)

    /// The regression witness. Logic 12.3 moved ONE bank for two bank presses sent back to back
    /// (docs/observations/2026-09-27-ko-KR-a-bank-step-answers-from-the-redrawn-upper-row.json);
    /// here the second press is absorbed. Before the walk was verified, the strip byte went out
    /// on bank 1: `enabled: false` for armed track 16 pressed strip 0 there, arming track 8 and
    /// leaving 16 armed. Now the step that did not move stops the walk, no strip byte is sent,
    /// the step that did move is walked back, and the refusal is one the router walks past.
    @Test func aSecondBankPressThatDoesNotMoveSendsNoStripByteAndWalksBack() async throws {
        let states: [FlagKey: Bool] = [
            FlagKey(function: .recArm, track: 16): true,
            FlagKey(function: .recArm, track: 8): false,
        ]
        let rig = await makeBankedSetRig(states: states, absorbedBankPresses: [2])

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "16", "enabled": "false"])

        let sent = await rig.surface.sentBytes
        #expect(stripToggleBytes(sent).isEmpty, "no strip byte may go out on a bank that was not reached")
        #expect(bit(await rig.surface.read(.recArm, track: 8)) == "off")
        #expect(bit(await rig.surface.read(.recArm, track: 16)) == "on")
        // Two presses toward bank 2 (the second absorbed), one back for the one that moved.
        let expected = [pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0), pressPair(.bankLeft, strip: 0)]
            .flatMap { $0 }
        #expect(sent == expected)
        #expect(await rig.surface.bank == 0)
        #expect(await rig.channel.currentBank == 0)

        #expect(!result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "C")
        #expect(obj["error"] as? String == "bank_walk_unverified")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["banks_requested"] as? Int == 2)
        #expect(obj["bank_presses_sent"] as? Int == 3)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
        let windows = try #require(obj["step_windows"] as? [String])
        #expect(windows == [threeWindows[1], threeWindows[1], threeWindows[0]])
        #expect(obj["operation"] as? String == "track.set_arm")
        #expect(obj["channel"] as? String == "MCU")
        let hint = try #require(obj["hint"] as? String)
        #expect(hint.contains("not pressed"))
        #expect(!HonestContract.isTerminalStateC(result.message))
        #expect(!HonestContract.isFallbackUnsafeStateC(result.message))

        // The same cadence through the real router: the refusal is walked past to the next channel.
        let routed = await makeBankedSetRig(states: states, absorbedBankPresses: [2])
        await routed.channel.handleFeedback(.noteOn(channel: 0, note: 0x5E, velocity: 0x7F))
        let router = ChannelRouter()
        let cgEvent = MockChannel(id: .cgEvent, successEnvelope: HonestContract.encodeStateA(extras: ["track": 16]))
        await router.register(routed.channel)
        await router.register(cgEvent)

        let routedResult = await router.route(operation: "track.set_arm", params: ["index": "16", "enabled": "false"])

        #expect(stripToggleBytes(await routed.surface.sentBytes).isEmpty)
        #expect(bit(await routed.surface.read(.recArm, track: 8)) == "off")
        let routedObj = try setEnvelope(routedResult)
        #expect(routedObj["fallback_from_channel"] as? String == ChannelID.mcu.rawValue)
        #expect(routedObj["fallback_from_error"] as? String == "bank_walk_unverified")
        #expect(await cgEvent.executedOps.count == 1)
    }

    /// Two banks, every step moving: one strip press, on strip 0 of bank 2, State A, and the walk
    /// back reaches bank 0.
    @Test func aTwoBankWalkWhoseStepsAllMovePressesTheRightStripAndWalksBack() async throws {
        let rig = await makeBankedSetRig(states: [
            FlagKey(function: .recArm, track: 16): true,
            FlagKey(function: .recArm, track: 8): false,
        ])

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "16", "enabled": "false"])

        let expected = [
            pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0),
            pressPair(.recArm, strip: 0),
            pressPair(.bankLeft, strip: 0), pressPair(.bankLeft, strip: 0),
        ].flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(bit(await rig.surface.read(.recArm, track: 16)) == "off")
        #expect(bit(await rig.surface.read(.recArm, track: 8)) == "off")
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(attempted)
        #expect(obj["banks_moved"] as? Int == 2)
        #expect(obj["bank_presses_sent"] as? Int == 4)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
        #expect(await rig.surface.bank == 0)
        #expect(await rig.channel.currentBank == 0)
        // Each step waited for its own redraw and one quiet poll: two polls per step, four steps.
        #expect(await rig.sleeper.count(of: .milliseconds(MCUChannel.bankWindowPollMilliseconds)) == 8)
    }

    /// No upper row has ever been received: a bank step has nothing to be compared against, so
    /// nothing is sent at all, and the refusal is one the router walks past.
    @Test func aWalkWithNoUpperRowSendsNothingAndTheRouterWalksPast() async throws {
        let states: [FlagKey: Bool] = [FlagKey(function: .recArm, track: 16): true]
        let rig = await makeBankedSetRig(states: states, seedUpperRow: false)

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "16", "enabled": "false"])

        #expect(await rig.surface.sentBytes.isEmpty)
        #expect(!result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "C")
        #expect(obj["error"] as? String == "bank_walk_unverified")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(obj["bank_presses_sent"] as? Int == 0)
        #expect(obj["banks_moved"] as? Int == 0)
        #expect(obj["banks_requested"] as? Int == 2)
        let windows = try #require(obj["step_windows"] as? [String])
        #expect(windows.isEmpty)
        #expect(!HonestContract.isTerminalStateC(result.message))
        #expect(await rig.sleeper.requested.isEmpty)

        let routed = await makeBankedSetRig(states: states, seedUpperRow: false)
        await routed.channel.handleFeedback(.noteOn(channel: 0, note: 0x5E, velocity: 0x7F))
        let router = ChannelRouter()
        let cgEvent = MockChannel(id: .cgEvent, successEnvelope: HonestContract.encodeStateA(extras: ["track": 16]))
        await router.register(routed.channel)
        await router.register(cgEvent)

        let routedResult = await router.route(operation: "track.set_arm", params: ["index": "16", "enabled": "false"])

        #expect(await routed.surface.sentBytes.isEmpty)
        let routedObj = try setEnvelope(routedResult)
        #expect(routedObj["state"] as? String == "A")
        #expect(routedObj["fallback_from_error"] as? String == "bank_walk_unverified")
        #expect(await cgEvent.executedOps.count == 1)
    }

    /// The strip write happened and was confirmed; the one restore press was absorbed. The
    /// operation's own answer stands, it says the restore did not complete, and the bookkeeping is
    /// the bank the surface is actually on.
    @Test func aRestoreStepThatDoesNotMoveLeavesTheReplyAndTheBookkeepingOnTheReachedBank() async throws {
        // Track 11 → bank 1, strip 3. Bank press 1 is the walk out, press 2 the restore.
        let rig = await makeBankedSetRig(states: [FlagKey(function: .mute, track: 11): false], absorbedBankPresses: [2])

        let result = await rig.channel.execute(operation: "track.set_mute", params: ["index": "11", "enabled": "true"])

        let expected = [pressPair(.bankRight, strip: 0), pressPair(.mute, strip: 3), pressPair(.bankLeft, strip: 0)]
            .flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        let held = try #require(await rig.surface.read(.mute, track: 11))
        #expect(held)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(!restored)
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["bank_presses_sent"] as? Int == 2)
        #expect(await rig.surface.bank == 1)
        #expect(await rig.channel.currentBank == 1)
    }

    // MARK: - Logic stops the last bank at the last strip (#1020, measured 2026-09-27)

    /// Track 16 of 21 strips: the second bank-right step shows strips 13-20, a row that differs
    /// from the one before and redraws quietly, so it "moved" — but only five strips, and strip 0
    /// there is track 13. The row reads as the old one slid by five, so one probe Bank Right is
    /// sent; it redraws the same row (Logic's last bank), so the step may have been clamped:
    /// nothing is pressed, both steps that moved the window are walked back, and the refusal is
    /// the non-terminal one.
    @Test func theClampedLastBankIsRefusedAndWalkedBackWithNoStripByte() async throws {
        let rig = await makeClampRig(names: twentyOneDistinct)

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "16", "enabled": "true"])

        let expected = [
            pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0),
            pressPair(.bankLeft, strip: 0), pressPair(.bankLeft, strip: 0),
        ].flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(await rig.surface.buttonPresses.isEmpty, "no strip byte on a window that is not bank 2")
        #expect(await armedTracks(on: rig.surface, initially: []).isEmpty)
        #expect(await rig.surface.stripOffset == 0)
        #expect(await rig.channel.currentBank == 0)

        #expect(!result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "C")
        #expect(obj["error"] as? String == "bank_walk_unverified")
        let attempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["banks_requested"] as? Int == 2)
        #expect(obj["bank_presses_sent"] as? Int == 5, "the probe press is counted as sent")
        #expect(obj["bank_steps_disambiguated"] as? Int == 0)
        let short = try #require(obj["bank_step_short_of_eight"] as? Bool)
        #expect(short)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
        let unaligned = try #require(obj["bank_window_unaligned"] as? Bool)
        #expect(!unaligned)
        let hint = try #require(obj["hint"] as? String)
        #expect(hint.contains("fewer than eight strips"))
        #expect(!HonestContract.isTerminalStateC(result.message))

        // Home and aligned again: a bank-0 write needs no walk and lands on its own track.
        let bank0 = await rig.channel.execute(operation: "track.set_arm", params: ["index": "3", "enabled": "true"])
        #expect(bank0.isSuccess)
        #expect(try setEnvelope(bank0)["state"] as? String == "A")
        #expect(await armedTracks(on: rig.surface, initially: []) == [3])
    }

    /// Track 15 of 21: bank 1 is a full eight-strip shift, so the arm lands on track 15.
    @Test func theFullBankBeforeTheClampedOneStillArmsItsTrack() async throws {
        let rig = await makeClampRig(names: twentyOneDistinct)

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "15", "enabled": "true"])

        let expected = [pressPair(.bankRight, strip: 0), pressPair(.recArm, strip: 7), pressPair(.bankLeft, strip: 0)]
            .flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(await rig.surface.buttonPresses == [LCDBankSurface.ButtonPress(function: .recArm, track: 15)])
        #expect(await armedTracks(on: rig.surface, initially: []) == [15])
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["banks_moved"] as? Int == 1)
        let short = try #require(obj["bank_step_short_of_eight"] as? Bool)
        #expect(!short)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
        #expect(await rig.channel.currentBank == 0)
    }

    /// `mixer.bank` right twice lands on the clamped bank (strips 13-20) and says so the way it
    /// always has, with the bookkeeping at 2. A strip write after it — in "bank 2", where no walk
    /// is needed, or in bank 0 — is refused with nothing sent, because the window's offset is not
    /// a multiple of eight. `mixer.bank` left to the end (the step that redraws unchanged) clears it.
    @Test func mixerBankOntoTheClampedBankThenAStripWriteIsRefusedWithNothingSent() async throws {
        let rig = await makeClampRig(names: twentyOneDistinct)

        let bank = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "right", "count": "2"])
        #expect(bank.isSuccess)
        let bankObj = try setEnvelope(bank)
        #expect(bankObj["state"] as? String == "A")
        #expect(bankObj["banks_moved"] as? Int == 2)
        #expect(bankObj["bank_presses_sent"] as? Int == 3, "two steps and the probe that found the last bank")
        #expect(bankObj["bank_steps_disambiguated"] as? Int == 0)
        #expect(await rig.surface.stripOffset == 13)
        #expect(await rig.channel.currentBank == 2)
        let sentAfterBank = await rig.surface.sentBytes.count

        for track in ["16", "3"] {
            let arm = await rig.channel.execute(operation: "track.set_arm", params: ["index": track, "enabled": "true"])
            #expect(!arm.isSuccess)
            let obj = try setEnvelope(arm)
            #expect(obj["error"] as? String == "bank_walk_unverified")
            #expect(obj["bank_presses_sent"] as? Int == 0)
            let attempted = try #require(obj["write_attempted"] as? Bool)
            #expect(!attempted)
            let unaligned = try #require(obj["bank_window_unaligned"] as? Bool)
            #expect(unaligned)
            #expect(!HonestContract.isTerminalStateC(arm.message))
        }
        #expect(await rig.surface.sentBytes.count == sentAfterBank, "nothing is sent on an unaligned window")
        #expect(await rig.surface.buttonPresses.isEmpty)

        _ = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "left", "count": "3"])
        #expect(await rig.surface.stripOffset == 0)
        #expect(await rig.channel.currentBank == 0)
        let cleared = await rig.channel.execute(operation: "track.set_arm", params: ["index": "3", "enabled": "true"])
        #expect(try setEnvelope(cleared)["state"] as? String == "A")
        #expect(await armedTracks(on: rig.surface, initially: []) == [3])
    }

    /// On the measured Korean rows the bank-1 row begins with three `DelCls`, the names bank 0
    /// ended on, so the step from bank 0 reads exactly like a five-strip shift. One probe Bank
    /// Right still moves (8 -> 13), so that step was not Logic's last and moved a full eight; the
    /// Bank Left after it redraws the bank-1 row byte for byte, and the arm lands on track 15.
    @Test func anAmbiguousStepThatAProbeProvesFullArmsItsTrack() async throws {
        let rig = await makeClampRig(names: measuredKoStrips)

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "15", "enabled": "true"])

        let expected = [
            pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0), pressPair(.bankLeft, strip: 0),
            pressPair(.recArm, strip: 7), pressPair(.bankLeft, strip: 0),
        ].flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(await rig.surface.buttonPresses == [LCDBankSurface.ButtonPress(function: .recArm, track: 15)])
        #expect(await armedTracks(on: rig.surface, initially: []) == [15])
        #expect(await rig.surface.stripOffset == 0)
        #expect(await rig.channel.currentBank == 0)
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["bank_presses_sent"] as? Int == 4)
        #expect(obj["bank_steps_disambiguated"] as? Int == 1)
        let short = try #require(obj["bank_step_short_of_eight"] as? Bool)
        #expect(!short)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
    }

    /// Track 16 on the Korean rows: the first step is proved full by its probe, the second
    /// (8 -> 13) reads as a slide too, and its probe redraws the same row — Logic's last bank — so
    /// nothing is pressed and both window moves are walked back.
    @Test func onRepeatedNamesTheClampedLastBankIsStillRefusedAndWalkedHome() async throws {
        let rig = await makeClampRig(names: measuredKoStrips)

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "16", "enabled": "true"])

        let expected = [
            pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0), pressPair(.bankLeft, strip: 0),
            pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0),
            pressPair(.bankLeft, strip: 0), pressPair(.bankLeft, strip: 0),
        ].flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(await rig.surface.buttonPresses.isEmpty)
        #expect(await armedTracks(on: rig.surface, initially: []).isEmpty)
        #expect(await rig.surface.stripOffset == 0)
        #expect(await rig.channel.currentBank == 0)
        #expect(!result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["error"] as? String == "bank_walk_unverified")
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["bank_presses_sent"] as? Int == 7)
        #expect(obj["bank_steps_disambiguated"] as? Int == 1)
        let short = try #require(obj["bank_step_short_of_eight"] as? Bool)
        #expect(short)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
        #expect(!HonestContract.isTerminalStateC(result.message))
    }

    /// `mixer.bank` right on the Korean rows: the step reads as a slide, the probe proves it full,
    /// and the window is left on bank 1 with no unaligned flag, so a bank-1 write needs no walk.
    @Test func mixerBankProbesAnAmbiguousStepAndLeavesTheWindowAligned() async throws {
        let rig = await makeClampRig(names: measuredKoStrips)

        let bank = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "right"])

        let expected = [pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0), pressPair(.bankLeft, strip: 0)]
            .flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(await rig.surface.stripOffset == 8)
        #expect(await rig.channel.currentBank == 1)
        let obj = try setEnvelope(bank)
        #expect(obj["state"] as? String == "A")
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["bank_presses_sent"] as? Int == 3)
        #expect(obj["bank_steps_disambiguated"] as? Int == 1)

        // Aligned: track 15 is strip 7 of the bank already showing, pressed with no walk.
        let arm = await rig.channel.execute(operation: "track.set_arm", params: ["index": "15", "enabled": "true"])
        #expect(try setEnvelope(arm)["state"] as? String == "A")
        #expect(await armedTracks(on: rig.surface, initially: []) == [15])
    }

    /// The probe's Bank Left must redraw the ambiguous step's row byte for byte. Here it redraws a
    /// different row, so the probe settles nothing: no strip byte, the walk goes home, and the
    /// refusal says the probe was unresolved.
    @Test func aProbeWhoseBankLeftReturnsADifferentRowIsRefused() async throws {
        let rig = await makeClampRig(names: measuredKoStrips)
        await rig.surface.redrawNextBankLeft(as: LCDBankSurface.stripsRow(twentyOneDistinct, from: 0))

        let result = await rig.channel.execute(operation: "track.set_arm", params: ["index": "15", "enabled": "true"])

        let expected = [
            pressPair(.bankRight, strip: 0), pressPair(.bankRight, strip: 0), pressPair(.bankLeft, strip: 0),
            pressPair(.bankLeft, strip: 0),
        ].flatMap { $0 }
        #expect(await rig.surface.sentBytes == expected)
        #expect(await rig.surface.buttonPresses.isEmpty)
        #expect(await rig.surface.stripOffset == 0)
        #expect(await rig.channel.currentBank == 0)
        #expect(!result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["error"] as? String == "bank_walk_unverified")
        #expect(obj["banks_moved"] as? Int == 0)
        #expect(obj["bank_steps_disambiguated"] as? Int == 0)
        let unresolved = try #require(obj["bank_probe_unresolved"] as? Bool)
        #expect(unresolved)
        let restored = try #require(obj["bank_restored"] as? Bool)
        #expect(restored)
        #expect(!HonestContract.isTerminalStateC(result.message))
    }

    /// `track.select` is not a toggle and is left exactly as it was: one press, State B
    /// `readback_unavailable` from the LED echo, no reading required.
    @Test func selectIsUntouchedByTheSetPath() async throws {
        let rig = makeSetRig(states: [:])

        let result = await rig.channel.execute(operation: "track.select", params: ["index": "2"])

        #expect(await rig.surface.sentBytes == pressPair(.select, strip: 2))
        #expect(result.isSuccess)
        let obj = try setEnvelope(result)
        #expect(obj["state"] as? String == "B")
        #expect(obj["reason"] as? String == "readback_unavailable")
        #expect(obj["verification_source"] as? String == "mcu_led_echo")
        #expect(obj["write_attempted"] == nil)
    }

    /// A channel built without any AXReadback — the shape every pre-#1020 test used — has no
    /// reading at all, and the answer is the same refusal as an unreadable track.
    @Test func noReadbackAtAllIsTheSameRefusal() async throws {
        let surface = ToggleSurface(states: [FlagKey(function: .mute, track: 0): false])
        let channel = MCUChannel(transport: surface, cache: StateCache())

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "0", "enabled": "true"])

        #expect(await surface.sentBytes.isEmpty)
        #expect(!result.isSuccess)
        #expect(HonestContract.stateCErrorCode(result.message) == "track_state_unreadable")
    }
}
