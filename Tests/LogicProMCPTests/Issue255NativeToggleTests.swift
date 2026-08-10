@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private let issue255NoMouseRuntime = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

private func issue255Object(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func issue255Channel(
    logicRuntime: AXLogicProElements.Runtime
) -> AccessibilityChannel {
    AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: logicRuntime,
        controlBarMouseRuntime: issue255NoMouseRuntime
    ))
}

@Test func issue255NativeTogglesRouteAccessibilityFirst() {
    #expect(ChannelRouter.routingTable["transport.toggle_count_in"]?.first == .accessibility)
    #expect(ChannelRouter.routingTable["edit.toggle_step_input"]?.first == .accessibility)
}

@Test func issue255CountInMatchesLogic123ControlBarTitle() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_500)
    let window = builder.element(25_501)
    let controlBar = builder.element(25_502)
    let countIn = builder.element(25_503)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
    builder.setChildren(controlBar, [countIn])
    builder.setAttribute(countIn, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(countIn, kAXTitleAttribute as String, "Count In")
    builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: false))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == countIn, action == kAXPressAction as String else { return false }
            builder.setAttribute(countIn, kAXValueAttribute as String, NSNumber(value: true))
            return true
        }
    )
    let channel = issue255Channel(logicRuntime: logicRuntime)

    let result = await channel.execute(operation: "transport.toggle_count_in", params: [:])

    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    let v1 = try #require(object["verified"] as? Bool)
    #expect(v1)
    let v2 = try #require(object["observed"] as? Bool)
    #expect(v2)
    #expect(object["button"] as? String == "Count In")
}

@Test func japaneseCreatorStudioPlayUsesExactLocalizedCheckboxAndReadback() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_504)
    let window = builder.element(25_505)
    let controlBar = builder.element(25_506)
    let play = builder.element(25_507)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setChildren(window, [controlBar])
    builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "コントロールバー")
    builder.setChildren(controlBar, [play])
    builder.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
    builder.setAttribute(play, kAXTitleAttribute as String, "再生")
    builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: false))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == play, action == kAXPressAction as String else { return false }
            builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: true))
            return true
        }
    )
    let channel = issue255Channel(logicRuntime: logicRuntime)

    let result = await channel.execute(operation: "transport.play", params: [:])

    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    #expect(object["state"] as? String == "A")
    let verified = try #require(object["verified"] as? Bool)
    let observed = try #require(object["observed"] as? Bool)
    #expect(verified)
    #expect(observed)
    #expect(object["button"] as? String == "Play")
}

@Test func issue255StepInputUsesWindowMenuAndVerifiesWindowState() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(25_510)
    let tracksWindow = builder.element(25_511)
    let stepInputWindow = builder.element(25_512)
    let menuBar = builder.element(25_513)
    let windowMenu = builder.element(25_514)
    let menu = builder.element(25_515)
    let showStepInput = builder.element(25_516)

    builder.setAttribute(app, kAXMainWindowAttribute as String, tracksWindow)
    builder.setAttribute(app, kAXWindowsAttribute as String, [tracksWindow])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setAttribute(tracksWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(tracksWindow, kAXTitleAttribute as String, "Untitled - Tracks")
    builder.setAttribute(stepInputWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(
        stepInputWindow,
        kAXTitleAttribute as String,
        "Untitled - Step Input Keyboard"
    )

    builder.setChildren(menuBar, [windowMenu])
    builder.setAttribute(windowMenu, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
    builder.setAttribute(windowMenu, kAXTitleAttribute as String, "Window")
    builder.setChildren(windowMenu, [menu])
    builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
    builder.setChildren(menu, [showStepInput])
    builder.setAttribute(showStepInput, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(showStepInput, kAXTitleAttribute as String, "Show Step Input Keyboard")
    builder.setAttribute(showStepInput, kAXEnabledAttribute as String, NSNumber(value: true))

    let logicRuntime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard element == showStepInput, action == kAXPressAction as String else { return false }
            builder.setAttribute(app, kAXWindowsAttribute as String, [tracksWindow, stepInputWindow])
            return true
        }
    )
    let channel = issue255Channel(logicRuntime: logicRuntime)

    let result = await channel.execute(operation: "edit.toggle_step_input", params: [:])

    #expect(result.isSuccess)
    let object = try #require(issue255Object(result.message))
    let v1 = try #require(object["verified"] as? Bool)
    #expect(v1)
    let v2 = try #require(object["previous_open"] as? Bool)
    #expect(!v2)
    let v3 = try #require(object["observed_open"] as? Bool)
    #expect(v3)
    #expect(object["via"] as? String == "window-menu")
}
