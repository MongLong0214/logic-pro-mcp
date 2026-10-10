@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#291 owned checked bus-input acquisition", .serialized)
struct Issue291OwnedInputBusMenuTests {
    struct Prepared {
        let f: Issue291PhysicalStripReferenceTests.Fixture
        let echo: AXUIElement
        let leaf: AXUIElement
        let inputLeaf: AXUIElement
    }
    private func prepare(_ number: Int = 1) throws -> Prepared {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        f.b.setAttribute(f.outputs[0],kAXDescriptionAttribute as String,"Bus 256")
        f.b.setAttribute(f.outputs[0],kAXHelpAttribute as String,"Input slot. Choose the channel strip input source.")
        f.b.setActionNames(f.outputs[0],[kAXPressAction as String])
        let echo=f.b.element(291_940), leaf=f.b.element(291_941), bus=f.b.element(291_942)
        let busMenu=f.b.element(291_943), input=f.b.element(291_944), inputMenu=f.b.element(291_945)
        let inputLeaf=f.b.element(291_946), noInput=f.b.element(291_947)
        for (element,title) in [(echo,"Bus \(number) ← Audio 2"),(leaf,"Bus \(number) ← Audio 2"),
                                (bus,"Bus"),(input,"Input"),(inputLeaf,"Input 1-2"),(noInput,"No Input")] {
            f.b.setRole(element,kAXMenuItemRole as String)
            f.b.setAttribute(element,kAXTitleAttribute as String,title)
            f.b.setChildren(element,[])
        }
        for element in [echo,leaf] { f.b.setAttribute(element,"AXMenuItemMarkChar","✓") }
        for element in [busMenu,inputMenu] { f.b.setRole(element,kAXMenuRole as String) }
        f.b.setChildren(busMenu,[leaf]); f.b.setChildren(bus,[busMenu])
        f.b.setChildren(inputMenu,[inputLeaf]); f.b.setChildren(input,[inputMenu])
        f.b.setChildren(f.root,[echo,noInput,input,bus])
        return Prepared(f:f,echo:echo,leaf:leaf,inputLeaf:inputLeaf)
    }
    private func read(_ p: Prepared, document: String? = nil) async -> ChannelResult {
        let f=p.f
        let binding=AXMixerStripBinding.Binding(window:f.window,mixer:f.mixer,strip:f.strips[0],document:document ?? f.bundle.absoluteString)
        return await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getInputBusVerified(runtime:f.logic,timing:.immediate)
        }
    }
    @Test("Own input list reads checked bus rather than display", arguments:[1,256])
    func checkedInputBus(_ number: Int) async throws {
        let p=try prepare(number), body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A")
        let input=try #require(body["current_input"] as? [String:Any])
        #expect(input["kind"] as? String == "bus")
        #expect(input["number"] as? Int == number)
        #expect(body["popup_menu_state"] as? String == "closed")
        let write: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!write)
        #expect(p.f.mutations.count == 2)
        if p.f.mutations.count == 2 {
            #expect(CFEqual(p.f.mutations[0].0,p.f.outputs[0]))
            #expect(p.f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(p.f.mutations[1].0,p.f.root))
            #expect(p.f.mutations[1].1 == kAXCancelAction as String)
        }
    }
    @Test("Invalid bus choice and a checked nonbus competitor remain unknown", arguments:[false,true])
    func inputChoicesMustBeKnown(_ conflict: Bool) async throws {
        let p=try prepare(conflict ? 1 : 257)
        if conflict { p.f.b.setAttribute(p.inputLeaf,"AXMenuItemMarkChar","✓") }
        let body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_input"] == nil)
        #expect(body["popup_menu_state"] as? String == "closed")
        let write: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!write)
    }
    @Test("Cancel retiring the original input source withholds its checked bus", arguments: [false, true])
    func originalInputMustSurviveCancel(_ retires: Bool) async throws {
        let p = try prepare(), f = p.f
        f.attributeReadResult = { element, _ in
            guard retires, f.mutations.contains(where: {
                CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
            }) else { return nil }
            // The live host retained the window, Mixer and document but retired
            // the original source after Cancel. Never adopt another strip here.
            f.reorder([1])
            if CFEqual(element, f.strips[0]) || CFEqual(element, f.outputs[0]) {
                return .failure(.init(raw: AXError.invalidUIElement.rawValue))
            }
            return nil
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == (retires ? "C" : "A"))
        let sourceAfter: Bool = try #require(body["source_custody_after_cleanup"] as? Bool)
        if retires { #expect(!sourceAfter) } else { #expect(sourceAfter) }
        let menuOwned: Bool = try #require(body["menu_custody_at_read"] as? Bool)
        #expect(menuOwned)
        #expect(body["output_checkmark_reads_observed"] as? Int == 2)
        let readsAgree: Bool = try #require(body["output_checkmark_reads_agree"] as? Bool)
        #expect(readsAgree)
        let cancelled: Bool = try #require(body["popup_cancel_succeeded"] as? Bool)
        #expect(cancelled)
        let writeAttempted: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        if retires {
            #expect(body["current_input"] == nil)
            for original in [f.strips[0], f.outputs[0]] {
                let retired: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    original, kAXRoleAttribute as String, runtime: f.logic.ax)
                if case .failure(let status) = retired {
                    #expect(status.raw == AXError.invalidUIElement.rawValue)
                } else { Issue.record("The original source and input control must be retired") }
            }
        } else {
            let input = try #require(body["current_input"] as? [String: Any])
            #expect(input["kind"] as? String == "bus")
            #expect(input["number"] as? Int == 1)
        }
        let current = try #require(AXLogicProElements.mixerChannelStripsIfCompletelyRead(in: f.mixer, runtime: f.logic.ax))
        let originalStillMember = current.strips.contains(where: { CFEqual($0, f.strips[0]) })
        if retires { #expect(!originalStillMember) } else { #expect(originalStillMember) }
        if case .found(let window) = AXLogicProElements.arrangeWindowRead(runtime: f.logic) {
            #expect(CFEqual(window, f.window))
        } else { Issue.record("The original window must remain owned") }
        if case .found(let mixer) = AXLogicProElements.mixerAreaLookup(in: f.window, runtime: f.logic) {
            #expect(CFEqual(mixer, f.mixer))
        } else { Issue.record("The original Mixer must remain owned") }
        if case .success(.some(let document)) = AXLogicProElements.projectPickerDocumentRead(f.window, runtime: f.logic) {
            #expect(document == f.bundle.absoluteString)
        } else { Issue.record("The original document must remain owned") }
        #expect(f.mutations.count == 2)
        if f.mutations.count == 2 {
            #expect(CFEqual(f.mutations[0].0, f.outputs[0]))
            #expect(f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(f.mutations[1].0, f.root))
            #expect(f.mutations[1].1 == kAXCancelAction as String)
        }
    }
    @Test func wrongProjectDoesNotNavigate() async throws {
        let p=try prepare()
        let body=try #require(sharedJSONObject(await read(p,document:"file:///wrong.logicx").message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Missing input or unadvertised press cannot navigate", arguments:[false,true])
    func inputControlMustBeQualified(_ missing: Bool) async throws {
        let p=try prepare()
        if missing {
            p.f.b.setAttribute(p.f.outputs[0],kAXHelpAttribute as String,"Output slot. Choose output.")
        } else {
            p.f.b.setActionNames(p.f.outputs[0],[])
        }
        let body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Input control replacement during capability lookup cannot acquire the replacement")
    func replacedInputControlDoesNotNavigate() async throws {
        let p=try prepare(), f=p.f
        let replacement=f.b.element(291_948)
        f.b.setButton(replacement,description:"Bus 256",help:"Input slot. Choose the channel strip input source.",x:0,y:0,width:1,height:1)
        f.b.setChildren(replacement,[])
        f.onActionNamesRead = { element in
            if CFEqual(element,f.outputs[0]) { f.b.setChildren(f.strips[0],[replacement]) }
        }
        let body=try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }
}
