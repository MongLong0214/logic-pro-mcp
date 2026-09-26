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

    /// The decision table. Every refusal reason is a fixed token, and the three invariants a caller
    /// may rely on are: neither actuating case is returned while either reading is unreadable or
    /// the dialog is unidentified; neither actuating case is returned unless Logic was read to own
    /// the keyboard, because both are one Escape keystroke and a keystroke goes to whoever owns
    /// the keyboard; and under `.withheldWhileDialogPresent` the menu loop is never returned while
    /// the dialog reading is anything but absent. The policy is consulted only for the dialog the
    /// parent identified as its own: an unreadable or unidentified reading refuses under its own
    /// reason, because naming it "dialog present" would report a dialog nobody read.
    static func decidePostLeafAction(
        _ reading: PostLeafScreenReading, policy: EscapeOverDialogPolicy
    ) -> PostLeafAction {
        // nil is not false here, but it is not true either: the loop sends keystrokes, and a
        // keyboard owner that was not read is a keystroke sent to nobody in particular.
        let logicHoldsKeyboard = reading.logicOwnsKeyboard == true
        let menuEscapeLoopIfLogicHoldsKeyboard: PostLeafAction =
            logicHoldsKeyboard ? .menuEscapeLoop : .refuseToAct(reason: "logic_not_keyboard_owner")
        // The dialog cancel is the same key-53 Escape the record measured (3/3 samples at the HID
        // tap), not a System Events click on the Cancel button, so it needs the keyboard exactly as
        // the menu loop does. It used to be returned on any keyboard reading (010d0e22).
        let dialogCancelIfLogicHoldsKeyboard: PostLeafAction =
            logicHoldsKeyboard ? .dialogCancel : .refuseToAct(reason: "logic_not_keyboard_owner")

        switch reading.menu {
        case .unreadable:
            return .refuseToAct(reason: "window_list_unreadable")
        case .closed:
            switch reading.dialog {
            case .absent:
                return .none
            case .identifiedOurs:
                return dialogCancelIfLogicHoldsKeyboard
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

    // MARK: - Reading the screen

    /// One reading of the screen from one window list, against the Logic-owned window numbers the
    /// parent read before the script ran. Every question is put to the same list, so the menu, the
    /// dialog and the keyboard owner describe one instant.
    ///
    /// A nil list or nil pid is a reading that was not taken: both halves are `unreadable` and
    /// `appeared` is nil. A nil baseline leaves the menu and keyboard readable -- they need no
    /// baseline -- but the dialog `unreadable`, because "what appeared since" cannot be answered
    /// without a "since". The dialog is `identifiedOurs` only when exactly one Logic window
    /// appeared and its name is a `goToPositionDialogTitle` under `.exactStrict`; two or more, or
    /// one whose name is missing or something else, is `unidentified`. `kCGWindowName` is
    /// populated only for processes holding Screen Recording, and whether the server process holds
    /// it is unmeasured: a nil name here refuses as `unidentified_dialog_present`, which is the safe
    /// direction (nothing is pressed), not a reading of the dialog's title.
    static func readPostLeafScreen(
        baseline: Set<Int>?, logicPID: pid_t?, windows: [[String: Any]]?
    ) -> (reading: PostLeafScreenReading, appeared: [LogicOnScreenWindows.Entry]?) {
        guard let logicPID, let windows else {
            return (PostLeafScreenReading(menu: .unreadable, dialog: .unreadable, logicOwnsKeyboard: nil), nil)
        }
        let popupCount = LogicOnScreenWindows.popupMenuCount(windows, logicPID: logicPID)
        let menu: PostLeafMenuReading = popupCount == 0 ? .closed : .open(count: popupCount)
        let keyboard = LogicOnScreenWindows.keyboardOwnerIsLogic(windows, logicPID: logicPID)
        guard let baseline else {
            return (PostLeafScreenReading(menu: menu, dialog: .unreadable, logicOwnsKeyboard: keyboard), nil)
        }
        let appeared = LogicOnScreenWindows.appearedSince(baseline: baseline, in: windows, logicPID: logicPID)
        let dialog: PostLeafDialogReading
        if appeared.isEmpty {
            dialog = .absent
        } else if appeared.count == 1,
                  AXLocalePolicy.goToPositionDialogTitle.matches(appeared[0].name, mode: .exactStrict) {
            dialog = .identifiedOurs
        } else {
            dialog = .unidentified(count: appeared.count)
        }
        return (PostLeafScreenReading(menu: menu, dialog: dialog, logicOwnsKeyboard: keyboard), appeared)
    }

    // MARK: - Settling the screen

    /// At most this many Escapes per settlement, whichever surface each one is aimed at.
    static let postLeafEscapeAttempts = 3
    /// After an Escape the targeted surface is re-read up to this many times before the next
    /// decision. 20 x 50 ms = 1.0 s, more than three times the longest measured removal: the menu
    /// left in 0.28-0.293 s and the dialog in 0.23-0.235 s after one key-53 Escape at the HID tap
    /// (docs/observations/2026-09-26-ko-KR-escape-over-go-to-position-closes-the-menu-first.json).
    /// #1016's 3 x 50 ms would have read both surfaces still present on every poll.
    static let postLeafEscapeSettlePolls = 20
    static let postLeafEscapeSettlePollMicros: UInt32 = 50_000

    /// What one settlement pass read, sent and read again. `settled` is the only Boolean a caller
    /// should branch on, and it is true only when the last reading decided `.none`: a menu closed
    /// and no dialog on screen. An unreadable last reading decides a refusal, so it is never
    /// settled; neither is a surface still counted after the last permitted Escape.
    struct PostLeafSettlement: Equatable, Sendable {
        /// The policy every decision in this pass was taken under.
        let policy: EscapeOverDialogPolicy
        let initial: PostLeafScreenReading
        let initialAppeared: [LogicOnScreenWindows.Entry]?
        /// The decision over `initial`. The loop does not act on it -- it re-reads first -- but the
        /// receipt reports it, because it is what the screen looked like when the script returned.
        let decided: PostLeafAction
        /// One entry per Escape sent, `menu` or `dialog`, in the order they went out.
        let escapeTargets: [String]
        let final: PostLeafScreenReading
        let finalAppeared: [LogicOnScreenWindows.Entry]?
        let finalAction: PostLeafAction

        var settled: Bool { finalAction == .none }

        /// The `post_leaf_settlement` object, keyed and ready to merge into a receipt. The tokens
        /// are the decision's own; `after` appears only when something was sent, so a receipt with
        /// no `after` is a receipt of a pass that typed nothing.
        var receiptFields: [String: Any] {
            var object: [String: Any] = [
                "policy": policy.rawValue,
                "read": Self.readingFields(initial, appeared: initialAppeared),
                "action": Self.actionToken(decided),
                "escapes_sent": escapeTargets.count,
                "escape_targets": escapeTargets,
                "final_action": Self.actionToken(finalAction),
                "settled": settled,
            ]
            if case let .refuseToAct(reason) = decided {
                object["refusal_reason"] = reason
            }
            if !escapeTargets.isEmpty {
                object["after"] = Self.readingFields(final, appeared: finalAppeared)
            }
            if case let .refuseToAct(reason) = finalAction {
                object["final_refusal_reason"] = reason
            }
            return ["post_leaf_settlement": object]
        }

        static func actionToken(_ action: PostLeafAction) -> String {
            switch action {
            case .none: return "none"
            case .menuEscapeLoop: return "menu_escape_loop"
            case .dialogCancel: return "dialog_cancel"
            case .refuseToAct: return "refuse_to_act"
            }
        }

        static func readingFields(
            _ reading: PostLeafScreenReading, appeared: [LogicOnScreenWindows.Entry]?
        ) -> [String: Any] {
            var fields: [String: Any] = [:]
            switch reading.menu {
            case .closed:
                fields["menu"] = "closed"
            case let .open(count):
                fields["menu"] = "open"
                fields["menu_count"] = count
            case .unreadable:
                fields["menu"] = "unreadable"
            }
            switch reading.dialog {
            case .absent:
                fields["dialog"] = "absent"
            case .identifiedOurs:
                fields["dialog"] = "identified_ours"
            case let .unidentified(count):
                fields["dialog"] = "unidentified"
                fields["dialog_count"] = count
            case .unreadable:
                fields["dialog"] = "unreadable"
            }
            if let appeared {
                fields["appeared_windows"] = appeared.map { entry -> [String: Any] in
                    ["number": entry.number, "layer": entry.layer, "name": entry.name ?? NSNull()]
                }
            } else {
                fields["appeared_windows"] = "unreadable"
            }
            switch reading.logicOwnsKeyboard {
            case .some(true): fields["keyboard_owner"] = "logic"
            case .some(false): fields["keyboard_owner"] = "other"
            case .none: fields["keyboard_owner"] = "unread"
            }
            return fields
        }
    }

    /// Reads the screen, sends the one Escape the reading permits, and reads again, at most
    /// `postLeafEscapeAttempts` times. Every Escape is preceded by its own fresh reading, at the
    /// top of the attempt: the initial reading is reported but never acted on, so a list that
    /// stops answering, or a keyboard that moved to another process, between two reads stops the
    /// loop with nothing further sent. After an Escape the targeted surface is polled through
    /// `sleepMicros` until it is no longer counted or `postLeafEscapeSettlePolls` polls have
    /// passed; the next attempt then decides over that last poll. The final decision is taken over
    /// the last reading the loop made, whichever way it ended.
    static func settlePostLeafScreen(
        baseline: Set<Int>?,
        runtime: AXLogicProElements.Runtime,
        policy: EscapeOverDialogPolicy,
        sleepMicros: @Sendable (UInt32) -> Void
    ) -> PostLeafSettlement {
        let logicPID = runtime.logicProPID()
        func read() -> (reading: PostLeafScreenReading, appeared: [LogicOnScreenWindows.Entry]?) {
            readPostLeafScreen(baseline: baseline, logicPID: logicPID, windows: runtime.onScreenWindowList())
        }

        let initial = read()
        let decided = decidePostLeafAction(initial.reading, policy: policy)
        var escapeTargets: [String] = []
        var last = initial
        func finish() -> PostLeafSettlement {
            PostLeafSettlement(
                policy: policy,
                initial: initial.reading,
                initialAppeared: initial.appeared,
                decided: decided,
                escapeTargets: escapeTargets,
                final: last.reading,
                finalAppeared: last.appeared,
                finalAction: decidePostLeafAction(last.reading, policy: policy)
            )
        }

        while escapeTargets.count < postLeafEscapeAttempts {
            last = read()
            let target: String
            switch decidePostLeafAction(last.reading, policy: policy) {
            case .menuEscapeLoop: target = "menu"
            case .dialogCancel: target = "dialog"
            case .none, .refuseToAct: return finish()
            }
            runtime.postPopupMenuEscape()
            escapeTargets.append(target)
            for _ in 0..<postLeafEscapeSettlePolls {
                sleepMicros(postLeafEscapeSettlePollMicros)
                last = read()
                if !stillCounted(target, in: last.reading) { break }
            }
        }
        return finish()
    }

    /// Whether the surface an Escape was aimed at is still positively counted. An unreadable
    /// re-read is not "still there": polling stops and the next attempt's decision refuses on it.
    private static func stillCounted(_ target: String, in reading: PostLeafScreenReading) -> Bool {
        if target == "menu" {
            if case .open = reading.menu { return true }
            return false
        }
        return reading.dialog == .identifiedOurs
    }
}
