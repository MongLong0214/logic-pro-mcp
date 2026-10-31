@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// A delivered AX action can precede its value readback. These fixtures keep every AX read and
// action in process; no running Logic instance or HID event is involved.
final class Issue1059Checkbox: @unchecked Sendable {
    enum Readback {
        case arrivesAfterWait
        case unreadableAfterPress
        case staysAtInitial
        case pressFailsThenConfirmChanges
    }

    private let lock = NSLock()
    private let initial: Bool
    private let readback: Readback
    private var readsAfterDelivery = 0
    private var delivered = false
    private var actions: [String] = []

    init(initial: Bool, readback: Readback) {
        self.initial = initial
        self.readback = readback
    }

    func value() -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        guard delivered else { return NSNumber(value: initial) }
        readsAfterDelivery += 1
        switch readback {
        case .arrivesAfterWait:
            return NSNumber(value: readsAfterDelivery > 12 ? !initial : initial)
        case .unreadableAfterPress:
            return nil
        case .staysAtInitial:
            return NSNumber(value: initial)
        case .pressFailsThenConfirmChanges:
            return NSNumber(value: !initial)
        }
    }

    func perform(_ action: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        actions.append(action)
        if readback == .pressFailsThenConfirmChanges && action == kAXPressAction as String {
            return false
        }
        delivered = true
        return true
    }

    var performed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}

private struct Issue1059Bar {
    let checkbox: Issue1059Checkbox
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let target: AXUIElement

    init(description: String, initial: Bool, readback: Issue1059Checkbox.Readback, includeStoppedPlay: Bool = false) {
        checkbox = Issue1059Checkbox(initial: initial, readback: readback)
        app = builder.element(10_590)
        let window = builder.element(10_591)
        let controlBar = builder.element(10_592)
        target = builder.element(10_593)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "컨트롤 막대")
        var checkboxes = [target]
        if includeStoppedPlay {
            let play = builder.element(10_594)
            builder.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            builder.setAttribute(play, kAXDescriptionAttribute as String, "재생")
            builder.setAttribute(play, kAXValueAttribute as String, NSNumber(value: false))
            checkboxes.append(play)
        }
        builder.setChildren(controlBar, checkboxes)
        builder.setAttribute(target, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(target, kAXDescriptionAttribute as String, description)
    }

    func runtime() -> AXLogicProElements.Runtime {
        let checkbox = self.checkbox
        let target = self.target
        return builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard element == target, attribute == kAXValueAttribute as String else { return nil }
                return .some(checkbox.value())
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard element == target else { return false }
                return checkbox.perform(action)
            }
        )
    }
}

private let issue1059NoMouse = AXMouseHelper.Runtime(
    postMouseEvent: { _, _, _ in false },
    postKeyEvent: { _ in false },
    postUnicodeScalar: { _ in false },
    sleepMicros: { _ in }
)

private func issue1059Channel(_ bar: Issue1059Bar) -> AccessibilityChannel {
    AccessibilityChannel(runtime: .axBacked(
        isTrusted: { true },
        isLogicProRunning: { true },
        logicRuntime: bar.runtime(),
        controlBarMouseRuntime: issue1059NoMouse
    ))
}

