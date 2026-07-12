import Foundation
import Testing
@testable import LogicProMCP

// #346 — exhaustive, deterministic truth table for the pure modal-reconciliation
// core (classify + decide). No AX / live Logic; the live reader + executor are
// verified separately. Enum `==` comparisons below are non-optional Bool
// expressions (NOT the dead `#expect(optionalBool == true)` pattern).

private func makeSignals(
    sheetPresent: Bool = false,
    sheetDescription: String = "",
    createButtonPresent: Bool = false,
    cancelButtonPresent: Bool = false,
    cancelButtonEnabled: Bool = true,
    deleteConfirmButtonPresent: Bool = false,
    strayMenuOpen: Bool = false,
    topLevelAlertPresent: Bool = false,
    topLevelAlertButtonCount: Int = 0,
    topLevelAlertPrimaryButton: String = ""
) -> ModalReconciliation.ModalSignals {
    ModalReconciliation.ModalSignals(
        sheetPresent: sheetPresent,
        sheetDescription: sheetDescription,
        createButtonPresent: createButtonPresent,
        cancelButtonPresent: cancelButtonPresent,
        cancelButtonEnabled: cancelButtonEnabled,
        deleteConfirmButtonPresent: deleteConfirmButtonPresent,
        strayMenuOpen: strayMenuOpen,
        topLevelAlertPresent: topLevelAlertPresent,
        topLevelAlertButtonCount: topLevelAlertButtonCount,
        topLevelAlertPrimaryButton: topLevelAlertPrimaryButton
    )
}

// MARK: - classify

@Test func testClassifyMandatoryNewTrackViaDisabledCancel() {
    // Live shape: Create enabled, Cancel present-but-disabled (Escape inert).
    let signals = makeSignals(
        sheetPresent: true,
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testClassifyMandatoryNewTrackViaDescription() {
    // Description alone identifies the sheet even if button state is unreadable.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track"
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testClassifyDeleteConfirm() {
    let signals = makeSignals(
        sheetPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true,
        deleteConfirmButtonPresent: true
    )
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

@Test func testClassifyStrayMenu() {
    let signals = makeSignals(sheetPresent: false, strayMenuOpen: true)
    #expect(ModalReconciliation.classify(signals) == .strayMenu)
}

@Test func testClassifyUnknownSheet() {
    // A sheet with none of the recognised signals — never auto-dismissed.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "Some Other Sheet",
        createButtonPresent: false,
        cancelButtonPresent: true,
        cancelButtonEnabled: true
    )
    #expect(ModalReconciliation.classify(signals) == .unknownSheet)
}

@Test func testClassifyNone() {
    #expect(ModalReconciliation.classify(makeSignals()) == .none)
}

@Test func testClassifySheetWinsOverStrayMenu() {
    // A present sheet is the stronger blocker even if a menu also reads open.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track",
        strayMenuOpen: true
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

// MARK: - discriminator: disabled Cancel is the mandatory-sheet signal

@Test func testDisabledCancelIsTheMandatoryDiscriminator() {
    // Two sheets identical except Cancel's enabled state (and no "New Track"
    // description): disabled Cancel => mandatory; enabled Cancel => ordinary
    // cancelable sheet (unknown, fail-closed) — never auto-Created.
    let mandatory = makeSignals(
        sheetPresent: true,
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false
    )
    let ordinary = makeSignals(
        sheetPresent: true,
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true
    )
    #expect(ModalReconciliation.classify(mandatory) == .mandatoryNewTrack)
    #expect(ModalReconciliation.classify(ordinary) == .unknownSheet)
}

@Test func testDeleteConfirmWithDisabledCancelIsNotMisreadAsNewTrack() {
    // A delete-confirm sheet has NO Create button, so a disabled Cancel must not
    // promote it to mandatoryNewTrack (the createButtonPresent conjunct guards).
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "Delete channel strips",
        createButtonPresent: false,
        cancelButtonPresent: true,
        cancelButtonEnabled: false,
        deleteConfirmButtonPresent: true
    )
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

// MARK: - decide

@Test func testDecideMandatoryNewTrackAlwaysClicksCreate() {
    #expect(ModalReconciliation.decide(kind: .mandatoryNewTrack, isDeleteContext: true) == .clickCreate)
    #expect(ModalReconciliation.decide(kind: .mandatoryNewTrack, isDeleteContext: false) == .clickCreate)
}

@Test func testDecideDeleteConfirmInDeleteContext() {
    #expect(ModalReconciliation.decide(kind: .deleteConfirm, isDeleteContext: true) == .confirmDelete)
}

@Test func testDecideDeleteConfirmOutsideDeleteContextFailsClosed() {
    let decision = ModalReconciliation.decide(kind: .deleteConfirm, isDeleteContext: false)
    #expect(decision == .failClosed("unexpected delete-confirm sheet"))
    // Must NOT confirm a delete the caller did not request.
    #expect(decision != .confirmDelete)
}

@Test func testDecideStrayMenuEscapes() {
    #expect(ModalReconciliation.decide(kind: .strayMenu, isDeleteContext: false) == .escapeMenu)
}

@Test func testDecideUnknownSheetFailsClosedAndIsNotDismissed() {
    let decision = ModalReconciliation.decide(kind: .unknownSheet, isDeleteContext: true)
    #expect(decision == .failClosed("unexpected blocking sheet"))
    // A "Save changes?" could lose data — assert we never auto-dismiss/act.
    #expect(decision != .clickCreate)
    #expect(decision != .confirmDelete)
    #expect(decision != .escapeMenu)
    #expect(decision != .noAction)
}

@Test func testDecideNoneIsNoAction() {
    #expect(ModalReconciliation.decide(kind: .none, isDeleteContext: true) == .noAction)
    #expect(ModalReconciliation.decide(kind: .none, isDeleteContext: false) == .noAction)
}

// MARK: - end-to-end pipeline (classify -> decide)

@Test func testPipelineNewTrackSheetAutoCreates() {
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track",
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .mandatoryNewTrack)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: true) == .clickCreate)
}

@Test func testPipelineDeleteConfirmConfirmsInDeleteContext() {
    let signals = makeSignals(
        sheetPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true,
        deleteConfirmButtonPresent: true
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .deleteConfirm)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: true) == .confirmDelete)
}

