import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite(.serialized)
struct Issue971ModalCensusRecoveryTests {
    private final class Fixture: @unchecked Sendable {
        let b = FakeAXRuntimeBuilder()
        let app: AXUIElement, window: AXUIElement, child: AXUIElement
        let sheet: AXUIElement, dialog: AXUIElement, broken: AXUIElement
        let stage: String, recovery: String, status: Int32, persistent: Bool
        let initialModal: Bool, initialWindowsFailure: Bool, mixedFailure: Bool
        private(set) var windowsReads = 0, childrenReads = 0, roleReads = 0

        init(stage: String, recovery: String = "clear", status: Int32 = AXError.cannotComplete.rawValue,
             persistent: Bool = false, initialModal: Bool = false, initialWindowsFailure: Bool = false,
             mixedFailure: Bool = false) {
            self.stage = stage; self.recovery = recovery; self.status = status
            self.persistent = persistent; self.initialModal = initialModal
            self.initialWindowsFailure = initialWindowsFailure
            self.mixedFailure = mixedFailure
            app = b.element(971_608_0); window = b.element(971_608_1)
            child = b.element(971_608_2); sheet = b.element(971_608_3); dialog = b.element(971_608_4)
            broken = b.element(971_608_5)
            for element in [window, dialog, broken] { b.setRole(element, kAXWindowRole as String) }
            b.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
            b.setAttribute(broken, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
            b.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
            b.setAttribute(dialog, kAXTitleAttribute as String, "Save")
            b.setRole(child, kAXGroupRole as String); b.setRole(sheet, kAXSheetRole as String)
            b.setChildren(window, [child]); b.setChildren(child, [])
            b.setChildren(sheet, []); b.setChildren(dialog, [])
        }

        func runtime() -> AXLogicProElements.Runtime {
            b.makeLogicRuntime(appElement: app, attributeValueResultHandler: { [self] element, attribute in
                if CFEqual(element, app), attribute == kAXWindowsAttribute as String {
                    windowsReads += 1
                    if initialWindowsFailure, windowsReads == 1 {
                        return .failure(.init(raw: AXError.cannotComplete.rawValue))
                    }
                    return .success(([window] + (initialModal || (windowsReads > 1 && recovery == "dialog")
                        ? [dialog] : []) + (mixedFailure && windowsReads == 1 ? [broken] : [])) as AnyObject)
                }
                if CFEqual(element, child), attribute == kAXRoleAttribute as String {
                    roleReads += 1
                    if stage == "role", persistent || roleReads == 1 { return .failure(.init(raw: status)) }
                }
                return nil
            }, childrenResultHandler: { [self] element in
                if CFEqual(element, broken) { return .failure(.init(raw: AXError.apiDisabled.rawValue)) }
                guard CFEqual(element, window) else { return nil }
                childrenReads += 1
                if stage == "children", persistent || childrenReads == 1 { return .failure(.init(raw: status)) }
                return .success([child] + (windowsReads > 1 && recovery == "sheet" ? [sheet] : []))
            }, setAttributeHandler: { _, _, _ in Issue.record("Modal census cannot write"); return false },
                performActionHandler: { _, _ in Issue.record("Modal census cannot act"); return false })
        }
    }

    @Test("One incomplete modal census can recover only through a fresh complete windows and child census",
          arguments: ["children", "role"])
    func transientCensusNeedsFreshCompleteProof(stage: String) {
        let f = Fixture(stage: stage)
        let reason = AXLogicProElements.dialogPresenceReason(runtime: f.runtime())
        #expect(reason == .noBlockingWindow)
        #expect(f.windowsReads == 2 && f.childrenReads == 2)
        #expect(f.roleReads == (stage == "role" ? 2 : 1))
    }

    @Test("A modal appearing during the reread remains blocking, including a newly listed foreign window",
          arguments: ["children", "role"], ["sheet", "dialog"])
    func freshCensusCannotEraseAModal(stage: String, recovery: String) {
        let f = Fixture(stage: stage, recovery: recovery)
        let reason = AXLogicProElements.dialogPresenceReason(runtime: f.runtime())
        #expect(reason == .blockingWindowFound)
        #expect(reason.namesAnActualDialog)
        #expect(f.windowsReads == 2)
    }

    @Test("Persistent incomplete modal censuses remain unknown after exactly one reread",
          arguments: ["children", "role"])
    func persistentCensusRemainsBlocked(stage: String) {
        let f = Fixture(stage: stage, persistent: true)
        let reason = AXLogicProElements.dialogPresenceReason(runtime: f.runtime())
        #expect(reason == .windowChildrenUnreadable && !reason.namesAnActualDialog)
        #expect(f.windowsReads == 2 && f.childrenReads == 2)
    }

    @Test("Permission, retired-element and unsupported-operation errors are never retried",
          arguments: ["children", "role"],
          [AXError.apiDisabled.rawValue, AXError.invalidUIElement.rawValue, AXError.notImplemented.rawValue])
    func otherFailuresRemainBlocked(stage: String, status: Int32) {
        let f = Fixture(stage: stage, status: status)
        let reason = AXLogicProElements.dialogPresenceReason(runtime: f.runtime())
        #expect(reason == .windowChildrenUnreadable && !reason.namesAnActualDialog)
        #expect(f.windowsReads == 1 && f.childrenReads == 1)
    }

    @Test("A transient failure cannot hide a separate permission failure behind a fresh window list",
          arguments: ["children", "role"])
    func mixedFailuresAreNotRetried(stage: String) {
        let f = Fixture(stage: stage, mixedFailure: true)
        #expect(AXLogicProElements.dialogPresenceReason(runtime: f.runtime()) == .windowChildrenUnreadable)
        #expect(f.windowsReads == 1)
    }

    @Test("An actually observed modal is never erased by a second census",
          arguments: ["children", "role"])
    func observedModalIsNotRetried(stage: String) {
        let f = Fixture(stage: stage, initialModal: true)
        #expect(AXLogicProElements.dialogPresenceReason(runtime: f.runtime()) == .blockingWindowFound)
        #expect(f.windowsReads == 1)
    }

    @Test("The existing windows retry consumes the only reread even if its child census then fails",
          arguments: ["children", "role"])
    func retryBudgetIsSharedWithWindowsRead(stage: String) {
        let f = Fixture(stage: stage, persistent: true, initialWindowsFailure: true)
        #expect(AXLogicProElements.dialogPresenceReason(runtime: f.runtime()) == .windowChildrenUnreadable)
        #expect(f.windowsReads == 2 && f.childrenReads == 1)
    }
}
