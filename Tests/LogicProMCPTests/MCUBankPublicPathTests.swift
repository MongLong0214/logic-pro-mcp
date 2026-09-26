import Foundation
import MCP
import Testing
@testable import LogicProMCP

// The public path for `mixer.bank` (#862): MixerDispatcher -> ChannelRouter -> the real MCUChannel,
// over the LCDBankSurface and CountingSleeper that MCUBankWindowTests.swift keeps at file scope.
// MCUBankWindowTests proves what the channel decides. This file proves that decision survives the
// dispatcher's validation, the router's health gate and the tool-result encoding, and that the one
// refusal which must precede any byte still does so when the request arrives the way a caller
// sends it — as `logic_mixer bank {direction}` — rather than as a pre-stringified channel call.
//
// The router gates `.mcu` on MCUChannel.healthCheck, which needs the cache's MCU connection to read
// `isConnected`. MCUFeedbackParser sets that on ANY well-formed feedback, so every rig here earns
// its health the way a live server does: by receiving a frame through the channel's own feedback
// path, never by writing the flag into the cache directly.

// MARK: - Fixtures

/// Eight six-character names plus a separator each: the 56-character upper row Logic draws.
private func lcdRow(_ names: [String]) -> String {
    precondition(names.count == 8)
    return names.map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
}

private let bank0Names = ["Kick", "Snare", "HiHat", "Bass", "Keys", "Gtr L", "Gtr R", "Vox"]
private let bank1Names = ["Bass 2", "Synth", "Pad", "Lead", "Strngs", "Brass", "Perc", "FX"]
private let bank0Row = lcdRow(bank0Names)
private let bank1Row = lcdRow(bank1Names)
/// What Logic draws on the LOWER row: values, not names. Offset 0x38 is the first lower-row cell.
private let lowerRowValues = lcdRow(["-3.0dB", "-6.0dB", "0.0dB", "-inf", "-1.5dB", "-2.0dB", "-2.0dB", "-4.5dB"])
private let lowerRowOffset: UInt8 = 0x38

private let bankRightPress = MCUProtocol.encodeButton(.bankRight, on: true)

private struct PublicPathRig {
    let router: ChannelRouter
    let cache: StateCache
    let surface: LCDBankSurface
    let sleeper: CountingSleeper
    let channel: MCUChannel
}

private func makePublicPathRig(response: LCDBankSurface.Response) async -> PublicPathRig {
    let surface = LCDBankSurface(response: response)
    let sleeper = CountingSleeper()
    let cache = StateCache()
    let channel = MCUChannel(transport: surface, cache: cache, sleep: sleeper.closure)
    await surface.attach(channel: channel)
    let router = ChannelRouter()
    await router.register(channel)
    return PublicPathRig(router: router, cache: cache, surface: surface, sleeper: sleeper, channel: channel)
}

/// The call a client makes: tool `logic_mixer`, command `bank`, MCP-typed params.
private func publicBank(_ rig: PublicPathRig, params: [String: Value]) async -> CallTool.Result {
    await MixerDispatcher.handle(command: "bank", params: params, router: rig.router, cache: rig.cache)
}

private func envelope(_ result: CallTool.Result) throws -> [String: Any] {
    let text = sharedToolText(result)
    return try #require(sharedJSONObject(text), "tool result must be a JSON object: \(text)")
}

// MARK: - Tests

