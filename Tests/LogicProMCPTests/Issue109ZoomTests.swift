import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #109: set_zoom now drives the writable Horizontal-Zoom AXSlider with a
/// read-back instead of an unmappable, unverifiable key command. The other
/// edit/nav key-command surfaces (undo/copy/… honest State B; select_all/
/// quantize/zoom_to_fit fail-loud) are unchanged and remain covered by
/// existing dispatcher tests.
@Suite("Issue109 zoom readback")
struct Issue109ZoomTests {
    private func zoomFixture(start: Double) -> (builder: FakeAXRuntimeBuilder, app: AXUIElement, slider: AXUIElement) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(7700)
        let window = b.element(7701)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        let slider = b.element(7702)
        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, "Horizontal Zoom")
        b.setAttribute(slider, kAXValueAttribute as String, start)
        b.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
        b.setAttribute(slider, kAXMaxValueAttribute as String, 1.0)
        b.setChildren(window, [slider])
        return (b, app, slider)
    }

    private func obj(_ r: ChannelResult) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(r.message.utf8))) as? [String: Any]
    }

    @Test("set_zoom_level writes the horizontal zoom slider and verifies (State A)")
    func zoomVerifies() {
        let f = zoomFixture(start: 0.18)
        let result = AccessibilityChannel.defaultSetZoomLevel(
            params: ["level": "8"], runtime: f.builder.makeLogicRuntime(appElement: f.app)
        )
        #expect(result.isSuccess)
        let o = obj(result)
        #expect((o?["verified"] as? Bool)!)
        #expect(o?["verify_source"] as? String == "ax_zoom_slider")
        // level 8 → (8-1)/9 = 0.777…
        #expect(abs((o?["observed"] as? Double ?? -9) - (7.0 / 9.0)) < 0.02)
        // The slider's stored AX value actually moved.
        let stored = (f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue
            ?? (f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? Double)
        #expect(abs((stored ?? -9) - (7.0 / 9.0)) < 0.001)
    }

    @Test("set_zoom_level maps level 1 to fully out and 10 to fully in")
    func zoomLevelMapping() {
        for (level, expected) in [(1, 0.0), (10, 1.0), (5, 4.0 / 9.0)] {
            let f = zoomFixture(start: 0.5)
            let result = AccessibilityChannel.defaultSetZoomLevel(
                params: ["level": String(level)], runtime: f.builder.makeLogicRuntime(appElement: f.app)
            )
            #expect(abs((obj(result)?["observed"] as? Double ?? -9) - expected) < 0.02, "level \(level) → \(expected)")
        }
    }

    @Test("set_zoom_level falls back (non-terminal plain error) when no slider exists")
    func zoomFallsBackWhenNoSlider() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(7800)
        let window = b.element(7801)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        b.setChildren(window, []) // no zoom slider
        let result = AccessibilityChannel.defaultSetZoomLevel(
            params: ["level": "8"], runtime: b.makeLogicRuntime(appElement: app)
        )
        #expect(!result.isSuccess)
        // Plain (non-HC) error → non-terminal → the router falls back to keycmd.
        #expect(!HonestContract.isTerminalStateC(result.message))
    }

    @Test("set_zoom is AX-first with key-command fallback in the router")
    func routingIsAXFirst() {
        let chain = ChannelRouter.routingTable["nav.set_zoom_level"]
        #expect(chain?.first == .accessibility)
        #expect((chain?.contains(.midiKeyCommands))!)
    }

    @Test(
        "set_zoom_level rejects malformed level with TERMINAL State C invalid_params",
        arguments: [
            ["level": "0"],     // below range
            ["level": "11"],    // above range
            ["level": "-1"],    // negative
            ["level": "abc"],   // non-numeric
            ["level": ""],      // empty
            [:],                // missing entirely
        ]
    )
    func zoomInvalidParamsAreTerminal(params: [String: String]) throws {
        let f = zoomFixture(start: 0.5)
        let result = AccessibilityChannel.defaultSetZoomLevel(
            params: params, runtime: f.builder.makeLogicRuntime(appElement: f.app)
        )
        #expect(!result.isSuccess)
        let o = try #require(obj(result))
        #expect(!((o["success"] as? Bool)!))
        #expect(o["error"] as? String == "invalid_params")
        // Terminal → the router MUST suppress fallback to the key-command
        // channel (which doesn't validate and would fire a generic zoom).
        #expect(HonestContract.isTerminalStateC(result.message))
        // Guard must fire before any slider write: the fixture slider is untouched.
        let stored = (f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue
            ?? (f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? Double)
        #expect(abs((stored ?? -9) - 0.5) < 0.001)
    }
}
