@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

private final class CurrentOutputMenuFixture: @unchecked Sendable {
    let b = FakeAXRuntimeBuilder()
    var next = 291_800
    var failedMarks = Set<Int>()
    var failure = AXHelpers.AXStatusError(raw: -25204)
    func item(_ title: String, mark: String? = nil, children: [AXUIElement] = []) -> AXUIElement {
        next += 1
        let node = b.element(next)
        b.setAttribute(node, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(node, kAXTitleAttribute as String, title)
        b.setAttribute(node, kAXSelectedAttribute as String, false)
        if let mark { b.setAttribute(node, "AXMenuItemMarkChar", mark) }
        b.setChildren(node, children)
        return node
    }
    func menu(_ children: [AXUIElement]) -> AXUIElement {
        next += 1
        let node = b.element(next)
        b.setAttribute(node, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(node, children)
        return node
    }
    var runtime: AXHelpers.Runtime {
        b.makeAXRuntime(attributeValueResultHandler: { [self] node, attr in
            guard attr == "AXMenuItemMarkChar", failedMarks.contains(b.elementID(node)) else { return nil }
            return .failure(failure)
        }, setAttributeHandler: nil, performActionHandler: nil)
    }
}

@Test("Current output is the checked routing choice, not the checked panner or AXSelected")
func currentOutputMenuReadsCheckedStereoAlias() {
    let f = CurrentOutputMenuFixture()
    let stereo = f.item("Stereo Output", mark: "✓")
    let output = f.item("Output", mark: "-", children: [f.menu([stereo, f.item("Output 3-4")])])
    let bus = f.item("Bus", children: [f.menu([f.item("Bus 1 → Aux 1")])])
    let root = f.menu([f.item("Stereo Output", mark: "✓"), f.item("No Output"), output, bus,
                       f.item("Balance", mark: "✓")])
    #expect(AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: f.runtime) == .stereoOutput)
    #expect(f.b.actionCalls.isEmpty)
    #expect(f.b.setCalls.isEmpty)
}

@Test("Send destinations use their complete Output/Mono/Stereo tree, never the current root echo",
      arguments: ["stereo", "pair", "root_only", "duplicate_leaf", "duplicate_parent", "unread_mono"])
func sendOutputChoiceUsesActualNestedStructure(fault: String) throws {
    let f = CurrentOutputMenuFixture()
    let stereo = f.item("Stereo Output"), pair = f.item("Output 3-4")
    let monoMenu = f.menu([f.item("Output 1"), f.item("Output 2"), f.item("Output 3"), f.item("Output 4")])
    let stereoMenu = f.menu([stereo, pair])
    let outputMenu = f.menu([f.item("Mono", children: [monoMenu]), f.item("Stereo", children: [stereoMenu])])
    if fault == "duplicate_leaf" { f.b.setChildren(stereoMenu, [stereo, pair, f.item("Output 3-4")]) }
    if fault == "unread_mono" { f.b.removeAttribute(monoMenu, kAXRoleAttribute as String) }
    let output = f.item("Output", children: [outputMenu])
    var rows = [f.item("Output 3-4", mark: "✓"), f.item("Post Pan", mark: "✓")]
    if fault != "root_only" { rows.append(output) }
    if fault == "duplicate_parent" { rows.append(f.item("Output", children: [outputMenu])) }
    let root = f.menu(rows)
    let destination: OutputAssignment = fault == "stereo" ? .stereoOutput : .physical(3, 4)
    let choice = AccessibilityChannel.sendMenuChoice(for: destination, in: root, runtime: f.runtime)
    if fault == "stereo" || fault == "pair" {
        guard case .item(let leaf, let path) = choice else {
            Issue.record("Actual nested send output was not offered: \(choice.failureLabel)"); return
        }
        #expect(CFEqual(leaf, fault == "stereo" ? stereo : pair))
        #expect(path == ["Output", "Stereo", fault == "stereo" ? "Stereo Output" : "Output 3-4"])
        // The existing main-output selector remains deliberately flat.
        #expect(AccessibilityChannel.outputMenuChoice(for: destination, in: root, runtime: f.runtime).failureLabel == "destination_not_offered")
    } else {
        switch fault {
        case "root_only": #expect(choice.failureLabel == "submenu_not_offered")
        case "duplicate_leaf": #expect(choice.failureLabel == "destination_title_repeated")
        case "duplicate_parent": #expect(choice.failureLabel == "submenu_title_repeated")
        default: #expect(choice.failureLabel == "menu_not_read")
        }
    }
    #expect(f.b.actionCalls.isEmpty)
    #expect(f.b.setCalls.isEmpty)
}

@Test("Conflicting checked routing choices are unknown, not first-match authority")
func currentOutputMenuRefusesContradictoryChecks() {
    let f = CurrentOutputMenuFixture()
    let output = f.item("Output", children: [f.menu([f.item("Stereo Output", mark: "✓")])])
    let bus = f.item("Bus", children: [f.menu([f.item("Bus 1 → Aux 1", mark: "✓")])])
    let root = f.menu([f.item("Stereo Output", mark: "✓"), output, bus])
    #expect(AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: f.runtime) == nil)
}

@Test("Checked bus authority comes from its Bus branch, including nested buses")
func currentOutputMenuReadsNestedCheckedBus() {
    let f = CurrentOutputMenuFixture()
    let nested = f.item("33 - 64", children: [f.menu([f.item("Bus 33 → Aux 2", mark: "✓")])])
    let root = f.menu([f.item("Bus 33", mark: "✓"),
                       f.item("Output", children: [f.menu([f.item("Stereo Output")])]),
                       f.item("Bus", children: [f.menu([f.item("Bus 1"), nested])])])
    #expect(AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: f.runtime) == .bus(33))
    #expect(f.b.actionCalls.isEmpty)
}

@Test("Checked physical pairs and No Output require matching checked routing evidence", arguments: [false, true])
func currentOutputMenuReadsPhysicalOrNoOutput(_ noOutput: Bool) {
    let f = CurrentOutputMenuFixture()
    let pair = f.item("Output 3-4", mark: noOutput ? nil : "✓")
    let root = f.menu([f.item(noOutput ? "No Output" : "Output 3-4", mark: "✓"),
                       f.item("Output", children: [f.menu([f.item("Stereo Output"), pair])])])
    #expect(AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: f.runtime) ==
            (noOutput ? .noOutput : .physical(3, 4)))
    #expect(f.b.actionCalls.isEmpty)
}

@Test("Unreadable or unsupported routing marks cannot prove an unselected alternative", arguments: [-25204, -25205])
func currentOutputMenuRefusesUnreadMarks(_ status: Int32) {
    let f = CurrentOutputMenuFixture()
    let alternative = f.item("Output 3-4")
    f.failedMarks.insert(f.b.elementID(alternative))
    f.failure = AXHelpers.AXStatusError(raw: status)
    let output = f.item("Output", children: [f.menu([f.item("Stereo Output", mark: "✓"), alternative])])
    let root = f.menu([f.item("Stereo Output", mark: "✓"), output])
    #expect(AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: f.runtime) == nil)
}

@Test("A malformed mark or untyped submenu child is unread, never an unchecked alternative", arguments: [false, true])
func currentOutputMenuRefusesMalformedWitness(_ malformedRole: Bool) {
    let f = CurrentOutputMenuFixture()
    let alternate = f.item("Output 3-4")
    let busMenu = f.menu([f.item("Bus 1 → Aux 1", mark: "✓")])
    if malformedRole { f.b.removeAttribute(busMenu, kAXRoleAttribute as String) }
    else { f.b.setAttribute(alternate, "AXMenuItemMarkChar", NSNumber(value: 42)) }
    let output = f.item("Output", children: [f.menu([f.item("Stereo Output", mark: "✓"), alternate])])
    let root = f.menu([f.item("Stereo Output", mark: "✓"), output,
                       f.item("Bus", children: malformedRole ? [busMenu] : [f.menu([])])])
    #expect(AccessibilityChannel.currentOutputMenuAssignment(in: root, runtime: f.runtime) == nil)
}

@Suite("#291 owned checked-output acquisition", .serialized)
struct Issue291OwnedCurrentOutputTests {
    @Test("Native popup focus is read beside a fresh CG census, and unread or foreign focus refuses",
          arguments: ["owned", "unread", "foreign"])
    func nativePopupReadsCurrentWindowsBeforeFocusedApplication(focus: String) throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let wrapper = f.b.element(291_870), item = f.b.element(291_871)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setRole(wrapper, kAXPopUpButtonRole as String)
        f.b.setAttribute(wrapper, kAXParentAttribute as String, f.mixer)
        f.b.setAttribute(wrapper, kAXWindowAttribute as String, f.window)
        f.b.setChildren(wrapper, [f.root])
        f.b.setRole(f.root, kAXMenuRole as String)
        f.b.setFrame(f.root, x: 20, y: 100, width: 230, height: 175)
        f.b.setRole(item, kAXMenuItemRole as String)
        f.b.setChildren(f.root, [item])
        f.outputHitTest = { _, _ in .success(item) }
        final class FocusProbe: @unchecked Sendable {
            var currentCGRead = false
        }
        let probe = FocusProbe()
        let runtime = AXLogicProElements.Runtime(logicProPID: { f.pid }, ax: f.logic.ax,
            onScreenWindowList: {
                probe.currentCGRead = true
                return [[kCGWindowOwnerPID as String: f.pid, kCGWindowNumber as String: 291_901,
                         kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                         kCGWindowBounds as String: CGRect(x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation]]
            }, focusedApplicationPID: {
                let current = probe.currentCGRead
                probe.currentCGRead = false
                if focus == "foreign" { return f.pid + 1 }
                return focus == "owned" && current ? f.pid : nil
            })
        let physical = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let observed = AccessibilityChannel.NativeOutputReadPopup.read(
            physical: physical, app: f.app, pid: f.pid, runtime: runtime)
        if focus == "owned" { #expect(observed != nil) }
        else { #expect(observed == nil) }
        #expect(f.mutations.isEmpty)
    }

    @Test("No Output native popup requires the same owned native path and CG frame, never a destination press",
          arguments: ["owned", "wrong_window", "wrong_mixer", "wrong_wrapper_role", "wrong_root_role",
                      "wrong_hit_role", "nonreciprocal_hit", "nonreciprocal_root", "frame_disagrees",
                      "missing_frame", "hit_unread", "hit_absent", "foreign_popup", "duplicate_popup",
                      "preexisting_popup", "cg_changed_during_hit", "source_changed_during_hit",
                      "document_changed_during_hit", "foreign_focus_during_hit", "wrapper_changed_after_mark",
                      "other_output_state", "missing_press_capability"])
    func ownedNativeNoOutputPopupAcquiresAndCleansUp(fault: String) async throws {
        try await assertOwnedNativeNeutralPopup(fault: fault, input: false)
    }

    @Test("A native No Input popup can be owned and cancelled without becoming a checked Bus assignment",
          arguments: ["owned", "wrong_window", "wrong_mixer", "wrong_wrapper_role", "wrong_root_role",
                      "wrong_hit_role", "nonreciprocal_hit", "nonreciprocal_root", "frame_disagrees",
                      "missing_frame", "hit_unread", "hit_absent", "foreign_popup", "duplicate_popup",
                      "preexisting_popup", "cg_changed_during_hit", "source_changed_during_hit",
                      "document_changed_during_hit", "foreign_focus_during_hit", "wrapper_changed_after_mark",
                      "other_output_state", "missing_press_capability"])
    func ownedNativeNoInputPopupAcquiresAndCleansUp(fault: String) async throws {
        try await assertOwnedNativeNeutralPopup(fault: fault, input: true)
    }

    @Test("No Input cleanup requires one unambiguous checked neutral root and no competing input check",
          arguments: ["unchecked_neutral", "duplicate_neutral", "conflicting_checked_root",
                      "checked_input_leaf", "unread_neutral_mark", "wrong_neutral_label"])
    func nativeNoInputRejectsAmbiguousMarks(fault: String) async throws {
        try await assertOwnedNativeNeutralPopup(fault: fault, input: true)
    }

    @Test("Neutral input refuses foreign or unread keyboard focus before opening a popup",
          arguments: ["foreign_application_focus", "unread_application_focus"])
    func nativeNeutralInputRequiresFocusedProcessBeforePress(fault: String) async throws {
        try await assertOwnedNativeNeutralPopup(fault: fault, input: true)
    }

    private func assertOwnedNativeNeutralPopup(fault: String, input: Bool) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        let wrapper = f.b.element(291_860), noOutput = f.b.element(291_861)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setRole(wrapper, kAXPopUpButtonRole as String)
        f.b.setAttribute(wrapper, kAXParentAttribute as String, f.mixer)
        f.b.setAttribute(wrapper, kAXWindowAttribute as String, f.window)
        f.b.setAttribute(f.root, kAXWindowAttribute as String, f.window)
        f.b.setRole(noOutput, kAXMenuItemRole as String)
        f.b.setAttribute(noOutput, kAXTitleAttribute as String, input ? "No Input" : "No Output")
        f.b.setAttribute(noOutput, "AXMenuItemMarkChar", "✓")
        f.b.setChildren(noOutput, [])
        f.b.setChildren(f.root, [noOutput])
        f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, input ? "Input" : "No Output")
        if input {
            f.b.setAttribute(f.outputs[0], kAXHelpAttribute as String, "Input slot. Choose the channel strip input source.")
        }
        f.b.setActionNames(f.outputs[0], [kAXPressAction as String])
        f.b.setFrame(f.root, x: 20, y: 100, width: 230, height: 175)
        f.outputMenuWrapper = wrapper
        f.popupFrame = CGRect(x: 20, y: 100, width: 230, height: 175)
        // The real host opens this menu despite returning cannotComplete.
        f.outputPressFailure = .init(raw: AXError.cannotComplete.rawValue)
        @Sendable func popupWindow(owner: pid_t, number: Int) -> [String: Any] {
            [kCGWindowOwnerPID as String: owner, kCGWindowNumber as String: number,
             kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
             kCGWindowBounds as String: CGRect(x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation]
        }
        switch fault {
        case "missing_press_capability": f.b.setActionNames(f.outputs[0], [])
        case "wrong_window": f.b.setAttribute(wrapper, kAXWindowAttribute as String, f.b.element(291_862))
        case "wrong_mixer": f.b.setAttribute(wrapper, kAXParentAttribute as String, f.b.element(291_862))
        case "wrong_wrapper_role": f.b.setRole(wrapper, kAXGroupRole as String)
        case "wrong_root_role": f.b.setRole(f.root, kAXGroupRole as String)
        case "wrong_hit_role": f.b.setRole(noOutput, kAXButtonRole as String)
        case "nonreciprocal_hit": f.b.setChildren(f.root, [])
        case "frame_disagrees": f.b.setFrame(f.root, x: 21, y: 100, width: 230, height: 175)
        case "missing_frame": f.popupFrame = nil
        case "preexisting_popup": f.popupWindowsOverride = [popupWindow(owner: f.pid, number: 291_901)]
        case "other_output_state": f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, input ? "Input 1" : "Stereo Output")
        case "unchecked_neutral": f.b.setAttribute(noOutput, "AXMenuItemMarkChar", "")
        case "unread_neutral_mark":
            f.attributeReadResult = { node, attribute in
                if CFEqual(node, noOutput), attribute == "AXMenuItemMarkChar" {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            }
        case "wrong_neutral_label": f.b.setAttribute(noOutput, kAXTitleAttribute as String, "No Output")
        case "duplicate_neutral", "conflicting_checked_root", "checked_input_leaf":
            let other = f.b.element(291_863)
            f.b.setRole(other, kAXMenuItemRole as String)
            f.b.setAttribute(other, kAXTitleAttribute as String, fault == "duplicate_neutral" ? "No Input" : "Input 1")
            f.b.setAttribute(other, "AXMenuItemMarkChar", "✓")
            f.b.setChildren(other, [])
            if fault == "checked_input_leaf" {
                let parent = f.b.element(291_864), submenu = f.b.element(291_865)
                f.b.setRole(parent, kAXMenuItemRole as String)
                f.b.setAttribute(parent, kAXTitleAttribute as String, "Input")
                f.b.setAttribute(parent, "AXMenuItemMarkChar", "")
                f.b.setRole(submenu, kAXMenuRole as String)
                f.b.setChildren(submenu, [other])
                f.b.setChildren(parent, [submenu])
                f.b.setChildren(f.root, [noOutput, parent])
            } else { f.b.setChildren(f.root, [noOutput, other]) }
        default: break
        }
        if ["foreign_popup", "duplicate_popup"].contains(fault) {
            f.onChildrenResultRead = { node in
                if CFEqual(node, f.mixer), !f.mutations.isEmpty {
                    if fault == "foreign_popup" {
                        f.popupWindowsOverride = [popupWindow(owner: f.pid + 1, number: 291_901)]
                    } else {
                        f.popupWindowsOverride = [popupWindow(owner: f.pid, number: 291_901),
                                                 popupWindow(owner: f.pid, number: 291_902)]
                    }
                }
            }
        }
        if fault == "nonreciprocal_root" {
            f.onChildrenResultRead = { node in
                if CFEqual(node, wrapper) { f.b.setChildren(wrapper, []) }
            }
        }
        if fault == "wrapper_changed_after_mark" {
            f.onAttributeRead = { node, attribute in
                if CFEqual(node, noOutput), attribute == "AXMenuItemMarkChar" {
                    f.b.setAttribute(wrapper, kAXWindowAttribute as String, f.b.element(291_862))
                }
            }
        }
        f.outputHitTest = { app, point in
            #expect(CFEqual(app, f.app))
            #expect(point == CGPoint(x: 135, y: 187.5))
            switch fault {
            case "hit_unread": return .failure(.init(raw: AXError.cannotComplete.rawValue))
            case "hit_absent": return .success(nil)
            case "cg_changed_during_hit":
                f.popupWindowsOverride = [popupWindow(owner: f.pid, number: 291_902)]
            case "source_changed_during_hit": f.reorder([1])
            case "document_changed_during_hit": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
            case "foreign_focus_during_hit": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
            default: break
            }
            return .success(noOutput)
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let base = f.logic
        let runtime: AXLogicProElements.Runtime
        if fault == "foreign_application_focus" || fault == "unread_application_focus" {
            runtime = .init(logicProPID: base.logicProPID, ax: base.ax,
                onScreenWindowList: base.onScreenWindowList,
                focusedApplicationPID: { fault == "foreign_application_focus" ? f.pid + 1 : nil })
        } else { runtime = base }
        let reading = await AXMixerStripBinding.$current.withValue(binding) {
            if input { return await AccessibilityChannel.getInputBusVerified(runtime: runtime, timing: .immediate) }
            return await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(reading.message))
        if fault != "owned" {
            #expect(body["state"] as? String == "C")
            #expect(body["current_output"] == nil)
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
            #expect(f.mutations.allSatisfy { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String })
            #expect(f.mutations.count == (["preexisting_popup", "missing_press_capability",
                "foreign_application_focus", "unread_application_focus"].contains(fault) ? 0 : 1))
            return
        }
        if input {
            #expect(body["state"] as? String == "C", "No Input is still outside the bus-only capability")
            #expect(body["current_input"] == nil)
        } else {
            #expect(body["state"] as? String == "A")
            #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "no_output")
        }
        #expect(body["popup_menu_state"] as? String == "closed")
        let attempted = try #require(body["write_attempted"] as? Bool)
        let pressSucceeded = try #require(body["popup_press_succeeded"] as? Bool)
        let cancelSucceeded = try #require(body["popup_cancel_succeeded"] as? Bool)
        #expect(!attempted)
        #expect(!pressSucceeded)
        #expect(cancelSucceeded)
        #expect(f.mutations.count == 2)
        #expect(CFEqual(f.mutations.first!.0, f.outputs[0]))
        #expect(CFEqual(f.mutations.last!.0, f.root))
        #expect(f.mutations.last!.1 == kAXCancelAction as String)
    }

