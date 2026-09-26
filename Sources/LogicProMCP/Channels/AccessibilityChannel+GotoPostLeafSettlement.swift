import Foundation

/// #942. What the parent read off the window server after `goto_position`'s script returned from
/// a post-leaf refusal, and the one action, if any, that reading permits.
///
/// Fourteen of the script's returns come after the Go To Position leaf was clicked and end without
/// anyone reading whether the menu or the dialog is still up. The script cannot take that reading
/// itself: an open Logic menu wedges AppleEvent dispatch (-1712) and the dialog is modal, so the
/// two channels it could ask are the ones the leftover state disables. The parent reads the
/// CoreGraphics window list in-process instead (`LogicOnScreenWindows`), and this extension is the
/// rule that turns that reading into at most one action. Acting is the exception. Every branch
/// where a reading could not be taken, or where the screen holds something the parent did not
/// open, refuses, and the refusal names its reason so the receipt can carry it verbatim.
extension AccessibilityChannel {
    /// Whether a Logic popup menu is on screen. `unreadable` is the window list itself failing to
    /// come back, kept apart from `closed` because a read that did not happen is not a closed menu.
    enum PostLeafMenuReading: Equatable, Sendable {
        case closed
        case open(count: Int)
        case unreadable
    }

    /// Whether a Logic window that was not there before the leaf click is on screen, and whether
    /// the parent could tell it is the Go To Position dialog it opened. `unidentified` is a window
    /// that appeared and could not be matched to that dialog; the parent presses nothing it cannot
    /// name (#726).
    enum PostLeafDialogReading: Equatable, Sendable {
        case absent
        case identifiedOurs
        case unidentified(count: Int)
        case unreadable
    }

    struct PostLeafScreenReading: Equatable, Sendable {
        let menu: PostLeafMenuReading
        let dialog: PostLeafDialogReading
        /// From the first normal-layer window's owner, as `LogicOnScreenWindows.keyboardOwnerIsLogic`
        /// reads it; nil when the list has no such window or its owner is unreadable. An Escape sent
        /// while another process owns the keyboard is an Escape sent to that process.
        let logicOwnsKeyboard: Bool?
    }

    /// Whether Escape may be sent at an open menu while the Go To Position dialog is also up.
    ///
    /// The menu sits above the modal dialog. One Escape either closes the menu and leaves the
    /// dialog, or is taken by the dialog under it. Only a linked live observation record of that
    /// Escape ordering -- a Logic menu open over the modal Go To Position dialog, Escape sent the
    /// way the server sends it, both surfaces re-read from the window list -- may change `current`.
    /// A unit test cannot, and neither can a record taken for a different dialog.
    ///
    /// `current` is `.menuEscapeMeasuredToLeaveDialog` on the strength of
    /// docs/observations/2026-09-26-ko-KR-escape-over-go-to-position-closes-the-menu-first.json:
    /// in three samples a key-53 Escape at the HID tap closed the Navigate menu and left the same
    /// dialog window on screen, unchanged, 1.5 s later: over six times the longest the same Escape
    /// took to remove the dialog alone (0.235 s). The loop that acts on it must re-read the popup
    /// count before every Escape, so a further Escape goes out only while a menu is still counted.
    enum EscapeOverDialogPolicy: String, Sendable, CaseIterable {
        case withheldWhileDialogPresent = "withheld_while_dialog_present"
        case menuEscapeMeasuredToLeaveDialog = "menu_escape_measured_to_leave_dialog"

        static let current: EscapeOverDialogPolicy = .menuEscapeMeasuredToLeaveDialog
    }

    enum PostLeafAction: Equatable, Sendable {
        case none
        case menuEscapeLoop
        case dialogCancel
        case refuseToAct(reason: String)
    }

    /// The decision table. Every refusal reason is a fixed token, and the two invariants a caller
    /// may rely on are: neither actuating case is returned while either reading is unreadable or
    /// the dialog is unidentified, and under `.withheldWhileDialogPresent` the menu loop is never
    /// returned while the dialog reading is anything but absent. The policy is consulted only for
    /// the dialog the parent identified as its own: an unreadable or unidentified reading refuses
    /// under its own reason, because naming it "dialog present" would report a dialog nobody read.
    static func decidePostLeafAction(
        _ reading: PostLeafScreenReading, policy: EscapeOverDialogPolicy
    ) -> PostLeafAction {
        // nil is not false here, but it is not true either: the loop sends keystrokes, and a
        // keyboard owner that was not read is a keystroke sent to nobody in particular.
        let logicHoldsKeyboard = reading.logicOwnsKeyboard == true
        let menuEscapeLoopIfLogicHoldsKeyboard: PostLeafAction =
            logicHoldsKeyboard ? .menuEscapeLoop : .refuseToAct(reason: "logic_not_keyboard_owner")

        switch reading.menu {
        case .unreadable:
            return .refuseToAct(reason: "window_list_unreadable")
        case .closed:
            switch reading.dialog {
            case .absent:
                return .none
            case .identifiedOurs:
                return .dialogCancel
            case .unidentified:
                return .refuseToAct(reason: "unidentified_dialog_present")
            case .unreadable:
                return .refuseToAct(reason: "dialog_reading_unreadable")
            }
        case .open:
            switch reading.dialog {
            case .absent:
                return menuEscapeLoopIfLogicHoldsKeyboard
            case .unidentified:
                return .refuseToAct(reason: "unidentified_dialog_present")
            case .unreadable:
                return .refuseToAct(reason: "dialog_reading_unreadable")
            case .identifiedOurs:
                return policy == .menuEscapeMeasuredToLeaveDialog
                    ? menuEscapeLoopIfLogicHoldsKeyboard
                    : .refuseToAct(reason: "dialog_present_escape_withheld")
            }
        }
    }
}
