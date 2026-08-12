@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue #538 — modal sheet witness")
struct Issue538ModalWitnessTests {

    @Test("a listed AX sheet is reported present")
    func listedSheetIsPresent() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        let sheet = builder.element(3)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(window, "AXSheets", [sheet])
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.mainWindowSheetWitnessObservation(runtime: runtime)

        #expect(
            observed == .present,
            "Mutation caught: remove the sheet from AXSheets; the witness must stop reporting present."
        )
    }

    @Test("a fully readable empty main-window tree is reported gone")
    func emptyTreeIsGone() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.mainWindowSheetWitnessObservation(runtime: runtime)

        #expect(
            observed == .gone,
            "Mutation caught: add an AXSheet child; a readable tree with a sheet must not report gone."
        )
    }

    @Test("an unavailable app root is unreadable, never gone")
    func unavailableAppRootIsUnreadable() {
        let builder = FakeAXRuntimeBuilder()
        let runtime = builder.makeLogicRuntime(
            pid: nil,
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.mainWindowSheetWitnessObservation(runtime: runtime)

        #expect(
            observed == .unreadable(.appRootUnavailable),
            "Mutation caught: return an AX application PID; the app-root failure category must change."
        )
    }

    @Test("a failed main-window read is unreadable with its own stage")
    func mainWindowReadFailureIsNamed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let error = AXHelpers.AXStatusError(raw: -25205)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXMainWindowAttribute as String) else {
                    return nil
                }
                return .failure(error)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.mainWindowSheetWitnessObservation(runtime: runtime)

        #expect(
            observed == .unreadable(.mainWindow(error)),
            "Mutation caught: flatten the main-window failure to nil; that would incorrectly report gone."
        )
    }

    @Test("a failed sheets or children read is unreadable with its own stage")
    func sheetTreeReadFailureIsNamed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        let error = AXHelpers.AXStatusError(raw: -25201)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                return .failure(error)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.mainWindowSheetWitnessObservation(runtime: runtime)

        #expect(
            observed == .unreadable(.childrenOrSheets(error)),
            "Mutation caught: convert the children failure into an empty array; that would incorrectly report gone."
        )
    }

    @Test("every poll is reported until a positively observed close")
    func pollingReportsPresentThenGone() async {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1)
        let window = builder.element(2)
        let sheet = builder.element(3)
        let reads = LockedCounter()
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                if reads.next() == 1 {
                    return .success([sheet] as AnyObject)
                }
                return .success(nil)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let polls = await AccessibilityChannel.pollMainWindowSheetWitness(
            runtime: runtime,
            observationAttempts: 4,
            observationDelayNanoseconds: 0
        )

        #expect(
            polls.map(\.observation) == [.present, .gone],
            "Mutation caught: flatten an unreadable poll to gone or keep polling after the observed close."
        )
        #expect(
            polls.map(\.index) == [1, 2],
            "Mutation caught: omit the initial present poll or misnumber the close poll."
        )
    }

    @Test("a witnessed mandatory-sheet close is the only successful reconciliation")
    func witnessedSheetCloseSetsPerformed() async {
        let fixture = makeMandatorySheetFixture(postActionWitness: .gone)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            outcome.performed,
            "Mutation caught: return the AppleScript success before the gone witness; an observed close must set performed."
        )
        #expect(
            outcome.witnessSummary?.observedGone == true,
            "Mutation caught: drop the gone observation from the summary; performed would no longer have witness evidence."
        )
    }

    @Test("a sheet still present after Create is not performed")
    func persistentSheetDoesNotSetPerformed() async {
        let fixture = makeMandatorySheetFixture(postActionWitness: .stillPresent)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            !outcome.performed,
            "Mutation caught: trust executeAppleScript(...).isSuccess while the sheet witness still reports present."
        )
        #expect(
            outcome.sheetWitness.map(\.observation) == [.present],
            "Mutation caught: turn the still-present sheet into gone; the negative performed path must remain observable."
        )
    }

    @Test("a genuine AX read failure is not performed")
    func unreadableSheetDoesNotSetPerformed() async {
        let fixture = makeMandatorySheetFixture(postActionWitness: .cannotComplete)
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)

        let outcome = await AccessibilityChannel.reconcileAfterMutation(
            isDeleteContext: false,
            runtime: fixture.runtime,
            witnessAttempts: 1,
            witnessDelayNanoseconds: 0
        )

        #expect(
            !outcome.performed,
            "Mutation caught: flatten cannot-complete into gone; a genuinely unreadable sheet must not be performed."
        )
        #expect(
            outcome.sheetWitness.map(\.observation) == [.unreadable(.childrenOrSheets(cannotComplete))],
            "Mutation caught: reclassify cannot-complete as an absence answer; only -25205/-25212 get that treatment."
        )
    }

    @Test("AXSheets unsupported and childless noValue are absence answers")
    func structuralAbsenceStatusesAreGone() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(30)
        let window = builder.element(31)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.mainWindowSheetWitnessObservation(runtime: runtime)

        #expect(
            observed == .gone,
            "Mutation caught: classify AXSheets -25205 or childless AXChildren -25212 as unreadable; both are structural absence answers."
        )
    }

    @Test("last-track State A gate requires a performed mandatory reconciliation")
    func unperformedMandatoryReconciliationBlocksDeletionStateA() {
        let cannotCertify = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: true,
            mandatoryNewTrackReconciliationObserved: true,
            mandatoryNewTrackReconciliationPerformed: false
        )
        let canCertifyAfterWitness = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: true,
            mandatoryNewTrackReconciliationObserved: true,
            mandatoryNewTrackReconciliationPerformed: true
        )

        #expect(
            !cannotCertify,
            "Mutation caught: ignore the unperformed mandatory reconciliation and let the deletion count certify State A."
        )
        #expect(
            canCertifyAfterWitness,
            "Mutation caught: make the State A gate reject a confirmed reconciliation; the guard must be specific to unperformed recovery."
        )
    }
}

private enum MandatorySheetPostActionWitness: Equatable {
    case gone
    case stillPresent
    case cannotComplete
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func makeMandatorySheetFixture(
    postActionWitness: MandatorySheetPostActionWitness
) -> (runtime: AXLogicProElements.Runtime, actionIssued: LockedFlag) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(10)
    let window = builder.element(11)
    let sheet = builder.element(12)
    let create = builder.element(13)
    let cancel = builder.element(14)
    let actionIssued = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(create, kAXTitleAttribute as String, "Create")
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
    builder.setChildren(sheet, [create, cancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            if actionIssued.get(), postActionWitness == .gone {
                return .some([] as NSArray)
            }
            return .some([sheet] as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            guard actionIssued.get(),
                  postActionWitness == .cannotComplete,
                  CFEqual(element, window),
                  attribute == "AXSheets"
            else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: nil,
        executeAppleScript: { _ in
            actionIssued.set()
            return .success("clicked")
        }
    )
    return (runtime, actionIssued)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
