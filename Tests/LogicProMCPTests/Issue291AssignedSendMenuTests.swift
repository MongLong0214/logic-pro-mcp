@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#291 assigned-send owned checked-menu acquisition", .serialized)
struct Issue291AssignedSendMenuTests {
    private final class RequestStop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.withLock { stopped = true } }
        var isStopped: Bool { lock.withLock { stopped } }
    }
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
    private final class SendWriterProbe: @unchecked Sendable {
        let p: Prepared
        let stereo: AXUIElement
        let pair: AXUIElement
        let mode: AXUIElement
        let bus: AXUIElement
        var current = "Stereo Output"
        var open = false
        var pressed: [String] = []
        var menuOpens = 0
        var cancels = 0
        var closeWindowReads = 0
        var cancelProjectInjected = false
        var foregroundLost = false
        var busLookupFaultReached = false
        var fault: String?
        init(_ p: Prepared, withBus: Bool = false) {
            self.p = p
            let b = p.f.b
            stereo = b.element(291_970); pair = b.element(291_971)
            mode = b.element(291_972)
            bus = b.element(291_980)
            let output = b.element(291_973), outputs = b.element(291_974)
            let stereoParent = b.element(291_975), stereoMenu = b.element(291_976)
            for (e, title) in [(stereo,"Stereo Output"),(pair,"Output 3-4"),(mode,"Post Pan"),
                               (output,"Output"),(stereoParent,"Stereo")] {
                b.setRole(e,kAXMenuItemRole as String); b.setAttribute(e,kAXTitleAttribute as String,title)
                b.setAttribute(e,kAXEnabledAttribute as String,true); b.setChildren(e,[])
                b.setActionNames(e,[kAXPressAction as String])
            }
            b.setRole(outputs,kAXMenuRole as String); b.setRole(stereoMenu,kAXMenuRole as String)
            b.setChildren(stereoMenu,[stereo,pair]); b.setChildren(stereoParent,[stereoMenu])
            b.setChildren(outputs,[stereoParent]); b.setChildren(output,[outputs])
            b.setChildren(p.f.root,[p.checkedEcho,mode,output])
            if withBus {
                let busParent = b.element(291_981), busMenu = b.element(291_982)
                b.setRole(busParent, kAXMenuItemRole as String); b.setAttribute(busParent, kAXTitleAttribute as String, "Bus")
                b.setRole(busMenu, kAXMenuRole as String)
                b.setRole(bus, kAXMenuItemRole as String); b.setAttribute(bus, kAXTitleAttribute as String, "Bus 1 → Aux 1")
                b.setAttribute(bus, kAXEnabledAttribute as String, true); b.setChildren(bus, [])
                b.setActionNames(bus, [kAXPressAction as String])
                b.setChildren(busMenu, [bus]); b.setChildren(busParent, [busMenu])
                b.setChildren(p.f.root, [p.checkedEcho, mode, output, busParent])
                let input = b.element(291_983)
                b.setButton(input, description: "Bus 1", help: "Input slot. Choose the channel strip input source.",
                    x: 80, y: 120, width: 60, height: 20)
                b.setChildren(input, [])
                b.setChildren(p.f.strips[1], AXHelpers.getChildren(p.f.strips[1], runtime: p.f.logic.ax) + [input])
            }
            b.setAttribute(p.f.app,kAXFrontmostAttribute as String,true)
            refresh()
        }
        func refresh() {
            let b = p.f.b
            b.setAttribute(p.checkedEcho,kAXTitleAttribute as String,current)
            b.setAttribute(p.checkedEcho,"AXMenuItemMarkChar","✓")
            b.setAttribute(stereo,"AXMenuItemMarkChar",current == "Stereo Output" ? "✓" : "")
            b.setAttribute(pair,"AXMenuItemMarkChar",current == "Output 3-4" ? "✓" : "")
            b.setAttribute(bus,"AXMenuItemMarkChar",current == "Bus 1 → Aux 1" ? "✓" : "")
            b.setAttribute(mode,"AXMenuItemMarkChar","✓")
        }
        func action(_ node: AXUIElement, _ action: String) -> Bool {
            let f = p.f
            if action == kAXCancelAction as String, CFEqual(node,f.root), open {
                cancels += 1
                open = false; f.b.setChildren(f.mixer,f.strips)
                if fault == "cancel_source_retired" { f.b.setChildren(f.mixer, [f.strips[1]]) }
                if fault == "cancel_level" { f.b.setAttribute(p.knob, kAXValueAttribute as String, 1) }
                if fault == "cancel_project" { f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx") }
                return fault != "cancel_failed_ack"
            }
            if action == kAXPressAction as String, CFEqual(node,f.outputs[0]) {
                menuOpens += 1
                open = true; refresh(); f.b.setChildren(f.mixer,f.strips + [f.root]); return true
            }
            if action == kAXPressAction as String, open, CFEqual(node,pair) || CFEqual(node,stereo) || CFEqual(node,bus) {
                let next = CFEqual(node,bus) ? "Bus 1 → Aux 1" : CFEqual(node,pair) ? "Output 3-4" : "Stereo Output"
                pressed.append(next)
                if fault != "no_effect" { current = next }
                if fault == "destination_label" {
                    f.b.setAttribute(f.outputs[0], kAXDescriptionAttribute as String, next)
                }
                if fault == "unreadable_label" {
                    f.b.removeAttribute(f.outputs[0], kAXDescriptionAttribute as String)
                }
                if fault == "control_retired" { f.b.setChildren(f.strips[0], [p.anchor, p.knob]) }
                if fault == "level" { f.b.setAttribute(p.knob,kAXValueAttribute as String,1) }
                if fault == "mode" { f.b.setAttribute(mode,kAXTitleAttribute as String,"Pre Fader") }
                if fault == "post_open_foreground" {
                    foregroundLost = true; refresh(); return true
                }
                if fault == "source_retired" { f.b.setChildren(f.mixer,[f.strips[1]]) }
                else { f.b.setChildren(f.mixer,f.strips) }
                open = false; refresh(); return true
            }
            Issue.record("Unexpected send action \(action)"); return false
        }
        var runtime: AXLogicProElements.Runtime {
            let f = p.f, base = f.logic
            let ax = f.b.makeAXRuntime(appElement:f.app,
                attributeValueResultHandler: { [self] node, _ in
                    if fault == "late_unreadable_input", busLookupFaultReached, CFEqual(node, f.b.element(291_983)) {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    guard fault == "strip_invalid", !pressed.isEmpty, CFEqual(node, f.strips[0]) else { return nil }
                    return .failure(.init(raw: -25202))
                },
                childrenResultHandler: { [self] node in
                    guard fault == "strip_invalid", !pressed.isEmpty, CFEqual(node, f.strips[0]) else { return nil }
                    return .failure(.init(raw: -25202))
                },
                actionNamesHandler: { [self] node in
                    if CFEqual(node, bus) {
                        switch fault {
                        case "late_receiver": f.b.setAttribute(f.b.element(291_983), kAXDescriptionAttribute as String, "Bus 2")
                        case "late_retirement":
                            let replacement = f.b.element(291_986)
                            f.b.setRole(replacement, kAXLayoutItemRole as String)
                            f.b.setChildren(replacement, AXHelpers.getChildren(f.strips[1], runtime: base.ax))
                            f.b.setChildren(f.mixer, [f.strips[0], replacement] + (open ? [f.root] : []))
                        case "late_dependency": f.b.removeAttribute(f.outputs[1], kAXDescriptionAttribute as String)
                        case "late_loop": f.b.setAttribute(f.b.element(291_984), kAXDescriptionAttribute as String, "Bus 1")
                        case "late_unreadable_input": break
                        default: return nil
                        }
                        busLookupFaultReached = true
                        return [kAXPressAction as String]
                    }
                    guard CFEqual(node,pair) else { return nil }
                    switch fault {
                    case "late_wrong_project": f.b.setAttribute(f.window,kAXDocumentAttribute as String,"file:///wrong.logicx")
                    case "late_label": f.b.setAttribute(f.outputs[0],kAXDescriptionAttribute as String,"changed before press")
                    case "late_foreground": foregroundLost = true
                    case "late_background": f.b.setAttribute(f.app,kAXFrontmostAttribute as String,false)
                    case "late_foreign_editor":
                        let editor = f.b.element(291_978)
                        f.b.setRole(editor,kAXTextFieldRole as String); f.b.setChildren(editor,[])
                        f.b.setChildren(f.window,AXHelpers.getChildren(f.window,runtime:base.ax) + [editor])
                        f.b.setAttribute(f.app,kAXFocusedUIElementAttribute as String,editor)
                    default: return nil
                    }
                    return [kAXPressAction as String]
                },
                setAttributeHandler: { _,_,_ in Issue.record("Send parameter setter forbidden"); return false },
                performActionHandler: { [self] in action($0,$1) },
                performActionResultHandler: { [self] in action($0,$1) ? .success(()) : .failure(.init(raw:-25204)) })
            return .init(logicProPID:base.logicProPID,ax:ax,
                executeAppleScript: { _ in Issue.record("AppleScript forbidden"); return .error("forbidden") },
                onScreenWindowList: { [self] in
                    var visible = open
                    if cancels > 0, fault?.hasPrefix("cancel_cg_") == true {
                        closeWindowReads += 1
                        if fault == "cancel_cg_unreadable" { return nil }
                        visible = fault == "cancel_cg_persistent" || closeWindowReads == 1
                        let projectBoundary = fault == "cancel_cg_deciding_project" ? 1 : 2
                        if fault == "cancel_cg_deciding_project" { visible = false }
                        if fault == "cancel_cg_project" || fault == "cancel_cg_deciding_project",
                           closeWindowReads == projectBoundary {
                            cancelProjectInjected = true
                            f.b.setAttribute(f.window, kAXDocumentAttribute as String, "file:///wrong.logicx")
                        }
                    }
                    return visible ? [[kCGWindowOwnerPID as String:f.pid,
                        kCGWindowNumber as String:291_979,
                        kCGWindowLayer as String:LogicOnScreenWindows.popupMenuLevel]] : []
                },
                postPopupMenuEscape: { Issue.record("Escape forbidden") },
                focusedApplicationPID: { [self] in foregroundLost ? f.pid + 1 : base.focusedApplicationPID() },
                observeFrontmost:base.observeFrontmost)
        }
        func write(destination: String = "physical:3-4", expected: String = "stereo_output",
                   replacement: Bool = true, ordinal: Int = 1,
                   timing: AccessibilityChannel.OutputAssignmentTiming = .immediate) async -> ChannelResult {
            let f = p.f, gate = LogicMutationGate()
            guard let claim = gate.tryAcquire(operation:"logic_mixer.set_send_output_verified") else { return .error("gate") }
            defer { gate.release(claim) }
            let context = OperationTraceContext(mutationGateAcquired:true,ownsGate: { gate.stillOwns(claim) })
            return await OperationTraceContext.$current.withValue(context) {
                await AXMixerStripBinding.$current.withValue(.init(window:f.window,mixer:f.mixer,
                    strip:f.strips[0],document:f.bundle.absoluteString)) {
                    await AccessibilityChannel.setAssignedSendOutputVerified(params:["destination":destination,
                        "expected_current":expected,"replace_existing":replacement ? "true" : "false",
                        "send_ordinal":String(ordinal)],runtime:runtime,timing:timing)
                }
            }
        }
    }
    @Test("A checked Send reader observes Cancel settlement before reporting restored evidence",
          arguments: ["cancel_cg_delayed", "cancel_cg_persistent", "cancel_cg_unreadable", "cancel_cg_project", "cancel_cg_deciding_project"])
    func occupiedSendReaderWaitsForPopupClosure(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p), f = p.f
        probe.fault = fault
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_mixer.get_send_destination_verified"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let result = await OperationTraceContext.$current.withValue(context) {
            await AXMixerStripBinding.$current.withValue(.init(window: f.window, mixer: f.mixer,
                strip: f.strips[0], document: f.bundle.absoluteString)) {
                await AccessibilityChannel.getAssignedSendVerified(ordinal: 1, runtime: probe.runtime,
                    timing: .init(popupOpenTimeoutMs: 0,
                        popupCloseTimeoutMs: fault == "cancel_cg_deciding_project" ? 0 : 30,
                        readbackTimeoutMs: 0, pollIntervalMs: 1))
            }
        }
        let body = try #require(sharedJSONObject(result.message))
        // This reader may report a checked observation with an explicit UI residual.
        // Restoration is not assignment authority; a changed project still withholds it.
        #expect(body["state"] as? String == (fault.hasSuffix("project") ? "C" : "A"), "\(body)")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        #expect(probe.menuOpens == 1 && probe.cancels == 1)
        #expect(probe.pressed.isEmpty)
        if fault == "cancel_cg_delayed" {
            #expect(probe.closeWindowReads >= 2)
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(body["focus_restoration"] as? String == "restored")
        } else {
            #expect(body["popup_menu_state"] as? String != "closed")
            if fault.hasSuffix("project") {
                #expect(probe.cancelProjectInjected)
                #expect(body["current_destination"] == nil)
            }
        }
    }
    @Test("A matching send waits for observed asynchronous popup closure without another action",
          arguments: ["cancel_cg_delayed", "cancel_cg_persistent", "cancel_cg_unreadable", "cancel_cg_project"])
    func occupiedSendNoOpWaitsForPopupClosure(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let result = try #require(sharedJSONObject(await probe.write(destination: "stereo_output",
            timing: .init(popupOpenTimeoutMs: 0, popupCloseTimeoutMs: 30, readbackTimeoutMs: 0, pollIntervalMs: 1)).message))
        #expect(result["state"] as? String == (fault == "cancel_cg_delayed" ? "A" : "C"), "\(result)")
        let attempted = try #require(result["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(probe.pressed.isEmpty)
        #expect(probe.cancels == 1)
        if fault == "cancel_cg_delayed" {
            #expect(probe.closeWindowReads >= 2)
            #expect(result["popup_menu_state"] as? String == "closed")
        } else {
            #expect(result["after"] == nil)
        }
    }
    @Test("An already-matching checked send closes its popup without reapplying the destination",
          arguments: ["source_retired", "cancel_failed_ack"])
    func occupiedSendAlreadyMatchingDoesNotWrite(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        // A redundant destination press can retire the native source. A no-op
        // must use checked evidence without entering that mutation boundary.
        probe.fault = fault
        let before = AXLogicProElements.sendSlotObservations(in: p.f.strips[0], runtime: probe.runtime.ax)
        let result = try #require(sharedJSONObject(await probe.write(destination: "stereo_output").message))
        #expect(result["state"] as? String == "A", "\(result)")
        let attempted = try #require(result["write_attempted"] as? Bool)
        let changed = try #require(result["changed"] as? Bool)
        #expect(!attempted)
        #expect(!changed)
        #expect(probe.pressed.isEmpty)
        #expect(probe.cancels == 1)
        #expect(!probe.open)
        #expect(result["popup_menu_state"] as? String == "closed")
        #expect(AXLogicProElements.sendSlotObservations(in: p.f.strips[0], runtime: probe.runtime.ax) == before)
    }

    @Test("A matching send does not publish verified state after cleanup loses source or protected state",
          arguments: ["cancel_source_retired", "cancel_level", "cancel_project"])
    func occupiedSendNoOpStillRequiresCleanupCustody(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let result = try #require(sharedJSONObject(await probe.write(destination: "stereo_output").message))
        #expect(result["state"] as? String == "C", "\(result)")
        let attempted = try #require(result["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(probe.pressed.isEmpty)
        #expect(probe.cancels == 1)
        #expect(!probe.open)
        #expect(result["after"] == nil)
    }

    @Test("Occupied-send output replacement and explicit inverse retain level, bypass, mode and exact slot",
        arguments: ["fixed_label", "destination_label", "missing_identifiers"])
    func occupiedSendOutputRoundtrip(label: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = label
        for (element, identifier) in [(p.f.strips[0], "original-source"), (p.group, "occupied-group"),
                                       (p.f.outputs[0], "occupied-list"), (p.bypass, "occupied-bypass")] {
            if label != "missing_identifiers" {
                p.f.b.setAttribute(element, kAXIdentifierAttribute as String, identifier)
            }
        }
        let before = AXLogicProElements.sendSlotObservations(in:p.f.strips[0],runtime:probe.runtime.ax)
        let forward = try #require(sharedJSONObject(await probe.write().message))
        #expect(forward["state"] as? String == "A", "\(forward)")
        if label == "missing_identifiers" {
            let identifiers = try #require(forward["pre_press_source_identifiers"] as? [String: Any])
            #expect(identifiers.count == 4 && identifiers.values.allSatisfy { $0 is NSNull })
        } else {
            #expect(forward["pre_press_source_identifiers"] as? [String: String] == [
                "strip": "original-source", "send_group": "occupied-group",
                "send_list": "occupied-list", "send_bypass": "occupied-bypass"])
            #expect(forward["pre_press_identifier_read_status"] as? [String: Int] == [
                "strip": 0, "send_group": 0, "send_list": 0, "send_bypass": 0])
        }
        let identity = try #require(forward["post_press_control_identity"] as? [String: Bool])
        #expect(identity == ["observed": true, "ordinal": true, "group": true,
            "list": true, "bypass": true, "parent_proxy": true, "source_path": true])
        #expect(probe.pressed == ["Output 3-4"])
        #expect(probe.current == "Output 3-4")
        let inverse = try #require(sharedJSONObject(await probe.write(destination:"stereo_output",expected:"physical:3-4").message))
        #expect(inverse["state"] as? String == "A", "\(inverse)")
        #expect(probe.pressed == ["Output 3-4","Stereo Output"])
        #expect(AXLogicProElements.sendSlotObservations(in:p.f.strips[0],runtime:probe.runtime.ax) == before)
        #expect(!probe.open)
    }
    @Test("Occupied-send refusals never press a destination",
        arguments:["stale", "empty", "replacement", "bus", "late_wrong_project", "late_label"])
    func occupiedSendOutputRefusals(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let body = try #require(sharedJSONObject(await probe.write(destination:fault == "bus" ? "bus:1" : "physical:3-4",
            expected:fault == "stale" ? "physical:3-4" : "stereo_output",
            replacement:fault != "replacement",ordinal:fault == "empty" ? 0 : 1).message))
        #expect(body["state"] as? String == "C", "\(body)")
        #expect(probe.pressed.isEmpty)
        if fault == "late_label" { #expect(probe.cancels == 0) }
    }
    @Test("Post-press effect, protected-state and original-source loss remain uncertain; no guessed inverse",
        arguments:["no_effect", "level", "mode", "source_retired", "control_retired", "strip_invalid", "unreadable_label"])
    func occupiedSendOutputPostPressUncertainty(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let body = try #require(sharedJSONObject(await probe.write().message))
        #expect(body["state"] as? String == "B", "\(body)")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(writeAttempted)
        #expect(probe.pressed == ["Output 3-4"])
        if fault == "control_retired" {
            let identity = try #require(body["post_press_control_identity"] as? [String: Bool])
            #expect(identity == ["observed": false])
        }
        if fault == "strip_invalid" {
            let statuses = try #require(body["post_press_source_read_status"] as? [String: Int])
            #expect(statuses["strip_role"] == -25202)
            #expect(statuses["strip_children"] == -25202)
        }
    }
    @Test("Revoked writer focus/foreground permits neither destination nor popup inverse",
        arguments:["late_foreground", "late_background", "late_foreign_editor", "post_open_foreground"])
    func occupiedSendCleanupCannotUseReaderOnlyCustody(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p)
        probe.fault = fault
        let body = try #require(sharedJSONObject(await probe.write().message))
        #expect(body["state"] as? String == (fault == "post_open_foreground" ? "B" : "C"))
        #expect(probe.pressed == (fault == "post_open_foreground" ? ["Output 3-4"] : []))
        #expect(probe.cancels == 0)
        #expect(probe.open)
    }
    @Test("Registered occupied-send writer uses only a physical reference and the real mutation gate")
    func registeredOccupiedSendOutputWriter() async throws {
        let command = "set_send_output_verified"
        let spec = try #require(OperationRegistry.spec(tool:"logic_mixer",command:command))
        #expect(spec.mutability == .mutating)
        #expect(spec.indexBinding == .refRequired)
        #expect(spec.allowedParams == Set(["target_ref","project_ref","ordinal","destination","expected_current","replace_existing"]))
        let handler = try #require(OperationHandlerRegistry.handler(tool:"logic_mixer",command:command))
        let p = try prepare(), probe = SendWriterProbe(p)
        let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter()
        let channel = p.f.channel(logicOverride:probe.runtime)
        await router.register(channel)
        let poller = StatePoller(axChannel:channel,cache:cache,
            runtime:.init(hasVisibleWindow: { true },dialogPresent: { false },blockingDialogInfo: { nil },
                projectFileReader:.unavailable,keyboardFocus: { .notTextEditing }))
        #expect(await poller.refreshNow())
        let resource = try await ResourceHandlers.read(uri:"logic://mixer",cache:cache,router:router,
            targetRegistry:registry,fileReader:.unavailable)
        let rows = try #require(sharedJSONObject(sharedResourceText(resource))?["strips"] as? [[String:Any]])
        var matching: [String] = []
        for reference in rows.compactMap({ $0["mixer_strip_ref"] as? String }) {
            if let physical = await registry.resolve(.init(rawValue:reference))?.physicalMixerStrip,
               CFEqual(physical.strip,p.f.strips[0]) { matching.append(reference) }
        }
        #expect(matching.count == 1)
        let reference = try #require(matching.first)
        let dependencies = HandlerDependencies(router:router,cache:cache,targetRegistry:registry,poller:poller,
            dialogPresent: { false },supportBundleExporter:nil,mutationGate:LogicMutationGate(),
            liveTrackNames: { [0:"A",1:"B"] },projectFileReader:.unavailable)
        let params: [String:Value] = ["target_ref":.string(reference),"ordinal":.int(1),
            "destination":.object(["kind":.string("physical"),"ports":.array([.int(3),.int(4)])]),
            "expected_current":.object(["kind":.string("stereo_output")]),"replace_existing":.bool(true)]
        func call(_ inputs: [String:Value]) async -> CallTool.Result {
            await LogicProServer.runWithDeadline(tool:"logic_mixer",command:command,
                commandParams:inputs,mutationGate:dependencies.mutationGate) {
                await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies,inputs) }
            }
        }
        for extra in ["track","index","value","bypassed"] {
            var invalid = params; invalid[extra] = .int(0)
            let body = try #require(sharedJSONObject(sharedToolText(await call(invalid))))
            #expect(body["state"] as? String == "C")
            #expect(probe.pressed.isEmpty)
        }
        for invalidReference in ["mix_unissued","trk_unissued"] {
            var invalid = params; invalid["target_ref"] = .string(invalidReference)
            let body = try #require(sharedJSONObject(sharedToolText(await call(invalid))))
            #expect(body["state"] as? String == "C")
            #expect(probe.pressed.isEmpty)
        }
        var wrongProject = params; wrongProject["project_ref"] = .string("prj_unissued")
        #expect(sharedJSONObject(sharedToolText(await call(wrongProject)))?["state"] as? String == "C")
        #expect(probe.pressed.isEmpty)
        let forward = try #require(sharedJSONObject(sharedToolText(await call(params))))
        #expect(forward["state"] as? String == "A", "\(forward)")
        #expect(probe.pressed == ["Output 3-4"])
        var inverse = params
        inverse["destination"] = params["expected_current"]
        inverse["expected_current"] = params["destination"]
        let restored = try #require(sharedJSONObject(sharedToolText(await call(inverse))))
        #expect(restored["state"] as? String == "A", "\(restored)")
        #expect(probe.pressed == ["Output 3-4","Stereo Output"])
        #expect(!probe.open)
        #expect(dependencies.mutationGate?.currentOperation() == nil)
    }
    @Test("A resource-only Bus Send change requires its actual retained original-header pair")
    func registeredOccupiedSendExistingBusRequiresRetainedPair() async throws {
        let p = try prepare(), probe = SendWriterProbe(p, withBus: true)
        let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter()
        let channel = p.f.channel(logicOverride: probe.runtime)
        await router.register(channel)
        let poller = StatePoller(axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false }, blockingDialogInfo: { nil },
                projectFileReader: .unavailable, keyboardFocus: { .notTextEditing }))
        #expect(await poller.refreshNow())
        let resource = try await ResourceHandlers.read(uri: "logic://mixer", cache: cache, router: router,
            targetRegistry: registry, fileReader: .unavailable)
        let rows = try #require(sharedJSONObject(sharedResourceText(resource))?["strips"] as? [[String: Any]])
        var references: [String] = []
        for value in rows.compactMap({ $0["mixer_strip_ref"] as? String }) {
            if let binding = await registry.resolve(.init(rawValue: value))?.physicalMixerStrip,
               CFEqual(binding.strip, p.f.strips[0]) { references.append(value) }
        }
        #expect(references.count == 1)
        let reference = try #require(references.first)
        let source = try #require(await registry.resolve(.init(rawValue: reference))?.physicalMixerStrip)
        #expect(await cache.retainedMixerAssociation(reference: .init(rawValue: reference), source: source,
            snapshot: await registry.currentSnapshot) == nil)
        let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
            poller: poller, dialogPresent: { false }, supportBundleExporter: nil, mutationGate: LogicMutationGate(),
            liveTrackNames: { [:] }, projectFileReader: .unavailable)
        let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_mixer", command: "set_send_output_verified"))
        let before = AXLogicProElements.sendSlotObservations(in: p.f.strips[0], runtime: probe.runtime.ax)
        let bus: Value = .object(["kind": .string("bus"), "number": .int(1)])
        let stereo: Value = .object(["kind": .string("stereo_output")])
        let params: [String: Value] = ["target_ref": .string(reference), "ordinal": .int(1),
            "destination": bus, "expected_current": stereo, "replace_existing": .bool(true)]
        let result = await LogicProServer.runWithDeadline(tool: "logic_mixer", command: "set_send_output_verified",
            commandParams: params, mutationGate: dependencies.mutationGate) {
            await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
        }
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "C", "Actual resource-only Bus refusal: \(sharedToolText(result))")
        #expect(body["error"] as? String == "stale_snapshot")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(probe.menuOpens == 0 && probe.cancels == 0 && probe.pressed.isEmpty)
        #expect(probe.current == "Stereo Output")
        #expect(AXLogicProElements.sendSlotObservations(in: p.f.strips[0], runtime: probe.runtime.ax) == before)
        #expect(!probe.open)
        #expect(dependencies.mutationGate?.currentOperation() == nil)
    }

    @Test(arguments: ["no_receiver", "loop", "dependency", "ambiguous", "late_receiver",
                      "late_retirement", "late_dependency", "late_loop", "late_unreadable_input"])
    func occupiedBusSendRefusesMissingOrChangedReceiverAndLoop(fault: String) async throws {
        let p = try prepare(), probe = SendWriterProbe(p, withBus: true), f = p.f
        probe.fault = fault
        if fault == "no_receiver" { f.b.setAttribute(f.b.element(291_983), kAXDescriptionAttribute as String, "Input 1") }
        if ["loop", "dependency", "late_dependency", "late_loop", "late_unreadable_input"].contains(fault) {
            let input = f.b.element(291_984)
            f.b.setButton(input, description: fault == "loop" ? "Bus 1" : "Bus 2",
                help: "Input slot. Choose the channel strip input source.", x: 0, y: 120, width: 60, height: 20)
            f.b.setChildren(input, [])
            f.b.setChildren(f.strips[0], AXHelpers.getChildren(f.strips[0], runtime: f.logic.ax) + [input])
        }
        if fault == "dependency" { f.b.removeAttribute(f.outputs[1], kAXDescriptionAttribute as String) }
        if fault == "ambiguous" {
            let duplicate = f.b.element(291_985)
            f.b.setRole(duplicate, kAXMenuItemRole as String)
            f.b.setAttribute(duplicate, kAXTitleAttribute as String, "Bus 1 → Aux 1")
            f.b.setAttribute(duplicate, kAXEnabledAttribute as String, true); f.b.setChildren(duplicate, [])
            f.b.setChildren(f.b.element(291_982), [probe.bus, duplicate])
        }
        let body = try #require(sharedJSONObject(await probe.write(destination: "bus:1").message))
        #expect(body["state"] as? String == "C", "Actual Bus guard response: \(body)")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(!attempted)
        #expect(probe.pressed.isEmpty, "No destination or guessed inverse may create an Aux or override changed routing")
        if fault.hasPrefix("late_") { #expect(probe.busLookupFaultReached, "The actual offered Bus leaf capability lookup must reach the fault") }
        let expectedError: String
        switch fault {
        case "no_receiver", "late_receiver": expectedError = "bus_has_no_receiver"
        case "loop", "late_loop": expectedError = "routing_cycle"
        case "dependency", "late_dependency", "late_unreadable_input": expectedError = "routing_dependency_unknown"
        default: expectedError = "stale_target_reference"
        }
        #expect(body["error"] as? String == expectedError)
    }

    @Test("Routing actions reuse the exact occupied census control, never an empty anchor or a lookalike",
          arguments: ["held", "negative", "empty", "missing_list", "duplicate_list", "foreign_parent"])
    func sharedAssignedSendControlRequiresOriginalCensus(fault: String) throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        switch fault {
        case "missing_list": f.b.setChildren(p.group, [p.bypass])
        case "duplicate_list": f.b.setChildren(p.group, [p.bypass, f.outputs[0], f.outputs[0]])
        case "foreign_parent": f.b.setAttribute(p.group, kAXParentAttribute as String, f.strips[1])
        default: break
        }
        let control = AXLogicProElements.assignedSendMenuControl(in: f.strips[0],
            ordinal: fault == "negative" ? -1 : (fault == "empty" ? 0 : 1), runtime: f.logic.ax)
        if fault == "held" {
            let held = try #require(control)
            #expect(held.ordinal == 1)
            #expect(CFEqual(held.group, p.group))
            #expect(CFEqual(held.list, f.outputs[0]))
            #expect(CFEqual(held.bypass, p.bypass))
        } else { #expect(control == nil) }
        #expect(f.mutations.isEmpty)
    }
    @Test("Routing/association population reads inserts only when the strip footprint is requested",
          arguments: [SessionPopulationObservation.Domain.routing, .associations], [false, true])
    func routingPopulationSkipsUnrequestedInserts(domain: SessionPopulationObservation.Domain, includeStrips: Bool) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let insert = Issue982UnreadChildrenTests.occupiedSlot(f.b, 291_950, name: "Compressor")
        f.b.setChildren(f.strips[1], [f.outputs[1], insert])
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(
                domains: includeStrips ? [domain, .strips] : [domain]),
                fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        let states = try #require(population.strips)
        #expect(!states.isEmpty)
        if includeStrips {
            #expect(states.contains { $0.pluginsSource != nil || $0.pluginsReadError != nil })
            #expect(states[1].plugins.count == 1)
        } else {
            #expect(states.allSatisfy { $0.pluginsSource == nil && $0.pluginsReadError == nil })
        }
        let cache = StateCache()
        await cache.updateProject(try #require(population.project))
        await cache.updateChannelStrips(states)
        let capture = await SessionPopulationObservation.capture(cache: cache,
            targetRegistry: nil, fileReader: .unavailable)
        let report = SessionPopulationObservation.build(request: .init(
            domains: includeStrips ? [domain, .strips] : [domain]), capture: capture)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let rows = try #require((wire["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
        if includeStrips {
            #expect(rows[1]["plugin_count"] as? Int == 1)
        } else {
            #expect(rows[1]["plugin_count"] == nil || rows[1]["plugin_count"] is NSNull)
        }
        if domain == .routing || includeStrips {
            let hasSend = try #require(states.first?.sendSlots?.contains { $0.ordinal == 1 })
            #expect(hasSend)
        } else {
            // Association-only capture leaves unrequested routing unknown.
            #expect(states.allSatisfy { $0.sendSlots == nil })
        }
        #expect(f.mutations.isEmpty)
    }
    @Test("Explicit fresh routing capture retains the occupied send's checked destination")
    func freshRoutingCaptureReadsAssignedSend() async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let population = try await OperationTraceContext.$current.withValue(context) {
            try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                allowUINavigation: true), fileReader: .unavailable, stoppingWhen: { false })
        }
        #expect(population.stable)
        #expect(population.checkedOutputs.count == 2)
        let send = try #require(population.checkedOutputs.first { $0.sendOrdinal == 1 })
        #expect(send.assignment == .bus(1))
        #expect(CFEqual(send.source.strip, f.strips[0]))
        let output = try #require(population.checkedOutputs.first { $0.sendOrdinal == nil })
        #expect(output.assignment == .bus(1))
        #expect(f.b.attributeValue(f.outputs[1], kAXDescriptionAttribute as String) as? String == "Stereo Output")
        #expect(CFEqual(output.source.strip, f.strips[1]))
        #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel", "AXPress", "AXCancel"])
        let presses = f.mutations.filter { $0.1 == kAXPressAction as String }
        try #require(presses.count == 2)
        #expect(CFEqual(presses[0].0, f.outputs[0]) && CFEqual(presses[1].0, f.outputs[1]))
        #expect(population.uiEffects.restoration == "restored")
    }

    @Test("Registered inspection publishes checked physical and host Stereo output endpoints",
          arguments: ["physical", "stereo", "send_physical", "send_stereo", "missing_checked", "conflicting_checked"])
    func registeredCheckedPhysicalOutputReachesItsGraphEndpoint(_ destination: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let isSend = destination.hasPrefix("send_")
            let prepared = isSend ? try prepare() : nil
            let f: Issue291PhysicalStripReferenceTests.Fixture
            if let prepared { f = prepared.f } else { f = try .init() }
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let isPhysical = destination == "physical" || destination == "send_physical"
            let title = isPhysical ? "Output 3-4" : "Stereo Output"
            let assignment: OutputAssignment = isPhysical ? .physical(3, 4) : .stereoOutput
            let echo = f.b.element(291_990)
            f.b.setRole(echo, kAXMenuItemRole as String)
            f.b.setAttribute(echo, kAXTitleAttribute as String, title)
            f.b.setAttribute(echo, "AXMenuItemMarkChar", "✓")
            f.b.setChildren(echo, [])
            f.b.setAttribute(f.pair, kAXTitleAttribute as String, title)
            f.b.setAttribute(f.pair, "AXMenuItemMarkChar", "✓")
            f.b.setChildren(f.root, [echo, f.b.element(2_910_202)])
            if destination == "conflicting_checked" {
                let competitor = f.b.element(291_991)
                f.b.setRole(competitor, kAXMenuItemRole as String)
                f.b.setAttribute(competitor, kAXTitleAttribute as String, "Output 5-6")
                f.b.setAttribute(competitor, "AXMenuItemMarkChar", "✓")
                f.b.setChildren(competitor, [])
                f.b.setChildren(f.b.element(2_910_203), [f.pair, competitor])
            }
            for output in f.outputs {
                // A source caption is deliberately not the checked destination's identity.
                if !isSend || !CFEqual(output, f.outputs[0]) {
                    f.b.setAttribute(output, kAXDescriptionAttribute as String, "Bus 256")
                }
                f.b.setActionNames(output, [kAXPressAction as String])
            }
            let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter(), channel = f.channel()
            await router.register(channel)
            let dependencies = HandlerDependencies(router: router, cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: channel, cache: cache, runtime: .init(hasVisibleWindow: { true },
                    projectFileReader: .unavailable, keyboardFocus: { .notTextEditing })),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: LogicMutationGate(),
                liveTrackNames: { [:] }, projectFileReader: .unavailable)
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("strips"), .string("routing")]),
                "allow_ui_navigation": .bool(destination != "missing_checked")]
            let response = await LogicProServer.runWithDeadline(tool: "logic_project", command: "inspect_session",
                commandParams: params, mutationGate: dependencies.mutationGate) {
                await FeatureFlags.withAdr002TargetRefForTests(true) { await handler(dependencies, params) }
            }
            let body = try #require(sharedJSONObject(sharedToolText(response)))
            let snapshot = try #require(body["snapshot_id"] as? String)
            let retained = try #require(await cache.retainedInspection(id: snapshot))
            let owner = try #require(retained.capture.channelStrips.first?.physicalBinding)
            let ordinal: Int? = isSend ? 1 : nil
            let checked = try #require(retained.capture.freshPopulation?.checkedOutputs.filter {
                $0.source.matches(owner) && $0.sendOrdinal == ordinal
            })
            let source = try #require(retained.capture.mixerReference(at: 0))
            let graph = try #require(body["routing"] as? [String: Any])
            let nodes = try #require(graph["nodes"] as? [[String: Any]])
            let edges = try #require(graph["edges"] as? [[String: Any]])
            if ["missing_checked", "conflicting_checked"].contains(destination) {
                #expect(checked.isEmpty)
                #expect(!nodes.contains { $0["kind"] as? String == "output" })
                #expect(!edges.contains { $0["provenance"] as? String == "axOutputMenuCheckmark" })
                #expect(f.mutations.count == (destination == "missing_checked" ? 0 : 4))
                return
            }
            #expect(checked.count == 1 && checked.first?.assignment == assignment,
                "Reach the actual registered native checked-menu producer before testing its consumer")
            let endpointID = isPhysical ? "output_physical_3_4" : "output_stereo"
            let outgoing = edges.filter { $0["source"] as? String == source.rawValue
                && $0["kind"] as? String == (isSend ? "send" : "mainOutput") }
            #expect(outgoing.count == 1)
            #expect(outgoing.first?["destination"] as? String == endpointID)
            #expect(outgoing.first?["provenance"] as? String == (isSend ? "axSendMenuCheckmark" : "axOutputMenuCheckmark"))
            if isSend {
                #expect(outgoing.first?["observedSendOrdinal"] as? Int == 1)
                #expect(outgoing.first?["send"] == nil || outgoing.first?["send"] is NSNull)
            }
            let endpoint = try #require(nodes.first { $0["id"] as? String == endpointID })
            #expect(endpoint["kind"] as? String == "output")
            #expect(endpoint["displayName"] as? String == assignment.token)
            #expect(endpoint["targetRef"] == nil || endpoint["targetRef"] is NSNull)
            #expect(nodes.filter { $0["kind"] as? String == "output" }.count == 1,
                "Two separately held sources share one typed sink, not two invented output identities")
            let mainOutputs = edges.filter { $0["kind"] as? String == "mainOutput" }
            #expect(mainOutputs.count == (isSend ? 1 : 2))
            #expect(Set(mainOutputs.compactMap { $0["source"] as? String }).count == (isSend ? 1 : 2))
            #expect(!nodes.contains { $0["id"] as? String == "output_physical_1_2" })
            #expect(graph["coverage"] as? String == "partial")
            #expect(f.mutations.count == 4)
            #expect(f.mutations.allSatisfy { element, action in
                action == kAXCancelAction as String && CFEqual(element, f.root)
                    || action == kAXPressAction as String && f.outputs.contains { CFEqual($0, element) }
            })
        }
    }

    @Test("Physical output endpoints require fresh unique native checked assignments",
          arguments: ["physical", "stereo", "bus", "distinct_stereo_pair", "absent", "foreign_owner", "conflict",
                      "duplicate", "unstable", "cached", "decoded", "refs_stale", "moved", "invalid_ports", "invalid_bus", "no_output"])
    func checkedPhysicalOutputGraphRefusesUnsupportedEvidence(_ fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let f = try Issue291PhysicalStripReferenceTests.Fixture()
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            let states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache, targetRegistry: registry, fileReader: .unavailable)
            let owner = try #require(states[0].physicalBinding)
            let source = try #require(base.mixerReference(at: 0))
            var fresh = SessionPopulationObservation.FreshPopulation(project: base.project,
                tracks: base.tracks, strips: states, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            let assignment: OutputAssignment
            switch fault {
            case "stereo", "distinct_stereo_pair": assignment = .stereoOutput
            case "bus": assignment = .bus(7)
            case "invalid_ports": assignment = .physical(3, 3)
            case "invalid_bus": assignment = .bus(257)
            case "no_output": assignment = .noOutput
            default: assignment = .physical(3, 4)
            }
            if fault != "absent" {
                let observedOwner = fault == "foreign_owner" ? AXMixerStripBinding.Binding(
                    window: f.window, mixer: f.mixer, strip: f.strips[0], document: "file:///foreign.logicx/") : owner
                fresh.checkedOutputs = [.init(source: observedOwner, assignment: assignment)]
                if fault == "conflict" || fault == "duplicate" {
                    fresh.checkedOutputs.append(.init(source: owner, assignment: fault == "conflict" ? .stereoOutput : assignment))
                }
                if fault == "distinct_stereo_pair" {
                    fresh.checkedOutputs.append(.init(source: try #require(states[1].physicalBinding), assignment: .physical(1, 2)))
                }
            }
            let rows = fault == "decoded" ? try JSONDecoder().decode([ChannelStripState].self,
                from: JSONEncoder().encode(states)) : states
            let capture = SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: rows, mixerFetchedAt: base.mixerFetchedAt,
                fileTrackCount: base.fileTrackCount, projectFileNotBound: base.projectFileNotBound,
                requestedProjectMatches: base.requestedProjectMatches, referencesEnabled: base.referencesEnabled,
                targetSnapshot: base.targetSnapshot, issued: fault == "refs_stale" ? nil : base.issued,
                projectIssuance: base.projectIssuance, beganAt: base.beganAt, endedAt: base.endedAt,
                captureID: base.captureID, freshPopulation: fault == "cached" ? nil : fresh,
                mixerReferences: base.mixerReferences)
            let graph = fault == "moved" ? RoutingGraphPublication.publish(capture: capture, project: .moved)
                : SessionPopulationObservation.routingGraph(capture: capture)
            let outgoing = graph.edges.filter { $0.source == source.rawValue && $0.kind == .mainOutput }
            if ["physical", "stereo", "bus", "distinct_stereo_pair"].contains(fault) {
                #expect(outgoing.count == 1)
                let id = fault == "physical" ? "output_physical_3_4" : fault == "bus" ? "bus_7" : "output_stereo"
                #expect(outgoing.first?.destination == id)
                #expect(outgoing.first?.provenance == .axOutputMenuCheckmark)
                #expect(graph.nodes.first { $0.id == id }?.targetRef == nil)
                if fault != "bus" { #expect(graph.coverage.physicalOutput.state == .partial) }
                #expect(routingPath(from: source, to: id, in: graph) == .unverified)
                if fault == "distinct_stereo_pair" {
                    #expect(graph.nodes.filter { $0.kind == .output }.count == 2)
                    #expect(graph.edges.contains { $0.destination == "output_physical_1_2" && $0.source != source.rawValue })
                }
            } else { #expect(outgoing.isEmpty) }
            #expect(!graph.complete)
            #expect(f.mutations.isEmpty)
        }
    }
    @Test("Registered routing capture permits only its original nonediting physical or header focus under its Help guard",
          arguments: ["healthy", "editor", "settable", "characters", "line", "detached", "duplicate", "parent", "window", "background",
                      "header_healthy", "header_popup", "header_settable", "header_value", "header_line", "header_detached", "header_window", "header_background"])
    func guardedRoutingCaptureRetainsPassivePhysicalFocus(fault input: String) async throws {
        let p = try prepare(), f = p.f
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        let isHeader = input.hasPrefix("header_")
        let fault = input == "header_popup" ? "healthy" : (isHeader ? String(input.dropFirst(7)) : input)
        let focus = isHeader ? passiveHeaderFocus(f) : try passivePhysicalFocus(f)
        if input == "header_popup" {
            let search = f.b.element(291_960)
            f.b.setRole(search, kAXTextFieldRole as String)
            f.b.setChildren(search, [])
            f.b.setChildren(f.root, try AXHelpers.childrenResult(f.root, runtime: f.logic.ax).get() + [search])
            f.onAttributeRead = { element, attribute in
                guard CFEqual(element, f.app), attribute == kAXFocusedUIElementAttribute as String else { return }
                // Focus changes with the owned action, not midway through the
                // popup witness's deciding read of its retained search identity.
                if f.mutations.last?.1 == kAXPressAction as String {
                    f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, search)
                } else if f.mutations.last?.1 == kAXCancelAction as String {
                    f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, focus)
                }
            }
        }
        switch fault {
        case "editor": f.b.setRole(focus, kAXTextFieldRole as String)
        case "settable": f.b.setAttributeSettable(focus, kAXValueAttribute as String, true)
        case "value": f.b.setAttribute(focus, kAXValueAttribute as String, NSNumber(value: 1))
        case "characters": f.b.setAttribute(focus, kAXNumberOfCharactersAttribute as String, 1)
        case "line": f.b.setAttribute(focus, kAXInsertionPointLineNumberAttribute as String, 1)
        case "detached":
            if isHeader { f.b.setChildren(f.headers[0], [f.headerVolumes[0], f.headerPans[0]]) }
            else { f.b.setChildren(f.mixer, [f.strips[0]]) }
        case "duplicate": f.b.setChildren(f.mixer, [f.strips[0], focus, focus])
        case "parent": f.b.setAttribute(focus, kAXParentAttribute as String, f.window)
        case "window": f.b.setAttribute(f.app, kAXFocusedWindowAttribute as String, f.app)
        case "background": f.b.setAttribute(f.app, kAXFrontmostAttribute as String, false)
        default: break
        }
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.inspect_session"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let scope = AccessibilityChannel.OwnedTrackStackObservationNavigation.ReadFocusScope()
        let guardian = AXHelpers.HelpReadGuard(allowHelpReads: true, stop: {
            AccessibilityChannel.readLogicKeyboardFocus(runtime: f.logic) != .notTextEditing && !scope.permits()
        })
        do {
            let population = try await OperationTraceContext.$current.withValue(context) {
                try await AXHelpers.HelpReadGuard.$current.withValue(guardian) {
                    try await f.channel().readFreshSessionPopulation(request: .init(domains: [.routing],
                        allowUINavigation: true), fileReader: .unavailable, readFocusScope: scope,
                        stoppingBeforeAXRead: { guardian.stopped }, stoppingWhen: { guardian.stopped })
                }
            }
            #expect(fault == "healthy")
            #expect(population.stable)
            #expect(population.checkedOutputs.count == 2)
            let send = try #require(population.checkedOutputs.first { $0.sendOrdinal == 1 })
            #expect(send.assignment == .bus(1))
            #expect(CFEqual(send.source.strip, f.strips[0]))
            let output = try #require(population.checkedOutputs.first { $0.sendOrdinal == nil })
            #expect(output.assignment == .bus(1))
            #expect(f.b.attributeValue(f.outputs[1], kAXDescriptionAttribute as String) as? String == "Stereo Output")
            #expect(CFEqual(output.source.strip, f.strips[1]))
            #expect(f.mutations.map { $0.1 } == ["AXPress", "AXCancel", "AXPress", "AXCancel"])
            let presses = f.mutations.filter { $0.1 == kAXPressAction as String }
            try #require(presses.count == 2)
            #expect(CFEqual(presses[0].0, f.outputs[0]) && CFEqual(presses[1].0, f.outputs[1]))
            #expect(population.uiEffects.restoration == "restored")
            let currentFocus: AXUIElement = try #require(AXHelpers.getAttribute(f.app,
                kAXFocusedUIElementAttribute as String, runtime: f.logic.ax))
            #expect(CFEqual(currentFocus, focus))
        } catch {
            #expect(fault != "healthy")
            #expect(f.mutations.isEmpty)
        }
        #expect(!scope.permits())
    }
    @Test("A checked send graph edge is tied to its source census, not a physical write slot",
          arguments: ["held", "absent", "other_owner", "conflict", "unstable", "empty", "duplicate_ordinal", "stereo", "physical", "invalid_bus", "invalid_physical", "no_output", "negative_ordinal", "moved", "decoded_known", "cache_only", "refs_stale"])
    func checkedSendGraphUsesOnlyHeldCensus(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let p = try prepare(), f = p.f
            defer { try? FileManager.default.removeItem(at: f.bundle) }
            var states = try #require(AccessibilityChannel.defaultGetMixerStates(
                runtime: f.logic, stoppingWhen: { false }).states)
            if fault == "empty" { states[0].sendSlots?[1].state = .observedEmpty }
            if fault == "duplicate_ordinal", let slot = states[0].sendSlots?[1] { states[0].sendSlots?.append(slot) }
            if fault == "decoded_known" {
                states[0].sendSlots?[1] = try JSONDecoder().decode(SendSlotObservation.self, from: Data(
                    #"{"ordinal":1,"state":"occupied_known_destination","checked_destination":"bus:1","destination_source":"ax_send_menu_checkmark","level_raw":0,"bypassed":false,"destination_display":"Bus 256"}"#.utf8))
            }
            let cache = StateCache(), registry = TargetRegistry()
            await cache.updateProject(.init(name: "Session", filePath: f.bundle.path, source: "fixture"))
            await cache.updateDocumentState(true)
            await cache.updateChannelStrips(states)
            let base = await SessionPopulationObservation.capture(cache: cache,
                targetRegistry: registry, fileReader: .unavailable)
            let owner = try #require(states[0].physicalBinding)
            let source = try #require(base.mixerReference(at: 0))
            var fresh = SessionPopulationObservation.FreshPopulation(project: base.project,
                tracks: base.tracks, strips: states, fileTrackCount: nil,
                beganAt: base.beganAt, endedAt: base.endedAt, stable: fault != "unstable")
            if fault != "absent" {
                fresh.checkedOutputs = [.init(source: fault == "other_owner"
                    ? try #require(states[1].physicalBinding) : owner,
                    assignment: fault == "stereo" ? .stereoOutput : (fault == "physical" ? .physical(3, 4)
                        : (fault == "invalid_physical" ? .physical(3, 3) : (fault == "invalid_bus" ? .bus(999)
                        : (fault == "no_output" ? .noOutput : .bus(1))))),
                    sendOrdinal: fault == "negative_ordinal" ? -1 : 1)]
                if fault == "conflict" {
                    fresh.checkedOutputs.append(.init(source: owner, assignment: .bus(2), sendOrdinal: 1))
                }
            }
            let capture = SessionPopulationObservation.Capture(before: base.before, after: base.after,
                projectEpoch: base.projectEpoch, project: base.project, tracks: base.tracks,
                tracksFetchedAt: base.tracksFetchedAt, channelStrips: base.channelStrips,
                mixerFetchedAt: base.mixerFetchedAt, fileTrackCount: base.fileTrackCount,
                projectFileNotBound: base.projectFileNotBound,
                requestedProjectMatches: base.requestedProjectMatches,
                referencesEnabled: base.referencesEnabled, targetSnapshot: base.targetSnapshot,
                issued: fault == "refs_stale" ? nil : base.issued, projectIssuance: base.projectIssuance,
                beganAt: base.beganAt, endedAt: base.endedAt, captureID: base.captureID,
                freshPopulation: fault == "cache_only" ? nil : fresh, mixerReferences: base.mixerReferences)
            let graph = fault == "moved" ? RoutingGraphPublication.publish(capture: capture, project: .moved)
                : SessionPopulationObservation.routingGraph(capture: capture)
            let edges = graph.edges.filter { $0.source == source.rawValue && $0.kind == .send }
            if ["held", "stereo", "physical"].contains(fault) {
                #expect(edges.count == 1)
                let edge = try #require(edges.first)
                let endpoint = fault == "stereo" ? "output_stereo" : fault == "physical" ? "output_physical_3_4" : "bus_1"
                #expect(edge.destination == endpoint)
                #expect(edge.send == nil)
                #expect(edge.observedSendOrdinal == 1)
                #expect(edge.provenance.rawValue == "axSendMenuCheckmark")
                #expect(graph.nodes.first { $0.id == endpoint }?.targetRef == nil)
                #expect(graph.coverage.sends.state == .partial)
                #expect(routingPath(from: source, to: endpoint, in: graph) == .unverified)
            } else { #expect(edges.isEmpty) }
            if fault != "moved" {
                let report = SessionPopulationObservation.build(request: .init(domains: [.routing, .strips]), capture: capture)
                let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
                let rows = try #require((wire["strips"] as? [String: Any])?["rows"] as? [[String: Any]])
                let slots = try #require(rows.first?["send_slots"] as? [[String: Any]])
                let slot = try #require(slots.first { $0["ordinal"] as? Int == 1 })
                if ["held", "stereo", "physical"].contains(fault) {
                    #expect(slot["state"] as? String == "occupied_known_destination")
                    let expected = fault == "stereo" ? "stereo_output" : (fault == "physical" ? "physical:3-4" : "bus:1")
                    #expect(slot["checked_destination"] as? String == expected)
                    #expect(slot["destination_source"] as? String == "ax_send_menu_checkmark")
                } else {
                    #expect(slot["state"] as? String == (fault == "empty" ? "observed_empty" : "occupied_unknown_destination"))
                    #expect(slot["checked_destination"] == nil)
                    #expect(slot["destination_source"] == nil)
                }
                #expect(slot["level_raw"] as? Double == 0)
                let bypassed = try #require(slot["bypassed"] as? Bool)
                #expect(!bypassed)
                #expect(slot["destination_display"] as? String == "Bus 256")
                #expect(states[0].sendSlots?[1].state == (fault == "empty" ? .observedEmpty
                    : (fault == "decoded_known" ? .occupiedKnownDestination : .occupiedUnknownDestination)))
            }
            #expect(!graph.complete)
            let decision = evaluate(.init(sourceTrackRef: source, physicalSlot: 1,
                destinationBusNumber: 1, destinationRef: nil, expectedProjectEpoch: graph.projectEpoch), against: graph)
            #expect(!decision.allowed)
            #expect(!decision.writeAttempted)
            #expect(f.mutations.isEmpty)
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
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "checked-send-focus-receipt"))
        defer { gate.release(claim) }
        let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { gate.stillOwns(claim) })
        let response = await OperationTraceContext.$current.withValue(context) { await read(p) }
        let body = try #require(sharedJSONObject(response.message))
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
    @Test("A routing read cannot acquire a popup after its request stops",
          arguments: ["expired", "cancelled_at_capability", "gate_lost_at_capability"])
    func stoppedRequestDoesNotAcquireRoutingPopup(_ fault: String) async throws {
        let p = try prepare(), f = p.f
        let gate = LogicMutationGate()
        let claim = try #require(gate.tryAcquire(operation: "logic_project.apply_session_repair"))
        defer { gate.release(claim) }
        let stopped = RequestStop()
        f.onActionNamesRead = { control in
            guard CFEqual(control, f.outputs[0]) else { return }
            if fault == "cancelled_at_capability" {
                stopped.stop()
            }
            if fault == "gate_lost_at_capability" { gate.release(claim) }
        }
        let context = OperationTraceContext(mutationGateAcquired: true,
            ownsGate: { gate.stillOwns(claim) },
            deadline: ContinuousClock.now.advanced(by: .seconds(fault == "expired" ? -1 : 30)),
            cancellationRequested: { stopped.isStopped })
        let response = await OperationTraceContext.$current.withValue(context) { await read(p) }
        let body = try #require(sharedJSONObject(response.message))
        #expect(body["state"] as? String == "C")
        #expect(body["current_destination"] == nil)
        let navigated = try #require(body["navigation_attempted"] as? Bool)
        #expect(!navigated)
        #expect(f.mutations.isEmpty, "An expired or revoked request must not leave a newly opened popup")
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
