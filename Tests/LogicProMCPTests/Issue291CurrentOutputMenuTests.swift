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
          arguments: ["owned", "remembered", "source_read", "document", "source", "slot", "popup", "gate", "deadline"])
    func cancelledOutputReadCleansOnlyItsOwnedPopup(_ revocation: String) async throws {
        let f = try Issue291PhysicalStripReferenceTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.bundle) }
        prepare(f)
        f.b.setAttribute(f.app, kAXFrontmostAttribute as String, true)
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
        let cleanupOwned = revocation == "owned" || revocation == "remembered" || revocation == "source_read"
        #expect(cancels.count == (cleanupOwned ? 1 : 0))
        #expect(f.mutations.filter { $0.1 == kAXPressAction as String }.count == 1)
        if cleanupOwned {
            let cancel = try #require(cancels.first)
            #expect(CFEqual(cancel.0, f.root))
            #expect(body["popup_menu_state"] as? String == "closed")
            #expect(body["focus_restoration"] as? String == "restored")
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
