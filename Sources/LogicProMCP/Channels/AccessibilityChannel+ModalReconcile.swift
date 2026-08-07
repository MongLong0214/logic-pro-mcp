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
        /// Set only when an authorized action was declined at execution time.
        /// `performed == false` alone cannot distinguish "the decision was not to
        /// act" from "the decision was to act and the executor refused", and
        /// those are very different things to report.
        let refusal: AlertAcknowledgeRefusal?

        init(
            kind: ModalReconciliation.BlockingModalKind,
            decision: ModalReconciliation.ModalReconcileDecision,
            performed: Bool,
            refusal: AlertAcknowledgeRefusal? = nil
        ) {
            self.kind = kind
            self.decision = decision
            self.performed = performed
            self.refusal = refusal
        }

        static let none = ModalReconcileOutcome(kind: .none, decision: .noAction, performed: false)
    }

    // MARK: - Public entry points

    /// Reconcile a blocking modal left by a just-completed mutation. Performs
    /// every actionable decision (clickCreate / confirmDelete / escapeMenu);
    /// fail-closed and no-action never touch the UI. `isDeleteContext` authorises
    /// confirming a delete-channel-strips sheet.
    static func reconcileAfterMutation(
        isDeleteContext: Bool,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ModalReconcileOutcome {
        await reconcile(
            isDeleteContext: isDeleteContext,
            preflight: false,
            clearMandatoryNewTrack: true,
            runtime: runtime
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
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ModalReconcileOutcome {
        await reconcile(
            isDeleteContext: false,
            preflight: true,
            clearMandatoryNewTrack: clearMandatoryNewTrack,
            runtime: runtime
        )
    }

    private static func reconcile(
        isDeleteContext: Bool,
        preflight: Bool,
        clearMandatoryNewTrack: Bool,
        runtime: AXLogicProElements.Runtime
    ) async -> ModalReconcileOutcome {
        // #453: the alert ELEMENT is captured with the signals and carried to the
        // executor. `ModalSignals` is the pure core's input and stays string-only,
        // so the element travels beside it rather than inside it.
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
            signals: signals,
            alertTarget: read.alertTarget,
            runtime: runtime
        )
        return ModalReconcileOutcome(
            kind: kind,
            decision: decision,
            performed: result.performed,
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

    /// #453: the same read, keeping the top-level alert's element so the executor
    /// can act on the element that was classified instead of re-resolving one.
    static func readModalSignalsAndAlertTarget(
        runtime: AXLogicProElements.Runtime = .production
    ) -> (signals: ModalReconciliation.ModalSignals, alertTarget: AXLogicProElements.BlockingDialogTarget?) {
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
            ), alert.target)
        }

        let description = (AXHelpers.getAttribute(sheet, kAXDescriptionAttribute, runtime: runtime.ax) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // #350: resolve each button's on-screen label ONCE, then match locale-
        // aware against the AXLocalePolicy LabelSets (EN + KO) so Korean Logic's
        // 생성 / 취소 / 새로운 트랙 sheet is recognized, not just the English literals.
        // The captured labels are threaded to the executor so it clicks the REAL
        // localized title rather than a hardcoded English string.
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
        ), nil)
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

    private static func perform(
        _ decision: ModalReconciliation.ModalReconcileDecision,
        signals: ModalReconciliation.ModalSignals,
        alertTarget: AXLogicProElements.BlockingDialogTarget?,
        runtime: AXLogicProElements.Runtime
    ) async -> (performed: Bool, refusal: AlertAcknowledgeRefusal?) {
        switch decision {
        case .noAction, .failClosed:
            return (false, nil)
        case .clickCreate:
            return (await clickNewTrackCreateButton(createTitle: signals.createButtonTitle), nil)
        case .confirmDelete:
            return (await confirmDeleteTracksSheet(deleteTitle: signals.deletePrimaryTitle), nil)
        case .acknowledgeAlert:
            return acknowledgeTopLevelAlert(target: alertTarget, runtime: runtime)
        case .escapeMenu:
            return (await sendEscapeKey(), nil)
        }
    }

    /// Click the mandatory New Track sheet's only exit (`Create` / `생성`). The
    /// title is the localized on-screen label the reader resolved (#350), so this
    /// works on Korean Logic; Escape/Cancel are inert on this sheet.
    private static func clickNewTrackCreateButton(createTitle: String) async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let escapedTitle = AppleScriptSafety.escapeForScript(createTitle)
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                click button "\(escapedTitle)" of group 1 of sheet 1 of window 1
            end tell
        end tell
        return "clicked"
        """
        return await AppleScriptChannel.executeAppleScript(script).isSuccess
    }

    /// Confirm the delete-channel-strips sheet by its primary destructive button,
    /// clicking the localized title the reader resolved (#350). Falls back to the
    /// sheet's default button (Return) when the title is absent/unmatched — which
    /// also covers the KO path (the KO delete title is unverified, so no variant).
    private static func confirmDeleteTracksSheet(deleteTitle: String) async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let escapedTitle = AppleScriptSafety.escapeForScript(deleteTitle)
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                click button "\(escapedTitle)" of sheet 1 of window 1
            end tell
        end tell
        return "clicked"
        """
        if !deleteTitle.isEmpty,
           await AppleScriptChannel.executeAppleScript(script).isSuccess {
            return true
        }
        // Fall back to the default button — the primary delete action is the
        // sheet's default, so Return commits it.
        sendReturnKey()
        return true
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
    ) -> (performed: Bool, refusal: AlertAcknowledgeRefusal?) {
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
    private static func sendEscapeKey() async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                key code 53
            end tell
        end tell
        return "escaped"
        """
        return await AppleScriptChannel.executeAppleScript(script).isSuccess
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
        refusal: AlertAcknowledgeRefusal? = nil
    ) {
        guard kind != .none else { return }
        extras["reconciled_modal_kind"] = reconcileKindLabel(kind)
        extras["reconciled_action"] = action
        if newTrackAutoConfirmed {
            extras["new_track_dialog_auto_confirmed"] = true
        }
        // #453: an authorized action the executor declined. Reported so a caller
        // can tell "we chose not to act" from "we tried and refused"; the value is
        // a fixed structural token, never dialog text or a button title.
        if let refusal {
            extras["reconcile_refused"] = refusal.rawValue
        }
    }
}
