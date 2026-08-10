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
