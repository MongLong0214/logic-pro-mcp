@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#968 exact physical Mixer name writer", .serialized)
struct Issue968MixerNameWriterTests {
    final class Fixture: @unchecked Sendable {
        let source: Issue291PhysicalStripReferenceTests.Fixture
        let plate: AXUIElement
        let editor: AXUIElement
        let originalChildren: [AXUIElement]
        var events: [String] = []
        var acknowledgeOnly = false
        var afterEditorAcquisition: (() -> Void)?
        var afterValueSet: (() -> Void)?
        var authorized = true
        var beforeAttributeRead: ((AXUIElement, String) -> Void)?
        var afterFirstClick: (() -> Void)?

        init() throws {
            source = try .init(aux: true)
            originalChildren = AXHelpers.getChildren(source.strips[2], runtime: source.b.makeAXRuntime())
            plate = originalChildren[0]
            editor = source.b.element(968_500)
            source.b.setFrame(plate, x: 160, y: 470, width: 70, height: 20)
            source.b.setRole(editor, kAXTextFieldRole as String)
            source.b.setAttribute(editor, kAXDescriptionAttribute as String, "Name")
            source.b.setAttribute(editor, kAXWindowAttribute as String, source.window)
            source.b.setAttribute(editor, kAXValueAttribute as String, "Aux")
            source.b.setAttributeSettable(editor, kAXValueAttribute as String, true)
            source.b.setChildren(editor, [])
        }

        var logic: AXLogicProElements.Runtime {
            let ax = source.b.makeAXRuntime(appElement: source.app,
                attributeValueHandler: { [self] element, attribute in
                    beforeAttributeRead?(element, attribute); return nil
                },
                attributeValueResultHandler: { [self] element, attribute in
                    beforeAttributeRead?(element, attribute); return nil
                },
                childrenHandler: { [self] element in
                    beforeAttributeRead?(element, kAXChildrenAttribute as String); return nil
                },
                childrenResultHandler: { [self] element in
                    beforeAttributeRead?(element, kAXChildrenAttribute as String); return nil
                },
                setAttributeHandler: { [self] element, attribute, value in
                    guard CFEqual(element, editor), attribute == kAXValueAttribute as String,
                          let name = value as? String else {
                        Issue.record("A different control was written"); return false
                    }
                    events.append("name_value")
                    if !acknowledgeOnly { source.b.setAttribute(editor, attribute, name) }
                    afterValueSet?()
                    return true
                },
                performActionHandler: { _, _ in Issue.record("No unrelated AX action is authorized"); return false },
                elementAtPosition: { [self] _, point in
                    point == CGPoint(x: 195, y: 480) ? .success(plate) : .success(nil)
                })
            return .init(logicProPID: { [self] in source.pid }, ax: ax,
                executeAppleScript: { _ in Issue.record("No scripting fallback"); return .error("forbidden") },
                onScreenWindowList: { [] },
                postPopupMenuEscape: { Issue.record("No unowned Escape") },
                focusedApplicationPID: { [self] in source.pid })
        }

        var mouse: AXMouseHelper.Runtime {
            .init(postMouseEvent: { _, _, _ in Issue.record("Only prepared paired clicks are permitted"); return false },
                postKeyEvent: { [self] key in
                    guard key == 36 else { Issue.record("No unrelated key"); return false }
                    events.append("commit")
                    source.b.setAttribute(plate, kAXValueAttribute as String,
                        source.b.attributeValue(editor, kAXValueAttribute as String) as? String ?? "Aux")
                    source.b.setChildren(source.strips[2], originalChildren)
                    source.b.setAttribute(source.app, kAXFocusedUIElementAttribute as String, source.window)
                    return true
                },
                postUnicodeScalar: { _ in Issue.record("No blind typing fallback"); return false },
                sleepMicros: { _ in },
                prepareMouseClick: { [self] point, count in
                    guard point == CGPoint(x: 195, y: 480) else { return nil }
                    return .init(postDown: { [self] in
                        events.append("down\(count)")
                        if count == 2 {
                            source.b.setChildren(source.strips[2], [editor] + originalChildren.dropFirst())
                            source.b.setAttribute(source.app, kAXFocusedUIElementAttribute as String, editor)
                            afterEditorAcquisition?()
                        }
                        return true
                    }, postUp: { [self] in
                        events.append("up\(count)")
                        if count == 1 { afterFirstClick?() }
                        return true
                    })
                })
        }

