@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #1060 — the Portuguese control bar describes Play `Reproduz`
//
// A Portuguese Logic 12.3 describes the control bar's Play checkbox `Reproduz` (read 2026-09-29),
// the pt value of Localizable.strings `StrTransportBtns|||Play`. transportPlayControl was derived
// from key `play`, whose pt value is `reproduzir`. The control-bar finder asks `.exactStrict` and
// the transport-state read asks whether the description contains a member, and `Reproduz` is
// neither `reproduzir` nor contains it. So in Portuguese `play` found no checkbox and fell to the
// MCU rung, and a playing transport did not read as playing. Each case below drives a consumer
// with the checkbox names a pt control bar showed live, and fails if `Reproduz` leaves the set.

private let issue1060NoMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

private final class Issue1060AXActions: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ action: String) { lock.lock(); names.append(action); lock.unlock() }
    var performed: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// A Portuguese control bar holding Cycle, Record and Play as Logic 12.3 describes them. A press on
/// Play is delivered and flips its value, the way a real press does; Cycle and Record are never
/// pressed by these operations, and a press on either is recorded so the test can say so.
private struct Issue1060ControlBar {
    let builder = FakeAXRuntimeBuilder()
    let actions = Issue1060AXActions()
    let app: AXUIElement
    let controlBar: AXUIElement
    let play: AXUIElement

    init(playing: Bool) {
        app = builder.element(10_600)
        let window = builder.element(10_601)
        controlBar = builder.element(10_602)
        let cycle = builder.element(10_603)
        let record = builder.element(10_604)
        play = builder.element(10_605)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Barra de Controles")
        builder.setChildren(controlBar, [cycle, record, play])
        for (box, description, value) in [(cycle, "Repetição", false), (record, "Grava", false),
                                          (play, "Reproduz", playing)] {
            builder.setAttribute(box, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            builder.setAttribute(box, kAXDescriptionAttribute as String, description)
            builder.setAttribute(box, kAXValueAttribute as String, NSNumber(value: value))
        }
    }

    func logicRuntime() -> AXLogicProElements.Runtime {
        let builder = self.builder
        let actions = self.actions
        let play = self.play
        return builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                actions.record("\(builder.elementID(element)):\(action)")
                guard element == play, action == kAXPressAction as String else { return true }
                let pressed = (builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?
                    .boolValue ?? false
                builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: !pressed))
                return true
            }
        )
    }
}

/// The CGEvent rung, which `transport.stop` tries first (RoutingTable, #1029). A delivered Stop key
/// turns the control bar's Play off, the way Logic does; every operation it is handed is recorded.
private actor Issue1060StopKey: Channel {
    nonisolated let id = ChannelID.cgEvent
    private let builder: FakeAXRuntimeBuilder
    private nonisolated(unsafe) let play: AXUIElement
    private(set) var executed: [String] = []

    init(bar: Issue1060ControlBar) {
        builder = bar.builder
        play = bar.play
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executed.append(operation)
        if operation == "transport.stop" {
            builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: false))
        }
        return .success("stop key: \(operation)")
    }

    func healthCheck() async -> ChannelHealth { .healthy(detail: "stop key") }
}

