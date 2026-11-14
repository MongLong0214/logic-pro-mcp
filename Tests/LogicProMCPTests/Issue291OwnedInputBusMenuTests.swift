@preconcurrency import ApplicationServices
import Foundation
import MCP
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
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
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

    @Test("Assigned Bus window-root popups retain the same checked input through both owned readers",
          arguments: [false, true], ["owned", "wrong_window", "wrong_mixer", "frame_disagrees",
              "nonreciprocal_root", "foreign_popup", "duplicate_popup", "source_changed",
              "document_changed", "foreign_focus", "contradictory_marks", "unread_mark",
              "preexisting_foreign_focus", "unread_focus", "not_frontmost", "unread_frontmost"])
    func assignedBusWindowRootPopup(internalReader: Bool, fault: String) async throws {
        let p = try prepare(1), f = p.f
        let wrapper = f.b.element(291_960)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "Bus 1")
        f.b.setRole(wrapper, kAXPopUpButtonRole as String)
        f.b.setAttribute(wrapper, kAXParentAttribute as String, f.mixer)
        f.b.setAttribute(wrapper, kAXWindowAttribute as String, f.window)
        f.b.setAttribute(f.root, kAXWindowAttribute as String, f.window)
        f.b.setFrame(f.root, x: 20, y: 100, width: 230, height: 175)
        // This wrapper deliberately leaves the root outside Mixer AXChildren.
        f.outputMenuWrapper = wrapper
        f.popupFrame = CGRect(x: 20, y: 100, width: 230, height: 175)
        switch fault {
        case "not_frontmost": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        case "wrong_window": f.b.setAttribute(wrapper, kAXWindowAttribute as String, f.b.element(291_961))
        case "wrong_mixer": f.b.setAttribute(wrapper, kAXParentAttribute as String, f.b.element(291_961))
        case "frame_disagrees": f.b.setFrame(f.root, x: 21, y: 100, width: 230, height: 175)
        case "nonreciprocal_root":
            f.onChildrenResultRead = { node in
                if CFEqual(node, wrapper) { f.b.setChildren(wrapper, []) }
            }
        case "contradictory_marks": f.b.setAttribute(p.leaf, kAXTitleAttribute as String, "Bus 2 ← Audio 2")
        case "unread_mark":
            f.attributeReadResult = { node, attribute in
                if CFEqual(node, p.leaf), attribute == "AXMenuItemMarkChar" {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            }
        case "unread_frontmost":
            f.attributeReadResult = { node, attribute in
                if CFEqual(node, f.app), attribute == kAXFrontmostAttribute as String { return .success(nil) }
                return nil
            }
        default: break
        }
        if fault == "foreign_popup" || fault == "duplicate_popup" {
            f.onChildrenResultRead = { node in
                guard CFEqual(node, f.mixer), !f.mutations.isEmpty else { return }
                let popup: [String: Any] = [kCGWindowOwnerPID as String: fault == "foreign_popup" ? f.pid + 1 : f.pid,
                    kCGWindowNumber as String: 291_901,
                    kCGWindowLayer as String: LogicOnScreenWindows.popupMenuLevel,
                    kCGWindowBounds as String: CGRect(x: 20, y: 100, width: 230, height: 175).dictionaryRepresentation]
                f.popupWindowsOverride = [popup]
                if fault == "duplicate_popup" {
                    var other = popup
                    other[kCGWindowNumber as String] = 291_902
                    f.popupWindowsOverride?.append(other)
                }
            }
        }
        f.outputHitTest = { app, point in
            #expect(CFEqual(app, f.app))
            #expect(point == CGPoint(x: 135, y: 187.5))
            switch fault {
            case "source_changed": f.reorder([1])
            case "document_changed": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
            case "foreign_focus": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
            default: break
            }
            return .success(p.echo)
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let base = f.logic
        let runtime: AXLogicProElements.Runtime
        if fault == "preexisting_foreign_focus" || fault == "unread_focus" {
            runtime = .init(logicProPID: base.logicProPID, ax: base.ax,
                onScreenWindowList: base.onScreenWindowList,
                focusedApplicationPID: { fault == "preexisting_foreign_focus" ? f.pid + 1 : nil })
        } else { runtime = base }
        let reading = await AXMixerStripBinding.$current.withValue(binding) {
            if internalReader {
                return await AccessibilityChannel.getCheckedInputObservation(runtime: runtime, timing: .immediate)
            }
            return await AccessibilityChannel.getInputBusObservation(runtime: runtime, timing: .immediate)
        }
        let body = try #require(sharedJSONObject(reading.result.message))
        if fault != "owned" {
            #expect(body["state"] as? String == "C")
            #expect(reading.assignment == nil)
            #expect(reading.inputSlot == nil)
            let writeAttempted = try #require(body["write_attempted"] as? Bool)
            #expect(!writeAttempted)
            let expectedActions = ["preexisting_foreign_focus", "unread_focus", "not_frontmost", "unread_frontmost"].contains(fault) ? 0 : 1
            #expect(f.mutations.count == expectedActions)
            #expect(f.mutations.allSatisfy { CFEqual($0.0, f.outputs[0]) && $0.1 == kAXPressAction as String })
            return
        }
        #expect(body["state"] as? String == "A")
        #expect(reading.assignment == .bus(1))
        let inputSlot = try #require(reading.inputSlot)
        #expect(inputSlot.owner.matches(binding))
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(body["output_checkmark_reads_observed"] as? Int == 2)
        let readsAgree = try #require(body["output_checkmark_reads_agree"] as? Bool)
        #expect(readsAgree)
        #expect(f.mutations.count == 2)
        #expect(CFEqual(f.mutations.first!.0, f.outputs[0]))
        #expect(f.mutations.first!.1 == kAXPressAction as String)
        #expect(CFEqual(f.mutations.last!.0, f.root))
        #expect(f.mutations.last!.1 == kAXCancelAction as String)
    }

    private func prepareInputDomain(_ kind: String) throws -> (Prepared, InputAssignment) {
        let p = try prepare(), f = p.f
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
        let neutral = f.b.element(291_947)
        let expected: InputAssignment
        switch kind {
        case "mono", "stereo":
            let title = kind == "mono" ? "Input 1" : "Input 1-2"
            f.b.setAttribute(p.echo, kAXTitleAttribute as String, title)
            f.b.setAttribute(p.inputLeaf, kAXTitleAttribute as String, title)
            f.b.setAttribute(p.leaf, "AXMenuItemMarkChar", "")
            f.b.setAttribute(p.inputLeaf, "AXMenuItemMarkChar", "✓")
            expected = .physical(kind == "mono" ? [1] : [1, 2])
        case "no_input":
            f.b.setAttribute(p.leaf, "AXMenuItemMarkChar", "")
            f.b.setAttribute(neutral, "AXMenuItemMarkChar", "✓")
            f.b.setChildren(f.root, [neutral, f.b.element(291_944), f.b.element(291_942)])
            expected = .noInput
        default: expected = .bus(1)
        }
        return (p, expected)
    }

    @Test("Checked input facts distinguish mono, stereo, no-input and Bus without widening the bus-only facade",
          arguments: ["mono", "stereo", "no_input", "bus"])
    func checkedInputDomainKeepsNonBusKindsDistinct(kind: String) throws {
        let (p, expected) = try prepareInputDomain(kind), f = p.f
        #expect(AccessibilityChannel.currentInputMenuAssignment(in: f.root, runtime: f.logic.ax) == expected)
        if kind == "bus" {
            #expect(AccessibilityChannel.currentInputMenuBusAssignment(in: f.root, runtime: f.logic.ax) == 1)
        } else {
            #expect(AccessibilityChannel.currentInputMenuBusAssignment(in: f.root, runtime: f.logic.ax) == nil)
        }
        #expect(f.mutations.isEmpty)
    }

    @Test("The owned internal input reader retains qualified non-Bus facts without publishing them through the bus-only facade",
          arguments: ["mono", "stereo", "no_input"])
    func ownedNonBusInputFactsStayPrivate(kind: String) async throws {
        let (p, expected) = try prepareInputDomain(kind), f = p.f
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let reading = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getCheckedInputObservation(runtime: f.logic, timing: .immediate)
        }
        #expect(reading.inputAssignment == expected)
        #expect(reading.assignment == nil)
        let body = try #require(sharedJSONObject(reading.result.message))
        #expect(body["state"] as? String == "C", "the wire facet remains bus-only")
        #expect(body["current_input"] == nil)
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(f.mutations.count == 2)
        #expect(f.mutations.last?.1 == kAXCancelAction as String)
    }

    @Test("Owned input/output/Send reads retain current stopped controls, never changed or detached transport",
          arguments: ["input", "output", "send"], ["owned", "play_started", "record_started", "play_unread", "play_replaced",
              "bar_reparented", "gate_revoked", "post_close_competing_bar", "late_transport",
              "post_close_duplicate_play", "post_close_duplicate_record", "post_close_relabelled_play", "cancel_after_open"])
    func ownedInputPopupRetainsStoppedTransport(domain: String, fault: String) async throws {
        let (p, expected) = try prepareInputDomain("mono"), f = p.f
        if domain != "input" {
            f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "Stereo Output")
            f.b.setAttribute(f.outputs[0], kAXHelpAttribute as String, "Output slot. Choose the channel strip output.")
            f.b.setAttribute(p.echo, kAXTitleAttribute as String, "Stereo Output")
            f.b.setAttribute(p.inputLeaf, kAXTitleAttribute as String, "Stereo Output")
            f.b.setAttribute(f.b.element(291_944), kAXTitleAttribute as String, "Output")
            #expect(AccessibilityChannel.currentOutputMenuAssignment(in: f.root, runtime: f.logic.ax) == .stereoOutput)
        }
        if domain == "send" {
            let anchor = f.b.element(291_9900), group = f.b.element(291_9901)
            let bypass = f.b.element(291_9902), knob = f.b.element(291_9903), mode = f.b.element(291_9904)
            f.b.setButton(anchor, description: "send button", help: "Send slot. Route signal.",
                x: 0, y: 0, width: 1, height: 1)
            f.b.setChildren(anchor, [])
            f.b.setRole(group, kAXGroupRole as String)
            f.b.setAttribute(group, kAXDescriptionAttribute as String, "Stereo Output")
            f.b.setRole(bypass, kAXCheckBoxRole as String)
            f.b.setAttribute(bypass, kAXValueAttribute as String, 0)
            f.b.setChildren(bypass, [])
            f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "list")
            f.b.removeAttribute(f.outputs[0], kAXHelpAttribute as String)
            f.b.setChildren(group, [bypass, f.outputs[0]])
            f.b.setRole(knob, kAXSliderRole as String)
            f.b.setAttribute(knob, kAXHelpAttribute as String, "Send Level knob. Set level.")
            f.b.setAttribute(knob, kAXValueAttribute as String, 0)
            f.b.setChildren(knob, [])
            f.b.setChildren(f.strips[0], [anchor, group, knob])
            f.b.setRole(mode, kAXMenuItemRole as String)
            f.b.setAttribute(mode, kAXTitleAttribute as String, "Post Fader")
            f.b.setAttribute(mode, "AXMenuItemMarkChar", "✓")
            f.b.setChildren(mode, [])
            f.b.setChildren(f.root, f.logic.ax.children(f.root) + [mode])
        }
        let base = f.logic
        let play = f.b.element(2_910_301), record = f.b.element(2_910_302), bar = f.b.element(2_910_300)
        defer { f.onChildrenResultRead = nil; f.attributeReadResult = nil }
        f.attributeReadResult = { node, attribute in
            guard CFEqual(node, play), attribute == kAXValueAttribute as String else { return nil }
            if fault == "play_unread", !f.mutations.isEmpty {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            if fault == "late_transport", f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                f.b.setAttribute(play, attribute, 1)
            }
            return nil
        }
        f.onChildrenResultRead = { node in
            if ["post_close_duplicate_play", "post_close_duplicate_record", "post_close_relabelled_play"].contains(fault),
               CFEqual(node, f.window), f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                let replacement = f.b.element(291_974)
                let label = fault == "post_close_duplicate_record" ? "Record" : "Play"
                f.b.setRole(replacement, kAXCheckBoxRole as String)
                f.b.setAttribute(replacement, kAXTitleAttribute as String, label)
                f.b.setAttribute(replacement, kAXDescriptionAttribute as String, label)
                f.b.setAttribute(replacement, kAXValueAttribute as String, 1)
                f.b.setChildren(replacement, [])
                if fault == "post_close_relabelled_play" { f.b.setAttribute(play, kAXDescriptionAttribute as String, "Cycle") }
                let controls = base.ax.children(bar)
                if !controls.contains(where: { CFEqual($0, replacement) }) { f.b.setChildren(bar, controls + [replacement]) }
            }
            if fault == "post_close_competing_bar", CFEqual(node, f.window),
               f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                let other = f.b.element(291_970), otherPlay = f.b.element(291_971), otherRecord = f.b.element(291_972)
                f.b.setRole(other, kAXGroupRole as String)
                f.b.setAttribute(other, kAXDescriptionAttribute as String, "Control Bar")
                for (control, label) in [(otherPlay, "Play"), (otherRecord, "Record")] {
                    f.b.setRole(control, kAXCheckBoxRole as String)
                    f.b.setAttribute(control, kAXDescriptionAttribute as String, label)
                    f.b.setAttribute(control, kAXValueAttribute as String, 0)
                    f.b.setChildren(control, [])
                }
                f.b.setChildren(other, [otherPlay, otherRecord])
                let current = base.ax.children(f.window)
                if !current.contains(where: { CFEqual($0, other) }) { f.b.setChildren(f.window, current + [other]) }
            }
            guard CFEqual(node, f.root), !f.mutations.isEmpty else { return }
            switch fault {
            case "play_started": f.b.setAttribute(play, kAXValueAttribute as String, 1)
            case "record_started": f.b.setAttribute(record, kAXValueAttribute as String, 1)
            case "play_replaced":
                let replacement = f.b.element(291_973)
                f.b.setRole(replacement, kAXCheckBoxRole as String)
                f.b.setAttribute(replacement, kAXDescriptionAttribute as String, "Play")
                f.b.setAttribute(replacement, kAXValueAttribute as String, 0)
                f.b.setChildren(replacement, [])
                f.b.setChildren(bar, [replacement, record])
            case "bar_reparented": f.b.setChildren(f.window, base.ax.children(f.window).filter { !CFEqual($0, bar) })
            default: break
            }
        }
        let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
            attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
            children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
            actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
            childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
            performActionResult: base.ax.performActionResult, elementAtPosition: base.ax.elementAtPosition,
            attributeValuesResult: { node, attributes in
                // Measured native failure: the popup is readable individually,
                // but the whole-window Role/Children batch returns AXFailure.
                if CFEqual(node, f.root), attributes == [kAXRoleAttribute as String, kAXChildrenAttribute as String] {
                    return .failure(.init(raw: AXError.failure.rawValue))
                }
                return .success(attributes.map { attribute in
                    if attribute == kAXChildrenAttribute as String { return base.ax.children(node) as NSArray }
                    return base.ax.attributeValue(node, attribute) ?? NSNull()
                })
            })
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: ax,
            onScreenWindowList: base.onScreenWindowList, focusedApplicationPID: base.focusedApplicationPID)
        let owner = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) && (fault != "gate_revoked" || f.mutations.isEmpty) },
            cancellationRequested: { fault == "cancel_after_open" && !f.mutations.isEmpty })
        let reading = await OperationTraceContext.$current.withValue(context) {
            await AXMixerStripBinding.$current.withValue(owner) {
                if domain == "input" {
                    return await AccessibilityChannel.getCheckedInputObservation(runtime: runtime, timing: .immediate)
                }
                return await AccessibilityChannel.getOutputObservation(runtime: runtime,
                    sendOrdinal: domain == "send" ? 1 : nil, timing: .immediate)
            }
        }
        if fault != "owned" {
            #expect(reading.inputAssignment == nil)
            #expect(reading.assignment == nil)
            #expect(f.mutations.allSatisfy { $0.1 == kAXPressAction as String || $0.1 == kAXCancelAction as String })
            if fault.hasPrefix("post_close_") || fault == "late_transport" {
                #expect(f.mutations.last?.1 == kAXCancelAction as String)
            }
            if fault == "cancel_after_open", domain == "output" {
                let body = try #require(sharedJSONObject(reading.result.message))
                #expect(body["error"] as? String == "cancelled")
                #expect(body["popup_menu_state"] as? String == "closed")
                #expect(f.mutations.last?.1 == kAXCancelAction as String)
            }
            return
        }
        if domain == "input" { #expect(reading.inputAssignment == expected) }
        else { #expect(reading.assignment == .stereoOutput) }
        let body = try #require(sharedJSONObject(reading.result.message))
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(f.mutations.count == 2)
        #expect(f.mutations.last?.1 == kAXCancelAction as String)
    }

    @Test("Input cleanup can renew a redrawn stopped transport only in the exact source window",
          arguments: ["stopped", "stopped_no_held", "stopped_no_held_transient_scalar",
                      "final_document", "duplicate", "foreign", "unreadable", "playing", "recording"])
    func inputCleanupReobservesRedrawnStoppedTransport(_ state: String) async throws {
        final class Probe: @unchecked Sendable {
            var redrawn = false
            var freshPlayReads = 0
            var postFreshStripReads = 0
            var finalDriftInjected = false
        }
        let p = try prepare(1), f = p.f, probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let oldBar = f.b.element(2_910_300)
        let newBar = f.b.element(291_975), newPlay = f.b.element(291_976)
        let newRecord = f.b.element(291_977), duplicatePlay = f.b.element(291_978)
        f.b.setRole(newBar, kAXGroupRole as String)
        f.b.setAttribute(newBar, kAXDescriptionAttribute as String, "Control Bar")
        for (control, label) in [(newPlay, "Play"), (newRecord, "Record"), (duplicatePlay, "Play")] {
            f.b.setRole(control, kAXCheckBoxRole as String)
            f.b.setAttribute(control, kAXDescriptionAttribute as String, label)
            f.b.setAttribute(control, kAXValueAttribute as String,
                (state == "playing" && CFEqual(control, newPlay))
                    || (state == "recording" && CFEqual(control, newRecord)) ? 1 : 0)
            f.b.setChildren(control, [])
        }
        f.b.setChildren(newBar, state == "duplicate"
            ? [newPlay, duplicatePlay, newRecord] : [newPlay, newRecord])
        f.attributeReadResult = { node, attribute in
            if ["stopped_no_held_transient_scalar", "final_document"].contains(state), probe.redrawn,
               CFEqual(node, newPlay), attribute == kAXValueAttribute as String {
                probe.freshPlayReads += 1
                if probe.freshPlayReads <= 4 {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
            }
            if state == "unreadable", CFEqual(node, newPlay),
               attribute == kAXValueAttribute as String {
                return .failure(.init(raw: AXError.cannotComplete.rawValue))
            }
            return nil
        }
        f.onChildrenResultRead = { node in
            if state == "final_document", probe.freshPlayReads >= 5, CFEqual(node, f.strips[0]) {
                probe.postFreshStripReads += 1
                if probe.postFreshStripReads == 8 {
                    probe.finalDriftInjected = true
                    f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
                }
            }
            guard !probe.redrawn, CFEqual(node, f.mixer),
                  f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) else { return }
            probe.redrawn = true
            let retained = f.logic.ax.children(f.window).filter { !CFEqual($0, oldBar) }
            f.b.setChildren(f.window, state == "foreign" ? retained : retained + [newBar])
        }
        let base = f.logic
        let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
            attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
            children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
            actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
            childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
            performActionResult: base.ax.performActionResult, elementAtPosition: base.ax.elementAtPosition,
            attributeValuesResult: { node, attributes in
                .success(attributes.map { attribute in
                    if attribute == kAXChildrenAttribute as String { return base.ax.children(node) as NSArray }
                    return base.ax.attributeValue(node, attribute) ?? NSNull()
                })
            })
        let runtime = state.hasPrefix("stopped_no_held") || state == "final_document" ? base : AXLogicProElements.Runtime(
            logicProPID: base.logicProPID, ax: ax, onScreenWindowList: base.onScreenWindowList,
            focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getInputBusVerified(runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        #expect(probe.redrawn)
        if state == "final_document" { #expect(probe.finalDriftInjected) }
        let succeeds = state.hasPrefix("stopped")
        #expect(body["state"] as? String == (succeeds ? "A" : "C"), "\(body)")
        #expect((body["current_input"] as? [String: Any])?["number"] as? Int ==
            (succeeds ? 1 : nil))
        #expect(body["popup_menu_state"] as? String == "closed")
        let receipt = try #require(body["input_transport_fallback"] as? [String: Any])
        #expect(receipt["held_transport_captured"] as? Bool ==
            !(state.hasPrefix("stopped_no_held") || state == "final_document"))
        if state == "stopped_no_held" {
            #expect(receipt["fallback_attempted"] as? Bool == false)
        } else {
            #expect(receipt["fallback_attempted"] as? Bool == true)
            #expect(receipt["held_transport_matched"] as? Bool == false)
        }
        if (state.hasPrefix("stopped") && state != "stopped_no_held") || state == "final_document" {
            #expect(receipt["fresh_transport"] as? String == "stopped")
            #expect(receipt["first_failed_checkpoint"] as? String == "none")
        }
        if state == "playing" || state == "recording" {
            #expect(receipt["fresh_transport"] as? String == state)
            #expect(receipt["first_failed_checkpoint"] as? String == "fresh_transport")
        }
        #expect(f.mutations.count == 2)
        #expect(f.mutations.first?.1 == kAXPressAction as String)
        #expect(f.mutations.last?.1 == kAXCancelAction as String)
    }

    @Test("A transient post-close source miss cannot let a matching held transport suppress fresh recovery")
    func matchingHeldTransportStillRunsFreshFallbackAfterTransientSourceMiss() async throws {
        final class Probe: @unchecked Sendable { var sourceRetired = false; var sourceRestored = false }
        let p = try prepare(1), f = p.f, probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        f.onChildrenResultRead = { node in
            guard !probe.sourceRetired, CFEqual(node, f.mixer),
                  f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) else { return }
            probe.sourceRetired = true
            f.b.setChildren(f.mixer, [f.strips[1]])
        }
        let base = f.logic
        let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
            attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
            children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
            actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
            childrenResult: base.ax.childrenResult, attributeValueResult: base.ax.attributeValueResult,
            performActionResult: base.ax.performActionResult, elementAtPosition: base.ax.elementAtPosition,
            attributeValuesResult: { node, attributes in
                if probe.sourceRetired, !probe.sourceRestored,
                   f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                    probe.sourceRestored = true
                    f.b.setChildren(f.mixer, f.strips)
                }
                return .success(attributes.map { attribute in
                    if attribute == kAXChildrenAttribute as String { return base.ax.children(node) as NSArray }
                    return base.ax.attributeValue(node, attribute) ?? NSNull()
                })
            })
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: ax,
            onScreenWindowList: base.onScreenWindowList, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getInputBusVerified(runtime: runtime, timing: .immediate)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        let receipt = try #require(body["input_transport_fallback"] as? [String: Any])
        #expect(probe.sourceRetired && probe.sourceRestored)
        #expect(receipt["held_transport_captured"] as? Bool == true)
        #expect(receipt["held_transport_matched"] as? Bool == true)
        #expect(receipt["fallback_attempted"] as? Bool == true, "\(body)")
        #expect(receipt["fresh_transport"] as? String == "stopped")
        #expect(receipt["first_failed_checkpoint"] as? String == "none")
        #expect(body["state"] as? String == "A", "\(body)")
        #expect((body["current_input"] as? [String: Any])?["number"] as? Int == 1)
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
    }

    @Test("Input fresh fallback settles one transient stopped-transport AX failure within its readback deadline")
    func inputFreshFallbackRetriesOneTransientTransportRead() async throws {
        final class Probe: @unchecked Sendable {
            var sourceRetired = false
            var sourceRestored = false
            var postRestorePlayValueReads = 0
            var injectedFailure = false
        }
        let p = try prepare(1), f = p.f, probe = Probe()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        f.onChildrenResultRead = { node in
            guard !probe.sourceRetired, CFEqual(node, f.mixer),
                  f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) else { return }
            probe.sourceRetired = true
            f.b.setChildren(f.mixer, [f.strips[1]])
        }
        let base = f.logic
        let controlBar = try #require(base.ax.children(f.window).first {
            AXHelpers.getAttribute($0, kAXDescriptionAttribute as String, runtime: base.ax) as String? == "Control Bar"
        })
        let play = try #require(base.ax.children(controlBar).first {
            AXHelpers.getAttribute($0, kAXDescriptionAttribute as String, runtime: base.ax) as String? == "Play"
        })
        let ax = AXHelpers.Runtime(axApp: base.ax.axApp, attributeValue: base.ax.attributeValue,
            attributeIsSettable: base.ax.attributeIsSettable, setAttributeValue: base.ax.setAttributeValue,
            children: base.ax.children, performAction: base.ax.performAction, childCount: base.ax.childCount,
            actionNames: base.ax.actionNames, actionNamesResult: base.ax.actionNamesResult,
            childrenResult: base.ax.childrenResult,
            attributeValueResult: { node, attribute in
                if probe.sourceRestored, CFEqual(node, play), attribute == kAXValueAttribute as String {
                    probe.postRestorePlayValueReads += 1
                    if probe.postRestorePlayValueReads == 1 {
                        probe.injectedFailure = true
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                }
                return base.ax.attributeValueResult?(node, attribute)
                    ?? .success(base.ax.attributeValue(node, attribute))
            },
            performActionResult: base.ax.performActionResult, elementAtPosition: base.ax.elementAtPosition,
            attributeValuesResult: { node, attributes in
                if probe.sourceRetired, !probe.sourceRestored,
                   f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                    probe.sourceRestored = true
                    f.b.setChildren(f.mixer, f.strips)
                }
                return .success(attributes.map { attribute in
                    if attribute == kAXChildrenAttribute as String { return base.ax.children(node) as NSArray }
                    return base.ax.attributeValue(node, attribute) ?? NSNull()
                })
            })
        let runtime = AXLogicProElements.Runtime(logicProPID: base.logicProPID, ax: ax,
            onScreenWindowList: base.onScreenWindowList, focusedApplicationPID: base.focusedApplicationPID)
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let timing = AccessibilityChannel.OutputAssignmentTiming(
            popupOpenTimeoutMs: 0, popupCloseTimeoutMs: 0,
            readbackTimeoutMs: 100, pollIntervalMs: 0)
        let result = await OperationTraceContext.$current.withValue(.init(mutationGateAcquired: true)) {
            await AXMixerStripBinding.$current.withValue(binding) {
                await AccessibilityChannel.getInputBusVerified(runtime: runtime, timing: timing)
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        let receipt = try #require(body["input_transport_fallback"] as? [String: Any])
        #expect(probe.sourceRetired && probe.sourceRestored && probe.injectedFailure)
        #expect(probe.postRestorePlayValueReads >= 2)
        #expect(receipt["held_transport_matched"] as? Bool == true)
        #expect(receipt["fallback_attempted"] as? Bool == true)
        #expect(receipt["fresh_transport"] as? String == "stopped")
        #expect(body["state"] as? String == "A", "\(body)")
        #expect((body["current_input"] as? [String: Any])?["number"] as? Int == 1)
        #expect(f.mutations.map(\.1) == [kAXPressAction as String, kAXCancelAction as String])
    }

    @Test("A checked non-Bus menu cannot retain input facts after original source, document or label custody is lost",
          arguments: ["source", "document", "label"])
    func nonBusInputFactsRequireFinalSourceCustody(fault: String) async throws {
        let (p, _) = try prepareInputDomain("stereo"), f = p.f
        f.onActionNamesRead = { node in
            guard CFEqual(node, f.root) else { return }
            f.onActionNamesRead = nil
            switch fault {
            case "source": f.reorder([1])
            case "document": f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
            case "label": f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, "Input 3-4")
            default: Issue.record("unhandled custody fault")
            }
        }
        let binding = AXMixerStripBinding.Binding(window: f.window, mixer: f.mixer,
            strip: f.strips[0], document: f.bundle.absoluteString)
        let reading = await AXMixerStripBinding.$current.withValue(binding) {
            await AccessibilityChannel.getCheckedInputObservation(runtime: f.logic, timing: .immediate)
        }
        #expect(reading.inputAssignment == nil)
        #expect(reading.assignment == nil)
        #expect(f.mutations.count == 1)
    }

    @Test("A physical input needs agreeing checked root and Input leaf, never output aliases or a competing route",
          arguments: ["output_alias", "neutral_output_alias", "missing_echo", "conflicting_bus",
                      "mismatched_leaf", "wrong_parent", "duplicate_echo", "unknown_mark"])
    func checkedNonBusInputRejectsContradictions(fault: String) throws {
        let p = try prepare(), f = p.f
        f.b.setAttribute(p.echo, kAXTitleAttribute as String, "Input 1-2")
        f.b.setAttribute(p.leaf, "AXMenuItemMarkChar", "")
        f.b.setAttribute(p.inputLeaf, "AXMenuItemMarkChar", "✓")
        switch fault {
        case "output_alias": f.b.setAttribute(p.echo, kAXTitleAttribute as String, "Output 1-2")
        case "neutral_output_alias": f.b.setAttribute(p.echo, kAXTitleAttribute as String, "No Output")
        case "missing_echo": f.b.setAttribute(p.echo, "AXMenuItemMarkChar", "")
        case "conflicting_bus": f.b.setAttribute(p.leaf, "AXMenuItemMarkChar", "✓")
        case "mismatched_leaf": f.b.setAttribute(p.inputLeaf, kAXTitleAttribute as String, "Input 3-4")
        case "wrong_parent":
            f.b.setChildren(f.b.element(291_943), [p.inputLeaf])
            f.b.setChildren(f.b.element(291_945), [])
        case "duplicate_echo":
            let duplicate = f.b.element(291_948)
            f.b.setRole(duplicate, kAXMenuItemRole as String)
            f.b.setAttribute(duplicate, kAXTitleAttribute as String, "Input 1-2")
            f.b.setAttribute(duplicate, "AXMenuItemMarkChar", "✓")
            f.b.setChildren(duplicate, [])
            f.b.setChildren(f.root, f.logic.ax.children(f.root) + [duplicate])
        case "unknown_mark": f.b.setAttribute(p.inputLeaf, "AXMenuItemMarkChar", "?")
        default: Issue.record("unhandled input counterexample")
        }
        #expect(AccessibilityChannel.currentInputMenuAssignment(in: f.root, runtime: f.logic.ax) == nil)
        #expect(AccessibilityChannel.currentInputMenuBusAssignment(in: f.root, runtime: f.logic.ax) == nil)
        #expect(f.mutations.isEmpty)
    }

    @Test(arguments: ["healthy", "selected", "selected_no_type", "selected_no_checked_input", "selected_changed_input",
        "selected_wrong_project", "selected_unread_checked_input", "selected_not_restored",
        "two_same_name", "no_type", "no_checked_input", "ambiguous_input", "changed_input",
        "changed_input_control", "changed_label_control", "changed_label", "changed_source", "wrong_project", "wrong_registry",
        "foreign_editor", "unread_checked_input", "not_restored"])
    func registeredKeepRechecksTheCapturedAuxWithoutChangingRouting(fault requestedFault: String) async throws {
        let selectedScope = requestedFault == "selected" || requestedFault.hasPrefix("selected_")
        let fault = requestedFault == "selected" ? "healthy"
            : selectedScope ? String(requestedFault.dropFirst("selected_".count)) : requestedFault
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            try await FeatureFlags.withAdr004MutationSagaForTests(true) {
                let p = try prepare(), f = p.f, b = f.b
                defer { try? FileManager.default.removeItem(at: f.bundle) }
                let label = b.element(967_901)
                b.setRole(label, kAXStaticTextRole as String)
                b.setAttribute(label, kAXDescriptionAttribute as String, "label")
                b.setAttribute(label, kAXValueAttribute as String, "Aux 7")
                b.setChildren(label, [])
                if fault != "no_type" { b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]) + [label]) }
                if ["two_same_name", "ambiguous_input"].contains(fault) {
                    let second = b.element(967_902)
                    if fault == "two_same_name" {
                        b.setRole(second, kAXStaticTextRole as String)
                        b.setAttribute(second, kAXDescriptionAttribute as String, "label")
                        b.setAttribute(second, kAXValueAttribute as String, "Aux 9")
                        b.setChildren(second, [])
                        b.setChildren(f.strips[1], b.makeAXRuntime().children(f.strips[1]) + [second])
                        b.setAttribute(f.outputs[1], kAXHelpAttribute as String, "Input slot. Choose the channel strip input source.")
                        b.setAttribute(f.outputs[1], kAXDescriptionAttribute as String, "Bus 256")
                        b.setActionNames(f.outputs[1], [kAXPressAction as String])
                        for nameID in [2_910_104, 2_910_114] { b.setAttribute(b.element(nameID), kAXValueAttribute as String, "Same") }
                    } else {
                        b.setButton(second, description: "Bus 256", help: "Input slot. Choose the channel strip input source.",
                            x: 0, y: 0, width: 1, height: 1)
                        b.setChildren(second, [])
                        b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]) + [second])
                    }
                }
                let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter(), journal = SagaJournal()
                let gate = LogicMutationGate(), channel = f.channel()
                await router.register(channel)
                let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                    poller: StatePoller(axChannel: channel, cache: cache, runtime: .init(hasVisibleWindow: { true },
                        projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                    dialogPresent: { false }, supportBundleExporter: nil, sagaJournal: journal,
                    mutationGate: gate, liveTrackNames: { [:] }, projectFileReader: .unavailable)
                func call(_ command: String, _ params: [String: Value]) async throws -> [String: Any] {
                    let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: command))
                    #expect(LogicProServer.strictParamValidationResult(tool: "logic_project", command: command, params: params) == nil)
                    let execution = LogicProServer.sagaExecutionOwnsLifecycle(tool: "logic_project", command: command)
                    let lifecycle = execution ? ContinuousClock.now.advanced(by: .seconds(
                        LogicProServer.commandDeadlineSeconds(tool: "logic_project", command: command))) : nil
                    let scoped = lifecycle.map { dependencies.withSagaLifecycleDeadline($0) } ?? dependencies
                    let response = await LogicProServer.runWithDeadline(tool: "logic_project", command: command,
                        commandParams: params,
                        outerAbsoluteDeadline: lifecycle.map { LogicProServer.sagaOuterAbsoluteDeadline(lifecycleDeadline: $0) },
                        mutationGate: execution ? nil : gate, externallyManagedMutation: execution) {
                        await FeatureFlags.withAdr002TargetRefForTests(true) {
                            await FeatureFlags.withAdr004MutationSagaForTests(true) { await handler(scoped, params) }
                        }
                    }
                    return try #require(sharedJSONObject(sharedToolText(response)))
                }
                if selectedScope {
                    b.setAttribute(f.mixer, kAXSelectedChildrenAttribute as String, [f.strips[0]])
                    b.setAttribute(f.strips[0], kAXSelectedAttribute as String, true)
                }
                let inspected = try await call("inspect_session", ["domains": .array([.string("strips"), .string("routing")]),
                    "scope": .string(selectedScope ? "selection" : "whole_project"),
                    "allow_ui_navigation": .bool(fault != "no_checked_input")])
                let project = try #require((inspected["project"] as? [String: Any])?["project_ref"] as? String)
                let snapshot = try #require(inspected["snapshot_id"] as? String)
                let routing = try #require(inspected["routing"] as? [String: Any])
                let nodes = try #require(routing["nodes"] as? [[String: Any]])
                let receivers = nodes.filter { $0["kind"] as? String == "aux" }.compactMap {
                    ($0["targetRef"] as? [String: Any])?["rawValue"] as? String
                }
                let edges = try #require(routing["edges"] as? [[String: Any]])
                let incomplete = ["no_type", "no_checked_input", "ambiguous_input"].contains(fault)
                if !incomplete {
                    #expect(receivers.count == (fault == "two_same_name" ? 2 : 1))
                    for receiver in receivers {
                        #expect(edges.contains { $0["kind"] as? String == "inputAssignment" && $0["source"] as? String == "bus_1"
                            && $0["destination"] as? String == receiver })
                    }
                }
                #expect(routing["coverage"] as? String == "partial")
                if fault == "healthy" {
                    let retained = try #require(await cache.retainedInspection(id: snapshot))
                    guard case .accepted(let policy) = ProjectSessionAudit.parseIntentPolicy([
                        "schema": .string(ProjectSessionAudit.intentPolicySchema), "project_ref": .string(project),
                        "targets": .array([]), "receivers": .array([.object(["bus": .int(1), "aux": .string("keep")])])
                    ]) else { Issue.record("The observed-receiver policy must parse"); return }
                    #expect(ApprovedSessionRepair.capturedReceiverKeepObservations(policy: policy,
                        source: retained.capture, request: retained.request) != nil)
                    // Even native-looking cached rows cannot replace this invocation's fresh proof.
                    #expect(ApprovedSessionRepair.capturedReceiverKeepObservations(policy: policy,
                        source: inputCapture(retained.capture, fresh: nil), request: retained.request) == nil)
                }
                let plan = try await call("plan_session_repair", ["snapshot_id": .string(snapshot), "policy": .object([
                    "schema": .string(ProjectSessionAudit.intentPolicySchema), "project_ref": .string(project),
                    "targets": .array([]), "receivers": .array([.object(["bus": .int(1), "aux": .string("keep")])])])])
                let executable = try #require(plan["executable"] as? Bool)
                if incomplete { #expect(!executable); return }
                #expect(executable, "Actual captured Aux-kind + checked input should support KEEP: \(plan)")
                guard executable else { return }
                let steps = try #require(plan["steps"] as? [Any])
                #expect(steps.isEmpty)
                let arguments: [String: Value] = ["plan_id": .string(try #require(plan["plan_id"] as? String)),
                    "digest": .string(try #require(plan["digest"] as? String)), "confirmed": .bool(true),
                    "idempotency_key": .string("keep-native-aux")]
                let readsBefore = f.mutations.count
                let observations = try #require(plan["existing_receiver_observations"] as? [[String: Any]])
                let observation = try #require(observations.first)
                #expect(observation["namespace_availability"] as? String == "not_observed")
                #expect(observation["scope"] as? String == "approved_observed_receivers")
                let exhaustive = try #require(observation["exhaustive"] as? Bool)
                #expect(!exhaustive)
                let candidates = try #require(observation["candidates"] as? [[String: Any]])
                #expect(Set(candidates.compactMap { $0["target_ref"] as? String }) == Set(receivers))
                if fault == "changed_input" {
                    for item in [p.echo, p.leaf] { b.setAttribute(item, kAXTitleAttribute as String, "Bus 2 ← Audio 2") }
                }
                if fault == "changed_label" { b.setAttribute(label, kAXValueAttribute as String, "Aux 2") }
                if fault == "changed_label_control" {
                    let replacement = b.element(967_903)
                    b.setRole(replacement, kAXStaticTextRole as String)
                    b.setAttribute(replacement, kAXDescriptionAttribute as String, "label")
                    b.setAttribute(replacement, kAXValueAttribute as String, "Aux 7")
                    b.setChildren(replacement, [])
                    b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]).map { CFEqual($0, label) ? replacement : $0 })
                }
                if fault == "changed_input_control" {
                    let replacement = b.element(967_904)
                    b.setButton(replacement, description: "Bus 256", help: "Input slot. Choose the channel strip input source.",
                        x: 0, y: 0, width: 1, height: 1)
                    b.setChildren(replacement, [])
                    b.setChildren(f.strips[0], b.makeAXRuntime().children(f.strips[0]).map { CFEqual($0, f.outputs[0]) ? replacement : $0 })
                }
                if fault == "changed_source" {
                    let replacement = b.element(967_905)
                    b.setRole(replacement, kAXLayoutItemRole as String)
                    b.setFrame(replacement, x: 0, y: 100, width: 80, height: 400)
                    b.setChildren(replacement, [])
                    b.setChildren(f.mixer, [replacement, f.strips[1]])
                }
                if fault == "wrong_project" { b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///tmp/foreign.logicx/") }
                if fault == "wrong_registry" { await registry.bumpProjectEpoch() }
                if fault == "foreign_editor" {
                    let field = b.element(967_906)
                    b.setRole(field, kAXTextFieldRole as String)
                    b.setAttribute(field, kAXWindowAttribute as String, f.window)
                    b.setAttribute(field, kAXValueAttribute as String, "editing")
                    b.setAttribute(field, kAXInsertionPointLineNumberAttribute as String, 0)
                    b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, field)
                }
                if fault == "unread_checked_input" {
                    f.attributeReadResult = { element, attribute in
                        CFEqual(element, p.leaf) && attribute == "AXMenuItemMarkChar"
                            ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
                    }
                }
                if fault == "not_restored" { b.setActionNames(f.root, []) }
                let result = try await call("apply_session_repair", arguments)
                if !["healthy", "two_same_name"].contains(fault) {
                    #expect(result["state"] as? String == "C", "\(result)")
                    let wrote = try #require(result["write_attempted"] as? Bool)
                    #expect(!wrote)
                    if ["changed_input", "unread_checked_input", "not_restored"].contains(fault) {
                        #expect(f.mutations.count > readsBefore, "Reach the actual checked reader after preview")
                    } else { #expect(f.mutations.count == readsBefore) }
                    if fault == "not_restored" {
                        let read = try #require(result["receiver_read_receipt"] as? [String: Any])
                        #expect(read["popup_menu_state"] as? String == "not_restored")
                    }
                    return
                }
                #expect(result["saga_state"] as? String == "completed", "Actual KEEP apply: \(result)")
                let verified = try #require(result["verified"] as? Bool)
                #expect(verified)
                let wrote = try #require(result["write_attempted"] as? Bool)
                #expect(!wrote)
                #expect(result["writes_performed"] as? Int == 0)
                let evidence = try #require(result["goal_evidence"] as? [[String: Any]])
                #expect(Set(evidence.compactMap { $0["target_ref"] as? String }) == Set(receivers))
                #expect(f.mutations.count > readsBefore, "Apply must independently reopen/check/close the exact input, not echo its capture")
                let countAfter = f.mutations.count
                let replay = try await call("apply_session_repair", arguments)
                let duplicate = try #require(replay["duplicate"] as? Bool)
                #expect(duplicate)
                #expect(f.mutations.count == countAfter)
                #expect(f.mutations.allSatisfy { element, action in
                    (action == kAXPressAction as String && f.outputs.contains { CFEqual($0, element) })
                        || (action == kAXCancelAction as String && CFEqual(element, f.root))
                })
                guard case .completed? = await journal.record(for: "keep-native-aux") else {
                    Issue.record("KEEP must finalize in the existing Saga journal"); return
                }
            }
        }
    }
    @Test("Input bus destinations follow the owning incoming-arrow menu, never its current echo",
          arguments: [1, 256])
    func inputDestinationChoiceUsesIncomingBusIdentity(_ number: Int) throws {
        let p = try prepare(number)
        // Exercise the existing structural selector with input semantics. An
        // incoming arrow is host bus identity, not a receiver-name join.
        let choice = AccessibilityChannel.outputMenuChoice(for: .bus(number),
            in: p.f.root, runtime: p.f.logic.ax, receiverArrow: "←")
        guard case .item(let selected, let path) = choice else {
            Issue.record("The unique offered input bus must be selectable: \(choice.failureLabel)")
            return
        }
        #expect(CFEqual(selected, p.leaf))
        #expect(!CFEqual(selected, p.echo))
        #expect(path == ["Bus", "Bus \(number) ← Audio 2"])
        #expect(p.f.mutations.isEmpty)
    }
    @Test("Input destination selection rejects opposite arrows and duplicate incoming choices",
          arguments: ["opposite_arrow", "duplicate", "physical_input"])
    func inputDestinationChoiceRefusesAmbiguousOrForeignChoices(_ fault: String) throws {
        let p = try prepare(1)
        if fault == "opposite_arrow" {
            p.f.b.setAttribute(p.leaf, kAXTitleAttribute as String, "Bus 1 → Audio 2")
        } else if fault == "duplicate" {
            let second = p.f.b.element(291_948)
            p.f.b.setRole(second, kAXMenuItemRole as String)
            p.f.b.setAttribute(second, kAXTitleAttribute as String, "Bus 1 ← Another receiver")
            p.f.b.setChildren(second, [])
            let busMenu = p.f.b.element(291_943)
            p.f.b.setChildren(busMenu, [p.leaf, second])
        } else {
            p.f.b.setAttribute(p.leaf, kAXTitleAttribute as String, "Input 1")
        }
        let choice = AccessibilityChannel.outputMenuChoice(for: .bus(1),
            in: p.f.root, runtime: p.f.logic.ax, receiverArrow: "←")
        if case .item = choice { Issue.record("Unknown or ambiguous input destinations must refuse") }
        #expect(p.f.mutations.isEmpty)
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
    @Test(arguments: [1, 256])
    func koreanInputAliasMustAgreeAcrossOwnedEchoAndBusLeaf(_ number: Int) async throws {
        let p = try prepare(number), title = "Bus \(number)  (버스 \(number))"
        for item in [p.echo, p.leaf] { p.f.b.setAttribute(item, kAXTitleAttribute as String, title) }
        p.f.b.setAttribute(p.f.b.element(291_942), kAXTitleAttribute as String, "버스")
        let choice = AccessibilityChannel.outputMenuChoice(for: .bus(number), in: p.f.root,
            runtime: p.f.logic.ax, receiverArrow: "←")
        if case .item(let leaf, _) = choice { #expect(CFEqual(leaf, p.leaf)) }
        else { Issue.record("The actual Korean input Bus leaf must be uniquely selectable: \(choice.failureLabel)") }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "A", "Actual Korean checked input: \(body)")
        #expect((body["current_input"] as? [String: Any])?["number"] as? Int == number)
        #expect(body["popup_menu_state"] as? String == "closed")
        #expect(p.f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
        #expect(OutputAssignment.busNumber(ofMenuItemTitle: title) == nil, "Output/send menus do not inherit input alias grammar")
        #expect(RoutingGraphPublication.classifyOutputLabel(title).0 == .unclassified)
    }

    @Test(arguments: ["Bus 1 (버스 2)", "Bus 1 (버스 1) (버스 1)", "Bus 1 (Receiver 1)",
                      "Bus 1 (버스 1", "Bus 1 ((버스 1))", "Bus 1 (버스 1) → Audio 2",
                      "Bus 257 (버스 257)", "Bus 1 (버스 1) extra", "Bus 1 (버스 one)",
                      "Bus 1 (버스 1) ← Audio 2 ← Audio 3"])
    func malformedInputAliasesCannotBecomeCheckedBusAuthority(_ title: String) async throws {
        let p = try prepare(1)
        for item in [p.echo, p.leaf] { p.f.b.setAttribute(item, kAXTitleAttribute as String, title) }
        let choice = AccessibilityChannel.outputMenuChoice(for: .bus(1), in: p.f.root,
            runtime: p.f.logic.ax, receiverArrow: "←")
        if case .item = choice { Issue.record("Malformed alias cannot choose an input destination") }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_input"] == nil)
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(p.f.mutations.map { $0.1 } == ["AXPress", "AXCancel"])
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

    @Test("Routing inspection publishes only its owned checked bus input", arguments: [1, 256], [false, true])
    func inspectionPublishesCheckedInput(number: Int, navigation: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(number), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            let fresh = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: navigation), fileReader: .unavailable, stoppingWhen: { false })
            }
            #expect(fresh.stable)
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(try #require(fresh.project))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(try #require(fresh.strips))
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let receiver = try #require(base.mixerReference(at: 0))
            let capture = inputCapture(base, fresh: fresh)
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let inputs = graph.edges.filter { $0.kind == .inputAssignment }
            if navigation {
                let input = try #require(inputs.first)
                #expect(inputs.count == 1)
                #expect(input.source == "bus_\(number)")
                #expect(input.destination == receiver.rawValue)
                #expect(input.provenance == .axInputMenuCheckmark)
                #expect(graph.nodes.first { $0.id == receiver.rawValue }?.kind == .physicalStrip)
                #expect(graph.coverage.busToAuxInput.state == .partial)
                #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel", "AXPress", "AXCancel"])
                let owners = [f.outputs[0], f.root, f.outputs[1], f.root]
                #expect(f.mutations.count == owners.count)
                for (action, owner) in zip(f.mutations, owners) { #expect(CFEqual(action.0, owner)) }
                // This fixture supplies an input-shaped menu even at the output
                // control. Its incoming bus choices cannot become output evidence.
                #expect(fresh.checkedOutputs.isEmpty)
                #expect(!graph.edges.contains { $0.kind == .mainOutput })
            } else {
                #expect(inputs.isEmpty)
                #expect(f.mutations.isEmpty)
            }
            #expect(!graph.complete)
            #expect(!graph.nodes.contains { $0.kind == .aux })
            #expect(graph.snapshotId == base.captureID)
        }
    }

    @Test("Fresh routing inspection projects checked physical inputs, not Bus or No Input edges",
          arguments: ["mono", "stereo", "no_input"], [false, true])
    func inspectionPublishesCheckedNonBusInput(kind: String, navigation: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (p, _) = try prepareInputDomain(kind), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let caption = kind == "no_input" ? "Input" : (kind == "mono" ? "Input 1" : "Input 1-2")
            f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, caption)
            let gate = LogicMutationGate()
            let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
            let fresh = try await OperationTraceContext.$current.withValue(context) {
                try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                    allowUINavigation: navigation), fileReader: .unavailable, stoppingWhen: { false })
            }
            #expect(fresh.stable)
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(try #require(fresh.project))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(try #require(fresh.strips))
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let capture = inputCapture(base, fresh: fresh)
            let report = SessionPopulationObservation.build(request: .init(domains: [.routing]), capture: capture)
            let row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report.strips.rows[0])) as? [String: Any])
            if navigation {
                #expect(fresh.checkedInputs.count == 1)
                let checked = try #require(row["checked_input"] as? [String: Any])
                #expect(checked["kind"] as? String == (kind == "no_input" ? "no_input" : "physical"))
                #expect(checked["source"] as? String == "ax_input_menu_checkmark")
                if kind == "no_input" { #expect(checked["ports"] == nil) }
                else { #expect(checked["ports"] as? [Int] == (kind == "mono" ? [1] : [1, 2])) }
                #expect(f.mutations.count == 4)
            } else {
                #expect(fresh.checkedInputs.isEmpty)
                #expect(row["checked_input"] == nil)
                #expect(f.mutations.isEmpty)
            }
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let inputs = graph.edges.filter { $0.kind == .inputAssignment }
            if navigation && kind != "no_input" {
                let receiver = try #require(base.mixerReference(at: 0))
                let edge = try #require(inputs.first)
                #expect(inputs.count == 1)
                #expect(edge.source == (kind == "mono" ? "input_physical_1" : "input_physical_1_2"))
                #expect(edge.destination == receiver.rawValue)
                #expect(edge.provenance == .axInputMenuCheckmark)
                let endpoint = try #require(graph.nodes.first { $0.id == edge.source })
                #expect(endpoint.kind == .input)
                #expect(endpoint.targetRef == nil && endpoint.busNumber == nil)
                #expect(graph.coverage.busToAuxInput.state == .partial)
            } else {
                #expect(inputs.isEmpty)
                #expect(!graph.nodes.contains { $0.kind == .input })
            }
            #expect(!graph.nodes.contains { $0.kind == .bus || $0.kind == .aux })
            #expect(!graph.complete)
            #expect(f.mutations.allSatisfy { $0.1 == "AXPress" || $0.1 == "AXCancel" })
        }
    }

    @Test("Checked non-Bus publication refuses missing, conflicting or foreign capture witnesses",
          arguments: ["held", "absent", "other_owner", "duplicate", "unstable", "missing_slot",
                      "missing_observation", "different_fresh_slot", "wrong_document", "unqualified", "invalid_ports",
                      "cached", "wrong_fresh_project", "duplicate_fresh_owner"])
    func checkedNonBusPublicationRequiresHeldCapture(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (p, _) = try prepareInputDomain("stereo"), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            var states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            let owner = try #require(states[0].physicalBinding)
            if fault == "missing_slot" { states[0].inputSlotBinding = nil }
            if fault == "missing_observation" { states[0].inputObservation = nil }
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            var freshStates = states
            if fault == "different_fresh_slot" { freshStates[0].inputSlotBinding = nil }
            if fault == "duplicate_fresh_owner" { freshStates.append(states[0]) }
            let freshProject = fault == "wrong_fresh_project"
                ? ProjectInfo(name: "Other", filePath: "/tmp/Other.logicx", source: "fixture") : base.project
            var fresh = SessionPopulationObservation.FreshPopulation(project: freshProject,
                tracks: base.tracks, strips: freshStates, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            if fault != "absent" {
                let receiver: AXMixerStripBinding.Binding
                if fault == "other_owner" { receiver = try #require(states[1].physicalBinding) }
                else if fault == "wrong_document" {
                    receiver = .init(window: owner.window, mixer: owner.mixer, strip: owner.strip,
                        document: "file:///unrelated.logicx")
                } else { receiver = owner }
                fresh.checkedInputs = [.init(receiver: receiver,
                    assignment: .physical(fault == "invalid_ports" ? [2, 1] : [1, 2]))]
                if fault == "duplicate" { fresh.checkedInputs.append(fresh.checkedInputs[0]) }
            }
            let capture = inputCapture(base, fresh: fault == "cached" ? nil : fresh)
            let checked = SessionPopulationObservation.reportedCheckedInput(of: states[0],
                capture: capture, qualified: fault != "unqualified")
            if fault == "held" {
                #expect(checked?.kind == "physical")
                #expect(checked?.ports == [1, 2])
            } else { #expect(checked == nil) }
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let inputs = graph.edges.filter { $0.kind == .inputAssignment }
            // `unqualified` above exercises the report caller's explicit switch;
            // this otherwise valid capture still qualifies its own graph projection.
            if fault == "held" || fault == "unqualified" {
                let edge = try #require(inputs.first)
                #expect(inputs.count == 1 && edge.source == "input_physical_1_2")
                #expect(edge.destination == base.mixerReference(at: 0)?.rawValue)
                #expect(graph.coverage.busToAuxInput.state == .partial)
            } else {
                #expect(inputs.isEmpty)
                #expect(!graph.nodes.contains { $0.kind == .input })
                #expect(!graph.provenance.contains(.axInputMenuCheckmark))
            }
            #expect(!graph.complete)
            let write = evaluate(RoutingWriteRequest(sourceTrackRef: try #require(base.mixerReference(at: 0)),
                physicalSlot: 1, destinationBusNumber: nil, destinationRef: nil,
                expectedProjectEpoch: graph.projectEpoch), against: graph)
            #expect(!write.allowed && !write.writeAttempted)
            #expect(f.mutations.isEmpty)
        }
    }

    private func inputCapture(_ base: SessionPopulationObservation.Capture,
        fresh: SessionPopulationObservation.FreshPopulation?) -> SessionPopulationObservation.Capture {
        SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: base.channelStrips,
                mixerFetchedAt: base.mixerFetchedAt, fileTrackCount: base.fileTrackCount,
                projectFileNotBound: base.projectFileNotBound, requestedProjectMatches: base.requestedProjectMatches,
                referencesEnabled: base.referencesEnabled, targetSnapshot: base.targetSnapshot,
                issued: base.issued, projectIssuance: base.projectIssuance,
                beganAt: base.beganAt, endedAt: base.endedAt, captureID: base.captureID,
                freshPopulation: fresh, mixerReferences: base.mixerReferences)
    }

    @Test("Input publication keeps exact owner, source census and unique typed evidence",
        arguments: ["held", "absent", "other_owner", "conflict", "unstable", "invalid_bus", "missing_slot",
                    "missing_observation", "different_fresh_slot", "duplicate_fresh_owner", "wrong_fresh_project"])
    func checkedInputPublicationRefusesUnsupportedEvidence(_ fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            var states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            let owner = try #require(states[0].physicalBinding)
            if fault == "missing_slot" { states[0].inputSlotBinding = nil }
            if fault == "missing_observation" { states[0].inputObservation = nil }
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let receiver = try #require(base.mixerReference(at: 0))
            var freshStates = states
            if fault == "different_fresh_slot" { freshStates[0].inputSlotBinding = nil }
            if fault == "duplicate_fresh_owner" { freshStates.append(states[0]) }
            let freshProject = fault == "wrong_fresh_project"
                ? ProjectInfo(name: "Other", filePath: "/tmp/Other.logicx", source: "fixture") : base.project
            var fresh = SessionPopulationObservation.FreshPopulation(project: freshProject,
                tracks: base.tracks, strips: freshStates, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            if fault != "absent" {
                fresh.checkedInputs = [.init(receiver: fault == "other_owner"
                    ? try #require(states[1].physicalBinding) : owner,
                    busNumber: fault == "invalid_bus" ? 257 : 1)]
                if fault == "conflict" { fresh.checkedInputs.append(.init(receiver: owner, busNumber: 2)) }
            }
            let capture = inputCapture(base, fresh: fresh)
            let checked = SessionPopulationObservation.reportedCheckedInput(of: states[0],
                capture: capture, qualified: true)
            if fault == "held" { #expect(checked?.number == 1) }
            else { #expect(checked == nil) }
            let graph = SessionPopulationObservation.routingGraph(capture: capture)
            let inputs = graph.edges.filter { $0.kind == .inputAssignment }
            if fault == "held" {
                let input = try #require(inputs.first)
                #expect(inputs.count == 1)
                #expect(input.source == "bus_1")
                #expect(input.destination == receiver.rawValue)
            } else { #expect(inputs.isEmpty) }
            if fault == "held" { #expect(graph.provenance.contains(.axInputMenuCheckmark)) }
            else { #expect(!graph.provenance.contains(.axInputMenuCheckmark)) }
            #expect(!graph.complete)
            #expect(!graph.nodes.contains { $0.kind == .aux })
            #expect(f.mutations.isEmpty)
        }
    }

    @Test("Input acquisition never publishes a conflict or a population moved after cleanup",
        arguments: ["conflict", "moved", "not_restored"])
    func inputInspectionKeepsCleanupAndPopulationBookends(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        if fault == "conflict" { f.b.setAttribute(p.inputLeaf, "AXMenuItemMarkChar", "✓") }
        if fault == "not_restored" { f.b.setActionNames(f.root, []) }
        if fault == "moved" {
            f.attributeReadResult = { _, _ in
                if f.mutations.contains(where: { $0.1 == kAXCancelAction as String }) {
                    f.b.setAttribute(f.volumes[1], kAXValueAttribute as String, 101)
                }
                return nil
            }
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let fresh = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: true), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(fresh.checkedInputs.isEmpty)
        if fault == "conflict" { #expect(fresh.stable) }
        else { #expect(!fresh.stable) }
        if fault == "moved" { #expect(fresh.uiEffects.reason == "routing_population_moved") }
        if fault == "not_restored" { #expect(fresh.uiEffects.reason == "routing_popup_not_restored") }
        #expect(f.mutations.allSatisfy { $0.1 == "AXPress" || $0.1 == "AXCancel" })
    }
    @Test("An unchanged focus pointer is restored only while its native path remains current",
          arguments: [true, false])
    func inputCleanupDoesNotRestoreDetachedFocus(retired: Bool) async throws {
        let p = try prepare(), f = p.f
        let focus = f.volumes[0]
        f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, focus)
        f.attributeReadResult = { _, _ in
            if retired, f.mutations.contains(where: {
                CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
            }) { f.reorder([1]) }
            return nil
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "checked-input-focus-receipt"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let response = await OperationTraceContext.$current.withValue(context) { await read(p) }
        let body = try #require(sharedJSONObject(response.message))
        #expect(f.mutations.map { $0.1 } == [kAXPressAction as String, kAXCancelAction as String])
        #expect(body["output_checkmark_reads_observed"] as? Int == 2)
        #expect(body["state"] as? String == (retired ? "C" : "A"))
        #expect(body["focus_restoration"] as? String == (retired ? "not_restored" : "restored"))
        let actual: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
            kAXFocusedUIElementAttribute as String, runtime: f.logic.ax))
        #expect(CFEqual(actual, focus), "Reach the same-pointer case, not a different focused element")
        #expect(AXHelpers.getRole(focus, runtime: f.logic.ax) == kAXSliderRole as String)
        #expect(f.value(focus) == 100, "No focus or fader setter supplies restoration")
    }

    @Test("A late cleanup census cannot authorize Help reads of a now-retired input owner")
    func inputCleanupRechecksOwnerBeforeRetiredControlHelp() async throws {
        final class RetirementProbe: @unchecked Sendable {
            var deliveredOldCensus = false
            var retiredHelpReads = 0
        }
        let p = try prepare(), f = p.f, probe = RetirementProbe()
        f.childrenReadResult = { node in
            guard CFEqual(node, f.mixer), !probe.deliveredOldCensus,
                  f.mutations.contains(where: {
                      CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
                  }) else { return nil }
            // The sampled census still names the old owner, but the host has
            // already retired it when the caller consumes that sample. Its AX
            // attributes remain readable; no error or changed caption masks it.
            probe.deliveredOldCensus = true
            f.reorder([1])
            return .success(f.strips)
        }
        f.attributeReadResult = { element, attribute in
            if probe.deliveredOldCensus, CFEqual(element, f.outputs[0]),
               attribute == kAXHelpAttribute as String { probe.retiredHelpReads += 1 }
            return nil
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(probe.deliveredOldCensus, "Reach real post-Cancel membership retirement")
        #expect(probe.retiredHelpReads == 0, "Old census data cannot authorize another old-control Help scan")
        #expect(body["state"] as? String == "C")
        let sourceCurrent = try #require(body["source_custody_after_cleanup"] as? Bool)
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!sourceCurrent && !writeAttempted)
        #expect(body["output_checkmark_reads_observed"] as? Int == 2)
        #expect(body["popup_menu_state"] as? String == "closed")
        let role: String = try #require(AXHelpers.getAttribute(f.outputs[0], kAXRoleAttribute as String,
            runtime: f.logic.ax))
        #expect(role == kAXButtonRole as String, "The original input stays readable, not conveniently invalidated")
    }

    @Test("Cleanup requires original input membership even when its AX role stays readable",
          arguments: ["healthy", "invalid_element", "readable_nonmember"])
    func originalInputMustSurviveCancel(_ mode: String) async throws {
        let p = try prepare(), f = p.f
        let retires = mode != "healthy"
        f.attributeReadResult = { element, _ in
            guard retires, f.mutations.contains(where: {
                CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
            }) else { return nil }
            // Model loss of the original member after cleanup. The separate native
            // re-click observation kept readable attributes but lost membership;
            // it does not qualify that gesture as Cancel or a successful getter.
            f.reorder([1])
            if mode == "invalid_element", CFEqual(element, f.strips[0]) || CFEqual(element, f.outputs[0]) {
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
        #expect(body["popup_menu_state"] as? String == "closed",
            "Observed popup absence is distinct from the retired source's refused assignment authority")
        let writeAttempted: Bool = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        if retires {
            #expect(body["current_input"] == nil)
            for original in [f.strips[0], f.outputs[0]] {
                let retired: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                    original, kAXRoleAttribute as String, runtime: f.logic.ax)
                if mode == "invalid_element" {
                    if case .failure(let status) = retired {
                        #expect(status.raw == AXError.invalidUIElement.rawValue)
                    } else { Issue.record("The original source and input control must be retired") }
                } else if case .success(.some(let role)) = retired {
                    #expect(role == (CFEqual(original, f.strips[0]) ? kAXLayoutItemRole : kAXButtonRole) as String)
                } else { Issue.record("The nonmember source and control must remain AX-readable") }
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
    @Test("A refused source cannot report popup closure across a changed or unreadable owner",
          arguments: ["foreign_document", "foreign_window", "unreadable_mixer"])
    func popupClosureRequiresOriginalOwnerAfterSourceRetirement(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let foreign = f.b.element(291_949)
        f.b.setRole(foreign, kAXWindowRole as String)
        f.b.setChildren(foreign, [])
        f.attributeReadResult = { _, _ in
            guard f.mutations.contains(where: {
                CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
            }) else { return nil }
            f.reorder([1])
            if fault == "foreign_document" {
                f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///foreign.logicx")
            } else if fault == "foreign_window" {
                f.b.setAttribute(f.app, kAXMainWindowAttribute as String, foreign)
                f.b.setAttribute(f.app, kAXWindowsAttribute as String, [foreign])
            }
            return nil
        }
        f.childrenReadResult = { element in
            guard fault == "unreadable_mixer", CFEqual(element, f.mixer),
                  f.mutations.contains(where: {
                      CFEqual($0.0, f.root) && $0.1 == kAXCancelAction as String
                  }) else { return nil }
            return .failure(.init(raw: AXError.cannotComplete.rawValue))
        }
        let body = try #require(sharedJSONObject(await read(p).message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_input"] == nil)
        #expect(body["popup_menu_state"] as? String == "not_restored")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(f.mutations.count == 2)
        if f.mutations.count == 2 {
            #expect(CFEqual(f.mutations[0].0, f.outputs[0]) && f.mutations[0].1 == kAXPressAction as String)
            #expect(CFEqual(f.mutations[1].0, f.root) && f.mutations[1].1 == kAXCancelAction as String)
        }
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

    private func publishPublicInput(_ p: Prepared) async throws -> (dependencies: HandlerDependencies, source: String, track: String, project: String) {
        let f = p.f
        let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter()
        let channel = f.channel()
        await router.register(channel)
        let poller = StatePoller(axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
        #expect(await poller.refreshNow())
        let mixer = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let strips = try #require(sharedJSONObject(sharedResourceText(mixer))?["strips"] as? [[String: Any]])
        var source: String?
        for reference in strips.compactMap({ $0["mixer_strip_ref"] as? String }) {
            if let physical = await registry.resolve(TargetReference(rawValue: reference))?.physicalMixerStrip,
               CFEqual(physical.strip, f.strips[0]) { source = reference }
        }
        let tracks = try await ResourceHandlers.read(uri: "logic://tracks", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let trackRows = try #require(sharedJSONObject(sharedResourceText(tracks))?["data"] as? [[String: Any]])
        let track = try #require(trackRows.first?["track_ref"] as? String)
        let project = try await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let projectRef = try #require((sharedJSONObject(sharedResourceText(project))?["data"] as? [String: Any])?["project_ref"] as? String)
        #expect(f.mutations.isEmpty, "Issuing physical references must not navigate or write")
        let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry, poller: poller,
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: LogicMutationGate(),
            liveTrackNames: { [0: "A", 1: "B"] }, projectFileReader: .unavailable)
        return (dependencies, try #require(source), track, projectRef)
    }

    private func publicInput(_ dependencies: HandlerDependencies, params: [String: Value], referencesEnabled: Bool = true) async throws -> [String: Any] {
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "get_input_bus_verified"))
        let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "get_input_bus_verified",
            commandParams: params, mutationGate: dependencies.mutationGate) {
                if let context = OperationTraceContext.current {
                    #expect(context.mutationGateAcquired,
                        "Popup acquisition and retained-source renewal require the real exclusive observation claim")
                    #expect(context.ownsGate())
                } else {
                    Issue.record("Popup acquisition must have an operation context")
                }
                // The deadline wrapper detaches its work. Set the test-only flag
                // inside that task rather than relying on inherited TaskLocals.
                return await FeatureFlags.withAdr002TargetRefForTests(referencesEnabled) {
                    await handler(dependencies, params)
                }
            }
        let completedGate = try #require(dependencies.mutationGate)
        #expect(completedGate.currentOperation() == nil,
            "Completed input observations must release their exclusive claim")
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    @Test func publicInputBusCannotEnterDuringAnotherOperation() async throws {
        let gate = LogicMutationGate()
        let predecessor = try #require(gate.tryAcquire(operation: "logic_tracks.rename"))
        defer { gate.release(predecessor) }
        let result = await LogicProServer.runWithDeadline(
            tool: "logic_mixer", command: "get_input_bus_verified", mutationGate: gate
        ) {
            Issue.record("Input popup acquisition entered while another operation owned Logic")
            return toolTextResult("unexpected acquisition")
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["error"] as? String == "mutating_operation_in_progress")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(gate.stillOwns(predecessor))
        #expect(gate.currentOperation() == "logic_tracks.rename")
    }

    @Test func publicInputBusContract() throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_mixer", command: "get_input_bus_verified"))
        #expect(spec.mutability == .readOnly)
        #expect(spec.allowedParams == Set(["target_ref", "project_ref"]))
        #expect(spec.deadline == .short)
        #expect(ChannelRouter.v2RoutingTable["mixer.get_input_bus_verified"] == [.accessibility])
        #expect(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "get_input_bus_verified") != nil)
    }

    @Test(arguments: [1, 256])
    func publicInputBusReadsPhysicalReference(number: Int) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(number), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            var params: [String: Value] = ["target_ref": .string(published.source)]
            if number == 256 { params["project_ref"] = .string(published.project) }
            let body = try await publicInput(published.dependencies, params: params)
            #expect(body["state"] as? String == "A")
            #expect(body["operation"] as? String == "mixer.get_input_bus_verified")
            #expect(body["target_ref"] as? String == published.source)
            let input = try #require(body["current_input"] as? [String: Any])
            #expect(input["kind"] as? String == "bus")
            #expect(input["number"] as? Int == number, "The checked bus, not the misleading Bus 256 display, is authoritative")
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(f.mutations.count == 2)
            if f.mutations.count == 2 {
                #expect(CFEqual(f.mutations[0].0, f.outputs[0]) && f.mutations[0].1 == kAXPressAction as String)
                #expect(CFEqual(f.mutations[1].0, f.root) && f.mutations[1].1 == kAXCancelAction as String)
            }
            #expect(!f.mutations.contains { CFEqual($0.0, p.leaf) || CFEqual($0.0, p.inputLeaf) })
        }
    }

    @Test(arguments: ["track", "unknown", "removed"])
    func publicInputBusRejectsNonPhysicalOrStaleReference(target: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            if target == "removed" { f.reorder([1]) }
            let reference = target == "track" ? published.track
                : (target == "unknown" ? "mix_missing_input_source" : published.source)
            let body = try await publicInput(published.dependencies, params: ["target_ref": .string(reference)])
            #expect(f.mutations.isEmpty)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "stale_target_reference")
            #expect(body["current_input"] == nil)
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }

    @Test(arguments: ["track", "index", "value", "destination", "ordinal"])
    func publicInputBusRejectsWriteAndIndexInputs(extra: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            let value: Value = extra == "destination" ? .object(["kind": .string("bus"), "number": .int(1)]) : .int(0)
            let body = try await publicInput(published.dependencies,
                params: ["target_ref": .string(published.source), extra: value])
            #expect(f.mutations.isEmpty)
            #expect(body["error"] as? String == "invalid_params")
            #expect(body["current_input"] == nil)
        }
    }

    @Test func publicInputBusRefusesDisabledReferences() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let published = try await publishPublicInput(p)
            let body = try await publicInput(published.dependencies,
                params: ["target_ref": .string(published.source)], referencesEnabled: false)
            #expect(f.mutations.isEmpty)
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "target_ref_unavailable")
            #expect(body["current_input"] == nil)
            let attempted = try #require(body["write_attempted"] as? Bool)
            #expect(!attempted)
        }
    }
}
