@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

private func makeIssue498Fixture(
    title: String,
    subrole: String,
    isModal: Bool,
    secondCancel: Bool = false
) -> (
    builder: FakeAXRuntimeBuilder,
    runtime: AXLogicProElements.Runtime,
    cancel: AXUIElement
) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(498_001)
    let window = builder.element(498_002)
    let cancel = builder.element(498_003)
    let ok = builder.element(498_004)

    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(window, kAXTitleAttribute as String, title)
    builder.setAttribute(window, kAXSubroleAttribute as String, subrole)
    builder.setAttribute(window, kAXModalAttribute as String, isModal)
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(ok, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(ok, kAXTitleAttribute as String, "OK")
    // #628: a second button carrying the same label. The real dialog has exactly one — measured,
    // its children are Cancel and OK — so this is the case the census exists to notice.
    if secondCancel {
        let decoy = builder.element(498_005)
        builder.setAttribute(decoy, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(decoy, kAXTitleAttribute as String, "Cancel")
        builder.setChildren(window, [cancel, decoy, ok])
    } else {
        builder.setChildren(window, [cancel, ok])
    }

    return (builder, builder.makeLogicRuntime(appElement: app), cancel)
}

@Test("Issue498: exact floating modal Go To Position dialog is dismissed")
func issue498DismissesExactFloatingModalDialog() {
    let fixture = makeIssue498Fixture(
        title: "Go To Position",
        subrole: kAXFloatingWindowSubrole as String,
        isModal: true
    )

    #expect(AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.builder.actionCalls.count == 1)
    #expect(fixture.builder.actionCalls.first?.elementID == fixture.builder.elementID(fixture.cancel))
    #expect(fixture.builder.actionCalls.first?.action == kAXPressAction as String)
}

@Test("Issue628: two same-labelled Cancels are not pressed on a guess")
func issue628AmbiguousCancelIsNotPressedByTreeOrder() {
    let fixture = makeIssue498Fixture(
        title: "Go To Position",
        subrole: kAXFloatingWindowSubrole as String,
        isModal: true,
        secondCancel: true
    )
    // Record the terminal Escape fallback rather than sending a key to the running application.
    // Dispatch is not evidence of dismissal. Neither ambiguous Cancel may be chosen by order.
    let escapes = MutableBox(0)
    _ = AccessibilityChannel.closeGoToPositionDialog(
        runtime: fixture.runtime, escape: { escapes.value += 1 }
    )
    let pressedTheFirstCancel = fixture.builder.actionCalls.contains {
        $0.elementID == fixture.builder.elementID(fixture.cancel)
            && $0.action == kAXPressAction as String
    }
    #expect(!pressedTheFirstCancel,
            "identity came from tree order: with two candidates neither is identified")
    #expect(escapes.value == 1)
}

@Test("Issue498: standard non-modal project window is not touched")
func issue498DoesNotTouchStandardNonModalProjectWindow() {
    let fixture = makeIssue498Fixture(
        title: "My Go To Position Project - Tracks",
        subrole: kAXStandardWindowSubrole as String,
        isModal: false
    )

    #expect(!AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.builder.actionCalls.isEmpty)
}

/// Each guard needs a fixture that ONLY it can reject, or the three cannot be told
/// apart. The window below is modal and titled exactly right, so the subrole check is
/// the only thing standing between it and a keypress — mutation-tested: removing that
/// check makes this test, and only this test, fail.
@Test("Issue498: a modal, exactly-titled window that is not floating is not touched")
func issue498SubroleAloneRejectsAStandardModalWindow() {
    let fixture = makeIssue498Fixture(
        title: "Go To Position",
        subrole: kAXStandardWindowSubrole as String,
        isModal: true
    )

    #expect(!AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.builder.actionCalls.isEmpty)
}

/// The same isolation for modality: floating and exactly titled, so only AXModal can
/// reject it.
@Test("Issue498: a floating, exactly-titled window that is not modal is not touched")
func issue498ModalityAloneRejectsANonModalFloatingWindow() {
    let fixture = makeIssue498Fixture(
        title: "Go To Position",
        subrole: kAXFloatingWindowSubrole as String,
        isModal: false
    )

    #expect(!AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.builder.actionCalls.isEmpty)
}

@Test("Issue498: floating modal window with title suffix is not touched")
func issue498DoesNotTouchFloatingModalTitleSuffix() {
    let fixture = makeIssue498Fixture(
        title: "Go To Position Extra",
        subrole: kAXFloatingWindowSubrole as String,
        isModal: true
    )

    #expect(!AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.builder.actionCalls.isEmpty)
}

// MARK: - #1063 (R1063-02): a help tag is not the Go To Position dialog

