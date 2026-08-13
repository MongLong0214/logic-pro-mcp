import ApplicationServices
import Foundation

/// #346 — live AX reader + executor for the pure `ModalReconciliation` core.
/// Reads the MAIN WINDOW's sheet (native AX; `dialogPresent` scans only
/// top-level windows and MISSES a main-window sheet) into `ModalSignals`,
/// classifies + decides via the pure core, and performs the sanctioned recovery
/// (click "Create" / confirm delete / Escape a stray menu). Unknown sheets fail
/// closed — never blindly dismissed.
extension AccessibilityChannel {

    /// #453: why an authorized alert acknowledgement was refused at click time.
    ///
    /// A refusal is a SAFETY OUTCOME, not an error to be swallowed — the operator
    /// needs to know the server declined to click and why. Every case is a
    /// structural fact about the AX tree; none of them carries dialog text,
    /// button titles or any other UI content, because a refusal reason travels
    /// into extras and logs where user content must never appear.
    enum AlertAcknowledgeRefusal: String, Sendable {
        /// The classifier's dialog element was not carried to the executor.
        case targetUnavailable = "alert_target_unavailable"
        /// No blocking dialog is present any more — it closed itself.
        case targetGone = "alert_target_gone"
        /// A blocking dialog is present, but not the one that was classified.
        case targetChanged = "alert_target_changed"
        /// The re-read button count is not exactly one, so this is a CHOICE.
        case buttonCountChanged = "alert_button_count_changed"
        /// The single button was found but the press itself failed.
        case pressFailed = "alert_press_failed"
    }

    /// Outcome of one reconciliation pass, surfaced as honest extras by callers.
    struct ModalReconcileOutcome: Sendable, Equatable {
        let kind: ModalReconciliation.BlockingModalKind
        let decision: ModalReconciliation.ModalReconcileDecision
        let performed: Bool
        /// True only when this pass actually issued the classifier-bound action.
        /// A decision describes what would be safe; it is not evidence that a
        /// press or key event was attempted.
        let actionAttempted: Bool
        /// Per-poll post-action sheet observations. These stay in-process for
        /// debug logging and tests; response envelopes carry only
        /// `witnessSummary`, never this trace.
        let sheetWitness: [ModalSheetWitnessPoll]
        /// Compact, response-safe observation summary for the action's witness.
        /// For sheet actions, `gone` says only that the captured sheet identity
        /// disappeared; it is intentionally not attributed to the direct press.
        let witnessSummary: ModalReconcileWitnessSummary?
        /// Set only when an authorized action was declined at execution time.
        /// `performed == false` alone cannot distinguish "the decision was not to
        /// act" from "the decision was to act and the executor refused", and
        /// those are very different things to report.
        let refusal: AlertAcknowledgeRefusal?
        /// Preserves a raw AX action status (for example, a stale captured
        /// element) when the runtime could provide one. This says only that AX
        /// rejected the press; it never attributes a later close to that press.
        let actionFailure: AXHelpers.AXActionError?

        init(
            kind: ModalReconciliation.BlockingModalKind,
            decision: ModalReconciliation.ModalReconcileDecision,
            performed: Bool,
            actionAttempted: Bool = false,
            sheetWitness: [ModalSheetWitnessPoll] = [],
            witnessSummary: ModalReconcileWitnessSummary? = nil,
            refusal: AlertAcknowledgeRefusal? = nil,
            actionFailure: AXHelpers.AXActionError? = nil
        ) {
            self.kind = kind
            self.decision = decision
            self.performed = performed
            self.actionAttempted = actionAttempted
            self.sheetWitness = sheetWitness
            self.witnessSummary = witnessSummary
            self.refusal = refusal
            self.actionFailure = actionFailure
        }

        static let none = ModalReconcileOutcome(kind: .none, decision: .noAction, performed: false)
    }

    /// The one thing a post-sheet-action poll is allowed to claim. An AX failure
    /// is deliberately separate from `.gone`: it means the observation failed,
    /// not that Logic closed the sheet.
    enum ModalSheetWitnessObservation: Sendable, Equatable {
        case present
        case gone
        case unreadable(ModalSheetWitnessReadFailure)

        var diagnosticLabel: String {
            switch self {
            case .present:
                return "present"
            case .gone:
                return "gone"
            case .unreadable(let failure):
                return "unreadable_\(failure.diagnosticLabel)"
            }
        }
    }

    /// The AX read that made a sheet witness unreadable. These fixed structural
    /// tokens intentionally carry no window title, sheet text, or button label.
    enum ModalSheetWitnessReadFailure: Sendable, Equatable {
        case sheet(AXHelpers.AXStatusError)

        var diagnosticLabel: String {
            switch self {
            case .sheet(let error):
                return "sheet_\(error.diagnosticLabel)"
            }
        }
    }

    /// One ordered status-preserving observation after a sheet action.
    struct ModalSheetWitnessPoll: Sendable, Equatable {
        let index: Int
        let observation: ModalSheetWitnessObservation

        var diagnosticLabel: String {
            observation.diagnosticLabel
        }
    }

    /// The shipped form of a post-action witness. Keeping counts rather than
    /// the ordered trace prevents a normal `project.new` envelope from carrying
    /// up to 30 diagnostic entries while retaining the useful fact of what the
    /// witness observed and how often.
    struct ModalReconcileWitnessSummary: Sendable, Equatable {
        let pollCount: Int
        let observations: [String: Int]
        /// A separate, complete read of every modal source after the bound
        /// target observation. This is an observation of the blocker set, not
        /// evidence that the attempted action caused it to become clean.
        let blockerSetClear: Bool?

        init(labels: [String], blockerSetClear: Bool? = nil) {
            self.pollCount = labels.count
            self.observations = labels.reduce(into: [:]) { counts, label in
                counts[label, default: 0] += 1
            }
            self.blockerSetClear = blockerSetClear
        }

        private init(pollCount: Int, observations: [String: Int], blockerSetClear: Bool?) {
            self.pollCount = pollCount
            self.observations = observations
            self.blockerSetClear = blockerSetClear
        }

        init(sheetWitness: [ModalSheetWitnessPoll], blockerSetClear: Bool? = nil) {
            self.init(labels: sheetWitness.map(\.diagnosticLabel), blockerSetClear: blockerSetClear)
        }

        var observedGone: Bool {
            observations["gone", default: 0] > 0
        }

        var envelopeValue: [String: Any] {
            var value: [String: Any] = [
                "polls": pollCount,
                "observations": observations,
            ]
            if let blockerSetClear {
                value["blocker_set_clear"] = blockerSetClear
            }
            return value
        }

