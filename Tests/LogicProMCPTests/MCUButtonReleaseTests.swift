import Foundation
import Testing
@testable import LogicProMCP

// A momentary MCU button is a press AND a release (#862). Measured 2026-09-26 on Logic 12.3: a
// Note On velocity 127 with no velocity 0 after it is a HELD button, and Logic auto-repeats held
// bank buttons — one bank-left walk and one bank-right redrew the LCD upper row between two
// windows every ~30 ms for more than 2.5 s. These tests pin every site class that presses a
// momentary button: each press must be followed at once by the release of the same note.

// MARK: - Fixtures

/// Indices of Note On velocity-127 messages NOT immediately followed by velocity 0 on the same note.
private func unreleasedPresses(_ sent: [[UInt8]]) -> [Int] {
    sent.indices.filter { index in
        let bytes = sent[index]
        guard bytes.count == 3, bytes[0] == 0x90, bytes[2] == 0x7F else { return false }
        let next = index + 1
        return next >= sent.count || sent[next] != [0x90, bytes[1], 0x00]
    }
}

private func pressCount(_ sent: [[UInt8]]) -> Int {
    sent.filter { $0.count == 3 && $0[0] == 0x90 && $0[2] == 0x7F }.count
}

private func press(_ function: MCUProtocol.ButtonFunction, strip: Int = 0) -> [[UInt8]] {
    [
        MCUProtocol.encodeButton(function, strip: strip, on: true),
        MCUProtocol.encodeButton(function, strip: strip, on: false),
    ]
}

private func releaseTestRow(_ names: [String]) -> String {
    precondition(names.count == 8)
    return names.map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
}

/// Two bank windows for the strip-relative sites, which bank through a verified walk (#1020).
private let releaseTestWindows = [
    releaseTestRow(["Kick", "Snare", "HiHat", "Bass", "Keys", "Gtr L", "Gtr R", "Vox"]),
    releaseTestRow(["Bass 2", "Synth", "Pad", "Lead", "Strngs", "Brass", "Perc", "FX"]),
]

private func releaseEnvelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

// MARK: - Tests

@Suite("MCUButtonReleaseTests")
struct MCUButtonReleaseTests {
    // Site class: executeBank's press loop.
    @Test func bankMoveSendsEachPressThenItsRelease() async throws {
        let windows = [
            releaseTestRow(["Kick", "Snare", "HiHat", "Bass", "Keys", "Gtr L", "Gtr R", "Vox"]),
            releaseTestRow(["Bass 2", "Synth", "Pad", "Lead", "Strngs", "Brass", "Perc", "FX"]),
            releaseTestRow(["Choir", "Organ", "Piano", "Rhodes", "Clav", "Sub", "Arp", "Ride"]),
        ]
        let surface = LCDBankSurface(response: .windows(windows))
        let sleeper = CountingSleeper()
        let channel = MCUChannel(transport: surface, cache: StateCache(), sleep: sleeper.closure)
        await surface.attach(channel: channel)
        await surface.seedUpperRow(windows[0])

        let result = await channel.execute(operation: "mixer.bank", params: ["direction": "right", "count": "2"])

        #expect(result.isSuccess)
        let obj = try releaseEnvelope(result)
        #expect(obj["bank_presses_sent"] as? Int == 2)
        let sent = await surface.sentBytes
        let expected: [[UInt8]] = [press(.bankRight), press(.bankRight)].flatMap { $0 }
        #expect(sent == expected)
        #expect(pressCount(sent) == 2)
        #expect(unreleasedPresses(sent).isEmpty)
        // Presses are separated by each step's readback polls, not by a fixed spacing.
        #expect(await sleeper.count(of: .milliseconds(1)) == 0)
        #expect(await sleeper.count(of: .milliseconds(25)) == 4)
    }

    // Site classes: withBanking's bank loop and restore loop, plus the strip button (enabled=true).
    @Test func bankedStripButtonReleasesTheBankTheStripAndTheRestorePresses() async {
        // #1020: every bank step is verified by the redrawn LCD upper row, so the surface banks.
        let transport = LCDBankSurface(response: .windows(releaseTestWindows))
        // #1020: the strip button is a set, so it reads the track before pressing and confirms
        // after; the reading follows the press onto the wire.
        let mutePress = MCUProtocol.encodeButton(.mute, strip: 3, on: true)
        let channel = MCUChannel(
            transport: transport,
            cache: StateCache(),
            axReadback: MCUChannel.AXReadback(
                readVolume: { _ in nil },
                readPan: { _ in nil },
                readMuted: { _ in await transport.sentBytes.contains(mutePress) }
            ),
            sleep: CountingSleeper().closure
        )
        await transport.attach(channel: channel)
        await transport.seedUpperRow(releaseTestWindows[0])

        // Track 11 → bank 1, strip 3.
        let result = await channel.execute(operation: "track.set_mute", params: ["index": "11", "enabled": "true"])

        #expect(result.isSuccess)
        let sent = await transport.sentBytes
        let expected: [[UInt8]] = [press(.bankRight), press(.mute, strip: 3), press(.bankLeft)].flatMap { $0 }
        #expect(sent == expected)
        #expect(pressCount(sent) == 3)
        #expect(unreleasedPresses(sent).isEmpty)
    }