@Suite("MCUBankPublicPathTests")
struct MCUBankPublicPathTests {
    // Positive: the redrawn row, not the press, is what the caller's State A rests on.
    @Test func bankRightThroughTheDispatcherIsStateAFromTheRedrawnRow() async throws {
        let rig = await makePublicPathRig(response: .redraw(row: bank1Row))
        await rig.surface.seedUpperRow(bank0Row)
        // The seed frame is also what makes the router willing to dispatch to this channel.
        let health = await rig.channel.healthCheck()
        #expect(health.ready, "\(health.detail)")

        let result = await publicBank(rig, params: ["direction": .string("right")])

        let isError = try #require(result.isError as Bool?)
        #expect(!isError, "\(sharedToolText(result))")
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "A")
        let success = try #require(obj["success"] as? Bool)
        #expect(success)
        let verified = try #require(obj["verified"] as? Bool)
        #expect(verified)
        #expect(obj["operation"] as? String == "mixer.bank")
        #expect(obj["channel"] as? String == "MCU")
        #expect(obj["direction"] as? String == "right")
        #expect(obj["verify_source"] as? String == "mcu_lcd_upper_row")
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["window_after"] as? String == bank1Row)
        #expect(obj["strips"] as? [String] == bank1Names)
        #expect(obj["bank_presses_sent"] as? Int == 1)
        #expect(obj["upper_row_writes_observed"] as? Int == 1)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 1)
        // A single-channel chain walks past nothing, so the router must not decorate the receipt.
        #expect(obj["fallback_from_channel"] == nil)
        #expect(obj["last_error"] == nil)
        #expect(await rig.channel.currentBank == 1)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress])
        #expect(await rig.sleeper.count(of: .milliseconds(1)) == 1)
        #expect(await rig.sleeper.count(of: .milliseconds(25)) == 2)
    }

    // The dispatcher stringifies `count`; the channel parses it back. DispatcherTests shows the string
    // reaching a mock; this shows the real channel pressing that many times.
    @Test func countThroughTheDispatcherIsThatManyPresses() async throws {
        let rig = await makePublicPathRig(response: .redraw(row: bank1Row))
        await rig.surface.seedUpperRow(bank0Row)

        let result = await publicBank(rig, params: ["direction": .string("right"), "count": .int(2)])

        let isError = try #require(result.isError as Bool?)
        #expect(!isError, "\(sharedToolText(result))")
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["bank_presses_sent"] as? Int == 2)
        #expect(obj["bank_bookkeeping_after"] as? Int == 2)
        #expect(obj["strips"] as? [String] == bank1Names)
        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress, bankRightPress])
        #expect(await rig.sleeper.count(of: .milliseconds(1)) == 2)
    }

    // Negative, pre-write: a connected surface that has drawn values but never names. The health
    // gate passes (feedback arrived), the upper-row sequence is still 0, and the refusal must be the
    // channel's own — before any byte — not the router's exhaustion wrapper.
    @Test func neverReceivedUpperRowRefusesThroughTheDispatcherBeforeAnyByte() async throws {
        // `.redraw` on purpose: without the pre-write guard this rig would answer State A from a row
        // the server had never seen before the press, which is exactly the receipt #862 forbids.
        let rig = await makePublicPathRig(response: .redraw(row: bank1Row))
        await rig.channel.handleFeedback(.sysEx(LCDBankSurface.lcdFrame(lowerRowValues, offset: lowerRowOffset)))
        #expect(await rig.cache.mcuUpperRowWriteSequence == 0)
        let health = await rig.channel.healthCheck()
        #expect(health.ready, "\(health.detail)")

        let result = await publicBank(rig, params: ["direction": .string("right")])

        let isError = try #require(result.isError as Bool?)
        #expect(isError, "\(sharedToolText(result))")
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "C")
        let success = try #require(obj["success"] as? Bool)
        #expect(!success)
        #expect(obj["error"] as? String == "readback_unavailable")
        #expect(obj["operation"] as? String == "mixer.bank")
        #expect(obj["channel"] as? String == "MCU")
        #expect(obj["verify_source"] as? String == "mcu_lcd_upper_row")
        let writeAttempted = try #require(obj["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let hint = try #require(obj["hint"] as? String)
        #expect(hint.contains("never been received"))
        #expect(obj["bank_presses_sent"] == nil)
        #expect(obj["last_error"] == nil)
        #expect(await rig.channel.currentBank == 0)

        let sent = await rig.surface.sentBytes
        #expect(sent.isEmpty)
        #expect(await rig.sleeper.requested.isEmpty)
    }

    // Control for the test above: with NO feedback ever received the router's health gate answers,
    // not the channel — the channels_exhausted shape EndToEndTests records for set_master_volume.
    // It shows the lower-row frame above is load-bearing, and that this path sends nothing either.
    @Test func unavailableMCUIsChannelsExhaustedAndSendsNothing() async throws {
        let rig = await makePublicPathRig(response: .redraw(row: bank1Row))
        let health = await rig.channel.healthCheck()
        #expect(!health.available, "\(health.detail)")

        let result = await publicBank(rig, params: ["direction": .string("right")])

        let isError = try #require(result.isError as Bool?)
        #expect(isError, "\(sharedToolText(result))")
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "C")
        #expect(obj["error"] as? String == "channels_exhausted")
        #expect(obj["operation"] as? String == "mixer.bank")
        let lastError = try #require(obj["last_error"] as? String)
        #expect(lastError.contains("MCU feedback not detected"))
        #expect(obj["bank_presses_sent"] == nil)

        let sent = await rig.surface.sentBytes
        #expect(sent.isEmpty)
        #expect(await rig.sleeper.requested.isEmpty)
    }
}
