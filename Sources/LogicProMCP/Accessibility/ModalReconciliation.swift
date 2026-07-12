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
        /// A top-level informational `AXDialog` alert (NOT a main-window sheet)
        /// with EXACTLY ONE button — safe to acknowledge. A 2+ button dialog is
        /// a CHOICE and is classified `.unknownSheet` instead (fail closed).
        case informationalAlert
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
        /// A top-level `AXDialog` alert window (NOT a main-window sheet) is up.
        /// Only populated on the no-sheet branch, so a sheet always outranks it.
        let topLevelAlertPresent: Bool
        /// Number of titled buttons on that alert — the safety discriminator:
        /// exactly one ⇒ informational (acknowledge); two+ ⇒ a choice (fail closed).
        let topLevelAlertButtonCount: Int
        /// The single button's title (empty when none/ambiguous).
        let topLevelAlertPrimaryButton: String
    }

    /// The sanctioned reconciliation action for a classified modal.
    enum ModalReconcileDecision: Equatable, Sendable {
        case noAction
        /// Click the mandatory New Track sheet's only exit ("Create").
        case clickCreate
        /// Confirm the delete-channel-strips sheet (primary delete button).
        case confirmDelete
        /// Acknowledge a single-button top-level informational alert (click its
        /// only button). Safe in any context — one button means no lossy choice.
        case acknowledgeAlert
        /// Send Escape to close a stray open menu.
        case escapeMenu
        /// Refuse to act — report the reason; NEVER blindly dismiss a modal we
        /// do not understand (a "Save changes?" prompt could lose data).
        case failClosed(String)
    }

    /// Logic's own `AXDescription` on the mandatory New Track sheet. Either this
    /// OR the disabled-Cancel signal is sufficient to identify the sheet.
    static let newTrackSheetDescription = "New Track"

    /// Classify the current modal from its observable signals. Precedence: a
    /// main-window sheet (the strongest blocker) outranks a top-level alert,
    /// which outranks a stray menu. The mandatory New Track sheet is
    /// disambiguated from an ordinary cancelable sheet by its DISABLED Cancel (or
    /// the "New Track" description) — the `createButtonPresent` conjunct keeps a
    /// delete-confirm sheet that happens to disable Cancel from being misread as
    /// a New Track sheet. A top-level alert is only acknowledged when it has
    /// EXACTLY ONE button; two+ buttons is a lossy CHOICE and fails closed.
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
        if s.topLevelAlertPresent {
            // Exactly one button ⇒ informational (safe to acknowledge). Anything
            // else (0 ambiguous, or 2+ = a choice like Save/Don't Save/Cancel) is
            // never guessed — fail closed as an unknown sheet.
            return s.topLevelAlertButtonCount == 1 ? .informationalAlert : .unknownSheet
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
        case .informationalAlert:
            return .acknowledgeAlert
        case .strayMenu:
            return .escapeMenu
        case .unknownSheet:
            return .failClosed("unexpected blocking sheet")
        case .none:
            return .noAction
        }
    }
}
