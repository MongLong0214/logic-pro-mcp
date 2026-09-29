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
/// An entry leaves the scan only when its role is READ as `AXHelpTag`. A failed role read, or a
/// successful nil (which is also what a malformed payload produces), keeps it in, and its `AXModal`
/// decides as before.
@Suite("Issue #1063 — a help tag in AXWindows is not an unreadable modal")
struct Issue1063HelpTagIsNotModalTests {

    private static let unsupported = AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue)
    private static let noValue = AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
    private static let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

    /// One scripted status-preserving read, kept Sendable so the handler can capture it.
    private enum Answer: Sendable {
        case text(String)
        case successfulNil
        case status(AXHelpers.AXStatusError)

        var result: Result<AnyObject?, AXHelpers.AXStatusError> {
            switch self {
            case .text(let value): return .success(value as NSString)
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

    @Test("a verified track create with a help tag in AXWindows is State A, not retry_exhausted")
    func createWithAHelpTagPresentIsStateA() async throws {
        let builder = FakeAXRuntimeBuilder()
        let shape = Self.fixture(builder, base: 106_360)
        let menuBar = builder.element(106_370)
        let trackMenu = builder.element(106_371)
        let createItem = builder.element(106_372)
        let headers = builder.element(106_373)
        let existing = builder.element(106_374)
        let created = builder.element(106_375)
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
        #expect(modalReads.current() > 0, "the help tag's AXModal -25205 seam must fire, or this test proves nothing")
        #expect(state == "A", "got: \(result.message)")
        #expect(verified)
        #expect(envelope["reason"] == nil)
        #expect(envelope["reconciled_modal_unreadable_reason"] == nil)
    }
}
