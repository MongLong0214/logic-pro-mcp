@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("Issue #538 — identity-bound modal witness")
struct Issue538ModalWitnessTests {

    @Test("the captured sheet is present while its AX identity remains readable")
    func boundSheetIsPresent() {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(1)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        let runtime = builder.makeLogicRuntime(setAttributeHandler: nil, performActionHandler: nil)

        let observed = AccessibilityChannel.boundSheetWitnessObservation(sheet, runtime: runtime)

        #expect(
            observed == .present,
            "Mutation caught: replace the captured-sheet role read with an unconditional gone result; a readable bound sheet must remain present."
        )
    }

    @Test("invalidUIElement means the captured sheet identity is gone")
    func invalidCapturedSheetIsGone() {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(2)
        let invalid = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(invalid)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundSheetWitnessObservation(sheet, runtime: runtime)

        #expect(
            observed == .gone,
            "Mutation caught: treat invalidUIElement on the captured sheet as unreadable; this status means that exact sheet identity ceased to exist."
        )
    }

    @Test("a non-staleness failure of the captured sheet is unreadable")
    func nonStaleCapturedSheetIsUnreadable() {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(3)
        let cannotComplete = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return .failure(cannotComplete)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let observed = AccessibilityChannel.boundSheetWitnessObservation(sheet, runtime: runtime)

        #expect(
            observed == .unreadable(.sheet(cannotComplete)),
            "Mutation caught: classify cannotComplete on the captured sheet as gone; only invalidUIElement proves this identity disappeared."
        )
    }

    @Test("polling stops only after the bound sheet becomes invalid")
    func pollingReportsPresentThenGone() async {
        let builder = FakeAXRuntimeBuilder()
        let sheet = builder.element(4)
        let reads = LockedCounter()
        let runtime = builder.makeLogicRuntime(
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, sheet), attribute == (kAXRoleAttribute as String) else { return nil }
                return reads.next() == 1
                    ? .success(kAXSheetRole as NSString)
                    : .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let polls = await AccessibilityChannel.pollBoundSheetWitness(
            sheet,
            runtime: runtime,
            observationAttempts: 4,
            observationDelayNanoseconds: 0
        )

        #expect(
            polls.map(\.observation) == [.present, .gone],
            "Mutation caught: keep polling after invalidUIElement or treat a readable captured sheet as gone."
        )
        #expect(
            polls.map(\.index) == [1, 2],
            "Mutation caught: omit the initial bound-sheet poll or misnumber the invalid-element close poll."
        )
    }

    @Test("AXSheets unsupported and childless noValue remain structural absence answers")
    func structuralAbsenceStatusesRemainClean() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(10)
        let window = builder.element(11)
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

        let signals = AccessibilityChannel.readModalSignals(runtime: runtime)

        #expect(
            !signals.sheetPresent,
            "Mutation caught: classify AXSheets -25205 or childless AXChildren -25212 as unreadable; both are structural absence answers."
        )
    }

    @Test("a sheet deeper than the old bound is classified, not treated as clean")
    func deepSheetIsClassified() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(20)
        let window = builder.element(21)
        let groups = (0..<5).map { builder.element(22 + $0) }
        let sheet = builder.element(30)
        let create = builder.element(31)
        let cancel = builder.element(32)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
        builder.setAttribute(sheet, kAXDescriptionAttribute as String, "New Track")
        builder.setAttribute(create, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(create, kAXTitleAttribute as String, "Create")
        builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
        builder.setAttribute(cancel, kAXEnabledAttribute as String, false)
        builder.setChildren(window, [groups[0]])
        for index in 0..<(groups.count - 1) {
            builder.setChildren(groups[index], [groups[index + 1]])
        }
        builder.setChildren(groups[groups.count - 1], [sheet])
        builder.setChildren(sheet, [create, cancel])
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        #expect(
            kind == .mandatoryNewTrack,
            "Mutation caught: restore the former depth-four absence result; the unvisited deep subtree would hide this mandatory sheet."
        )
    }

    @Test("a reached sheet-search depth cap is not a clean observation")
    func depthCapIsFailClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(35)
        let window = builder.element(36)
        let groups = (0..<33).map { builder.element(37 + $0) }
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setChildren(window, [groups[0]])
        for index in 0..<(groups.count - 1) {
            builder.setChildren(groups[index], [groups[index + 1]])
        }
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        #expect(
            kind == .unknownSheet,
            "Mutation caught: change the `maxDepth == 0` branch from incomplete to absent; an unvisited subtree would falsely certify a clean modal observation."
        )
    }

    @Test("a malformed successful children payload blocks clean classification")
    func malformedChildrenAreFailClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(40)
        let window = builder.element(41)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                return .failure(.malformedChildren)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        #expect(
            kind == .unknownSheet,
            "Mutation caught: flatten malformed AXChildren to an empty success; an undecodable subtree must block a clean modal observation."
        )
    }

    @Test("an absent main window is an answer for the modal read, not an unknown blocker")
    func absentMainWindowIsAnAnswer() {
        // There is no main-window sheet when there is no main window, and during `project.new`
        // there genuinely is not one between choosing a template and Logic publishing the arrange
        // window. Calling that unreadable made project creation report an unknown blocking sheet
        // during the exact phase it exists to describe. The other two blocker kinds are still read
        // below it, so this remains a complete observation. What a track deletion additionally
        // needs — the window its count came from — is required at that call site instead.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(50)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation: treat an absent `AXMainWindow` as unreadable again; this becomes `.unknownSheet`.
        #expect(kind == .none)
    }

    @Test("an unreadable top-level dialog scan cannot certify a clean blocker set")
    func unreadableTopLevelDialogFailsClosed() {
        for status in [AXError.cannotComplete.rawValue, AXError.attributeUnsupported.rawValue] {
            let builder = FakeAXRuntimeBuilder()
            let app = builder.element(51)
            let window = builder.element(52)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            let runtime = builder.makeLogicRuntime(
                appElement: app,
                attributeValueResultHandler: { element, attribute in
                    guard CFEqual(element, app), attribute == (kAXWindowsAttribute as String) else { return nil }
                    return .failure(AXHelpers.AXStatusError(raw: status))
                },
                setAttributeHandler: nil,
                performActionHandler: nil
            )

            let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

            // Mutation source: flatten a failed AXWindows list (including
            // -25205) to an empty list; that would incorrectly produce `.none`.
            #expect(kind == .unknownSheet)
        }
    }

    @Test("an AXSystemDialog remains a blocker instead of becoming no alert")
    func systemDialogFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(53)
        let window = builder.element(54)
        let systemDialog = builder.element(55)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXWindowsAttribute as String, [window, systemDialog])
        builder.setAttribute(systemDialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)
        let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: nil)

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation source: restore the AXDialog-only equality check; this
        // AXSystemDialog would be omitted and the pass would look clean.
        #expect(kind == .unknownSheet)
    }

    @Test("an unreadable menu scan cannot certify a clean blocker set")
    func unreadableStrayMenuFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(56)
        let window = builder.element(57)
        let menuBar = builder.element(58)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, menuBar) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation source: convert a menu-child AX failure to `gone`; this
        // otherwise empty fixture would incorrectly produce `.none`.
        #expect(kind == .unknownSheet)
    }

    @Test("an accepted direct Create needs a fresh clean modal read after its bound sheet invalidates")
    func acceptedCreateGoneSheetIsPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            outcome.performed,
            "Mutation source: make a successful classifier-bound Create AXPress return unaccepted; this clean fixture must establish performed after the direct press and fresh clean scan."
        )
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: replace the bound Create press with an ordinal fallback; only the captured Create element may produce this success."
        )
    }

    @Test("a replacement sheet after invalidation is not attributed to the Create press")
    func acceptedCreateWithReplacementSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .replaced)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        // Mutation source: remove the fresh complete modal scan from Create's
        // `performed` conjunction; the stale bound reference alone would make
        // this replacement sheet look like a created track.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
    }

    @Test("accepted Create with a persistent sheet is not performed")
    func acceptedCreatePersistentSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .present)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            !outcome.performed,
            "Mutation caught: replace `action.accepted && summary.observedGone` with `action.accepted`; an accepted Create while the bound sheet persists would become performed."
        )
    }

    @Test("rejected Create with a gone sheet is not performed")
    func rejectedCreateGoneSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: false, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            !outcome.performed,
            "Mutation caught: remove `action.accepted &&` and use only `summary.observedGone`; a rejected Create with an independently gone sheet would become performed."
        )
    }

    @Test("an accepted direct delete press needs a fresh clean modal read after its bound sheet invalidates")
    func acceptedDeleteGoneSheetIsPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            outcome.performed,
            "Mutation source: make a successful classifier-bound Delete AXPress return unaccepted; this clean fixture must establish performed after the direct press and fresh clean scan."
        )
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: replace the bound delete press with an ordinal fallback; only the captured destructive button may produce this success."
        )
    }

    @Test("a replacement sheet after delete confirmation is not attributed to the Delete press")
    func acceptedDeleteWithReplacementSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .replaced)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        // Mutation source: remove the fresh complete modal scan from delete's
        // `performed` conjunction; the stale bound reference would mark the
        // Delete press performed while another sheet is still blocking.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
    }

    @Test("accepted delete confirmation with a persistent sheet is not performed")
    func acceptedDeletePersistentSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .present)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            !outcome.performed,
            "Mutation caught: replace `action.accepted && summary.observedGone` with `action.accepted`; an accepted delete press while its bound sheet persists would become performed."
        )
    }

    @Test("rejected delete confirmation with a gone sheet is not performed")
    func rejectedDeleteGoneSheetIsNotPerformed() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: false, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            !outcome.performed,
            "Mutation caught: remove either conjunct from `action.accepted && summary.observedGone`; a rejected delete press with an independently gone sheet would become performed."
        )
    }

    @Test("the witness remains on the classified sheet when AXMainWindow changes")
    func boundWitnessIgnoresRawMainWindowDrift() async {
        let fixture = makeBoundSheetFixture(
            action: .create,
            actionAccepted: true,
            postAction: .present,
            rawMainWindowDriftsToAuxiliary: true
        )

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            !outcome.performed,
            "Mutation caught: replace the bound-sheet witness with a fresh kAXMainWindow lookup; the auxiliary window has no sheet and would falsely report gone."
        )
        #expect(
            outcome.sheetWitness.map(\.observation) == [.present],
            "Mutation caught: observe a different window instead of the classifier-bound sheet; the original sheet must remain visible to this witness."
        )
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: invoke an ordinal fallback while the captured sheet is still present; the witness test must remain direct-element-only."
        )
    }

    @Test("a failed native press does not trigger an ordinal fallback")
    func rejectedNativePressDoesNotFallbackToOrdinalWindow() async {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: false, postAction: .present)

        let outcome = await reconcile(fixture, isDeleteContext: true)

        #expect(
            !outcome.performed,
            "Mutation caught: promote a rejected direct AXPress to performed; this rejected press must stay unperformed."
        )
        #expect(
            !fixture.ordinalFallbackUsed.get(),
            "Mutation caught: invoke the former ordinal AppleScript fallback after a failed native press; this fixture observes that injected AppleScript seam."
        )
    }

    @Test("a native action status is retained for diagnostics")
    func staleActionStatusIsRetained() async {
        let stale = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        let fixture = makeBoundSheetFixture(
            action: .create,
            actionAccepted: false,
            postAction: .present,
            actionFailure: stale
        )

        let outcome = await reconcile(fixture, isDeleteContext: false)

        #expect(
            outcome.actionFailure == .status(stale),
            "Mutation caught: flatten AXUIElementPerformAction's invalidUIElement status to false; the stale captured-button diagnostic would be lost."
        )
    }

    @Test("a native action status is surfaced in reconciliation extras")
    func staleActionStatusReachesExtras() throws {
        let stale = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
        var extras: [String: Any] = [:]

        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: .mandatoryNewTrack,
            action: AccessibilityChannel.reconcileActionLabel(.clickCreate),
            newTrackAutoConfirmed: false,
            actionFailure: .status(stale)
        )

        let diagnostic = try #require(extras["reconcile_action_error"] as? String)
        #expect(
            diagnostic == "ax_\(AXError.invalidUIElement.rawValue)",
            "Mutation caught: remove `actionFailure` from `mergeReconcileExtras`; the raw invalidUIElement rejection would not reach callers."
        )
    }

    @Test("only a none reconciliation is a settled clean modal observation")
    func deletionCleanObservationRequiresNoModalKind() {
        let cases: [(kind: ModalReconciliation.BlockingModalKind, performed: Bool, expected: Bool)] = [
            (.none, false, true),
            (.mandatoryNewTrack, true, false),
            (.deleteConfirm, false, false),
            (.informationalAlert, false, false),
            (.strayMenu, true, false),
            (.unknownSheet, false, false),
        ]

        // Asserted per row, not through a labelled-tuple comparison in a loop: that form was
        // measured not to fail when the function under test was hard-coded.
        for testCase in cases {
            let outcome = AccessibilityChannel.ModalReconcileOutcome(
                kind: testCase.kind,
                decision: .noAction,
                performed: testCase.performed
            )
            let actual = AccessibilityChannel.deletionModalObservationIsSettledClean(
                outcome, arrangeWindowPresent: true
            )
            if testCase.expected {
                #expect(actual)
            } else {
                #expect(!actual)
            }
        }

        // The arrange window is where the track count came from. A decrement observed while it
        // cannot be resolved is a transient AX failure shaped like a successful delete, so no
        // modal outcome may certify it clean.
        // Mutation: drop `arrangeWindowPresent` from the conjunction; this assertion becomes true.
        #expect(!AccessibilityChannel.deletionModalObservationIsSettledClean(
            AccessibilityChannel.ModalReconcileOutcome(kind: .none, decision: .noAction, performed: false),
            arrangeWindowPresent: false
        ))
    }

    @Test("State A gate truth table requires both a decrement and a settled clean observation")
    func deletionStateAGateTruthTable() {
        // Written as four separate bindings rather than a loop over labelled tuples. The loop form
        // was measured NOT to detect its own mutation: with the gate hard-coded to `false`, every
        // row still passed while a plain `#expect(Bool(false))` in the same test failed. A gate
        // this load-bearing has to be asserted in a form that was watched to fail.
        let neither = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: false, settledCleanModalObservation: false
        )
        let cleanOnly = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: false, settledCleanModalObservation: true
        )
        let countOnly = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: true, settledCleanModalObservation: false
        )
        let both = AccessibilityChannel.deletionCountCanCertifyStateA(
            observedTrackCountDecreased: true, settledCleanModalObservation: true
        )

        // Mutation: drop `settledCleanModalObservation` from the conjunction — `countOnly` becomes
        // true. Drop `observedTrackCountDecreased` — `cleanOnly` becomes true. Hard-code either
        // constant — `both` or the three negatives break.
        #expect(!neither)
        #expect(!cleanOnly)
        #expect(!countOnly)
        #expect(both)
    }

    @Test("State A waits for two consecutive complete clean modal observations")
    func deletionCleanObservationStreakRequiresTwoPasses() {
        let oneCleanObservation = AccessibilityChannel.deletionCleanObservationStreakIsSettled(1)
        let twoCleanObservations = AccessibilityChannel.deletionCleanObservationStreakIsSettled(2)

        // Mutation source: change the threshold from `>= 2` to `>= 1`; the
        // first binding becomes true and exposes the single-snapshot race.
        #expect(!oneCleanObservation)
        #expect(twoCleanObservations)
    }

    @Test("mandatory-track creation requires a positive post-action track count")
    func mandatoryTrackCreationRequiresTrackCount() {
        let performedWithoutTrack = AccessibilityChannel.mandatoryTrackCreationWasObserved(
            createActionPerformed: true,
            observedTrackCount: 0
        )
        let performedWithTrack = AccessibilityChannel.mandatoryTrackCreationWasObserved(
            createActionPerformed: true,
            observedTrackCount: 1
        )

        // Mutation source: drop `observedTrackCount > 0`; an invalidated sheet
        // with no project-level track read would become `mandatory_track_created`.
        #expect(!performedWithoutTrack)
        #expect(performedWithTrack)
    }

    @Test("project.new does not report a mandatory track without a post-Create track count")
    func projectNewDoesNotPromoteCreateToTrackFact() async throws {
        let fixture = makeProjectNewPerformedCreateWithoutTrackFixture()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let mandatoryTrackCreated = try #require(envelope["mandatory_track_created"] as? Bool)

        // Mutation source: have `mandatoryTrackCreationWasObserved` return only
        // `createActionPerformed`; this accepted Create with zero headers would
        // falsely claim a project-level track fact.
        #expect(result.isSuccess)
        #expect(!mandatoryTrackCreated)
    }

    @Test("a delete-confirm followed by New Track presses each classifier-bound action once")
    func sequentialDeleteAndMandatorySheetEachReceiveOneAction() async throws {
        let fixture = makeSequentialDeleteSheetFixture()

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: fixture.runtime)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let action = try #require(envelope["reconciled_action"] as? String)

        // Mutation source: restore the former operation-wide action latch; the
        // delete confirm still presses, but the later mandatory Create count is
        // zero while its decision label would be falsely reported as a press.
        #expect(fixture.deleteConfirmPresses.get() == 1)
        #expect(fixture.createPresses.get() == 1)
        #expect(action == "click_create")
    }

    @Test("project.new preserves a stale Create status in its unconfirmed envelope")
    func projectNewUnconfirmedCreatePreservesActionError() async throws {
        let fixture = makeProjectNewStaleCreateFixture()

        let result = await AccessibilityChannel.observeProjectCreationOutcome(
            runtime: fixture.runtime,
            selection: "Empty Project",
            observationAttempts: 1,
            observationDelayNanoseconds: 0
        )
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let actionError = try #require(envelope["reconcile_action_error"] as? String)

        // Mutation source: remove `outcome.actionFailure` from the mandatory
        // create-unconfirmed extras; the direct stale Create status disappears.
        #expect(!result.isSuccess)
        #expect(actionError == "ax_\(AXError.invalidUIElement.rawValue)")
    }
}

