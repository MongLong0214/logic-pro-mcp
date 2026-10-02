import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import LogicProMCP

/// #942. The post-leaf screen decision and the window-list readers it is fed from.
///
/// The decision table below is written out by hand from the rule, one row per cell of
/// menu × dialog × keyboard × policy, and a separate test checks that the rows cover the domain
/// exactly once. It is not generated from the function, so a change to the function that is not
/// also a change to the rule shows up as a red row, not as a table that agrees with itself.
///
/// NO `#expect(<Bool> == <Bool>)` HERE (#393, `Scripts/ci-forbid-dead-expect.sh`). The keyboard
/// reader answers `Bool?`, and its three answers are projected through a String so that nil is
/// asserted as a value and not through an Optional<Bool> comparison.
@Suite("#942 post-leaf screen decision")
struct Issue942PostLeafDecisionTests {
    typealias Menu = AccessibilityChannel.PostLeafMenuReading
    typealias Dialog = AccessibilityChannel.PostLeafDialogReading
    typealias Policy = AccessibilityChannel.EscapeOverDialogPolicy
    typealias Action = AccessibilityChannel.PostLeafAction

    struct DecisionCell: Sendable, CustomTestStringConvertible {
        let menu: Menu
        let dialog: Dialog
        let keyboard: Bool?
        let policy: Policy
        let expected: Action

        init(_ menu: Menu, _ dialog: Dialog, _ keyboard: Bool?, _ policy: Policy, _ expected: Action) {
            self.menu = menu
            self.dialog = dialog
            self.keyboard = keyboard
            self.policy = policy
            self.expected = expected
        }

        var testDescription: String {
            "menu=\(menu) dialog=\(dialog) keyboard=\(Issue942PostLeafDecisionTests.describe(keyboard)) "
                + "policy=\(policy.rawValue) -> \(expected)"
        }
    }

    static let menus: [Menu] = [.closed, .open(count: 1), .unreadable]
    static let dialogs: [Dialog] = [.absent, .identifiedOurs, .unidentified(count: 1), .unreadable]
    static let keyboards: [Bool?] = [true, false, nil]

