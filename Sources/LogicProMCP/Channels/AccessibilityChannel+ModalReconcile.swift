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
        /// Per-poll post-action sheet observations. These stay in-process for
        /// debug logging and tests; response envelopes carry only
        /// `witnessSummary`, never this trace.
        let sheetWitness: [ModalSheetWitnessPoll]
        /// Compact, response-safe observation summary for the action's witness.
        /// `performed` is true only when this summary includes `gone`.
        let witnessSummary: ModalReconcileWitnessSummary?
        /// Set only when an authorized action was declined at execution time.
        /// `performed == false` alone cannot distinguish "the decision was not to
        /// act" from "the decision was to act and the executor refused", and
        /// those are very different things to report.
        let refusal: AlertAcknowledgeRefusal?

        init(
            kind: ModalReconciliation.BlockingModalKind,
            decision: ModalReconciliation.ModalReconcileDecision,
            performed: Bool,
            sheetWitness: [ModalSheetWitnessPoll] = [],
            witnessSummary: ModalReconcileWitnessSummary? = nil,
            refusal: AlertAcknowledgeRefusal? = nil
        ) {
            self.kind = kind
            self.decision = decision
            self.performed = performed
            self.sheetWitness = sheetWitness
            self.witnessSummary = witnessSummary
            self.refusal = refusal
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
        case appRootUnavailable
        case mainWindow(AXHelpers.AXStatusError)
        case childrenOrSheets(AXHelpers.AXStatusError)

        var diagnosticLabel: String {
            switch self {
            case .appRootUnavailable:
                return "app_root"
            case .mainWindow(let error):
                return "main_window_\(error.raw)"
            case .childrenOrSheets(let error):
                return "children_sheets_\(error.raw)"
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

        init(labels: [String]) {
            self.pollCount = labels.count
            self.observations = labels.reduce(into: [:]) { counts, label in
                counts[label, default: 0] += 1
            }
        }

        init(sheetWitness: [ModalSheetWitnessPoll]) {
            self.init(labels: sheetWitness.map(\.diagnosticLabel))
        }

        var observedGone: Bool {
            observations["gone", default: 0] > 0
        }

        var envelopeValue: [String: Any] {
            [
                "polls": pollCount,
                "observations": observations,
            ]
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
        let read = readModalSignalsAndAlertTarget(runtime: runtime)
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
            sheetWitness: result.sheetWitness,
            witnessSummary: result.witnessSummary,
            refusal: result.refusal
        )
    }

    // MARK: - Signal reader

    /// Read the main window's sheet into `ModalSignals`. When no sheet is
    /// present the only remaining blocker we reconcile is a stray open menu.
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
    ) -> (
        signals: ModalReconciliation.ModalSignals,
        alertTarget: AXLogicProElements.BlockingDialogTarget?,
        createButton: AXUIElement?,
        deleteButton: AXUIElement?
    ) {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let sheet = firstSheet(in: window, runtime: runtime.ax) else {
            // No main-window sheet: the remaining blockers are a top-level
            // informational alert (safe only when single-button) and a stray
            // open menu. Alert signals are populated ONLY here, so any sheet
            // above still outranks a top-level alert.
            let alert = topLevelAlertSignals(runtime: runtime)
            return (ModalReconciliation.ModalSignals(
                sheetPresent: false,
                sheetDescription: "",
                createButtonPresent: false,
                cancelButtonPresent: false,
                cancelButtonEnabled: false,
                deleteConfirmButtonPresent: false,
                strayMenuOpen: detectStrayMenuOpen(runtime: runtime),
                topLevelAlertPresent: alert.present,
                topLevelAlertButtonCount: alert.buttonCount,
                topLevelAlertPrimaryButton: alert.primaryButton,
                createButtonTitle: "",
                cancelButtonTitle: "",
                deletePrimaryTitle: ""
            ), alert.target, nil, nil)
        }

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
        // structural English `Delete ` prefix. The KO title is unverified, so KO
        // delete-confirm detection degrades to fail-closed + the Return fallback.
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

        return (ModalReconciliation.ModalSignals(
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
        ), nil, createButton?.element, deleteButton?.element)
    }

    /// Detect a TOP-LEVEL informational `AXDialog` alert (NOT a main-window
    /// sheet). Reuses `blockingDialogInfo` — which already scans top-level
    /// windows, excludes plugin-editor / keyboard-layout overlays, and returns
    /// the dialog's titled buttons — so the single-button safety gate applies to
    /// its `buttonTitles.count`. Restricted to the `AXDialog` subrole so it stays
    /// consistent with the executor's verified `subrole is "AXDialog"` targeting
    /// (an `AXSystemDialog` we could not dismiss is deliberately not claimed).
    private static func topLevelAlertSignals(
        runtime: AXLogicProElements.Runtime
    ) -> (present: Bool, buttonCount: Int, primaryButton: String, target: AXLogicProElements.BlockingDialogTarget?) {
        guard let target = AXLogicProElements.blockingDialogTarget(runtime: runtime),
              target.info.role == (kAXDialogSubrole as String) else {
            return (false, 0, "", nil)
        }
        return (true, target.info.buttonTitles.count, target.info.buttonTitles.first ?? "", target)
    }

    /// The main window's first attached sheet. Real AX exposes an open sheet via
    /// the window's `AXSheets` attribute (the `kAXSheetsAttribute` constant is not
    /// vended by ApplicationServices, so the raw name is used) AND as a descendant
    /// with role `AXSheet`; the role scan is the resilient fallback.
    private static func firstSheet(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        if let sheets: [AXUIElement] = AXHelpers.getAttribute(window, "AXSheets", runtime: runtime),
           let sheet = sheets.first {
            return sheet
        }
        return AXHelpers.findDescendant(
            of: window, role: kAXSheetRole as String, maxDepth: 4, runtime: runtime
        )
    }

    /// Status-preserving version of `firstSheet`. The ordinary reader above is
    /// intentionally best-effort for classification; a close witness cannot use
    /// it because `nil` there conflates a missing sheet with a failed AX read.
    private static func firstSheetResult(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<AXUIElement?, AXHelpers.AXStatusError> {
        switch AXHelpers.getAttributeResult(window, "AXSheets", runtime: runtime) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .failure(let error):
            // `kAXErrorAttributeUnsupported` (-25205) is a definitive answer — this element does not
            // vend AXSheets — not a failed reading. Measured on Logic 12.3: the arrange window never
            // vends it, so every poll of the witness returned "unreadable" and the sheet's close
            // could not be observed at all. That is why raising the bound from 250 ms to 2 s changed
            // nothing: it was never a race. Fall through to the role traversal, which CAN see it.
            // Any other status is a real read failure and stays unreadable.
            guard axStatusIsDefinitiveAbsence(error) else {
                return .failure(error)
            }
            return findSheetDescendantResult(in: window, maxDepth: 4, runtime: runtime)
        case .success(let sheets):
            if let sheet = sheets?.first {
                return .success(sheet)
            }
            return findSheetDescendantResult(in: window, maxDepth: 4, runtime: runtime)
        }
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
    /// role reads. Any unreadable node makes the whole no-sheet claim unreadable:
    /// a partial tree cannot prove that a sheet is gone.
    private static func findSheetDescendantResult(
        in element: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> Result<AXUIElement?, AXHelpers.AXStatusError> {
        guard maxDepth > 0 else { return .success(nil) }
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .failure(let error):
            // A node with no children is an answer: nothing here, keep looking elsewhere.
            guard !axStatusIsDefinitiveAbsence(error) else { return .success(nil) }
            return .failure(error)
        case .success(let children):
            for child in children {
                switch AXHelpers.getAttributeResult(child, kAXRoleAttribute as String, runtime: runtime) as Result<String?, AXHelpers.AXStatusError> {
                case .failure(let error):
                    return .failure(error)
                case .success(let role):
                    if role == (kAXSheetRole as String) {
                        return .success(child)
                    }
                }
                switch findSheetDescendantResult(in: child, maxDepth: maxDepth - 1, runtime: runtime) {
                case .failure(let error):
                    return .failure(error)
                case .success(let sheet):
                    if let sheet { return .success(sheet) }
                }
            }
            return .success(nil)
        }
    }

    /// Snapshot the current app-root → main-window → sheets path. The main
    /// window is resolved from the app root on *every* call so this trace can
    /// show whether that path is readable during a project-window replacement;
    /// it does not yet assume replacement explains any particular result.
    static func mainWindowSheetWitnessObservation(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalSheetWitnessObservation {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unreadable(.appRootUnavailable)
        }
        switch AXHelpers.getAttributeResult(app, kAXMainWindowAttribute as String, runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .failure(let error):
            return .unreadable(.mainWindow(error))
        case .success(let window):
            guard let window else { return .gone }
            switch firstSheetResult(in: window, runtime: runtime.ax) {
            case .success(.some):
                return .present
            case .success(.none):
                return .gone
            case .failure(let error):
                return .unreadable(.childrenOrSheets(error))
            }
        }
    }

    /// Collect and log every post-action poll. This deliberately does not alter
    /// `performed`: #538 needs this evidence before choosing an observation that
    /// can truthfully replace an action-result acknowledgement.
    static func pollMainWindowSheetWitness(
        runtime: AXLogicProElements.Runtime = .production,
        observationAttempts: Int = 30,
        observationDelayNanoseconds: UInt64 = 100_000_000
    ) async -> [ModalSheetWitnessPoll] {
        let attempts = max(1, observationAttempts)
        var polls: [ModalSheetWitnessPoll] = []
        for index in 1...attempts {
            let poll = ModalSheetWitnessPoll(
                index: index,
                observation: mainWindowSheetWitnessObservation(runtime: runtime)
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

    /// A top-level-alert witness is separate from the reader used to classify
    /// the alert: after pressing, it must positively observe that no AXDialog
    /// remains. The status-preserving path matters here too. `noValue` means the
    /// requested locator has no value; `attributeUnsupported` means that locator
    /// is unavailable and we fall back from AXWindows to the focused/main-window
    /// locators before deciding the alert is gone. Any other AX status is a real
    /// failed read and is never treated as disappearance.
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
        case appRootUnavailable
        case windows(AXHelpers.AXStatusError)
        case fallbackWindow(AXHelpers.AXStatusError)
        case windowSubrole(AXHelpers.AXStatusError)

        var diagnosticLabel: String {
            switch self {
            case .appRootUnavailable: return "app_root"
            case .windows(let error): return "windows_\(error.raw)"
            case .fallbackWindow(let error): return "fallback_window_\(error.raw)"
            case .windowSubrole(let error): return "window_subrole_\(error.raw)"
            }
        }
    }

    private static func topLevelAlertWitnessObservation(
        runtime: AXLogicProElements.Runtime
    ) -> ModalTopLevelAlertWitnessObservation {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unreadable(.appRootUnavailable)
        }
        switch AXHelpers.getAttributeResult(app, kAXWindowsAttribute as String, runtime: runtime.ax) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(let windows):
            return topLevelAlertWitnessObservation(in: windows ?? [], runtime: runtime.ax)
        case .failure(let error) where error.raw == AXError.noValue.rawValue:
            return .gone
        case .failure(let error) where error.raw == AXError.attributeUnsupported.rawValue:
            return topLevelAlertFallbackWitnessObservation(app: app, runtime: runtime.ax)
        case .failure(let error):
            return .unreadable(.windows(error))
        }
    }

    /// AXWindows is normally the complete top-level source. If Logic reports it
    /// unsupported, use the two live window locators rather than converting that
    /// answer into a read failure. A top-level blocking alert is frontmost, so a
    /// dialog found by either locator is still a positive `present`; real read
    /// errors remain unreadable.
    private static func topLevelAlertFallbackWitnessObservation(
        app: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> ModalTopLevelAlertWitnessObservation {
        var candidates: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            switch AXHelpers.getAttributeResult(app, attribute, runtime: runtime) as Result<AXUIElement?, AXHelpers.AXStatusError> {
            case .success(let window):
                if let window, !candidates.contains(where: { CFEqual($0, window) }) {
                    candidates.append(window)
                }
            case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                continue
            case .failure(let error):
                return .unreadable(.fallbackWindow(error))
            }
        }
        return topLevelAlertWitnessObservation(in: candidates, runtime: runtime)
    }

    private static func topLevelAlertWitnessObservation(
        in windows: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> ModalTopLevelAlertWitnessObservation {
        for window in windows {
            switch AXHelpers.getAttributeResult(window, kAXSubroleAttribute as String, runtime: runtime) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let subrole):
                if subrole == (kAXDialogSubrole as String) {
                    return .present
                }
            case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                // This window simply does not vend AXSubrole, so it cannot be
                // a positively observed AXDialog for this witness.
                continue
            case .failure(let error):
                return .unreadable(.windowSubrole(error))
            }
        }
        return .gone
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
            case .menuBar(let error): return "menu_bar_\(error.raw)"
            case .menuChildren(let error): return "menu_children_\(error.raw)"
            case .menuItemSelected(let error): return "menu_item_selected_\(error.raw)"
            }
        }
    }

    private static func strayMenuWitnessObservation(
        runtime: AXLogicProElements.Runtime
    ) -> ModalStrayMenuWitnessObservation {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unreadable(.appRootUnavailable)
        }
        switch AXHelpers.getAttributeResult(app, kAXMenuBarAttribute as String, runtime: runtime.ax) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(.none):
            return .gone
        case .success(.some(let menuBar)):
            switch AXHelpers.childrenResult(menuBar, runtime: runtime.ax) {
            case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                return .gone
            case .failure(let error):
                return .unreadable(.menuChildren(error))
            case .success(let items):
                for item in items {
                    switch AXHelpers.getAttributeResult(item, kAXSelectedAttribute as String, runtime: runtime.ax) as Result<Bool?, AXHelpers.AXStatusError> {
                    case .success(let selected):
                        if selected == true { return .present }
                    case .failure(let error) where axStatusIsDefinitiveAbsence(error):
                        continue
                    case .failure(let error):
                        return .unreadable(.menuItemSelected(error))
                    }
                }
                return .gone
            }
        case .failure(let error) where axStatusIsDefinitiveAbsence(error):
            return .gone
        case .failure(let error):
            return .unreadable(.menuBar(error))
        }
    }

    private static func pollTopLevelAlertWitness(
        runtime: AXLogicProElements.Runtime,
        observationAttempts: Int,
        observationDelayNanoseconds: UInt64
    ) async -> ModalReconcileWitnessSummary {
        let attempts = max(1, observationAttempts)
        var labels: [String] = []
        for index in 1...attempts {
            let observation = topLevelAlertWitnessObservation(runtime: runtime)
            labels.append(observation.diagnosticLabel)
            Log.info("modal_alert_witness poll=\(index) status=\(observation.diagnosticLabel)", subsystem: .ax)
            if observation == .gone { break }
            if index < attempts {
                try? await Task.sleep(nanoseconds: observationDelayNanoseconds)
            }
        }
        return ModalReconcileWitnessSummary(labels: labels)
    }

    private static func pollStrayMenuWitness(
        runtime: AXLogicProElements.Runtime,
        observationAttempts: Int,
        observationDelayNanoseconds: UInt64
    ) async -> ModalReconcileWitnessSummary {
        let attempts = max(1, observationAttempts)
        var labels: [String] = []
        for index in 1...attempts {
            let observation = strayMenuWitnessObservation(runtime: runtime)
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

    /// Best-effort detection of a menu bar menu left open: a menu bar item whose
    /// menu is showing reports `AXSelected == true`. Conservative — only true on
    /// a positively-observed selected item, so a spurious Escape is never sent.
    private static func detectStrayMenuOpen(runtime: AXLogicProElements.Runtime) -> Bool {
        guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime) else { return false }
        return AXHelpers.getChildren(menuBar, runtime: runtime.ax).contains { item in
            (AXHelpers.getAttribute(item, kAXSelectedAttribute, runtime: runtime.ax) as Bool?) == true
        }
    }

    // MARK: - Executor

    private struct ModalActionPerformResult {
        let performed: Bool
        let refusal: AlertAcknowledgeRefusal?
        let sheetWitness: [ModalSheetWitnessPoll]
        let witnessSummary: ModalReconcileWitnessSummary?
    }

    private static func perform(
        _ decision: ModalReconciliation.ModalReconcileDecision,
        alertTarget: AXLogicProElements.BlockingDialogTarget?,
        createButton: AXUIElement?,
        deleteButton: AXUIElement?,
        runtime: AXLogicProElements.Runtime,
        witnessAttempts: Int,
        witnessDelayNanoseconds: UInt64
    ) async -> ModalActionPerformResult {
        switch decision {
        case .noAction, .failClosed:
            return ModalActionPerformResult(
                performed: false, refusal: nil, sheetWitness: [], witnessSummary: nil
            )
        case .clickCreate:
            let actionAccepted = clickNewTrackCreateButton(
                createButton: createButton,
                runtime: runtime
            )
            let witness = await pollMainWindowSheetWitness(
                runtime: runtime,
                observationAttempts: witnessAttempts,
                observationDelayNanoseconds: witnessDelayNanoseconds
            )
            let summary = ModalReconcileWitnessSummary(sheetWitness: witness)
            return ModalActionPerformResult(
                performed: actionAccepted && summary.observedGone,
                refusal: nil,
                sheetWitness: witness,
                witnessSummary: summary
            )
        case .confirmDelete:
            let actionAccepted = confirmDeleteTracksSheet(
                deleteButton: deleteButton,
                runtime: runtime
            )
            let witness = await pollMainWindowSheetWitness(
                runtime: runtime,
                observationAttempts: witnessAttempts,
                observationDelayNanoseconds: witnessDelayNanoseconds
            )
            let summary = ModalReconcileWitnessSummary(sheetWitness: witness)
            return ModalActionPerformResult(
                performed: actionAccepted && summary.observedGone,
                refusal: nil,
                sheetWitness: witness,
                witnessSummary: summary
            )
        case .acknowledgeAlert:
            let result = acknowledgeTopLevelAlert(target: alertTarget, runtime: runtime)
            let summary = await pollTopLevelAlertWitness(
                runtime: runtime,
                observationAttempts: witnessAttempts,
                observationDelayNanoseconds: witnessDelayNanoseconds
            )
            return ModalActionPerformResult(
                performed: result.pressed && summary.observedGone,
                refusal: result.refusal,
                sheetWitness: [],
                witnessSummary: summary
            )
        case .escapeMenu:
            let actionAccepted = await sendEscapeKey(runtime: runtime)
            let summary = await pollStrayMenuWitness(
                runtime: runtime,
                observationAttempts: witnessAttempts,
                observationDelayNanoseconds: witnessDelayNanoseconds
            )
            return ModalActionPerformResult(
                performed: actionAccepted && summary.observedGone,
                refusal: nil,
                sheetWitness: [],
                witnessSummary: summary
            )
        }
    }

    /// Press the mandatory New Track sheet's resolved `Create` / `생성` element.
    /// Escape/Cancel are inert on this sheet; an unavailable or rejected element
    /// is reported by the false action result and is never replaced by a fresh
    /// ordinal lookup.
    private static func clickNewTrackCreateButton(
        createButton: AXUIElement?,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let createButton else { return false }
        return AXHelpers.performAction(createButton, kAXPressAction as String, runtime: runtime.ax)
    }

    /// Confirm the delete-channel-strips sheet by pressing its resolved primary
    /// destructive button. A missing or rejected element is an unperformed
    /// action, not permission to send Return at an unidentified sheet.
    private static func confirmDeleteTracksSheet(
        deleteButton: AXUIElement?,
        runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard let deleteButton else { return false }
        return AXHelpers.performAction(deleteButton, kAXPressAction as String, runtime: runtime.ax)
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
    ) -> (pressed: Bool, refusal: AlertAcknowledgeRefusal?) {
        guard let target else { return (false, .targetUnavailable) }

        // Re-resolve the app's current blocking dialog and require it to be the
        // SAME element. This is what makes "the dialog was replaced" and "several
        // dialogs are present" refusals rather than silent mis-clicks: the reader
        // returns the first blocking dialog, so a newly-frontmost one yields a
        // different element and fails the identity check below.
        guard let current = AXLogicProElements.blockingDialogTarget(runtime: runtime) else {
            return (false, .targetGone)
        }
        guard CFEqual(current.element, target.element) else {
            return (false, .targetChanged)
        }

        // Re-read the count from the live element rather than trusting the count
        // captured at classification time.
        let buttons = AXLogicProElements.titledButtons(of: current.element, runtime: runtime.ax)
        guard buttons.count == 1, let only = buttons.first else {
            return (false, .buttonCountChanged)
        }

        guard AXHelpers.performAction(only.element, kAXPressAction as String, runtime: runtime.ax) else {
            return (false, .pressFailed)
        }
        return (true, nil)
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
        refusal: AlertAcknowledgeRefusal? = nil
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
    }
}
