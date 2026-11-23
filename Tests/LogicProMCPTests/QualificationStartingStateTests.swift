@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

/// The live gate's starting state, driven from values measured on Logic 13 (Korean UI):
/// - the keyboard focus that makes the track writes work is `AXGroup 트랙` inside the project window
///   `QualFixtureR11 - 트랙`; the Mixer group `AXGroup 믹서` and a strip `AXLayoutItem` do not;
/// - a write acts only on the selected track, so exactly one track must be selected;
/// - a tooltip is a layer-103 window whose role reads AXHelpTag.
///
/// One test per unmet condition, plus the canonical state that has none. NO
/// `#expect(<Bool> == <Bool>)` (#393).
@Suite("Live gate starting state")
struct QualificationStartingStateTests {
    private static let logicPID: pid_t = 4242
    private static func element(_ id: Int) -> AXUIElement { AXUIElementCreateApplication(pid_t(60_000 + id)) }

    private static let project = element(10)
    private static let projectTitle = "QualFixtureR11 - 트랙"

    private static func focus(
        role: String = "AXGroup", description: String? = "트랙", in window: AXUIElement? = project,
        id: Int = 11
    ) -> QualificationFocusIdentity {
        QualificationFocusIdentity(
            element: element(id), window: window, role: role, subrole: nil,
            description: description, windowTitle: projectTitle)
    }

    private static let projectWindow = QualificationAXWindowFacts(
        element: project, title: projectTitle, subrole: "AXStandardWindow", modal: false)

    private static func ui(
        cg: [[String: Any]] = [],
        ax: [QualificationAXWindowFacts] = [projectWindow],
        axRead: Bool = true,
        focus: QualificationFocusIdentity? = focus(),
        focusStatus: Int32 = 0,
        unreadable: [String] = []
    ) -> QualificationUIObservation {
        QualificationUIInvariants.observation(
            cgWindows: cg, logicPID: logicPID, axWindows: ax, axWindowsRead: axRead,
            focus: focus, focusStatus: focusStatus, unreadable: unreadable)
    }

