@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class HelpTagReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// #1063: Logic lists the tooltip under a resting pointer as an `AXWindows` entry whose `AXRole` is
/// `AXHelpTag`. Measured on that entry: `AXModal` -25205, `AXSubrole` -25205, `AXTitle` -25212, while
/// the two real windows answer `AXModal` false. The top-level scan failed closed on the tooltip's
/// `AXModal`, so every verified track write that followed reported State B `retry_exhausted` with
/// `top_level_window_modal_read_failed` although the track had been created.
///
/// An entry leaves the scan only when its role is READ as `AXHelpTag`, whatever its `AXModal`
/// answers — -25205, a successful nil, or true. A failed role read, or a successful nil (which is
/// also what a malformed payload produces), keeps it in, and its `AXModal` decides as before.
@Suite("Issue #1063 — a help tag in AXWindows is not an unreadable modal")
struct Issue1063HelpTagIsNotModalTests {

    private static let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)
    private static let noValue = AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
    private static let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

    /// One scripted status-preserving read, kept Sendable so the handler can capture it.
    private enum Answer: Sendable {
        case text(String)
        case boolean(Bool)
        case successfulNil
        case status(AXHelpers.AXStatusError)

        var result: Result<AnyObject?, AXHelpers.AXStatusError> {
            switch self {
            case .text(let value): return .success(value as NSString)
            case .boolean(let value): return .success(NSNumber(value: value))
            case .successfulNil: return .success(nil)
            case .status(let error): return .failure(error)
            }
        }
    }

    /// The measured tooltip: `AXModal` and `AXSubrole` -25205, `AXTitle` -25212. The status-preserving
    /// `AXRole` read answers `role`; the builder's own attribute table holds the true role, so a reader
    /// that bypassed the status-preserving path would see `AXHelpTag` even when `role` fails.
    private static func helpTagHandler(
        _ helpTag: AXUIElement,
        role: Answer,
        modal: Answer = .status(unsupported),
        roleReads: HelpTagReadCounter,
        modalReads: HelpTagReadCounter
    ) -> @Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>? {
        { element, attribute in
            guard CFEqual(element, helpTag) else { return nil }
            switch attribute {
            case kAXRoleAttribute as String:
                roleReads.increment()
                return role.result
            case kAXModalAttribute as String:
                modalReads.increment()
                return modal.result
            case kAXSubroleAttribute as String:
                return .failure(unsupported)
            case kAXTitleAttribute as String:
                return .failure(noValue)
            default:
                return nil
            }
        }
    }

    /// Arrange window, the tooltip, and a second ordinary window — the live shape of #1063.
    private static func fixture(
        _ builder: FakeAXRuntimeBuilder,
        base: Int,
        extraWindows: [AXUIElement] = []
    ) -> (app: AXUIElement, arrange: AXUIElement, helpTag: AXUIElement, other: AXUIElement) {
        let app = builder.element(base)
        let arrange = builder.element(base + 1)
        let helpTag = builder.element(base + 2)
        let other = builder.element(base + 3)
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, helpTag] + extraWindows + [other])
        builder.setAttribute(arrange, kAXModalAttribute as String, false)
        builder.setAttribute(other, kAXModalAttribute as String, false)
        builder.setAttribute(helpTag, kAXRoleAttribute as String, kAXHelpTagRole as String)
        return (app, arrange, helpTag, other)
    }

    @Test("a help tag whose AXModal answers -25205 beside two non-modal windows leaves the observation complete")
    func helpTagWithUnsupportedModalIsSkipped() {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_300)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .text(kAXHelpTagRole as String),
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(modalReads.current() > 0, "the help tag's AXModal -25205 seam must fire, or this test proves nothing")
        #expect(roleReads.current() > 0, "the help tag's role must be read to leave the scan")
        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(read.unreadableReason == nil)
        #expect(read.modalObservationIsComplete)
    }

    @Test("a help tag whose AXModal is a successful nil is skipped by its role, not by the nil")
    func helpTagWithNilModalIsSkippedByRole() {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_310)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .text(kAXHelpTagRole as String),
                modal: .successfulNil,
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(modalReads.current() > 0, "the help tag's nil AXModal seam must fire, or this test proves nothing")
        #expect(roleReads.current() > 0)
        #expect(read.unreadableReason == nil)
        #expect(read.modalObservationIsComplete)
    }

    @Test("an entry whose role read fails stays in the scan and its -25205 AXModal still fails closed")
    func unreadableRoleKeepsTheEntryFailClosed() {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_320)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .status(Self.cannotComplete),
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(roleReads.current() > 0, "the failing role-read seam must fire, or this test proves nothing")
        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(!read.modalObservationIsComplete)
        #expect(read.unreadableReason == .topLevelWindowModalReadFailed(Self.unsupported))
    }

    @Test("an entry whose role read is a successful nil stays in the scan and still fails closed")
    func nilRoleKeepsTheEntryFailClosed() {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_330)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .successfulNil,
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(roleReads.current() > 0, "the nil role-read seam must fire, or this test proves nothing")
        #expect(!read.modalObservationIsComplete)
        #expect(read.unreadableReason == .topLevelWindowModalReadFailed(Self.unsupported))
    }

    @Test("a real modal dialog listed after a help tag is still found")
    func modalDialogAfterAHelpTagIsStillFound() {
        let builder = FakeAXRuntimeBuilder()
        let systemDialog = builder.element(106_349)
        let shape = Self.fixture(builder, base: 106_340, extraWindows: [systemDialog])
        builder.setAttribute(systemDialog, kAXModalAttribute as String, true)
        builder.setAttribute(systemDialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .text(kAXHelpTagRole as String),
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(roleReads.current() > 0, "the help tag must be reached before the dialog, or this test proves nothing")
        #expect(ModalReconciliation.classify(read.signals) == .unknownSheet)
        #expect(read.unreadableReason == nil)
    }

    @Test("a help tag whose AXModal answers true beside two non-modal windows leaves the observation complete")
    func helpTagWithTrueModalIsSkipped() {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_400)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .text(kAXHelpTagRole as String),
                modal: .boolean(true),
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(modalReads.current() > 0, "the help tag's AXModal true seam must fire, or this test proves nothing")
        #expect(roleReads.current() > 0, "the help tag's role must be read to leave the scan")
        #expect(ModalReconciliation.classify(read.signals) == .none)
        #expect(read.alertTarget == nil)
        #expect(read.unreadableReason == nil)
        #expect(read.modalObservationIsComplete)
    }

    @Test("a real modal dialog listed after a help tag answering AXModal true is still found")
    func modalDialogAfterAHelpTagWithTrueModalIsStillFound() throws {
        let builder = FakeAXRuntimeBuilder()
        let dialog = builder.element(106_419)
        let okButton = builder.element(106_418)
        let shape = Self.fixture(builder, base: 106_410, extraWindows: [dialog])
        builder.setAttribute(dialog, kAXModalAttribute as String, true)
        builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(dialog, kAXTitleAttribute as String, "Alert")
        builder.setAttribute(okButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(okButton, kAXTitleAttribute as String, "OK")
        builder.setChildren(dialog, [okButton])
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .text(kAXHelpTagRole as String),
                modal: .boolean(true),
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(modalReads.current() > 0, "the help tag must be reached before the dialog, or this test proves nothing")
        #expect(roleReads.current() > 0)
        // The help tag is listed first. Were it kept as the first blocker, its unreadable subrole would
        // reduce the scan to an unknown blocker and the dialog behind it would never be the target.
        #expect(ModalReconciliation.classify(read.signals) == .informationalAlert)
        let target = try #require(read.alertTarget)
        #expect(CFEqual(target.element, dialog))
        #expect(read.unreadableReason == nil)
    }

    @Test("an entry whose AXModal answers true and whose role read fails stays a blocker")
    func trueModalWithUnreadableRoleStaysABlocker() {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_420)
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .status(Self.cannotComplete),
                modal: .boolean(true),
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(modalReads.current() > 0, "the AXModal true seam must fire, or this test proves nothing")
        #expect(roleReads.current() > 0, "the failing role-read seam must fire, or this test proves nothing")
        #expect(ModalReconciliation.classify(read.signals) == .unknownSheet)
        #expect(read.alertTarget == nil)
        #expect(read.unreadableReason == nil)
    }

    @Test("a verified track create with a help tag in AXWindows is State A, not retry_exhausted")
    func createWithAHelpTagPresentIsStateA() async throws {
        try await Self.expectCreateIsStateA(helpTagModal: .status(Self.unsupported), base: 106_360)
    }

    @Test("a verified track create with a help tag answering AXModal true is State A, not a blocker")
    func createWithAHelpTagAnsweringModalTrueIsStateA() async throws {
        try await Self.expectCreateIsStateA(helpTagModal: .boolean(true), base: 106_430)
    }

    /// `create_instrument` through the Track menu with the #1063 tooltip in AXWindows, its role read
    /// as `AXHelpTag` and its `AXModal` answering `modal`.
    private static func expectCreateIsStateA(helpTagModal modal: Answer, base: Int) async throws {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: base)
        let menuBar = builder.element(base + 10)
        let trackMenu = builder.element(base + 11)
        let createItem = builder.element(base + 12)
        let headers = builder.element(base + 13)
        let existing = builder.element(base + 14)
        let created = builder.element(base + 15)
        let createPresses = HelpTagReadCounter()
        let roleReads = HelpTagReadCounter()
        let modalReads = HelpTagReadCounter()

        builder.setAttribute(shape.app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(shape.arrange, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [existing])
        builder.setAttribute(existing, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(existing, kAXTitleAttribute as String, "Existing")
        builder.setAttribute(existing, kAXDescriptionAttribute as String, "Audio Track")
        builder.setAttribute(created, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(created, kAXTitleAttribute as String, "Inst 1")
        builder.setAttribute(created, kAXDescriptionAttribute as String, "Software Instrument Track")
        builder.setAttribute(created, kAXSelectedAttribute as String, true)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setAttribute(trackMenu, kAXSelectedAttribute as String, false)
        builder.setChildren(trackMenu, [createItem])
        builder.setAttribute(createItem, kAXTitleAttribute as String, "소프트웨어 악기")
        builder.setAttribute(createItem, kAXSelectedAttribute as String, false)

        let runtime = builder.makeLogicRuntime(
            appElement: shape.app,
            attributeValueResultHandler: Self.helpTagHandler(
                shape.helpTag,
                role: .text(kAXHelpTagRole as String),
                modal: modal,
                roleReads: roleReads,
                modalReads: modalReads
            ),
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, createItem), action == (kAXPressAction as String) else { return false }
                createPresses.increment()
                builder.setChildren(headers, [existing, created])
                return true
            }
        )

        let result = await AccessibilityChannel.createTrackViaMenu(
            // The fixture's own menu titles, not Logic's.
            item: AXLocalePolicy.LabelSet(
                canonical: "Software Instrument",
                variants: ["소프트웨어 악기"],
                rationale: "fixture menu leaf"),
            expectedTrackType: .softwareInstrument,
            runtime: runtime
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let state = try #require(envelope["state"] as? String)
        let verified = try #require(envelope["verified"] as? Bool)

        #expect(createPresses.current() == 1, "the count increase must be caused by the requested menu press")
        #expect(modalReads.current() > 0, "the help tag's AXModal seam must fire, or this test proves nothing")
        #expect(roleReads.current() > 0, "the help tag's role must be read to leave the scan")
        #expect(state == "A", "got: \(result.message)")
        #expect(verified)
        #expect(envelope["reason"] == nil)
        #expect(envelope["reconciled_modal_unreadable_reason"] == nil)
    }
}
