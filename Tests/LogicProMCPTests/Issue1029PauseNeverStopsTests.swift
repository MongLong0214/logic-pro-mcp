@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

// #1029 review round 1, R-01: pause must never run Stop. Logic's Pause (keypad Period) freezes the
// playhead and leaves Play on. The Accessibility channel has no pause control, and its pause case used
// to press Stop, which turns Play off and clears Record. The pause route reached that case whenever
// the CGEvent rung before it refused (Logic not frontmost, for one), so a refused pause became a stop.
//
// These tests drive the real router and the real Accessibility channel over a fake control bar, next
// to a CGEvent channel that refuses, and count the presses the fake receives. Nothing here reads a
// clock.

/// Every AX press the fake control bar receives, by element id.
private final class ControlBarPresses: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed: [Int] = []

    func record(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        pressed.append(id)
    }

    var all: [Int] {
        lock.lock(); defer { lock.unlock() }
        return pressed
    }
}

/// Counts the keystrokes a CGEvent channel posts.
private final class PostedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private let pauseTestNoMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

/// A playing control bar: Play on, Record off. A press on either checkbox flips it, as Logic's does.
private struct PlayingControlBar {
    let builder: FakeAXRuntimeBuilder
    let play: AXUIElement
    let channel: AccessibilityChannel

    var playIsOn: Bool? {
        (builder.attributeValue(play, kAXValueAttribute as String) as? NSNumber)?.boolValue
    }

    init(presses: ControlBarPresses) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10_450)
        let window = builder.element(10_451)
        let controlBar = builder.element(10_452)
        let play = builder.element(10_453)
        let record = builder.element(10_454)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        builder.setChildren(controlBar, [play, record])
        for (checkbox, title, on) in [(play, "Play", true), (record, "Record", false)] {
            builder.setAttribute(checkbox, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            builder.setAttribute(checkbox, kAXTitleAttribute as String, title)
            builder.setAttribute(checkbox, kAXValueAttribute as String, NSNumber(value: on))
        }

        let logicRuntime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard action == kAXPressAction as String else { return false }
                presses.record(builder.elementID(element))
                let current = (builder.attributeValue(element, kAXValueAttribute as String) as? NSNumber)?.boolValue
                if let current {
                    builder.setAttribute(element, kAXValueAttribute as String, NSNumber(value: !current))
                }
                return true
            }
        )
        self.builder = builder
        self.play = play
        self.channel = AccessibilityChannel(runtime: .axBacked(
            isTrusted: { true },
            isLogicProRunning: { true },
            hasVisibleWindow: { true },
            logicRuntime: logicRuntime,
            controlBarMouseRuntime: pauseTestNoMouseRuntime
        ))
    }
}

/// A CGEvent channel that refuses every keystroke: Logic is not frontmost and cannot be activated.
private func refusingCGEventChannel(_ posted: PostedKeys) -> CGEventChannel {
    CGEventChannel(runtime: CGEventChannel.Runtime(
        isLogicProRunning: { true },
        logicProPID: { 4242 },
        postKeyEvent: { _, _, _ in
            posted.record()
            return true
        },
        sleepMicros: { _ in },
        isLogicFrontmost: { false },
        activateLogic: { false }
    ))
}

private func pauseTestObject(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Test func pauseRefusedByCGEventDoesNotWalkOntoTheAccessibilityStop() async throws {
    // Mutations killed: `.accessibility` put back in the pause route (the reply becomes
    // `channels_exhausted`, or with the old AX case a State A stop), and the old AX case
    // (`toggleTransportButton("Stop")`) with it (a press lands and Play goes off).
    let presses = ControlBarPresses()
    let posted = PostedKeys()
    let bar = PlayingControlBar(presses: presses)
    let router = ChannelRouter()
    await router.register(refusingCGEventChannel(posted))
    await router.register(bar.channel)

    let result = await router.route(operation: "transport.pause")

    #expect(presses.all.isEmpty, "pause pressed control-bar elements \(presses.all)")
    #expect(posted.total == 0)
    let playOn = try #require(bar.playIsOn)
    #expect(playOn, "Play must still be on: nothing was paused and nothing was stopped")
    #expect(!result.isSuccess, "\(result.message)")
    let object = try #require(pauseTestObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["state"] as? String != "A")
    // The CGEvent rung's own refusal, verbatim: it names why no key was posted.
    #expect(object["error"] as? String == "ax_write_failed")
    #expect(object["frontmost_preparation"] as? String != nil)
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
}

@Test func accessibilityPauseRefusesAndPressesNothing() async throws {
    // Logic has no AX pause control, and Stop is not pause. A direct call of the channel's pause
    // case must refuse and leave the transport alone, so no route or caller reaches Stop through it.
    // Mutation killed: the case restored to `return runtime.toggleTransportButton("Stop")`.
    let presses = ControlBarPresses()
    let bar = PlayingControlBar(presses: presses)

    let result = await bar.channel.execute(operation: "transport.pause", params: [:])

    #expect(presses.all.isEmpty, "the AX pause case pressed \(presses.all)")
    let playOn = try #require(bar.playIsOn)
    #expect(playOn)
    #expect(!result.isSuccess, "\(result.message)")
    let object = try #require(pauseTestObject(result.message))
    #expect(object["state"] as? String == "C")
    #expect(object["error"] as? String == "not_supported")
    #expect(object["operation"] as? String == "transport.pause")
    let writeAttempted = try #require(object["write_attempted"] as? Bool)
    #expect(!writeAttempted)
}