        func run(expected: String, desired: String) async throws -> [String: Any] {
            guard let states = AccessibilityChannel.defaultGetMixerStates(runtime: logic, stoppingWhen: { false }).states,
                  let owner = states.first(where: { $0.name == "Aux" })?.physicalBinding else {
                Issue.record("The actual physical Mixer producer did not issue the target")
                return [:]
            }
            let channel = AccessibilityChannel(runtime: .axBacked(isTrusted: { true },
                isLogicProRunning: { true }, hasVisibleWindow: { true }, logicRuntime: logic,
                observationMouseRuntime: mouse, canPostEvents: { true }))
            let context = OperationTraceContext(mutationGateAcquired: true, ownsGate: { [self] in authorized })
            let result = await OperationTraceContext.$current.withValue(context) {
                await AXMixerStripBinding.$current.withValue(owner) {
                    await channel.execute(operation: "mixer.rename_exact", params: ["expected_name": expected, "name": desired])
                }
            }
            let text: String
            switch result { case .success(let value), .error(let value): text = value }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        }
    }

    @Test func aPhysicalAuxUsesOnlyItsOwnedEditorAndCommittedNameReadback() async throws {
        let f = try Fixture()
        let body = try await f.run(expected: "Aux", desired: "Return, aux α")
        #expect(body["state"] as? String == "A")
        #expect(body["before"] as? String == "Aux")
        #expect(body["observed"] as? String == "Return, aux α")
        let attempted = try #require(body["write_attempted"] as? Bool)
        #expect(attempted)
        #expect(f.events == ["down1", "up1", "down2", "up2", "name_value", "commit"])
        #expect(AXPluginInstanceIdentity.stripName(f.source.strips[2], runtime: f.logic.ax) == "Return, aux α")
        #expect(AXPluginInstanceIdentity.stripName(f.source.strips[0], runtime: f.logic.ax) == "B")
        #expect(AXValueExtractors.extractSelectedState(f.source.headers[0], runtime: f.logic.ax) == Optional(false))
        #expect(AXValueExtractors.extractSelectedState(f.source.headers[1], runtime: f.logic.ax) == Optional(false))
    }

