@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1621. Two defects measured on Logic Pro 13 (ko-KR), 2026-11-28.
//
// 1. `transport.stop` through Accessibility pressed the Play checkbox. On Logic 13 that press,
//    made while playing, restarts playback from the start position and Play stays on (bar 15 went
//    to bar 12 and the playhead kept moving, AXValue stayed 1). The Stop button is a separate
//    AXButton, identifier `controlBar/stopButton`, described `정지   0` while playing. Pressed
//    while playing it stopped the transport at once and held the playhead; pressed while stopped
//    it is Go to Beginning and moved the playhead to bar 1.
// 2. `transport.pause` refused with `tempo_unreadable` whenever the Control Bar display was Beats,
//    where the tempo is not shown but the position reads to the tick (`13.3.4.189`).
//
// The fakes below model those measurements. Nothing reads a clock or a running Logic.

/// A control bar as Logic 13 exposes it: a Play checkbox, a Record checkbox, and a Stop AXButton.
/// Pressing Play while playing leaves it on and restarts (counted); pressing Stop while playing
/// turns Play off; pressing Stop while stopped is Go to Beginning (counted, Play stays off).
private final class Logic13Bar: @unchecked Sendable {
    enum StopBehavior {
        /// Logic 13 as measured.
        case stops
        /// The press is delivered and Play never reads off.
        case ignored
    }

    private let lock = NSLock()
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let play: AXUIElement
    let stop: AXUIElement?
    private(set) var playPresses = 0
    private(set) var stopPresses = 0
    private(set) var restarts = 0
    private(set) var goToBeginnings = 0
    private var playing: Bool
    private let stopBehavior: StopBehavior

    init(playing: Bool, withStopButton: Bool = true, stopBehavior: StopBehavior = .stops) {
        self.playing = playing
        self.stopBehavior = stopBehavior
        app = builder.element(16_210)
        let window = builder.element(16_211)
        let controlBar = builder.element(16_212)
        play = builder.element(16_213)
        let record = builder.element(16_214)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        var children = [play, record]
        for (checkbox, title, on) in [(play, "Play", playing), (record, "Record", false)] {
            builder.setAttribute(checkbox, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            builder.setAttribute(checkbox, kAXTitleAttribute as String, title)
            builder.setAttribute(checkbox, kAXValueAttribute as String, NSNumber(value: on))
        }
        if withStopButton {
            let stop = builder.element(16_215)
            builder.setAttribute(stop, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(stop, kAXIdentifierAttribute as String, "controlBar/stopButton")
            // The description is not what finds it: it reads `Stop` while playing and
            // `Go to Beginning` when stopped, in the language of the Logic.
            builder.setAttribute(stop, kAXDescriptionAttribute as String, playing ? "Stop   0" : "Go to Beginning   ↩")
            children.append(stop)
            self.stop = stop
        } else {
            stop = nil
        }
        builder.setChildren(controlBar, children)
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    private func publish() {
        builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: playing))
    }

    func runtime() -> AXLogicProElements.Runtime {
        builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { [self] element, action in
                guard action == kAXPressAction as String else { return false }
                lock.lock(); defer { lock.unlock() }
                if element == play {
                    playPresses += 1
                    // Measured: Play pressed while playing restarts and stays on. From stopped it plays.
                    if playing { restarts += 1 } else { playing = true }
                    publish()
                    return true
                }
                if let stop, element == stop {
                    stopPresses += 1
                    if playing {
                        if stopBehavior == .stops { playing = false }
                    } else {
                        goToBeginnings += 1
                    }
                    publish()
                    return true
                }
                return false
            }
        )
    }

    func router() async -> ChannelRouter {
        let router = ChannelRouter()
        await router.register(AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            hasVisibleWindow: { true },
            logicRuntime: runtime(),
            controlBarMouseRuntime: AXMouseHelper.Runtime(
                postMouseEvent: { _, _, _ in false },
                postKeyEvent: { _ in false },
                postUnicodeScalar: { _ in false },
                sleepMicros: { _ in }
            )
        )))
        return router
    }
}

