@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1029 review round 1, R-02: pause and play size their stillness gap from a tempo read in the same
// measurement, `transport.get_tempo`. That read must say when the tempo was not read. The transport
// state's own tempo keeps the model's 120 default then, and a gap sized from 120 during slow playback
// calls a moving playhead still.
//
// These tests drive the real router and the real Accessibility channel over a fake control bar and
// read the tempo the way the dispatcher does, through `TransportDispatcher.observedTempo(router:)`.

private let observedTempoNoMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

/// A control bar holding a tempo slider with this description and value, or no slider when `slider`
/// is nil. A nil `value` is a slider whose value does not read.
private func observedTempoRouter(slider: (description: String, value: Any?)?) async -> ChannelRouter {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(10_470)
    let window = builder.element(10_471)
    let controlBar = builder.element(10_472)
    let tempoSlider = builder.element(10_473)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    if let slider {
        builder.setChildren(controlBar, [tempoSlider])
        builder.setAttribute(tempoSlider, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(tempoSlider, kAXDescriptionAttribute as String, slider.description)
        if let value = slider.value {
            builder.setAttribute(tempoSlider, kAXValueAttribute as String, value)
        }
    }

    let channel = AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        hasVisibleWindow: { true },
        logicRuntime: builder.makeLogicRuntime(appElement: app),
        controlBarMouseRuntime: observedTempoNoMouseRuntime
    ))
    let router = ChannelRouter()
    await router.register(channel)
    return router
}

@Test(arguments: [
    ("Tempo", 120.0),
    ("템포", 20.0),
    ("Tempo", 5.0),
])
func observedTempoReadsTheTempoSlider(description: String, tempo: Double) async throws {
    // The slider `set_tempo` finds and reads back, in English and in Korean.
    let router = await observedTempoRouter(slider: (description, NSNumber(value: tempo)))
    let observed = try #require(await TransportDispatcher.observedTempo(router: router))
    #expect(observed == tempo)
}

@Test func observedTempoIsNilWhenThereIsNoTempoSlider() async {
    // Mutation killed: a missing slider answered with the model's default
    // (`return .error(...)` -> `return encodeResult(["tempo": 120.0])`).
    let router = await observedTempoRouter(slider: nil)
    #expect(await TransportDispatcher.observedTempo(router: router) == nil)
}

@Test func observedTempoIsNilWhenTheSliderValueDoesNotRead() async {
    // Mutation killed: an unread value answered with the model's default
    // (`extractSliderValue(...)` -> `extractSliderValue(...) ?? 120.0`).
    let router = await observedTempoRouter(slider: ("Tempo", nil))
    #expect(await TransportDispatcher.observedTempo(router: router) == nil)
}

@Test func accessibilityTempoReadRefusesAZeroTempo() async {
    // A zero tempo sizes no gap: 1.25 beats at 0 BPM has no length. This asserts on the Accessibility
    // channel's own answer, because the dispatcher also drops a tempo that is not positive.
    // Mutation killed: `tempo.isFinite, tempo > 0` dropped from `defaultGetObservedTempo`.
    let router = await observedTempoRouter(slider: ("Tempo", NSNumber(value: 0.0)))
    let result = await router.route(operation: "transport.get_tempo")
    #expect(!result.isSuccess, "a zero tempo was answered as read: \(result.message)")
}
