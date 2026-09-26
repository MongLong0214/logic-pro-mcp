import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import LogicProMCP

/// #942. The post-leaf settlement, driven from scripted window lists through the two Runtime
/// seams: what one list reads as, what the loop sends and when, what the receipt carries, and
/// which of the route's results run it at all.
///
/// The fixture is a window server that answers a scripted sequence of lists, one per read, and
/// counts the reads, the Escapes and the sleeps. Nothing here reads a wall clock: a poll is a
/// counted `sleepMicros` call followed by a counted read, and the evidence for "the loop re-read
/// before it acted" is the read count at the moment each Escape went out.
///
/// NO `#expect(<Bool> == <Bool>)` HERE (#393, `Scripts/ci-forbid-dead-expect.sh`). Readings are
/// compared through the receipt's own String tokens, and the one Boolean a caller branches on,
/// `settled`, is required out of the receipt and then asserted directly.
///
/// Every test names the mutation it was seen red under; the list is in the pull request.
final class Issue942ScriptedWindowServer: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[[String: Any]]?]
    private var cursor = 0
    private var reads = 0
    private var escapes = 0
    private var readsAtEscape: [Int] = []
    private var sleeps: [UInt32] = []

    /// The lists served in order, one per read; the last one repeats once the script runs out.
    init(_ lists: [[[String: Any]]?]) {
        precondition(!lists.isEmpty, "a scripted window server needs at least one list")
        self.lists = lists
    }

    func windowList() -> [[String: Any]]? {
        lock.withLock {
            let list = lists[min(cursor, lists.count - 1)]
            cursor += 1
            reads += 1
            return list
        }
    }

    func postEscape() {
        lock.withLock {
            escapes += 1
            readsAtEscape.append(reads)
        }
    }

    func sleep(_ micros: UInt32) {
        lock.withLock { sleeps.append(micros) }
    }

    /// From the next read on, serve these instead. The read count keeps counting: this is what
    /// the screen changed to, not a new server.
    func replaceSequence(_ lists: [[[String: Any]]?]) {
        precondition(!lists.isEmpty, "a scripted window server needs at least one list")
        lock.withLock {
            self.lists = lists
            cursor = 0
        }
    }

    var escapeCount: Int { lock.withLock { escapes } }
    var readCount: Int { lock.withLock { reads } }
    var readsBeforeEachEscape: [Int] { lock.withLock { readsAtEscape } }
    var sleepCount: Int { lock.withLock { sleeps.count } }
    var sleptMicros: Set<UInt32> { lock.withLock { Set(sleeps) } }
}

@Suite(.serialized) struct Issue942PostLeafSettlementTests {
    typealias Fixture = Issue942PostLeafDecisionTests
    typealias Harness = Issue942PostLeafMenuReconciliationTests
    typealias Policy = AccessibilityChannel.EscapeOverDialogPolicy
    typealias Settlement = AccessibilityChannel.PostLeafSettlement

    /// The pid `FakeAXRuntimeBuilder.makeLogicRuntime` gives a runtime unless told otherwise, and
    /// therefore the one the route-level harness's runtime carries: the fixture rows must be
    /// owned by the pid the reading is taken for, or every Logic row reads as another process's.
    static let logicPID: pid_t = 4242
    static let finderPID = Fixture.finderPID
    /// The Logic-owned numbers on screen before the leaf click: the main window only.
    static let baseline: Set<Int> = [905]
    static let ourDialogTitle = "Go To Position"

    // MARK: - Screens, front to back as the window server orders them

    static func logicMain() -> [String: Any] {
        Fixture.window(owner: NSNumber(value: logicPID), number: 905, layer: NSNumber(value: 0), name: "Untitled - Tracks")
    }

    static func finderMain() -> [String: Any] {
        Fixture.window(owner: NSNumber(value: finderPID), number: 904, layer: NSNumber(value: 0), name: "Finder")
    }

    static func popupMenu() -> [String: Any] {
        Fixture.window(
            owner: NSNumber(value: logicPID), number: 900,
            layer: NSNumber(value: LogicOnScreenWindows.popupMenuLevel))
    }

    /// A window the leaf click left behind: Logic's, below the menu layer, not in the baseline.
    static func appearedWindow(number: Int = 906, name: String?) -> [String: Any] {
        Fixture.window(owner: NSNumber(value: logicPID), number: number, layer: NSNumber(value: 8), name: name)
    }