private enum BoundSheetAction {
    case create
    case delete
}

private enum BoundSheetPostAction {
    case gone
    case present
    case replaced
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

private final class LockedActionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct BoundSheetFixture {
    let runtime: AXLogicProElements.Runtime
    let ordinalFallbackUsed: LockedFlag
}

private func reconcile(
    _ fixture: BoundSheetFixture,
    isDeleteContext: Bool
) async -> AccessibilityChannel.ModalReconcileOutcome {
    await AccessibilityChannel.reconcileAfterMutation(
        isDeleteContext: isDeleteContext,
        runtime: fixture.runtime,
        witnessAttempts: 1,
        witnessDelayNanoseconds: 0
    )
}

private func makeBoundSheetFixture(
    action: BoundSheetAction,
    actionAccepted: Bool,
    postAction: BoundSheetPostAction,
    rawMainWindowDriftsToAuxiliary: Bool = false,
    actionFailure: AXHelpers.AXStatusError? = nil
) -> BoundSheetFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(100)
    let auxiliaryWindow = builder.element(101)
    let arrangeWindow = builder.element(102)
    let trackHeaders = builder.element(103)
    let sheet = builder.element(104)
    let primary = builder.element(105)
    let cancel = builder.element(106)
    let replacementSheet = builder.element(107)
    let actionIssued = LockedFlag()
    let ordinalFallbackUsed = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrangeWindow)
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, action == .create ? "New Track" : "Delete Tracks")
    builder.setAttribute(primary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(
        primary,
        kAXTitleAttribute as String,
        action == .create ? "Create" : "Delete Tracks and Content"
    )
    builder.setAttribute(cancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(cancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(cancel, kAXEnabledAttribute as String, action != .create)
    builder.setChildren(sheet, [primary, cancel])
    builder.setAttribute(replacementSheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(replacementSheet, kAXDescriptionAttribute as String, "New Track")

    if rawMainWindowDriftsToAuxiliary {
        builder.setAttribute(app, kAXWindowsAttribute as String, [auxiliaryWindow, arrangeWindow])
        builder.setAttribute(auxiliaryWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(arrangeWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(trackHeaders, kAXDescriptionAttribute as String, "Track headers")
        builder.setChildren(arrangeWindow, [trackHeaders])
    }

    let attributeValueHandler: (@Sendable (AXUIElement, String) -> AnyObject??) = { element, attribute in
        if CFEqual(element, arrangeWindow), attribute == "AXSheets" {
            if actionIssued.get(), postAction == .gone {
                return .some([] as NSArray)
            }
            if actionIssued.get(), postAction == .replaced {
                return .some([replacementSheet] as NSArray)
            }
            return .some([sheet] as NSArray)
        }
        if rawMainWindowDriftsToAuxiliary,
           actionIssued.get(),
           CFEqual(element, app),
           attribute == (kAXMainWindowAttribute as String) {
            return .some(auxiliaryWindow)
        }
        return nil
    }
    let attributeValueResultHandler: (@Sendable (AXUIElement, String) -> Result<AnyObject?, AXHelpers.AXStatusError>?) = { element, attribute in
        guard actionIssued.get(),
              postAction == .gone || postAction == .replaced,
              CFEqual(element, sheet),
              attribute == (kAXRoleAttribute as String)
        else { return nil }
        return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
    }
    let press: @Sendable (AXUIElement, String) -> Bool = { element, actionName in
        guard CFEqual(element, primary), actionName == (kAXPressAction as String) else { return false }
        actionIssued.set()
        return actionAccepted
    }
    var pressResult: (@Sendable (AXUIElement, String) -> Result<Void, AXHelpers.AXStatusError>)?
    if let failure = actionFailure {
        pressResult = { element, actionName -> Result<Void, AXHelpers.AXStatusError> in
            guard CFEqual(element, primary), actionName == (kAXPressAction as String) else {
                return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
            }
            actionIssued.set()
            return .failure(failure)
        }
    }
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: attributeValueHandler,
        attributeValueResultHandler: attributeValueResultHandler,
        setAttributeHandler: nil,
        performActionHandler: press,
        performActionResultHandler: pressResult,
        executeAppleScript: { _ in
            ordinalFallbackUsed.set()
            return .success("ordinal fallback")
        }
    )

    return BoundSheetFixture(runtime: runtime, ordinalFallbackUsed: ordinalFallbackUsed)
}

private enum SequentialDeleteSheetStage {
    case noSheet
    case deleteConfirm
    case mandatoryNewTrack
}

private final class SequentialDeleteSheetState: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: SequentialDeleteSheetStage = .noSheet

    func set(_ next: SequentialDeleteSheetStage) {
        lock.lock()
        stage = next
        lock.unlock()
    }

    func get() -> SequentialDeleteSheetStage {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }
}

private struct SequentialDeleteSheetFixture {
    let runtime: AXLogicProElements.Runtime
    let deleteConfirmPresses: LockedActionCount
    let createPresses: LockedActionCount
}

private func makeSequentialDeleteSheetFixture() -> SequentialDeleteSheetFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(200)
    let window = builder.element(201)
    let menuBar = builder.element(202)
    let trackMenu = builder.element(203)
    let deleteMenuItem = builder.element(204)
    let trackHeaders = builder.element(205)
    let trackHeader = builder.element(206)
    let deleteSheet = builder.element(207)
    let deletePrimary = builder.element(208)
    let deleteCancel = builder.element(209)
    let mandatorySheet = builder.element(210)
    let createPrimary = builder.element(211)
    let createCancel = builder.element(212)
    let state = SequentialDeleteSheetState()
    let deleteConfirmPresses = LockedActionCount()
    let createPresses = LockedActionCount()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(window, [trackHeaders])
    builder.setAttribute(trackHeaders, kAXRoleAttribute as String, kAXListRole as String)
    builder.setAttribute(trackHeaders, kAXIdentifierAttribute as String, "Track Headers")
    builder.setChildren(trackHeaders, [trackHeader])
    builder.setAttribute(trackHeader, kAXRoleAttribute as String, kAXLayoutItemRole as String)
    builder.setChildren(menuBar, [trackMenu])
    builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
    builder.setChildren(trackMenu, [deleteMenuItem])
    builder.setAttribute(deleteMenuItem, kAXTitleAttribute as String, "Delete Track")

    builder.setAttribute(deleteSheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(deleteSheet, kAXDescriptionAttribute as String, "Delete Tracks")
    builder.setAttribute(deletePrimary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(deletePrimary, kAXTitleAttribute as String, "Delete Tracks and Content")
    builder.setAttribute(deleteCancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(deleteCancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(deleteCancel, kAXEnabledAttribute as String, true)
    builder.setChildren(deleteSheet, [deletePrimary, deleteCancel])

    builder.setAttribute(mandatorySheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(mandatorySheet, kAXDescriptionAttribute as String, "New Track")
    builder.setAttribute(createPrimary, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(createPrimary, kAXTitleAttribute as String, "Create")
    builder.setAttribute(createCancel, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(createCancel, kAXTitleAttribute as String, "Cancel")
    builder.setAttribute(createCancel, kAXEnabledAttribute as String, false)
    builder.setChildren(mandatorySheet, [createPrimary, createCancel])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, window), attribute == "AXSheets" else { return nil }
            switch state.get() {
            case .noSheet: return .some([] as NSArray)
            case .deleteConfirm: return .some([deleteSheet] as NSArray)
            case .mandatoryNewTrack: return .some([mandatorySheet] as NSArray)
            }
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard action == (kAXPressAction as String) else { return false }
            if CFEqual(element, deleteMenuItem) {
                state.set(.deleteConfirm)
                return true
            }
            if CFEqual(element, deletePrimary) {
                deleteConfirmPresses.increment()
                builder.setChildren(trackHeaders, [])
                state.set(.mandatoryNewTrack)
                return true
            }
            if CFEqual(element, createPrimary) {
                createPresses.increment()
                return true
            }
            return false
        }
    )
    return SequentialDeleteSheetFixture(
        runtime: runtime,
        deleteConfirmPresses: deleteConfirmPresses,
        createPresses: createPresses
    )
}

private struct ProjectNewStaleCreateFixture {
    let runtime: AXLogicProElements.Runtime
}

private struct ProjectNewPerformedCreateWithoutTrackFixture {
    let runtime: AXLogicProElements.Runtime
}

private func makeProjectNewPerformedCreateWithoutTrackFixture() -> ProjectNewPerformedCreateWithoutTrackFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(280)
    let window = builder.element(281)
    let menuBar = builder.element(282)
    let sheet = builder.element(283)
    let create = builder.element(284)
    let cancel = builder.element(285)
    let actionIssued = LockedFlag()

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(app, kAXWindowsAttribute as String, [window])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    builder.setChildren(menuBar, [])
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
    builder.setAttribute(window, kAXTitleAttribute as String, "Untitled 1 - Tracks")
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
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
            return actionIssued.get() ? .some([] as NSArray) : .some([sheet] as NSArray)
        },
        attributeValueResultHandler: { element, attribute in
            guard actionIssued.get(),
                  CFEqual(element, sheet),
                  attribute == (kAXRoleAttribute as String)
            else { return nil }
            return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
        },
        setAttributeHandler: nil,
        performActionHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else { return false }
            actionIssued.set()
            return true
        }
    )
    return ProjectNewPerformedCreateWithoutTrackFixture(runtime: runtime)
}

private func makeProjectNewStaleCreateFixture() -> ProjectNewStaleCreateFixture {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(300)
    let window = builder.element(301)
    let sheet = builder.element(302)
    let create = builder.element(303)
    let cancel = builder.element(304)
    let stale = AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
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
            return .some([sheet] as NSArray)
        },
        setAttributeHandler: nil,
        performActionHandler: { _, _ in false },
        performActionResultHandler: { element, action in
            guard CFEqual(element, create), action == (kAXPressAction as String) else {
                return .failure(stale)
            }
            return .failure(stale)
        }
    )
    return ProjectNewStaleCreateFixture(runtime: runtime)
}