private func issue1059Object(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Suite("Issue #1059 — conditional transport checkboxes stop at a delivered press")
struct Issue1059TransportFirstPressTests {
    @Test("Play and Record do not press again or fall through when readback lags", arguments: [
        ("transport.play", "재생", Issue1059Checkbox.Readback.arrivesAfterWait),
        ("transport.record", "녹음", Issue1059Checkbox.Readback.unreadableAfterPress),
    ])
    func deliveredPressStopsLadder(operation: String, description: String,
                                   readback: Issue1059Checkbox.Readback) async throws {
        let bar = Issue1059Bar(description: description, initial: false, readback: readback)
        let router = ChannelRouter()
        let fallbacks = [
            MockChannel(id: .appleScript), MockChannel(id: .mcu),
            MockChannel(id: .coreMIDI), MockChannel(id: .cgEvent),
        ]
        await router.register(issue1059Channel(bar))
        for channel in fallbacks { await router.register(channel) }

        let result = await router.route(operation: operation, params: [:])

        #expect(bar.checkbox.performed == [kAXPressAction as String])
        for channel in fallbacks {
            #expect(await channel.executedOps.isEmpty)
        }
        #expect(!result.isSuccess)
        let envelope = try #require(issue1059Object(result.message))
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["error"] as? String == "readback_mismatch")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(envelope["action"] as? String == "axpress")
        #expect(envelope["attempts"] as? [String] == ["axpress"])
        if readback == .arrivesAfterWait {
            #expect(try #require(envelope["observed"] as? Bool),
                    "the mismatch receipt includes the fresh read after the wait")
        } else {
            #expect(envelope["observed"] is NSNull)
        }
    }

    @Test("Stop clears Record at most once even when its result is discarded")
    func stopRecordClearIsPressedOnce() async throws {
        let bar = Issue1059Bar(description: "녹음", initial: true,
                               readback: .staysAtInitial, includeStoppedPlay: true)
        let result = await issue1059Channel(bar).execute(operation: "transport.stop", params: [:])

        #expect(bar.checkbox.performed == [kAXPressAction as String])
        #expect(result.isSuccess)
    }

    @Test("Stop cannot fall through after its Record clear may have landed")
    func stopRecordClearForbidsFallbackWhenStopControlIsMissing() async throws {
        let bar = Issue1059Bar(description: "녹음", initial: true, readback: .arrivesAfterWait)
        let router = ChannelRouter()
        let cgEvent = MockChannel(id: .cgEvent, available: false)
        let fallbacks = [
            MockChannel(id: .mcu), MockChannel(id: .coreMIDI), MockChannel(id: .appleScript),
        ]
        await router.register(issue1059Channel(bar))
        await router.register(cgEvent)
        for channel in fallbacks { await router.register(channel) }

        let result = await router.route(operation: "transport.stop", params: [:])

        #expect(bar.checkbox.performed == [kAXPressAction as String])
        #expect(await cgEvent.executedOps.isEmpty)
        for channel in fallbacks {
            #expect(await channel.executedOps.isEmpty)
        }
        #expect(!result.isSuccess)
        let envelope = try #require(issue1059Object(result.message))
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["error"] as? String == "element_not_found")
        #expect(try #require(envelope["write_attempted"] as? Bool))
        #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
        #expect(try #require(envelope["fallback_unsafe"] as? Bool))
        #expect(envelope["record_clear_outcome"] as? String == "unconfirmed_after_write")
        #expect(envelope["record_clear_applied"] == nil)
        #expect(try #require(envelope["terminal"] as? Bool))
        #expect(!(try #require(envelope["human_intervention_required"] as? Bool)))
        #expect(envelope["human_intervention_requests"] as? Int == 0)
        #expect(envelope["human_dependent_transitions"] as? Int == 0)
    }

    @Test("Stop may use automatic fallback when Record was already clear")
    func stopNoOpRecordClearKeepsFallbackEligible() async {
        let bar = Issue1059Bar(description: "녹음", initial: false, readback: .staysAtInitial)
        let router = ChannelRouter()
        let cgEvent = MockChannel(id: .cgEvent, available: false)
        let mcu = MockChannel(id: .mcu)
        await router.register(cgEvent)
        await router.register(issue1059Channel(bar))
        await router.register(mcu)

        let result = await router.route(operation: "transport.stop", params: [:])

        #expect(bar.checkbox.performed.isEmpty)
        #expect(await cgEvent.executedOps.isEmpty)
        #expect((await mcu.executedOps).count == 1)
        #expect(result.isSuccess)
    }

    @Test("AXConfirm may follow an AXPress that reported no delivery")
    func undeliveredPressAllowsNextStrategy() async throws {
        let bar = Issue1059Bar(description: "재생", initial: false,
                               readback: .pressFailsThenConfirmChanges)
        let result = await issue1059Channel(bar).execute(operation: "transport.play", params: [:])

        #expect(bar.checkbox.performed == [kAXPressAction as String, kAXConfirmAction as String])
        #expect(result.isSuccess)
        let envelope = try #require(issue1059Object(result.message))
        #expect(envelope["state"] as? String == "A")
        #expect(envelope["attempts"] as? [String] == ["axpress:failed", "axconfirm"])
    }
}
