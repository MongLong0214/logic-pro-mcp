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
// the poll waits go through CountingSleeper.

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
    let shape: Shape
    let arrival: Arrival
    let closesWhenPressed: Bool

    init(shape: Shape = .oneButton, arrival: Arrival = .onPress, closesWhenPressed: Bool = true) {
        self.shape = shape
        self.arrival = arrival
        self.closesWhenPressed = closesWhenPressed
    }

    func writePressed() {
        lock.lock()
        defer { lock.unlock() }
        modeReadsSincePress = 0
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

    return builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard attribute == (kAXWindowsAttribute as String), CFEqual(element, app) else { return nil }
            let windows: [AXUIElement] = warning.isUp && !isSheet ? [arrange, dialog] : [arrange]
            return AnyObject??.some(windows as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
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
        }
    )
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
}
