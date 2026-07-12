import Foundation

/// Pure, side-effect-free decision core for reconciling the blocking modals a
/// Logic Pro operation can trigger but never reconcile (#346), leaving Logic
/// permanently wedged. The live AX reader (`AccessibilityChannel+ModalReconcile`)
/// gathers observable signals into `ModalSignals`; `classify` maps them to a
/// `BlockingModalKind`; `decide` maps a kind + call context to a sanctioned
/// `ModalReconcileDecision`. No AX calls live here, so the full truth table is
/// unit-testable without a live Logic session.
///
/// The three live triggers (one class): the mandatory "Create New Track" sheet
/// (Cancel DISABLED, Escape inert — the ONLY exit is "Create") that Logic
/// auto-presents on delete-to-zero / fresh bootstrap; the "delete channel strips
/// that are assigned to tracks!" confirmation on channel-strip track delete; and
/// a Navigate menu left open on a marker-op error.
enum ModalReconciliation {

    /// Which blocking modal (if any) Logic is currently presenting.
    enum BlockingModalKind: Equatable, Sendable {
        case none
        /// Mandatory "New Track" sheet — Cancel disabled, only "Create" exits.
        case mandatoryNewTrack
        /// "delete channel strips that are assigned to tracks!" confirmation.
        case deleteConfirm
        /// A menu bar menu left open (no sheet present).
        case strayMenu
        /// A sheet is up that we do not recognise — never blindly dismissed.
        case unknownSheet
    }

    /// Observable signals read from the main window's sheet (+ menu bar). Pure
    /// inputs to `classify`, so the classifier stays fully deterministic.
    struct ModalSignals: Equatable, Sendable {
        let sheetPresent: Bool
        let sheetDescription: String
        let createButtonPresent: Bool
        let cancelButtonPresent: Bool
        let cancelButtonEnabled: Bool
        let deleteConfirmButtonPresent: Bool
        let strayMenuOpen: Bool
    }

    /// The sanctioned reconciliation action for a classified modal.
    enum ModalReconcileDecision: Equatable, Sendable {
        case noAction
        /// Click the mandatory New Track sheet's only exit ("Create").
        case clickCreate
        /// Confirm the delete-channel-strips sheet (primary delete button).
        case confirmDelete
        /// Send Escape to close a stray open menu.
        case escapeMenu
        /// Refuse to act — report the reason; NEVER blindly dismiss a modal we
        /// do not understand (a "Save changes?" prompt could lose data).
        case failClosed(String)
    }

    /// Logic's own `AXDescription` on the mandatory New Track sheet. Either this
    /// OR the disabled-Cancel signal is sufficient to identify the sheet.
    static let newTrackSheetDescription = "New Track"

    /// Classify the current modal from its observable signals. A present sheet
    /// always wins over a stray menu (a sheet is the stronger blocker), and the
    /// mandatory New Track sheet is disambiguated from an ordinary cancelable
    /// sheet by its DISABLED Cancel (or the "New Track" description) — the
    /// `createButtonPresent` conjunct keeps a delete-confirm sheet that happens
    /// to disable Cancel from being misread as a New Track sheet.
    static func classify(_ s: ModalSignals) -> BlockingModalKind {
        if s.sheetPresent {
            let isMandatoryNewTrack =
                (s.createButtonPresent && s.cancelButtonPresent && !s.cancelButtonEnabled)
                || s.sheetDescription == newTrackSheetDescription
            if isMandatoryNewTrack {
                return .mandatoryNewTrack
            }
            if s.deleteConfirmButtonPresent {
                return .deleteConfirm
            }
            return .unknownSheet
        }
        if s.strayMenuOpen {
            return .strayMenu
        }
        return .none
    }

    /// Map a classified modal + call context to a sanctioned action. The
    /// delete-confirm sheet is only confirmed inside a delete context; an
    /// unexpected one — or any unknown sheet — fails closed rather than being
    /// dismissed blindly.
    static func decide(kind: BlockingModalKind, isDeleteContext: Bool) -> ModalReconcileDecision {
        switch kind {
        case .mandatoryNewTrack:
            return .clickCreate
        case .deleteConfirm:
            return isDeleteContext ? .confirmDelete : .failClosed("unexpected delete-confirm sheet")
        case .strayMenu:
            return .escapeMenu
        case .unknownSheet:
            return .failClosed("unexpected blocking sheet")
        case .none:
            return .noAction
        }
    }
}