    @Test(arguments: ["before_setter", "before_commit"])
    func transportStartingDuringAcquisitionStopsTheNextWrite(boundary: String) async throws {
        let f = try Fixture()
        let start: () -> Void = {
            f.source.b.setAttribute(f.source.b.element(2_910_301), kAXValueAttribute as String, 1)
        }
        if boundary == "before_setter" { f.afterEditorAcquisition = start }
        else { f.afterValueSet = start }
        let body = try await f.run(expected: "Aux", desired: "Changed")
        #expect(body["state"] as? String == "B")
        #expect(!f.events.contains("commit"))
        if boundary == "before_setter" { #expect(!f.events.contains("name_value")) }
    }

    @Test(arguments: ["before_first", "after_first"])
    func theOriginalStripCanHoldFocusWhileItsNamePlateIsPassive(boundary: String) async throws {
        let f = try Fixture()
        f.source.b.setRole(f.source.strips[2], "AXLayoutItem")
        f.source.b.setAttribute(f.source.strips[2], kAXInsertionPointLineNumberAttribute as String, 0)
        f.source.b.setAttributeSettable(f.plate, kAXValueAttribute as String, false)
        let focus: () -> Void = {
            f.source.b.setAttribute(f.source.app, kAXFocusedUIElementAttribute as String, f.source.strips[2])
        }
        if boundary == "before_first" { focus() }
        else { f.afterFirstClick = focus }
        let body = try await f.run(expected: "Aux", desired: "Return, aux α")
        #expect(body["state"] as? String == "A")
        #expect(body["observed"] as? String == "Return, aux α")
        #expect(f.events == ["down1", "up1", "down2", "up2", "name_value", "commit"])
    }

    @Test(arguments: ["before_setter", "before_commit"])
    func aNewModalStopsTheNextWrite(boundary: String) async throws {
        let f = try Fixture()
        let block: () -> Void = {
            let dialog = f.source.b.element(968_501)
            f.source.b.setRole(dialog, kAXWindowRole as String)
            f.source.b.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
            f.source.b.setAttribute(dialog, kAXModalAttribute as String, true)
            f.source.b.setChildren(dialog, [])
            f.source.b.setAttribute(f.source.app, kAXWindowsAttribute as String, [f.source.window, dialog])
        }
        if boundary == "before_setter" { f.afterEditorAcquisition = block }
        else { f.afterValueSet = block }
        let body = try await f.run(expected: "Aux", desired: "Changed")
        #expect(body["state"] as? String == "B")
        #expect(!f.events.contains("commit"))
        if boundary == "before_setter" { #expect(!f.events.contains("name_value")) }
    }

    @Test(arguments: ["wrong_expected", "no_op", "ack_only", "foreign_focus", "document_changed", "strip_removed", "authority_lost"])
    func failuresDoNotGrantCommitAuthority(change: String) async throws {
        let f = try Fixture()
        if change == "ack_only" { f.acknowledgeOnly = true }
        f.afterEditorAcquisition = {
            switch change {
            case "foreign_focus": f.source.b.setAttribute(f.source.app, kAXFocusedUIElementAttribute as String, f.source.headers[0])
            case "document_changed": f.source.b.setAttribute(f.source.window, kAXDocumentAttribute as String, f.source.bundle.appendingPathComponent("other.logicx").absoluteString)
            case "strip_removed": f.source.b.setChildren(f.source.mixer, Array(f.source.strips.prefix(2)))
            case "authority_lost": f.authorized = false
            default: break
            }
        }
        let body = try await f.run(expected: change == "wrong_expected" ? "Other" : "Aux",
            desired: change == "no_op" ? "Aux" : "Changed")
        let early = ["wrong_expected", "no_op"].contains(change)
        #expect(body["state"] as? String == (change == "no_op" ? "A" : early ? "C" : "B"))
        #expect(!f.events.contains("commit"))
        if early { #expect(f.events.isEmpty) }
        else if change == "ack_only" { #expect(f.events.contains("name_value")) }
        else { #expect(!f.events.contains("name_value")) }
        #expect(AXPluginInstanceIdentity.stripName(f.source.strips[2], runtime: f.logic.ax) == "Aux")
        #expect(AXPluginInstanceIdentity.stripName(f.source.strips[0], runtime: f.logic.ax) == "B")
    }

    @Test(arguments: ["before_setter", "before_commit"], ["window", "foreign_focus"])
    func theLastDialogCensusCannotAuthorizeAWrittenOldWindow(boundary: String, change: String) async throws {
        let f = try Fixture()
        var ready = false
        var stoppedSampled = false
        var changed = false
        if boundary == "before_setter" { f.afterEditorAcquisition = { ready = true } }
        else { f.afterValueSet = { ready = true } }
        f.beforeAttributeRead = { element, attribute in
            if ready, CFEqual(element, f.source.b.element(2_910_302)), attribute == kAXValueAttribute as String {
                stoppedSampled = true
            }
            if stoppedSampled, !changed, CFEqual(element, f.source.app), attribute == kAXWindowsAttribute as String {
                changed = true
                let other = f.source.b.element(968_502)
                if change == "foreign_focus" {
                    f.source.b.setRole(other, kAXTextFieldRole as String)
                    f.source.b.setAttribute(other, kAXWindowAttribute as String, f.source.window)
                    f.source.b.setAttribute(other, kAXValueAttribute as String, "Unrelated editing")
                    f.source.b.setAttribute(f.source.app, kAXFocusedUIElementAttribute as String, other)
                    return
                }
                f.source.b.setRole(other, kAXWindowRole as String)
                f.source.b.setAttribute(other, kAXTitleAttribute as String, "Other - Tracks")
                f.source.b.setAttribute(other, kAXDocumentAttribute as String, f.source.bundle.absoluteString)
                f.source.b.setChildren(other, [])
                f.source.b.setAttribute(f.source.app, kAXWindowsAttribute as String, [other])
                f.source.b.setAttribute(f.source.app, kAXMainWindowAttribute as String, other)
                f.source.b.setAttribute(f.source.app, kAXFocusedWindowAttribute as String, other)
            }
        }
        let body = try await f.run(expected: "Aux", desired: "Changed")
        #expect(changed, "The last modal census must actually change the window or keyboard owner")
        #expect(body["state"] as? String == "B")
        #expect(!f.events.contains("commit"))
        if boundary == "before_setter" { #expect(!f.events.contains("name_value")) }
    }

    @Test(arguments: ["transport", "modal", "foreign_editor", "foreign_insertion_point"])
    func aChangedGestureBoundaryCompletesOnlyTheFirstPair(change: String) async throws {
        let f = try Fixture()
        f.afterFirstClick = {
            switch change {
            case "transport": f.source.b.setAttribute(f.source.b.element(2_910_301), kAXValueAttribute as String, 1)
            case "modal":
                let sheet = f.source.b.element(968_503)
                f.source.b.setRole(sheet, kAXSheetRole as String)
                f.source.b.setChildren(sheet, [])
                f.source.b.setChildren(f.source.window, f.source.b.makeAXRuntime().children(f.source.window) + [sheet])
            default:
                let other = f.source.b.element(968_504)
                f.source.b.setRole(other, change == "foreign_insertion_point" ? "AXLayoutItem" : kAXTextFieldRole as String)
                if change == "foreign_insertion_point" {
                    f.source.b.setAttribute(other, kAXInsertionPointLineNumberAttribute as String, 0)
                }
                f.source.b.setAttribute(other, kAXValueAttribute as String, "Unrelated editing")
                f.source.b.setAttribute(f.source.app, kAXFocusedUIElementAttribute as String, other)
            }
        }
        let body = try await f.run(expected: "Aux", desired: "Changed")
        #expect(body["state"] as? String == "B")
        #expect(f.events == ["down1", "up1"])
    }

    @Test func passiveFocusValidationCannotKeepAnOldWindowAuthorizedForTheSecondPair() async throws {
        let f = try Fixture()
        f.source.b.setRole(f.source.strips[2], "AXLayoutItem")
        f.source.b.setAttribute(f.source.strips[2], kAXInsertionPointLineNumberAttribute as String, 0)
        f.source.b.setAttributeSettable(f.plate, kAXValueAttribute as String, false)
        var focused = false
        var focusClassified = false
        var changed = false
        f.afterFirstClick = {
            focused = true
            f.source.b.setAttribute(f.source.app, kAXFocusedUIElementAttribute as String, f.source.strips[2])
        }
        f.beforeAttributeRead = { element, attribute in
            if focused, CFEqual(element, f.source.strips[2]), attribute == kAXInsertionPointLineNumberAttribute as String {
                focusClassified = true
            }
            // The preceding final owner check has sampled its window. The
            // passive-focus allowance then reads this exact strip's fields.
            if focusClassified, !changed, CFEqual(element, f.source.strips[2]), attribute == kAXChildrenAttribute as String {
                changed = true
                let other = f.source.b.element(968_505)
                f.source.b.setRole(other, kAXWindowRole as String)
                f.source.b.setAttribute(other, kAXTitleAttribute as String, "Other - Tracks")
                f.source.b.setAttribute(other, kAXDocumentAttribute as String, f.source.bundle.absoluteString)
                f.source.b.setChildren(other, [])
                f.source.b.setAttribute(f.source.app, kAXWindowsAttribute as String, [other])
                f.source.b.setAttribute(f.source.app, kAXMainWindowAttribute as String, other)
                f.source.b.setAttribute(f.source.app, kAXFocusedWindowAttribute as String, other)
            }
        }
        let body = try await f.run(expected: "Aux", desired: "Changed")
        #expect(changed)
        #expect(body["state"] as? String == "B")
        #expect(f.events == ["down1", "up1"])
    }

    @Test func focusClassificationCannotBorrowAnotherObjectsNoneditingRole() async throws {
        let f = try Fixture()
        let foreign = f.source.b.element(968_506)
        f.source.b.setRole(foreign, kAXTextFieldRole as String)
        f.source.b.setAttribute(foreign, kAXValueAttribute as String, "Unrelated editing")
        var ready = false
        var focusedReads = 0
        f.afterFirstClick = {
            ready = true
            f.source.b.setAttribute(f.source.app, kAXFocusedUIElementAttribute as String, foreign)
        }
        f.beforeAttributeRead = { element, attribute in
            if ready, CFEqual(element, f.source.app), attribute == kAXFocusedUIElementAttribute as String {
                focusedReads += 1
                f.source.b.setAttribute(f.source.app, attribute, focusedReads == 2 ? f.source.window : foreign)
            }
        }
        let body = try await f.run(expected: "Aux", desired: "Changed")
        #expect(focusedReads > 0)
        #expect(body["state"] as? String == "B")
        #expect(f.events == ["down1", "up1"])
    }
}
