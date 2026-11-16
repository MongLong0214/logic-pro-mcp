@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import LogicProMCP

/// The live UI-invariant reader (`QualificationUIInvariants.observeLogic`) driven through a fake AX
/// runtime, so the reads themselves (not hand-built observations) are under test.
///
/// Measured values used here (Logic Pro 13.0 7801, ko, Aqua session): AXWindows reads one AXStandardWindow "NativeLogic13-9995.logicx - 트랙" whose AXModal
/// reads false; AXFocusedUIElement reads an AXGroup "트랙" whose AXWindow is that main window; two
/// successive reads of the focused element and of AXWindows are CFEqual.
/// -25204 (cannotComplete) is what a fresh Background-session process reads; -25212 is noValue.
///
/// Two defects these tests pin: a failed read became an empty window list or a nil modal flag, so the
/// gate saw zero violations; and focus identity compared descriptive fields only.
///
/// NO `#expect(<Bool> == <Bool>)` (#393).
@Suite("UI-invariant reader: unreadable is not absent, identity is the element")
struct QualificationUIObserverTests {
    static let pid: pid_t = 4242
    static let mainTitle = "NativeLogic13-9995.logicx - 트랙"

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var failing: [String: Int32] = [:]
        func key(_ builder: FakeAXRuntimeBuilder, _ element: AXUIElement, _ attribute: String) -> String {
            "\(builder.elementID(element))/\(attribute)"
        }
        func set(_ key: String, _ status: Int32?) {
            lock.lock(); defer { lock.unlock() }
            failing[key] = status
        }
        func status(_ key: String) -> Int32? {
            lock.lock(); defer { lock.unlock() }
            return failing[key]
        }
    }

    private struct Fixture {
        let b = FakeAXRuntimeBuilder()
        let failures = Failures()
        let app: AXUIElement, main: AXUIElement, focusA: AXUIElement, focusB: AXUIElement

        init() {
            app = b.element(0); main = b.element(1); focusA = b.element(2); focusB = b.element(3)
            b.setRole(main, kAXWindowRole as String)
            b.setAttribute(main, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
            b.setAttribute(main, kAXTitleAttribute as String, QualificationUIObserverTests.mainTitle)
            b.setAttribute(main, "AXModal", false)
            b.setAttribute(app, kAXWindowsAttribute as String, [main])
            // Two distinct controls Logic describes identically (same role, no description, same window).
            for control in [focusA, focusB] {
                b.setRole(control, kAXGroupRole as String)
                b.setAttribute(control, kAXDescriptionAttribute as String, "트랙")
                b.setAttribute(control, kAXWindowAttribute as String, main)
            }
            b.setAttribute(app, kAXFocusedUIElementAttribute as String, focusA)
        }

        func fail(_ element: AXUIElement, _ attribute: String, _ status: Int32?) {
            failures.set(failures.key(b, element, attribute), status)
        }

        var runtime: AXHelpers.Runtime {
            let b = b, failures = failures, app = app
            return b.makeAXRuntime(
                appElement: app,
                attributeValueHandler: { element, attribute -> AnyObject?? in
                    guard failures.status(failures.key(b, element, attribute)) != nil else { return nil }
                    return Optional<AnyObject?>.some(nil)
                },
                attributeValueResultHandler: { element, attribute in
                    failures.status(failures.key(b, element, attribute)).map {
                        .failure(AXHelpers.AXStatusError(raw: $0))
                    }
                },
                setAttributeHandler: nil, performActionHandler: nil)
        }

        func observe() -> QualificationUIObservation {
            QualificationUIInvariants.observeLogic(pid: QualificationUIObserverTests.pid, cgWindows: [], runtime: runtime)
        }
    }

    private static let cannotComplete = Int32(AXError.cannotComplete.rawValue)
    private static let noValue = Int32(AXError.noValue.rawValue)

    private static func unreadable(_ found: [String]) -> Bool {
        found.contains { $0.contains("ui_invariant_unreadable") }
    }

    // MARK: a missing lookup names itself

    @Test func aMissingLogicProcessIsAnUnreadableObservationThatNamesTheLookup() {
        let f = Fixture()
        let missing = QualificationUIInvariants.observeLogic(
            runningPID: { nil }, windowList: { [] }, runtime: f.runtime)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: missing)
        #expect(found.contains { $0.contains("running-application lookup") }, "\(found)")
        #expect(Self.unreadable(found), "\(found)")
    }

    @Test func aMissingWindowListIsAnUnreadableObservationThatNamesTheList() {
        let f = Fixture()
        let missing = QualificationUIInvariants.observeLogic(
            runningPID: { QualificationUIObserverTests.pid }, windowList: { nil }, runtime: f.runtime)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: missing)
        #expect(found.contains { $0.contains("CGWindowListCopyWindowInfo") }, "\(found)")
    }

    // MARK: controls: the fixture itself reads clean

    @Test func aReadableUnchangedScreenHasNoViolation() {
        let f = Fixture()
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(found.isEmpty, "\(found)")
    }

    @Test func theSameFocusedElementReadTwiceIsNotMoved() {
        let f = Fixture()
        let before = f.observe()
        let after = f.observe()
        #expect(!QualificationUIInvariants.violations(before: before, after: after).contains { $0.contains("focus_moved") })
    }

    // MARK: a failed read is not an empty answer

    @Test func aWindowListThatCannotBeReadBeforeAndAfterFailsAsUnreadable() {
        let f = Fixture()
        f.fail(f.app, kAXWindowsAttribute as String, Self.cannotComplete)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(Self.unreadable(found), "\(found)")
    }

    @Test func aModalFlagThatCannotBeReadBeforeAndAfterFailsAsUnreadable() {
        let f = Fixture()
        f.fail(f.main, "AXModal", Self.cannotComplete)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(Self.unreadable(found), "\(found)")
    }

    @Test func aModalFlagAnsweringNoValueIsNotReadAsNotModal() {
        // 0c4ada89: an entry nothing identifies once certified State A while a real blocker was up.
        let f = Fixture()
        f.fail(f.main, "AXModal", Self.noValue)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(Self.unreadable(found), "\(found)")
    }

    /// After a Logic 13 insert: AXWindows listed a tooltip whose role read
    /// AXHelpTag, AXTitle -25212, AXSubrole -25205, AXModal -25205 (CG layer 103).
    private static func addHelpTag(_ f: Fixture, roleStatus: Int32? = nil) -> AXUIElement {
        let tag = f.b.element(7)
        f.b.setRole(tag, kAXHelpTagRole as String)
        f.fail(tag, kAXTitleAttribute as String, Self.noValue)
        f.fail(tag, kAXSubroleAttribute as String, Int32(AXError.attributeUnsupported.rawValue))
        f.fail(tag, "AXModal", Int32(AXError.attributeUnsupported.rawValue))
        if let roleStatus { f.fail(tag, kAXRoleAttribute as String, roleStatus) }
        f.b.setAttribute(f.app, kAXWindowsAttribute as String, [tag, f.main])
        return tag
    }

    @Test func aTooltipWhoseRoleReadsAsHelpTagIsNotAnUnreadableModalFlag() {
        let f = Fixture()
        _ = Self.addHelpTag(f)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aTooltipWhoseRoleCannotBeReadKeepsItsModalFlagUnreadable() {
        let f = Fixture()
        _ = Self.addHelpTag(f, roleStatus: Self.cannotComplete)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(Self.unreadable(found), "\(found)")
    }

    @Test func aTooltipThatAppearsDuringTheOperationIsStillAWindowLeftOpen() {
        let f = Fixture()
        let before = f.observe()
        _ = Self.addHelpTag(f)
        let found = QualificationUIInvariants.violations(before: before, after: f.observe())
        #expect(found.contains { $0.contains("window_left_open(AX") }, "\(found)")
    }

    @Test func aModalFlagThatFailsOnlyAfterTheOperationIsNamedUnreadable() {
        let f = Fixture()
        let before = f.observe()
        f.fail(f.main, "AXModal", Self.cannotComplete)
        let found = QualificationUIInvariants.violations(before: before, after: f.observe())
        #expect(found.contains { $0.contains("ui_invariant_unreadable(after") }, "\(found)")
    }

    @Test func aWindowListThatFailsOnlyAtTheBaselineIsNamedUnreadable() {
        let f = Fixture()
        f.fail(f.app, kAXWindowsAttribute as String, Self.cannotComplete)
        let before = f.observe()
        f.fail(f.app, kAXWindowsAttribute as String, nil)
        let found = QualificationUIInvariants.violations(before: before, after: f.observe())
        #expect(found.contains { $0.contains("ui_invariant_unreadable(baseline") }, "\(found)")
        // Nothing was read at the baseline, so nothing may be claimed to have opened since.
        #expect(!found.contains { $0.contains("window_left_open(AX") }, "\(found)")
    }

    @Test func aWindowTitleThatCannotBeReadFailsAsUnreadable() {
        let f = Fixture()
        f.fail(f.main, kAXTitleAttribute as String, Self.cannotComplete)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(Self.unreadable(found), "\(found)")
    }

    @Test func theFocusedElementsWindowThatCannotBeReadFailsAsUnreadable() {
        let f = Fixture()
        f.fail(f.focusA, kAXWindowAttribute as String, Self.cannotComplete)
        let found = QualificationUIInvariants.violations(before: f.observe(), after: f.observe())
        #expect(Self.unreadable(found), "\(found)")
    }

    @Test func aPersistentlyUnreadableWindowListNeverSettlesToClean() {
        let f = Fixture()
        f.fail(f.app, kAXWindowsAttribute as String, Self.cannotComplete)
        let before = f.observe()
        let found = QualificationUIInvariants.settledViolations(
            before: before, observe: { f.observe() }, sleep: { _ in })
        #expect(Self.unreadable(found), "\(found)")
    }

    // MARK: identity is the AX element, not its description

    @Test func focusMovingBetweenTwoIdenticallyDescribedControlsIsMoved() {
        let f = Fixture()
        let before = f.observe()
        f.b.setAttribute(f.app, kAXFocusedUIElementAttribute as String, f.focusB)
        let found = QualificationUIInvariants.violations(before: before, after: f.observe())
        #expect(found.contains { $0.contains("focus_moved") }, "\(found)")
    }

    @Test func focusOnTheSameElementInAnotherWindowIsMoved() {
        let f = Fixture()
        let before = f.observe()
        let other = f.b.element(9)
        f.b.setRole(other, kAXWindowRole as String)
        f.b.setAttribute(other, kAXTitleAttribute as String, Self.mainTitle)
        f.b.setAttribute(f.focusA, kAXWindowAttribute as String, other)
        let found = QualificationUIInvariants.violations(before: before, after: f.observe())
        #expect(found.contains { $0.contains("focus_moved") }, "\(found)")
    }

    @Test func aWindowReplacedByAnIdenticallyDescribedWindowIsAViolation() {
        // Same title, subrole and modal flag, different AX element: one window closed and another opened.
        let f = Fixture()
        let before = f.observe()
        let replacement = f.b.element(8)
        f.b.setRole(replacement, kAXWindowRole as String)
        f.b.setAttribute(replacement, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        f.b.setAttribute(replacement, kAXTitleAttribute as String, Self.mainTitle)
        f.b.setAttribute(replacement, "AXModal", false)
        f.b.setAttribute(f.app, kAXWindowsAttribute as String, [replacement])
        let found = QualificationUIInvariants.violations(before: before, after: f.observe())
        #expect(found.contains { $0.contains("window_left_open(AX") }, "\(found)")
        #expect(found.contains { $0.contains("window_closed(AX") }, "\(found)")
    }
}
