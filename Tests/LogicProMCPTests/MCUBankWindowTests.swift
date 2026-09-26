import Foundation
import Testing
@testable import LogicProMCP

// `mixer.bank` (#862) is verified by the MCU LCD upper row, never by the press having been sent.
// These tests drive the real MCUChannel against a fake surface that answers a bank press the way
// Logic does — by redrawing the upper row through the channel's own feedback path — and a sleeper
// that returns at once so every wait is a count, not a clock (#804).
//
// `LCDBankSurface` and `CountingSleeper` sit at file scope on purpose: MCUBankPublicPathTests
// drives the public dispatcher path through the same two fakes.

// MARK: - Fakes

/// A transport that behaves like Logic's MCU LCD for bank presses. On each bank press it answers
/// according to `Response`, delivering the redraw REENTRANTLY from inside `send` via
/// `MCUChannel.handleFeedback(.sysEx)`: the channel is suspended on `await transport.send`, so
/// the parser writes the row into StateCache before the channel's first poll — the same way
/// AutomationTargetSurface models Logic in MCUChannelTests.
actor LCDBankSurface: MCUTransportProtocol {
    enum Response: Sendable {
        /// Redraw the upper row with this text on every bank press.
        case redraw(row: String)
        /// Redraw the upper row with exactly the bytes it already holds.
        case redrawIdentical
        /// Never redraw.
        case ignore
    }

    private(set) var sentBytes: [[UInt8]] = []
    private var channel: MCUChannel?
    private var response: Response
    private var currentRow: String

    init(response: Response, currentRow: String = String(repeating: " ", count: 56)) {
        self.response = response
        self.currentRow = currentRow
    }

    func attach(channel: MCUChannel) {
        self.channel = channel
    }

    func setResponse(_ response: Response) {
        self.response = response
    }

    /// What Logic does on connect: one full upper-row write. Without it the cache has never
    /// received a row and `mixer.bank` refuses before sending.
    func seedUpperRow(_ row: String) async {
        currentRow = row
        await deliverUpperRow(row)
    }

    func send(_ bytes: [UInt8]) async {
        sentBytes.append(bytes)
        guard let button = MCUProtocol.decodeButton(bytes), button.on,
              button.function == .bankLeft || button.function == .bankRight
        else { return }
        switch response {
        case .redraw(let row):
            currentRow = row
            await deliverUpperRow(row)
        case .redrawIdentical:
            await deliverUpperRow(currentRow)
        case .ignore:
            break
        }
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {}
    func stop() {}

    /// An MCU LCD frame: F0 00 00 66 14 12 <offset> <chars> F7. Offsets below 0x38 are the upper row.
    static func lcdFrame(_ text: String, offset: UInt8) -> [UInt8] {
        MCUProtocol.sysExHeader + [0x12, offset] + Array(text.utf8) + [0xF7]
    }

    private func deliverUpperRow(_ row: String) async {
        guard let channel else { return }
        await channel.handleFeedback(.sysEx(Self.lcdFrame(row, offset: 0)))
    }
}

/// Records every Duration the channel asks to sleep for and returns at once.
actor CountingSleeper {
    private(set) var requested: [Duration] = []

    func record(_ duration: Duration) {
        requested.append(duration)
    }

    func count(of duration: Duration) -> Int {
        requested.filter { $0 == duration }.count
    }

    nonisolated var closure: @Sendable (Duration) async -> Void {
        { [self] duration in await self.record(duration) }
    }
}

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

private let bankRightPress = MCUProtocol.encodeButton(.bankRight, on: true)
private let bankLeftPress = MCUProtocol.encodeButton(.bankLeft, on: true)

private struct BankRig {
    let channel: MCUChannel
    let surface: LCDBankSurface
    let sleeper: CountingSleeper
    let cache: StateCache
}

private func makeBankRig(response: LCDBankSurface.Response, seedUpperRow: String?) async -> BankRig {
    let surface = LCDBankSurface(response: response)
    let sleeper = CountingSleeper()
    let cache = StateCache()
    let channel = MCUChannel(transport: surface, cache: cache, sleep: sleeper.closure)
    await surface.attach(channel: channel)
    if let seedUpperRow {
        await surface.seedUpperRow(seedUpperRow)
    }
    return BankRig(channel: channel, surface: surface, sleeper: sleeper, cache: cache)
}

private func envelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

// MARK: - Tests

@Suite("MCUBankWindowTests")
struct MCUBankWindowTests {
    // T1
    @Test func bankRightWithRedrawnRowIsStateA() async throws {
        let rig = await makeBankRig(response: .redraw(row: bank1Row), seedUpperRow: bank0Row)

        let result = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "right"])

        #expect(result.isSuccess)
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
        #expect(obj["bank_presses_sent"] as? Int == 1)
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["window_after"] as? String == bank1Row)
        #expect(obj["upper_row_writes_observed"] as? Int == 1)
        #expect(obj["strips"] as? [String] == bank1Names)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 1)
        #expect(await rig.channel.currentBank == 1)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress])
        // One press spacing, then the fresh poll and the one poll that shows the row held still.
        #expect(await rig.sleeper.count(of: .milliseconds(1)) == 1)
        #expect(await rig.sleeper.count(of: .milliseconds(25)) == 2)
    }

    // T2
    @Test func ignoredPressIsEchoTimeoutAndLeavesBookkeeping() async throws {
        let rig = await makeBankRig(response: .ignore, seedUpperRow: bank0Row)

        let result = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "right"])

        #expect(result.isSuccess)
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "B")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(!verified)
        #expect(obj["reason"] as? String == "echo_timeout_\(MCUChannel.echoTimeoutMs)ms")
        #expect(obj["direction"] as? String == "right")
        #expect(obj["bank_presses_sent"] as? Int == 1)
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["readback_source"] as? String == "mcu_lcd_upper_row")
        #expect(obj["upper_row_writes_observed"] as? Int == 0)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 0)
        #expect(obj["strips"] == nil)
        #expect(await rig.channel.currentBank == 0)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress])
        // The budget is spelled out here rather than read from the product, so a product that
        // shrank its own budget would disagree with this line instead of agreeing with itself.
        let budget = max(1, MCUChannel.echoTimeoutMs / 25)
        #expect(await rig.sleeper.count(of: .milliseconds(25)) == budget)
        #expect(await rig.sleeper.count(of: .milliseconds(1)) == 1)
        #expect(await rig.sleeper.requested.count == budget + 1)
    }

    // T3
    @Test func identicalRedrawIsNoopUnobservable() async throws {
        let rig = await makeBankRig(response: .redrawIdentical, seedUpperRow: bank0Row)

        let result = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "left"])

        #expect(result.isSuccess)
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "B")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(!verified)
        #expect(obj["reason"] as? String == "noop_unobservable")
        #expect(obj["direction"] as? String == "left")
        #expect(obj["verify_source"] as? String == "mcu_lcd_upper_row")
        #expect(obj["bank_presses_sent"] as? Int == 1)
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["window_after"] as? String == bank0Row)
        #expect(obj["upper_row_writes_observed"] as? Int == 1)
        #expect(obj["strips"] == nil)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 0)
        let limitation = try #require(obj["surface_limitation"] as? String)
        #expect(limitation.contains("identical"))
        #expect(await rig.channel.currentBank == 0)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankLeftPress])
    }

    // T4
    @Test func neverReceivedRowRefusesBeforeSending() async throws {
        let rig = await makeBankRig(response: .redraw(row: bank1Row), seedUpperRow: nil)
        #expect(await rig.cache.mcuUpperRowWriteSequence == 0)

        let result = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "right"])

        #expect(!result.isSuccess)
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
        #expect(await rig.channel.currentBank == 0)

        let sent = await rig.surface.sentBytes
        #expect(sent.isEmpty)
        #expect(await rig.sleeper.requested.isEmpty)
    }

    // T5
    @Test func invalidParamsRefuseBeforeSending() async throws {
        // Seeded, so validation is the ONLY thing standing between the request and the wire.
        let rig = await makeBankRig(response: .redraw(row: bank1Row), seedUpperRow: bank0Row)

        let rejected: [[String: String]] = [
            ["direction": "up"],
            ["direction": "right", "count": "0"],
            ["direction": "right", "count": "32"],
            ["direction": "left", "count": "two"],
            [:],
        ]
        for params in rejected {
            let result = await rig.channel.execute(operation: "mixer.bank", params: params)
            #expect(!result.isSuccess, "\(params) must be refused")
            let obj = try envelope(result)
            #expect(obj["state"] as? String == "C", "\(params)")
            #expect(obj["error"] as? String == "invalid_params", "\(params)")
            #expect(obj["operation"] as? String == "mixer.bank", "\(params)")
            #expect(obj["channel"] as? String == "MCU", "\(params)")
            let hint = try #require(obj["hint"] as? String)
            #expect(hint.contains("mixer.bank requires"), "\(params): \(hint)")
        }

        let sent = await rig.surface.sentBytes
        #expect(sent.isEmpty)
        #expect(await rig.sleeper.requested.isEmpty)
        #expect(await rig.channel.currentBank == 0)
    }

    // T6
    @Test func lowerRowWriteLeavesSequenceAndUpperRowWriteAdvancesItByOne() async {
        let cache = StateCache()
        #expect(await cache.mcuUpperRowWriteSequence == 0)

        await cache.updateMCUDisplayRow(upper: false, text: "Kick", offset: 0x38)
        #expect(await cache.mcuUpperRowWriteSequence == 0)
        var snapshot = await cache.mcuUpperRowSnapshot()
        #expect(snapshot.sequence == 0)
        #expect(snapshot.row == String(repeating: " ", count: 56))

        await cache.updateMCUDisplayRow(upper: true, text: bank0Row, offset: 0)
        #expect(await cache.mcuUpperRowWriteSequence == 1)
        snapshot = await cache.mcuUpperRowSnapshot()
        #expect(snapshot.sequence == 1)
        #expect(snapshot.row == bank0Row)

        // A partial redraw is one write, and the snapshot carries the row as merged.
        await cache.updateMCUDisplayRow(upper: true, text: "Tom    ", offset: 7)
        #expect(await cache.mcuUpperRowWriteSequence == 2)
        snapshot = await cache.mcuUpperRowSnapshot()
        #expect(snapshot.row.hasPrefix("Kick   Tom    "))
        #expect(snapshot.row.count == 56)

        await cache.updateMCUDisplayRow(upper: false, text: "-3.0dB", offset: 0x38 + 7)
        #expect(await cache.mcuUpperRowWriteSequence == 2)

        await cache.updateMCUDisplay(MCUDisplayState(upperRow: bank1Row, lowerRow: String(repeating: " ", count: 56)))
        #expect(await cache.mcuUpperRowWriteSequence == 3)
        snapshot = await cache.mcuUpperRowSnapshot()
        #expect(snapshot.row == bank1Row)

        // The wire the resource reads is untouched.
        let display = await cache.getMCUDisplay()
        #expect(display.upperRow == bank1Row)
        #expect(display.lowerRow.count == 56)
    }

    // T7
    @Test func countThreeSendsThreePressesOneMillisecondApart() async throws {
        let rig = await makeBankRig(response: .redraw(row: bank1Row), seedUpperRow: bank0Row)

        let result = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "right", "count": "3"]
        )

        #expect(result.isSuccess)
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["bank_presses_sent"] as? Int == 3)
        #expect(obj["upper_row_writes_observed"] as? Int == 3)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 3)
        #expect(await rig.channel.currentBank == 3)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress, bankRightPress, bankRightPress])
        let waits = await rig.sleeper.requested
        #expect(Array(waits.prefix(3)) == [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
        #expect(Array(waits.dropFirst(3)) == [.milliseconds(25), .milliseconds(25)])
    }

    // Bookkeeping is clamped to 0...31 on State A; it never goes negative on a left press at bank 0.
    @Test func bookkeepingClampsAtBankZeroOnStateA() async throws {
        let rig = await makeBankRig(response: .redraw(row: bank1Row), seedUpperRow: bank0Row)

        let result = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "left", "count": "5"]
        )

        let obj = try envelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["bank_presses_sent"] as? Int == 5)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 0)
        #expect(await rig.channel.currentBank == 0)
        let sent = await rig.surface.sentBytes
        #expect(sent == Array(repeating: bankLeftPress, count: 5))
    }

    @Test func bankWindowStripsSplitsSevenCharacterCellsAndTrimsTrailingSpaces() {
        #expect(MCUChannel.bankWindowStrips(bank0Row) == bank0Names)
        #expect(MCUChannel.bankWindowStrips(String(repeating: " ", count: 56)) == Array(repeating: "", count: 8))
        // A short row is padded to 56 before splitting, so cells keep their positions.
        #expect(MCUChannel.bankWindowStrips("Kick   Snare") == ["Kick", "Snare", "", "", "", "", "", ""])
    }
}