    /// The shapes a test names. An enum rather than the lists themselves so a table of cases is
    /// `Sendable`; `windows` materialises the list the enum stands for.
    enum Screen: Sendable, CustomTestStringConvertible {
        /// Logic's main window in front of Finder's: menu closed, nothing appeared, keyboard Logic.
        case logicFront
        /// Logic's popup menu over `logicFront`.
        case menuOpen
        /// The menu over one appeared window with this name (nil: the name did not come back).
        case menuOverAppeared(name: String?)
        /// One appeared window with this name, no menu.
        case appearedOnly(name: String?)
        /// Two appeared windows, both carrying our dialog's title.
        case twoAppeared
        /// The menu up, but Finder's window in front of Logic's: another process owns the keyboard.
        case menuOpenKeyboardOther
        /// The menu up and no normal-layer window at all: nobody was read to own the keyboard.
        case menuOpenKeyboardUnread
        /// The window server gave no list.
        case unreadable

        var windows: [[String: Any]]? {
            switch self {
            case .logicFront:
                return [logicMain(), finderMain()]
            case .menuOpen:
                return [popupMenu(), logicMain(), finderMain()]
            case let .menuOverAppeared(name):
                return [popupMenu(), appearedWindow(name: name), logicMain(), finderMain()]
            case let .appearedOnly(name):
                return [appearedWindow(name: name), logicMain(), finderMain()]
            case .twoAppeared:
                return [appearedWindow(number: 906, name: ourDialogTitle),
                        appearedWindow(number: 907, name: ourDialogTitle), logicMain(), finderMain()]
            case .menuOpenKeyboardOther:
                return [popupMenu(), finderMain(), logicMain()]
            case .menuOpenKeyboardUnread:
                return [popupMenu()]
            case .unreadable:
                return nil
            }
        }

        var testDescription: String { "\(self)" }
    }

    // MARK: - Runtimes over the scripted server

    /// A runtime whose only live-looking seams are the two window-server ones, both bound to
    /// the scripted server. `pid` nil is a Logic that is not running.
    static func runtime(_ server: Issue942ScriptedWindowServer, pid: pid_t? = logicPID) -> AXLogicProElements.Runtime {
        let base = FakeAXRuntimeBuilder().makeLogicRuntime(pid: pid)
        return AXLogicProElements.Runtime(
            logicProPID: base.logicProPID,
            ax: base.ax,
            executeAppleScript: base.executeAppleScript,
            executeAppleScriptWithTimeout: base.executeAppleScriptWithTimeout,
            onScreenWindowList: { server.windowList() },
            postPopupMenuEscape: { server.postEscape() }
        )
    }

    /// One settlement pass over the scripted screens, with the receipt object it produces.
    static func settle(
        _ screens: [Screen], policy: Policy = .current, baseline: Set<Int>? = baseline, pid: pid_t? = logicPID
    ) throws -> (settlement: Settlement, server: Issue942ScriptedWindowServer, receipt: [String: Any]) {
        let server = Issue942ScriptedWindowServer(screens.map(\.windows))
        let settlement = AccessibilityChannel.settlePostLeafScreen(
            baseline: baseline, runtime: runtime(server, pid: pid), policy: policy,
            sleepMicros: { server.sleep($0) })
        let receipt = try #require(settlement.receiptFields["post_leaf_settlement"] as? [String: Any])
        return (settlement, server, receipt)
    }

    static func token(_ object: [String: Any], _ key: String) throws -> String {
        try #require(object[key] as? String, "\(key)")
    }

    static func reading(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        try #require(object[key] as? [String: Any], "\(key)")
    }

    /// `menu|dialog|keyboard_owner` off one reading object, so a case's expectation is one token.
    static func summary(_ reading: [String: Any]) throws -> String {
        "\(try token(reading, "menu"))|\(try token(reading, "dialog"))|\(try token(reading, "keyboard_owner"))"
    }

    static func settled(_ receipt: [String: Any]) throws -> Bool {
        try #require(receipt["settled"] as? Bool)
    }

    static func escapeTargets(_ receipt: [String: Any]) throws -> [String] {
        try #require(receipt["escape_targets"] as? [String])
    }

    // MARK: - T_read: one list, one reading

    struct ReadCase: Sendable, CustomTestStringConvertible {
        let label: String
        let screen: Screen
        let baseline: Set<Int>?
        let pid: pid_t?
        /// `menu|dialog|keyboard_owner`.
        let expected: String
        /// The numbers of the appeared windows, nil when the dialog reading was not taken.
        let appeared: [Int]?

        init(_ label: String, _ screen: Screen, baseline: Set<Int>? = Issue942PostLeafSettlementTests.baseline,
             pid: pid_t? = Issue942PostLeafSettlementTests.logicPID, expected: String, appeared: [Int]?) {
            self.label = label
            self.screen = screen
            self.baseline = baseline
            self.pid = pid
            self.expected = expected
            self.appeared = appeared
        }

        var testDescription: String { "\(label) -> \(expected)" }
    }

