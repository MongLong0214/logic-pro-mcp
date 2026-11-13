@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Logic 13 project chooser shell readiness")
struct ProjectChooserShellReadinessTests {
    private final class WindowListBox: @unchecked Sendable {
        let value: [[String: Any]]?

        init(_ value: [[String: Any]]?) {
            self.value = value
        }
    }

    private let logicPID: pid_t = 4_242

    private func cgWindow(
        owner: pid_t = 4_242,
        number: Int = 1,
        layer: Int = 0,
        bounds: CGRect? = CGRect(x: 30, y: 40, width: 1_200, height: 760),
        name: String? = "Choose a Project"
    ) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: owner),
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowLayer as String: NSNumber(value: layer),
        ]
        if let bounds { row[kCGWindowBounds as String] = bounds.dictionaryRepresentation }
        if let name { row[kCGWindowName as String] = name }
        return row
    }

    private func fixture(
        title: String = "Choose a Project",
        document: String? = nil,
        axWindows: Bool = true,
        windowList: [[String: Any]]? = []
    ) -> (builder: FakeAXRuntimeBuilder, app: AXUIElement, window: AXUIElement,
          runtime: AXLogicProElements.Runtime) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1_565_000)
        let window = builder.element(1_565_001)
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(window, kAXTitleAttribute as String, title)
        if let document {
            builder.setAttribute(window, kAXDocumentAttribute as String, document)
        }
        builder.setChildren(window, [])
        if axWindows {
            builder.setAttribute(app, kAXWindowsAttribute as String, [window])
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setChildren(app, [window])
        } else {
            builder.setAttribute(app, kAXWindowsAttribute as String, [AXUIElement]())
            builder.setChildren(app, [])
        }
        let windowListBox = WindowListBox(windowList)
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { logicPID },
            ax: builder.makeAXRuntime(appElement: app),
            executeAppleScript: { _ in .error("read-only chooser observation cannot run scripts") },
            onScreenWindowList: { windowListBox.value },
            postPopupMenuEscape: { Issue.record("read-only chooser observation cannot type Escape") }
        )
        return (builder, app, window, runtime)
    }

    @Test("status-preserving AX observation accepts only exact localized chooser titles",
          arguments: ["Choose a Project", "프로젝트 선택"])
    func exactLocalizedAXChooserIsPositive(title: String) {
        let f = fixture(title: title)

        #expect(AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
        #expect(!AccessibilityChannel.exactEmptyProjectChooserIsVisible(runtime: f.runtime),
                "readiness must not weaken the mutation helper's label/button proof")
        #expect(AccessibilityChannel.documentWindowCount([f.window], runtime: f.runtime) == 0)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("an AX-bound document with the chooser title remains a document")
    func sameTitledDocumentIsNotAChooserShell() {
        let f = fixture(document: "file:///fixture/Choose%20a%20Project.logicx/")

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
        #expect(AccessibilityChannel.documentWindowCount([f.window], runtime: f.runtime) == 1)
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("a chooser-title near match is not an exact chooser shell")
    func chooserTitleNearMatchIsNotPositive() {
        let f = fixture(title: "Choose a Project - Tracks")

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
    }

    @Test("another AX window prevents a chooser shell verdict")
    func anotherAXWindowPreventsPositiveObservation() {
        let f = fixture()
        let document = f.builder.element(1_565_002)
        f.builder.setAttribute(document, kAXRoleAttribute as String, kAXWindowRole as String)
        f.builder.setAttribute(document, kAXTitleAttribute as String, "Existing - Tracks")
        f.builder.setAttribute(document, kAXDocumentAttribute as String, "file:///fixture/Existing.logicx/")
        f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, document])

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
    }

    @Test("empty AX window state can use one exact Logic-owned CG chooser")
    func emptyAXUsesExactCGFallback() {
        let f = fixture(axWindows: false, windowList: [cgWindow(name: "프로젝트 선택")])

        #expect(AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
        #expect(f.builder.setCalls.isEmpty)
        #expect(f.builder.actionCalls.isEmpty)
    }

    @Test("a popup helper does not compete with the sole normal chooser window")
    func popupHelperIsIgnored() {
        let f = fixture(
            axWindows: false,
            windowList: [
                cgWindow(name: "Choose a Project"),
                cgWindow(number: 2, layer: LogicOnScreenWindows.popupMenuLevel, name: nil),
            ]
        )

        #expect(AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
    }

    @Test("ambiguous or malformed CG chooser rows fail closed",
          arguments: ["wrong_owner", "wrong_layer", "zero_bounds", "nan_bounds", "missing_bounds",
                      "wrong_name", "missing_name", "second_named", "second_unnamed", "missing_layer",
                      "missing_number"])
    func invalidCGShapeIsNotPositive(shape: String) {
        var windows = [cgWindow()]
        switch shape {
        case "wrong_owner": windows = [cgWindow(owner: 9_999)]
        case "wrong_layer": windows = [cgWindow(layer: 3)]
        case "zero_bounds": windows = [cgWindow(bounds: CGRect(x: 0, y: 0, width: 0, height: 700))]
        case "nan_bounds": windows = [cgWindow(bounds: CGRect(x: CGFloat.nan, y: 0, width: 900, height: 700))]
        case "missing_bounds": windows = [cgWindow(bounds: nil)]
        case "wrong_name": windows = [cgWindow(name: "Existing - Tracks")]
        case "missing_name": windows = [cgWindow(name: nil)]
        case "second_named": windows.append(cgWindow(number: 2, name: "Mixer"))
        case "second_unnamed": windows.append(cgWindow(number: 2, name: nil))
        case "missing_layer": windows[0].removeValue(forKey: kCGWindowLayer as String)
        default: windows[0].removeValue(forKey: kCGWindowNumber as String)
        }
        let f = fixture(axWindows: false, windowList: windows)

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime),
                "shape=\(shape)")
    }

    @Test("an unreadable CG list is unknown, not an empty screen")
    func unreadableCGListIsNotPositive() {
        let f = fixture(axWindows: false, windowList: nil)
        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: f.runtime))
    }

    @Test("failed AXWindows reads cannot fall through to CG")
    func failedAXWindowsReadIsNotPositive() {
        let f = fixture(axWindows: false, windowList: [cgWindow()])
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { logicPID },
            ax: f.builder.makeAXRuntime(
                appElement: f.app,
                attributeValueResultHandler: { element, attribute in
                    if CFEqual(element, f.app), attribute == (kAXWindowsAttribute as String) {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            ),
            executeAppleScript: { _ in .error("unexpected script") },
            onScreenWindowList: { [cgWindow()] },
            postPopupMenuEscape: { Issue.record("unexpected Escape") }
        )

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: runtime))
    }

    @Test("failed AXMainWindow reads cannot fall through to CG")
    func failedAXMainWindowReadIsNotPositive() {
        let f = fixture(axWindows: false, windowList: [cgWindow()])
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { logicPID },
            ax: f.builder.makeAXRuntime(
                appElement: f.app,
                attributeValueResultHandler: { element, attribute in
                    if CFEqual(element, f.app), attribute == (kAXMainWindowAttribute as String) {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            ),
            executeAppleScript: { _ in .error("unexpected script") },
            onScreenWindowList: { [cgWindow()] },
            postPopupMenuEscape: { Issue.record("unexpected Escape") }
        )

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: runtime))
    }

    @Test("only a successful empty AXWindows value enables the CG fallback",
          arguments: ["absent", "malformed", "main_window_present"])
    func cgFallbackRequiresStatusPreservingAXEmpty(shape: String) {
        let f = fixture(axWindows: false, windowList: [cgWindow()])
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { logicPID },
            ax: f.builder.makeAXRuntime(
                appElement: f.app,
                attributeValueResultHandler: { element, attribute in
                    guard CFEqual(element, f.app) else { return nil }
                    if attribute == (kAXWindowsAttribute as String) {
                        switch shape {
                        case "absent": return .success(nil)
                        case "malformed": return .success("not an AX array" as NSString)
                        default: return nil
                        }
                    }
                    if shape == "main_window_present",
                       attribute == (kAXMainWindowAttribute as String) {
                        return .success(f.window)
                    }
                    return nil
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            ),
            executeAppleScript: { _ in .error("unexpected script") },
            onScreenWindowList: { [cgWindow()] },
            postPopupMenuEscape: { Issue.record("unexpected Escape") }
        )

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: runtime))
    }

    @Test("malformed AX title and document values fail closed",
          arguments: ["title", "document"])
    func malformedAXChooserValueIsNotPositive(attribute: String) {
        let f = fixture()
        let runtime = AXLogicProElements.Runtime(
            logicProPID: { logicPID },
            ax: f.builder.makeAXRuntime(
                appElement: f.app,
                attributeValueResultHandler: { element, name in
                    if CFEqual(element, f.window),
                       name == (attribute == "title"
                           ? kAXTitleAttribute as String
                           : kAXDocumentAttribute as String) {
                        return .success(NSNumber(value: 13))
                    }
                    return nil
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            ),
            executeAppleScript: { _ in .error("unexpected script") },
            onScreenWindowList: { [] },
            postPopupMenuEscape: { Issue.record("unexpected Escape") }
        )

        #expect(!AccessibilityChannel.projectChooserShellIsPositivelyObserved(runtime: runtime))
    }
}
