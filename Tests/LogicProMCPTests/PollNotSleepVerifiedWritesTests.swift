import Foundation
import MCP
import Testing
@testable import LogicProMCP

// A fixed sleep in front of a readback became a bounded poll that reads at once. Each test pins one
// half of that: the poll leaves early when the value is already there, and it waits out the old bound
// and then says the value did not arrive when it never does.

private final class FakeClock: @unchecked Sendable {
    var now: Double = 0
    var slept: [UInt32] = []
    func sleep(_ micros: UInt32) { slept.append(micros); now += Double(micros) / 1_000_000 }
}

private actor ScriptedTransportChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    private let states: [String]
    private var reads = 0
    init(states: [String]) { self.states = states }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy(detail: "scripted") }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard operation == "transport.get_state" else { return .success("Mock: \(operation)") }
        let index = min(reads, states.count - 1)
        reads += 1
        return .success(states[index])
    }
}

private final class SleepLog: @unchecked Sendable {
    var nanos: [UInt64] = []
}

private func live(_ playing: Bool) -> String {
    """
    {"isPlaying":\(playing),"isRecording":false,"tempo":120.0,"position":"1.1.1.1","timePosition":"00:00:00.000","sampleRate":44100,"isCycleEnabled":false,"isMetronomeEnabled":false,"lastUpdated":"2026-06-19T02:17:42.000Z"}
    """
}
private let stopped = live(false)
private let playing = live(true)

@Suite("Poll, not sleep, on verified writes", .serialized)
struct PollNotSleepVerifiedWritesTests {
    @Test("the poll returns at once when the value is already there")
    func exitsEarly() {
        let clock = FakeClock()
        let ok = ReadbackPoll.until(bound: 150_000, now: { clock.now }, sleep: clock.sleep, check: { true })
        #expect(ok)
        // One confirming read a step later; no waiting beyond that.
        #expect(clock.slept == [5_000])
    }

    @Test("a value that is there once and then gone is not accepted")
    func transientIsNotAccepted() {
        let clock = FakeClock()
        var reads = 0
        let ok = ReadbackPoll.until(bound: 50_000, step: 5_000, now: { clock.now }, sleep: clock.sleep, check: {
            reads += 1
            return reads == 1
        })
        #expect(!ok)
    }

    @Test("the poll waits only while the value is missing and stops when it arrives")
    func stopsOnArrival() {
        let clock = FakeClock()
        var reads = 0
        let ok = ReadbackPoll.until(bound: 150_000, step: 5_000, now: { clock.now }, sleep: clock.sleep, check: {
            reads += 1
            return reads >= 4
        })
        #expect(ok)
        #expect(clock.slept == [5_000, 5_000, 5_000, 5_000])
    }

    @Test("the poll spends the old bound and no more, then reports the value did not arrive")
    func reportsHonestlyAtBound() {
        let clock = FakeClock()
        var reads = 0
        let ok = ReadbackPoll.until(bound: 150_000, step: 40_000, now: { clock.now }, sleep: clock.sleep, check: {
            reads += 1
            return false
        })
        #expect(!ok)
        #expect(clock.slept.reduce(0, +) == 150_000)
        #expect(reads == clock.slept.count + 1)
    }

    @Test("a value that arrives only on the last check after the final sleep is still read")
    func lastCheckAfterFinalSleep() {
        let clock = FakeClock()
        var reads = 0
        let ok = ReadbackPoll.until(bound: 20_000, step: 10_000, now: { clock.now }, sleep: clock.sleep, check: {
            reads += 1
            return reads >= 3
        })
        #expect(ok)
    }

    @Test("transport.play reads at once and does not sleep when the state is already there")
    func playLandsEarly() async {
        let router = ChannelRouter()
        await router.register(ScriptedTransportChannel(states: [stopped, playing]))
        let log = SleepLog()
        let result = await TransportDispatcher.handle(
            command: "play", params: [:], router: router, cache: StateCache(),
            sleep: { log.nanos.append($0) }
        )
        let text = sharedToolText(result)
        #expect(text.contains(#""state":"A""#))
                #expect(log.nanos.isEmpty)
    }

    @Test("transport.play waits only while the state is unchanged, starting with 10 ms steps")
    func playWaitsInSmallSteps() async {
        let router = ChannelRouter()
        await router.register(ScriptedTransportChannel(states: [stopped, stopped, stopped, stopped, playing]))
        let log = SleepLog()
        let result = await TransportDispatcher.handle(
            command: "play", params: [:], router: router, cache: StateCache(),
            sleep: { log.nanos.append($0) }
        )
        #expect(sharedToolText(result).contains(#""state":"A""#))
        #expect(log.nanos == [10_000_000, 20_000_000, 40_000_000])
    }

    @Test("transport.play never reading playing spends the old 12 x 100 ms bound and is State B")
    func playExhaustsHonestly() async {
        let router = ChannelRouter()
        await router.register(ScriptedTransportChannel(states: [stopped]))
        let log = SleepLog()
        let result = await TransportDispatcher.handle(
            command: "play", params: [:], router: router, cache: StateCache(),
            sleep: { log.nanos.append($0) }
        )
        let text = sharedToolText(result)
        #expect(text.contains(#""state":"B""#))
        #expect(text.contains(#""poll_attempts":12"#))
        #expect(text.contains(#""verified":false"#))
        #expect(log.nanos.reduce(0, +) == 12 * 100_000_000)
    }

    @Test("transport.stop reads at once, waits while still playing, and exits on stopped")
    func stopWaitsThenLands() async {
        let router = ChannelRouter()
        await router.register(ScriptedTransportChannel(states: [playing, playing, playing, stopped]))
        let log = SleepLog()
        let result = await TransportDispatcher.handle(
            command: "stop", params: [:], router: router, cache: StateCache(),
            sleep: { log.nanos.append($0) }
        )
        #expect(sharedToolText(result).contains(#""state":"A""#))
        #expect(log.nanos == [10_000_000, 20_000_000])
    }

    @Test("transport.stop never reading stopped is not State A")
    func stopExhaustsHonestly() async {
        let router = ChannelRouter()
        await router.register(ScriptedTransportChannel(states: [playing]))
        let log = SleepLog()
        let result = await TransportDispatcher.handle(
            command: "stop", params: [:], router: router, cache: StateCache(),
            sleep: { log.nanos.append($0) }
        )
        #expect(!sharedToolText(result).contains(#""state":"A""#))
        #expect(log.nanos.reduce(0, +) <= 12 * 100_000_000)
    }

    @Test("a discrete state is accepted on the first passing check when confirm is off")
    func discreteStateNeedsNoConfirm() {
        let clock = FakeClock()
        let ok = ReadbackPoll.until(bound: 150_000, now: { clock.now }, sleep: clock.sleep, confirm: false, check: { true })
        #expect(ok)
        #expect(clock.slept.isEmpty)
    }
}