    // Site class: strip button, enabled=true, no banking.
    @Test func stripButtonEnabledIsAPressThenARelease() async {
        let transport = MockMCUTransport()
        let soloPress = MCUProtocol.encodeButton(.solo, strip: 2, on: true)
        let channel = MCUChannel(
            transport: transport,
            cache: StateCache(),
            axReadback: MCUChannel.AXReadback(
                readVolume: { _ in nil },
                readPan: { _ in nil },
                readSoloed: { _ in await transport.sentBytes.contains(soloPress) }
            )
        )

        let result = await channel.execute(operation: "track.set_solo", params: ["index": "2", "enabled": "true"])

        #expect(result.isSuccess)
        let sent = await transport.sentBytes
        // Solo strip 2 is note 0x0A.
        #expect(sent == [[0x90, 0x0A, 0x7F], [0x90, 0x0A, 0x00]])
        #expect(unreleasedPresses(sent).isEmpty)
    }

    // Site class: strip button, enabled=false. Until #1020 this sent one bare velocity-0 byte,
    // which is not a press; clearing a lit toggle is the same press as setting it.
    @Test func stripButtonDisabledIsAPressThenARelease() async {
        let transport = MockMCUTransport()
        let mutePress = MCUProtocol.encodeButton(.mute, strip: 3, on: true)
        let channel = MCUChannel(
            transport: transport,
            cache: StateCache(),
            axReadback: MCUChannel.AXReadback(
                readVolume: { _ in nil },
                readPan: { _ in nil },
                // Muted until the press is on the wire, unmuted after it.
                readMuted: { _ in await !transport.sentBytes.contains(mutePress) }
            )
        )

        let result = await channel.execute(operation: "track.set_mute", params: ["index": "3", "enabled": "false"])

        #expect(result.isSuccess)
        let sent = await transport.sentBytes
        // Mute strip 3 is note 0x13.
        #expect(sent == [[0x90, 0x13, 0x7F], [0x90, 0x13, 0x00]])
        #expect(unreleasedPresses(sent).isEmpty)
    }

    // Site classes: executeAutomation's select press and its automation-mode press, inside
    // withBanking's bank and restore presses.
    @Test func automationReleasesTheSelectAndTheModePress() async throws {
        let transport = LCDBankSurface(response: .windows(releaseTestWindows))
        let writePress = MCUProtocol.encodeButton(.automationWrite, on: true)
        let channel = MCUChannel(
            transport: transport,
            cache: StateCache(),
            axReadback: MCUChannel.AXReadback(
                readVolume: { _ in nil },
                readPan: { _ in nil },
                readAutomationMode: { _ in
                    await transport.sentBytes.contains(writePress) ? .write : .off
                },
                readSelectedTrack: { 10 }
            ),
            sleep: CountingSleeper().closure
        )
        await transport.attach(channel: channel)
        await transport.seedUpperRow(releaseTestWindows[0])

        // Track 10 → bank 1, strip 2.
        let result = await channel.execute(operation: "track.set_automation", params: ["index": "10", "mode": "write"])

        #expect(result.isSuccess)
        let obj = try releaseEnvelope(result)
        #expect(obj["state"] as? String == "A")
        let sent = await transport.sentBytes
        let expected: [[UInt8]] = [press(.bankRight), press(.select, strip: 2), press(.automationWrite), press(.bankLeft)]
            .flatMap { $0 }
        #expect(sent == expected)
        #expect(pressCount(sent) == 4)
        #expect(unreleasedPresses(sent).isEmpty)
    }

    // Site class: transport buttons.
    @Test func transportCommandIsAPressThenARelease() async {
        let transport = MockMCUTransport()
        let channel = MCUChannel(transport: transport, cache: StateCache())

        let result = await channel.execute(operation: "transport.rewind", params: [:])

        #expect(result.isSuccess)
        let sent = await transport.sentBytes
        #expect(sent == press(.rewind))
        #expect(unreleasedPresses(sent).isEmpty)
    }
}