    @Test("A late stale-target refusal keeps known menu/focus effects but withholds the output")
    func outputContextFailureKeepsObservedMenuEffects() throws {
        let read = ChannelResult.success(HonestContract.encodeStateA(extras: [
            "current_output": ["kind": "stereo_output"], "navigation_attempted": true,
            "popup_menu_state": "not_restored", "popup_cancel_succeeded": false,
            "focus_restoration": "not_restored", "write_attempted": false,
        ]))
        let failed = AccessibilityChannel.outputReadContextFailure(read,
            operation: "mixer.get_output_verified")
        let body = try #require(sharedJSONObject(failed.message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_output"] == nil)
        #expect(body["popup_menu_state"] as? String == "not_restored")
        #expect(body["focus_restoration"] as? String == "not_restored")
        let navigated: Bool = try #require(body["navigation_attempted"] as? Bool)
        #expect(navigated)
    }
    @Test("Public checked-output read is registered read-only and rejects legacy selectors")
    func publicCurrentOutputContract() async throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_mixer", command: "get_output_verified"))
        #expect(spec.mutability == .readOnly)
        #expect(spec.allowedParams == Set(["target_ref", "project_ref"]))
        #expect(ChannelRouter.v2RoutingTable["mixer.get_output_verified"] == [.accessibility])
        let router = ChannelRouter()
        let result = await MixerDispatcher.handle(command: "get_output_verified", params: ["track": .int(0)], router: router, cache: StateCache())
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "invalid_params")
    }
    private func prepare(_ f: Issue291PhysicalStripReferenceTests.Fixture) {
        let echo = f.b.element(291_850)
        let parent = f.b.element(291_851)
        let menu = f.b.element(291_852)
        let stereo = f.b.element(291_853)
        for (node, title) in [(echo, "Stereo Output"), (parent, "Output"), (stereo, "Stereo Output")] {
            f.b.setRole(node, kAXMenuItemRole as String)
            f.b.setAttribute(node, kAXTitleAttribute as String, title)
            f.b.setChildren(node, [])
        }
        f.b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
        f.b.setAttribute(stereo, "AXMenuItemMarkChar", "✓")
        f.b.setRole(menu, kAXMenuRole as String)
        f.b.setChildren(menu, [stereo])
        f.b.setChildren(parent, [menu])
        f.b.setChildren(f.root, [echo, parent])
    }

    private func prepareBusNamespace(_ f: Issue291PhysicalStripReferenceTests.Fixture, fault: String = "healthy") {
        prepare(f)
        guard fault != "missing" else { return }
        let parent = f.b.element(967_101), menu = f.b.element(967_102)
        let first = f.b.element(967_103), group = f.b.element(967_104)
        let nested = f.b.element(967_105), last = f.b.element(967_106)
        for (node, title) in [(parent, "Bus"), (first, "Bus 1 → Aux 1"),
                              (group, "33 - 64"), (last, fault == "unknown" ? "Unrecognized entry" : "Bus 33")] {
            f.b.setRole(node, kAXMenuItemRole as String)
            f.b.setAttribute(node, kAXTitleAttribute as String, title)
            f.b.setChildren(node, [])
        }
        for node in [menu, nested] { f.b.setRole(node, kAXMenuRole as String) }
        f.b.setChildren(nested, [last])
        f.b.setChildren(group, [nested])
        f.b.setChildren(menu, [first, group])
        f.b.setChildren(parent, [menu])
        if fault == "duplicate" { f.b.setAttribute(last, kAXTitleAttribute as String, "Bus 1") }
        if fault == "unread" {
            f.childrenReadResult = { node in
                CFEqual(node, nested) ? .failure(.init(raw: -25204)) : nil
            }
        }
        f.b.setChildren(f.root, f.b.makeAXRuntime().children(f.root) + [parent])
    }

    @Test("An owned output read retains the actual nested Bus menu inventory without allocation claims")
    func checkedOutputPublishesObservedBusNumbersWithoutAllocationAuthority() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepareBusNamespace(f)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "A")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "stereo_output")
        let inventory = try #require(body["observed_bus_namespace"] as? [String: Any])
        #expect(inventory["bus_numbers"] as? [Int] == [1, 33])
        #expect(inventory["source"] as? String == "ax_output_bus_menu")
        #expect(inventory["namespace_availability"] as? String == "not_observed")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(f.mutations.count == 2)
        #expect(CFEqual(f.mutations[0].0, f.outputs[0]))
        #expect(CFEqual(f.mutations[1].0, f.root))
        #expect(f.mutations[0].1 == kAXPressAction as String)
        #expect(f.mutations[1].1 == kAXCancelAction as String)
    }

    @Test("Missing, unknown, duplicate or unread Bus menus do not become an empty usable namespace",
          arguments: ["missing", "unknown", "duplicate", "unread"])
    func checkedOutputWithholdsUnqualifiedBusNamespace(fault: String) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepareBusNamespace(f, fault: fault)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["observed_bus_namespace"] == nil)
        if fault != "unread" {
            #expect(body["state"] as? String == "A", "Optional namespace evidence must not erase the existing checked assignment")
        }
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
    }

    @Test("An unchanged checked output cannot authenticate two different Bus menu inventories")
    func checkedOutputWithholdsDisagreeingBusNamespace() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepareBusNamespace(f)
        let last = f.b.element(967_106), counter = "967-bus-mark-reads"
        f.attributeReadResult = { node, attribute in
            guard CFEqual(node, last), attribute == "AXMenuItemMarkChar" else { return nil }
            let reads = (f.b.attributeValue(f.window, counter) as? Int ?? 0) + 1
            f.b.setAttribute(f.window, counter, reads)
            if reads == 1 { f.b.setAttribute(last, kAXTitleAttribute as String, "Bus 34") }
            return .success("" as NSString)
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(f.b.attributeValue(f.window, counter) as? Int == 2)
        #expect(body["state"] as? String == "A")
        #expect(body["observed_bus_namespace"] == nil)
        #expect(f.mutations.count == 2)
    }

    @Test("Owned read opens and cancels only the held source popup, never presses a destination")
    func ownedCurrentOutputAcquiresAndCleansUp() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer, strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "A")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "stereo_output")
        let attempted: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(body["popup_menu_state"] as? String == "closed")
        let pressSucceeded: Bool = try #require(body["popup_press_succeeded"] as? Bool)
        #expect(pressSucceeded)
        #expect(f.mutations.count == 2)
        #expect(CFEqual(f.mutations[0].0, f.outputs[0]))
        #expect(f.mutations[0].1 == kAXPressAction as String)
        #expect(CFEqual(f.mutations[1].0, f.root))
        #expect(f.mutations[1].1 == kAXCancelAction as String)
    }

    @Test("Ordinary output read custody and cleanup-only custody stay distinct",
          arguments: ["transient_current_index", "unread_source", "wrong_root", "preexisting_popup",
                      "changed_pid", "changed_window", "changed_document", "changed_strip",
                      "menu_multiplicity", "label_before_press", "missing_cancel", "cancel_not_closing"])
    func ordinaryOutputPopupRetirementUsesOnlyBoundedCustody(_ fault: String) async throws {
        final class Probe: @unchecked Sendable {
            var mixerReadsBeforePress = 0
            var mixerReadsAfterPress = 0
            var changed = false
        }
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let probe = Probe()
        let foreignRoot = f.b.element(291_880), foreignWindow = f.b.element(291_881)
        f.b.setRole(foreignRoot, kAXMenuRole as String)
        f.b.setChildren(foreignRoot, [])
        f.b.setActionNames(foreignRoot, [kAXCancelAction as String])
        f.b.setRole(foreignWindow, kAXWindowRole as String)
        f.b.setChildren(foreignWindow, [])
        if fault == "preexisting_popup" { f.b.setChildren(f.mixer, f.strips + [f.root]) }
        if fault == "missing_cancel" { f.b.setActionNames(f.root, []) }
        f.onChildrenResultRead = { node in
            guard CFEqual(node, f.mixer) else { return }
            if f.mutations.isEmpty {
                probe.mixerReadsBeforePress += 1
                if fault == "label_before_press", probe.mixerReadsBeforePress == 7 {
                    f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "Output 3-4")
                }
                return
            }
            probe.mixerReadsAfterPress += 1
            guard probe.mixerReadsAfterPress >= 2, !probe.changed else { return }
            probe.changed = true
            switch fault {
            case "wrong_root": f.b.setChildren(f.mixer, f.strips + [foreignRoot])
            case "menu_multiplicity": f.b.setChildren(f.mixer, f.strips + [f.root, foreignRoot])
            case "changed_window":
                f.b.setAttribute(f.app, kAXMainWindowAttribute as String, foreignWindow)
                f.b.setAttribute(f.app, kAXWindowsAttribute as String, [foreignWindow])
            case "changed_document":
                f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
            case "changed_strip": f.reorder([1])
            default: break
            }
        }
        f.childrenReadResult = { node in
            guard CFEqual(node, f.mixer), !f.mutations.isEmpty else { return nil }
            if fault == "transient_current_index", probe.mixerReadsAfterPress == 2 {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            if fault == "cancel_not_closing",
               f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }) {
                return .success(f.strips + [f.root])
            }
            return nil
        }
        if fault == "unread_source" {
            f.attributeReadResult = { node, attribute in
                guard !f.mutations.isEmpty, CFEqual(node, f.outputs[0]),
                      attribute == kAXDescriptionAttribute as String else { return nil }
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
        }
        let base = f.logic
        let runtime: AXLogicProElements.Runtime
        if fault == "changed_pid" {
            runtime = .init(logicProPID: { f.mutations.isEmpty ? f.pid : f.pid + 1 }, ax: base.ax,
                onScreenWindowList: base.onScreenWindowList,
                focusedApplicationPID: base.focusedApplicationPID)
        } else { runtime = base }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        let readable = fault == "transient_current_index"
        #expect(body["state"] as? String == (readable ? "A" : "C"), "\(body)")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String == (readable ? "stereo_output" : nil))
        let cancelExpected = ["transient_current_index", "unread_source", "cancel_not_closing"].contains(fault)
        let cancels = f.mutations.filter { $0.1 == kAXCancelAction as String }
        #expect(cancels.count == (cancelExpected ? 1 : 0))
        #expect(cancels.allSatisfy { CFEqual($0.0, f.root) })
        if fault == "unread_source" {
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(AccessibilityChannel.checkedOutputPopupMenus(in: f.mixer, runtime: f.logic.ax)?.isEmpty == true)
        }
        if fault == "label_before_press" || fault == "preexisting_popup" {
            #expect(f.mutations.isEmpty)
        }
        if fault == "cancel_not_closing" { #expect(body["popup_menu_state"] as? String == "not_restored") }
        #expect(!f.mutations.contains { CFEqual($0.0, f.pair) && $0.1 == kAXPressAction as String })
    }

    @Test("A captured Mixer-child Logic 13 popup survives modal semantic retirement only for read and cleanup",
          arguments: ["survives", "source_lost"])
    func mixerChildPopupUsesCapturedReadCleanupToken(_ state: String) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
        let frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        f.b.setFrame(f.root, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.popupFrame = frame
        f.attributeReadResult = { node, attribute in
            let pressed = f.mutations.contains { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String }
            let cancelled = f.mutations.contains { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }
            guard pressed, !cancelled, CFEqual(node, f.mixer),
                  attribute == kAXDescriptionAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        f.onChildrenResultRead = { node in
            guard state == "source_lost", CFEqual(node, f.mixer),
                  f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }) else { return }
            f.b.setChildren(f.strips[0], f.logic.ax.children(f.strips[0]).filter {
                !CFEqual($0, f.outputs[0])
            })
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == (state == "survives" ? "A" : "C"), "\(body)")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String ==
            (state == "survives" ? "stereo_output" : nil))
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
        #expect(!f.mutations.contains { CFEqual($0.0, f.pair) && $0.1 == kAXPressAction as String })
    }

    @Test("Mixer-child output acquisition waits for the exact CG row that follows its AX root")
    func mixerChildOutputWaitsForDelayedCGIdentity() async throws {
        final class Probe: @unchecked Sendable { var postPressCGReads = 0 }
        let f = try Issue291PhysicalStripReferenceTests.Fixture(), probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
        let frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        f.b.setFrame(f.root, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.popupFrame = frame
        f.attributeReadResult = { node, attribute in
            let pressed = f.mutations.contains { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String }
            let cancelled = f.mutations.contains { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }
            guard pressed, !cancelled, CFEqual(node, f.mixer),
                  attribute == kAXDescriptionAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        let base = f.logic
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: base.ax,
            onScreenWindowList: {
                guard let windows = base.onScreenWindowList() else { return nil }
                guard f.mutations.contains(where: {
                    CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String
                }), !f.mutations.contains(where: {
                    CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
                }) else { return windows }
                probe.postPressCGReads += 1
                guard probe.postPressCGReads == 1 else { return windows }
                return windows.filter {
                    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue
                        != LogicOnScreenWindows.popupMenuLevel
                }
            }, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let timing = AccessibilityChannel.OutputAssignmentTiming(
            popupOpenTimeoutMs: 100, popupCloseTimeoutMs: 0,
            readbackTimeoutMs: 0, pollIntervalMs: 0)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: timing)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.postPressCGReads >= 2)
        #expect(body["state"] as? String == "A", "\(body)")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "stereo_output")
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
    }

    @Test("Mixer-child output binds the stable CG window number while bounds and name settle")
    func mixerChildOutputAcceptsStableCGIdentityAcrossGeometrySettling() async throws {
        final class Probe: @unchecked Sendable { var postPressCGReads = 0 }
        let f = try Issue291PhysicalStripReferenceTests.Fixture(), probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
        let axFrame = CGRect(x: 25, y: 105, width: 220, height: 165)
        let initialCGFrame = CGRect(x: 20, y: 100, width: 230, height: 175)
        let settledCGFrame = CGRect(x: 18, y: 98, width: 234, height: 179)
        f.b.setFrame(f.root, x: axFrame.origin.x, y: axFrame.origin.y,
                     width: axFrame.width, height: axFrame.height)
        f.popupFrame = initialCGFrame
        f.attributeReadResult = { node, attribute in
            let pressed = f.mutations.contains { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String }
            let cancelled = f.mutations.contains { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }
            guard pressed, !cancelled, CFEqual(node, f.mixer),
                  attribute == kAXDescriptionAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        let base = f.logic
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: base.ax,
            onScreenWindowList: {
                guard var windows = base.onScreenWindowList() else { return nil }
                guard f.mutations.contains(where: {
                    CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String
                }), !f.mutations.contains(where: {
                    CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
                }) else { return windows }
                probe.postPressCGReads += 1
                for index in windows.indices where
                    (windows[index][kCGWindowLayer as String] as? NSNumber)?.intValue
                        == LogicOnScreenWindows.popupMenuLevel {
                    windows[index][kCGWindowBounds as String] =
                        (probe.postPressCGReads == 1 ? initialCGFrame : settledCGFrame).dictionaryRepresentation
                    windows[index][kCGWindowName as String] =
                        probe.postPressCGReads == 1 ? "Menu" : "Menu Shadow"
                }
                return windows
            }, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.postPressCGReads >= 2)
        #expect(body["state"] as? String == "A", "\(body)")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "stereo_output")
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
    }

    @Test("Captured Mixer-child cleanup accepts its exact CG identity once among descendant popup windows")
    func mixerChildOutputCleanupMatchesCapturedCGMemberWithoutPublishing() async throws {
        final class Probe: @unchecked Sendable {
            var postPressCGReads = 0
            var competingCGReads = 0
        }
        let f = try Issue291PhysicalStripReferenceTests.Fixture(), probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
        let frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        f.b.setFrame(f.root, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.popupFrame = frame
        let base = f.logic
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: base.ax,
            onScreenWindowList: {
                guard var windows = base.onScreenWindowList() else { return nil }
                guard f.mutations.contains(where: {
                    CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String
                }), !f.mutations.contains(where: {
                    CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
                }) else { return windows }
                probe.postPressCGReads += 1
                if probe.postPressCGReads >= 4 {
                    probe.competingCGReads += 1
                    windows.append([
                        kCGWindowOwnerPID as String: f.pid,
                        kCGWindowNumber as String: 291_902,
                        kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                        kCGWindowBounds as String: CGRect(
                            x: 30, y: 110, width: 180, height: 130).dictionaryRepresentation,
                    ])
                }
                return windows
            }, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let timing = AccessibilityChannel.OutputAssignmentTiming(
            popupOpenTimeoutMs: 0, popupCloseTimeoutMs: 0,
            readbackTimeoutMs: 100, pollIntervalMs: 0)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: timing)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.competingCGReads > 0)
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(body["current_output"] == nil)
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(body["popup_cancel_succeeded"] as? Bool == true)
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
    }

    @Test("A pending Mixer-child root cannot be replaced by another eligible popup root",
          arguments: ["mixer_child", "top_level"])
    func pendingMixerChildRootReplacementFailsClosed(_ replacement: String) async throws {
        final class Probe: @unchecked Sendable {
            var installedPending = false
            var cgReadsAfterPress = 0
            var mixerReadsAfterMissingCG = 0
            var replacementInstalled = false
        }
        let f = try Issue291PhysicalStripReferenceTests.Fixture(), probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let pendingRoot = f.b.element(291_990)
        f.b.setRole(pendingRoot, kAXMenuRole as String)
        f.b.setAttribute(pendingRoot, kAXParentAttribute as String, f.mixer)
        f.b.setChildren(pendingRoot, f.logic.ax.children(f.root))
        let frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        f.b.setFrame(pendingRoot, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.b.setFrame(f.root, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.popupFrame = frame
        f.onChildrenResultRead = { node in
            guard CFEqual(node, f.mixer),
                  f.mutations.contains(where: {
                      CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String
                  }) else { return }
            if !probe.installedPending {
                probe.installedPending = true
                f.b.setChildren(f.mixer, f.strips + [pendingRoot])
                return
            }
            guard probe.cgReadsAfterPress >= 1, !probe.replacementInstalled else { return }
            probe.mixerReadsAfterMissingCG += 1
            guard probe.mixerReadsAfterMissingCG == 2 else { return }
            probe.replacementInstalled = true
            if replacement == "mixer_child" {
                f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
                f.b.setChildren(f.mixer, f.strips + [f.root])
            } else {
                f.b.setAttribute(f.root, kAXParentAttribute as String, f.app)
                f.b.setChildren(f.mixer, f.strips)
                f.b.setChildren(f.app, [f.window, f.root])
            }
        }
        let base = f.logic
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: base.ax,
            onScreenWindowList: {
                guard let windows = base.onScreenWindowList() else { return nil }
                guard f.mutations.contains(where: {
                    CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String
                }), !f.mutations.contains(where: {
                    CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
                }) else { return windows }
                probe.cgReadsAfterPress += 1
                guard probe.cgReadsAfterPress == 1 else { return windows }
                return windows.filter {
                    ($0[kCGWindowLayer as String] as? NSNumber)?.intValue
                        != LogicOnScreenWindows.popupMenuLevel
                }
            }, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let timing = AccessibilityChannel.OutputAssignmentTiming(
            popupOpenTimeoutMs: 100, popupCloseTimeoutMs: 0,
            readbackTimeoutMs: 0, pollIntervalMs: 0)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: timing)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.installedPending && probe.replacementInstalled)
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(body["current_output"] == nil)
        #expect(f.mutations.map(\.1) == [kAXPressAction as String])
    }

    @Test("Logic popup CG bounds require finite origins",
          arguments: ["nan_x", "nan_y", "negative_infinity_x", "negative_infinity_y"])
    func mixerChildPopupRejectsNonfiniteCGOrigin(_ fault: String) {
        var x = 20.0, y = 100.0
        if fault == "nan_x" { x = .nan }
        if fault == "nan_y" { y = .nan }
        if fault == "negative_infinity_x" { x = -.infinity }
        if fault == "negative_infinity_y" { y = -.infinity }
        let row: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: Int32(2_910_900)),
            kCGWindowNumber as String: NSNumber(value: Int64(291_901)),
            kCGWindowLayer as String: NSNumber(value: Int32(LogicOnScreenWindows.popupMenuLevel)),
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": 230.0, "Height": 175.0],
        ]
        #expect(AccessibilityChannel.checkedLogicOutputPopupWindows(
            [row], logicPID: 2_910_900) == nil)
    }

    @Test("Captured Mixer-child publication accepts only its later exact bounded closure")
    func mixerChildPopupRecordsDelayedExactClosure() async throws {
        final class Probe: @unchecked Sendable { var postCancelMixerReads = 0 }
        let f = try Issue291PhysicalStripReferenceTests.Fixture(), probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
        let frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        f.b.setFrame(f.root, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.popupFrame = frame
        f.attributeReadResult = { node, attribute in
            let pressed = f.mutations.contains { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String }
            let cancelled = f.mutations.contains { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }
            guard pressed, !cancelled, CFEqual(node, f.mixer),
                  attribute == kAXDescriptionAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        f.childrenReadResult = { node in
            guard CFEqual(node, f.mixer),
                  f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }) else { return nil }
            probe.postCancelMixerReads += 1
            return probe.postCancelMixerReads <= 2 ? .success(f.strips + [f.root]) : nil
        }
        let base = f.logic
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: base.ax,
            onScreenWindowList: {
                guard var windows = base.onScreenWindowList() else { return nil }
                if f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }),
                   probe.postCancelMixerReads <= 2 {
                    windows.append([kCGWindowOwnerPID as String: f.pid,
                        kCGWindowNumber as String: 291_901,
                        kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                        kCGWindowBounds as String: frame.dictionaryRepresentation])
                }
                return windows
            }, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let timing = AccessibilityChannel.OutputAssignmentTiming(
            popupOpenTimeoutMs: 0, popupCloseTimeoutMs: 100,
            readbackTimeoutMs: 0, pollIntervalMs: 0)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: timing)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.postCancelMixerReads >= 3)
        #expect(body["state"] as? String == "A", "\(body)")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "stereo_output")
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
    }

    @Test("Captured Mixer-child cleanup refuses changed identity, capability, gate and non-closure",
          arguments: ["parent_drift", "cg_drift", "duplicate_cg", "missing_cancel", "gate", "final_gate", "ack_not_closed"])
    func mixerChildPopupTokenFailsClosed(_ fault: String) async throws {
        final class Probe: @unchecked Sendable {
            var capabilityReads = 0
            var finalWindowReads = 0
            var gateRevoked = false
        }
        let f = try Issue291PhysicalStripReferenceTests.Fixture(), probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.mixer)
        f.b.setFrame(f.root, x: 20, y: 100, width: 230, height: 175)
        f.popupFrame = CGRect(x: 20, y: 100, width: 230, height: 175)
        if fault == "missing_cancel" { f.b.setActionNames(f.root, []) }
        f.attributeReadResult = { node, attribute in
            let pressed = f.mutations.contains { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String }
            let cancelled = f.mutations.contains { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }
            guard pressed, !cancelled, CFEqual(node, f.mixer),
                  attribute == kAXDescriptionAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        f.onActionNamesRead = { node in
            guard CFEqual(node, f.root) else { return }
            probe.capabilityReads += 1
            guard probe.capabilityReads == 1 else { return }
            switch fault {
            case "parent_drift":
                f.b.setAttribute(f.root, kAXParentAttribute as String, f.strips[1])
            case "cg_drift":
                f.popupWindowsOverride = [[kCGWindowOwnerPID as String: f.pid,
                    kCGWindowNumber as String: 291_902,
                    kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                    kCGWindowBounds as String: CGRect(x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation]]
            case "duplicate_cg":
                f.popupWindowsOverride = [
                    [kCGWindowOwnerPID as String: f.pid,
                     kCGWindowNumber as String: 291_901,
                     kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                     kCGWindowBounds as String: CGRect(
                        x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation],
                    [kCGWindowOwnerPID as String: f.pid,
                     kCGWindowNumber as String: 291_901,
                     kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                     kCGWindowBounds as String: CGRect(
                        x: 30, y: 110, width: 180, height: 130).dictionaryRepresentation],
                ]
            case "gate": probe.gateRevoked = true
            default: break
            }
        }
        if fault == "ack_not_closed" {
            f.childrenReadResult = { node in
                guard CFEqual(node, f.mixer),
                      f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }) else { return nil }
                return .success(f.strips + [f.root])
            }
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let base = f.logic
        let runtime: AXLogicProElements.Runtime
        if fault == "final_gate" {
            runtime = .init(logicProPID: base.logicProPID, ax: base.ax,
                onScreenWindowList: {
                    let windows = base.onScreenWindowList()
                    if probe.capabilityReads >= 2 {
                        probe.finalWindowReads += 1
                        if probe.finalWindowReads == 2 { probe.gateRevoked = true }
                    }
                    return windows
                }, focusedApplicationPID: base.focusedApplicationPID)
        } else { runtime = base }
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: { !probe.gateRevoked })
        let result = await OperationTraceContext.$current.withValue(context) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(body["current_output"] == nil)
        #expect(body["popup_menu_state"] as? String == "not_restored")
        let cancels = f.mutations.filter { $0.1 == kAXCancelAction as String }
        if fault == "final_gate" { #expect(probe.gateRevoked && probe.finalWindowReads >= 2) }
        #expect(cancels.count == (fault == "ack_not_closed" ? 1 : 0))
        #expect(cancels.allSatisfy { CFEqual($0.0, f.root) })
        #expect(!f.mutations.contains { CFEqual($0.0, f.pair) && $0.1 == kAXPressAction as String })
    }

    @Test("A newly acquired top-level Logic 13 output menu is read and cleaned only through its captured root",
          arguments: ["survives", "source_replaced", "strip_replaced"])
    func topLevelOutputMenuUsesSeparateReadCleanupAndPublicationProofs(_ state: String) async throws {
        final class Probe: @unchecked Sendable {
            var promoted = false
            var closed = false
            var cancelCapabilityReads = 0
        }
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setChildren(f.app, [f.window])
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.app)
        let frame = CGRect(x: 20, y: 100, width: 230, height: 175)
        f.b.setFrame(f.root, x: frame.origin.x, y: frame.origin.y,
                     width: frame.width, height: frame.height)
        f.popupFrame = frame
        let probe = Probe()
        f.onChildrenResultRead = { node in
            if CFEqual(node, f.mixer), !f.mutations.isEmpty, !probe.promoted {
                probe.promoted = true
                f.b.setChildren(f.mixer, f.strips)
                f.b.setChildren(f.app, [f.window, f.root])
            }
            if CFEqual(node, f.app),
               f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }),
               !probe.closed {
                probe.closed = true
                f.b.setChildren(f.app, [f.window])
                if state == "source_replaced" {
                    f.b.setChildren(f.strips[0], f.logic.ax.children(f.strips[0]).filter {
                        !CFEqual($0, f.outputs[0])
                    })
                }
                if state == "strip_replaced" { f.reorder([1]) }
            }
        }
        f.attributeReadResult = { node, attribute in
            guard probe.promoted, !probe.closed, CFEqual(node, f.outputs[0]),
                  attribute == kAXDescriptionAttribute as String else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        f.onActionNamesRead = { node in
            if CFEqual(node, f.root) { probe.cancelCapabilityReads += 1 }
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.promoted)
        #expect(body["state"] as? String == (state == "survives" ? "A" : "C"), "\(body)")
        #expect((body["current_output"] as? [String: Any])?["kind"] as? String ==
            (state == "survives" ? "stereo_output" : nil))
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(probe.cancelCapabilityReads == 2)
        #expect(f.mutations.count == 2)
        if f.mutations.count == 2 {
            #expect(CFEqual(f.mutations[0].0, f.outputs[0]))
            #expect(CFEqual(f.mutations[1].0, f.root))
            #expect(f.mutations[1].1 == kAXCancelAction as String)
        }
        #expect(!f.mutations.contains { CFEqual($0.0, f.pair) && $0.1 == kAXPressAction as String })
    }

    @Test("Captured top-level output cleanup refuses drift, missing capability and acknowledged non-closure",
          arguments: ["root_drift", "cg_drift", "missing_cancel", "ack_not_closed",
                      "competing_mixer", "lingering_mixer", "action_failure_closure",
                      "disappears_before_cleanup"])
    func topLevelOutputCleanupFailsClosed(_ fault: String) async throws {
        final class Probe: @unchecked Sendable { var promoted = false; var capabilityReads = 0 }
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setChildren(f.app, [f.window])
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.app)
        f.b.setFrame(f.root, x: 20, y: 100, width: 230, height: 175)
        f.popupFrame = CGRect(x: 20, y: 100, width: 230, height: 175)
        if fault == "missing_cancel" { f.b.setActionNames(f.root, []) }
        let foreignRoot = f.b.element(291_887)
        let foreignMixerMenu = f.b.element(291_888)
        f.b.setRole(foreignRoot, kAXMenuRole as String)
        f.b.setAttribute(foreignRoot, kAXParentAttribute as String, f.app)
        f.b.setChildren(foreignRoot, [])
        f.b.setRole(foreignMixerMenu, kAXMenuRole as String)
        f.b.setChildren(foreignMixerMenu, [])
        let probe = Probe()
        f.onChildrenResultRead = { node in
            if CFEqual(node, f.mixer), !f.mutations.isEmpty, !probe.promoted {
                probe.promoted = true
                f.b.setChildren(f.mixer, fault == "competing_mixer"
                    ? f.strips + [foreignMixerMenu] : f.strips)
                f.b.setChildren(f.app, [f.window, f.root])
            }
            if fault != "ack_not_closed", CFEqual(node, f.app),
               f.mutations.contains(where: { CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String }) {
                f.b.setChildren(f.app, [f.window])
                if fault == "lingering_mixer" {
                    f.b.setChildren(f.mixer, f.strips + [foreignMixerMenu])
                }
            }
        }
        f.onActionNamesRead = { node in
            guard CFEqual(node, f.root) else { return }
            probe.capabilityReads += 1
            guard probe.capabilityReads == 1 else { return }
            if fault == "root_drift" { f.b.setChildren(f.app, [f.window, foreignRoot]) }
            if fault == "cg_drift" {
                f.popupWindowsOverride = [[kCGWindowOwnerPID as String: f.pid,
                    kCGWindowNumber as String: 291_902,
                    kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                    kCGWindowBounds as String: CGRect(x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation]]
            }
            if fault == "disappears_before_cleanup" {
                f.b.setChildren(f.app, [f.window])
                f.popupWindowsOverride = []
            }
        }
        let base = f.logic
        let runtime: AXLogicProElements.Runtime
        if fault == "action_failure_closure" {
            let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
                attributeIsSettable: base.ax.attributeIsSettable,
                setAttributeValue: base.ax.setAttributeValue, children: base.ax.children,
                performAction: base.ax.performAction, childCount: base.ax.childCount,
                actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
                childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
                performActionResult: { node, action in
                    if CFEqual(node, f.root), action == kAXCancelAction as String {
                        _ = base.ax.performActionResult?(node, action)
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return base.ax.performActionResult?(node, action)
                        ?? .failure(.init(raw: AXError.failure.rawValue))
                }, elementAtPosition: base.ax.elementAtPosition,
                attributeValuesResult: base.ax.attributeValuesResult)
            runtime = .init(logicProPID: base.logicProPID, ax: ax,
                onScreenWindowList: base.onScreenWindowList,
                focusedApplicationPID: base.focusedApplicationPID)
        } else {
            runtime = base
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(body["current_output"] == nil)
        #expect(body["popup_menu_state"] as? String == "not_restored")
        #expect(f.mutations.count == (["ack_not_closed", "lingering_mixer", "action_failure_closure"].contains(fault) ? 2 : 1))
        #expect(!f.mutations.contains { CFEqual($0.0, f.pair) && $0.1 == kAXPressAction as String })
    }

    @Test("Fresh top-level absence is bracketed by the exact source immediately before press",
          arguments: ["foreign_popup", "source_during_absence", "document_during_absence",
                      "gate_after_bookend", "cancel_after_bookend"])
    func topLevelOutputRequiresFreshAbsenceAtPressBoundary(_ fault: String) async throws {
        final class Probe: @unchecked Sendable {
            var windowReads = 0
            var injected = false
            var armRevocation = false
            var revocationLatched = false
        }
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setChildren(f.app, [f.window])
        f.b.setAttribute(f.root, kAXParentAttribute as String, f.app)
        f.b.setFrame(f.root, x: 20, y: 100, width: 230, height: 175)
        f.outputPressOpensMenu = false
        let probe = Probe()
        let base = f.logic
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: base.ax,
            onScreenWindowList: {
                probe.windowReads += 1
                guard let windows = base.onScreenWindowList() else { return nil }
                guard probe.windowReads == 2 else { return windows }
                probe.injected = true
                switch fault {
                case "foreign_popup":
                    f.b.setChildren(f.app, [f.window, f.root])
                    return windows + [[kCGWindowOwnerPID as String: f.pid,
                        kCGWindowNumber as String: 291_908,
                        kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                        kCGWindowBounds as String: CGRect(x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation]]
                case "source_during_absence":
                    f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "Output 3-4")
                case "document_during_absence":
                    f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
                case "gate_after_bookend", "cancel_after_bookend":
                    probe.armRevocation = true
                default: break
                }
                return windows
            }, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: {
                guard fault == "gate_after_bookend", probe.armRevocation else { return true }
                if !probe.revocationLatched { probe.revocationLatched = true; return true }
                return false
            }, deadline: ContinuousClock.now.advanced(by: .seconds(30)),
            cancellationRequested: {
                guard fault == "cancel_after_bookend", probe.armRevocation else { return false }
                if !probe.revocationLatched { probe.revocationLatched = true; return false }
                return true
            })
        let result = await OperationTraceContext.$current.withValue(context) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getOutputVerified(params: [:], runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.windowReads == 2 && probe.injected)
        if fault.hasSuffix("after_bookend") { #expect(probe.revocationLatched) }
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(body["current_output"] == nil)
        #expect(f.mutations.isEmpty, "A foreign popup at the final boundary must prevent even the slot press")
    }

    @Test("No physical target or a wrong document refuses before any popup action")
    func ownedCurrentOutputRefusesWrongTarget() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        let absent = await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        #expect(try #require(sharedJSONObject(absent.message))["state"] as? String == "C")
        let wrong = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer, strip: f.strips[0], document: "file:///wrong.logicx")
        let stale = await AXMixerStripBinding.$current.withValue(wrong) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        #expect(try #require(sharedJSONObject(stale.message))["error"] as? String == "stale_target_reference")
        #expect(f.mutations.isEmpty)
    }

    @Test("Cancellation reverses only an already-owned popup under its live original scope",
          arguments: ["owned", "remembered", "source_read", "live_focus", "detached_focus", "document", "source", "slot", "popup", "gate", "deadline"])
    func cancelledOutputReadCleansOnlyItsOwnedPopup(_ revocation: String) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let checksNativeFocus = revocation == "live_focus" || revocation == "detached_focus"
        if checksNativeFocus {
            f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.volumes[1])
        }
        let interrupted = "291-interrupted-popup"
        f.onActionNamesRead = { node in
            guard revocation != "source_read" else { return }
            guard CFEqual(node, f.root), f.b.attributeValue(f.window, interrupted) as? Bool != true else { return }
            f.b.setAttribute(f.window, interrupted, true)
            switch revocation {
            case "document": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
            case "source": f.b.setChildren(f.mixer, [f.strips[1], f.root])
            case "slot":
                if case .success(let children) = AXHelpers.childrenResult(f.strips[0], runtime: f.logic.ax) {
                    f.b.setChildren(f.strips[0], children.filter { !CFEqual($0, f.outputs[0]) })
                }
            case "popup":
                let foreign = f.b.element(291_854)
                f.b.setRole(foreign, kAXMenuRole as String)
                f.b.setChildren(foreign, [])
                f.b.setChildren(f.mixer, f.strips + [foreign])
            default: break
            }
            if revocation == "deadline" { Thread.sleep(forTimeInterval: 0.12) }
            if revocation != "remembered" { withUnsafeCurrentTask { $0?.cancel() } }
            // Model the interrupted reader's latched Help refusal. Cleanup must
            // not reset it or grant a fresh Help/assignment acquisition.
            _ = AXHelpers.getHelp(f.outputs[0], runtime: f.logic.ax)
        }
        f.onAttributeRead = { node, attribute in
            if revocation == "detached_focus", f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                f.b.setChildren(f.mixer, [f.strips[0]])
            }
            if revocation == "source_read", CFEqual(node, f.outputs[0]),
               attribute == kAXDescriptionAttribute as String, f.mutations.count == 1,
               f.b.attributeValue(f.window, interrupted) as? Bool != true {
                f.b.setAttribute(f.window, interrupted, true)
                withUnsafeCurrentTask { $0?.cancel() }
                _ = AXHelpers.getHelp(f.outputs[0], runtime: f.logic.ax)
            }
            if attribute == kAXHelpAttribute as String, f.b.attributeValue(f.window, interrupted) as? Bool == true {
                f.b.setAttribute(f.window, "291-help-after-interruption", true)
            }
        }
        let guardian = AXHelpers.HelpReadGuard(stop: {
            f.b.attributeValue(f.window, interrupted) as? Bool == true
        })
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: { revocation != "gate" || f.b.attributeValue(f.window, interrupted) as? Bool != true },
            deadline: ContinuousClock.now.advanced(by: revocation == "deadline" ? .milliseconds(100) : .seconds(30)),
            cancellationRequested: { f.b.attributeValue(f.window, interrupted) as? Bool == true })
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let read = await Task {
            await OperationTraceContext.$current.withValue(context) {
                await AXMixerStripBinding.$current.withValue(binding) {
                    await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                        await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
                    }
                }
            }
        }.value
        let body = try #require(sharedJSONObject(read.message))
        let interruptionObserved = try #require(f.b.attributeValue(f.window, interrupted) as? Bool)
        #expect(interruptionObserved)
        #expect(guardian.stopped)
        let helpAfterInterruption = f.b.attributeValue(f.window, "291-help-after-interruption") as? Bool ?? false
        #expect(!helpAfterInterruption)
        #expect(body["state"] as? String == "C")
        #expect(body["current_output"] == nil)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        let cancels = f.mutations.filter { $0.1 == kAXCancelAction as String }
        let cleanupOwned = revocation == "owned" || revocation == "remembered" || revocation == "source_read" || checksNativeFocus
        #expect(cancels.count == (cleanupOwned ? 1 : 0))
        #expect(f.mutations.filter { $0.1 == kAXPressAction as String }.count == 1)
        if cleanupOwned {
            let cancel = try #require(cancels.first)
            #expect(CFEqual(cancel.0, f.root))
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(body["focus_restoration"] as? String == (revocation == "detached_focus" ? "not_restored" : "restored"))
            if checksNativeFocus {
                let actual: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                    kAXFocusedUIElementAttribute as String, runtime: f.logic.ax))
                #expect(CFEqual(actual, f.volumes[1]))
                #expect(AXHelpers.getRole(actual, runtime: f.logic.ax) == kAXSliderRole as String)
            }
        } else {
            #expect(body["popup_menu_state"] as? String != "closed")
        }
    }

    @Test("A failed press acknowledgement requires actual owned-menu readback, not the acknowledgement", arguments: [false, true])
    func ownedCurrentOutputRequiresObservedPopupAfterFailedPress(_ opensMenu: Bool) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.outputPressFailure = .init(raw: AXError.cannotComplete.rawValue)
        f.outputPressOpensMenu = opensMenu
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer, strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == (opensMenu ? "A" : "C"))
        let pressAcknowledged: Bool = try #require(body["popup_press_succeeded"] as? Bool)
        #expect(!pressAcknowledged)
        let writeAttempted: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        if opensMenu {
            #expect((body["current_output"] as? [String: Any])?["kind"] as? String == "stereo_output")
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(f.mutations.count == 2)
        } else {
            #expect(body["current_output"] == nil)
            #expect(body["popup_menu_state"] as? String == "not_observed")
            #expect(f.mutations.count == 1)
        }
    }

    @Test("Revocation during the Cancel action-name read prevents cleanup on the foreign project")
    func ownedCurrentOutputRefusesCleanupAfterRevocation() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.onActionNamesRead = { node in
            if CFEqual(node, f.root) { f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx") }
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer, strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C")
        #expect(body["popup_menu_state"] as? String == "not_restored")
        #expect(f.mutations.count == 1)
        #expect(CFEqual(f.mutations[0].0, f.outputs[0]))
    }

    @Test("A late clear-modal read cannot authorize a popup press after document revocation")
    func ownedCurrentOutputRefusesPressAfterLateSourceRead() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        let clearDialog = f.b.element(291_899)
        f.b.setRole(clearDialog, kAXWindowRole as String)
        f.b.setAttribute(clearDialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        f.b.setAttribute(clearDialog, kAXModalAttribute as String, false)
        f.b.setChildren(clearDialog, [])
        f.b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, clearDialog])
        f.attributeReadResult = { node, attribute in
            if CFEqual(node, clearDialog), attribute == kAXModalAttribute as String {
                // Revoke in sourceOwned's second clear-modal read, not preflight.
                if f.b.attributeValue(f.window, "291-baseline-read") as? Bool == true {
                    f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
                } else { f.b.setAttribute(f.window, "291-baseline-read", true) }
                return .success(NSNumber(value: false))
            }
            return nil
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer, strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        #expect(try #require(sharedJSONObject(result.message))["state"] as? String == "C")
        #expect(f.mutations.isEmpty)
    }

    @Test("A final popup-role read cannot authorize Cancel after document revocation")
    func ownedCurrentOutputRefusesCancelAfterLateMenuRead() async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        let clearDialog = f.b.element(291_899)
        f.b.setRole(clearDialog, kAXWindowRole as String)
        f.b.setAttribute(clearDialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        f.b.setAttribute(clearDialog, kAXModalAttribute as String, false)
        f.b.setChildren(clearDialog, [])
        f.b.setAttribute(f.app, kAXWindowsAttribute as String, [f.window, clearDialog])
        f.onActionNamesRead = { node in
            if CFEqual(node, f.root) {
                f.attributeReadResult = { child, attribute in
                    if CFEqual(child, clearDialog), attribute == kAXModalAttribute as String {
                        f.b.setAttribute(f.window, "291-cleanup-modal-read", true)
                        return .success(NSNumber(value: false))
                    }
                    if CFEqual(child, f.root), attribute == kAXRoleAttribute as String,
                       f.b.attributeValue(f.window, "291-cleanup-modal-read") as? Bool == true {
                        f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
                        return .success(kAXMenuRole as NSString)
                    }
                    return nil
                }
            }
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer, strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getOutputVerified(params: [:], runtime: f.logic, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(body["state"] as? String == "C")
        #expect(body["popup_menu_state"] as? String == "not_restored")
        #expect(f.mutations.count == 1)
    }
}
