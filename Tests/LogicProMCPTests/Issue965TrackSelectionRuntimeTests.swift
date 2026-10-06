@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// Synthetic application handles above one million cannot identify the operator's Logic process.
/// The fixture records the EXISTING selection ladder, including its settable permission read.
private final class TrackSelectionRuntimeFixture: @unchecked Sendable {
    let builder: FakeAXRuntimeBuilder
    let app: AXUIElement
    let rail: AXUIElement
    let header: AXUIElement
    let acceptsChildren: Bool
    let selectedSettable: Bool?
    let acceptsSelected: Bool
    let acceptsHeaderPress: Bool
    private(set) var events: [String] = []

    init(
        acceptsChildren: Bool,
        selectedSettable: Bool?,
        acceptsSelected: Bool,
        acceptsHeaderPress: Bool
    ) {
        let b = FakeAXRuntimeBuilder()
        builder = b
        app = b.element(1_965_400)
        let window = b.element(1_965_401)
        rail = b.element(1_965_402)
        header = b.element(1_965_403)
        self.acceptsChildren = acceptsChildren
        self.selectedSettable = selectedSettable
        self.acceptsSelected = acceptsSelected
        self.acceptsHeaderPress = acceptsHeaderPress
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(rail, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(rail, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setChildren(header, [])
        b.setChildren(rail, [header])
        b.setChildren(window, [rail])
        b.setChildren(app, [window])
        b.setAttribute(app, kAXWindowsAttribute as String, [window])
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
    }

    var runtime: AXLogicProElements.Runtime {
        let base = builder.makeAXRuntime(appElement: app)
        let ax = AXHelpers.Runtime(
            axApp: base.axApp,
            attributeValue: base.attributeValue,
            attributeIsSettable: { [self] element, attribute in
                guard CFEqual(element, header), attribute == kAXSelectedAttribute as String else {
                    Issue.record("Unexpected settable-permission read")
                    return nil
                }
                events.append("read_selected_settable")
                return selectedSettable
            },
            setAttributeValue: { [self] element, attribute, value in
                if CFEqual(element, rail), attribute == kAXSelectedChildrenAttribute as String {
                    events.append("set_selected_children")
                    guard let children = value as? [AXUIElement], children.count == 1,
                          CFEqual(children[0], header) else {
                        Issue.record("AXSelectedChildren must contain the exact requested header")
                        return false
                    }
                    return acceptsChildren
                }
                if CFEqual(element, header), attribute == kAXSelectedAttribute as String {
                    events.append("set_selected")
                    guard let selected = value as? NSNumber, selected.boolValue else {
                        Issue.record("AXSelected must request true on the exact requested header")
                        return false
                    }
                    return acceptsSelected
                }
                Issue.record("Unexpected selection setter")
                return false
            },
            children: base.children,
            performAction: { [self] element, action in
                guard CFEqual(element, header), action == kAXPressAction as String else {
                    Issue.record("Unexpected selection action")
                    return false
                }
                events.append("press_header")
                return acceptsHeaderPress
            },
            childCount: base.childCount,
            actionNames: base.actionNames,
            actionNamesResult: base.actionNamesResult,
            childrenResult: base.childrenResult,
            attributeValueResult: base.attributeValueResult
        )
        return AXLogicProElements.Runtime(
            logicProPID: { 1_966_400 }, ax: ax,
            executeAppleScript: { _ in Issue.record("Unexpected selection AppleScript"); return .error("No script") },
            onScreenWindowList: { [] },
            postPopupMenuEscape: { Issue.record("Unexpected selection Escape") },
            focusedApplicationPID: { 1_966_400 }
        )
    }
}

@Suite("#965 selection ladder honors the injected AX runtime")
struct Issue965TrackSelectionRuntimeTests {
    @Test func acceptedSelectedChildrenStopsBeforePermissionReadOrPress() {
        let f = TrackSelectionRuntimeFixture(
            acceptsChildren: true, selectedSettable: true,
            acceptsSelected: true, acceptsHeaderPress: true
        )
        let selected = AXLogicProElements.selectTrackViaAX(at: 0, runtime: f.runtime)
        #expect(selected)
        #expect(f.events == ["set_selected_children"])
    }

    @Test func declinedChildrenThenSettableSelectedStopsBeforePress() {
        let f = TrackSelectionRuntimeFixture(
            acceptsChildren: false, selectedSettable: true,
            acceptsSelected: true, acceptsHeaderPress: true
        )
        let selected = AXLogicProElements.selectTrackViaAX(at: 0, runtime: f.runtime)
        #expect(selected)
        #expect(f.events == ["set_selected_children", "read_selected_settable", "set_selected"])
    }

    @Test(arguments: [false, true])
    func declinedSettersReachTheExistingHeaderPress(_ isSettable: Bool) {
        let f = TrackSelectionRuntimeFixture(
            acceptsChildren: false, selectedSettable: isSettable,
            acceptsSelected: false, acceptsHeaderPress: true
        )
        let selected = AXLogicProElements.selectTrackViaAX(at: 0, runtime: f.runtime)
        #expect(selected)
        let expected = ["set_selected_children", "read_selected_settable"]
            + (isSettable ? ["set_selected"] : []) + ["press_header"]
        #expect(f.events == expected)
    }

    @Test func unreadSettablePermissionNeverAuthorizesSelectedSetter() {
        let f = TrackSelectionRuntimeFixture(
            acceptsChildren: false, selectedSettable: nil,
            acceptsSelected: true, acceptsHeaderPress: false
        )
        let selected = AXLogicProElements.selectTrackViaAX(at: 0, runtime: f.runtime)
        #expect(!selected)
        #expect(f.events == ["set_selected_children", "read_selected_settable", "press_header"])
    }
}
