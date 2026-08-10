@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

private func makeIssue498Fixture(
    title: String,
    subrole: String,
    isModal: Bool
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
    builder.setChildren(window, [cancel, ok])

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