    static let readCases: [ReadCase] = [
        .init("nothing left behind", .logicFront, expected: "closed|absent|logic", appeared: []),
        .init("menu open, nothing appeared", .menuOpen, expected: "open|absent|logic", appeared: []),
        .init("menu over our dialog", .menuOverAppeared(name: ourDialogTitle),
              expected: "open|identified_ours|logic", appeared: [906]),
        .init("our dialog, menu closed", .appearedOnly(name: ourDialogTitle),
              expected: "closed|identified_ours|logic", appeared: [906]),
        .init("our dialog under its Korean title", .appearedOnly(name: "위치로 이동"),
              expected: "closed|identified_ours|logic", appeared: [906]),
        // A title that only contains the dialog's is not the dialog's: `.exactStrict`, not `.contains`.
        .init("a window whose name merely contains the title", .appearedOnly(name: "Untitled — 위치로 이동"),
              expected: "closed|unidentified|logic", appeared: [906]),
        .init("a window whose name did not come back", .appearedOnly(name: nil),
              expected: "closed|unidentified|logic", appeared: [906]),
        .init("two windows both carrying the title", .twoAppeared,
              expected: "closed|unidentified|logic", appeared: [906, 907]),
        .init("menu over a window that cannot be named", .menuOverAppeared(name: nil),
              expected: "open|unidentified|logic", appeared: [906]),
        // "What appeared since" has no answer without a "since".
        .init("no baseline", .logicFront, baseline: nil, expected: "closed|unreadable|logic", appeared: nil),
        .init("no baseline, menu open", .menuOpen, baseline: nil, expected: "open|unreadable|logic", appeared: nil),
        .init("no list", .unreadable, expected: "unreadable|unreadable|unread", appeared: nil),
        .init("no Logic pid", .menuOpen, pid: nil, expected: "unreadable|unreadable|unread", appeared: nil),
        .init("Finder in front", .menuOpenKeyboardOther, expected: "open|absent|other", appeared: []),
        .init("no normal-layer window", .menuOpenKeyboardUnread, expected: "open|absent|unread", appeared: []),
    ]

    /// Mutations seen red: `.exactStrict` -> `.contains` (the "merely contains" case);
    /// `appeared.count == 1` -> `>= 1` (the two-windows case); nil baseline read as `.absent`
    /// (both "no baseline" cases).
    @Test(arguments: Self.readCases)
    func theReadingIsBuiltFromOneListAgainstTheBaseline(_ c: ReadCase) throws {
        let read = AccessibilityChannel.readPostLeafScreen(
            baseline: c.baseline, logicPID: c.pid, windows: c.screen.windows)
        let fields = Settlement.readingFields(read.reading, appeared: read.appeared)
        #expect(try Self.summary(fields) == c.expected)
        #expect(read.appeared?.map(\.number) == c.appeared)
        if let appeared = c.appeared {
            let listed = try #require(fields["appeared_windows"] as? [[String: Any]])
            #expect(listed.compactMap { $0["number"] as? Int } == appeared)
        } else {
            #expect(try Self.token(fields, "appeared_windows") == "unreadable")
        }
    }

