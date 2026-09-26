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
        /// Logic's bank window as measured on 12.3 (#862, 2026-09-27): an ordered list of windows
        /// and a position that starts at `start` (seed the row with `windows[start]`). Each bank
        /// press moves one window in its direction and redraws the window it lands on; a press
        /// past either end redraws the window it is already on, byte for byte. With `silentAfter`
        /// set, every press after that many bank presses neither moves nor redraws — the second
        /// of two back-to-back presses that Logic absorbed.
        case windows([String], start: Int = 0, silentAfter: Int? = nil)
    }

    private(set) var sentBytes: [[UInt8]] = []
    private var channel: MCUChannel?
    private var response: Response
    private var currentRow: String
    private var windowPosition = 0
    private var bankPressesSeen = 0

    init(response: Response, currentRow: String = String(repeating: " ", count: 56)) {
        self.response = response
        self.currentRow = currentRow
        if case .windows(_, let start, _) = response { windowPosition = start }
    }

    func attach(channel: MCUChannel) {
        self.channel = channel
    }

    func setResponse(_ response: Response) {
        self.response = response
        bankPressesSeen = 0
        if case .windows(_, let start, _) = response { windowPosition = start }
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
        case .windows(let windows, _, let silentAfter):
            bankPressesSeen += 1
            if let silentAfter, bankPressesSeen > silentAfter { return }
            let step = button.function == .bankRight ? 1 : -1
            windowPosition = min(max(windowPosition + step, 0), windows.count - 1)
            currentRow = windows[windowPosition]
            await deliverUpperRow(currentRow)
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
private let bank2Names = ["Choir", "Organ", "Piano", "Rhodes", "Clav", "Sub", "Arp", "Ride"]
private let bank3Names = ["Tom 1", "Tom 2", "Crash", "Room", "Ovhd", "Shaker", "Clap", "Snap"]
private let bank0Row = lcdRow(bank0Names)
private let bank1Row = lcdRow(bank1Names)
private let bank2Row = lcdRow(bank2Names)
private let bank3Row = lcdRow(bank3Names)
/// Four windows, four different rows: what a 32-track project's upper row walks through.
private let fourWindows = [bank0Row, bank1Row, bank2Row, bank3Row]

private let bankRightPress = MCUProtocol.encodeButton(.bankRight, on: true)
private let bankRightRelease = MCUProtocol.encodeButton(.bankRight, on: false)
private let bankLeftPress = MCUProtocol.encodeButton(.bankLeft, on: true)
private let bankLeftRelease = MCUProtocol.encodeButton(.bankLeft, on: false)

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
        #expect(sent == [bankRightPress, bankRightRelease])
        // The fresh poll and the one poll that shows the row held still; nothing else waits.
        #expect(await rig.sleeper.count(of: .milliseconds(25)) == 2)
        #expect(await rig.sleeper.requested.count == 2)
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
        #expect(sent == [bankRightPress, bankRightRelease])
        // The budget is spelled out here rather than read from the product, so a product that
        // shrank its own budget would disagree with this line instead of agreeing with itself.
        let budget = max(1, MCUChannel.echoTimeoutMs / 25)
        #expect(await rig.sleeper.count(of: .milliseconds(25)) == budget)
        #expect(await rig.sleeper.requested.count == budget)
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
        #expect(sent == [bankLeftPress, bankLeftRelease])
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
    // Each press is its own step with its own readback: snapshot, press, poll until the row holds
    // still. State A for count 3 means three separate redraws to three different rows.
    @Test func countThreeIsThreeWitnessedSteps() async throws {
        let rig = await makeBankRig(response: .windows(fourWindows), seedUpperRow: bank0Row)

        let result = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "right", "count": "3"]
        )

        #expect(result.isSuccess)
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["verify_source"] as? String == "mcu_lcd_upper_row")
        #expect(obj["bank_presses_sent"] as? Int == 3)
        #expect(obj["banks_moved"] as? Int == 3)
        #expect(obj["banks_requested"] as? Int == 3)
        let stepWindows = try #require(obj["step_windows"] as? [String])
        #expect(stepWindows == [bank1Row, bank2Row, bank3Row])
        #expect(Set(stepWindows).count == 3)
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["window_after"] as? String == bank3Row)
        #expect(obj["strips"] as? [String] == bank3Names)
        #expect(obj["upper_row_writes_observed"] as? Int == 3)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 3)
        #expect(await rig.channel.currentBank == 3)

        let sent = await rig.surface.sentBytes
        #expect(sent == Array(repeating: [bankRightPress, bankRightRelease], count: 3).flatMap { $0 })
        // Two polls per step (the fresh one and the one that shows the row held still), and no
        // other wait: the poll is what separates one press from the next.
        let waits = await rig.sleeper.requested
        #expect(waits == Array(repeating: Duration.milliseconds(25), count: 6))
    }

    // Bookkeeping is clamped to 0...31 on State A; it never goes negative on a left walk that
    // starts from a bank the bookkeeping never saw. At the left edge the walk then stops at once.
    @Test func bookkeepingClampsAtBankZeroOnStateA() async throws {
        let sixWindows = fourWindows + [lcdRow(bank1Names.reversed()), lcdRow(bank2Names.reversed())]
        let rig = await makeBankRig(response: .windows(sixWindows, start: 5), seedUpperRow: sixWindows[5])

        let result = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "left", "count": "5"]
        )

        let obj = try envelope(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["bank_presses_sent"] as? Int == 5)
        #expect(obj["banks_moved"] as? Int == 5)
        #expect(obj["window_after"] as? String == bank0Row)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 0)
        #expect(await rig.channel.currentBank == 0)
        let sent = await rig.surface.sentBytes
        #expect(sent == Array(repeating: [bankLeftPress, bankLeftRelease], count: 5).flatMap { $0 })

        // Now at the left edge: the first press redraws unchanged, so the walk stops after one
        // press and answers exactly what a single press at the edge answers.
        let edge = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "left", "count": "5"]
        )
        let edgeObj = try envelope(edge)
        #expect(edgeObj["state"] as? String == "B")
        #expect(edgeObj["reason"] as? String == "noop_unobservable")
        #expect(edgeObj["bank_presses_sent"] as? Int == 1)
        #expect(edgeObj["banks_moved"] as? Int == 0)
        #expect(edgeObj["banks_requested"] as? Int == 5)
        #expect(edgeObj["step_windows"] as? [String] == [bank0Row])
        #expect(edgeObj["bank_bookkeeping_after"] as? Int == 0)
        #expect(await rig.channel.currentBank == 0)
        #expect(await rig.surface.sentBytes.count == 12)
    }

    // (a) The measured Logic 12.3 behaviour: of two presses, the second is absorbed — no move, no
    // redraw. One bank was witnessed, so the reply says one, not two, and it is not State A.
    @Test func secondPressWithNoRedrawIsEchoTimeoutAfterOneBank() async throws {
        let rig = await makeBankRig(response: .windows(fourWindows, silentAfter: 1), seedUpperRow: bank0Row)

        let result = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "right", "count": "2"]
        )

        #expect(result.isSuccess)
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "B")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(!verified)
        #expect(obj["reason"] as? String == "echo_timeout_\(MCUChannel.echoTimeoutMs)ms")
        #expect(obj["bank_presses_sent"] as? Int == 2)
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["banks_requested"] as? Int == 2)
        #expect(obj["step_windows"] as? [String] == [bank1Row, bank1Row])
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["window_after"] as? String == bank1Row)
        #expect(obj["upper_row_writes_observed"] as? Int == 1)
        #expect(obj["readback_source"] as? String == "mcu_lcd_upper_row")
        let rowQuiescent = try #require(obj["row_quiescent"] as? Bool)
        #expect(!rowQuiescent)
        #expect(obj["strips"] == nil)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 1)
        #expect(await rig.channel.currentBank == 1)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress, bankRightRelease, bankRightPress, bankRightRelease])
        // Step 1: fresh poll + quiescent poll. Step 2: the whole budget, spelled out here.
        let budget = max(1, MCUChannel.echoTimeoutMs / 25)
        #expect(await rig.sleeper.count(of: .milliseconds(25)) == 2 + budget)
        #expect(await rig.sleeper.requested.count == 2 + budget)
    }

    // (b) The walk reaches the end of the mixer after one move: the next press redraws the same
    // row. One bank moved of three requested, and the third press is never sent.
    @Test func reachingTheEdgeAfterOneMoveIsReadbackMismatch() async throws {
        let rig = await makeBankRig(response: .windows([bank0Row, bank1Row]), seedUpperRow: bank0Row)

        let result = await rig.channel.execute(
            operation: "mixer.bank", params: ["direction": "right", "count": "3"]
        )

        #expect(result.isSuccess)
        let obj = try envelope(result)
        #expect(obj["state"] as? String == "B")
        let verified = try #require(obj["verified"] as? Bool)
        #expect(!verified)
        #expect(obj["reason"] as? String == "readback_mismatch")
        #expect(obj["verify_source"] as? String == "mcu_lcd_upper_row")
        #expect(obj["bank_presses_sent"] as? Int == 2)
        #expect(obj["banks_moved"] as? Int == 1)
        #expect(obj["banks_requested"] as? Int == 3)
        #expect(obj["step_windows"] as? [String] == [bank1Row, bank1Row])
        #expect(obj["window_before"] as? String == bank0Row)
        #expect(obj["window_after"] as? String == bank1Row)
        #expect(obj["upper_row_writes_observed"] as? Int == 2)
        let limitation = try #require(obj["surface_limitation"] as? String)
        #expect(limitation.contains("moved 1 of 3"))
        #expect(limitation.contains("unchanged"))
        #expect(obj["strips"] == nil)
        #expect(obj["bank_bookkeeping_before"] as? Int == 0)
        #expect(obj["bank_bookkeeping_after"] as? Int == 1)
        #expect(await rig.channel.currentBank == 1)

        let sent = await rig.surface.sentBytes
        #expect(sent == [bankRightPress, bankRightRelease, bankRightPress, bankRightRelease])
    }

    // (c) A single press answers with exactly the fields it answered before the per-step walk,
    // plus banks_moved / banks_requested / step_windows. The legacy key sets are written out here,
    // captured from a48a5cb5, so a field the walk dropped or renamed shows up as a difference.
    @Test func singlePressKeepsItsWireFields() async throws {
        let connection: Set<String> = ["mcu_connected", "mcu_last_feedback_age_ms", "mcu_registered"]
        let common: Set<String> = [
            "state", "success", "verified", "operation", "channel", "direction",
            "bank_bookkeeping_before", "bank_bookkeeping_after", "bank_presses_sent",
            "upper_row_writes_observed", "window_before", "window_after",
        ]
        let added: Set<String> = ["banks_moved", "banks_requested", "step_windows"]
        let cases: [(LCDBankSurface.Response, Set<String>, String, Int)] = [
            (.redraw(row: bank1Row), ["verify_source", "strips"], "A", 1),
            (.ignore, ["reason", "readback_source", "row_quiescent"], "B", 0),
            (.redrawIdentical, ["reason", "verify_source", "surface_limitation"], "B", 0),
        ]
        for (response, specific, state, moved) in cases {
            let rig = await makeBankRig(response: response, seedUpperRow: bank0Row)
            let result = await rig.channel.execute(operation: "mixer.bank", params: ["direction": "right"])
            let obj = try envelope(result)
            #expect(Set(obj.keys) == common.union(connection).union(specific).union(added), "\(response)")
            #expect(obj["state"] as? String == state, "\(response)")
            #expect(obj["bank_presses_sent"] as? Int == 1, "\(response)")
            #expect(obj["banks_moved"] as? Int == moved, "\(response)")
            #expect(obj["banks_requested"] as? Int == 1, "\(response)")
            let window = try #require(obj["window_after"] as? String)
            #expect(obj["step_windows"] as? [String] == [window], "\(response)")
            #expect(obj["bank_bookkeeping_after"] as? Int == moved, "\(response)")
        }
    }

    @Test func bankWindowStripsSplitsSevenCharacterCellsAndTrimsTrailingSpaces() {
        #expect(MCUChannel.bankWindowStrips(bank0Row) == bank0Names)
        #expect(MCUChannel.bankWindowStrips(String(repeating: " ", count: 56)) == Array(repeating: "", count: 8))
        // A short row is padded to 56 before splitting, so cells keep their positions.
        #expect(MCUChannel.bankWindowStrips("Kick   Snare") == ["Kick", "Snare", "", "", "", "", "", ""])
    }
}