    /// The rule, as literal data. Rows are grouped by menu reading, then dialog reading, then
    /// keyboard, with the two policies side by side so the one place they differ is visible.
    static let decisionTable: [DecisionCell] = [
        // menu unreadable: refuse whatever the rest says.
        .init(.unreadable, .absent, true, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .absent, true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .absent, false, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .absent, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .absent, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .absent, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .identifiedOurs, true, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .identifiedOurs, true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .identifiedOurs, false, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .identifiedOurs, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .identifiedOurs, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .identifiedOurs, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unidentified(count: 1), true, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unidentified(count: 1), true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unidentified(count: 1), false, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unidentified(count: 1), false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unidentified(count: 1), nil, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unidentified(count: 1), nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unreadable, true, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unreadable, true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unreadable, false, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unreadable, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unreadable, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "window_list_unreadable")),
        .init(.unreadable, .unreadable, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "window_list_unreadable")),

        // menu closed: the dialog reading decides and policy plays no part. The one keystroke it
        // can permit, the dialog cancel, is the same Escape as the menu loop's and needs the
        // keyboard the same way.
        .init(.closed, .absent, true, .withheldWhileDialogPresent, .none),
        .init(.closed, .absent, true, .menuEscapeMeasuredToLeaveDialog, .none),
        .init(.closed, .absent, false, .withheldWhileDialogPresent, .none),
        .init(.closed, .absent, false, .menuEscapeMeasuredToLeaveDialog, .none),
        .init(.closed, .absent, nil, .withheldWhileDialogPresent, .none),
        .init(.closed, .absent, nil, .menuEscapeMeasuredToLeaveDialog, .none),
        .init(.closed, .identifiedOurs, true, .withheldWhileDialogPresent, .dialogCancel),
        .init(.closed, .identifiedOurs, true, .menuEscapeMeasuredToLeaveDialog, .dialogCancel),
        .init(.closed, .identifiedOurs, false, .withheldWhileDialogPresent, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.closed, .identifiedOurs, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.closed, .identifiedOurs, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.closed, .identifiedOurs, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.closed, .unidentified(count: 1), true, .withheldWhileDialogPresent, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.closed, .unidentified(count: 1), true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.closed, .unidentified(count: 1), false, .withheldWhileDialogPresent, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.closed, .unidentified(count: 1), false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.closed, .unidentified(count: 1), nil, .withheldWhileDialogPresent, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.closed, .unidentified(count: 1), nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.closed, .unreadable, true, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.closed, .unreadable, true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.closed, .unreadable, false, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.closed, .unreadable, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.closed, .unreadable, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.closed, .unreadable, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "dialog_reading_unreadable")),

        // menu open, dialog absent: the loop runs only for a keyboard Logic was read to own.
        .init(.open(count: 1), .absent, true, .withheldWhileDialogPresent, .menuEscapeLoop),
        .init(.open(count: 1), .absent, true, .menuEscapeMeasuredToLeaveDialog, .menuEscapeLoop),
        .init(.open(count: 1), .absent, false, .withheldWhileDialogPresent, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.open(count: 1), .absent, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.open(count: 1), .absent, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.open(count: 1), .absent, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "logic_not_keyboard_owner")),

        // menu open, dialog present: withheld refuses outright; the measured policy loops only for
        // the dialog the parent identified, and only with the keyboard.
        .init(.open(count: 1), .identifiedOurs, true, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_present_escape_withheld")),
        .init(.open(count: 1), .identifiedOurs, true, .menuEscapeMeasuredToLeaveDialog, .menuEscapeLoop),
        .init(.open(count: 1), .identifiedOurs, false, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_present_escape_withheld")),
        .init(.open(count: 1), .identifiedOurs, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.open(count: 1), .identifiedOurs, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_present_escape_withheld")),
        .init(.open(count: 1), .identifiedOurs, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "logic_not_keyboard_owner")),
        .init(.open(count: 1), .unidentified(count: 1), true, .withheldWhileDialogPresent, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.open(count: 1), .unidentified(count: 1), true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.open(count: 1), .unidentified(count: 1), false, .withheldWhileDialogPresent, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.open(count: 1), .unidentified(count: 1), false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.open(count: 1), .unidentified(count: 1), nil, .withheldWhileDialogPresent, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.open(count: 1), .unidentified(count: 1), nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "unidentified_dialog_present")),
        .init(.open(count: 1), .unreadable, true, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.open(count: 1), .unreadable, true, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.open(count: 1), .unreadable, false, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.open(count: 1), .unreadable, false, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.open(count: 1), .unreadable, nil, .withheldWhileDialogPresent, .refuseToAct(reason: "dialog_reading_unreadable")),
        .init(.open(count: 1), .unreadable, nil, .menuEscapeMeasuredToLeaveDialog, .refuseToAct(reason: "dialog_reading_unreadable")),
    ]

    static func describe(_ keyboard: Bool?) -> String {
        guard let keyboard else { return "unread" }
        return keyboard ? "logic" : "other"
    }

    static func decide(_ cell: DecisionCell) -> Action {
        AccessibilityChannel.decidePostLeafAction(
            .init(menu: cell.menu, dialog: cell.dialog, logicOwnsKeyboard: cell.keyboard),
            policy: cell.policy)
    }

    // MARK: - The decision table

    @Test(arguments: Self.decisionTable)
    func theDecisionMatchesTheHandWrittenRow(_ cell: DecisionCell) {
        #expect(Self.decide(cell) == cell.expected)
    }

    /// The table is only a proof of the rule if it names every cell once. 3 × 4 × 3 × 2 = 72,
    /// counted as distinct descriptions of the inputs so a duplicated row cannot hide a missing one.
    @Test func theTableCoversEveryCellExactlyOnce() {
        var expectedKeys: Set<String> = []
        for menu in Self.menus {
            for dialog in Self.dialogs {
                for keyboard in Self.keyboards {
                    for policy in Policy.allCases {
                        expectedKeys.insert("\(menu)|\(dialog)|\(Self.describe(keyboard))|\(policy.rawValue)")
                    }
                }
            }
        }
        let tableKeys = Self.decisionTable.map {
            "\($0.menu)|\($0.dialog)|\(Self.describe($0.keyboard))|\($0.policy.rawValue)"
        }
        #expect(expectedKeys.count == 72)
        #expect(Self.decisionTable.count == 72)
        #expect(Set(tableKeys).count == tableKeys.count)
        #expect(Set(tableKeys) == expectedKeys)
    }

    // MARK: - Invariants, checked against the function rather than the table

    /// Neither actuating action while either reading is unreadable or the dialog is unidentified.
    static func readingWasNotTakenOrNotIdentified(_ cell: DecisionCell) -> Bool {
        if case .unidentified = cell.dialog { return true }
        return cell.menu == .unreadable || cell.dialog == .unreadable
    }

    @Test(arguments: Self.decisionTable.filter { Self.readingWasNotTakenOrNotIdentified($0) })
    func nothingIsActuatedOnAReadingThatWasNotTakenOrNotIdentified(_ cell: DecisionCell) {
        let action = Self.decide(cell)
        #expect(action != .menuEscapeLoop)
        #expect(action != .dialogCancel)
    }

    /// Under the withheld policy the menu loop never runs over a dialog reading that is not absent.
    @Test(arguments: Self.decisionTable.filter { $0.policy == .withheldWhileDialogPresent && $0.dialog != .absent })
    func theWithheldPolicyNeverLoopsOverAPresentDialog(_ cell: DecisionCell) {
        #expect(Self.decide(cell) != .menuEscapeLoop)
    }

    /// Every refusal reason the table carries is one of the five tokens the receipt may show.
    @Test func everyRefusalReasonIsAKnownToken() {
        let known: Set<String> = [
            "window_list_unreadable", "unidentified_dialog_present", "dialog_reading_unreadable",
            "logic_not_keyboard_owner", "dialog_present_escape_withheld",
        ]
        var seen: Set<String> = []
        for cell in Self.decisionTable {
            if case let .refuseToAct(reason) = Self.decide(cell) { seen.insert(reason) }
        }
        #expect(seen == known)
    }

    /// The shipped policy follows the live record
    /// 2026-09-26-ko-KR-escape-over-go-to-position-closes-the-menu-first; changing it needs a new record.
    @Test func theShippedPolicyIsTheMeasuredOrdering() {
        #expect(Policy.current == .menuEscapeMeasuredToLeaveDialog)
        #expect(Policy.withheldWhileDialogPresent.rawValue == "withheld_while_dialog_present")
        #expect(Policy.menuEscapeMeasuredToLeaveDialog.rawValue == "menu_escape_measured_to_leave_dialog")
        #expect(Policy.allCases.count == 2)
    }

    // MARK: - Window-list readers

    static let logicPID: pid_t = 7174
    static let finderPID: pid_t = 101
    static let otherPID: pid_t = 202

    static func window(
        owner: Any, number: Int, layer: Any?, name: String? = nil, bounds: [String: Any]? = nil
    ) -> [String: Any] {
        var window: [String: Any] = [
            kCGWindowOwnerPID as String: owner,
            kCGWindowNumber as String: NSNumber(value: number),
        ]
        if let layer { window[kCGWindowLayer as String] = layer }
        if let name { window[kCGWindowName as String] = name }
        if let bounds { window[kCGWindowBounds as String] = bounds }
        return window
    }

    /// Front to back, as the window server orders it: Logic's menu on top, Finder's main window
    /// above Logic's, so the keyboard is Finder's. One popup-level window belongs to another
    /// process, one Logic window sits a level above the menu, one carries no layer at all.
    static var mixedScreen: [[String: Any]] {
        [
        window(owner: NSNumber(value: logicPID), number: 900, layer: NSNumber(value: LogicOnScreenWindows.popupMenuLevel)),
        window(owner: NSNumber(value: otherPID), number: 901, layer: NSNumber(value: LogicOnScreenWindows.popupMenuLevel)),
        window(owner: Int(logicPID), number: 902, layer: NSNumber(value: LogicOnScreenWindows.popupMenuLevel + 1)),
        window(owner: NSNumber(value: logicPID), number: 903, layer: nil),
        window(owner: NSNumber(value: finderPID), number: 904, layer: NSNumber(value: 0), name: "Finder"),
        window(
            owner: NSNumber(value: logicPID), number: 905, layer: NSNumber(value: 0), name: "Untitled - Tracks",
            bounds: [
                "X": NSNumber(value: 10), "Y": NSNumber(value: 20),
                "Width": NSNumber(value: 1600), "Height": NSNumber(value: 900),
            ]),
        ]
    }

    @Test func logicOwnedKeepsLogicRowsWithANumberAndALayerAndNothingElse() {
        let entries = LogicOnScreenWindows.logicOwned(Self.mixedScreen, logicPID: Self.logicPID)
        #expect(entries.map(\.number) == [900, 902, 905])
        #expect(entries.map(\.layer) == [LogicOnScreenWindows.popupMenuLevel, LogicOnScreenWindows.popupMenuLevel + 1, 0])
        #expect(entries.map(\.name) == [nil, nil, "Untitled - Tracks"])
        #expect(entries.map(\.bounds) == [nil, nil, CGRect(x: 10, y: 20, width: 1600, height: 900)])
    }

    @Test func logicOwnedAcceptsTheThreePidSpellings() {
        let boxed = Self.window(owner: NSNumber(value: Self.logicPID), number: 1, layer: 0)
        let int = Self.window(owner: Int(Self.logicPID), number: 2, layer: 0)
        let native = Self.window(owner: Self.logicPID, number: 3, layer: 0)
        let entries = LogicOnScreenWindows.logicOwned([boxed, int, native], logicPID: Self.logicPID)
        #expect(entries.map(\.number) == [1, 2, 3])
    }

    @Test func aPartialBoundsDictionaryReadsAsNoBounds() {
        let partial = Self.window(
            owner: Self.logicPID, number: 1, layer: 0,
            bounds: ["Width": NSNumber(value: 1600), "Height": NSNumber(value: 900)])
        let entries = LogicOnScreenWindows.logicOwned([partial], logicPID: Self.logicPID)
        #expect(entries.count == 1)
        #expect(entries.first?.bounds == nil)
    }

    /// The popup at the exact level counts; the other process's popup, Logic's window one level
    /// up, and the row without a layer do not.
    @Test func popupMenuCountCountsOnlyLogicWindowsAtExactlyThePopupLevel() {
        #expect(LogicOnScreenWindows.popupMenuCount(Self.mixedScreen, logicPID: Self.logicPID) == 1)
        #expect(LogicOnScreenWindows.popupMenuCount(Self.mixedScreen, logicPID: Self.otherPID) == 1)
        #expect(LogicOnScreenWindows.popupMenuCount(Self.mixedScreen, logicPID: Self.finderPID) == 0)
        #expect(LogicOnScreenWindows.popupMenuCount([], logicPID: Self.logicPID) == 0)
    }

    /// The level the live reading found an open Logic menu at (an open menu wedges AppleEvents at
    /// layer 101). If the toolchain ever moves the key this pins the moment the reading changed.
    @Test func thePopupMenuLevelIsTheOneTheLiveReadingSaw() {
        #expect(LogicOnScreenWindows.popupMenuLevel == 101)
    }

    static func keyboardOwner(_ windows: [[String: Any]], focused: pid_t? = nil) -> String {
        describe(LogicOnScreenWindows.keyboardOwnerIsLogic(windows, logicPID: logicPID, focusedApplicationPID: focused))
    }

    /// The screen of 2026-10-02 with Finder activated and no Finder window open
    /// (lpm-evidence/942/inactive-layer/run2.json, state A1), front to back from layer 8 down:
    /// Logic's marker list at 3, its Go To Position dialog demoted from 8 to 0, its Tracks window
    /// at 0. `lsappinfo front` and the system-wide AXFocusedApplication both named Finder.
    static var windowlessFinderOverLogic: [[String: Any]] {
        [
            window(owner: NSNumber(value: logicPID), number: 3343, layer: NSNumber(value: 3)),
            window(owner: NSNumber(value: logicPID), number: 3386, layer: NSNumber(value: 0)),
            window(owner: NSNumber(value: logicPID), number: 3342, layer: NSNumber(value: 0)),
        ]
    }

    /// Mutations this kills: the focused application ignored (the first expectation reads
    /// "logic"); an unread focused application taken as "not Logic" (the second reads "other").
    @Test func anApplicationWithNoWindowHoldsTheKeyboardWhenTheAccessibilityServerSaysSo() {
        #expect(Self.keyboardOwner(Self.windowlessFinderOverLogic, focused: Self.finderPID) == "other")
        #expect(Self.keyboardOwner(Self.windowlessFinderOverLogic, focused: nil) == "logic")
        #expect(Self.keyboardOwner(Self.windowlessFinderOverLogic, focused: Self.logicPID) == "logic")
    }

    /// The production predicate, from what it read. Review R1 of #1082: the focused application
    /// was accepted through `isKnownLogicPID`, which answers true for a pid whose bundle does not
    /// read, so a focused helper process passed. Mutation this kills: accepting the focused pid by
    /// `isKnownLogicPID` instead of requiring it to be the keyboard window's own process.
    @Test func theFrontmostGateNeedsTheFocusedApplicationToBeTheKeyboardWindowsOwnProcess() {
        let windows: [[String: Any]] = [
            Self.window(owner: NSNumber(value: Self.logicPID), number: 1, layer: NSNumber(value: 0)),
        ]
        let everyPidIsLogic: (pid_t) -> Bool = { _ in true }
        #expect(!ProcessUtils.logicOwnsTheKeyboard(
            windows: windows, focusedApplicationPID: Self.finderPID, isKnownLogicPID: everyPidIsLogic))
        #expect(ProcessUtils.logicOwnsTheKeyboard(
            windows: windows, focusedApplicationPID: Self.logicPID, isKnownLogicPID: everyPidIsLogic))
        #expect(ProcessUtils.logicOwnsTheKeyboard(
            windows: windows, focusedApplicationPID: nil, isKnownLogicPID: everyPidIsLogic))
        #expect(!ProcessUtils.logicOwnsTheKeyboard(
            windows: windows, focusedApplicationPID: Self.logicPID, isKnownLogicPID: { _ in false }))
    }

    /// Both readings must say Logic. Mutation this kills: the focused application overriding the
    /// window reading, so a prompt in front of Logic reads as Logic's because Logic is focused.
    @Test func aFocusedLogicDoesNotOverrideAnotherProcesssKeyboardWindow() {
        #expect(Self.keyboardOwner(Self.alertOverLogic, focused: Self.logicPID) == "other")
        let unreadableOwner: [[String: Any]] = [
            Self.window(owner: "Logic Pro", number: 1, layer: NSNumber(value: 0)),
        ]
        #expect(Self.keyboardOwner(unreadableOwner, focused: Self.logicPID) == "unread")
    }

    @Test func theKeyboardOwnerIsTheFirstNormalLayerWindowsOwner() {
        #expect(Self.keyboardOwner(Self.mixedScreen) == "other")
        let logicInFront: [[String: Any]] = [
            Self.window(owner: NSNumber(value: Self.logicPID), number: 1, layer: NSNumber(value: LogicOnScreenWindows.popupMenuLevel)),
            Self.window(owner: NSNumber(value: Self.logicPID), number: 2, layer: NSNumber(value: 0)),
            Self.window(owner: NSNumber(value: Self.finderPID), number: 3, layer: NSNumber(value: 0)),
        ]
        #expect(Self.keyboardOwner(logicInFront) == "logic")
    }

    /// The screen of 2026-10-02 (lpm-evidence/942/keyboard-owner/2026-10-02-unc-alert-over-logic.json),
    /// front to back, keeping the first row of each run of one owner at one layer: the window
    /// server, Control Center, the menu bar, Notification Center, two UserNotificationCenter
    /// permission prompts at layer 8, Logic's marker list at 3, and Logic's Go To Position dialog,
    /// demoted to 0 behind the prompts. `lsappinfo front` named UserNotificationCenter, and key 53
    /// at the HID tap closed nothing of Logic's.
    static let alertPID: pid_t = 81314
    static var alertOverLogic: [[String: Any]] {
        [
            window(owner: NSNumber(value: 391), number: 8, layer: NSNumber(value: 2_147_483_630)),
            window(owner: NSNumber(value: 661), number: 1574, layer: NSNumber(value: 25)),
            window(owner: NSNumber(value: 391), number: 63, layer: NSNumber(value: 24)),
            window(owner: NSNumber(value: 733), number: 27, layer: NSNumber(value: 21)),
            window(owner: NSNumber(value: alertPID), number: 1693, layer: NSNumber(value: 8)),
            window(owner: NSNumber(value: alertPID), number: 1692, layer: NSNumber(value: 8)),
            window(owner: NSNumber(value: logicPID), number: 1684, layer: NSNumber(value: 3)),
            window(owner: NSNumber(value: logicPID), number: 1688, layer: NSNumber(value: 0)),
        ]
    }

    @Test func anAlertAtTheModalPanelLevelInFrontOfLogicHoldsTheKeyboard() {
        #expect(Self.keyboardOwner(Self.alertOverLogic) == "other")
        #expect(LogicOnScreenWindows.keyboardWindow(Self.alertOverLogic)
            .flatMap { ProcessUtils.pidValue(from: $0[kCGWindowOwnerPID as String]) } == Self.alertPID)
    }

    /// Logic's own dialog at the modal-panel level is Logic's keyboard, as it is while Logic is
    /// active; and another app's floating panel in front of Logic still is not the keyboard's owner.
    @Test func logicsOwnModalPanelIsLogicsAndAnotherAppsFloatingPanelIsPassedOver() {
        let dialogOverLogic: [[String: Any]] = [
            Self.window(owner: NSNumber(value: Self.logicPID), number: 1, layer: NSNumber(value: LogicOnScreenWindows.modalPanelLevel)),
            Self.window(owner: NSNumber(value: Self.finderPID), number: 2, layer: NSNumber(value: 0)),
        ]
        #expect(Self.keyboardOwner(dialogOverLogic) == "logic")
        let floatingOverLogic: [[String: Any]] = [
            Self.window(owner: NSNumber(value: Self.otherPID), number: 1, layer: NSNumber(value: 3)),
            Self.window(owner: NSNumber(value: Self.logicPID), number: 2, layer: NSNumber(value: 0)),
        ]
        #expect(Self.keyboardOwner(floatingOverLogic) == "logic")
    }

    /// The level the live reading found the prompts and Logic's active dialog at.
    @Test func theModalPanelLevelIsTheOneTheLiveReadingSaw() {
        #expect(LogicOnScreenWindows.modalPanelLevel == 8)
    }

    @Test func theKeyboardOwnerIsUnreadWithoutANormalLayerWindow() {
        let onlyMenus: [[String: Any]] = [
            Self.window(owner: NSNumber(value: Self.logicPID), number: 1, layer: NSNumber(value: LogicOnScreenWindows.popupMenuLevel)),
            Self.window(owner: NSNumber(value: Self.logicPID), number: 2, layer: nil),
        ]
        #expect(Self.keyboardOwner(onlyMenus) == "unread")
        #expect(Self.keyboardOwner([]) == "unread")
    }

    /// A normal-layer window whose owner cannot be read is not "not Logic"; it is a reading that
    /// was not taken, and the decision refuses on nil the same as on false.
    @Test func theKeyboardOwnerIsUnreadWhenTheFrontWindowsOwnerIsNotAPid() {
        let unreadableOwner: [[String: Any]] = [
            Self.window(owner: "Logic Pro", number: 1, layer: NSNumber(value: 0)),
            Self.window(owner: NSNumber(value: Self.logicPID), number: 2, layer: NSNumber(value: 0)),
        ]
        #expect(Self.keyboardOwner(unreadableOwner) == "unread")
    }

    /// The baseline holds the numbers the parent read before the leaf click. What appeared since
    /// is Logic's, not in the baseline, and not the menu, which `popupMenuCount` answers for.
    @Test func appearedSinceReportsNewLogicWindowsBelowTheMenuLayer() {
        let baseline: Set<Int> = [905]
        let appeared = LogicOnScreenWindows.appearedSince(
            baseline: baseline, in: Self.mixedScreen, logicPID: Self.logicPID)
        #expect(appeared.map(\.number) == [902])

        let dialog = Self.window(
            owner: NSNumber(value: Self.logicPID), number: 906, layer: NSNumber(value: 8), name: "Go To Position")
        let withDialog = LogicOnScreenWindows.appearedSince(
            baseline: [902, 905], in: Self.mixedScreen + [dialog], logicPID: Self.logicPID)
        #expect(withDialog == [LogicOnScreenWindows.Entry(number: 906, layer: 8, bounds: nil, name: "Go To Position")])

        let nothingNew = LogicOnScreenWindows.appearedSince(
            baseline: [902, 905], in: Self.mixedScreen, logicPID: Self.logicPID)
        #expect(nothingNew.isEmpty)
    }
}
