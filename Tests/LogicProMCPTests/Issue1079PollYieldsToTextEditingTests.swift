@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #1079 — with the server connected and idle, an inline track rename lost keyboard focus partway
/// through typing and the rest of the keystrokes reached Logic as key commands; with the process
/// killed it did not. The background poll loop now skips its cycle while Logic's focused element
/// is a text field, read through the same classifier that keeps a synthetic key out of one.
///
/// Every test drives the real `StatePoller` and counts what a cycle invokes: the window check, the
/// blocking-dialog sample, each AX section read, and the `osascript` document-path read that
/// `LogicProjectFileReader` makes. The loop's `sleep` seam ends the loop after a fixed number of
/// ticks, so nothing here waits on a clock.
@Suite("Issue1079PollYieldsToTextEditing", .timeLimit(.minutes(1)))
struct Issue1079PollYieldsToTextEditingTests {

    // MARK: - Fixtures

    enum Read: CaseIterable, CustomStringConvertible {
        case focus, window, blockingDialog, project, tracks, transport, mixer, markers, documentPath

        var description: String {
            switch self {
            case .focus: "keyboard focus"
            case .window: "visible-window check"
            case .blockingDialog: "blocking-dialog sample"
            case .project: "project.get_info"
            case .tracks: "track read"
            case .transport: "transport.get_state"
            case .mixer: "mixer.get_state"
            case .markers: "nav.get_markers"
            case .documentPath: "osascript document path"
            }
        }
    }

    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Read: Int] = [:]
        private var sleeps = 0

        func bump(_ read: Read) {
            lock.lock(); defer { lock.unlock() }
            counts[read, default: 0] += 1
        }

        func count(_ read: Read) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[read, default: 0]
        }

        /// Returns how many times the loop has slept, this time included.
        func nextSleep() -> Int {
            lock.lock(); defer { lock.unlock() }
            sleeps += 1
            return sleeps
        }
    }

    private static let projectJSON: String = {
        var info = ProjectInfo()
        info.name = "Fixture"
        info.lastUpdated = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // No `filePath`, so a cycle that reads the project goes on to ask for the document path.
        return String(decoding: (try? encoder.encode(info)) ?? Data(), as: UTF8.self)
    }()

    /// An AX channel whose every read the poll cycle makes is counted.
    private static func countingChannel(_ log: ReadLog) -> AccessibilityChannel {
        AccessibilityChannel(runtime: .init(
            isTrusted: { true },
            isLogicProRunning: { true },
            appRoot: { nil },
            transportState: { log.bump(.transport); return .success("{}") },
            toggleTransportButton: { _ in .error("not under test") },
            setTempo: { _ in .error("not under test") },
            setCycleRange: { _ in .error("not under test") },
            tracks: { log.bump(.tracks); return .success("[]") },
            trackStates: { log.bump(.tracks); return [TrackState(id: 0, name: "Vox", type: .audio)] },
            selectedTrack: { .error("not under test") },
            selectTrack: { _ in .error("not under test") },
            setTrackToggle: { _, _ in .error("not under test") },
            renameTrack: { _ in .error("not under test") },
            mixerState: { log.bump(.mixer); return .success("[]") },
            channelStrip: { _ in .error("not under test") },
            setMixerValue: { _, _ in .error("not under test") },
            projectInfo: { log.bump(.project); return .success(projectJSON) },
            markers: { log.bump(.markers); return .success("[]") }
        ))
    }

    private static func makePoller(
        log: ReadLog,
        focus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus,
        mutationInFlight: Bool = false,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in throw CancellationError() }
    ) -> StatePoller {
        var runtime = StatePoller.Runtime(
            hasVisibleWindow: { log.bump(.window); return true },
            dialogPresent: { false },
            sleep: sleep,
            blockingDialogInfo: { log.bump(.blockingDialog); return nil },
            projectFileReader: .init(
                currentDocumentPath: { log.bump(.documentPath); return nil },
                now: Date.init,
                readPlistData: { _ in nil },
                mtime: { _ in nil },
                sleep: { _ in }
            ),
            keyboardFocus: { log.bump(.focus); return focus() }
        )
        runtime.mutationInFlight = { mutationInFlight }
        return StatePoller(axChannel: countingChannel(log), cache: StateCache(), runtime: runtime)
    }

    /// Runs the background loop for exactly `ticks` iterations and returns what it read. The loop
    /// sleeps once per iteration whether or not it ran a cycle, so the sleep seam is the tick
    /// counter; on the last tick it throws, which ends the loop the way cancellation does.
    private static func runBackgroundLoop(
        ticks: Int,
        mutationInFlight: Bool = false,
        focus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus
    ) async -> ReadLog {
        let log = ReadLog()
        let (loopEnded, endLoop) = AsyncStream<Void>.makeStream()
        let poller = makePoller(log: log, focus: focus, mutationInFlight: mutationInFlight) { _ in
            if log.nextSleep() >= ticks {
                endLoop.finish()
                throw CancellationError()
            }
            await Task.yield()
        }
        await poller.start()
        for await _ in loopEnded {}
        await poller.stop()
        return log
    }

    private static let cycleReads: [Read] = Read.allCases.filter { $0 != .focus }

    // MARK: - The gate

    @Test(
        "a focused text field skips every background cycle: no AX section read, no osascript",
        arguments: [
            AccessibilityChannel.LogicKeyboardFocus.textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false),
            AccessibilityChannel.LogicKeyboardFocus.textEditing(role: kAXGroupRole as String, byInsertionPoint: true),
        ]
    )
    func textEditingSkipsTheCycle(focus: AccessibilityChannel.LogicKeyboardFocus) async {
        let log = await Self.runBackgroundLoop(ticks: 3) { focus }

        // The gate was asked on every tick. Without this, zero reads below could mean the loop
        // never got as far as the gate.
        #expect(log.count(.focus) == 3, "the focus was read \(log.count(.focus)) times in 3 ticks")
        for read in Self.cycleReads {
            #expect(log.count(read) == 0, "\(read) ran while a text field held the focus")
        }
    }

    @Test("a focus that is not text editing runs the cycle as before")
    func notTextEditingRunsTheCycle() async {
        let log = await Self.runBackgroundLoop(ticks: 3) { .notTextEditing }

        #expect(log.count(.focus) == 3)
        for read in [Read.window, .blockingDialog, .project, .tracks, .transport, .mixer, .documentPath] {
            #expect(log.count(read) == 3, "\(read) ran \(log.count(read)) times in 3 ticks")
        }
        #expect(log.count(.markers) >= 1, "the marker read, due on the first cycle, never ran")
    }

    @Test(
        "an unreadable focus polls: a failed read is not a text field, and yielding to it would stop polling",
        arguments: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage.allCases
    )
    func unreadableFocusPolls(stage: AccessibilityChannel.LogicKeyboardFocus.UnreadableStage) async {
        let log = await Self.runBackgroundLoop(ticks: 2) { .unreadable(stage) }

        #expect(log.count(.focus) == 2)
        for read in [Read.window, .project, .tracks, .transport, .mixer, .documentPath] {
            #expect(log.count(read) == 2, "\(read) ran \(log.count(read)) times in 2 ticks")
        }
    }

    @Test("an explicit refreshNow runs while a text field holds the focus, and does not ask")
    func refreshNowIsNotGated() async {
        let log = ReadLog()
        let poller = Self.makePoller(log: log) {
            .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
        }

        await poller.refreshNow()

        #expect(log.count(.focus) == 0, "refreshNow consulted the background loop's focus gate")
        for read in [Read.window, .project, .tracks, .transport, .mixer, .documentPath] {
            #expect(log.count(read) == 1, "\(read) ran \(log.count(read)) times for one refresh")
        }
    }

    @Test("the focus is not read while a mutation holds the AX surface")
    func focusIsReadOnlyAfterTheMutationGate() async {
        let log = await Self.runBackgroundLoop(ticks: 3, mutationInFlight: true) { .notTextEditing }

        #expect(log.count(.focus) == 0, "the focus was read while a mutation held the surface")
        #expect(log.count(.window) == 0, "a cycle ran while a mutation held the surface")
    }

    // MARK: - The shared classifier

    private struct FocusFixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let focused: AXUIElement

        func logicRuntime(pid: pid_t? = 4242) -> AXLogicProElements.Runtime {
            builder.makeLogicRuntime(pid: pid, appElement: app)
        }
    }

    /// An application element whose `AXFocusedUIElement` is a single element with `role`, or with
    /// no role at all when `role` is nil.
    private static func focusFixture(role: String?) -> FocusFixture {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10_790)
        let focused = builder.element(10_791)
        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, focused)
        if let role { builder.setAttribute(focused, kAXRoleAttribute as String, role) }
        return FocusFixture(builder: builder, app: app, focused: focused)
    }

    @Test("classifier: a focused text field is text editing; a focused track list is not")
    func classifierSeparatesTextFieldFromOtherFocus() {
        let textField = Self.focusFixture(role: kAXTextFieldRole as String)
        let trackList = Self.focusFixture(role: kAXListRole as String)

        #expect(
            AccessibilityChannel.readLogicKeyboardFocus(runtime: textField.logicRuntime())
                == .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
        )
        #expect(
            AccessibilityChannel.readLogicKeyboardFocus(runtime: trackList.logicRuntime())
                == .notTextEditing
        )
    }

    @Test("classifier: an insertion point marks a text surface whatever its role")
    func classifierCountsAnInsertionPoint() {
        let fixture = Self.focusFixture(role: kAXGroupRole as String)
        fixture.builder.setAttribute(
            fixture.focused, kAXInsertionPointLineNumberAttribute as String, NSNumber(value: 0)
        )

        #expect(
            AccessibilityChannel.readLogicKeyboardFocus(runtime: fixture.logicRuntime())
                == .textEditing(role: kAXGroupRole as String, byInsertionPoint: true)
        )
    }

    @Test("classifier: each stage that does not read is reported as that stage, not as no text field")
    func classifierReportsWhereTheReadingStopped() {
        let fixture = Self.focusFixture(role: kAXTextFieldRole as String)
        #expect(
            AccessibilityChannel.readLogicKeyboardFocus(runtime: fixture.logicRuntime(pid: nil))
                == .unreadable(.appRoot)
        )

        let noFocus = FakeAXRuntimeBuilder()
        let app = noFocus.element(10_792)
        #expect(
            AccessibilityChannel.readLogicKeyboardFocus(runtime: noFocus.makeLogicRuntime(appElement: app))
                == .unreadable(.focusedElement)
        )

        let noRole = Self.focusFixture(role: nil)
        #expect(
            AccessibilityChannel.readLogicKeyboardFocus(runtime: noRole.logicRuntime())
                == .unreadable(.role)
        )
    }

    @Test("end to end through the classifier: a focused text field skips the loop, a focused track list does not")
    func loopReadsFocusThroughTheSharedClassifier() async {
        let textField = Self.focusFixture(role: kAXTextFieldRole as String).logicRuntime()
        let editing = await Self.runBackgroundLoop(ticks: 3) {
            AccessibilityChannel.readLogicKeyboardFocus(runtime: textField)
        }
        #expect(editing.count(.focus) == 3)
        #expect(editing.count(.window) == 0, "a cycle ran while the fake text field held the focus")
        #expect(editing.count(.documentPath) == 0, "the osascript read ran while the fake text field held the focus")

        let trackList = Self.focusFixture(role: kAXListRole as String).logicRuntime()
        let idle = await Self.runBackgroundLoop(ticks: 3) {
            AccessibilityChannel.readLogicKeyboardFocus(runtime: trackList)
        }
        #expect(idle.count(.window) == 3, "\(idle.count(.window)) cycles ran in 3 ticks with a track list focused")
        #expect(idle.count(.documentPath) == 3)
    }
}