private func issue1060Object(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Suite("Issue #1060 — Portuguese play, stop and the playing read find the control bar's Reproduz")
struct Issue1060PortuguesePlayTests {
    /// The control bar's Play row, cited at pt because that is the locale whose value the set
    /// lacked; `check-labelsets-are-derived.py` holds the row in all ten either way.
    private static let playRow =
        "logic-canon://strings/Contents%2FFrameworks%2FLogic.framework%2FVersions%2FA%2FResources%2FLocalizable.strings/pt/"
        + "StrTransportBtns%7C%7C%7CPlay#value"

    /// Mutation that turns this red: remove `Reproduz` from transportPlayControl's variants. The AX
    /// rung then finds no Play checkbox and the router hands `play` to the MCU rung, which is what
    /// a Portuguese Logic did on 2026-09-29: State B, the position still 1.1.
    @Test("play in Portuguese presses Reproduz through AX, once, and no later rung runs")
    func playPressesReproduz() async throws {
        let bar = Issue1060ControlBar(playing: false)
        let router = ChannelRouter()
        let mcu = MockChannel(id: .mcu)
        let midiKeyCommands = MockChannel(id: .midiKeyCommands)
        let cgEvent = MockChannel(id: .cgEvent)
        await router.register(AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            logicRuntime: bar.logicRuntime(),
            controlBarMouseRuntime: issue1060NoMouseRuntime
        )))
        await router.register(mcu)
        await router.register(midiKeyCommands)
        await router.register(cgEvent)

        let result = await router.route(operation: "transport.play", params: [:])

        let playID = bar.builder.elementID(bar.play)
        #expect(bar.actions.performed == ["\(playID):\(kAXPressAction as String)"])
        let later = await mcu.executedOps.count + midiKeyCommands.executedOps.count
            + cgEvent.executedOps.count
        #expect(later == 0, "the AX rung found Play, so nothing after it runs")
        #expect(result.isSuccess)
        let envelope = try #require(issue1060Object(result.message))
        #expect(try #require(envelope["action"] as? String) == "axpress")
        #expect(try #require(envelope["state"] as? String) == "A")
    }

    /// Mutation that turns this red: the same removal. `logic_transport stop` sends its CGEvent key
    /// only after reading the transport as playing, and that read is this set. Without `Reproduz` a
    /// playing Portuguese transport read as stopped, so `stop` answered State A with nothing sent.
    @Test("stop in Portuguese reads the transport as playing and sends its key, and AX presses nothing")
    func stopThroughTheToolSendsTheKey() async throws {
        let bar = Issue1060ControlBar(playing: true)
        let router = ChannelRouter()
        let stopKey = Issue1060StopKey(bar: bar)
        await router.register(AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            logicRuntime: bar.logicRuntime(),
            controlBarMouseRuntime: issue1060NoMouseRuntime
        )))
        await router.register(stopKey)

        let result = await TransportDispatcher.handle(
            command: "stop", params: [:], router: router, cache: StateCache(), sleep: { _ in }
        )

        #expect(await stopKey.executed == ["transport.stop"])
        #expect(bar.actions.performed.isEmpty, "the CGEvent rung answered, so AX pressed nothing")
        #expect(!(try #require(result.isError as Bool?)))
        let envelope = try #require(issue1060Object(sharedToolText(result)))
        #expect(try #require(envelope["state"] as? String) == "A")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(try #require(envelope["verify_source"] as? String) == "ax_transport_state")
    }

    /// Mutation that turns this red: the same removal. This is the rung after CGEvent, which runs
    /// when CGEvent refuses: it sets the same checkbox off, and in Portuguese it found none.
    @Test("stop's Accessibility rung in Portuguese sets Reproduz off")
    func stopReleasesReproduz() async throws {
        let bar = Issue1060ControlBar(playing: true)
        let channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            logicRuntime: bar.logicRuntime(),
            controlBarMouseRuntime: issue1060NoMouseRuntime
        ))

        let result = await channel.execute(operation: "transport.stop", params: [:])

        let playID = bar.builder.elementID(bar.play)
        #expect(bar.actions.performed == ["\(playID):\(kAXPressAction as String)"])
        #expect(result.isSuccess)
        let value = try #require(bar.builder.attributeValue(bar.play, kAXValueAttribute as String) as? NSNumber)
        #expect(!value.boolValue)
    }

    /// Mutation that turns this red: the same removal. `transport.get_state` reads Play twice --
    /// the containment scan over the bar, then the `.exactStrict` checkbox read that overrides it --
    /// and in Portuguese neither found it, so `isPlaying` kept the model's default.
    @Test("a Portuguese control bar with Reproduz pressed reads as playing, by both reads")
    func playingReadFindsReproduz() throws {
        let bar = Issue1060ControlBar(playing: true)
        let runtime = bar.logicRuntime()

        let scanned = AXValueExtractors.extractTransportState(from: bar.controlBar, runtime: runtime.ax)
        #expect(scanned.isPlaying, "the containment scan in extractTransportState")

        let checked = try #require(AXLogicProElements.readControlBarCheckboxValue(
            matching: AXLocalePolicy.transportPlayControl, runtime: runtime
        ))
        #expect(checked, "the .exactStrict checkbox read")

        let result = AccessibilityChannel.defaultGetTransportState(runtime: runtime)
        let state = try #require(issue1060Object(result.message))
        #expect(try #require(state["isPlaying"] as? Bool))
    }

    /// Mutation that turns this red: drop the `alsoDerivedFrom` entry. That entry is what makes
    /// `Scripts/check-labelsets-are-derived.py` hold the set to the control bar's own row in every
    /// locale; without it a later edit could drop `Reproduz` and only this suite would notice.
    @Test("transportPlayControl names the control bar's Play row beside the play row")
    func namesTheControlBarRow() {
        #expect(AXLocalePolicy.transportPlayControl.alsoDerivedFrom == [Self.playRow])
    }
}
