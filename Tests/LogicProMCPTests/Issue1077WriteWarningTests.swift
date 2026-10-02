@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// Logic answers the MCU Write press with a one-button warning and leaves it up; quitting Logic
// under it crashed Logic 4 of 4 times, and acknowledging it first did not (#1077). These tests
// drive MCUChannel with a surface whose Write press raises that warning in a fake AX tree, and
// read the modal set through the production reconciler (`automationModalReconciler`) over that
// tree. What each test checks is the fixture's own state after the reply: whether the warning is
// still up and how many times its button was pressed. A reply field alone cannot show that; a
// handler that never reads the modal set would still answer State A here. Nothing reads a clock:
// the poll waits go through CountingSleeper. The last two tests drive the track-delete loop, which
// shares the one-action-per-kind latch, over the same warning; that loop sleeps for real.

// MARK: - Fixtures

/// Logic's side of the fixture. `raise` puts the warning up; `settle` puts up a warning that was
/// due but not yet raised, as Logic would after the reply returns, so a handler that stops polling
/// before a late warning appears leaves it up here too.
private final class WriteWarning: @unchecked Sendable {
    /// `.oneButton` is the measured warning. `.twoButtons` is a dialog offering a choice.
    /// `.newTrackSheet` is the mandatory New Track sheet on the arrange window, Create enabled and
    /// Cancel disabled, labelled from the policy's canonical strings.
    enum Shape { case oneButton, twoButtons, newTrackSheet }
    enum Arrival { case none, onPress, onModeRead(Int) }

    private let lock = NSLock()
    private var up = false
    private var raised = 0
    private var presses = 0
    private var modeReadsSincePress = 0
    private var due = false
    private var menuOpen = false
    private var mainWindowReads = 0
    private var escapes = 0
    let shape: Shape
    let arrival: Arrival
    let closesWhenPressed: Bool
    /// Every modal read starts with the app's AXMainWindow, except the track-delete observation,
    /// which reads the arrange window it resolved once. These script the reads counted from the
    /// press (R1077-1): reads past `mainWindowReadsThatSucceed` fail with -25204, a press on the
    /// warning's button opens a stray menu when `menuOpensWhenPressed`, and the read numbered
    /// `reraisesOnMainWindowRead` finds the warning up again and the menu shut.
    let mainWindowReadsThatSucceed: Int?
    let menuOpensWhenPressed: Bool
    let reraisesOnMainWindowRead: Int?

    init(
        shape: Shape = .oneButton,
        arrival: Arrival = .onPress,
        closesWhenPressed: Bool = true,
        mainWindowReadsThatSucceed: Int? = nil,
        menuOpensWhenPressed: Bool = false,
        reraisesOnMainWindowRead: Int? = nil
    ) {
        self.shape = shape
        self.arrival = arrival
        self.closesWhenPressed = closesWhenPressed
        self.mainWindowReadsThatSucceed = mainWindowReadsThatSucceed
        self.menuOpensWhenPressed = menuOpensWhenPressed
        self.reraisesOnMainWindowRead = reraisesOnMainWindowRead
    }

    /// Called for the Write press, and for the Delete Track press in the track-delete fixture.
    func writePressed() {
        lock.lock()
        defer { lock.unlock() }
        modeReadsSincePress = 0
        mainWindowReads = 0
        switch arrival {
        case .none: break
        case .onPress: raiseLocked()
        case .onModeRead: due = true
        }
    }

    func modeRead() {
        lock.lock()
        defer { lock.unlock() }
        guard due, case .onModeRead(let ordinal) = arrival else { return }
        modeReadsSincePress += 1
        if modeReadsSincePress >= ordinal { raiseLocked() }
    }

    func buttonPressed() {
        lock.lock()
        defer { lock.unlock() }
        presses += 1
        if closesWhenPressed { up = false }
        if menuOpensWhenPressed { menuOpen = true }
    }

