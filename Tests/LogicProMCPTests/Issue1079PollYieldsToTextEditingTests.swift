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
        case focus, window, blockingDialog, project, tracks, trackHeader, transport, mixer, markers, documentPath

        var description: String {
            switch self {
            case .focus: "keyboard focus"
            case .window: "visible-window check"
            case .blockingDialog: "blocking-dialog sample"
            case .project: "project.get_info"
            case .tracks: "track read"
            case .trackHeader: "one header of the stoppable track read"
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
    /// `headers`, when set, makes the background poll's track read a walk of that many headers
    /// that asks its `stop` before each one, as the production walk does; each header read is
    /// counted as `.trackHeader`.
    private static func countingChannel(
        _ log: ReadLog, headers: Int? = nil, projectInfo: (@Sendable (Int) -> ChannelResult)? = nil,
        mixerState: (@Sendable () -> ChannelResult)? = nil
    ) -> AccessibilityChannel {
        let projectReads = Counter()
        var stoppable: (@Sendable (@escaping @Sendable () -> Bool) -> (states: [TrackState]?, yielded: Bool))?
        if let count = headers {
            stoppable = { @Sendable (stop: @escaping @Sendable () -> Bool) -> (states: [TrackState]?, yielded: Bool) in
                var states: [TrackState] = []
                for index in 0..<count {
                    if stop() { return (nil, true) }
                    log.bump(.trackHeader)
                    states.append(TrackState(id: index, name: "Track \(index)", type: .audio))
                }
                return (states, false)
            }
        }
        return AccessibilityChannel(runtime: .init(
            isTrusted: { true },
            isLogicProRunning: { true },
            appRoot: { nil },
            transportState: { log.bump(.transport); return .success("{}") },
            toggleTransportButton: { _ in .error("not under test") },
            setTempo: { _ in .error("not under test") },
            setCycleRange: { _ in .error("not under test") },
            tracks: { log.bump(.tracks); return .success("[]") },
            trackStates: { log.bump(.tracks); return [TrackState(id: 0, name: "Vox", type: .audio)] },
            trackStatesStopping: stoppable,
            selectedTrack: { .error("not under test") },
            selectTrack: { _ in .error("not under test") },
            setTrackToggle: { _, _ in .error("not under test") },
            renameTrack: { _ in .error("not under test") },
            mixerState: { log.bump(.mixer); return mixerState?() ?? .success("[]") },
            channelStrip: { _ in .error("not under test") },
            setMixerValue: { _, _ in .error("not under test") },
            projectInfo: {
                log.bump(.project)
                return projectInfo?(projectReads.next()) ?? .success(projectJSON)
            },
            markers: { log.bump(.markers); return .success("[]") }
        ))
    }

    private static func makePoller(
        log: ReadLog,
        headers: Int? = nil,
        focus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus,
        mutationInFlight: Bool = false,
        cache: StateCache = StateCache(),
        projectInfo: (@Sendable (Int) -> ChannelResult)? = nil,
        mixerState: (@Sendable () -> ChannelResult)? = nil,
        postPoll: @escaping StatePoller.PostPoll = { _, _ in true },
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
        return StatePoller(
            axChannel: countingChannel(log, headers: headers, projectInfo: projectInfo, mixerState: mixerState),
            cache: cache, runtime: runtime, postPoll: postPoll
        )
    }

    /// Runs the background loop for exactly `ticks` iterations and returns what it read. The loop
    /// sleeps once per iteration whether or not it ran a cycle, so the sleep seam is the tick
    /// counter; on the last tick it throws, which ends the loop the way cancellation does.
    private static func runBackgroundLoop(
        ticks: Int,
        mutationInFlight: Bool = false,
        headers: Int? = nil,
        cache: StateCache = StateCache(),
        projectInfo: (@Sendable (Int) -> ChannelResult)? = nil,
        mixerState: (@Sendable () -> ChannelResult)? = nil,
        postPoll: @escaping StatePoller.PostPoll = { _, _ in true },
        focus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus
    ) async -> ReadLog {
        let log = ReadLog()
        let (loopEnded, endLoop) = AsyncStream<Void>.makeStream()
        let poller = makePoller(
            log: log, headers: headers, focus: focus, mutationInFlight: mutationInFlight,
            cache: cache, projectInfo: projectInfo, mixerState: mixerState, postPoll: postPoll
        ) { _ in
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

        // At least once per tick: the gate. A running cycle also reads it before each read.
        #expect(log.count(.focus) >= 3)
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

        #expect(log.count(.focus) >= 2)
        for read in [Read.window, .project, .tracks, .transport, .mixer, .documentPath] {
            #expect(log.count(read) == 2, "\(read) ran \(log.count(read)) times in 2 ticks")
        }
    }

    // MARK: - Editing that begins while a background cycle is running (review R1)

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        func peek() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The focus reads as text editing from its `firstEditingReading`th reading on. Within one
    /// background cycle the focus is read at the tick's gate (1), then before the project read (2),
    /// the document-path query (3), the track read (4), transport (5), mixer (6) and markers (7),
    /// which are due on the first cycle. The window check and the blocking-dialog sample come
    /// before reading 2 and always run once the gate passes.
    struct MidCycle: Sendable, CustomTestStringConvertible {
        let firstEditingReading: Int
        let ran: [Read]
        let skipped: [Read]
        var testDescription: String { "editing from focus reading \(firstEditingReading)" }
    }

    static let midCycle: [MidCycle] = {
        let order: [Read] = [.project, .documentPath, .tracks, .transport, .mixer, .markers]
        return (2...8).map { first in
            let reached = first - 2
            return MidCycle(firstEditingReading: first,
                            ran: [.window, .blockingDialog] + order.prefix(reached),
                            skipped: Array(order.dropFirst(reached)))
        }
    }()

    /// Mutations this kills: any one of the six in-cycle checks removed (its row runs the read it
    /// guarded), and the checks consulted for a refresh's cycle (`refreshNowIsNotGated`). The last
    /// row, where editing never begins within the cycle, is the control: every read runs.
    @Test("a background cycle stops at the read after editing begins", arguments: midCycle)
    func aBackgroundCycleStopsAtTheReadAfterEditingBegins(_ c: MidCycle) async {
        let readings = Counter()
        let log = await Self.runBackgroundLoop(ticks: 1) {
            readings.next() >= c.firstEditingReading
                ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                : .notTextEditing
        }
        for read in c.ran {
            #expect(log.count(read) == 1, "\(read) ran \(log.count(read)) times, not once")
        }
        for read in c.skipped {
            #expect(log.count(read) == 0, "\(read) ran after editing began")
        }
    }

    /// The track walk itself. Measured 2026-10-02: reading AXHelp of a track header's elements, as
    /// `inferTrackType` does for every header, ended an inline rename at once, and in the
    /// ten-language run two candidate samples lost the field to a walk already under way. With
    /// three headers, the focus is read at the gate (1), before the project read (2), the
    /// document path (3) and the track read (4), then before each header (5, 6, 7), then before
    /// transport (8). Editing that begins at reading 6 lets header 1 be read and stops the walk
    /// before header 2: nothing after it runs. Editing that never begins reads all three headers
    /// and the rest of the cycle, which is the control.
    ///
    /// Mutations this kills: the walk not asking before each header (the stoppable read never
    /// called, or its `stop` ignored), and the poller carrying on after a walk that yielded, which
    /// reaches the fallback track read.
    @Test("a background track walk stops at the next header once editing begins")
    func aBackgroundTrackWalkStopsAtTheNextHeader() async {
        let midWalk = Counter()
        let stopped = await Self.runBackgroundLoop(ticks: 1, headers: 3) {
            midWalk.next() >= 6
                ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                : .notTextEditing
        }
        #expect(stopped.count(.trackHeader) == 1, "header reads \(stopped.count(.trackHeader)), not 1")
        // A walk that yielded must not be followed by the fallback track read, `track.get_tracks`,
        // which walks every header again and would read the help the walk stopped short of.
        #expect(stopped.count(.tracks) == 0, "the fallback track read ran after the walk yielded")
        for read in [Read.transport, .mixer, .markers] {
            #expect(stopped.count(read) == 0, "\(read) ran after the walk yielded")
        }

        let never = await Self.runBackgroundLoop(ticks: 1, headers: 3) { .notTextEditing }
        #expect(never.count(.trackHeader) == 3)
        for read in [Read.transport, .mixer, .markers] {
            #expect(never.count(read) == 1, "\(read) ran \(never.count(read)) times in the control")
        }
    }

    /// The production walk, over a fake window with three track headers. Mutation this kills:
    /// `defaultGetTrackStates(runtime:stoppingWhen:)` not asking before each header.
    @Test("the production track walk asks before each header and stops when told")
    func theProductionTrackWalkAsksBeforeEachHeader() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        let list = builder.element(3)
        let headers = [builder.element(4), builder.element(5), builder.element(6)]
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [list])
        builder.setAttribute(list, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(list, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(list, headers)
        for header in headers {
            builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        }
        let runtime = builder.makeLogicRuntime(appElement: app)

        // Each header is asked about twice: before it, and inside it before its help reads.
        let asked = Counter()
        let stopped = AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: { asked.next() >= 3 })
        #expect(stopped.yielded)
        #expect(stopped.states == nil)
        #expect(asked.next() == 4, "asked twice for header 1 and once before header 2, then stopped")

        let all = Counter()
        let read = AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: { _ = all.next(); return false })
        #expect(!read.yielded)
        #expect(read.states?.count == 3)
        #expect(all.next() == 7, "asked twice for each of the three headers")
    }

    // MARK: - Review R2

    final class AXReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var helpReads = 0
        private var editing = false
        func read(_ attribute: String, onHeaderOne: Bool, editingBeginsOn trigger: String?, afterHelpReads: Int? = nil) {
            lock.lock(); defer { lock.unlock() }
            if attribute == kAXHelpAttribute as String { helpReads += 1 }
            if onHeaderOne, attribute == trigger { editing = true }
            if let afterHelpReads, helpReads >= afterHelpReads { editing = true }
        }
        var help: Int { lock.lock(); defer { lock.unlock() }; return helpReads }
        var isEditing: Bool { lock.lock(); defer { lock.unlock() }; return editing }
    }

    /// Two headers with one child each, read by the production walk. `trigger` names an attribute
    /// whose read on header 1 starts the edit -- the user opening a rename while that header's
    /// earlier reads are under way, after the walk has asked before it.
    private static func walkWithEditingBeginningOn(
        _ trigger: String?, afterHelpReads: Int? = nil
    ) -> (states: [TrackState]?, yielded: Bool, help: Int) {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        let list = builder.element(3)
        let headers = [builder.element(4), builder.element(5)]
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [list])
        builder.setAttribute(list, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(list, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(list, headers)
        for (offset, header) in headers.enumerated() {
            builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXDescriptionAttribute as String, "Track \(offset)")
            let child = builder.element(10 + offset)
            builder.setAttribute(child, kAXRoleAttribute as String, kAXButtonRole as String)
            builder.setChildren(header, [child])
        }
        let reads = AXReadLog()
        let headerOne = builder.elementID(headers[0])
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                reads.read(attribute, onHeaderOne: builder.elementID(element) == headerOne, editingBeginsOn: trigger,
                           afterHelpReads: afterHelpReads)
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        let walk = AccessibilityChannel.defaultGetTrackStates(runtime: runtime, stoppingWhen: { reads.isEditing })
        return (walk.states, walk.yielded, reads.help)
    }

    /// F1079-02: the walk asks before each header, but a header's own reads come before its help
    /// reads, so editing that begins during them used to reach the help reads anyway. Mutation this
    /// kills: the check inside `inferTrackType` removed (header 1's two help reads run). The control
    /// is the same walk with no edit: every element's help is read and both states come back.
    @Test("editing that begins during a header's earlier reads stops the walk before any help read")
    func editingDuringAHeaderStopsBeforeItsHelpReads() {
        let midHeader = Self.walkWithEditingBeginningOn(kAXDescriptionAttribute as String)
        #expect(midHeader.yielded)
        #expect(midHeader.states == nil)
        #expect(midHeader.help == 0, "\(midHeader.help) help reads after editing began")

        let control = Self.walkWithEditingBeginningOn(nil)
        #expect(!control.yielded)
        #expect(control.states?.count == 2)
        #expect(control.help == 4, "help read \(control.help) times, not once per header and child")
    }

    /// After review R3: a rename opened during one header's help reads was lost to the rest of that
    /// header's batch, so the stop is asked before every help read. Editing begins once the first
    /// help read (header 1's own) has been made; its child's help must not be read. Mutation this
    /// kills: the stop asked once before the batch (two help reads, then the yield).
    @Test("editing that begins during a header's help reads stops before the next one")
    func editingDuringTheHelpReadsStopsBeforeTheNextOne() {
        let walk = Self.walkWithEditingBeginningOn(nil, afterHelpReads: 1)
        #expect(walk.yielded)
        #expect(walk.states == nil)
        #expect(walk.help == 1, "\(walk.help) help reads; the one under way when editing began is the only one allowed")
    }

    /// F1079-01: the cached project has a path; the project read answers without one, so the cycle
    /// asks for the document path, and editing begins at that check (focus reading 3). Skipping
    /// the query and writing the pathless info read as a project change and cleared every
    /// section. Mutation this kills: the yield at the path query writing the info anyway. The
    /// control is the same cycle with no edit, where the path query runs.
    @Test("a yield at the document-path query keeps the cached project and its sections")
    func aYieldAtThePathQueryKeepsTheCache() async {
        let path = "/Users/fixture/Fixture.logicx"
        let cache = StateCache()
        var known = ProjectInfo()
        known.name = "Fixture"
        known.filePath = path
        await cache.updateProject(known)
        await cache.updateTracks([TrackState(id: 0, name: "Vox", type: .audio), TrackState(id: 1, name: "Bass", type: .audio)])

        let readings = Counter()
        let log = await Self.runBackgroundLoop(ticks: 1, cache: cache) {
            readings.next() >= 3 ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
        }
        #expect(log.count(.project) == 1, "the project read is what reaches the path check")
        #expect(log.count(.documentPath) == 0)
        #expect(await cache.getProject().filePath == path, "the cached path was replaced by none")
        #expect(await cache.getTracks().count == 2, "the cached tracks were cleared")

        let control = await Self.runBackgroundLoop(ticks: 1) { .notTextEditing }
        #expect(control.count(.documentPath) == 1, "the control asked for the path")
    }

    final class Published: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[ResourceCacheKey]] = []
        func add(_ keys: [ResourceCacheKey]) { lock.lock(); defer { lock.unlock() }; batches.append(keys) }
        var all: [[ResourceCacheKey]] { lock.lock(); defer { lock.unlock() }; return batches }
    }

    /// F1079-02: publishing a cycle's sections reads resources back, so a cycle that yields must
    /// not publish. Tick 1 writes the project and yields before the track read (focus reading 4);
    /// tick 2 runs whole, and its own project read fails, so the project key it publishes can only
    /// be the one tick 1 held. Mutations this kills: a yield publishing at once (tick 1 publishes),
    /// and the held keys dropped (tick 2 publishes no project key).
    @Test("a yielded cycle publishes nothing, and the next whole cycle publishes what it wrote")
    func aYieldedCycleHoldsItsNotifications() async {
        let published = Published()
        let readings = Counter()
        let log = await Self.runBackgroundLoop(
            ticks: 2,
            projectInfo: { call in call == 1 ? .success(Self.projectJSON) : .error("unreadable") },
            postPoll: { keys, _ in published.add(keys); return true }
        ) {
            readings.next() == 4 ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
        }
        #expect(log.count(.project) == 2, "both ticks read the project")
        #expect(log.count(.tracks) == 1, "only tick 2 reached the track read")
        let batches = published.all
        #expect(batches.count == 1, "published \(batches.count) times, not once")
        // Not `batches.first?.contains(.project) == true`: under this toolchain's swift-testing that
        // expectation passed with the key absent (measured, 2026-10-02).
        let publishedKeys = batches.first ?? []
        #expect(publishedKeys.contains(.project), "tick 1's project write was not published")
        #expect(publishedKeys.contains(.tracks))
    }

    // MARK: - Review R3

    /// F1079-R3-01: the path query read the focus as editing (reading 3) and skipped its write, but
    /// the cycle asked the focus again before the track read, and from reading 4 on the focus does
    /// not read, which polls. So the walk ran and read the help. Mutation this kills: the path
    /// query's yield not ending the cycle. The control is the same readings with no edit at 3.
    @Test("a yield at the path query ends the cycle even when the next focus reading fails")
    func aYieldAtThePathQueryEndsTheCycle() async {
        for editingAtThree in [true, false] {
            let readings = Counter()
            let log = await Self.runBackgroundLoop(ticks: 1, headers: 3) {
                switch readings.next() {
                case 1, 2: .notTextEditing
                case 3: editingAtThree ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
                default: .unreadable(.focusedElement)
                }
            }
            if editingAtThree {
                #expect(log.count(.trackHeader) == 0, "\(log.count(.trackHeader)) headers read after the yield")
                for read in [Read.tracks, .transport, .mixer, .markers, .documentPath] {
                    #expect(log.count(read) == 0, "\(read) ran after the path query yielded")
                }
            } else {
                #expect(log.count(.trackHeader) == 3, "the control read \(log.count(.trackHeader)) headers")
                #expect(log.count(.documentPath) == 1)
            }
        }
    }

    /// F1079-R3-02: editing that begins during the cycle's last read (markers, due on the first
    /// cycle) is read at the publication check, focus reading 8, and nothing is published; tick 2
    /// publishes what tick 1 wrote. Markers are written only on tick 1, so a markers key in tick
    /// 2's batch is the held one. Mutation this kills: publishing without asking the focus first.
    @Test("editing during the last read holds the publication for the next whole cycle")
    func editingDuringTheLastReadHoldsThePublication() async {
        // One tick alone: nothing may be published. Without the check, tick 1 publishes and the
        // reading at 8 falls on a later gate instead, which the two-tick run below cannot tell apart.
        let alone = Published()
        let aloneReadings = Counter()
        _ = await Self.runBackgroundLoop(
            ticks: 1,
            postPoll: { keys, _ in alone.add(keys); return true }
        ) {
            aloneReadings.next() == 8 ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
        }
        #expect(alone.all.isEmpty, "tick 1 published \(alone.all) after editing began")

        let published = Published()
        let readings = Counter()
        _ = await Self.runBackgroundLoop(
            ticks: 2,
            postPoll: { keys, _ in published.add(keys); return true }
        ) {
            readings.next() == 8 ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
        }
        let batches = published.all
        #expect(batches.count == 1, "published \(batches.count) times, not once")
        let keys = batches.first ?? []
        #expect(keys.contains(.markers), "tick 1's markers were not held and published")
    }

    /// F1079-R3-02: a publication the stop cut short reports false, and the poller holds its keys
    /// for the next whole cycle. Tick 1 writes the project and its publication stops; tick 2's own
    /// project read fails, so a project key in its batch is the held one. Mutation this kills: a
    /// stopped publication's keys dropped.
    @Test("a publication cut short is published again by the next whole cycle")
    func aPublicationCutShortIsPublishedAgain() async {
        let published = Published()
        let log = await Self.runBackgroundLoop(
            ticks: 2,
            projectInfo: { call in call == 1 ? .success(Self.projectJSON) : .error("unreadable") },
            postPoll: { keys, _ in
                published.add(keys)
                return published.all.count > 1
            }
        ) { .notTextEditing }
        #expect(log.count(.project) == 2)
        let batches = published.all
        #expect(batches.count == 2, "published \(batches.count) times, not twice")
        let second = batches.count == 2 ? batches[1] : []
        #expect(second.contains(.project), "the cut-short publication's project key was dropped")
    }

    /// The stop a background cycle hands its publication reads the focus; a refresh's never stops.
    /// Mutation this kills: the background publication given a stop that never answers true.
    @Test("a background publication's stop reads the focus")
    func aBackgroundPublicationsStopReadsTheFocus() async {
        let answers = Published()
        let editing = Counter()
        _ = await Self.runBackgroundLoop(
            ticks: 1,
            postPoll: { _, stop in
                _ = editing.next()
                answers.add(stop() ? [.document] : [])
                return true
            }
        ) {
            // Not editing for the cycle and its publication check; editing once publication began.
            editing.peek() >= 1 ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
        }
        #expect(answers.all.first == [.document], "the stop did not read the focus as editing")
    }

    // MARK: - The help-read guard (after review R3)

    /// A fake AX runtime whose every read is counted by attribute.
    final class AttributeReads: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func bump(_ attribute: String) { lock.withLock { counts[attribute, default: 0] += 1 } }
        func count(_ attribute: String) -> Int { lock.withLock { counts[attribute, default: 0] } }
    }

    private static func countingAXRuntime(_ reads: AttributeReads) -> (AXHelpers.Runtime, AXUIElement) {
        let builder = FakeAXRuntimeBuilder()
        let element = builder.element(7)
        builder.setAttribute(element, kAXHelpAttribute as String, "help")
        builder.setAttribute(element, kAXTitleAttribute as String, "title")
        let runtime = builder.makeAXRuntime(
            attributeValueHandler: { _, attribute in reads.bump(attribute); return nil },
            setAttributeHandler: nil, performActionHandler: nil
        )
        return (runtime, element)
    }

    /// The guard refuses an AXHelp read once its stop answers true, and every one after it without
    /// asking again; other attributes are read as before; with no guard set nothing changes.
    /// Mutation this kills: the guard not consulted by `getAttribute` (the refused read is made).
    @Test("the help-read guard refuses help reads once stopped, and only help reads")
    func theHelpReadGuardRefusesHelpReadsOnceStopped() {
        let reads = AttributeReads()
        let (runtime, element) = Self.countingAXRuntime(reads)
        let asked = Counter()
        let guardian = AXHelpers.HelpReadGuard(stop: { asked.next() >= 2 })
        AXHelpers.HelpReadGuard.$current.withValue(guardian) {
            #expect(AXHelpers.getHelp(element, runtime: runtime) == "help")
            #expect(!guardian.stopped)
            #expect(AXHelpers.getHelp(element, runtime: runtime) == nil)
            #expect(guardian.stopped)
            #expect(AXHelpers.getHelp(element, runtime: runtime) == nil)
            #expect(AXHelpers.getTitle(element, runtime: runtime) == "title")
            let result: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, kAXHelpAttribute as String, runtime: runtime)
            guard case .failure = result else {
                Issue.record("a refused help read answered \(result), not a failure")
                return
            }
        }
        #expect(reads.count(kAXHelpAttribute as String) == 1, "help read \(reads.count(kAXHelpAttribute as String)) times")
        #expect(asked.peek() == 2, "the stop was asked \(asked.peek()) times; once stopped it is not asked again")
        // No guard set: the read is made.
        #expect(AXHelpers.getHelp(element, runtime: runtime) == "help")
        #expect(reads.count(kAXHelpAttribute as String) == 2)
    }

    /// The mixer read reads AXHelp, and a French run lost the rename to one under way. Editing
    /// begins at focus reading 7, inside the mixer read (the check before it is reading 6): its
    /// help read is refused, the mixer section is not written, markers are not read and nothing
    /// is published. The control is the same cycle with no edit. Mutations this kills: no guard
    /// set for the background cycle (the help is read), and the poller writing and going on after
    /// a cut-short read (markers are read, the mixer is written).
    @Test("a mixer read cut short by editing is discarded and the cycle ends")
    func aMixerReadCutShortIsDiscarded() async {
        for editing in [true, false] {
            let reads = AttributeReads()
            let (axRuntime, element) = Self.countingAXRuntime(reads)
            let strip = String(decoding: (try? JSONEncoder().encode(
                [ChannelStripState(trackIndex: 0, volume: -6, pan: 0)])) ?? Data(), as: UTF8.self)
            let cache = StateCache()
            let before = await cache.currentVersion(for: .mixer)
            let published = Published()
            let readings = Counter()
            let log = await Self.runBackgroundLoop(
                ticks: 1, cache: cache,
                mixerState: {
                    _ = AXHelpers.getHelp(element, runtime: axRuntime)
                    return .success(strip)
                },
                postPoll: { keys, _ in published.add(keys); return true }
            ) {
                editing && readings.next() >= 7
                    ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false) : .notTextEditing
            }
            let after = await cache.currentVersion(for: .mixer)
            #expect(log.count(.mixer) == 1)
            if editing {
                #expect(reads.count(kAXHelpAttribute as String) == 0, "the mixer's help was read after editing began")
                #expect(after == before, "the cut-short mixer read was written")
                #expect(log.count(.markers) == 0, "markers were read after the mixer read was cut short")
                #expect(published.all.isEmpty)
            } else {
                #expect(reads.count(kAXHelpAttribute as String) == 1)
                #expect(after != before, "the control's mixer read was not written")
                #expect(log.count(.markers) == 1)
            }
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
