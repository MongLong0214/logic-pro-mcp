@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#291 assigned-send owned checked-menu acquisition", .serialized)
struct Issue291AssignedSendMenuTests {
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
        #expect(try #require(body["write_attempted"] as? Bool) == false)
        #expect(p.f.mutations.count == 2)
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
        #expect(try #require(body["write_attempted"] as? Bool) == false)
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
        #expect(try #require(body["navigation_attempted"] as? Bool) == true)
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
