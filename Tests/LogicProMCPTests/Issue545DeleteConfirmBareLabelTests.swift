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

    @Test("the Korean bare primary button (삭제) classifies as deleteConfirm")
    func bareKoreanDeleteClassifiesAsDeleteConfirm() {
        let kind = classifiedKind(primaryButtonTitle: "삭제")
        #expect(kind == .deleteConfirm)
        #expect(kind != .unknownSheet)
    }

    @Test("the Japanese bare primary button (削除) classifies as deleteConfirm")
    func bareJapaneseDeleteClassifiesAsDeleteConfirm() {
        let kind = classifiedKind(primaryButtonTitle: "削除")
        #expect(kind == .deleteConfirm)
        #expect(kind != .unknownSheet)
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
