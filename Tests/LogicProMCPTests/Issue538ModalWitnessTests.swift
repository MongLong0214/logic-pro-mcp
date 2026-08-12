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
        builder.setAttribute(systemDialog, kAXModalAttribute as String, true)
        builder.setAttribute(systemDialog, kAXSubroleAttribute as String, kAXSystemDialogSubrole as String)
        let runtime = builder.makeLogicRuntime(appElement: app, setAttributeHandler: nil, performActionHandler: nil)

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation `system-modal-attribute-omission`: remove AXModal from the
        // scan; this AXSystemDialog would be omitted and the pass would look clean.
        #expect(kind == .unknownSheet)
    }

    @Test("an AXModal floating window blocks a clean modal observation")
    func floatingModalWindowFailsClosed() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(56)
        let arrange = builder.element(57)
        let goToPosition = builder.element(58)
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, goToPosition])
        builder.setAttribute(goToPosition, kAXSubroleAttribute as String, "AXFloatingWindow")
        builder.setAttribute(goToPosition, kAXModalAttribute as String, true)

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: builder.makeLogicRuntime(appElement: app)
        ))

        // Mutation `floating-modal-attribute-omission`: restore the former
        // AXDialog/AXSystemDialog allowlist. The known Go To Position shape then
        // disappears and the complete scan falsely returns `.none`.
        #expect(kind == .unknownSheet)
    }

    @Test("the complete scan retains its status-preserving AXDialog subrole")
    func observedDialogSubroleIsNotRereadBestEffort() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(59)
        let arrange = builder.element(60)
        let dialog = builder.element(61)
        let subroleReads = LockedCounter()
        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, dialog])
        builder.setAttribute(dialog, kAXModalAttribute as String, true)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, dialog), attribute == (kAXSubroleAttribute as String) else {
                    return nil
                }
                return subroleReads.next() == 1
                    ? .success(kAXDialogSubrole as NSString)
                    : .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(runtime: runtime))

        // Mutation `observed-subrole-reread`: call the best-effort dialog
        // helper without the captured subrole. Its second, failed read makes an
        // already-observed AXDialog vanish from the complete blocker set.
        #expect(kind == .unknownSheet)
        #expect(subroleReads.current() == 1)
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

    @Test("an accepted Create with a gone bound sheet reports observations, not causation")
    func acceptedCreateGoneSheetIsNotPerformed() async throws {
        let fixture = makeBoundSheetFixture(action: .create, actionAccepted: true, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: false)
        let witness = try #require(outcome.witnessSummary)

        // Mutation `sheet-close-causation-create`: restore a causal `performed`
        // conjunction. A user-close between AX accepting the press and this
        // witness is indistinguishable, so only the press and gone observation
        // may be reported.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
        #expect(witness.observedGone)
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

    @Test("an accepted delete confirmation with a gone bound sheet reports observations, not causation")
    func acceptedDeleteGoneSheetIsNotPerformed() async throws {
        let fixture = makeBoundSheetFixture(action: .delete, actionAccepted: true, postAction: .gone)

        let outcome = await reconcile(fixture, isDeleteContext: true)
        let witness = try #require(outcome.witnessSummary)

        // Mutation `sheet-close-causation-delete`: restore a causal `performed`
        // conjunction. The action was directly attempted and the target is gone,
        // but those observations cannot establish who closed the sheet.
        #expect(!outcome.performed)
        #expect(outcome.actionAttempted)
        #expect(witness.observedGone)
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

    @Test("the confirmation scan stays on the original sheet host when AXMainWindow drifts")
    func confirmationScanUsesOriginalSheetHost() async {
        let fixture = makeBoundSheetFixture(
            action: .create,
            actionAccepted: true,
            postAction: .replaced,
            rawMainWindowDriftsToAuxiliary: true
        )

        _ = await reconcile(fixture, isDeleteContext: false)
        let clear = AccessibilityChannel.freshCompleteModalReadIsClear(
            in: fixture.arrangeWindow,
            runtime: fixture.runtime
        )

        // Mutation `confirmation-main-window-reresolution`: replace the bound
        // host with a fresh AXMainWindow lookup. That auxiliary window has no
        // sheet and would hide the replacement still attached to the arrange
        // window, producing a false clean confirmation.
        #expect(!clear)
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
                outcome, arrangeWindowWasRead: true
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
        // Mutation: drop `arrangeWindowWasRead` from the conjunction; this assertion becomes true.
        #expect(!AccessibilityChannel.deletionModalObservationIsSettledClean(
            AccessibilityChannel.ModalReconcileOutcome(kind: .none, decision: .noAction, performed: false),
            arrangeWindowWasRead: false
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

    @Test("a mandatory sheet on the AXWindows arrange target cannot be skipped by AXMainWindow absence")
    func deleteBindsSheetReadToResolvedArrangeWindow() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(120)
        let arrange = builder.element(121)
        let menuBar = builder.element(122)
        let trackMenu = builder.element(123)
        let deleteItem = builder.element(124)
        let headers = builder.element(125)
        let header = builder.element(126)
        let sheet = builder.element(127)
        let create = builder.element(128)
        let cancel = builder.element(129)

        builder.setAttribute(app, kAXWindowsAttribute as String, [arrange])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(arrange, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [header])
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setChildren(trackMenu, [deleteItem])
        builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")
        builder.setAttribute(arrange, "AXSheets", [sheet])
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
            attributeValueResultHandler: { element, attribute in
                guard CFEqual(element, app), attribute == (kAXMainWindowAttribute as String) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.attributeUnsupported.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, deleteItem), action == (kAXPressAction as String) else { return false }
                builder.setChildren(headers, [])
                return true
            }
        )

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)

        // Mutation: replace the poll's bound `arrangeWindow` modal read with the
        // direct AXMainWindow read. It classifies -25205 as absent, skips this
        // attached mandatory sheet, and incorrectly returns State A after two
        // clean-looking count polls.
        #expect(!verified)
    }

    @Test("a failed header traversal is not an observed zero count for delete verification")
    func deleteDoesNotTreatUnreadableTrackTraversalAsEmptyRail() async throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(140)
        let window = builder.element(141)
        let menuBar = builder.element(142)
        let trackMenu = builder.element(143)
        let deleteItem = builder.element(144)
        let headers = builder.element(145)
        let header = builder.element(146)
        let deleted = LockedFlag()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        // Keep a normal non-dialog top-level window in the complete modal scan,
        // so this fixture isolates the header traversal error from an unrelated
        // empty-AXWindows read.
        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setChildren(window, [headers])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [header])
        builder.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setChildren(menuBar, [trackMenu])
        builder.setAttribute(trackMenu, kAXTitleAttribute as String, "Track")
        builder.setChildren(trackMenu, [deleteItem])
        builder.setAttribute(deleteItem, kAXTitleAttribute as String, "Delete Track")

        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenHandler: { element in
                CFEqual(element, headers) && deleted.get() ? [] : nil
            },
            childrenResultHandler: { element in
                guard CFEqual(element, headers), deleted.get() else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard CFEqual(element, deleteItem), action == (kAXPressAction as String) else { return false }
                deleted.set()
                return true
            }
        )

        let result = await AccessibilityChannel.defaultDeleteTrack(runtime: runtime)
        let postDeleteHeaderRead = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        let traversalWasUnreadable: Bool
        if case .unreadable = postDeleteHeaderRead {
            traversalWasUnreadable = true
        } else {
            traversalWasUnreadable = false
        }
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any]
        )
        let verified = try #require(envelope["verified"] as? Bool)
        let trackCountAfterWasUnobserved = envelope["track_count_after"] is NSNull
        let observedDeltaWasUnobserved = envelope["observed_delta"] is NSNull

        // Mutation `unreadable-after-count-echo`: restore `beforeCount` as the
        // post-delete fallback. Four unreadable reads would then masquerade as a
        // successfully observed no-delta result.
        #expect(traversalWasUnreadable)
        #expect(!verified)
        #expect(trackCountAfterWasUnobserved)
        #expect(observedDeltaWasUnobserved)
    }

    @Test("a readable empty Track Headers rail ignores an unrelated unreadable subtree")
    func readableTrackHeadersIgnoreUnrelatedUnreadableSubtree() {
        let builder = FakeAXRuntimeBuilder()
        let window = builder.element(150)
        let headers = builder.element(151)
        let unrelatedInspector = builder.element(152)
        builder.setChildren(window, [headers, unrelatedInspector])
        builder.setAttribute(headers, kAXRoleAttribute as String, kAXListRole as String)
        builder.setAttribute(headers, kAXIdentifierAttribute as String, "Track Headers")
        builder.setChildren(headers, [])
        builder.setAttribute(unrelatedInspector, kAXRoleAttribute as String, kAXGroupRole as String)
        let runtime = builder.makeLogicRuntime(
            childrenResultHandler: { element in
                guard CFEqual(element, unrelatedInspector) else { return nil }
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AXLogicProElements.allTrackHeadersRead(in: window, runtime: runtime)
        let observedEmptyRail: Bool
        if case .read(let headers) = read {
            observedEmptyRail = headers.isEmpty
        } else {
            observedEmptyRail = false
        }

        // Mutation `whole-window-strict-track-traversal`: make an unrelated
        // child failure abort candidate discovery. The readable empty rail then
        // becomes `.unreadable` even though its own children were read.
        #expect(observedEmptyRail)
    }

    @Test("the complete modal scan ignores a plug-in editor AXDialog")
    func pluginEditorDoesNotBlockCleanModalRead() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(160)
        let arrange = builder.element(161)
        let editor = builder.element(162)
        let close = builder.element(163)
        let bypass = builder.element(164)

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [editor, arrange])
        builder.setAttribute(editor, kAXModalAttribute as String, true)
        builder.setAttribute(editor, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(editor, kAXCloseButtonAttribute as String, close)
        builder.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        builder.setAttribute(bypass, kAXDescriptionAttribute as String, "bypass")
        builder.setChildren(editor, [bypass])

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: builder.makeLogicRuntime(appElement: app)
        ))

        // Mutation `plugin-editor-exclusion-after-axmodal`: skip the shared
        // plug-in-editor exclusion after AXModal confirms modality. This editor
        // becomes unknownSheet and no successful delete can accumulate a clean
        // streak.
        #expect(kind == .none)
    }

    @Test("the complete modal scan ignores the Drummer Smart Controls AXDialog")
    func smartControlsDoesNotBlockCleanModalRead() {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(170)
        let arrange = builder.element(171)
        let controls = builder.element(172)
        let toggle = builder.element(173)

        builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        builder.setAttribute(app, kAXWindowsAttribute as String, [controls, arrange])
        builder.setAttribute(controls, kAXModalAttribute as String, true)
        builder.setAttribute(controls, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setAttribute(controls, kAXTitleAttribute as String, "")
        builder.setAttribute(toggle, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(toggle, kAXDescriptionAttribute as String, "Smart Controls")
        builder.setChildren(controls, [toggle])

        let kind = ModalReconciliation.classify(AccessibilityChannel.readModalSignals(
            runtime: builder.makeLogicRuntime(appElement: app)
        ))

        // Mutation `smart-controls-exclusion-after-axmodal`: bypass the shared Smart Controls exclusion in the complete
        // scan. This ordinary pane is then promoted to unknownSheet.
        #expect(kind == .none)
    }

    @Test("a refused reconciliation does not serialize an unattempted decision as an action")
    func unattemptedReconcileDecisionUsesNoneActionLabel() {
        let outcome = AccessibilityChannel.ModalReconcileOutcome(
            kind: .informationalAlert,
            decision: .acknowledgeAlert,
            performed: false,
            actionAttempted: false,
            refusal: .targetGone
        )
        var extras: [String: Any] = [:]
        AccessibilityChannel.mergeReconcileExtras(
            &extras,
            kind: outcome.kind,
            action: AccessibilityChannel.attemptedReconcileActionLabel(outcome),
            newTrackAutoConfirmed: false,
            refusal: outcome.refusal
        )

        // Mutation: return `reconcileActionLabel(outcome.decision)` without the
        // `actionAttempted` guard. A successful creation would then publish
        // `acknowledge_alert` beside `alert_target_gone` despite no press.
        #expect(extras["reconciled_action"] as? String == "none")
        #expect(extras["reconcile_refused"] as? String == "alert_target_gone")
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
        // Mutation `project-new-sheet-close-causation`: restore the former
        // causal `performed` result for an accepted Create followed by sheet
        // disappearance. Without an independently observed track, project.new
        // must not publish a `mandatory_track_created` fact at all.
        #expect(!result.isSuccess)
        #expect(envelope["mandatory_track_created"] == nil)
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

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
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
    let arrangeWindow: AXUIElement
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

    return BoundSheetFixture(
        runtime: runtime,
        arrangeWindow: arrangeWindow,
        ordinalFallbackUsed: ordinalFallbackUsed
    )
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