    /// One AXMainWindow read: applies the script and says whether the read succeeds.
    func mainWindowRead() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        mainWindowReads += 1
        if mainWindowReads == reraisesOnMainWindowRead {
            menuOpen = false
            raiseLocked()
        }
        guard let limit = mainWindowReadsThatSucceed else { return true }
        return mainWindowReads <= limit
    }

    /// The fixture never runs AppleScript; an Escape the reconciler sends is only counted.
    func escapeSent() {
        lock.lock()
        defer { lock.unlock() }
        escapes += 1
    }

    func settle() {
        lock.lock()
        defer { lock.unlock() }
        if due { raiseLocked() }
    }

    private func raiseLocked() {
        due = false
        up = true
        raised += 1
    }

    var isUp: Bool { lock.lock(); defer { lock.unlock() }; return up }
    var raisedCount: Int { lock.lock(); defer { lock.unlock() }; return raised }
    var pressCount: Int { lock.lock(); defer { lock.unlock() }; return presses }
    var isMenuOpen: Bool { lock.lock(); defer { lock.unlock() }; return menuOpen }
    var escapeCount: Int { lock.lock(); defer { lock.unlock() }; return escapes }
}

private let axCannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

private final class RowDeleted: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Logic's app root: an arrange window plus, while the warning is up, a top-level modal AXDialog
/// holding its buttons, or for `.newTrackSheet` a sheet among the arrange window's children. The
/// arrange window answers AXSheets with -25205, as Logic does. With `arrangeModalUnreadable` its
/// AXModal read fails, so no read of the modal set is complete.
private func makeLogicAX(
    _ warning: WriteWarning,
    arrangeModalUnreadable: Bool = false
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(1)
    let dialog = builder.element(2)
    let arrange = builder.element(4)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXModalAttribute as String, false)
    builder.setAttribute(dialog, kAXModalAttribute as String, true)
    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    let sheet = builder.element(3)
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, AXLocalePolicy.newTrackSheetDescription.canonical)
    let titles: [String]
    switch warning.shape {
    case .oneButton: titles = ["OK"]
    case .twoButtons: titles = ["Alpha", "Beta"]
    case .newTrackSheet: titles = [AXLocalePolicy.createButton.canonical, AXLocalePolicy.cancelButton.canonical]
    }
    let buttons = titles.enumerated().map { offset, title in
        let button = builder.element(100 + offset)
        builder.setAttribute(button, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(button, kAXTitleAttribute as String, title)
        return button
    }
    let isSheet = warning.shape == .newTrackSheet
    if isSheet { builder.setAttribute(buttons[1], kAXEnabledAttribute as String, false) }
    builder.setChildren(isSheet ? sheet : dialog, buttons)
    let arrangeChildren: @Sendable (AXUIElement) -> [AXUIElement]? = { element in
        guard CFEqual(element, arrange) else { return nil }
        return isSheet && warning.isUp ? [sheet] : []
    }
    // One menu-bar item, selected while the fixture's stray menu is open.
    let menuBar = builder.element(5)
    let menuBarItem = builder.element(6)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [menuBarItem])

    return builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            if CFEqual(element, menuBarItem), attribute == (kAXSelectedAttribute as String) {
                return AnyObject??.some(NSNumber(value: warning.isMenuOpen))
            }
            guard attribute == (kAXWindowsAttribute as String), CFEqual(element, app) else { return nil }
            let windows: [AXUIElement] = warning.isUp && !isSheet ? [arrange, dialog] : [arrange]
            return AnyObject??.some(windows as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            if CFEqual(element, app), attribute == (kAXMainWindowAttribute as String) {
                return warning.mainWindowRead() ? nil : .failure(axCannotComplete)
            }
            guard CFEqual(element, arrange) else { return nil }
            if attribute == "AXSheets" {
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            }
            guard arrangeModalUnreadable, attribute == (kAXModalAttribute as String) else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        },
        childrenHandler: arrangeChildren,
        childrenResultHandler: { element in arrangeChildren(element).map { .success($0) } },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            if action == (kAXPressAction as String), buttons.contains(where: { CFEqual($0, element) }) {
                warning.buttonPressed()
            }
            return true
        },
        executeAppleScript: { _ in
            warning.escapeSent()
            return .error("fixture: AppleScript is not run")
        }
    )
}

