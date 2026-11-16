@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

/// DESIGN §2: per-operation UI invariants, driven from measured window-server and AX values with
/// no Logic.
///
/// Measured values used here:
/// - impl-logic13 B9-cglayers: after `record_sequence` a Logic-owned window at layer 101,
///   234x355 at 1077,98 was left on screen (Logic 13's unlisted display-mode menu).
/// - impl-logic13 A12-focus / B4: focus moved from the `AXGroup 믹서` to an `AXLayoutItem 오디오 1`.
/// - a closing window keeps its id, unnamed, for about 1.3 s.
///
/// NO `#expect(<Bool> == <Bool>)` (#393).
@Suite("DESIGN §2 per-operation UI invariants")
struct QualificationUIInvariantsTests {
    static let logicPID: pid_t = 4242
    static let otherPID: pid_t = 777

    private static func cg(
        pid: pid_t = logicPID, number: Int, layer: Int, x: Double = 0, y: Double = 0,
        width: Double = 800, height: Double = 600, name: String? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowOwnerPID as String: Int(pid),
            kCGWindowNumber as String: number,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height],
        ]
        if let name { row[kCGWindowName as String] = name }
        return row
    }

    /// Distinct AX elements: identity is the element (CFEqual), the fields only describe it.
    private static func element(_ id: Int) -> AXUIElement { AXUIElementCreateApplication(pid_t(50_000 + id)) }

    private static let mixerGroup = QualificationFocusIdentity(
        element: element(1), window: nil, role: "AXGroup", subrole: nil, description: "믹서", windowTitle: "Untitled - 트랙")
    private static let strip = QualificationFocusIdentity(
        element: element(2), window: nil, role: "AXLayoutItem", subrole: nil, description: "오디오 1", windowTitle: "Untitled - 트랙")

    private static func observe(
        _ windows: [[String: Any]] = [],
        ax: [QualificationAXWindowFacts] = [],
        focus: QualificationFocusIdentity? = mixerGroup,
        status: Int32 = 0
    ) -> QualificationUIObservation {
        QualificationUIInvariants.observation(
            cgWindows: windows, logicPID: logicPID, axWindows: ax, focus: focus, focusStatus: status)
    }

    private static var main: [String: Any] { cg(number: 10, layer: 0, name: "Untitled") }

    @Test func aCleanScreenHasNoViolation() {
        let before = Self.observe([Self.main])
        #expect(QualificationUIInvariants.violations(before: before, after: before).isEmpty)
    }

    @Test func theMeasuredLayer101LeakIsAViolation() {
        // B9-cglayers: 234x355 at 1077,98 at the popup-menu layer.
        let leak = Self.cg(number: 93, layer: 101, x: 1077, y: 98, width: 234, height: 355)
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]), after: Self.observe([Self.main, leak]))
        #expect(found.count == 1, "\(found)")
        let leakLine = found.first ?? ""
        #expect(leakLine.contains("logic_menu_layer_101_open"))
        #expect(leakLine.contains("234x355@1077,98"))
    }

    @Test func aPopupMenuLayerWindowOfAnotherProcessIsNotLogics() {
        let foreign = Self.cg(pid: Self.otherPID, number: 94, layer: 101, width: 234, height: 355)
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]), after: Self.observe([Self.main, foreign]))
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aModalPanelLayerWindowIsAViolation() {
        let modal = Self.cg(number: 95, layer: LogicOnScreenWindows.modalPanelLevel, width: 400, height: 200)
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]), after: Self.observe([Self.main, modal]))
        #expect(found.contains { $0.contains("modal_present") }, "\(found)")
    }

    @Test func anAXModalWindowIsAViolationEvenWithoutAModalLayer() {
        let sheet = QualificationAXWindowFacts(element: Self.element(4), title: "Go To Position", subrole: "AXDialog", modal: true)
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]), after: Self.observe([Self.main], ax: [sheet]))
        #expect(found.contains { $0.contains("modal_present(AXModal window \"Go To Position\")") }, "\(found)")
    }

    @Test func aLeftoverPluginEditorWindowIsAViolationNamingIt() {
        let editor = Self.cg(number: 11, layer: 0, width: 520, height: 400, name: "Channel EQ")
        let axEditor = QualificationAXWindowFacts(element: Self.element(5), title: "Channel EQ", subrole: "AXStandardWindow", modal: false)
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]),
            after: Self.observe([Self.main, editor], ax: [axEditor]))
        #expect(found.contains { $0.contains("window_left_open(window 11") && $0.contains("Channel EQ") }, "\(found)")
        #expect(found.contains { $0.contains("window_left_open(AX \"Channel EQ\"") }, "\(found)")
    }

    @Test func aLeftoverMarkerListWindowIsAViolation() {
        let markerList = QualificationAXWindowFacts(element: Self.element(6), title: "마커 목록", subrole: "AXFloatingWindow", modal: false)
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]), after: Self.observe([Self.main], ax: [markerList]))
        #expect(found.contains { $0.contains("window_left_open(AX \"마커 목록\"") }, "\(found)")
    }

    @Test func aCallerOwnedWindowThatWasClosedIsAViolation() {
        let editor = Self.cg(number: 11, layer: 0, width: 520, height: 400, name: "Channel EQ")
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main, editor]), after: Self.observe([Self.main]))
        #expect(found.contains { $0.contains("window_closed(window 11") }, "\(found)")
    }

    @Test func aWindowPresentBeforeAndAfterIsNotALeak() {
        let editor = Self.cg(number: 11, layer: 0, width: 520, height: 400, name: "Channel EQ")
        let before = Self.observe([Self.main, editor])
        #expect(QualificationUIInvariants.violations(before: before, after: before).isEmpty)
    }

    @Test func focusMovingFromTheMixerGroupToAStripIsAViolation() {
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main], focus: Self.mixerGroup),
            after: Self.observe([Self.main], focus: Self.strip))
        #expect(found.count == 1, "\(found)")
        let moveLine = found.first ?? ""
        #expect(moveLine.contains("focus_moved"))
        #expect(moveLine.contains("AXGroup/- \"믹서\""))
        #expect(moveLine.contains("AXLayoutItem/- \"오디오 1\""))
    }

    @Test func focusOnTheSameRoleButAnotherElementIsStillMoved() {
        let other = QualificationFocusIdentity(
            element: Self.element(3), window: nil, role: "AXLayoutItem", subrole: nil, description: "오디오 2", windowTitle: "Untitled - 트랙")
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main], focus: Self.strip),
            after: Self.observe([Self.main], focus: other))
        #expect(found.contains { $0.contains("focus_moved") }, "\(found)")
    }

    @Test func anUnreadableFocusIsAViolationNeverNoFocus() {
        // -25204 is what a fresh Background-session process reads before its first window-server call.
        let found = QualificationUIInvariants.violations(
            before: Self.observe([Self.main]),
            after: Self.observe([Self.main], focus: nil, status: -25204))
        #expect(found.contains { $0.contains("focus_unreadable(AXError -25204)") }, "\(found)")
        let baseline = QualificationUIInvariants.violations(
            before: Self.observe([Self.main], focus: nil, status: -25204),
            after: Self.observe([Self.main]))
        #expect(baseline.contains { $0.contains("focus_baseline_unreadable") }, "\(baseline)")
    }

    // MARK: settle

    private final class Scripted: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [QualificationUIObservation?]
        private(set) var reads = 0
        private(set) var slept: [TimeInterval] = []
        init(_ readings: [QualificationUIObservation?]) { self.readings = readings }
        func next() -> QualificationUIObservation? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return readings.count > 1 ? readings.removeFirst() : readings.first ?? nil
        }
        func sleep(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            slept.append(seconds)
        }
    }

    @Test func aClosingWindowThatKeepsItsIDForAWhileIsNotAPhantomLeak() {
        // Measured: a closing window keeps its id, unnamed, for about 1.3 s.
        let closing = Self.cg(number: 11, layer: 0, width: 520, height: 400)
        let before = Self.observe([Self.main])
        let script = Scripted(
            Array(repeating: Self.observe([Self.main, closing]), count: 13) + [Self.observe([Self.main])])
        let found = QualificationUIInvariants.settledViolations(
            before: before, observe: script.next, sleep: script.sleep)
        #expect(found.isEmpty, "\(found)")
        #expect(script.reads == 14)
        #expect(script.slept.count == 13)
    }

    @Test func aWindowThatNeverClosesIsReportedAfterTheSettleLimit() {
        let stuck = Self.cg(number: 11, layer: 0, width: 520, height: 400, name: "Channel EQ")
        let before = Self.observe([Self.main])
        let script = Scripted([Self.observe([Self.main, stuck])])
        let found = QualificationUIInvariants.settledViolations(
            before: before, observe: script.next, sleep: script.sleep)
        #expect(found.contains { $0.contains("window_left_open(window 11") }, "\(found)")
        // 2.0 s at 0.1 s steps: bounded, not endless.
        #expect(script.slept.count >= 19 && script.slept.count <= 21, "slept \(script.slept.count) times")
    }

    @Test func aCleanFirstReadingDoesNotWait() {
        let before = Self.observe([Self.main])
        let script = Scripted([before])
        let found = QualificationUIInvariants.settledViolations(
            before: before, observe: script.next, sleep: script.sleep)
        #expect(found.isEmpty)
        #expect(script.reads == 1)
        #expect(script.slept.isEmpty)
    }

    @Test func anObservationThatCannotBeTakenIsAViolation() {
        let before = Self.observe([Self.main])
        let found = QualificationUIInvariants.settledViolations(
            before: before, observe: { nil }, sleep: { _ in })
        #expect(found.contains { $0.contains("observation_unavailable") }, "\(found)")
    }
}
