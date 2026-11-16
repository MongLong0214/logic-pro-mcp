@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// A marker operation that opens Logic's Marker List closes it again and puts the focus back.
/// Measured on Logic 13: after create_marker the Marker List window stayed open and the key view
/// was an AXTable inside it, so the next operation read focus_moved.
@Suite struct MarkerListRestorationTests {
    private final class Screen: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let arrange: AXUIElement
        let list: AXUIElement
        let close: AXUIElement
        let strip: AXUIElement
        let listTable: AXUIElement
        let lock = NSLock()
        var closePressable = true
        var focusWritable = true
        var presses = 0

        init(listOpen: Bool) {
            app = builder.element(1)
            arrange = builder.element(2)
            list = builder.element(3)
            close = builder.element(4)
            strip = builder.element(5)
            listTable = builder.element(6)
            builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
            builder.setAttribute(arrange, kAXTitleAttribute as String, "P.logicx - 트랙")
            builder.setAttribute(arrange, kAXDocumentAttribute as String, "/P.logicx")
            builder.setAttribute(list, kAXTitleAttribute as String, "P.logicx - 마커 목록")
            builder.setAttribute(list, kAXDocumentAttribute as String, "/P.logicx")
            builder.setAttribute(list, kAXCloseButtonAttribute as String, close)
            builder.setAttribute(close, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(strip, kAXWindowAttribute as String, arrange)
            builder.setAttribute(listTable, kAXWindowAttribute as String, list)
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, arrange)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, strip)
            builder.setAttribute(app, kAXWindowsAttribute as String, listOpen ? [arrange, list] : [arrange])
        }

        /// What the operation does to the screen: open the list and move the key view into it.
        func openList(_ ledgerRuntime: AXLogicProElements.Runtime) {
            // The opener records the screen it found, exactly as `defaultOpenMarkerList` does.
            if let origin = AccessibilityChannel.markerListOrigin(runtime: ledgerRuntime, listWasOpen: false) {
                AccessibilityChannel.recordOpenedMarkerList(origin)
            }
            builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, list])
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, list)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, listTable)
        }

        var windowCount: Int {
            (builder.makeAXRuntime().attributeValue(app, kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? -1
        }

        var focusedElement: AXUIElement? {
            builder.makeAXRuntime().attributeValue(app, kAXFocusedUIElementAttribute as String) as! AXUIElement?
        }

        var runtime: AXLogicProElements.Runtime {
            builder.makeLogicRuntime(
                appElement: app,
                setAttributeHandler: { [self] element, attribute, value in
                    guard attribute == kAXFocusedAttribute as String, focusWritable else { return false }
                    let owner = CFEqual(element, strip) ? arrange : list
                    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, element)
                    builder.setAttribute(app, kAXFocusedWindowAttribute as String, owner)
                    return true
                },
                performActionHandler: { [self] element, action in
                    guard CFEqual(element, close), action == kAXPressAction as String else { return false }
                    presses += 1
                    if closePressable { builder.setAttribute(app, kAXWindowsAttribute as String, [arrange]) }
                    return true
                })
        }
    }

    private static func body(_ result: ChannelResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aListTheOperationOpenedIsClosedAndFocusReturns() async {
        let screen = Screen(listOpen: false)
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        let closedReported = body["marker_list_closed"] as? Bool ?? false
        #expect(closedReported, "\(body)")
        let restoredReported = body["ui_restored"] as? Bool ?? false
        #expect(restoredReported, "\(body)")
        #expect(screen.windowCount == 1)
        let focusBack = screen.focusedElement.map { CFEqual($0, screen.strip) } ?? false
        #expect(focusBack)
        #expect(result.isSuccess)
    }

    @Test func aListTheUserAlreadyHadOpenIsLeftAlone() async {
        let screen = Screen(listOpen: true)
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            .success(#"{"success":true}"#)
        }
        #expect(screen.presses == 0)
        #expect(screen.windowCount == 2)
        #expect(Self.body(result)["marker_list_closed"] == nil)
    }

    @Test func aListThatWillNotCloseIsReportedAsStillOpen() async {
        let screen = Screen(listOpen: false)
        screen.closePressable = false
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        let closedReported = body["marker_list_closed"] as? Bool ?? true
        #expect(!closedReported, "\(body)")
        let restoredReported = body["ui_restored"] as? Bool ?? true
        #expect(!restoredReported, "\(body)")
        #expect(body["ui_restore_reason"] as? String == "the Marker List window did not close", "\(body)")
    }

    @Test func focusThatCannotBeRestoredIsReportedNotClaimed() async {
        let screen = Screen(listOpen: false)
        screen.focusWritable = false
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        let closedReported = body["marker_list_closed"] as? Bool ?? false
        #expect(closedReported, "\(body)")
        let restoredReported = body["ui_restored"] as? Bool ?? true
        #expect(!restoredReported, "\(body)")
    }

    @Test func aFailedOperationStillClosesWhatItOpened() async {
        let screen = Screen(listOpen: false)
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            return .error(#"{"success":false}"#)
        }
        #expect(!result.isSuccess)
        #expect(screen.windowCount == 1)
    }
}