/// The track-delete side (R1077-1 asks for the same transitions on its loop). An arrange window
/// whose header rail loses its row when Delete Track is pressed; the press raises the fixture's
/// one-button warning as a top-level modal dialog. AXWindows lists the arrange window, and the
/// dialog while it is up. The Track menu-bar item doubles as the stray menu.
private func makeDeleteAX(_ warning: WriteWarning) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(200)
    let arrange = builder.element(201)
    let menuBar = builder.element(202)
    let trackMenu = builder.element(203)
    let deleteItem = builder.element(204)
    let headers = builder.element(205)
    let header = builder.element(206)
    let dialog = builder.element(207)
    let ok = builder.element(208)
    let rowDeleted = RowDeleted()

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXModalAttribute as String, false)
    builder.setChildren(arrange, [headers])
    builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
    builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, AXLocalePolicy.trackMenuBar.canonical)
    builder.setChildren(trackMenu, [deleteItem])
    builder.setAttribute(deleteItem, kAXTitleAttribute as String, AXLocalePolicy.deleteTrackMenuItem.canonical)
    builder.setAttribute(dialog, kAXModalAttribute as String, true)
    builder.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
    builder.setAttribute(ok, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(ok, kAXTitleAttribute as String, "OK")
    builder.setChildren(dialog, [ok])
    let headerRows: @Sendable (AXUIElement) -> [AXUIElement]? = { element in
        guard CFEqual(element, headers) else { return nil }
        return rowDeleted.isSet ? [] : [header]
    }

    return builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            if CFEqual(element, trackMenu), attribute == (kAXSelectedAttribute as String) {
                return AnyObject??.some(NSNumber(value: warning.isMenuOpen))
            }
            guard attribute == (kAXWindowsAttribute as String), CFEqual(element, app) else { return nil }
            let windows: [AXUIElement] = warning.isUp ? [arrange, dialog] : [arrange]
            return AnyObject??.some(windows as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            if CFEqual(element, app), attribute == (kAXMainWindowAttribute as String) {
                return warning.mainWindowRead() ? nil : .failure(axCannotComplete)
            }
            guard CFEqual(element, arrange), attribute == "AXSheets" else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
        },
        childrenHandler: headerRows,
        childrenResultHandler: { element in headerRows(element).map { .success($0) } },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard action == (kAXPressAction as String) else { return false }
            if CFEqual(element, deleteItem) {
                rowDeleted.set()
                warning.writePressed()
            } else if CFEqual(element, ok) {
                warning.buttonPressed()
            }
            return true
        },
        executeAppleScript: { _ in
            warning.escapeSent()
            return .error("fixture: AppleScript is not run")
        }
    )
}