private func issue1621Object(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Suite("Issue #1621 - Logic 13 transport stop and pause")
struct Issue1621TransportStopLogic13Tests {
    // MARK: Stop

    @Test("Accessibility stop presses the Stop button, never the Play checkbox, and Play reads off")
    func stopPressesTheStopButtonWhilePlaying() async throws {
        // Mutation killed: the Stop path back on `setControlBarCheckboxValue(Play, desired: false)`,
        // which restarts playback and leaves Play on (the reply was readback_mismatch, axpress).
        let bar = Logic13Bar(playing: true)
        let router = await bar.router()

        let result = await router.route(operation: "transport.stop", params: [:])

        #expect(result.isSuccess, "\(result.message)")
        let envelope = try #require(issue1621Object(result.message))
        #expect(envelope["state"] as? String == "A")
        #expect(envelope["button"] as? String == "Stop")
        let observedOff = try #require(envelope["observed"] as? Bool)
        #expect(!observedOff)
        #expect(bar.playPresses == 0, "the Play checkbox was pressed while playing: playback restarted")
        #expect(bar.restarts == 0)
        #expect(bar.stopPresses == 1)
        #expect(!bar.isPlaying)
    }

    @Test("Accessibility stop on a stopped transport presses nothing: the Stop button is Go to Beginning")
    func stopWhileStoppedDoesNotMoveThePlayhead() async throws {
        // Mutation killed: pressing the Stop button without reading Play first (the playhead
        // went to bar 1 on a stopped transport).
        let bar = Logic13Bar(playing: false)
        let router = await bar.router()

        let result = await router.route(operation: "transport.stop", params: [:])

        #expect(result.isSuccess, "\(result.message)")
        let envelope = try #require(issue1621Object(result.message))
        #expect(envelope["state"] as? String == "A")
        #expect(envelope["action"] as? String == "no-op")
        #expect(bar.stopPresses == 0)
        #expect(bar.goToBeginnings == 0)
        #expect(bar.playPresses == 0)
    }

    @Test("A Stop press after which Play still reads on is State C readback_mismatch, pressed once")
    func stopThatDoesNotTakeIsNotCalledStopped() async throws {
        let bar = Logic13Bar(playing: true, stopBehavior: .ignored)
        let router = await bar.router()

        let result = await router.route(operation: "transport.stop", params: [:])

        #expect(!result.isSuccess)
        let envelope = try #require(issue1621Object(result.message))
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["error"] as? String == "readback_mismatch")
        let observedOn = try #require(envelope["observed"] as? Bool)
        #expect(observedOn)
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
        #expect(fallbackUnsafe)
        let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
        #expect(!safeToRetry)
        #expect(bar.stopPresses == 1)
        #expect(bar.playPresses == 0, "a failed Stop must not fall back to pressing Play")
    }

    @Test("A control bar with no Stop button keeps the Play checkbox path")
    func stopWithoutAStopButtonKeepsTheOlderPath() async throws {
        // Logic 12 exposes no Stop button that is known, and its Play press is what stopped it.
        let bar = Logic13Bar(playing: true, withStopButton: false)
        let router = await bar.router()
        _ = await router.route(operation: "transport.stop", params: [:])
        #expect(bar.stopPresses == 0)
        #expect(bar.playPresses >= 1)
    }

    // MARK: Pause in Beats

    private actor Readings: Channel {
        nonisolated let id: ChannelID
        let observedTempo: Double?
        var states: [TransportState]
        var executed: [String] = []

        init(id: ChannelID, observedTempo: Double?, states: [TransportState] = []) {
            self.id = id
            self.observedTempo = observedTempo
            self.states = states
        }

        func start() async throws {}
        func stop() async {}

        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            executed.append(operation)
            switch operation {
            case "transport.get_state":
                guard !states.isEmpty else { return .error("no more readings") }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return .success(String(decoding: try! encoder.encode(states.removeFirst()), as: UTF8.self))
            case "transport.get_tempo":
                guard let observedTempo else { return .error("tempo slider not found, so the tempo was not read") }
                return .success("{\"tempo\":\(observedTempo)}")
            case "transport.pause", "transport.resume":
                return .success("{\"sent\":true}")
            default:
                return .error("unexpected \(operation)")
            }
        }

        func healthCheck() async -> ChannelHealth { .healthy(detail: "fake") }
    }

    private static func reading(_ playing: Bool, _ position: String, _ components: [TransportPositionComponent]) -> TransportState {
        TransportState(
            isPlaying: playing,
            position: position,
            positionReadback: TransportPositionReadback(value: position, observedComponents: components),
            lastUpdated: Date()
        )
    }

    private static let ticks: [TransportPositionComponent] = [.bar, .beat, .subdivision, .tick]

    private func run(
        _ command: String, tempo: Double?, states: [TransportState]
    ) async throws -> (envelope: [String: Any], executed: [String], sleeps: [UInt64]) {
        let router = ChannelRouter()
        let write = Readings(id: .cgEvent, observedTempo: nil)
        let read = Readings(id: .accessibility, observedTempo: tempo, states: states)
        await router.register(write)
        await router.register(read)
        let sleeps = SleepLog()
        let result = await TransportDispatcher.handle(
            command: command, params: [:], router: router, cache: StateCache(),
            sleep: { await sleeps.add($0) }
        )
        let text = sharedToolText(result)
        return (try #require(issue1621Object(text)), await write.executed, await sleeps.values)
    }

    private actor SleepLog {
        var values: [UInt64] = []
        func add(_ value: UInt64) { values.append(value) }
    }

    @Test("Pause with the tempo unread but the position read to the tick tells moving from still and pauses")
    func pauseInBeatsSendsOnePauseAndVerifiesByTickStillness() async throws {
        // Measured in Beats: tempo slider absent, position `13.3.4.58`, `13.3.4.189`, ... while playing.
        // Mutation killed: the `tempo_unreadable` refusal restored for every unread tempo.
        let t = Self.ticks
        let out = try await run("pause", tempo: nil, states: [
            Self.reading(true, "13.3.4.58", t), Self.reading(true, "13.3.4.189", t),
            Self.reading(true, "14.2.2.218", t), Self.reading(true, "14.2.2.218", t),
        ])
        #expect(out.envelope["state"] as? String == "A", "\(out.envelope)")
        #expect(out.executed == ["transport.pause"])
        #expect(out.envelope["stillness_basis"] as? String == "tick_resolution_position")
        #expect(out.sleeps.first == 1_000_000_000)
    }

    @Test("Pause in Beats on an already paused transport sends nothing")
    func pauseInBeatsAlreadyPausedSendsNothing() async throws {
        let t = Self.ticks
        let out = try await run("pause", tempo: nil, states: [
            Self.reading(true, "14.2.2.218", t), Self.reading(true, "14.2.2.218", t),
        ])
        #expect(out.envelope["state"] as? String == "A", "\(out.envelope)")
        let alreadyPaused = try #require(out.envelope["already_paused"] as? Bool)
        #expect(alreadyPaused)
        #expect(out.executed.isEmpty)
    }

    @Test("Pause with the tempo unread and the position read to the beat only still refuses, and names the display mode")
    func pauseWithNeitherTempoNorTicksRefusesAndNamesTheDisplay() async throws {
        let out = try await run("pause", tempo: nil, states: [
            Self.reading(true, "12.4", [.bar, .beat]), Self.reading(true, "12.4", [.bar, .beat]),
        ])
        #expect(out.envelope["state"] as? String == "C")
        #expect(out.envelope["error"] as? String == "readback_unavailable")
        #expect(out.envelope["reason"] as? String == "tempo_unreadable")
        let writeAttempted = try #require(out.envelope["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(out.executed.isEmpty)
        let hint = try #require(out.envelope["hint"] as? String)
        #expect(hint.contains("display"), "the refusal must name the Control Bar display mode: \(hint)")
        #expect(hint.contains("Beats"), "and say what to change: \(hint)")
    }

    @Test("Play from a paused start in Beats resumes it through the tick-resolution gap")
    func playFromPausedInBeatsResumes() async throws {
        let t = Self.ticks
        let out = try await run("play", tempo: nil, states: [
            Self.reading(true, "14.2.2.218", t), Self.reading(true, "14.2.2.218", t),
            Self.reading(true, "14.2.2.230", t), Self.reading(true, "14.3.1.40", t),
        ])
        #expect(out.envelope["state"] as? String == "A", "\(out.envelope)")
        #expect(out.executed == ["transport.resume"])
    }

    @Test("Readings of different grain are not compared: `12.4` against `12.4.1.1` is not a moving playhead")
    func playheadStillRefusesToCompareDifferentGrain() throws {
        let coarse = Self.reading(true, "12.4", [.bar, .beat])
        let fine = Self.reading(true, "12.4.1.1", Self.ticks)
        #expect(TransportDispatcher.playheadStill(coarse, fine) == nil)
        let identical = try #require(TransportDispatcher.playheadStill(fine, fine))
        #expect(identical)
    }
}
