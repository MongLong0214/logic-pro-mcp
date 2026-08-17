@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #545 — Logic raises more than one track-delete confirmation sheet and they do
// NOT share a button label: "Delete Tracks and Content" on the channel-strip
// sheet, but a bare "Delete" on "Delete Track and Regions?" and "Delete Track
// and Cells?" (Live Loops). Before the fix, `deleteTracksPrimaryButton` had an
// empty `variants` list, so those bare-label sheets fell through to the
// structural fallback `label.hasPrefix("Delete ")` — WITH a trailing space,
// which a bare "Delete" does not satisfy. They classified `.unknownSheet`,
// failed closed, and were left on screen.
//
// These tests drive `AccessibilityChannel.readModalSignals` — the SAME reader
// that matches a button's AX title against `AXLocalePolicy.deleteTracksPrimaryButton`
// — through a fake AX tree, not just the pure `ModalSignals` struct. A test that
// only sets `deleteConfirmButtonPresent: true` by hand would presuppose the very
// label match this fix widened, and could not catch a regression in it.
@Suite("Issue #545 delete-confirm bare label")
struct Issue545DeleteConfirmBareLabelTests {
    /// Builds the minimal AX shape #545 was measured live in: a sheet on a
    /// non-modal window (no `AXMainWindow` required — mirrors the shape proven
    /// in Issue538's `sheetOnAXWindowsIsSeenWithoutAMainWindow`) whose only two
    /// buttons are the primary destructive control and Cancel.
    private func classifiedKind(primaryButtonTitle: String) -> ModalReconciliation.BlockingModalKind {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9500)
        let window = builder.element(9501)
        let sheet = builder.element(9502)
        let deleteButton = builder.element(9503)
        let cancelButton = builder.element(9504)

        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        builder.setAttribute(window, kAXModalAttribute as String, false)
        builder.setAttribute(window, "AXSheets", [sheet])
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        // A description that is neither the New Track sheet's nor empty, so the
        // mandatory-New-Track branch cannot claim this sheet by accident.
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "Delete Track and Regions?")
        builder.setChildren(sheet, [deleteButton, cancelButton])
        builder.setAttribute(deleteButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(deleteButton, kAXTitleAttribute as String, primaryButtonTitle)
        builder.setAttribute(cancelButton, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancelButton, kAXTitleAttribute as String, "Cancel")

        let runtime = builder.makeLogicRuntime(
            appElement: app, setAttributeHandler: nil, performActionHandler: nil
        )
        return ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))
    }

    @Test("a bare English 'Delete' primary button classifies as deleteConfirm, not unknownSheet")
    func bareEnglishDeleteClassifiesAsDeleteConfirm() {
        let kind = classifiedKind(primaryButtonTitle: "Delete")
        #expect(kind == .deleteConfirm)
        #expect(kind != .unknownSheet)
    }

    @Test("unmeasured locale labels do NOT classify — the gap is real and is left fail-closed")
    func unmeasuredLocaleLabelsDoNotClassify() {
        // A revision of this suite asserted that 삭제 and 削除 classify as `.deleteConfirm`. Those two
        // strings were translated by hand rather than read from the live sheet, which `AXLocalePolicy`'s
        // header forbids — and forbids because a hand translation was already wrong in this app once
        // (New is 신규, not the 새로 만들기 a translator reaches for). The tests then encoded the guess
        // and agreed with it, which is how the ORIGINAL #545 fix passed six tests while doing nothing.
        //
        // Note what is NOT sufficient: `markerListDeleteMenuItem` carries a live-confirmed 삭제/削除, so
        // these strings are real Logic labels somewhere in this app. That raises the prior; it is not a
        // measurement of THIS button. The same app is exactly where 신규 and 새로 만들기 diverged.
        //
        // So the absence is asserted deliberately. Outside English these sheets classify as unknown and
        // are left on screen — fail-closed, and the honest state of the gap (tracked in #519). Restoring
        // the variants means changing this test, and changing it should require naming a measurement.
        // 삭제 is now MEASURED (Logic 12.3, AppleLanguages=ko, 2026-08-17: buttons `취소, 삭제`), so it
        // classifies. 削除 has not been read off a live Japanese dialog and therefore must not.
        #expect(classifiedKind(primaryButtonTitle: "삭제") == .deleteConfirm)
        #expect(classifiedKind(primaryButtonTitle: "削除") != .deleteConfirm)
    }

    @Test("the channel-strip sheet's full canonical label still classifies (no regression)")
    func canonicalLabelStillClassifiesAsDeleteConfirm() {
        let kind = classifiedKind(primaryButtonTitle: "Delete Tracks and Content")
        #expect(kind == .deleteConfirm)
    }

    @Test("an unrelated single button does not turn every sheet into a delete confirm")
    func unrelatedButtonStaysUnknownSheet() {
        // OVER-MATCH GUARD: widening the label set to accept a bare "Delete"
        // must not widen it into matching arbitrary button text.
        let doneKind = classifiedKind(primaryButtonTitle: "Done")
        let okKind = classifiedKind(primaryButtonTitle: "OK")
        #expect(doneKind == .unknownSheet)
        #expect(okKind == .unknownSheet)
        #expect(doneKind != .deleteConfirm)
        #expect(okKind != .deleteConfirm)
    }

    @Test("a deleteConfirm sheet outside a delete context still fails closed, and preflight never performs it")
    func deleteConfirmOutsideContextStaysFailClosed() {
        // SAFETY PROPERTY that makes the widened label set safe: `decide` only
        // ever returns `.confirmDelete` inside a delete context, and preflight
        // never performs `.deleteConfirm` regardless of context. Assert both
        // explicitly rather than assuming they still hold after the widening.
        let kind = classifiedKind(primaryButtonTitle: "Delete")
        #expect(kind == .deleteConfirm)

        let decision = ModalReconciliation.decide(kind: kind, isDeleteContext: false)
        #expect(decision == .failClosed("unexpected delete-confirm sheet"))
        #expect(decision != .confirmDelete)

        #expect(!ModalReconciliation.preflightShouldPerform(kind: kind, clearMandatoryNewTrack: true))
        #expect(!ModalReconciliation.preflightShouldPerform(kind: kind, clearMandatoryNewTrack: false))
    }
}

