@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// A marker operation that opens Logic's Marker List closes it again and puts the focus back.
/// Measured on Logic 13: after create_marker the Marker List window stayed open and the key view
/// was an AXTable inside it, so the next operation read focus_moved.
@Suite(.serialized) struct MarkerListRestorationTests {
    private final class Screen: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let arrange: AXUIElement
        let list: AXUIElement
        let close: AXUIElement
        let strip: AXUIElement
        let listTable: AXUIElement
        /// A second project, for the user switching to it while an operation holds the list.
        let otherArrange: AXUIElement
        let otherList: AXUIElement
        let otherClose: AXUIElement
        let otherStrip: AXUIElement
        let lock = NSLock()
        var closePressable = true
        var focusWritable = true
        var presses = 0
        var otherPresses = 0
        /// The app's AXWindows read fails (the census is unavailable), as an AX status, not as [].
        var windowsUnreadable = false
        /// After the close is pressed, the census can no longer be read.
        var windowsUnreadableAfterPress = false
        /// The app's focused-window and focused-element reads fail.
        var focusUnreadable = false
        /// The main window's AXDocument read fails.
        var mainDocumentUnreadable = false

        init(listOpen: Bool) {
            app = builder.element(1)
            arrange = builder.element(2)
            list = builder.element(3)
            close = builder.element(4)
            strip = builder.element(5)
            listTable = builder.element(6)
            otherArrange = builder.element(7)
            otherList = builder.element(8)
            otherClose = builder.element(9)
            otherStrip = builder.element(10)
            builder.setAttribute(otherArrange, kAXTitleAttribute as String, "Q.logicx - 트랙")
            builder.setAttribute(otherArrange, kAXDocumentAttribute as String, "/Q.logicx")
            builder.setAttribute(otherList, kAXTitleAttribute as String, "Q.logicx - 마커 목록")
            builder.setAttribute(otherList, kAXDocumentAttribute as String, "/Q.logicx")
            builder.setAttribute(otherList, kAXCloseButtonAttribute as String, otherClose)
            builder.setAttribute(otherClose, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(otherStrip, kAXWindowAttribute as String, otherArrange)
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
        /// `between` runs after the list appears and before the opener registers it: the window in
        /// which the opener awaits the menu action and the user can still act.
        func openList(
            _ ledgerRuntime: AXLogicProElements.Runtime,
            record: Bool = true,
            between: () -> Void = {}
        ) {
            // The opener reads the screen it found, then records the exact list window it saw
            // appear and that window's project, as `defaultOpenMarkerList` does.
            let origin = record
                ? AccessibilityChannel.markerListOrigin(runtime: ledgerRuntime, listWasOpen: false) : nil
            builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, list])
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, list)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, listTable)
            between()
            if let origin, let binding = AXLogicProElements.markerListBinding(runtime: ledgerRuntime) {
                AccessibilityChannel.recordOpenedMarkerList(origin, opened: binding)
            }
        }

        /// The user switches to another open project and opens ITS Marker List.
        func switchToOtherProject() {
            setWindows(windows + [otherArrange, otherList])
            builder.setAttribute(app, kAXMainWindowAttribute as String, otherArrange)
            builder.setAttribute(app, kAXFocusedWindowAttribute as String, otherArrange)
            builder.setAttribute(app, kAXFocusedUIElementAttribute as String, otherStrip)
        }

        var windows: [AXUIElement] {
            builder.attributeValue(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        }

        func setWindows(_ value: [AXUIElement]) {
            builder.setAttribute(app, kAXWindowsAttribute as String, value)
        }

        var windowCount: Int {
            (builder.makeAXRuntime().attributeValue(app, kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? -1
        }

        var focusedElement: AXUIElement? {
            builder.makeAXRuntime().attributeValue(app, kAXFocusedUIElementAttribute as String) as! AXUIElement?
        }

        /// Whether a read of `attribute` on `element` fails with an AX status right now.
        private func readFails(_ element: AXUIElement, _ attribute: String) -> Bool {
            if mainDocumentUnreadable, CFEqual(element, arrange), attribute == kAXDocumentAttribute as String {
                return true
            }
            guard CFEqual(element, app) else { return false }
            if attribute == kAXWindowsAttribute as String { return windowsUnreadable }
            if attribute == kAXFocusedWindowAttribute as String
                || attribute == kAXFocusedUIElementAttribute as String { return focusUnreadable }
            return false
        }

        var runtime: AXLogicProElements.Runtime {
            builder.makeLogicRuntime(
                appElement: app,
                attributeValueHandler: { [self] element, attribute in
                    readFails(element, attribute) ? .some(nil) : nil
                },
                attributeValueResultHandler: { [self] element, attribute in
                    readFails(element, attribute)
                        ? .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)) : nil
                },
                setAttributeHandler: { [self] element, attribute, value in
                    guard attribute == kAXFocusedAttribute as String, focusWritable else { return false }
                    let owner = CFEqual(element, strip) ? arrange
                        : CFEqual(element, otherStrip) ? otherArrange : list
                    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, element)
                    builder.setAttribute(app, kAXFocusedWindowAttribute as String, owner)
                    return true
                },
                performActionHandler: { [self] element, action in
                    guard action == kAXPressAction as String else { return false }
                    if CFEqual(element, otherClose) {
                        otherPresses += 1
                        setWindows(windows.filter { !CFEqual($0, otherList) })
                        return true
                    }
                    guard CFEqual(element, close) else { return false }
                    presses += 1
                    if closePressable { setWindows(windows.filter { !CFEqual($0, list) }) }
                    if windowsUnreadableAfterPress { windowsUnreadable = true }
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

    @Test func anEntryThatMovedFocusIsFollowedByARestoreAndTheReReadDecides() {
        let screen = Screen(listOpen: false)
        let runtime = screen.runtime
        let result = AccessibilityChannel.withFocusRestored(runtime: runtime) {
            screen.openList(runtime, record: false)
            return .success(#"{"success":true}"#)
        }
        let restored = Self.body(result)["focus_restored"] as? Bool ?? false
        #expect(restored, "\(Self.body(result))")
        let focusBack = screen.focusedElement.map { CFEqual($0, screen.strip) } ?? false
        #expect(focusBack)
    }

    @Test func anEntryWhoseFocusCannotBeRestoredSaysSo() {
        let screen = Screen(listOpen: false)
        screen.focusWritable = false
        let runtime = screen.runtime
        let result = AccessibilityChannel.withFocusRestored(runtime: runtime) {
            screen.openList(runtime, record: false)
            return .success(#"{"success":true}"#)
        }
        let restored = Self.body(result)["focus_restored"] as? Bool ?? true
        #expect(!restored, "\(Self.body(result))")
    }

    // MARK: - Ownership and observation

    /// The user moves to another project and opens ITS Marker List while this operation holds its
    /// own. Cleanup closes only the window it opened, never the other project's, and does not pull
    /// the focus back to a project the user has left.
    @Test func anotherProjectsMarkerListIsNeverClosedAndItsFocusIsNotTaken() async {
        let screen = Screen(listOpen: false)
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            screen.switchToOtherProject()
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        #expect(screen.otherPresses == 0, "the other project's list was pressed closed: \(body)")
        #expect(screen.windows.contains { CFEqual($0, screen.otherList) }, "\(body)")
        #expect(!screen.windows.contains { CFEqual($0, screen.list) }, "the list this operation opened is closed")
        let focusStayed = screen.focusedElement.map { CFEqual($0, screen.otherStrip) } ?? false
        #expect(focusStayed, "focus was pulled back to the project the user left: \(body)")
        let restoredReported = body["ui_restored"] as? Bool ?? true
        #expect(!restoredReported, "\(body)")
    }

    /// A window census that cannot be read proves nothing about the list: it is not "closed".
    @Test func aCensusThatCannotBeReadNeverReportsTheListClosed() async {
        let screen = Screen(listOpen: false)
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            screen.windowsUnreadable = true
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        let closedReported = body["marker_list_closed"] as? Bool ?? true
        #expect(!closedReported, "\(body)")
        let restoredReported = body["ui_restored"] as? Bool ?? true
        #expect(!restoredReported, "\(body)")
    }

    /// The close was pressed, and the census then failed. The list may still be open.
    @Test func aCensusThatFailsAfterTheCloseIsPressedLeavesClosureUnverified() async {
        let screen = Screen(listOpen: false)
        screen.closePressable = false
        screen.windowsUnreadableAfterPress = true
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        #expect(screen.presses == 1, "\(body)")
        let closedReported = body["marker_list_closed"] as? Bool ?? true
        #expect(!closedReported, "\(body)")
        let restoredReported = body["ui_restored"] as? Bool ?? true
        #expect(!restoredReported, "\(body)")
    }

    /// Two failed focus reads are not two equal focus readings.
    @Test func focusThatCannotBeReadIsNotReportedRestored() async {
        let screen = Screen(listOpen: false)
        screen.focusUnreadable = true
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime)
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        let restoredReported = body["ui_restored"] as? Bool ?? true
        #expect(!restoredReported, "\(body)")
    }

    /// The tempo entry shares the focus restoration: unreadable focus is not restored focus.
    @Test func aTypedEntryWhoseFocusCannotBeReadIsNotReportedRestored() {
        let screen = Screen(listOpen: false)
        screen.focusUnreadable = true
        let runtime = screen.runtime
        let result = AccessibilityChannel.withFocusRestored(runtime: runtime) {
            screen.openList(runtime, record: false)
            return .success(#"{"success":true}"#)
        }
        let restored = Self.body(result)["focus_restored"] as? Bool ?? true
        #expect(!restored, "\(Self.body(result))")
    }

    /// The user switches to another project and opens ITS list while the opener is still awaiting
    /// the menu action, so the binding read at registration is the other project's list. That
    /// list is never adopted: it is not closed, and focus is not pulled back from it.
    @Test func aListFromAProjectSwitchedToBeforeRegistrationIsNeverAdopted() async {
        let screen = Screen(listOpen: false)
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime, between: { screen.switchToOtherProject() })
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        #expect(screen.otherPresses == 0, "the other project's list was pressed closed: \(body)")
        #expect(screen.windows.contains { CFEqual($0, screen.otherList) }, "\(body)")
        let focusStayed = screen.focusedElement.map { CFEqual($0, screen.otherStrip) } ?? false
        #expect(focusStayed, "focus was pulled back to the project the user left: \(body)")
        #expect(body["marker_list_closed"] == nil, "nothing is claimed for a list never owned: \(body)")
    }

    /// The origin project could not be read before the open, so no list that appears can be shown
    /// to be this operation's: none is adopted or closed.
    @Test func anOriginProjectThatCannotBeReadAdoptsNothing() async {
        let screen = Screen(listOpen: false)
        screen.mainDocumentUnreadable = true
        let runtime = screen.runtime
        let result = await AccessibilityChannel.withMarkerListRestored(runtime: runtime) {
            screen.openList(runtime, between: { screen.mainDocumentUnreadable = false })
            return .success(#"{"success":true}"#)
        }
        let body = Self.body(result)
        #expect(screen.presses == 0, "a list with no proven origin project was closed: \(body)")
        #expect(body["marker_list_closed"] == nil, "\(body)")
    }
}
