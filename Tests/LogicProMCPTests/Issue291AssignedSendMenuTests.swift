@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#291 assigned-send owned checked-menu acquisition", .serialized)
struct Issue291AssignedSendMenuTests {
    private final class FinalFocusRevocation: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var values = 0
        private var fired = false
        func arm() { lock.withLock { armed = true } }
        func valueRead() { lock.withLock { if armed { values += 1 } } }
        func take() -> Bool {
            lock.withLock {
                guard armed, values >= 2, !fired else { return false }
                fired = true; return true
            }
        }
    }
    struct Prepared {
        let f: Issue291PhysicalStripReferenceTests.Fixture
        let anchor: AXUIElement
        let group: AXUIElement
        let bypass: AXUIElement
        let knob: AXUIElement
        let checkedEcho: AXUIElement
        let checkedLeaf: AXUIElement
    }
    private func prepare() throws -> Prepared {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let anchor = f.b.element(291_900), group = f.b.element(291_901)
        let bypass = f.b.element(291_902), knob = f.b.element(291_903)
        f.b.setButton(anchor, description: "send button", help: "Send slot. Route signal.", x: 0, y: 0, width: 1, height: 1)
        f.b.setChildren(anchor, [])
        f.b.setRole(group, kAXGroupRole as String)
        // A deliberately misleading display cannot supply the typed destination.
        f.b.setAttribute(group, kAXDescriptionAttribute as String, "Bus 256")
        f.b.setRole(bypass, kAXCheckBoxRole as String)
        f.b.setAttribute(bypass, kAXValueAttribute as String, 0)
        f.b.setChildren(bypass, [])
        f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "list")
        f.b.removeAttribute(f.outputs[0], kAXHelpAttribute as String)
        f.b.setActionNames(f.outputs[0], [kAXPressAction as String])
        f.b.setChildren(group, [bypass, f.outputs[0]])
        f.b.setRole(knob, kAXSliderRole as String)
        f.b.setAttribute(knob, kAXHelpAttribute as String, "Send Level knob. Set level.")
        f.b.setAttribute(knob, kAXValueAttribute as String, 0)
        f.b.setChildren(knob, [])
        f.b.setChildren(f.strips[0], [anchor, group, knob])
        let echo = f.b.element(291_910), parent = f.b.element(291_911)
        let menu = f.b.element(291_912), leaf = f.b.element(291_913), panner = f.b.element(291_914)
        for (e, title) in [(echo,"Bus 1 → Aux 1"),(parent,"Bus"),(leaf,"Bus 1 → Aux 1"),(panner,"Post Pan")] {
            f.b.setRole(e,kAXMenuItemRole as String); f.b.setAttribute(e,kAXTitleAttribute as String,title)
            f.b.setChildren(e,[])
        }
        for e in [echo,leaf,panner] { f.b.setAttribute(e,"AXMenuItemMarkChar","✓") }
        f.b.setRole(menu,kAXMenuRole as String); f.b.setChildren(menu,[leaf]); f.b.setChildren(parent,[menu])
        f.b.setChildren(f.root,[echo,panner,parent])
        return Prepared(f:f,anchor:anchor,group:group,bypass:bypass,knob:knob,checkedEcho:echo,checkedLeaf:leaf)
    }
    private func read(_ p: Prepared, ordinal: Int = 1, document: String? = nil) async -> ChannelResult {
        let f = p.f
        let binding = AXMixerStripBinding.Binding(window:f.window,mixer:f.mixer,strip:f.strips[0],document:document ?? f.bundle.absoluteString)
        return await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getAssignedSendVerified(ordinal:ordinal,runtime:f.logic,timing:.immediate)
        }
    }
    private func passiveHeaderFocus(_ f: Issue291PhysicalStripReferenceTests.Fixture) -> AXUIElement {
        let label = f.b.element(291_940)
        f.b.setRole(label, kAXTextFieldRole as String)
        f.b.setAttribute(label, kAXValueAttribute as String, NSNumber(value: 0))
        f.b.setAttributeSettable(label, kAXValueAttribute as String, false)
        f.b.setAttribute(label, kAXWindowAttribute as String, f.window)
        f.b.setAttribute(label, kAXParentAttribute as String, f.headers[0])
        f.b.setChildren(label, [])
        f.b.setChildren(f.headers[0], [label, f.headerVolumes[0], f.headerPans[0]])
        f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, label)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        // The generic fake builder bridges NSNumber(0) through Bool. Preserve
        // the native CFNumber payload rather than qualifying a CFBoolean.
        f.attributeReadResult = { element, attribute in
            if CFEqual(element, label), attribute == kAXValueAttribute as String {
                return .success(f.b.attributeValue(element, attribute).map { $0 as AnyObject })
            }
            return nil
        }
        return label
    }
    private func passivePhysicalFocus(_ f: Issue291PhysicalStripReferenceTests.Fixture) throws -> AXUIElement {
        // Focus a different physical source, never the requested send's strip.
        let focus = f.strips[1], outer = f.b.element(291_950)
        let children = try AXHelpers.childrenResult(f.window, runtime: f.logic.ax).get()
        f.b.setRole(outer, kAXGroupRole as String)
        f.b.setAttribute(outer, kAXDescriptionAttribute as String, "Mixer")
        f.b.setChildren(outer, [f.mixer])
        f.b.setChildren(f.window, children.map { CFEqual($0, f.mixer) ? outer : $0 })
        f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, focus)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttributeSettable(focus, kAXValueAttribute as String, false)
        f.b.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 0)
        f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 0)
        f.attributeReadResult = { element, attribute in
            guard CFEqual(element, focus) else { return nil }
            if attribute == kAXValueAttribute as String || attribute == kAXSelectedTextAttribute as String {
                return .failure(.init(raw: AXError.noValue.rawValue))
            }
            return nil
        }
        return focus
    }
    @Test("An exact passive physical focus permits the different retained source's checked send read")
    func passivePhysicalFocusAllowsOnlyOwnedSendRead() async throws {
        let p = try prepare(), f = p.f
        let focus = try passivePhysicalFocus(f)
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: focus, runtime: f.logic) != .notTextEditing)
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A")
        #expect((body["current_destination"] as? [String: Any])?["number"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(body["focus_restoration"] as? String == "restored")
        let wrote = try #require(body["write_attempted"] as? Bool)
        #expect(!wrote)
        #expect(f.mutations.count == 2)
        #expect(f.mutations.allSatisfy {
            (CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String)
                || (CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String)
        })
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: focus, runtime: f.logic) != .notTextEditing)
    }
    @Test("A passive physical focus exception still refuses editing, ambiguous and foreign ownership",
          arguments: ["editor", "settable", "characters", "line", "boolean_line", "detached", "duplicate", "parent", "window", "background", "unread"])
    func unsafePhysicalFocusCannotPress(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let focus = try passivePhysicalFocus(f)
        switch fault {
        case "editor": f.b.setRole(focus, kAXTextFieldRole as String)
        case "settable": f.b.setAttributeSettable(focus, kAXValueAttribute as String, true)
        case "characters": f.b.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 1)
        case "line": f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 1)
        case "boolean_line": f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, false)
        case "detached": f.b.setChildren(f.mixer, [f.strips[0]])
        case "duplicate": f.b.setChildren(f.mixer, [f.strips[0], focus, focus])
        case "parent": f.b.setAttribute(focus, kAXParentAttribute as String, f.window)
        case "window": f.b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.app)
        case "background": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        case "unread":
            f.attributeReadResult = { element, attribute in
                guard CFEqual(element, focus) else { return nil }
                return .failure(.init(raw: attribute == kAXValueAttribute as String ? AXError.cannotComplete.rawValue : AXError.noValue.rawValue))
            }
        default: Issue.record("unknown physical focus fault")
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(f.mutations.isEmpty)
    }
    @Test("Revoking held physical focus at routing capability lookup refuses before the press")
    func passivePhysicalFocusRevocationBeforePress() async throws {
        let p = try prepare(), f = p.f
        _ = try passivePhysicalFocus(f)
        f.onActionNamesRead = { control in
            if CFEqual(control, f.outputs[0]) {
                f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.window)
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
    @Test("A retained noneditable Arrange label permits only the owned routing-popup read")
    func passiveHeaderAllowsRoutingReadWithoutRelaxingKeyboardGate() async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f)
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: label, runtime: f.logic) != .notTextEditing)
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A")
        #expect((body["current_destination"] as? [String: Any])?["number"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
        #expect(f.mutations.allSatisfy {
            (CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String)
                || (CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String)
        })
        #expect(AccessibilityChannel.readLogicKeyboardFocus(of: label, runtime: f.logic) != .notTextEditing)
    }
    @Test("Editing, ambiguous, foreign, or unreadable focus never permits a routing press",
          arguments: ["editable", "insertion", "selection", "text", "characters", "string_value", "boolean_value",
                      "wrong_window", "wrong_parent", "detached", "duplicate", "unread_attribute", "background"])
    func unsafeHeaderFocusHasNoAction(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f)
        switch fault {
        case "editable": f.b.setAttributeSettable(label, kAXValueAttribute as String, true)
        case "insertion": f.b.setAttribute(label, kAXInsertionPointLineNumberAttribute as String, 0)
        case "selection": f.b.setAttribute(label, kAXSelectedTextRangeAttribute as String, "0:0")
        case "text": f.b.setAttribute(label, kAXSelectedTextAttribute as String, "")
        case "characters": f.b.setAttribute(label, kAXNumberOfCharactersAttribute as String, 0)
        case "string_value": f.b.setAttribute(label, kAXValueAttribute as String, "0")
        case "boolean_value": f.b.setAttribute(label, kAXValueAttribute as String, false)
        case "wrong_window": f.b.setAttribute(label, kAXWindowAttribute as String, f.app)
        case "wrong_parent": f.b.setAttribute(label, kAXParentAttribute as String, f.headers[1])
        case "detached": f.b.setChildren(f.headers[0], [f.headerVolumes[0], f.headerPans[0]])
        case "duplicate": f.b.setChildren(f.headers[0], [label, label, f.headerVolumes[0], f.headerPans[0]])
        case "unread_attribute":
            f.attributeReadResult = { element, attribute in
                if CFEqual(element, label), attribute == kAXSelectedTextRangeAttribute as String {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if CFEqual(element, label), attribute == kAXValueAttribute as String {
                    return .success(f.b.attributeValue(element, attribute).map { $0 as AnyObject })
                }
                return nil
            }
        case "background": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        default: Issue.record("unknown injected fault")
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(f.mutations.isEmpty)
    }
    @Test("Focus or original header custody lost during capability lookup prevents the press",
          arguments: ["focus", "editable", "parent", "document"])
    func passiveFocusRevocationBeforePressHasNoAction(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f)
        f.onActionNamesRead = { control in
            guard CFEqual(control, f.outputs[0]) else { return }
            switch fault {
            case "focus": f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.headers[1])
            case "editable": f.b.setAttributeSettable(label, kAXValueAttribute as String, true)
            case "parent": f.b.setChildren(f.headers[0], [f.headerVolumes[0], f.headerPans[0]])
            case "document": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
            default: Issue.record("unknown injected revocation")
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        #expect(f.mutations.isEmpty)
    }
    @Test("The final held-focus read cannot press a source whose project it just revoked")
    func documentRevocationInFinalFocusReadHasNoAction() async throws {
        let p = try prepare(), f = p.f
        let label = passiveHeaderFocus(f), revocation = FinalFocusRevocation()
        f.onActionNamesRead = { control in
            if CFEqual(control, f.outputs[0]) { revocation.arm() }
        }
        f.attributeReadResult = { element, attribute in
            if CFEqual(element, label), attribute == kAXValueAttribute as String {
                revocation.valueRead()
                return .success(f.b.attributeValue(element, attribute).map { $0 as AnyObject })
            }
            return nil
        }
        f.onAttributeRead = { element, attribute in
            if CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String, revocation.take() {
                f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(f.b.attributeValue(f.window, kAXDocumentAttribute as String) as? String == "file:///wrong.logicx")
        #expect(body["state"] as? String == "C")
        let navigated = try #require(body["navigation_attempted"] as? Bool)
        #expect(!navigated)
        #expect(f.mutations.isEmpty)
    }
    @Test("Bare checked bus echoes cannot bypass the legal bus domain", arguments:[1,256,257,999999])
    func checkedSendBusDomain(_ number: Int) async throws {
        let p = try prepare()
        for element in [p.checkedEcho,p.checkedLeaf] {
            p.f.b.setAttribute(element,kAXTitleAttribute as String,"Bus \(number)")
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        if OutputAssignment.busNumbers.contains(number) {
            #expect(body["state"] as? String == "A")
            let destination = try #require(body["current_destination"] as? [String:Any])
            #expect(destination["number"] as? Int == number)
        } else {
            #expect(body["state"] as? String == "C")
            #expect(body["current_destination"] == nil)
        }
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(p.f.mutations.count == 2)
    }
    @Test("Rejected bus roots remain routing competitors, not panner marks",
          arguments:["Bus 257","Bus 999999","Bus 257 → Aux 1"],[false,true])
    func rejectedBusCompetitorIsNotAbsence(_ title: String, _ checked: Bool) async throws {
        let p = try prepare(), f = p.f
        let competitor = f.b.element(291_930)
        f.b.setRole(competitor,kAXMenuItemRole as String)
        f.b.setAttribute(competitor,kAXTitleAttribute as String,title)
        f.b.setAttribute(competitor,"AXMenuItemMarkChar",checked ? "✓" : "")
        f.b.setChildren(competitor,[])
        f.b.setChildren(f.root,[p.checkedEcho,competitor,f.b.element(291_914),f.b.element(291_911)])
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == (checked ? "C" : "A"))
        if checked { #expect(body["current_destination"] == nil) }
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
    }
    @Test("Retained assigned list reads checked destination, never display or bypass/level", arguments:[false,true])
    func assignedSendReadsOwnedCheckmarks(_ failedACK: Bool) async throws {
        let p = try prepare(), f = p.f
        if failedACK { f.outputPressFailure = .init(raw:AXError.cannotComplete.rawValue) }
        let result = await read(p)
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "A")
        let destination = try #require(body["current_destination"] as? [String:Any])
        #expect(destination["kind"] as? String == "bus")
        #expect(destination["number"] as? Int == 1)
        #expect(body["popup_menu_state"] as? String == "closed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
        if f.mutations.count == 2 {
            #expect(CFEqual(f.mutations[0].0,f.outputs[0]))
            #expect(f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(f.mutations[1].0,f.root))
            #expect(f.mutations[1].1 == kAXCancelAction as String)
        }
    }
    @Test("Empty/negative/out-of-range ordinal or wrong project has no action", arguments:[-1,0,2,99])
    func unboundSendHasNoAction(_ ordinal: Int) async throws {
        let p = try prepare()
        let body = try #require(sharedJSONObject(await read(p,ordinal:ordinal).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test func wrongProjectHasNoAction() async throws {
        let p = try prepare()
        let body = try #require(sharedJSONObject(await read(p,document:"file:///wrong.logicx").message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Lookalike automation/group without qualified send anchor cannot be pressed")
    func unqualifiedGroupHasNoAction() async throws {
        let p = try prepare()
        p.f.b.setChildren(p.f.strips[0],[p.group,p.knob])
        let body = try #require(sharedJSONObject(await read(p,ordinal:0).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test func unadvertisedListCannotBePressed() async throws {
        let p = try prepare()
        p.f.b.setActionNames(p.f.outputs[0], [])
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("A list that loses custody during capability lookup is not pressed")
    func listReplacementBeforePressRefuses() async throws {
        let p = try prepare(), f = p.f
        let replacement = f.b.element(291_920)
        f.b.setRole(replacement,kAXButtonRole as String)
        f.b.setAttribute(replacement,kAXDescriptionAttribute as String,"list")
        f.b.setChildren(replacement,[])
        f.onActionNamesRead = { control in
            if CFEqual(control,f.outputs[0]) { f.b.setChildren(p.group,[p.bypass,replacement]) }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
    @Test("Group replacement after opening withholds destination and avoids unowned cleanup")
    func groupReplacementAfterPressRefuses() async throws {
        let p = try prepare(), f = p.f
        let replacement = f.b.element(291_921)
        f.b.setRole(replacement,kAXGroupRole as String)
        f.b.setAttribute(replacement,kAXDescriptionAttribute as String,"Bus 256")
        f.b.setChildren(replacement,[p.bypass,f.outputs[0]])
        // Reinstate the initial parent; the replacement is installed only after actual press.
        f.b.setChildren(p.group,[p.bypass,f.outputs[0]])
        f.onChildrenResultRead = { control in
            if CFEqual(control,f.mixer), !f.mutations.isEmpty {
                f.b.setChildren(f.strips[0],[p.anchor,replacement,p.knob])
            }
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        let navigationAttempted = try #require(body["navigation_attempted"] as? Bool)
        #expect(navigationAttempted)
        #expect(f.mutations.count == 1)
        #expect(f.mutations.allSatisfy { CFEqual($0.0,f.outputs[0]) && $0.1 == kAXPressAction as String })
    }
    @Test("Unreadable late competitor prevents both ordinal publication and any action")
    func unreadLateSendCensusHasNoAction() async throws {
        let p = try prepare(), f = p.f
        let unread = f.b.element(291_922)
        f.b.setRole(unread,kAXButtonRole as String); f.b.setChildren(unread,[])
        f.b.setChildren(f.strips[0],[p.anchor,p.group,p.knob,unread])
        f.attributeReadResult = { control,key in
            if CFEqual(control,unread), key == kAXHelpAttribute as String { return .failure(.init(raw:-25204)) }
            return nil
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
}
