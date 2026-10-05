@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// The private read-only 2026-10-05 probe observed a Logic-owned AXWindow,
/// AXDialog subrole, explicit AXModal false and one WindowSharingSessionButton.
/// These injected witnesses do not claim that a native operation succeeded.
@Suite(.serialized)
struct Issue1084NonmodalDialogTests {
    private struct Fixture: @unchecked Sendable {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let arrange: AXUIElement
        let dialog: AXUIElement
        let button: AXUIElement

        init(modal: AnyObject? = NSNumber(value: false), sharingFirst: Bool = true) {
            app = builder.element(1084_700)
            arrange = builder.element(1084_701)
            dialog = builder.element(1084_702)
            button = builder.element(1084_703)
            builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
            builder.setAttribute(app, kAXWindowsAttribute as String,
                                 sharingFirst ? [dialog, arrange] : [arrange, dialog])
            builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(arrange, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
            builder.setAttribute(arrange, kAXModalAttribute as String, false)
            builder.setChildren(arrange, [])
            builder.setAttribute(dialog, kAXRoleAttribute as String, kAXWindowRole as String)
            builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
            builder.setAttribute(dialog, kAXTitleAttribute as String, "Window")
            if let modal { builder.setAttribute(dialog, kAXModalAttribute as String, modal) }
            builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setAttribute(button, kAXTitleAttribute as String, "WindowSharingSessionButton")
            builder.setChildren(dialog, [button])
            builder.setChildren(button, [])
        }

        var runtime: AXLogicProElements.Runtime {
            builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: nil)
        }

        func noActions() {
            #expect(builder.setCalls.isEmpty)
            #expect(builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func explicitNonmodalDialogDoesNotBlockByItsClass(sharingFirst: Bool) {
        let f = Fixture(sharingFirst: sharingFirst)
        let runtime = f.runtime
        #expect(!AXLogicProElements.isBlockingDialogWindow(f.dialog, runtime: runtime.ax))
        #expect(AXLogicProElements.dialogPresenceReason(runtime: runtime) == .noBlockingWindow)
        #expect(!AXLogicProElements.dialogPresent(runtime: runtime))
        #expect(AXLogicProElements.blockingDialogTarget(runtime: runtime) == nil)
        f.noActions()
    }

    @Test func sharingButtonDoesNotExemptAnActuallyModalDialog() {
        let f = Fixture(modal: NSNumber(value: true))
        let runtime = f.runtime
        #expect(AXLogicProElements.isBlockingDialogWindow(f.dialog, runtime: runtime.ax))
        #expect(AXLogicProElements.dialogPresenceReason(runtime: runtime) == .blockingWindowFound)
        #expect(AXLogicProElements.dialogPresent(runtime: runtime))
        f.noActions()
    }

    enum UnknownModal: CaseIterable, Sendable {
        case absent, numericZero, stringFalse, array, noValue, unsupported, cannotComplete, failure
    }

    @Test(arguments: UnknownModal.allCases)
    func unknownOrMalformedModalDoesNotBecomeExplicitFalse(answer: UnknownModal) {
        let payload: AnyObject?
        switch answer {
        case .numericZero: payload = NSNumber(value: 0)
        case .stringFalse: payload = "false" as NSString
        case .array: payload = [] as NSArray
        default: payload = nil
        }
        let f = Fixture(modal: payload)
        let status: AXError?
        switch answer {
        case .noValue: status = .noValue
        case .unsupported: status = .attributeUnsupported
        case .cannotComplete: status = .cannotComplete
        case .failure: status = .failure
        default: status = nil
        }
        let runtime = f.builder.makeLogicRuntime(appElement: f.app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, f.dialog), attribute == (kAXModalAttribute as String) else { return nil }
                if let status { return .failure(AXHelpers.AXStatusError(raw: status.rawValue)) }
                // Avoid the fixture builder's Bool bridge turning NSNumber(0)
                // into CFBoolean false before the production reader sees it.
                if case .numericZero = answer { return .success(NSNumber(value: 0)) }
                return nil
            }, setAttributeHandler: nil, performActionHandler: nil)
        #expect(AXLogicProElements.isBlockingDialogWindow(f.dialog, runtime: runtime.ax))
        #expect(AXLogicProElements.dialogPresent(runtime: runtime))
        f.noActions()
    }

    @Test func nonmodalDialogStillBlocksWhenItHostsASheet() {
        let f = Fixture()
        let sheet = f.builder.element(1084_704)
        f.builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        f.builder.setChildren(sheet, [])
        f.builder.setChildren(f.dialog, [f.button, sheet])
        #expect(AXLogicProElements.dialogPresenceReason(runtime: f.runtime) == .blockingWindowFound)
        #expect(AXLogicProElements.dialogPresent(runtime: f.runtime))
        f.noActions()
    }

    @Test func nonmodalDialogWithUnreadableChildrenCannotCertifyAbsence() {
        let f = Fixture()
        let runtime = f.builder.makeLogicRuntime(appElement: f.app,
            childrenResultHandler: { element in
                guard CFEqual(element, f.dialog) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            }, setAttributeHandler: nil, performActionHandler: nil)
        #expect(AXLogicProElements.dialogPresenceReason(runtime: runtime) == .windowChildrenUnreadable)
        #expect(AXLogicProElements.dialogPresent(runtime: runtime))
        f.noActions()
    }

    @Test func nonmodalFirstWindowDoesNotHideALaterModal() throws {
        let f = Fixture()
        let modal = f.builder.element(1084_705)
        f.builder.setAttribute(modal, kAXRoleAttribute as String, kAXWindowRole as String)
        f.builder.setAttribute(modal, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        f.builder.setAttribute(modal, kAXModalAttribute as String, true)
        f.builder.setChildren(modal, [])
        f.builder.setAttribute(f.app, kAXWindowsAttribute as String, [f.dialog, f.arrange, modal])
        let runtime = f.runtime
        #expect(AXLogicProElements.dialogPresenceReason(runtime: runtime) == .blockingWindowFound)
        let target = try #require(AXLogicProElements.blockingDialogTarget(runtime: runtime))
        #expect(CFEqual(target.element, modal))
        f.noActions()
    }
}