// MARK: - The shape that actually runs live

/// Everything above classifies a fixture built with `AXSheets`. Logic never vends that attribute — it
/// answers `-25205` for it, always — so `readModalSignals(runtime:)` returns through the sheet branch
/// and `topLevelDialogRead` is never entered. Those tests therefore stay green with the #545 routing
/// deleted, which is the identical defect that let the FIRST #545 fix pass six tests while changing
/// nothing on the running path. This fixture builds what Logic actually presents: a top-level
/// `AXWindow` with `AXModal == true` and no sheets, carrying a bare "Delete" and a "Cancel".
private struct TopLevelDeleteConfirmFixture {
    let runtime: AXLogicProElements.Runtime
    let deletePresses: Locked545Counter
}

private func makeTopLevelDeleteConfirmFixture(
    primaryButtonTitle: String
) -> TopLevelDeleteConfirmFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(545_900)
    let modal = builder.element(545_901)
    let primary = builder.element(545_902)
    let cancel = builder.element(545_903)
    let deletePresses = Locked545Counter()
    let actionIssued = Locked545Flag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, modal)
    builder.setAttribute(app, kAXWindowsAttribute as String, [modal])
    builder.setAttribute(modal, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(modal, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(modal, kAXModalAttribute as String, true)
    builder.setAttribute(modal, kAXDescriptionAttribute as String, "Delete Track and Regions?")
    // Deliberately NO AXSheets attribute anywhere: that is the whole point of this fixture.
    builder.setAttribute(primary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(primary, kAXTitleAttribute as String, primaryButtonTitle)
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setChildren(modal, [primary, cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueResultHandler: { element, attribute in
            // Once the dialog has been answered it is gone, so later reads of it fail the way a real
            // dismissed AX element does. Without this the reconciler keeps seeing a dialog it pressed.
            guard actionIssued.get(),
                  CFEqual(element, modal),
                  attribute == (kAXRoleAttribute as String)
            else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard CFEqual(element, primary), action == (kAXPressAction as String) else { return false }
            _ = deletePresses.next()
            actionIssued.set()
            return true
        }
    )
    return TopLevelDeleteConfirmFixture(runtime: runtime, deletePresses: deletePresses)
}

@Test("a top-level modal delete-confirm is routed and pressed, not left on screen")
func topLevelDeleteConfirmIsActionable() async {
    let fixture = makeTopLevelDeleteConfirmFixture(primaryButtonTitle: "Delete")

    let outcome = await AccessibilityChannel.reconcileAfterMutation(
        isDeleteContext: true,
        runtime: fixture.runtime,
        witnessAttempts: 1,
        witnessDelayNanoseconds: 0
    )

    // Mutation `top-level-delete-confirm-as-generic-blocker`: remove the `.deleteConfirm` arms from the
    // top-level dialog switch and from `readRemainingModalSignals`. The dialog then falls through to
    // `.blocking` -> `unknownSheet` and is left standing — the live #545 symptom — while every
    // sheet-shaped test in this file stays green.
    #expect(outcome.kind == .deleteConfirm)
    #expect(outcome.actionAttempted)
    #expect(fixture.deletePresses.current() == 1)
}

@Test("a top-level modal delete-confirm is NOT pressed outside a delete context")
func topLevelDeleteConfirmIsNotPressedWithoutDeleteContext() async {
    let fixture = makeTopLevelDeleteConfirmFixture(primaryButtonTitle: "Delete")

    // The gate that makes routing this dialog safe at all. Recognising a destructive confirmation must
    // never by itself be permission to answer one this server did not ask for.
    let outcome = await AccessibilityChannel.reconcileAfterMutation(
        isDeleteContext: false,
        runtime: fixture.runtime,
        witnessAttempts: 1,
        witnessDelayNanoseconds: 0
    )

    #expect(fixture.deletePresses.current() == 0)
    #expect(!outcome.actionAttempted)
}


/// File-private counters. `Issue538ModalWitnessTests` declares equivalents but they are `private` to
/// that file, so these are named distinctly rather than widened — a shared helper would couple two
/// suites that are deliberately independent.
private final class Locked545Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class Locked545Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); defer { lock.unlock() }; value = true }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
