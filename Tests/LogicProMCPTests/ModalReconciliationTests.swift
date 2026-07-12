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
    strayMenuOpen: Bool = false
) -> ModalReconciliation.ModalSignals {
    ModalReconciliation.ModalSignals(
        sheetPresent: sheetPresent,
        sheetDescription: sheetDescription,
        createButtonPresent: createButtonPresent,
        cancelButtonPresent: cancelButtonPresent,
        cancelButtonEnabled: cancelButtonEnabled,
        deleteConfirmButtonPresent: deleteConfirmButtonPresent,
        strayMenuOpen: strayMenuOpen
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