/// Logic lists the tooltip under a resting pointer among its `AXWindows` (#1063). An entry that also
/// answers the Go To Position shape — floating subrole, `AXModal` true, the exact title — is told
/// apart only by its role as READ. Each window below has that shape and its own Cancel and OK, and
/// its `AXRole` in the builder's table is `roles[i]`. `failRoleReadAt` makes that window's
/// status-preserving role read fail with -25204 while the table still holds its role, so a reader
/// that bypassed the status-preserving path would see the table's role instead of the failure.
/// `roleReads` counts status-preserving role reads of these windows, which only the help-tag check
/// makes (the Cancel lookup reads its buttons' roles through the best-effort path).
private func makeIssue1063GoToShapedWindows(
    roles: [String],
    failRoleReadAt failingIndex: Int? = nil
) -> (
    builder: FakeAXRuntimeBuilder,
    runtime: AXLogicProElements.Runtime,
    cancels: [AXUIElement],
    roleReads: MutableBox<Int>
) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1_063_000)
    var windows: [AXUIElement] = []
    var cancels: [AXUIElement] = []
    for (index, role) in roles.enumerated() {
        let base = 1_063_010 + index * 10
        let window = builder.element(base)
        let cancel = builder.element(base + 1)
        let ok = builder.element(base + 2)
        builder.setAttribute(window, kAXRoleAttribute as String, role)
        builder.setAttribute(window, kAXTitleAttribute as String, "Go To Position")
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXFloatingWindowSubrole as String)
        builder.setAttribute(window, kAXModalAttribute as String, true)
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(ok, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(ok, kAXTitleAttribute as String, "OK")
        builder.setChildren(window, [cancel, ok])
        windows.append(window)
        cancels.append(cancel)
    }
    builder.setAttribute(app, kAXWindowsAttribute as String, windows)

    let listed = windows
    let failing = failingIndex.map { windows[$0] }
    let roleReads = MutableBox(0)
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            guard attribute == kAXRoleAttribute as String,
                  listed.contains(where: { CFEqual($0, element) }) else { return nil }
            roleReads.value += 1
            if let failing, CFEqual(failing, element) {
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            }
            return nil
        },
        setAttributeHandler: nil,
        performActionHandler: nil
    )
    return (builder, runtime, cancels, roleReads)
}

@Test("Issue1063: a help tag with the Go To Position shape is not found and not acted on")
func issue1063HelpTagWithGoToShapeIsNotTouched() {
    let fixture = makeIssue1063GoToShapedWindows(roles: [kAXHelpTagRole as String])

    #expect(!AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.roleReads.value == 1, "the help tag's role must be read, or this test proves nothing")
    #expect(fixture.builder.actionCalls.isEmpty)
}

@Test("Issue1063: a window with the Go To Position shape whose role reads AXWindow is still closed")
func issue1063GenuineGoToDialogIsStillClosed() {
    let fixture = makeIssue1063GoToShapedWindows(roles: [kAXWindowRole as String])

    #expect(AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.roleReads.value == 1, "the role must be read and answer AXWindow, or this test proves nothing")
    #expect(fixture.builder.actionCalls.count == 1)
    #expect(fixture.builder.actionCalls.first?.elementID == fixture.builder.elementID(fixture.cancels[0]))
    #expect(fixture.builder.actionCalls.first?.action == kAXPressAction as String)
}

@Test("Issue1063: a Go To Position-shaped window whose role read fails is still treated as the dialog")
func issue1063UnreadableRoleKeepsTheDialogClosed() {
    // The table says AXHelpTag; the status-preserving read fails. Only the read counts.
    let fixture = makeIssue1063GoToShapedWindows(roles: [kAXHelpTagRole as String], failRoleReadAt: 0)

    #expect(AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.roleReads.value == 1, "the failing role-read seam must fire, or this test proves nothing")
    #expect(fixture.builder.actionCalls.count == 1)
    #expect(fixture.builder.actionCalls.first?.elementID == fixture.builder.elementID(fixture.cancels[0]))
}

@Test("Issue1063: a help tag listed before the genuine Go To Position dialog is passed over")
func issue1063HelpTagBeforeGenuineDialogActsOnlyOnTheDialog() {
    let fixture = makeIssue1063GoToShapedWindows(roles: [kAXHelpTagRole as String, kAXWindowRole as String])

    #expect(AccessibilityChannel.closeGoToPositionDialog(runtime: fixture.runtime))
    #expect(fixture.roleReads.value == 2, "both roles must be read, or this test proves nothing")
    #expect(fixture.builder.actionCalls.count == 1)
    #expect(fixture.builder.actionCalls.first?.elementID == fixture.builder.elementID(fixture.cancels[1]))
    #expect(fixture.builder.actionCalls.first?.action == kAXPressAction as String)
}