    /// Every title Logic ships for the dialog identifies it, and only exactly (#726: the parent
    /// presses nothing it cannot name). Ten locales; zh_CN and zh_TW share one string.
    @Test(arguments: AXLocalePolicy.goToPositionDialogTitle.labels)
    func everyShippedDialogTitleIdentifiesTheDialog(_ title: String) throws {
        let read = AccessibilityChannel.readPostLeafScreen(
            baseline: Self.baseline, logicPID: Self.logicPID, windows: Screen.appearedOnly(name: title).windows)
        let fields = Settlement.readingFields(read.reading, appeared: read.appeared)
        #expect(try Self.summary(fields) == "closed|identified_ours|logic", "\(title)")
        let prefixed = AccessibilityChannel.readPostLeafScreen(
            baseline: Self.baseline, logicPID: Self.logicPID,
            windows: Screen.appearedOnly(name: "Untitled - \(title)").windows)
        #expect(try Self.token(Settlement.readingFields(prefixed.reading, appeared: prefixed.appeared), "dialog")
            == "unidentified", "\(title)")
    }

    // MARK: - T_loop: an Escape is preceded by a fresh read and followed by a poll

    /// Mutation seen red: the settle poll never breaks (the `stillCounted` check removed), which
    /// turns one poll into twenty.
    @Test func anEscapeIsPrecededByAFreshReadAndStopsWhenTheMenuIsNoLongerCounted() throws {
        let run = try Self.settle([.menuOpen, .menuOpen, .logicFront])
        #expect(run.server.escapeCount == 1)
        // The initial read is reported, never acted on: the Escape went out after a second read.
        #expect(run.server.readsBeforeEachEscape == [2])
        // One poll read the menu gone; the next attempt's own read then decided nothing.
        #expect(run.server.sleepCount == 1)
        #expect(run.server.sleptMicros == [AccessibilityChannel.postLeafEscapeSettlePollMicros])
        #expect(run.server.readCount == 4)
        #expect(try Self.token(run.receipt, "action") == "menu_escape_loop")
        #expect(try Self.escapeTargets(run.receipt) == ["menu"])
        #expect(try Self.summary(Self.reading(run.receipt, "read")) == "open|absent|logic")
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "closed|absent|logic")
        #expect(try Self.token(run.receipt, "final_action") == "none")
        #expect(run.receipt["refusal_reason"] == nil)
        #expect(run.receipt["final_refusal_reason"] == nil)
        let settled = try Self.settled(run.receipt)
        #expect(settled)
        #expect(try Self.token(run.receipt, "policy") == Policy.current.rawValue)
    }

    // MARK: - T_after: a settlement that sent nothing still carries the reading that settled it

    /// Round 1 of #1019's review: `after` was encoded only when an Escape went out, so these two
    /// receipts said `settled: true` over a reading they did not carry. Mutation seen red: the
    /// `after` field gated on `!escapeTargets.isEmpty` again.
    @Test(arguments: [
        (Screen.menuOpen, "menu_escape_loop", "open|absent|logic"),
        (Screen.unreadable, "refuse_to_act", "unreadable|unreadable|unread"),
    ])
    func aSettlementWithNoEscapeCarriesItsSettlingReading(
        first: Screen, action: String, read: String
    ) throws {
        let run = try Self.settle([first, .logicFront])
        #expect(run.server.escapeCount == 0)
        #expect(run.server.readCount == 2)
        #expect(try Self.summary(Self.reading(run.receipt, "read")) == read)
        #expect(try Self.token(run.receipt, "action") == action)
        #expect(try #require(run.receipt["escapes_sent"] as? Int) == 0)
        #expect(try Self.token(run.receipt, "final_action") == "none")
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "closed|absent|logic")
        let settled = try Self.settled(run.receipt)
        #expect(settled)
    }

    // MARK: - T_unread: an unreadable re-read stops the loop with nothing sent

    /// Mutation seen red: the loop decides over the initial reading instead of its own re-read,
    /// which sends the Escape the second read should have withheld.
    @Test func anUnreadableReReadStopsWithoutSending() throws {
        let run = try Self.settle([.menuOpen, .unreadable])
        #expect(run.server.escapeCount == 0)
        #expect(run.server.sleepCount == 0)
        #expect(run.server.readCount == 2)
        #expect(try Self.token(run.receipt, "action") == "menu_escape_loop")
        #expect(try Self.escapeTargets(run.receipt).isEmpty)
        #expect(try #require(run.receipt["escapes_sent"] as? Int) == 0)
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "unreadable|unreadable|unread",
                "the re-read that refused is the reading the receipt carries")
        #expect(try Self.token(run.receipt, "final_action") == "refuse_to_act")
        #expect(try Self.token(run.receipt, "final_refusal_reason") == "window_list_unreadable")
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    /// The same, at the top: a first reading that was not taken decides a refusal and the loop
    /// sends nothing. An unreadable pass is never reported settled.
    @Test(arguments: [Screen.unreadable, .menuOpenKeyboardUnread])
    func aPassThatCouldNotReadIsNeverSettled(_ screen: Screen) throws {
        let run = try Self.settle([screen])
        #expect(run.server.escapeCount == 0)
        #expect(try Self.token(run.receipt, "action") == "refuse_to_act")
        #expect(try Self.token(run.receipt, "final_action") == "refuse_to_act")
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    // MARK: - T_keyboard: no keystroke to a keyboard Logic was not read to own

    struct KeyboardCase: Sendable, CustomTestStringConvertible {
        let screen: Screen
        let owner: String
        var testDescription: String { "\(screen) -> keyboard_owner \(owner)" }
    }

    static let keyboardCases: [KeyboardCase] = [
        .init(screen: .menuOpenKeyboardOther, owner: "other"),
        .init(screen: .menuOpenKeyboardUnread, owner: "unread"),
    ]

    /// Mutation seen red: `logicHoldsKeyboard` forced true in `decidePostLeafAction`.
    @Test(arguments: Self.keyboardCases)
    func noEscapeIsSentWhileAnotherProcessOrNobodyOwnsTheKeyboard(_ c: KeyboardCase) throws {
        let run = try Self.settle([c.screen])
        #expect(run.server.escapeCount == 0)
        #expect(run.server.readCount == 2, "the loop re-read once, decided the refusal, and stopped")
        #expect(try Self.token(Self.reading(run.receipt, "read"), "keyboard_owner") == c.owner)
        #expect(try Self.token(run.receipt, "action") == "refuse_to_act")
        #expect(try Self.token(run.receipt, "refusal_reason") == "logic_not_keyboard_owner")
        #expect(try Self.token(run.receipt, "final_refusal_reason") == "logic_not_keyboard_owner")
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    /// Mutation seen red: the same forced `logicHoldsKeyboard`, which sends a second Escape at
    /// Finder.
    @Test func theLoopStopsWhenLogicLosesTheKeyboard() throws {
        let run = try Self.settle([.menuOpen, .menuOpen, .menuOpen, .menuOpenKeyboardOther])
        #expect(run.server.escapeCount == 1)
        #expect(run.server.readsBeforeEachEscape == [2])
        // The menu stayed counted through the whole poll, then the next attempt read Finder in
        // front and refused rather than sending Escape to it.
        #expect(run.server.sleepCount == AccessibilityChannel.postLeafEscapeSettlePolls)
        #expect(run.server.readCount == 2 + AccessibilityChannel.postLeafEscapeSettlePolls + 1)
        #expect(try Self.escapeTargets(run.receipt) == ["menu"])
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "open|absent|other")
        #expect(try Self.token(run.receipt, "final_action") == "refuse_to_act")
        #expect(try Self.token(run.receipt, "final_refusal_reason") == "logic_not_keyboard_owner")
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    // MARK: - T_bound: at most three Escapes, and an open menu is never settled

    /// Mutations seen red: `postLeafEscapeAttempts` 3 -> 4; `settled` derived from
    /// `escapeTargets` instead of the final decision.
    @Test func theLoopIsBoundedAndAnOpenMenuIsNeverSettled() throws {
        let run = try Self.settle([.menuOpen])
        let attempts = AccessibilityChannel.postLeafEscapeAttempts
        let polls = AccessibilityChannel.postLeafEscapeSettlePolls
        #expect(attempts == 3)
        #expect(polls == 20)
        #expect(run.server.escapeCount == 3)
        #expect(try Self.escapeTargets(run.receipt) == ["menu", "menu", "menu"])
        // Every Escape had its own fresh read: 1 initial, then per attempt 1 decision read and
        // `polls` poll reads.
        #expect(run.server.readsBeforeEachEscape == [2, 2 + polls + 1, 2 + 2 * (polls + 1)])
        #expect(run.server.sleepCount == attempts * polls)
        #expect(run.server.readCount == 1 + attempts * (polls + 1))
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "open|absent|logic")
        #expect(try Self.token(run.receipt, "final_action") == "menu_escape_loop")
        #expect(run.receipt["final_refusal_reason"] == nil)
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    // MARK: - T_order: the measured ordering, menu first and then the dialog

    /// Mutation seen red: `.dialogCancel` dropped from the loop's actuating set, which leaves the
    /// dialog up after the menu closes.
    @Test func theMeasuredOrderingClosesTheMenuThenCancelsTheDialog() throws {
        let run = try Self.settle(
            [.menuOverAppeared(name: Self.ourDialogTitle), .menuOverAppeared(name: Self.ourDialogTitle),
             .appearedOnly(name: Self.ourDialogTitle), .appearedOnly(name: Self.ourDialogTitle), .logicFront],
            policy: .menuEscapeMeasuredToLeaveDialog)
        #expect(run.server.escapeCount == 2)
        #expect(try Self.escapeTargets(run.receipt) == ["menu", "dialog"])
        // Read 2 decided the menu Escape; read 3 polled the menu gone; read 4 decided the dialog
        // Escape; read 5 polled the dialog gone; read 6 decided nothing.
        #expect(run.server.readsBeforeEachEscape == [2, 4])
        #expect(run.server.sleepCount == 2)
        #expect(run.server.readCount == 6)
        #expect(try Self.summary(Self.reading(run.receipt, "read")) == "open|identified_ours|logic")
        #expect(try Self.token(run.receipt, "action") == "menu_escape_loop")
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "closed|absent|logic")
        #expect(try Self.token(run.receipt, "final_action") == "none")
        let settled = try Self.settled(run.receipt)
        #expect(settled)
    }

    /// Mutation seen red: the policy test in `decidePostLeafAction` replaced by `true`.
    @Test func theWithheldPolicyRefusesOverOurDialogWithoutAnEscape() throws {
        let run = try Self.settle(
            [.menuOverAppeared(name: Self.ourDialogTitle)], policy: .withheldWhileDialogPresent)
        #expect(run.server.escapeCount == 0)
        #expect(run.server.readCount == 2)
        #expect(try Self.token(run.receipt, "policy") == "withheld_while_dialog_present")
        #expect(try Self.token(run.receipt, "action") == "refuse_to_act")
        #expect(try Self.token(run.receipt, "refusal_reason") == "dialog_present_escape_withheld")
        #expect(try Self.token(run.receipt, "final_refusal_reason") == "dialog_present_escape_withheld")
        #expect(try Self.summary(Self.reading(run.receipt, "after")) == "open|identified_ours|logic")
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    /// The dialog alone, with the keyboard: one Escape at the dialog, then nothing on screen.
    @Test func ourDialogAloneIsCancelledWithOneEscape() throws {
        let run = try Self.settle(
            [.appearedOnly(name: Self.ourDialogTitle), .appearedOnly(name: Self.ourDialogTitle), .logicFront])
        #expect(run.server.escapeCount == 1)
        #expect(run.server.readsBeforeEachEscape == [2])
        #expect(try Self.token(run.receipt, "action") == "dialog_cancel")
        #expect(try Self.escapeTargets(run.receipt) == ["dialog"])
        #expect(try Self.token(run.receipt, "final_action") == "none")
        let settled = try Self.settled(run.receipt)
        #expect(settled)
    }

    // MARK: - A window the parent cannot name is never pressed

    struct UnidentifiedCase: Sendable, CustomTestStringConvertible {
        let label: String
        let screen: Screen
        var testDescription: String { label }
    }

    static let unidentifiedCases: [UnidentifiedCase] = [
        .init(label: "menu over a window whose name did not come back", screen: .menuOverAppeared(name: nil)),
        .init(label: "menu over a window with another name", screen: .menuOverAppeared(name: "Untitled — 위치로 이동")),
        .init(label: "a window whose name did not come back", screen: .appearedOnly(name: nil)),
        .init(label: "a window with another name", screen: .appearedOnly(name: "Bounce")),
        .init(label: "two windows both carrying the title", screen: .twoAppeared),
    ]

    /// Mutation seen red: the menu-open `.unidentified` arm of `decidePostLeafAction` returning
    /// the menu loop.
    @Test(arguments: Self.unidentifiedCases)
    func noEscapeIsSentAtAWindowTheParentCannotName(_ c: UnidentifiedCase) throws {
        let run = try Self.settle([c.screen])
        #expect(run.server.escapeCount == 0)
        #expect(run.server.readCount == 2)
        #expect(try Self.token(Self.reading(run.receipt, "read"), "dialog") == "unidentified")
        #expect(try Self.token(run.receipt, "action") == "refuse_to_act")
        #expect(try Self.token(run.receipt, "refusal_reason") == "unidentified_dialog_present")
        #expect(try Self.token(run.receipt, "final_refusal_reason") == "unidentified_dialog_present")
        let settled = try Self.settled(run.receipt)
        #expect(!settled)
    }

    // MARK: - T_trigger: the fourteen results, and nothing else

    struct TriggerCase: Sendable, CustomTestStringConvertible {
        let label: String
        let site: String
        let result: String?
        let executionFailureStage: String?
        let reconcilerAnswer: String
        let expectsSettlement: Bool

        init(_ label: String, site: String = "dialog_not_ready", result: String?, executionFailureStage: String? = nil,
             reconcilerAnswer: String = "CLOSED", expectsSettlement: Bool) {
            self.label = label
            self.site = site
            self.result = result
            self.executionFailureStage = executionFailureStage
            self.reconcilerAnswer = reconcilerAnswer
            self.expectsSettlement = expectsSettlement
        }

        var testDescription: String { "\(label) -> settlement \(expectsSettlement ? "present" : "absent")" }

        /// The two appearance results are the only literal results with no `PREFIX: ` part.
        var isAppearanceResult: Bool {
            guard let result else { return false }
            return !result.contains(":")
        }
    }

    static let sites = AccessibilityChannel.postLeafCleanupSites

    /// The fourteen: twelve dialog refusals and the two appearance results.
    static let settledCases: [TriggerCase] =
        sites.map { site in
            TriggerCase("dialog refusal at \(site.identifier)", site: site.identifier,
                        result: Harness.dialogRefusal(site), expectsSettlement: true)
        } + [
            TriggerCase("DIALOG_UNIDENTIFIED_NEW_WINDOW", result: "DIALOG_UNIDENTIFIED_NEW_WINDOW", expectsSettlement: true),
            TriggerCase("DIALOG_APPEARANCE_UNREADABLE", result: "DIALOG_APPEARANCE_UNREADABLE", expectsSettlement: true),
        ]

    /// Everything else the route can end on after a normal or failed script.
    static let unsettledCases: [TriggerCase] =
        sites.map { site in
            TriggerCase("menu refusal at \(site.identifier)", site: site.identifier,
                        result: Harness.menuRefusal(site), expectsSettlement: false)
        } + sites.map { site in
            TriggerCase("own result at \(site.identifier)", site: site.identifier,
                        result: "\(site.resultPrefix): fixture", reconcilerAnswer: "OPEN", expectsSettlement: false)
        } + [
            TriggerCase("OK", result: "OK", expectsSettlement: false),
        ] + Issue999GotoRefusalReceiptTests.preLeafResults.map { result in
            TriggerCase("pre-leaf \(result.prefix { $0 != ":" })",
                        result: "\(result) menu_actuation_attempted=true", expectsSettlement: false)
        } + (["LEAF_ARMED", "SELECT_ALL_ARMED", "NOT_ISSUED", "UNKNOWN"] as [String]).map { stage in
            TriggerCase("dead child at \(stage)", result: nil, executionFailureStage: stage, expectsSettlement: false)
        }

    static let triggerCases = settledCases + unsettledCases

    /// The screens a route run reads: the baseline first, then the settlement's own reads. The
    /// menu is up after the script, so a settlement that runs sends one Escape and settles.
    static let routeScreens: [Screen] = [.logicFront, .menuOpen, .menuOpen, .logicFront]

    static func runRoute(
        _ c: TriggerCase, screens: [Screen]? = routeScreens
    ) async throws -> (envelope: [String: Any], server: Issue942ScriptedWindowServer) {
        let server = Issue942ScriptedWindowServer((screens ?? [.unreadable]).map(\.windows))
        let run = try await Harness.runMenuRefusal(
            try Harness.site(c.site), reconcilerAnswer: c.reconcilerAnswer, result: c.result,
            executionFailureStage: c.executionFailureStage,
            onScreenWindowList: { server.windowList() },
            postPopupMenuEscape: { server.postEscape() })
        return (run.envelope, server)
    }

    /// Mutations seen red: `requiresPostLeafScreenSettlement` true for `.menuNotObservedClosed`
    /// (the twelve menu refusals gain the object); false for `.dialogAppearanceUnreadable` (that
    /// result loses it).
    @Test(arguments: Self.triggerCases)
    func eachOfTheFourteenResultsCarriesTheSettlementAndNothingElseDoes(_ c: TriggerCase) async throws {
        let run = try await Self.runRoute(c)
        #expect(Self.settledCases.count == 14)
        if c.expectsSettlement {
            let receipt = try #require(run.envelope["post_leaf_settlement"] as? [String: Any], "\(c.label)")
            #expect(try Self.summary(Self.reading(receipt, "read")) == "open|absent|logic")
            #expect(try Self.token(receipt, "action") == "menu_escape_loop")
            #expect(try Self.escapeTargets(receipt) == ["menu"])
            #expect(try Self.summary(Self.reading(receipt, "after")) == "closed|absent|logic")
            #expect(run.server.escapeCount == 1)
            // The baseline read, then the settlement's four.
            #expect(run.server.readCount == 5)
            let settled = try Self.settled(receipt)
            #expect(settled)
        } else {
            #expect(run.envelope["post_leaf_settlement"] == nil, "\(c.label)")
            #expect(run.server.escapeCount == 0, "\(c.label)")
            #expect(run.server.readCount == 1, "\(c.label): the baseline is read; nothing reads the screen after")
        }
    }

    /// The object is added beside the refusal, not into it. The same result run against a screen
    /// that settles and against no list at all produces the same receipt outside the object, and
    /// the fields #999 pinned keep the values they had before the object existed.
    @Test(arguments: Self.settledCases)
    func theSettlementChangesNothingButItsOwnObject(_ c: TriggerCase) async throws {
        let settled = try await Self.runRoute(c)
        let unread = try await Self.runRoute(c, screens: nil)
        var outsideSettled = settled.envelope
        var outsideUnread = unread.envelope
        outsideSettled["post_leaf_settlement"] = nil
        outsideUnread["post_leaf_settlement"] = nil
        #expect(NSDictionary(dictionary: outsideSettled).isEqual(to: outsideUnread), "\(c.label)")

        let site = try Harness.site(c.site)
        let expectedState = c.isAppearanceResult || Harness.refusesAsStateC(site) ? "C" : "B"
        #expect(try Self.token(settled.envelope, "state") == expectedState, "\(c.label)")
        #expect(try Self.token(settled.envelope, "dialog_cleanup") == "unobserved", "\(c.label)")
        #expect(try Self.token(settled.envelope, "menu_state") == "unobserved", "\(c.label)")
        let outcome = try Self.token(settled.envelope, "dialog_route_outcome")
        if c.isAppearanceResult {
            #expect(outcome == (c.result?.lowercased() ?? ""), "\(c.label)")
        } else {
            #expect(outcome.hasSuffix("_cleanup_closed_false"), "\(c.label)")
        }
        #expect(try #require(settled.envelope["fallback_unsafe"] as? Bool), "\(c.label)")
        #expect(!(try #require(settled.envelope["safe_to_retry"] as? Bool)), "\(c.label)")
        #expect(try #require(settled.envelope["menu_actuation_attempted"] as? Bool), "\(c.label)")

        // The unreadable run's own object: nothing sent, nothing settled, `after` the unread re-read.
        let receipt = try #require(unread.envelope["post_leaf_settlement"] as? [String: Any], "\(c.label)")
        #expect(unread.server.escapeCount == 0)
        #expect(try Self.summary(Self.reading(receipt, "read")) == "unreadable|unreadable|unread")
        #expect(try Self.token(receipt, "action") == "refuse_to_act")
        #expect(try Self.token(receipt, "refusal_reason") == "window_list_unreadable")
        #expect(try Self.summary(Self.reading(receipt, "after")) == "unreadable|unreadable|unread")
        let unreadSettled = try Self.settled(receipt)
        #expect(!unreadSettled)
    }

    // MARK: - T_baseline: the baseline is read before the script runs

    /// A runtime with the control-bar tree the route resolves before it reaches the dialog, its
    /// slider writes refused, and the two window seams on the scripted server. The shape is
    /// `issue529SliderRuntime`'s; it is repeated here because that one is private to its file and
    /// this test needs its own script seam.
    static func routeRuntime(_ server: Issue942ScriptedWindowServer) -> AXLogicProElements.Runtime {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9420)
        let window = builder.element(9421)
        let controlBar = builder.element(9422)
        let barSlider = builder.element(9423)
        let playheadPosition = builder.element(9425)

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [controlBar])
        builder.setAttribute(controlBar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(controlBar, kAXDescriptionAttribute as String, "Control Bar")
        builder.setChildren(controlBar, [playheadPosition])
        builder.setAttribute(playheadPosition, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(playheadPosition, kAXDescriptionAttribute as String, "Playhead Position")
        builder.setChildren(playheadPosition, [barSlider])
        builder.setAttribute(barSlider, kAXRoleAttribute as String, kAXSliderRole as String)
        builder.setAttribute(barSlider, kAXDescriptionAttribute as String, "Bar")
        builder.setAttribute(barSlider, kAXValueAttribute as String, NSNumber(value: 1))

        let base = builder.makeLogicRuntime(
            pid: logicPID,
            appElement: app,
            setAttributeHandler: { element, attribute, value in
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { _, _ in true },
            executeAppleScript: { _ in .success(#"{"result":"MENU_NOT_FOUND"}"#) }
        )
        return AXLogicProElements.Runtime(
            logicProPID: base.logicProPID,
            ax: base.ax,
            executeAppleScript: base.executeAppleScript,
            executeAppleScriptWithTimeout: base.executeAppleScriptWithTimeout,
            onScreenWindowList: { server.windowList() },
            postPopupMenuEscape: { server.postEscape() }
        )
    }

    static func envelope(_ result: ChannelResult) throws -> [String: Any] {
        let payload: String
        switch result {
        case let .success(text), let .error(text):
            payload = text
        }
        return try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    /// The script is what puts the dialog on screen. The server shows nothing appeared until the
    /// script runs, and our dialog afterwards; a baseline read after the script would hold the
    /// dialog's number and read it as nothing new.
    ///
    /// Mutation seen red: the baseline capture moved after `gotoPositionViaDialog`.
    @Test func theBaselineIsReadBeforeTheScriptRuns() async throws {
        let server = Issue942ScriptedWindowServer([Screen.logicFront.windows])
        let site = try Harness.site("dialog_not_ready")
        let output = try Harness.scriptOutput(Harness.dialogRefusal(site))
        let ledger = try #require(AccessibilityChannel.DialogIssuanceLedger.create())
        defer { ledger.remove() }
        let routed = await AccessibilityChannel.gotoPositionViaBarSlider(
            params: ["bar": "942"],
            runtime: Self.routeRuntime(server),
            isFrontmost: { true },
            activateLogic: { true },
            sleepMicros: { server.sleep($0) },
            executeDialogScript: { _ in
                server.replaceSequence([
                    Screen.appearedOnly(name: Self.ourDialogTitle).windows,
                    Screen.appearedOnly(name: Self.ourDialogTitle).windows,
                    Screen.logicFront.windows,
                ])
                return .success(output)
            },
            createDialogIssuanceLedger: { ledger }
        )
        let envelope = try Self.envelope(routed)
        let receipt = try #require(envelope["post_leaf_settlement"] as? [String: Any])
        #expect(server.readCount == 5, "one baseline read, then the settlement's four")
        #expect(try Self.summary(Self.reading(receipt, "read")) == "closed|identified_ours|logic")
        let appeared = try #require(Self.reading(receipt, "read")["appeared_windows"] as? [[String: Any]])
        #expect(appeared.count == 1)
        #expect(appeared.first?["number"] as? Int == 906)
        #expect(appeared.first?["layer"] as? Int == 8)
        #expect(appeared.first?["name"] as? String == Self.ourDialogTitle)
        #expect(try Self.token(receipt, "action") == "dialog_cancel")
        #expect(try Self.escapeTargets(receipt) == ["dialog"])
        #expect(server.escapeCount == 1)
        #expect(server.readsBeforeEachEscape == [3], "the baseline read, the initial read, the loop's own read")
        #expect(try Self.summary(Self.reading(receipt, "after")) == "closed|absent|logic")
        #expect(try Self.token(receipt, "final_action") == "none")
        let settled = try Self.settled(receipt)
        #expect(settled)
        #expect(try Self.token(envelope, "state") == "C")
        #expect(try Self.token(envelope, "dialog_cleanup") == "unobserved")
    }
}
