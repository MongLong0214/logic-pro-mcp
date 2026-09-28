@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// MARK: - Issue #1042 — a delivered toggle press is never followed by a second one
//
// A toggle has no target value. When the first press is delivered and the readback does not read
// as changed within the wait, the press may still have landed with the readback lagging, and any
// further press -- AXConfirm on the same checkbox, or the next channel's key command -- turns the
// control back. Each case routes through the real ChannelRouter with the real AccessibilityChannel
// on a fake AX tree whose press is delivered and whose value never changes, and counts every press
// that could reach Logic: the AX actions performed and each later rung's executes.

private let issue1042NoMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

private final class Issue1042AXActions: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func record(_ action: String) { lock.lock(); names.append(action); lock.unlock() }
    var performed: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

private struct Issue1042Ladder {
    let router: ChannelRouter
    let midiKeyCommands: MockChannel
    let cgEvent: MockChannel
    let mcu: MockChannel

    /// Every press after the AX rung's own: one per later channel execute.
    func laterRungPresses() async -> Int {
        let midi = await midiKeyCommands.executedOps.count
        let cg = await cgEvent.executedOps.count
        let mcuCount = await mcu.executedOps.count
        return midi + cg + mcuCount
    }
}

private func issue1042Ladder(logicRuntime: AXLogicProElements.Runtime) async -> Issue1042Ladder {
    let router = ChannelRouter()
    let accessibility = AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: logicRuntime,
        controlBarMouseRuntime: issue1042NoMouseRuntime
    ))
    let ladder = Issue1042Ladder(
        router: router,
        midiKeyCommands: MockChannel(id: .midiKeyCommands),
        cgEvent: MockChannel(id: .cgEvent),
        mcu: MockChannel(id: .mcu)
    )
    await router.register(accessibility)
    await router.register(ladder.midiKeyCommands)
    await router.register(ladder.cgEvent)
    await router.register(ladder.mcu)
    return ladder
}

private func issue1042Object(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// A control bar holding one checkbox with this AXDescription, value off. Every action on it is
/// delivered (returns true) and none changes the value: a press whose readback never catches up.
private func issue1042LaggingControlBar(
    description: String, actions: Issue1042AXActions
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(10_420)
    let window = builder.element(10_421)
    let controlBar = builder.element(10_422)
    let checkbox = builder.element(10_423)
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "컨트롤 막대")
    builder.setChildren(controlBar, [checkbox])
    builder.setAttribute(checkbox, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(checkbox, kAXDescriptionAttribute as String, description)
    builder.setAttribute(checkbox, kAXValueAttribute as String, NSNumber(value: false))
    return builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == checkbox else { return false }
            actions.record(action)
            return true
        }
    )
}

@Suite("Issue #1042 — a delivered toggle press is not pressed again by a fallback")
struct Issue1042ToggleSecondPressTests {
    /// Mutation this kills: after a delivered press whose readback did not change, go on to the
    /// next strategy and end retry-safe (the pre-#1042 `clickControlBarCheckbox`). That performs
    /// AXPress then AXConfirm and lets the router hand the toggle to the MIDI key command: three
    /// presses where one was delivered.
    @Test(
        "a control-bar toggle whose readback lags is pressed once, across the whole ladder",
        arguments: [
            ("transport.toggle_cycle", "사이클"),
            ("transport.toggle_metronome", "메트로놈"),
            ("transport.toggle_count_in", "카운트 인"),
        ]
    )
    func laggingControlBarToggleIsPressedOnce(operation: String, description: String) async throws {
        let actions = Issue1042AXActions()
        let ladder = await issue1042Ladder(
            logicRuntime: issue1042LaggingControlBar(description: description, actions: actions)
        )

        let result = await ladder.router.route(operation: operation, params: [:])

        #expect(actions.performed == [kAXPressAction as String], "one AX press, no AXConfirm after it")
        let later = await ladder.laterRungPresses()
        #expect(later == 0, "no later rung may press a toggle whose first press may have landed")
        #expect(!result.isSuccess)
        let envelope = try #require(issue1042Object(result.message))
        #expect(try #require(envelope["state"] as? String) == "C")
        #expect(try #require(envelope["error"] as? String) == "readback_mismatch")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        #expect(try #require(envelope["action"] as? String) == "axpress")
    }

    /// Mutation this kills: leave the Step Input Keyboard mismatch retry-safe with no
    /// `fallback_unsafe` (the pre-#1042 extras). The router then hands the toggle to the MIDI key
    /// command, a second press on a window the first may already have opened.
    @Test("a Step Input Keyboard press whose window never reads as opened is not pressed again")
    func laggingStepInputIsPressedOnce() async throws {
        let actions = Issue1042AXActions()
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10_430)
        let tracksWindow = builder.element(10_431)
        let menuBar = builder.element(10_432)
        let windowMenu = builder.element(10_433)
        let menu = builder.element(10_434)
        let stepInput = builder.element(10_435)
        builder.setAttribute(app, kAXMainWindowAttribute as String, tracksWindow)
        builder.setAttribute(app, kAXWindowsAttribute as String, [tracksWindow])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(tracksWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(tracksWindow, kAXTitleAttribute as String, "Untitled - Tracks")
        builder.setChildren(menuBar, [windowMenu])
        builder.setAttribute(windowMenu, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
        builder.setAttribute(windowMenu, kAXTitleAttribute as String, "Window")
        builder.setChildren(windowMenu, [menu])
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setChildren(menu, [stepInput])
        builder.setAttribute(stepInput, kAXRoleAttribute as String, kAXMenuItemRole as String)
        builder.setAttribute(stepInput, kAXTitleAttribute as String, "Step Input Keyboard")
        builder.setAttribute(stepInput, kAXEnabledAttribute as String, NSNumber(value: true))
        let logicRuntime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard element == stepInput else { return false }
                actions.record(action)
                return true
            }
        )
        let ladder = await issue1042Ladder(logicRuntime: logicRuntime)

        let result = await ladder.router.route(operation: "edit.toggle_step_input", params: [:])

        #expect(actions.performed == [kAXPressAction as String])
        let later = await ladder.laterRungPresses()
        #expect(later == 0, "no later rung may press a toggle whose first press may have landed")
        let envelope = try #require(issue1042Object(result.message))
        #expect(try #require(envelope["error"] as? String) == "readback_mismatch")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
    }
}