// MARK: - top-level informational alerts (#346 increment 2)

@Test func testSingleButtonTopLevelAlertIsAcknowledged() {
    // Live shape: top-level AXDialog "alert" with a single "OK" button.
    let signals = makeSignals(
        sheetPresent: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 1,
        topLevelAlertPrimaryButton: "OK"
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .informationalAlert)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: false) == .acknowledgeAlert)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: true) == .acknowledgeAlert)
}

@Test func testTwoButtonTopLevelDialogIsNeverAcknowledged() {
    // DATA-LOSS SAFETY GUARD: a 2+ button dialog is a CHOICE (e.g. Save /
    // Don't Save / Cancel) and must NEVER be auto-dismissed — classify to
    // unknownSheet, decide to failClosed, and assert it is not acknowledged.
    let signals = makeSignals(
        sheetPresent: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 2,
        topLevelAlertPrimaryButton: "Save"
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .unknownSheet)
    let decision = ModalReconciliation.decide(kind: kind, isDeleteContext: false)
    #expect(decision == .failClosed("unexpected blocking sheet"))
    #expect(decision != .acknowledgeAlert)
}

@Test func testZeroButtonTopLevelAlertFailsClosed() {
    // Present but no identifiable single button ⇒ cannot safely acknowledge.
    let signals = makeSignals(
        sheetPresent: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 0
    )
    #expect(ModalReconciliation.classify(signals) == .unknownSheet)
}

@Test func testMainWindowSheetOutranksTopLevelAlert() {
    // Both present ⇒ the main-window sheet wins (sheet is the stronger blocker).
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track",
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 1,
        topLevelAlertPrimaryButton: "OK"
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testTopLevelAlertOutranksStrayMenu() {
    let signals = makeSignals(
        sheetPresent: false,
        strayMenuOpen: true,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 1,
        topLevelAlertPrimaryButton: "OK"
    )
    #expect(ModalReconciliation.classify(signals) == .informationalAlert)
}

@Test func testDecideInformationalAlertAcknowledgesInAnyContext() {
    #expect(ModalReconciliation.decide(kind: .informationalAlert, isDeleteContext: true) == .acknowledgeAlert)
    #expect(ModalReconciliation.decide(kind: .informationalAlert, isDeleteContext: false) == .acknowledgeAlert)
}

// MARK: - create-path preflight scope (#348)

@Test func testPreflightCreateScopeDoesNotClickCreateForMandatoryNewTrack() {
    // DOUBLE-CREATE GUARD: in create scope the mandatory New Track sheet still
    // DECIDES clickCreate, but preflight must NOT PERFORM it — createTrackViaMenu
    // opens/confirms its own dialog, so acting here would create two tracks.
    #expect(ModalReconciliation.decide(kind: .mandatoryNewTrack, isDeleteContext: false) == .clickCreate)
    #expect(!ModalReconciliation.preflightShouldPerform(kind: .mandatoryNewTrack, clearMandatoryNewTrack: false))
}

@Test func testPreflightDefaultScopeClearsMandatoryNewTrack() {
    // Default scope (any other caller) still auto-clears the mandatory sheet.
    #expect(ModalReconciliation.preflightShouldPerform(kind: .mandatoryNewTrack, clearMandatoryNewTrack: true))
}

@Test func testPreflightCreateScopeStillAcknowledgesAlert() {
    #expect(ModalReconciliation.decide(kind: .informationalAlert, isDeleteContext: false) == .acknowledgeAlert)
    #expect(ModalReconciliation.preflightShouldPerform(kind: .informationalAlert, clearMandatoryNewTrack: false))
}

@Test func testPreflightCreateScopeStillEscapesStrayMenu() {
    #expect(ModalReconciliation.decide(kind: .strayMenu, isDeleteContext: false) == .escapeMenu)
    #expect(ModalReconciliation.preflightShouldPerform(kind: .strayMenu, clearMandatoryNewTrack: false))
}

@Test func testPreflightNeverActsOnDeleteConfirmUnknownOrNone() {
    for clear in [true, false] {
        #expect(!ModalReconciliation.preflightShouldPerform(kind: .deleteConfirm, clearMandatoryNewTrack: clear))
        #expect(!ModalReconciliation.preflightShouldPerform(kind: .unknownSheet, clearMandatoryNewTrack: clear))
        #expect(!ModalReconciliation.preflightShouldPerform(kind: .none, clearMandatoryNewTrack: clear))
    }
}
