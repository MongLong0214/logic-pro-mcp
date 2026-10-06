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
    private func zoomFixture(start: Double, description: String = "Horizontal Zoom") -> (builder: FakeAXRuntimeBuilder, app: AXUIElement, slider: AXUIElement) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(7700)
        let window = b.element(7701)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        let slider = b.element(7702)
        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, description)
        b.setAttribute(slider, kAXValueAttribute as String, start)
        b.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
        b.setAttribute(slider, kAXMaxValueAttribute as String, 1.0)
        b.setChildren(window, [slider])
        return (b, app, slider)
    }

    private func obj(_ r: ChannelResult) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(r.message.utf8))) as? [String: Any]
    }

    // #904: fixed values read from the installed Logic 12.3 (6674)
    // Logic.framework/Resources/Localizable.strings key `Horizontal Zoom`.
    // These are independent test inputs, not the policy's current label list.
    // The en/ko/ja/de Arrange AXSlider descriptions are corroborated by the
    // archived 2026-09-05 and 2026-09-12 navigation-free censuses. The other
    // six inputs are corpus-derived synthetic controls, NOT native readings.
    // ControllerAssignments.strings aGM-qO-ZOT.title has equivalent values;
    // these tests do not establish which key the actual slider calls.
    private static let horizontalZoomRows: [(String, String)] = [
        ("en", "Horizontal Zoom"),
        ("ko", "수평 확대/축소"),
        ("ja", "横方向にズーム"),
        ("de", "Horizontal-Zoom"),
        ("es", "Zoom horizontal"),
        ("fr", "Zoom horizontal"),
        ("it", "Zoom orizzontale"),
        ("pt", "Zoom horizontal"),
        ("zh_CN", "水平缩放"),
        ("zh_TW", "水平縮放"),
    ]

    private static let verticalZoomRows: [(String, String)] = [
        ("en", "Vertical Zoom"),
        ("ko", "수직 확대/축소"),
        ("ja", "縦方向にズーム"),
        ("de", "Vertikal-Zoom"),
        ("es", "Zoom vertical"),
        ("fr", "Zoom vertical"),
        ("it", "Zoom verticale"),
        ("pt", "Zoom vertical"),
        ("zh_CN", "垂直缩放"),
        ("zh_TW", "垂直縮放"),
    ]

    private func expectZoomWrite(description: String) throws {
        let f = zoomFixture(start: 0.18, description: description)
        let result = AccessibilityChannel.defaultSetZoomLevel(
            params: ["level": "8"], runtime: f.builder.makeLogicRuntime(appElement: f.app)
        )
        let target = 7.0 / 9.0
        // Independent actuator evidence: the same physical fixture element is
        // written exactly once, and its stored AXValue actually changes.
        #expect(f.builder.setCalls.count == 1)
        #expect(f.builder.setCalls.allSatisfy {
            $0.elementID == f.builder.elementID(f.slider) && $0.attribute == (kAXValueAttribute as String)
        })
        let stored = try #require((f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue)
        #expect(abs(stored - target) < 0.001)
        #expect(result.isSuccess)
        let payload = try #require(obj(result))
        let verified = try #require(payload["verified"] as? Bool)
        #expect(verified)
        #expect(payload["verify_source"] as? String == "ax_zoom_slider")
        let observed = try #require(payload["observed"] as? Double)
        #expect(abs(observed - stored) < 0.001)
    }

    @Test("#904 horizontal zoom locator returns the supplied row's actual slider", arguments: horizontalZoomRows)
    func zoomLocatorFindsOwnCorpusRow(locale: String, description: String) throws {
        let f = zoomFixture(start: 0.18, description: description)
        let located = try #require(AXLogicProElements.findHorizontalZoomSlider(
            runtime: f.builder.makeLogicRuntime(appElement: f.app)
        ), "locale=\(locale)")
        #expect(CFEqual(located, f.slider))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("#904 each own-row zoom value reaches the real setter and independent readback", arguments: horizontalZoomRows)
    func zoomWritesOwnCorpusRow(locale: String, description: String) throws {
        try expectZoomWrite(description: description)
    }

    @Test("#904 the two pre-existing Korean tolerance spellings still write", arguments: ["가로 확대/축소", "가로 확대"])
    func zoomPreservesLegacyKoreanTolerance(description: String) throws {
        // Historical tolerance only: neither string is asserted to be the
        // installed row or a newly qualified native observation.
        try expectZoomWrite(description: description)
    }

    @Test("#904 a matching description on the wrong role cannot receive a zoom write")
    func zoomRejectsWrongRoleWithoutWriting() throws {
        let f = zoomFixture(start: 0.18)
        f.builder.setAttribute(f.slider, kAXRoleAttribute as String, kAXButtonRole as String)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(AXLogicProElements.findHorizontalZoomSlider(runtime: runtime) == nil)
        let result = AccessibilityChannel.defaultSetZoomLevel(params: ["level": "8"], runtime: runtime)
        #expect(!result.isSuccess)
        #expect(!HonestContract.isTerminalStateC(result.message))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
        let stored = try #require((f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue)
        #expect(abs(stored - 0.18) < 0.001)
    }

    @Test("#904 vertical zoom is not a horizontal zoom target in any row locale", arguments: verticalZoomRows)
    func zoomRejectsVerticalDescriptionWithoutWriting(locale: String, description: String) throws {
        let f = zoomFixture(start: 0.18, description: description)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        #expect(AXLogicProElements.findHorizontalZoomSlider(runtime: runtime) == nil, "locale=\(locale)")
        let result = AccessibilityChannel.defaultSetZoomLevel(params: ["level": "8"], runtime: runtime)
        #expect(!result.isSuccess)
        #expect(!HonestContract.isTerminalStateC(result.message))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
        let stored = try #require((f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue)
        #expect(abs(stored - 0.18) < 0.001)
    }

    @Test("#904 a detached slider is not written when the window has no slider")
    func zoomRejectsMissingSliderWithoutWriting() throws {
        let f = zoomFixture(start: 0.18)
        let runtime = f.builder.makeLogicRuntime(appElement: f.app)
        let observedWindow: AXUIElement? = AXHelpers.getAttribute(f.app, kAXMainWindowAttribute, runtime: runtime.ax)
        let window = try #require(observedWindow)
        f.builder.setChildren(window, [])
        #expect(AXLogicProElements.findHorizontalZoomSlider(runtime: runtime) == nil)
        let result = AccessibilityChannel.defaultSetZoomLevel(params: ["level": "8"], runtime: runtime)
        #expect(!result.isSuccess)
        #expect(!HonestContract.isTerminalStateC(result.message))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
        let stored = try #require((f.builder.attributeValue(f.slider, kAXValueAttribute as String) as? NSNumber)?.doubleValue)
        #expect(abs(stored - 0.18) < 0.001)
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
