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
private actor ToggleSurface: MCUTransportProtocol {
    enum Response: Sendable { case toggles, ignoresPress, unreadableAfterPress }

    private(set) var sentBytes: [[UInt8]] = []
    private var bank = 0
    private var states: [FlagKey: Bool]
    private let response: Response

    init(response: Response = .toggles, states: [FlagKey: Bool] = [:]) {
        self.response = response
        self.states = states
    }

    func send(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
        guard let button = MCUProtocol.decodeButton(bytes), button.on else { return }
        switch button.function {
        case .bankLeft:
            bank = max(0, bank - 1)
        case .bankRight:
            bank += 1
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

/// A momentary press: Note On velocity 127, then velocity 0, on the strip's note.
private func pressPair(_ function: MCUProtocol.ButtonFunction, strip: Int) -> [[UInt8]] {
    [
        MCUProtocol.encodeButton(function, strip: strip, on: true),
        MCUProtocol.encodeButton(function, strip: strip, on: false),
    ]
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
        #expect(observed == enabled)
        #expect(obj["track"] as? Int == 2)
        #expect(obj["enabled"] as? Bool == enabled)
        #expect(obj["verification_source"] as? String == "ax_value")
        #expect(await rig.sleeper.requested.isEmpty)
        // The surface still holds what it held: nothing toggled it.
        #expect(await rig.surface.read(toggle.function, track: 2) == enabled)
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
        #expect(observed == enabled)
        #expect(obj["write_source"] as? String == "mcu")
        #expect(obj["verification_source"] as? String == "ax_value")
        // The first read after the press confirmed it, so no wait was taken.
        #expect(await rig.sleeper.requested.isEmpty)
        #expect(await rig.surface.read(toggle.function, track: 2) == enabled)
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
        let rig = makeSetRig(states: [FlagKey(function: .mute, track: 11): false])

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