private func deleteTrack(_ warning: WriteWarning) async -> [String: Any] {
    let result = await AccessibilityChannel.defaultDeleteTrack(runtime: makeDeleteAX(warning))
    return (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
}

/// One track whose automation mode is set by the mode buttons, with Select moving the selection.
/// The Write press tells the warning; every mode read the channel takes is counted by it.
private actor WriteWarningSurface: MCUTransportProtocol {
    private var selectedTrack = 0
    private var modes: [AutomationMode] = [.read]
    private let warning: WriteWarning
    private let modeReadable: Bool
    private(set) var events: [String] = []

    init(warning: WriteWarning, modeReadable: Bool = true) {
        self.warning = warning
        self.modeReadable = modeReadable
    }

    func send(_ bytes: [UInt8]) {
        guard let button = MCUProtocol.decodeButton(bytes), button.on else { return }
        switch button.function {
        case .select:
            selectedTrack = button.strip
            events.append("select:\(button.strip)")
        case .automationWrite:
            modes[selectedTrack] = .write
            events.append("automation:write:\(selectedTrack)")
            warning.writePressed()
        case .automationTouch:
            modes[selectedTrack] = .touch
            events.append("automation:touch:\(selectedTrack)")
        default:
            break
        }
    }

    func mode(at track: Int) -> AutomationMode? {
        warning.modeRead()
        guard modeReadable, modes.indices.contains(track) else { return nil }
        return modes[track]
    }

    func selectedTrackIndex() -> Int { selectedTrack }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {}
    func stop() {}
}

private struct Run {
    let body: [String: Any]
    let events: [String]
}

private func setAutomation(
    _ mode: String,
    warning: WriteWarning,
    modeReadable: Bool = true,
    arrangeModalUnreadable: Bool = false,
    watchesModal: Bool = true
) async -> Run {
    let surface = WriteWarningSurface(warning: warning, modeReadable: modeReadable)
    let runtime = makeLogicAX(warning, arrangeModalUnreadable: arrangeModalUnreadable)
    let channel = MCUChannel(
        transport: surface,
        cache: StateCache(),
        axReadback: MCUChannel.AXReadback(
            readVolume: { _ in nil },
            readPan: { _ in nil },
            readAutomationMode: { track in await surface.mode(at: track) },
            readSelectedTrack: { await surface.selectedTrackIndex() },
            reconcileModal: watchesModal
                ? AccessibilityChannel.automationModalReconciler(
                    runtime: runtime,
                    witnessAttempts: 2,
                    witnessDelayNanoseconds: 0
                )
                : nil
        ),
        sleep: CountingSleeper().closure
    )
    let result = await channel.execute(
        operation: "track.set_automation",
        params: ["index": "0", "mode": mode]
    )
    warning.settle()
    let body = (try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any] ?? [:]
    return Run(body: body, events: await surface.events)
}

// MARK: - Tests

@Suite("Issue1077WriteWarningTests")
struct Issue1077WriteWarningTests {
    @Test func theWriteWarningIsAcknowledgedBeforeTheReply() async throws {
        let warning = WriteWarning()
        let run = await setAutomation("write", warning: warning)

        // The seam fired: the Write press raised the warning in the fake AX tree.
        #expect(run.events == ["select:0", "automation:write:0"])
        #expect(warning.raisedCount == 1)
        // It was pressed once, through its own button, and it is gone.
        #expect(warning.pressCount == 1)
        #expect(!warning.isUp)
        #expect(run.body["state"] as? String == "A")
        #expect(run.body["observed_mode"] as? String == "write")
        #expect(run.body["modal_after_press"] as? String == "clear")
        #expect(run.body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(run.body["reconciled_action"] as? String == "acknowledge_alert")
        #expect(run.body["modal_reconciliation_witness"] != nil)
    }

    /// Control for the test above, in the same fixture: a press that raises nothing is State A
    /// with no reconcile fields and nothing pressed.
    @Test func aPressThatRaisesNothingReportsAClearModalSetAndPressesNothing() async throws {
        let warning = WriteWarning(arrival: .none)
        let run = await setAutomation("write", warning: warning)

        #expect(run.events == ["select:0", "automation:write:0"])
        #expect(warning.raisedCount == 0)
        #expect(warning.pressCount == 0)
        #expect(run.body["state"] as? String == "A")
        #expect(run.body["modal_after_press"] as? String == "clear")
        #expect(run.body["reconciled_modal_kind"] == nil)
        #expect(run.body["reconciled_action"] == nil)
    }

    /// Without the modal watch the same press leaves the warning up and still answers State A:
    /// the fixture can show the hazard the watch removes.
    @Test func withoutTheWatchTheWarningStaysUpBehindAStateAReply() async throws {
        let warning = WriteWarning()
        let run = await setAutomation("write", warning: warning, watchesModal: false)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 0)
        #expect(warning.isUp)
        #expect(run.body["state"] as? String == "A")
        #expect(run.body["modal_after_press"] == nil)
    }

    /// The #1077 setup: the mode read answers nothing, so the reply cannot be State A, and the
    /// warning must still be acknowledged.
    @Test func theWarningIsAcknowledgedWhenTheModeDoesNotRead() async throws {
        let warning = WriteWarning()
        let run = await setAutomation("write", warning: warning, modeReadable: false)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 1)
        #expect(!warning.isUp)
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "readback_unavailable")
        #expect(run.body["modal_after_press"] as? String == "clear")
        #expect(run.body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(run.body["reconciled_action"] as? String == "acknowledge_alert")
    }

    /// A warning that appears after one clean read, with the mode already landed. One clean read
    /// would end the poll and leave it up; `settle` then raises it as Logic would.
    @Test func aWarningThatAppearsAfterAFirstCleanReadIsStillAcknowledged() async throws {
        let warning = WriteWarning(arrival: .onModeRead(2))
        let run = await setAutomation("write", warning: warning)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 1)
        #expect(!warning.isUp)
        #expect(run.body["state"] as? String == "A")
        #expect(run.body["modal_after_press"] as? String == "clear")
        #expect(run.body["reconciled_modal_kind"] as? String == "informational_alert")
    }

    /// A dialog with two buttons is a choice; it is reported and nothing in it is pressed.
    @Test func aTwoButtonDialogIsReportedOpenAndNotPressed() async throws {
        let warning = WriteWarning(shape: .twoButtons)
        let run = await setAutomation("write", warning: warning)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 0)
        #expect(warning.isUp)
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "modal_left_open")
        #expect(run.body["modal_after_press"] as? String == "open")
        #expect(run.body["reconciled_modal_kind"] as? String == "unknown_sheet")
        #expect(run.body["reconciled_action"] as? String == "none")
        #expect(run.body["observed_mode"] as? String == "write")
    }

    /// The watch runs the preflight scope with Create excluded: a New Track sheet is reported and
    /// its Create is never pressed.
    @Test func aNewTrackSheetIsReportedAndItsCreateIsNotPressed() async throws {
        let warning = WriteWarning(shape: .newTrackSheet)
        let run = await setAutomation("write", warning: warning)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 0)
        #expect(warning.isUp)
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "modal_left_open")
        #expect(run.body["reconciled_modal_kind"] as? String == "mandatory_new_track")
        #expect(run.body["reconciled_action"] as? String == "none")
    }

    /// A press that does not close the warning is not repeated into the operation deadline.
    @Test func aWarningThatDoesNotCloseIsPressedOnceAndReportedOpen() async throws {
        let warning = WriteWarning(closesWhenPressed: false)
        let run = await setAutomation("write", warning: warning)

        #expect(warning.pressCount == 1)
        #expect(warning.isUp)
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "modal_left_open")
        #expect(run.body["modal_after_press"] as? String == "open")
        #expect(run.body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(run.body["reconciled_action"] as? String == "acknowledge_alert")
        #expect(run.body["modal_reconciliation_witness"] != nil)
    }

    /// A modal set that could not be read does not certify the mode, even when it matched.
    @Test func anUnreadableModalSetKeepsAMatchedModeOutOfStateA() async throws {
        let warning = WriteWarning(arrival: .none)
        let run = await setAutomation("write", warning: warning, arrangeModalUnreadable: true)

        #expect(run.body["observed_mode"] as? String == "write")
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "readback_unavailable")
        #expect(run.body["modal_after_press"] as? String == "unreadable")
        #expect(run.body["reconciled_modal_observation"] as? String == "incomplete")
        #expect(run.body["reconciled_modal_kind"] == nil)
    }

    /// A window whose AXModal does not read withholds the whole dialog read: the two-button dialog
    /// behind it is not classified, nothing in it is pressed, and the reply is not State A.
    @Test func aDialogBesideAnUnreadableWindowIsNotPressedAndNotCertified() async throws {
        let warning = WriteWarning(shape: .twoButtons)
        let run = await setAutomation("write", warning: warning, arrangeModalUnreadable: true)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 0)
        #expect(warning.isUp)
        #expect(run.body["observed_mode"] as? String == "write")
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "readback_unavailable")
        #expect(run.body["modal_after_press"] as? String == "unreadable")
    }

    /// Touch raises no warning in this fixture; the watch runs for every mode press all the same.
    @Test func everyModePressIsWatchedNotOnlyWrite() async throws {
        let warning = WriteWarning()
        let run = await setAutomation("touch", warning: warning)

        #expect(run.events == ["select:0", "automation:touch:0"])
        #expect(run.body["state"] as? String == "A")
        #expect(run.body["modal_after_press"] as? String == "clear")
    }

    /// The server's own MCU channel reads the modal set after a press; the tests above build their
    /// own channel, so without this nothing pins the production wiring.
    @Test func theServerWiresTheModalWatch() async throws {
        let server = LogicProServer()
        #expect(await server.mcuObservesModalAfterAutomationPressForTesting)
    }

    // MARK: R1077-1 — a sighting outlives the reads after it, and the limit binds the kind pressed

    /// The observation sees the warning; the executor's fresh read then fails at AXMainWindow, and
    /// so does every read after it. Nothing was pressed, and the reply must still name the warning
    /// it saw. The modal set never read complete again, so the reply is not State A.
    @Test func aWarningSeenBeforeAnUnreadableReconcileReadIsStillNamed() async throws {
        let warning = WriteWarning(mainWindowReadsThatSucceed: 1)
        let run = await setAutomation("write", warning: warning)

        // The seam fired: the warning went up and the first read could see it.
        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 0)
        #expect(warning.isUp)
        #expect(run.body["observed_mode"] as? String == "write")
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "readback_unavailable")
        #expect(run.body["modal_after_press"] as? String == "unreadable")
        #expect(run.body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(run.body["reconciled_action"] as? String == "none")
        #expect(run.body["modal_reconciliation_witness"] == nil)
    }

    /// The warning is acknowledged, and the press opens a menu. The next observation sees that
    /// menu, which nothing acted on, so the executor runs; by its fresh read the warning is up
    /// again. The warning's kind was already acted on, so it is not pressed a second time, and the
    /// reply keeps the first acknowledgement beside the warning that is still up.
    @Test func aKindAlreadyActedOnIsNotPressedAgainWhenTheFreshReadFindsIt() async throws {
        let warning = WriteWarning(menuOpensWhenPressed: true, reraisesOnMainWindowRead: 4)
        let run = await setAutomation("write", warning: warning)

        // The seam fired: raised on the press and again on the fourth read.
        #expect(warning.raisedCount == 2)
        #expect(warning.pressCount == 1)
        #expect(warning.isUp)
        #expect(!warning.isMenuOpen)
        #expect(warning.escapeCount == 0)
        #expect(run.body["state"] as? String == "B")
        #expect(run.body["reason"] as? String == "modal_left_open")
        #expect(run.body["modal_after_press"] as? String == "open")
        #expect(run.body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(run.body["reconciled_action"] as? String == "acknowledge_alert")
        #expect(run.body["modal_reconciliation_witness"] != nil)
    }

    /// The track-delete loop, first transition: its observation (on the arrange window it resolved
    /// once) sees the warning, and its executor's fresh read fails at AXMainWindow on every poll.
    @Test func deleteNamesAWarningItsFreshReadCouldNotSee() async throws {
        let warning = WriteWarning(mainWindowReadsThatSucceed: 0)
        let body = await deleteTrack(warning)

        #expect(warning.raisedCount == 1)
        #expect(warning.pressCount == 0)
        #expect(warning.isUp)
        #expect(body["state"] as? String == "B")
        #expect(body["reason"] as? String == "retry_exhausted")
        #expect(body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(body["reconciled_action"] as? String == "none")
    }

    /// The track-delete loop, second transition: the warning is acknowledged on the first poll and
    /// a menu opens; the second poll observes the menu, and its executor's fresh read (the second
    /// AXMainWindow read) finds the warning again. It is not pressed again.
    @Test func deleteDoesNotPressAWarningTwiceWhenAMenuWasObservedInBetween() async throws {
        let warning = WriteWarning(menuOpensWhenPressed: true, reraisesOnMainWindowRead: 2)
        let body = await deleteTrack(warning)

        #expect(warning.raisedCount == 2)
        #expect(warning.pressCount == 1)
        #expect(warning.isUp)
        #expect(warning.escapeCount == 0)
        #expect(body["state"] as? String == "B")
        #expect(body["reconciled_modal_kind"] as? String == "informational_alert")
        #expect(body["reconciled_action"] as? String == "acknowledge_alert")
    }
}
