@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue #538 — stray-menu witness honesty")
struct Issue538MenuWitnessHonestyTests {

    @Test("an accepted Escape with a gone menu reports observations, not causation")
    func acceptedEscapeGoneMenuIsNotPerformed() async {
        let fixture = makeMenuFixture(escapeAccepted: true, menuGoneAfterEscape: true)

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        // Mutation `menu-close-causation`: restore the accepted-Escape plus
        // gone-witness `performed` conjunction. Another actor can close the
        // menu before the bound target is polled.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
    }

    @Test("an accepted Escape with a persistent menu is not performed")
    func acceptedEscapePersistentMenuIsNotPerformed() async {
        let fixture = makeMenuFixture(escapeAccepted: true, menuGoneAfterEscape: false)

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            !outcome.performed,
            "Mutation caught: replace `actionAccepted && summary.observedGone` with `actionAccepted`; an accepted Escape while the menu remains selected would become performed."
        )
    }

    @Test("a rejected Escape with a gone menu is not performed")
    func rejectedEscapeGoneMenuIsNotPerformed() async {
        let fixture = makeMenuFixture(escapeAccepted: false, menuGoneAfterEscape: true)

        let outcome = await AccessibilityChannel.reconcilePreflight(
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            !outcome.performed,
            "Mutation caught: remove `actionAccepted &&` and use only `summary.observedGone`; a rejected Escape with an independently closed menu would become performed."
        )
    }
}

private final class MenuEscapeState: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false

    func markAttempted() {
        lock.lock()
        attempted = true
        lock.unlock()
    }

    func isAttempted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return attempted
    }
}

private struct MenuFixture {
    let runtime: AXLogicProElements.Runtime
}

private func makeMenuFixture(
    escapeAccepted: Bool,
    menuGoneAfterEscape: Bool
) -> MenuFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let window = builder.element(2)
    let menuBar = builder.element(3)
    let menuItem = builder.element(4)
    let state = MenuEscapeState()
    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [menuItem])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, menuItem), attribute == (kAXSelectedAttribute as String) else { return nil }
            let isGone = state.isAttempted() && menuGoneAfterEscape
            return .some(NSNumber(value: !isGone))
        },
        setAttributeHandler: nil,
        performActionHandler: nil,
        executeAppleScript: { _ in
            state.markAttempted()
            return escapeAccepted ? .success("escaped") : .error("escape rejected")
        }
    )
    return MenuFixture(runtime: runtime)
}