        func withBlockerSetClear(_ value: Bool) -> ModalReconcileWitnessSummary {
            ModalReconcileWitnessSummary(
                pollCount: pollCount,
                observations: observations,
                blockerSetClear: value
            )
        }
    }

    // MARK: - Public entry points

    /// Reconcile a blocking modal left by a just-completed mutation. Performs
    /// every actionable decision (clickCreate / confirmDelete / escapeMenu);
    /// fail-closed and no-action never touch the UI. `isDeleteContext` authorises
    /// confirming a delete-channel-strips sheet.
    static func reconcileAfterMutation(
        isDeleteContext: Bool,
        runtime: AXLogicProElements.Runtime = .production,
        witnessAttempts: Int = 30,
        witnessDelayNanoseconds: UInt64 = 100_000_000
    ) async -> ModalReconcileOutcome {
        await reconcile(
            isDeleteContext: isDeleteContext,
            preflight: false,
            clearMandatoryNewTrack: true,
            runtime: runtime,
            witnessAttempts: witnessAttempts,
            witnessDelayNanoseconds: witnessDelayNanoseconds
        )
    }

    /// Observe the current post-mutation blocker without issuing another action.
    /// Callers use this after one accepted-or-rejected recovery attempt to obtain
    /// a settled clean observation without repeating a possibly already-landed
    /// modal action.
    static func observeModalAfterMutation(
        isDeleteContext: Bool,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalReconcileOutcome {
        let read = readModalSignalsAndAlertTarget(runtime: runtime)
        let kind = ModalReconciliation.classify(read.signals)
        let decision = ModalReconciliation.decide(kind: kind, isDeleteContext: isDeleteContext)
        return ModalReconcileOutcome(kind: kind, decision: decision, performed: false)
    }

    /// As above, but carry the arrange-window answer captured by a mutation poll
    /// into the sheet reader. The count and the clean-modal observation can then
    /// only describe one AX window, rather than independently resolving
    /// `AXMainWindow` and `AXWindows` after one another.
    static func observeModalAfterMutation(
        isDeleteContext: Bool,
        arrangeWindow: AXLogicProElements.ArrangeWindowRead,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalReconcileOutcome {
        let read = readModalSignalsAndAlertTarget(
            runtime: runtime,
            mainWindow: modalMainWindowLookup(from: arrangeWindow)
        )
        let kind = ModalReconciliation.classify(read.signals)
        let decision = ModalReconciliation.decide(kind: kind, isDeleteContext: isDeleteContext)
        return ModalReconcileOutcome(kind: kind, decision: decision, performed: false)
    }

    /// Reconcile a blocking modal BEFORE starting an operation. Auto-clears a
    /// single-button informational alert and a stray open menu; the mandatory
    /// New Track sheet is auto-cleared ONLY when `clearMandatoryNewTrack` is true
    /// (the default). The CREATE path passes `false` so preflight never clicks
    /// "Create" — `createTrackViaMenu` opens/confirms its own New Track dialog,
    /// and doing both would double-create. A deleteConfirm / unknownSheet is
    /// reported but NOT acted on (we never confirm a delete the caller did not
    /// request, nor dismiss a sheet/dialog that could be a Save prompt).
    static func reconcilePreflight(
        clearMandatoryNewTrack: Bool = true,
        runtime: AXLogicProElements.Runtime = .production,
        witnessAttempts: Int = 30,
        witnessDelayNanoseconds: UInt64 = 100_000_000
    ) async -> ModalReconcileOutcome {
        await reconcile(
            isDeleteContext: false,
            preflight: true,
            clearMandatoryNewTrack: clearMandatoryNewTrack,
            runtime: runtime,
            witnessAttempts: witnessAttempts,
            witnessDelayNanoseconds: witnessDelayNanoseconds
        )
    }

    private static func reconcile(
        isDeleteContext: Bool,
        preflight: Bool,
        clearMandatoryNewTrack: Bool,
        runtime: AXLogicProElements.Runtime,
        witnessAttempts: Int,
        witnessDelayNanoseconds: UInt64
    ) async -> ModalReconcileOutcome {
        // #453 / #538: actionable AX ELEMENTs are captured with the signals and
        // carried to the executor. `ModalSignals` is the pure core's input and
        // stays string-only, so the elements travel beside it rather than inside
        // it. Re-finding a button through an ordinal window/sheet path can target
        // a different Logic window from the sheet the reader classified.
        let mainWindow = modalMainWindow(runtime: runtime)
        let read = readModalSignalsAndAlertTarget(runtime: runtime, mainWindow: mainWindow)
        let signals = read.signals
        let kind = ModalReconciliation.classify(signals)
        let decision = ModalReconciliation.decide(kind: kind, isDeleteContext: isDeleteContext)

        // At preflight, only the non-destructive blockers are auto-cleared (and
        // the mandatory New Track sheet only when `clearMandatoryNewTrack`); the
        // scoping policy is the pure `preflightShouldPerform`.
        if preflight,
           !ModalReconciliation.preflightShouldPerform(
                kind: kind,
                clearMandatoryNewTrack: clearMandatoryNewTrack
           ) {
            return ModalReconcileOutcome(kind: kind, decision: decision, performed: false)
        }

        let result = await perform(
            decision,
            alertTarget: read.alertTarget,
            strayMenuTarget: read.strayMenuTarget,
            sheet: read.sheet,
            mainWindow: mainWindow,
            createButton: read.createButton,
            deleteButton: read.deleteButton,
            runtime: runtime,
            witnessAttempts: witnessAttempts,
            witnessDelayNanoseconds: witnessDelayNanoseconds
        )
        return ModalReconcileOutcome(
            kind: kind,
            decision: decision,
            performed: result.performed,
            actionAttempted: result.actionAttempted,
            sheetWitness: result.sheetWitness,
            witnessSummary: result.witnessSummary,
            refusal: result.refusal,
            actionFailure: result.actionFailure
        )
    }

    // MARK: - Signal reader

    struct ModalSignalRead {
        let signals: ModalReconciliation.ModalSignals
        let alertTarget: AXLogicProElements.BlockingDialogTarget?
        let strayMenuTarget: AXUIElement?
        let sheet: AXUIElement?
        let createButton: AXUIElement?
        let deleteButton: AXUIElement?
    }

    /// Read the complete blocker set into `ModalSignals`. `.none` is emitted
    /// only after the main-window sheet, every top-level dialog, and the menu
    /// bar each produced a successful absent read; an unavailable source is an
    /// unknown blocking sheet, never an empty answer.
    static func readModalSignals(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalReconciliation.ModalSignals {
        readModalSignalsAndAlertTarget(runtime: runtime).signals
    }

    /// #453 / #538: the same read, keeping every actionable element so the
    /// executor can act on the element that was classified instead of
    /// re-resolving it through a fresh ordinal AX path.
    static func readModalSignalsAndAlertTarget(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalSignalRead {
        readModalSignalsAndAlertTarget(runtime: runtime, mainWindow: modalMainWindow(runtime: runtime))
    }

    private static func readModalSignalsAndAlertTarget(
        runtime: AXLogicProElements.Runtime,
        mainWindow: ModalMainWindowLookup
    ) -> ModalSignalRead {
        let window: AXUIElement
        switch mainWindow {
        case .found(let observed):
            window = observed
        case .absent:
            // No main window means no main-window sheet. The other two blocker kinds are still
            // read below, so this stays a complete observation rather than an unknown one.
            switch topLevelDialogRead(runtime: runtime) {
            case .unreadable, .blocking:
                return unreadableModalSignals()
            case .informational(let target):
                return noSheetModalSignals(
                    strayMenuOpen: false,
                    topLevelAlertPresent: true,
                    topLevelAlertButtonCount: target.info.buttonTitles.count,
                    topLevelAlertPrimaryButton: target.info.buttonTitles.first ?? "",
                    alertTarget: target
                )
            case .none:
                switch strayMenuTargetRead(runtime: runtime) {
                case .selected(let target):
                    return noSheetModalSignals(strayMenuOpen: true, strayMenuTarget: target)
                case .none:
                    return noSheetModalSignals(strayMenuOpen: false)
                case .unreadable:
                    return unreadableModalSignals()
                }
            }
        case .unreadable:
            return unreadableModalSignals()
        }

        switch firstSheetLookup(in: window, maxDepth: 32, runtime: runtime.ax) {
        case .found(let sheet):
            // A sheet already proves this is not a clean pass. It outranks the
            // other blocker kinds, so no action target from another window is
            // carried into this classification.
            return readModalSignals(from: sheet, runtime: runtime)
        case .incomplete, .unreadable(_):
            return unreadableModalSignals()
        case .absent:
            break
        }

        // A sheet is absent only after the status-preserving traversal above.
        // To return `.none`, the other two blocker kinds must now also be read
        // completely. A present dialog/menu is already sufficient to block; a
        // failed read is represented as an unknown sheet and cannot certify A.
        switch topLevelDialogRead(runtime: runtime) {
        case .unreadable, .blocking:
            return unreadableModalSignals()
        case .informational(let target):
            return noSheetModalSignals(
                strayMenuOpen: false,
                topLevelAlertPresent: true,
                topLevelAlertButtonCount: target.info.buttonTitles.count,
                topLevelAlertPrimaryButton: target.info.buttonTitles.first ?? "",
                alertTarget: target
            )
        case .none:
            switch strayMenuTargetRead(runtime: runtime) {
            case .selected(let target):
                return noSheetModalSignals(strayMenuOpen: true, strayMenuTarget: target)
            case .none:
                return noSheetModalSignals(strayMenuOpen: false)
            case .unreadable:
                return unreadableModalSignals()
            }
        }
    }

    /// This intentionally reads the app's `AXMainWindow` directly. The general
    /// `mainWindow` helper is a best-effort arrange-window finder and its `nil`
    /// answer is useful to ordinary UI discovery; here a missing or failed main
    /// window read cannot prove that a sheet is absent.
    /// Three outcomes, not two. Collapsing "there is no main window" into "the main window could
    /// not be read" made `project.new` report an unknown blocking sheet during the window it exists
    /// to describe: between choosing a template and Logic publishing the arrange window there IS no
    /// main window, and that is an answer. Only a failed read is unreadable.
    private enum ModalMainWindowLookup {
        case found(AXUIElement)
        case absent
        case unreadable
    }

    private static func modalMainWindow(
        runtime: AXLogicProElements.Runtime
    ) -> ModalMainWindowLookup {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return .unreadable }
        switch AXHelpers.getAttributeResult(
            app, kAXMainWindowAttribute as String, runtime: runtime.ax
        ) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(.some(let window)):
            return .found(window)
        case .success(.none):
            return .absent
        case .failure(let error) where axStatusIsDefinitiveAbsence(error):
            return .absent
        case .failure:
            return .unreadable
        }
    }

    private static func modalMainWindowLookup(
        from arrangeWindow: AXLogicProElements.ArrangeWindowRead
    ) -> ModalMainWindowLookup {
        switch arrangeWindow {
        case .found(let window): return .found(window)
        case .absent: return .absent
        case .unreadable: return .unreadable
        }
    }

    private static func noSheetModalSignals(
        strayMenuOpen: Bool,
        topLevelAlertPresent: Bool = false,
        topLevelAlertButtonCount: Int = 0,
        topLevelAlertPrimaryButton: String = "",
        alertTarget: AXLogicProElements.BlockingDialogTarget? = nil,
        strayMenuTarget: AXUIElement? = nil
    ) -> ModalSignalRead {
        ModalSignalRead(
            signals: ModalReconciliation.ModalSignals(
                sheetPresent: false,
                sheetDescription: "",
                createButtonPresent: false,
                cancelButtonPresent: false,
                cancelButtonEnabled: false,
                deleteConfirmButtonPresent: false,
                strayMenuOpen: strayMenuOpen,
                topLevelAlertPresent: topLevelAlertPresent,
                topLevelAlertButtonCount: topLevelAlertButtonCount,
                topLevelAlertPrimaryButton: topLevelAlertPrimaryButton,
                createButtonTitle: "",
                cancelButtonTitle: "",
                deletePrimaryTitle: ""
            ),
            alertTarget: alertTarget,
            strayMenuTarget: strayMenuTarget,
            sheet: nil,
            createButton: nil,
            deleteButton: nil
        )
    }

    /// The common fail-closed projection for any incomplete blocker read.
    /// `unknownSheet` is the pure classifier's established representation for
    /// an unknown blocker, including an unreadable source rather than a literal
    /// sheet node.
    private static func unreadableModalSignals() -> ModalSignalRead {
        ModalSignalRead(
            signals: ModalReconciliation.ModalSignals(
                sheetPresent: true,
                sheetDescription: "",
                createButtonPresent: false,
                cancelButtonPresent: false,
                cancelButtonEnabled: true,
                deleteConfirmButtonPresent: false,
                strayMenuOpen: false,
                topLevelAlertPresent: false,
                topLevelAlertButtonCount: 0,
                topLevelAlertPrimaryButton: "",
                createButtonTitle: "",
                cancelButtonTitle: "",
                deletePrimaryTitle: ""
            ),
            alertTarget: nil,
            strayMenuTarget: nil,
            sheet: nil,
            createButton: nil,
            deleteButton: nil
        )
    }

    private static func readModalSignals(
        from sheet: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> ModalSignalRead {
        let description = (AXHelpers.getAttribute(sheet, kAXDescriptionAttribute, runtime: runtime.ax) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // #350: resolve each button's on-screen label ONCE, then match locale-
        // aware against the AXLocalePolicy LabelSets (EN + KO + JA) so Korean and
        // Japanese Logic's localized New Track sheets are recognized, not just
        // the English literals.
        // The resolved elements are threaded to the executor so it presses the
        // REAL localized control rather than re-finding a title under an ordinal
        // window/sheet path.
        let labeled = AXHelpers.findAllDescendants(
            of: sheet, role: kAXButtonRole as String, maxDepth: 6, runtime: runtime.ax
        ).map { (element: $0, label: buttonLabel($0, runtime: runtime.ax)) }

        let createButton = labeled.first { AXLocalePolicy.createButton.matches($0.label, mode: .exact) }
        let cancelButton = labeled.first { AXLocalePolicy.cancelButton.matches($0.label, mode: .exact) }
        // Delete-confirm primary: localized LabelSet (EN only today) OR the
        // structural English `Delete ` prefix. The KO title is unverified, so an
        // unrecognized KO sheet remains fail-closed; no keyboard fallback is sent.
        let deleteButton = labeled.first {
            AXLocalePolicy.deleteTracksPrimaryButton.matches($0.label, mode: .exact)
                || $0.label.hasPrefix("Delete ")
        }
        // Fail-closed default: an unreadable enabled state is treated as ENABLED
        // so a normal cancelable sheet is never mistaken for the mandatory one
        // (which would auto-click "Create" — a side effect we must not guess).
        let cancelEnabled: Bool = cancelButton
            .flatMap { AXHelpers.getAttribute($0.element, kAXEnabledAttribute, runtime: runtime.ax) as Bool? }
            ?? true

        return ModalSignalRead(signals: ModalReconciliation.ModalSignals(
            sheetPresent: true,
            sheetDescription: description,
            createButtonPresent: createButton != nil,
            cancelButtonPresent: cancelButton != nil,
            cancelButtonEnabled: cancelEnabled,
            deleteConfirmButtonPresent: deleteButton != nil,
            strayMenuOpen: false,
            topLevelAlertPresent: false,
            topLevelAlertButtonCount: 0,
            topLevelAlertPrimaryButton: "",
            createButtonTitle: createButton?.label ?? "",
            cancelButtonTitle: cancelButton?.label ?? "",
            deletePrimaryTitle: deleteButton?.label ?? ""
        // A sheet outranks a top-level alert, so no alert target is carried here:
        // the alert branch above is the only one that can reach the acknowledge
        // executor, and handing back a target on this path would let a future
        // caller act on a dialog this pass deliberately did not classify.
        ),
        alertTarget: nil,
        strayMenuTarget: nil,
        sheet: sheet,
        createButton: createButton?.element,
        deleteButton: deleteButton?.element)
    }

    /// A complete top-level scan can find an auto-acknowledgeable AXDialog, a
    /// different blocking dialog (notably AXSystemDialog), no dialog, or fail.
    /// The latter two must never be conflated: only `.none` participates in a
    /// clean State-A observation.
    private enum TopLevelDialogRead {
        case none
        case informational(AXLogicProElements.BlockingDialogTarget)
        case blocking
        case unreadable
    }

    /// Read every top-level window with a status-preserving `AXModal` lookup.
    /// Modality decides whether a window blocks; its subrole only determines
    /// whether this reconciler can classify it as an actionable informational
    /// alert or must retain it as an unknown blocker. An unreadable `AXWindows`
    /// list cannot be replaced with focused/main-window best-effort discovery:
    /// that would leave other top-level modals unexamined and falsely certify a
    /// clean blocker set.
    private static func topLevelDialogRead(
        runtime: AXLogicProElements.Runtime
    ) -> TopLevelDialogRead {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unreadable
        }
        switch AXHelpers.getAttributeResult(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(let windows):
            return topLevelDialogRead(in: windows ?? [], runtime: runtime)
        case .failure(let error) where error.raw == AXError.noValue.rawValue:
            return .none
        case .failure:
            return .unreadable
        }
    }

    private static func topLevelDialogRead(
        in windows: [AXUIElement],
        runtime: AXLogicProElements.Runtime
    ) -> TopLevelDialogRead {
        var firstBlockingDialog: (element: AXUIElement, subrole: String)?
        for window in windows {
            switch AXHelpers.getAttributeResult(
                window, kAXModalAttribute as String, runtime: runtime.ax
            ) as Result<Bool?, AXHelpers.AXStatusError> {
            case .success(.some(false)):
                continue
            case .success(.none):
                // `AXModal` is recommended rather than required. A successful
                // nil is also what the typed helper produces for a malformed
                // payload, so neither establishes that this window is non-modal.
                return .unreadable
            case .failure:
                // Missing `AXModal` is likewise not an explicit false. Unlike
                // AXSheets, -25205/-25212 cannot be treated as structural
                // absence here without guessing that an unobservable window is
                // non-modal and letting it certify State A.
                return .unreadable
            case .success(.some(true)):
                break
            }

            // `AXModal == true` is already enough to make this window block.
            // Retain the same status-preserving subrole value for the exclusion
            // and alert-target paths; asking the best-effort API again here used
            // to turn a confirmed AXDialog into a clean observation on a transient
            // `cannotComplete` response.
            switch AXHelpers.getAttributeResult(
                window, kAXSubroleAttribute as String, runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let subrole):
                let knownSubrole = subrole ?? ""
                guard AXLogicProElements.isBlockingModalWindow(
                    window,
                    observedSubrole: subrole,
                    runtime: runtime.ax
                ) else { continue }
                if firstBlockingDialog == nil {
                    firstBlockingDialog = (window, knownSubrole)
                }
            case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                if firstBlockingDialog == nil {
                    firstBlockingDialog = (window, "")
                }
            case .failure:
                // We cannot name the modal kind, but AXModal already proved that
                // it blocks. This remains a blocker rather than an unreadable
                // answer or, worse, a clean one.
                return .blocking
            }
        }
        guard let firstBlockingDialog else { return .none }
        guard firstBlockingDialog.subrole == (kAXDialogSubrole as String),
              let target = AXLogicProElements.blockingDialogTarget(
                firstBlockingDialog.element,
                observedSubrole: firstBlockingDialog.subrole,
                runtime: runtime
              ),
              target.info.role == (kAXDialogSubrole as String)
        else {
            // Includes AXSystemDialog and any dialog whose identity/buttons
            // cannot be safely bound to the single-button acknowledge path.
            return .blocking
        }
        return .informational(target)
    }

    private enum SheetLookup {
        case found(AXUIElement)
        case absent
        case incomplete
        case unreadable(AXHelpers.AXStatusError)
    }

    /// Status-preserving sheet lookup used for classification and for a clean
    /// State-A gate. `attributeUnsupported` and `noValue` are structural answers
    /// and fall through to the role traversal; a malformed successful payload,
    /// a failed read, or a reached depth cap is *not* absence.
    private static func firstSheetLookup(
        in window: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> SheetLookup {
        switch AXHelpers.getAttributeResult(window, "AXSheets", runtime: runtime) as Result<AnyObject?, AXHelpers.AXStatusError> {
        case .failure(let error):
            guard axStatusIsDefinitiveAbsence(error) else {
                return .unreadable(error)
            }
        case .success(.some(let value)):
            guard CFGetTypeID(value) == CFArrayGetTypeID() else {
                return .unreadable(.malformedChildren)
            }
            let sheets = AXHelpers.decodeChildrenArray(value)
            if let sheet = sheets.first { return .found(sheet) }
        case .success(.none):
            break
        }
        return findSheetDescendantLookup(in: window, maxDepth: maxDepth, runtime: runtime)
    }


    /// Two AX statuses are ANSWERS, not failures, and conflating them with a failed reading is what
    /// made this witness unusable: `attributeUnsupported` (-25205) means the element does not vend
    /// that attribute at all, and `noValue` (-25212) means it has none. Measured on Logic 12.3 the
    /// arrange window returns -25205 for `AXSheets` and -25212 for a childless node, so treating
    /// either as "could not read" made every poll unreadable and no close was ever observable.
    /// Everything else — cannot-complete, invalid element, API disabled — really is a failed read.
    private static func axStatusIsDefinitiveAbsence(_ error: AXHelpers.AXStatusError) -> Bool {
        error.raw == AXError.attributeUnsupported.rawValue || error.raw == AXError.noValue.rawValue
    }

    /// Recurses through the fallback tree without flattening failed children or
    /// role reads. Any unreadable or unvisited node makes the whole no-sheet
    /// claim indeterminate: a partial tree cannot prove that a sheet is absent.
    private static func findSheetDescendantLookup(
        in element: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> SheetLookup {
        guard maxDepth > 0 else { return .incomplete }
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .failure(let error):
            // A node with no children is an answer: nothing here, keep looking elsewhere.
            guard !axStatusIsDefinitiveAbsence(error) else { return .absent }
            return .unreadable(error)
        case .success(let children):
            var sawIncomplete = false
            for child in children {
                switch AXHelpers.getAttributeResult(child, kAXRoleAttribute as String, runtime: runtime) as Result<String?, AXHelpers.AXStatusError> {
                case .failure(let error):
                    return .unreadable(error)
                case .success(let role):
                    if role == (kAXSheetRole as String) {
                        return .found(child)
                    }
                }
                switch findSheetDescendantLookup(in: child, maxDepth: maxDepth - 1, runtime: runtime) {
                case .found(let sheet):
                    return .found(sheet)
                case .unreadable(let error):
                    return .unreadable(error)
                case .incomplete:
                    sawIncomplete = true
                case .absent:
                    continue
                }
            }
            return sawIncomplete ? .incomplete : .absent
        }
    }

    /// Collect and log every post-action poll. This deliberately does not alter
    /// `performed`: #538 needs this evidence before choosing an observation that
    /// can truthfully replace an action-result acknowledgement.
    static func boundSheetWitnessObservation(
        _ sheet: AXUIElement,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalSheetWitnessObservation {
        switch AXHelpers.getAttributeResult(sheet, kAXRoleAttribute as String, runtime: runtime.ax) as Result<String?, AXHelpers.AXStatusError> {
        case .success(_):
            return .present
        case .failure(let error) where error.raw == AXError.invalidUIElement.rawValue:
            // This is an identity-bound observation: unlike a window lookup,
            // invalidUIElement means this exact captured sheet no longer exists.
            return .gone
        case .failure(let error):
            return .unreadable(.sheet(error))
        }
    }

    static func pollBoundSheetWitness(
        _ sheet: AXUIElement,
        runtime: AXLogicProElements.Runtime = .production,
        observationAttempts: Int = 30,
        observationDelayNanoseconds: UInt64 = 100_000_000
    ) async -> [ModalSheetWitnessPoll] {
        let attempts = max(1, observationAttempts)
        var polls: [ModalSheetWitnessPoll] = []
        for index in 1...attempts {
            let poll = ModalSheetWitnessPoll(
                index: index,
                observation: boundSheetWitnessObservation(sheet, runtime: runtime)
            )
            polls.append(poll)
            Log.info(
                "modal_sheet_witness poll=\(poll.index) status=\(poll.diagnosticLabel)",
                subsystem: .ax
            )
            if poll.observation == .gone { break }
            if index < attempts {
                try? await Task.sleep(nanoseconds: observationDelayNanoseconds)
            }
        }
        return polls
    }

    /// A top-level-alert witness stays on the alert element captured by the
    /// classifier. A fresh "is any AXDialog present?" scan can call a replacement
    /// AXSystemDialog or floating modal "gone" while another blocker remains.
    enum ModalTopLevelAlertWitnessObservation: Sendable, Equatable {
        case present
        case gone
        case unreadable(ModalTopLevelAlertWitnessReadFailure)

        var diagnosticLabel: String {
            switch self {
            case .present: return "present"
            case .gone: return "gone"
            case .unreadable(let failure): return "unreadable_\(failure.diagnosticLabel)"
            }
        }
    }

    enum ModalTopLevelAlertWitnessReadFailure: Sendable, Equatable {
        case alertModal(AXHelpers.AXStatusError)

        var diagnosticLabel: String {
            switch self {
            case .alertModal(let error): return "alert_modal_\(error.diagnosticLabel)"
            }
        }
    }

    static func boundTopLevelAlertWitnessObservation(
        _ alert: AXUIElement,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalTopLevelAlertWitnessObservation {
        switch AXHelpers.getAttributeResult(
            alert, kAXModalAttribute as String, runtime: runtime.ax
        ) as Result<Bool?, AXHelpers.AXStatusError> {
        case .success(.some):
            // The captured identity remains readable. Whether it now says true
            // or false, it did not disappear; only the complete follow-up scan
            // decides whether any blocker remains.
            return .present
        case .success(.none):
            return .unreadable(.alertModal(.malformedAttribute))
        case .failure(let error) where error.raw == AXError.invalidUIElement.rawValue:
            return .gone
        case .failure(let error):
            return .unreadable(.alertModal(error))
        }
    }

    /// A menu witness uses AXMenuBar → children → AXSelected. Both an absent
    /// menu-bar attribute and childless menu bar are structural answers: no menu
    /// can be open there. A non-absence status on any required read is retained
    /// as unreadable instead of being flattened to `gone`.
    enum ModalStrayMenuWitnessObservation: Sendable, Equatable {
        case present
        case gone
        case unreadable(ModalStrayMenuWitnessReadFailure)

        var diagnosticLabel: String {
            switch self {
            case .present: return "present"
            case .gone: return "gone"
            case .unreadable(let failure): return "unreadable_\(failure.diagnosticLabel)"
            }
        }
    }

    enum ModalStrayMenuWitnessReadFailure: Sendable, Equatable {
        case appRootUnavailable
        case menuBar(AXHelpers.AXStatusError)
        case menuChildren(AXHelpers.AXStatusError)
        case menuItemSelected(AXHelpers.AXStatusError)

        var diagnosticLabel: String {
            switch self {
            case .appRootUnavailable: return "app_root"
            case .menuBar(let error): return "menu_bar_\(error.diagnosticLabel)"
            case .menuChildren(let error): return "menu_children_\(error.diagnosticLabel)"
            case .menuItemSelected(let error): return "menu_item_selected_\(error.diagnosticLabel)"
            }
        }
    }

    private enum StrayMenuTargetRead {
        case selected(AXUIElement)
        case none
        case unreadable(ModalStrayMenuWitnessReadFailure)
    }

    private static func strayMenuTargetRead(
        runtime: AXLogicProElements.Runtime
    ) -> StrayMenuTargetRead {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unreadable(.appRootUnavailable)
        }
        switch AXHelpers.getAttributeResult(app, kAXMenuBarAttribute as String, runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(.none):
            return .none
        case .success(.some(let menuBar)):
            switch AXHelpers.childrenResult(menuBar, runtime: runtime.ax) {
            case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                return .none
            case .failure(let error):
                return .unreadable(.menuChildren(error))
            case .success(let items):
                for item in items {
                    switch AXHelpers.getAttributeResult(item, kAXSelectedAttribute as String, runtime: runtime.ax) as Result<Bool?, AXHelpers.AXStatusError> {
                    case .success(.some(true)):
                        return .selected(item)
                    case .success(.some(false)):
                        continue
                    case .success(.none):
                        return .unreadable(.menuItemSelected(.malformedAttribute))
                    case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                        continue
                    case .failure(let error):
                        return .unreadable(.menuItemSelected(error))
                    }
                }
                return .none
            }
        case .failure(let error) where axStatusIsDefinitiveAbsence(error):
            return .none
        case .failure(let error):
            return .unreadable(.menuBar(error))
        }
    }

    static func boundStrayMenuWitnessObservation(
        _ menuItem: AXUIElement,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalStrayMenuWitnessObservation {
        switch AXHelpers.getAttributeResult(
            menuItem, kAXSelectedAttribute as String, runtime: runtime.ax
        ) as Result<Bool?, AXHelpers.AXStatusError> {
        case .success(.some(true)):
            return .present
        case .success(.some(false)):
            return .gone
        case .success(.none):
            return .unreadable(.menuItemSelected(.malformedAttribute))
        case .failure(let error) where error.raw == AXError.invalidUIElement.rawValue:
            return .gone
        case .failure(let error):
            return .unreadable(.menuItemSelected(error))
        }
    }

    private static func pollBoundTopLevelAlertWitness(
        _ alert: AXUIElement?,
        runtime: AXLogicProElements.Runtime,
        observationAttempts: Int,
        observationDelayNanoseconds: UInt64
    ) async -> ModalReconcileWitnessSummary {
        guard let alert else {
            return ModalReconcileWitnessSummary(labels: ["unreadable_alert_target"])
        }
        let attempts = max(1, observationAttempts)
        var labels: [String] = []
        for index in 1...attempts {
            let observation = boundTopLevelAlertWitnessObservation(alert, runtime: runtime)
            labels.append(observation.diagnosticLabel)
            Log.info("modal_alert_witness poll=\(index) status=\(observation.diagnosticLabel)", subsystem: .ax)
            if observation == .gone { break }
            if index < attempts {
                try? await Task.sleep(nanoseconds: observationDelayNanoseconds)
            }
        }
        return ModalReconcileWitnessSummary(labels: labels)
    }

    private static func pollBoundStrayMenuWitness(
        _ menuItem: AXUIElement?,
        runtime: AXLogicProElements.Runtime,
        observationAttempts: Int,
        observationDelayNanoseconds: UInt64
    ) async -> ModalReconcileWitnessSummary {
        guard let menuItem else {
            return ModalReconcileWitnessSummary(labels: ["unreadable_menu_target"])
        }
        let attempts = max(1, observationAttempts)
        var labels: [String] = []
        for index in 1...attempts {
            let observation = boundStrayMenuWitnessObservation(menuItem, runtime: runtime)
            labels.append(observation.diagnosticLabel)
            Log.info("modal_menu_witness poll=\(index) status=\(observation.diagnosticLabel)", subsystem: .ax)
            if observation == .gone { break }
            if index < attempts {
                try? await Task.sleep(nanoseconds: observationDelayNanoseconds)
            }
        }
        return ModalReconcileWitnessSummary(labels: labels)
    }

    /// A button's visible label — `AXTitle` first (what AppleScript `button "X"`
    /// matches), falling back to `AXDescription` for buttons that only expose the
    /// description.
    private static func buttonLabel(_ button: AXUIElement, runtime: AXHelpers.Runtime) -> String {
        (AXHelpers.getTitle(button, runtime: runtime)
            ?? AXHelpers.getDescription(button, runtime: runtime)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Executor

    private struct ModalActionPerformResult {
        let performed: Bool
        let actionAttempted: Bool
        let refusal: AlertAcknowledgeRefusal?
        let actionFailure: AXHelpers.AXActionError?
        let sheetWitness: [ModalSheetWitnessPoll]
        let witnessSummary: ModalReconcileWitnessSummary?
    }

    private static func perform(
        _ decision: ModalReconciliation.ModalReconcileDecision,
        alertTarget: AXLogicProElements.BlockingDialogTarget?,
        strayMenuTarget: AXUIElement?,
        sheet: AXUIElement?,
        mainWindow: ModalMainWindowLookup,
        createButton: AXUIElement?,
        deleteButton: AXUIElement?,
        runtime: AXLogicProElements.Runtime,
        witnessAttempts: Int,
        witnessDelayNanoseconds: UInt64
    ) async -> ModalActionPerformResult {
        switch decision {
        case .noAction, .failClosed:
            return ModalActionPerformResult(
                performed: false, actionAttempted: false, refusal: nil, actionFailure: nil, sheetWitness: [], witnessSummary: nil
            )
        case .clickCreate:
            let action = clickNewTrackCreateButton(
                createButton: createButton,
                runtime: runtime
            )
            let witness: [ModalSheetWitnessPoll]
            if let sheet {
                witness = await pollBoundSheetWitness(
                    sheet,
                    runtime: runtime,
                    observationAttempts: witnessAttempts,
                    observationDelayNanoseconds: witnessDelayNanoseconds
                )
            } else {
                witness = []
            }
            var summary = ModalReconcileWitnessSummary(sheetWitness: witness)
            let completeBlockerSetIsClear = summary.observedGone
                && completeModalReadIsClear(runtime: runtime, mainWindow: mainWindow)
            summary = summary.withBlockerSetClear(completeBlockerSetIsClear)
            Log.info(
                "modal_sheet_confirmation action=click_create accepted=\(action.accepted) "
                    + "bound_sheet_gone=\(summary.observedGone) blocker_set_clear=\(completeBlockerSetIsClear)",
                subsystem: .ax
            )
            return ModalActionPerformResult(
                // AX accepts a press before Logic applies it. A subsequently
                // invalid sheet identity only says that this sheet disappeared;
                // it cannot distinguish our press from the user closing it.
                // Keep the direct action and bound observations in the receipt,
                // but never turn that temporal correlation into a causal claim.
                performed: false,
                actionAttempted: action.attempted,
                refusal: nil,
                actionFailure: action.failure,
                sheetWitness: witness,
                witnessSummary: summary
            )
        case .confirmDelete:
            let action = confirmDeleteTracksSheet(
                deleteButton: deleteButton,
                runtime: runtime
            )
            let witness: [ModalSheetWitnessPoll]
            if let sheet {
                witness = await pollBoundSheetWitness(
                    sheet,
                    runtime: runtime,
                    observationAttempts: witnessAttempts,
                    observationDelayNanoseconds: witnessDelayNanoseconds
                )
            } else {
                witness = []
            }
            var summary = ModalReconcileWitnessSummary(sheetWitness: witness)
            let completeBlockerSetIsClear = summary.observedGone
                && completeModalReadIsClear(runtime: runtime, mainWindow: mainWindow)
            summary = summary.withBlockerSetClear(completeBlockerSetIsClear)
            Log.info(
                "modal_sheet_confirmation action=confirm_delete accepted=\(action.accepted) "
                    + "bound_sheet_gone=\(summary.observedGone) blocker_set_clear=\(completeBlockerSetIsClear)",
                subsystem: .ax
            )
            return ModalActionPerformResult(
                // See clickCreate above: the observations establish only that
                // the captured sheet is gone, not what caused the close.
                performed: false,
                actionAttempted: action.attempted,
                refusal: nil,
                actionFailure: action.failure,
                sheetWitness: witness,
                witnessSummary: summary
            )
        case .acknowledgeAlert:
            let result = acknowledgeTopLevelAlert(target: alertTarget, runtime: runtime)
            var summary = await pollBoundTopLevelAlertWitness(
                alertTarget?.element,
                runtime: runtime,
                observationAttempts: witnessAttempts,
                observationDelayNanoseconds: witnessDelayNanoseconds
            )
            let completeBlockerSetIsClear = summary.observedGone
                && completeModalReadIsClear(runtime: runtime, mainWindow: mainWindow)
            summary = summary.withBlockerSetClear(completeBlockerSetIsClear)
            return ModalActionPerformResult(
                // A direct press and a later disappearance are not proof that
                // our press closed this alert. The bound identity and complete
                // blocker-set observations are retained in the receipt instead.
                performed: false,
                actionAttempted: result.attempted,
                refusal: result.refusal,
                actionFailure: result.actionFailure,
                sheetWitness: [],
                witnessSummary: summary
            )
        case .escapeMenu:
            let actionAccepted = await sendEscapeKey(runtime: runtime)
            var summary = await pollBoundStrayMenuWitness(
                strayMenuTarget,
                runtime: runtime,
                observationAttempts: witnessAttempts,
                observationDelayNanoseconds: witnessDelayNanoseconds
            )
            let completeBlockerSetIsClear = summary.observedGone
                && completeModalReadIsClear(runtime: runtime, mainWindow: mainWindow)
            summary = summary.withBlockerSetClear(completeBlockerSetIsClear)
            Log.info(
                "modal_menu_confirmation escape_accepted=\(actionAccepted) "
                    + "bound_menu_gone=\(summary.observedGone) blocker_set_clear=\(completeBlockerSetIsClear)",
                subsystem: .ax
            )
            return ModalActionPerformResult(
                // Escape has the same timing gap as a direct press: a menu may
                // close for another reason before its bound target is polled.
                performed: false,
                actionAttempted: true,
                refusal: nil,
                actionFailure: nil,
                sheetWitness: [],
                witnessSummary: summary
            )
        }
    }

    /// Re-read the complete blocker set against the exact sheet host that the
    /// action targeted. `AXMainWindow` can drift while a sheet is closing, so a
    /// fresh main-window lookup could inspect an auxiliary window and miss a
    /// replacement sheet still attached to the arrange window.
    static func freshCompleteModalReadIsClear(
        in sheetHost: AXUIElement?,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let sheetHost else { return false }
        return completeModalReadIsClear(runtime: runtime, mainWindow: .found(sheetHost))
    }

    private static func completeModalReadIsClear(
        runtime: AXLogicProElements.Runtime,
        mainWindow: ModalMainWindowLookup
    ) -> Bool {
        ModalReconciliation.classify(
            readModalSignalsAndAlertTarget(
                runtime: runtime,
                mainWindow: mainWindow
            ).signals
        ) == .none
    }

    /// Press the mandatory New Track sheet's resolved `Create` / `생성` element.
    /// Escape/Cancel are inert on this sheet; an unavailable or rejected element
    /// is reported by the false action result and is never replaced by a fresh
    /// ordinal lookup.
    private static func clickNewTrackCreateButton(
        createButton: AXUIElement?,
        runtime: AXLogicProElements.Runtime
    ) -> (attempted: Bool, accepted: Bool, failure: AXHelpers.AXActionError?) {
        guard let createButton else { return (false, false, nil) }
        switch AXHelpers.performActionResult(createButton, kAXPressAction as String, runtime: runtime.ax) {
        case .success:
            return (true, true, nil)
        case .failure(let error):
            return (true, false, error)
        }
    }

    /// Confirm the delete-channel-strips sheet by pressing its resolved primary
    /// destructive button. A missing or rejected element is an unperformed
    /// action, not permission to send Return at an unidentified sheet.
    private static func confirmDeleteTracksSheet(
        deleteButton: AXUIElement?,
        runtime: AXLogicProElements.Runtime
    ) -> (attempted: Bool, accepted: Bool, failure: AXHelpers.AXActionError?) {
        guard let deleteButton else { return (false, false, nil) }
        switch AXHelpers.performActionResult(deleteButton, kAXPressAction as String, runtime: runtime.ax) {
        case .success:
            return (true, true, nil)
        case .failure(let error):
            return (true, false, error)
        }
    }

    /// Acknowledge a single-button top-level informational alert.
    ///
    /// #453: the classifier gates this to EXACTLY ONE titled button — two or more
    /// means a choice, and choices are never auto-answered. That decision used to
    /// be made once and then thrown away: the executor re-resolved `first window
    /// whose subrole is "AXDialog"` in AppleScript and clicked, so a dialog that
    /// arrived in between was clicked though it was never classified, and a failed
    /// title lookup fell through to `click button 1` with no count check at all.
    /// On that fallback the safety discriminator did not participate.
    ///
    /// The gate is now enforced where the click happens, and three things changed
    /// to make that possible:
    ///
    /// - The dialog is the ELEMENT the classifier read, carried here directly. No
    ///   predicate is evaluated a second time, so there is no window in which a
    ///   different dialog can be substituted.
    /// - The button set is re-read from that element immediately before pressing
    ///   and must still be exactly one. A dialog that gained a button between
    ///   classification and click is refused.
    /// - The first-button fallback is gone. There is no path that presses a
    ///   control the single-button rule did not authorize.
    ///
    /// Refusal is the safe direction: an unacknowledged alert leaves the operator
    /// with a visible dialog, while a wrong click answers a question on their
    /// behalf and cannot be undone.
    private static func acknowledgeTopLevelAlert(
        target: AXLogicProElements.BlockingDialogTarget?,
        runtime: AXLogicProElements.Runtime
    ) -> (attempted: Bool, pressed: Bool, refusal: AlertAcknowledgeRefusal?, actionFailure: AXHelpers.AXActionError?) {
        guard let target else { return (false, false, .targetUnavailable, nil) }

        // Re-read the complete AXModal-gated top-level set and require the
        // currently actionable alert to be the SAME element. The older generic
        // dialog helper identifies by subrole only, which would let a window
        // that stopped vending `AXModal == true` reach a press. This is what
        // makes replacement, loss of modality, and several dialogs refusals
        // rather than silent mis-clicks.
        let current: AXLogicProElements.BlockingDialogTarget
        switch topLevelDialogRead(runtime: runtime) {
        case .informational(let observed):
            current = observed
        case .none:
            return (false, false, .targetGone, nil)
        case .blocking, .unreadable:
            return (false, false, .targetChanged, nil)
        }
        guard CFEqual(current.element, target.element) else {
            return (false, false, .targetChanged, nil)
        }

        // Re-read the count from the live element rather than trusting the count
        // captured at classification time.
        let buttons = AXLogicProElements.titledButtons(of: current.element, runtime: runtime.ax)
        guard buttons.count == 1, let only = buttons.first else {
            return (false, false, .buttonCountChanged, nil)
        }

        switch AXHelpers.performActionResult(only.element, kAXPressAction as String, runtime: runtime.ax) {
        case .success:
            return (true, true, nil, nil)
        case .failure(let error):
            return (true, false, .pressFailed, error)
        }
    }

    /// Send Escape (key code 53) to close a stray open menu.
    private static func sendEscapeKey(runtime: AXLogicProElements.Runtime) async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                key code 53
            end tell
        end tell
        return "escaped"
        """
        return await runtime.executeAppleScript(script).isSuccess
    }

    // MARK: - Extras labels

    /// Stable wire label for the reconciled modal kind (merged into op extras).
    static func reconcileKindLabel(_ kind: ModalReconciliation.BlockingModalKind) -> String {
        switch kind {
        case .none: return "none"
        case .mandatoryNewTrack: return "mandatory_new_track"
        case .deleteConfirm: return "delete_confirm"
        case .informationalAlert: return "informational_alert"
        case .strayMenu: return "stray_menu"
        case .unknownSheet: return "unknown_sheet"
        }
    }

    /// Stable wire label for the reconciliation action taken (merged into extras).
    static func reconcileActionLabel(_ decision: ModalReconciliation.ModalReconcileDecision) -> String {
        switch decision {
        case .noAction: return "none"
        case .clickCreate: return "click_create"
        case .confirmDelete: return "confirm_delete"
        case .acknowledgeAlert: return "acknowledge_alert"
        case .escapeMenu: return "escape_menu"
        case .failClosed: return "fail_closed"
        }
    }

    /// A reconciliation decision names a permitted action, not an action that
    /// occurred. Response envelopes may carry that label only after the bound
    /// executor actually issued its direct press/key event.
    static func attemptedReconcileActionLabel(_ outcome: ModalReconcileOutcome) -> String {
        outcome.actionAttempted ? reconcileActionLabel(outcome.decision) : "none"
    }

    /// Merge reconciliation provenance into an op's extras — only when a modal
    /// was actually observed, so the common (no-sheet) path stays noise-free.
    /// `new_track_dialog_auto_confirmed` is present only when the mandatory New
    /// Track sheet's "Create" was auto-clicked.
    static func mergeReconcileExtras(
        _ extras: inout [String: Any],
        kind: ModalReconciliation.BlockingModalKind,
        action: String,
        newTrackAutoConfirmed: Bool,
        witnessSummary: ModalReconcileWitnessSummary? = nil,
        refusal: AlertAcknowledgeRefusal? = nil,
        actionFailure: AXHelpers.AXActionError? = nil
    ) {
        guard kind != .none else { return }
        extras["reconciled_modal_kind"] = reconcileKindLabel(kind)
        extras["reconciled_action"] = action
        if newTrackAutoConfirmed {
            extras["new_track_dialog_auto_confirmed"] = true
        }
        if let witnessSummary {
            // Per-poll traces are deliberately debug-log-only. Responses retain
            // a compact count summary so callers can see whether the effect was
            // observed without receiving a 30-entry diagnostic array.
            extras["modal_reconciliation_witness"] = witnessSummary.envelopeValue
        }
        // #453: an authorized action the executor declined. Reported so a caller
        // can tell "we chose not to act" from "we tried and refused"; the value is
        // a fixed structural token, never dialog text or a button title.
        if let refusal {
            extras["reconcile_refused"] = refusal.rawValue
        }
        if let actionFailure {
            // AX statuses are structural diagnostics (for example, -25202 for
            // a stale element), not an assertion about whether another actor
            // subsequently closed the modal.
            extras["reconcile_action_error"] = actionFailure.diagnosticLabel
        }
    }
}