    private static func cg(number: Int, layer: Int, width: Double = 200, height: Double = 100) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: Int(logicPID),
            kCGWindowNumber as String: number,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": 10.0, "Y": 20.0, "Width": width, "Height": height],
        ]
    }

    private static func region(kind: String = "midi") -> SelectedRegionEventListReader.RegionIdentity {
        .init(name: "MIDI 리전", trackIndex: 2, startBar: 1, endBar: 2, kind: kind)
    }

    private static let oneMidiRegion = SelectedRegionEventListReader.SelectionObservation(
        scopeComplete: true, selected: [region()])

    private static func facts(
        owns: Bool? = true, main: AXUIElement? = project,
        regions: SelectedRegionEventListReader.SelectionObservation? = oneMidiRegion,
        unreadable: [String] = []
    ) -> QualificationStartingWindowFacts {
        QualificationStartingWindowFacts(
            logicOwnsKeyboard: owns, mainWindow: main, selectedRegions: regions, unreadable: unreadable)
    }

    private static func readings(
        ui: QualificationUIObservation? = ui(),
        facts: QualificationStartingWindowFacts? = facts(),
        selected: Int? = 1,
        stopped: Bool? = true
    ) -> QualificationStartingStateReadings {
        QualificationStartingStateReadings(
            ui: ui, windowFacts: facts, selectedTrackCount: selected, transportStopped: stopped)
    }

    private static func unmet(_ readings: QualificationStartingStateReadings) -> [String] {
        QualificationStartingState.unmetConditions(readings)
    }

    /// The condition names that appear in `lines`.
    private static func named(_ lines: [String], _ condition: String) -> Bool {
        lines.contains { $0.hasPrefix("\(QualificationStartingState.unmetPrefix) \(condition)(") }
    }

    // MARK: the canonical state

    @Test func theCanonicalStateHasNoUnmetCondition() {
        let found = Self.unmet(Self.readings())
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aReadTooltipDoesNotMakeTheStateUnmet() {
        let tip = QualificationAXWindowFacts(
            element: Self.element(20), title: nil, subrole: nil, modal: nil, helpTag: true,
            frame: CGRect(x: 979, y: 88, width: 32, height: 19))
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [Self.projectWindow, tip])))
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aTooltipWhoseRoleDidNotReadIsStillAnExtraWindow() {
        let unread = QualificationAXWindowFacts(
            element: Self.element(21), title: nil, subrole: nil, modal: nil, helpTag: false,
            frame: CGRect(x: 979, y: 88, width: 32, height: 19))
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [Self.projectWindow, unread])))
        #expect(Self.named(found, "extra_window_open"), "\(found)")
    }

    @Test func theTrackGroupIsRecognisedInEveryLocaleLabel() {
        for label in AXLocalePolicy.arrangeWindowTitleSuffix.labels {
            let found = Self.unmet(Self.readings(ui: Self.ui(focus: Self.focus(description: label))))
            #expect(found.isEmpty, "\(label): \(found)")
        }
    }

    // MARK: one test per unmet condition

    @Test func noSelectedRegionIsUnmet() {
        let none = SelectedRegionEventListReader.SelectionObservation(scopeComplete: true, selected: [])
        let found = Self.unmet(Self.readings(facts: Self.facts(regions: none)))
        #expect(Self.named(found, "selected_region_count"), "\(found)")
    }

    @Test func twoSelectedRegionsAreUnmet() {
        let two = SelectedRegionEventListReader.SelectionObservation(
            scopeComplete: true, selected: [Self.region(), Self.region()])
        let found = Self.unmet(Self.readings(facts: Self.facts(regions: two)))
        #expect(Self.named(found, "selected_region_count"), "\(found)")
    }

    @Test func aSelectedRegionThatIsNotMidiIsUnmet() {
        let audio = SelectedRegionEventListReader.SelectionObservation(
            scopeComplete: true, selected: [Self.region(kind: "audio")])
        let found = Self.unmet(Self.readings(facts: Self.facts(regions: audio)))
        #expect(Self.named(found, "selected_region_not_midi"), "\(found)")
    }

    @Test func anIncompleteRegionScopeIsUnmetEvenWithOneSelected() {
        let partial = SelectedRegionEventListReader.SelectionObservation(
            scopeComplete: false, selected: [Self.region()])
        let found = Self.unmet(Self.readings(facts: Self.facts(regions: partial)))
        #expect(Self.named(found, "selected_region_scope_incomplete"), "\(found)")
    }

    @Test func anUnreadRegionSelectionIsUnmetNotEmpty() {
        let found = Self.unmet(Self.readings(facts: Self.facts(regions: nil)))
        #expect(Self.named(found, "selected_region_unreadable"), "\(found)")
        #expect(!Self.named(found, "selected_region_count"), "\(found)")
    }

    @Test func aLayer101MenuIsUnmet() {
        let found = Self.unmet(Self.readings(ui: Self.ui(cg: [Self.cg(number: 93, layer: 101, width: 234, height: 355)])))
        #expect(Self.named(found, "layer_101_menu_open"), "\(found)")
    }

    @Test func aModalPanelWindowIsUnmet() {
        let found = Self.unmet(Self.readings(
            ui: Self.ui(cg: [Self.cg(number: 95, layer: LogicOnScreenWindows.modalPanelLevel)])))
        #expect(Self.named(found, "modal_present"), "\(found)")
    }

    @Test func anAXModalWindowIsUnmet() {
        let sheet = QualificationAXWindowFacts(
            element: Self.element(22), title: "Go To Position", subrole: "AXDialog", modal: true)
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [Self.projectWindow, sheet])))
        #expect(Self.named(found, "modal_present"), "\(found)")
    }

    @Test func aLeftOverPlugInEditorIsUnmet() {
        let editor = QualificationAXWindowFacts(
            element: Self.element(23), title: "Channel EQ", subrole: "AXStandardWindow", modal: false)
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [Self.projectWindow, editor])))
        #expect(Self.named(found, "extra_window_open"), "\(found)")
        #expect(found.contains { $0.contains("Channel EQ") }, "\(found)")
    }

    @Test func aLeftOverMarkerListIsUnmet() {
        let markers = QualificationAXWindowFacts(
            element: Self.element(24), title: "마커 목록", subrole: "AXStandardWindow", modal: false)
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [Self.projectWindow, markers])))
        #expect(Self.named(found, "extra_window_open"), "\(found)")
    }

    @Test func noProjectWindowIsUnmet() {
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [])))
        #expect(Self.named(found, "no_project_window"), "\(found)")
    }

    @Test func logicNotOwningTheKeyboardIsUnmet() {
        let found = Self.unmet(Self.readings(facts: Self.facts(owns: false)))
        #expect(Self.named(found, "main_window_not_frontmost"), "\(found)")
    }

    @Test func focusInAWindowThatIsNotTheMainWindowIsUnmet() {
        let found = Self.unmet(Self.readings(
            ui: Self.ui(focus: Self.focus(in: Self.element(30)))))
        #expect(Self.named(found, "main_window_not_frontmost"), "\(found)")
    }

    @Test func aFocusedElementWithNoWindowIsUnmet() {
        let found = Self.unmet(Self.readings(ui: Self.ui(focus: Self.focus(in: nil))))
        #expect(Self.named(found, "main_window_not_frontmost"), "\(found)")
    }

    @Test func noMainWindowIsUnmet() {
        let found = Self.unmet(Self.readings(facts: Self.facts(main: nil)))
        #expect(Self.named(found, "main_window_not_frontmost"), "\(found)")
    }

    @Test func focusOnTheMixerGroupIsUnmet() {
        // The measured focus the gate started from: `AXGroup 믹서`.
        let found = Self.unmet(Self.readings(ui: Self.ui(focus: Self.focus(description: "믹서"))))
        #expect(Self.named(found, "focus_not_on_track_group"), "\(found)")
    }

    @Test func focusOnAChannelStripIsUnmet() {
        let found = Self.unmet(Self.readings(
            ui: Self.ui(focus: Self.focus(role: "AXLayoutItem", description: "오디오 1"))))
        #expect(Self.named(found, "focus_not_on_track_group"), "\(found)")
    }

    @Test func aTextFieldCarryingTheTrackLabelIsNotTheTrackGroup() {
        let found = Self.unmet(Self.readings(
            ui: Self.ui(focus: Self.focus(role: "AXTextField", description: "트랙"))))
        #expect(Self.named(found, "focus_not_on_track_group"), "\(found)")
    }

    @Test func focusOnTheBareWindowIsUnmet() {
        let found = Self.unmet(Self.readings(
            ui: Self.ui(focus: Self.focus(role: "AXWindow", description: nil))))
        #expect(Self.named(found, "focus_not_on_track_group"), "\(found)")
    }

    @Test func noSelectedTrackIsUnmet() {
        let found = Self.unmet(Self.readings(selected: 0))
        #expect(Self.named(found, "selected_track_count"), "\(found)")
        #expect(found.contains { $0.contains("0 tracks are selected") }, "\(found)")
    }

    @Test func twoSelectedTracksAreUnmet() {
        let found = Self.unmet(Self.readings(selected: 2))
        #expect(Self.named(found, "selected_track_count"), "\(found)")
        #expect(found.contains { $0.contains("2 tracks are selected") }, "\(found)")
    }

    @Test func anUnreadableSelectionIsUnmet() {
        let found = Self.unmet(Self.readings(selected: nil))
        #expect(Self.named(found, "selected_track_unreadable"), "\(found)")
    }

    @Test func aPlayingTransportIsUnmet() {
        let found = Self.unmet(Self.readings(stopped: false))
        #expect(Self.named(found, "transport_not_stopped"), "\(found)")
    }

    @Test func anUnreadableTransportIsUnmet() {
        let found = Self.unmet(Self.readings(stopped: nil))
        #expect(Self.named(found, "transport_unreadable"), "\(found)")
    }

    // MARK: an unreadable read is never an empty one

    @Test func noObservationIsUnmet() {
        let found = Self.unmet(Self.readings(ui: nil))
        #expect(Self.named(found, "ui_unreadable"), "\(found)")
    }

    @Test func anObservationNamingAMissingReadIsUnmet() {
        let found = Self.unmet(Self.readings(ui: Self.ui(unreadable: ["window \"x\" AXModal AXError -25204"])))
        #expect(Self.named(found, "ui_unreadable"), "\(found)")
    }

    @Test func anUnreadAXWindowListIsUnmet() {
        let found = Self.unmet(Self.readings(ui: Self.ui(ax: [], axRead: false)))
        #expect(Self.named(found, "ui_unreadable"), "\(found)")
    }

    @Test func anUnreadFocusIsUnmet() {
        let found = Self.unmet(Self.readings(ui: Self.ui(focus: nil, focusStatus: -25204)))
        #expect(Self.named(found, "focus_unreadable"), "\(found)")
    }

    @Test func missingWindowFactsAreUnmet() {
        let found = Self.unmet(Self.readings(facts: nil))
        #expect(Self.named(found, "ui_unreadable"), "\(found)")
    }

    @Test func windowFactsThatNameAMissingReadAreUnmet() {
        let found = Self.unmet(Self.readings(
            facts: Self.facts(owns: nil, main: nil, unreadable: ["AXMainWindow AXError -25204"])))
        #expect(Self.named(found, "ui_unreadable"), "\(found)")
    }

    @Test func everyUnmetConditionIsNamedAtOnce() {
        let found = Self.unmet(Self.readings(
            ui: Self.ui(focus: Self.focus(description: "믹서")), selected: 2, stopped: false))
        #expect(Self.named(found, "focus_not_on_track_group"), "\(found)")
        #expect(Self.named(found, "selected_track_count"), "\(found)")
        #expect(Self.named(found, "transport_not_stopped"), "\(found)")
        #expect(found.count == 3, "\(found)")
    }

    // MARK: the selected track in a logic://tracks body

    private static func tracks(_ selected: [Bool?]) -> Data {
        let rows: [[String: Any]] = selected.enumerated().map { index, flag in
            var row: [String: Any] = ["id": index, "name": "Track \(index)", "track_ref": "trk_\(index)"]
            if let flag { row["isSelected"] = flag }
            return row
        }
        return try! JSONSerialization.data(withJSONObject: ["data": rows])
    }

    @Test func theMeasuredSelectionIsTheThirdRow() {
        // R12 s1: 오디오 1, 오디오 2, Deluxe Classic (selected), Studio Grand.
        let body = Self.tracks([false, false, true, false])
        #expect(QualificationStartingState.selectedTrackCount(tracksResource: body) == 1)
        #expect(QualificationStartingState.selectedTrackIndex(tracksResource: body) == 2)
    }

    @Test func noSelectedRowGivesNoIndex() {
        let body = Self.tracks([false, false])
        #expect(QualificationStartingState.selectedTrackCount(tracksResource: body) == 0)
        #expect(QualificationStartingState.selectedTrackIndex(tracksResource: body) == nil)
    }

    @Test func twoSelectedRowsGiveNoIndex() {
        let body = Self.tracks([true, false, true])
        #expect(QualificationStartingState.selectedTrackCount(tracksResource: body) == 2)
        #expect(QualificationStartingState.selectedTrackIndex(tracksResource: body) == nil)
    }

    @Test func aRowThatDoesNotStateItsSelectionMakesTheReadUnreadable() {
        let body = Self.tracks([false, nil, true])
        #expect(QualificationStartingState.selectedTrackCount(tracksResource: body) == nil)
        #expect(QualificationStartingState.selectedTrackIndex(tracksResource: body) == nil)
    }

    @Test func anEmptyOrMalformedBodyIsUnreadable() {
        #expect(QualificationStartingState.selectedTrackCount(tracksResource: Self.tracks([])) == nil)
        #expect(QualificationStartingState.selectedTrackCount(tracksResource: Data("not json".utf8)) == nil)
    }

    // MARK: the transport refuses to start

    private static let debugExecutableURL = ProcessInfo.processInfo.environment[
        "LPMCP_TEST_DEBUG_SERVER_EXECUTABLE"
    ].map { URL(fileURLWithPath: $0) } ?? URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true
    ).appendingPathComponent(".build/debug/LogicProMCP")

    private static let driveEnabled = FileManager.default.isExecutableFile(atPath: debugExecutableURL.path)

    private func transport(
        observation: QualificationUIObservation, withStartingState: Bool
    ) -> QualificationTransport {
        let provider: (@Sendable () -> QualificationStartingWindowFacts)? =
            withStartingState ? { @Sendable in Self.facts() } : nil
        return QualificationTransport(
            uiObserver: { observation }, startingWindowFacts: provider,
            requestTimeout: 30, shutdownGrace: 1)
    }

    private func request() -> QualificationDriveRequest {
        .init(
            executableURL: Self.debugExecutableURL, environment: ProcessInfo.processInfo.environment,
            expectedOperationCount: OperationRegistry.specs.count, operations: [])
    }

    @Test(.enabled(if: QualificationStartingStateTests.driveEnabled,
                   "Requires `swift build` (debug) before driving the real server."),
          .timeLimit(.minutes(2)))
    func theTransportRefusesToDriveFromAFocusOnTheMixerGroup() {
        let unmetFocus = Self.ui(focus: Self.focus(description: "믹서"))
        do {
            _ = try transport(observation: unmetFocus, withStartingState: true).drive(request())
            Issue.record("drive started although the keyboard focus was on the Mixer group")
        } catch {
            #expect("\(error)".contains("starting_state_unmet: focus_not_on_track_group"), "\(error)")
        }
    }

    @Test(.enabled(if: QualificationStartingStateTests.driveEnabled,
                   "Requires `swift build` (debug) before driving the real server."),
          .timeLimit(.minutes(2)))
    func theTransportRefusesToDriveWithALeakedMenuAndNamesIt() {
        let leak = Self.ui(cg: [Self.cg(number: 93, layer: 101, width: 234, height: 355)])
        do {
            _ = try transport(observation: leak, withStartingState: true).drive(request())
            Issue.record("drive started although a layer-101 menu was on screen")
        } catch {
            #expect("\(error)".contains("starting_state_unmet: layer_101_menu_open"), "\(error)")
        }
    }

    @Test(.enabled(if: QualificationStartingStateTests.driveEnabled,
                   "Requires `swift build` (debug) before driving the real server."),
          .timeLimit(.minutes(2)))
    func aTransportBuiltWithoutAStartingStateChecksNothingAboutTheMachine() throws {
        let unmetFocus = Self.ui(focus: Self.focus(description: "믹서"))
        let result = try transport(observation: unmetFocus, withStartingState: false).drive(request())
        #expect(result.handshakeOK)
    }
}
