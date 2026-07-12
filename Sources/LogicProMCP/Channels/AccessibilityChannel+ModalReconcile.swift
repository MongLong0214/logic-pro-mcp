import ApplicationServices
import Foundation

/// #346 — live AX reader + executor for the pure `ModalReconciliation` core.
/// Reads the MAIN WINDOW's sheet (native AX; `dialogPresent` scans only
/// top-level windows and MISSES a main-window sheet) into `ModalSignals`,
/// classifies + decides via the pure core, and performs the sanctioned recovery
/// (click "Create" / confirm delete / Escape a stray menu). Unknown sheets fail
/// closed — never blindly dismissed.
extension AccessibilityChannel {

    /// Outcome of one reconciliation pass, surfaced as honest extras by callers.
    struct ModalReconcileOutcome: Sendable, Equatable {
        let kind: ModalReconciliation.BlockingModalKind
        let decision: ModalReconciliation.ModalReconcileDecision
        let performed: Bool

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
        let signals = readModalSignals(runtime: runtime)
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

        let performed = await perform(decision, signals: signals, runtime: runtime)
        return ModalReconcileOutcome(kind: kind, decision: decision, performed: performed)
    }

    // MARK: - Signal reader

    /// Read the main window's sheet into `ModalSignals`. When no sheet is
    /// present the only remaining blocker we reconcile is a stray open menu.
    static func readModalSignals(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ModalReconciliation.ModalSignals {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let sheet = firstSheet(in: window, runtime: runtime.ax) else {
            // No main-window sheet: the remaining blockers are a top-level
            // informational alert (safe only when single-button) and a stray
            // open menu. Alert signals are populated ONLY here, so any sheet
            // above still outranks a top-level alert.
            let alert = topLevelAlertSignals(runtime: runtime)
            return ModalReconciliation.ModalSignals(
                sheetPresent: false,
                sheetDescription: "",
                createButtonPresent: false,
                cancelButtonPresent: false,
                cancelButtonEnabled: false,
                deleteConfirmButtonPresent: false,
                strayMenuOpen: detectStrayMenuOpen(runtime: runtime),
                topLevelAlertPresent: alert.present,
                topLevelAlertButtonCount: alert.buttonCount,
                topLevelAlertPrimaryButton: alert.primaryButton
            )
        }

        let description = (AXHelpers.getAttribute(sheet, kAXDescriptionAttribute, runtime: runtime.ax) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buttons = AXHelpers.findAllDescendants(
            of: sheet, role: kAXButtonRole as String, maxDepth: 6, runtime: runtime.ax
        )

        let createPresent = buttons.contains { buttonLabel($0, runtime: runtime.ax) == "Create" }
        let cancelButton = buttons.first { buttonLabel($0, runtime: runtime.ax) == "Cancel" }
        // Fail-closed default: an unreadable enabled state is treated as ENABLED
        // so a normal cancelable sheet is never mistaken for the mandatory one
        // (which would auto-click "Create" — a side effect we must not guess).
        let cancelEnabled: Bool = cancelButton
            .flatMap { AXHelpers.getAttribute($0, kAXEnabledAttribute, runtime: runtime.ax) as Bool? }
            ?? true
        let deletePresent = buttons.contains { buttonLabel($0, runtime: runtime.ax).hasPrefix("Delete ") }

        return ModalReconciliation.ModalSignals(
            sheetPresent: true,
            sheetDescription: description,
            createButtonPresent: createPresent,
            cancelButtonPresent: cancelButton != nil,
            cancelButtonEnabled: cancelEnabled,
            deleteConfirmButtonPresent: deletePresent,
            strayMenuOpen: false,
            topLevelAlertPresent: false,
            topLevelAlertButtonCount: 0,
            topLevelAlertPrimaryButton: ""
        )
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
    ) -> (present: Bool, buttonCount: Int, primaryButton: String) {
        guard let info = AXLogicProElements.blockingDialogInfo(runtime: runtime),
              info.role == (kAXDialogSubrole as String) else {
            return (false, 0, "")
        }
        return (true, info.buttonTitles.count, info.buttonTitles.first ?? "")
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
        runtime: AXLogicProElements.Runtime
    ) async -> Bool {
        switch decision {
        case .noAction, .failClosed:
            return false
        case .clickCreate:
            return await clickNewTrackCreateButton()
        case .confirmDelete:
            return await confirmDeleteTracksSheet()
        case .acknowledgeAlert:
            return await acknowledgeTopLevelAlert(primaryButton: signals.topLevelAlertPrimaryButton)
        case .escapeMenu:
            return await sendEscapeKey()
        }
    }

    /// Click the mandatory New Track sheet's only exit. This exact addressing is
    /// the live-verified recovery — Escape/Cancel are inert on this sheet.
    private static func clickNewTrackCreateButton() async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                click button "Create" of group 1 of sheet 1 of window 1
            end tell
        end tell
        return "clicked"
        """
        return await AppleScriptChannel.executeAppleScript(script).isSuccess
    }

    /// Confirm the delete-channel-strips sheet by its primary destructive button,
    /// falling back to the sheet's default button (Return) when the exact title
    /// is not matched (e.g. a localized build).
    private static func confirmDeleteTracksSheet() async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                click button "Delete Tracks and Content" of sheet 1 of window 1
            end tell
        end tell
        return "clicked"
        """
        if await AppleScriptChannel.executeAppleScript(script).isSuccess {
            return true
        }
        // Fall back to the default button — the primary delete action is the
        // sheet's default, so Return commits it.
        sendReturnKey()
        return true
    }

    /// Acknowledge a single-button top-level informational alert (the classifier
    /// has already gated this to EXACTLY ONE button). Clicks the named button on
    /// the first `AXDialog` window, falling back to that dialog's first button.
    private static func acknowledgeTopLevelAlert(primaryButton: String) async -> Bool {
        let target = LogicProTarget.appleScriptTarget()
        let escapedButton = AppleScriptSafety.escapeForScript(primaryButton)
        let script = """
        tell application "System Events"
            tell \(target.systemEventsProcessTarget)
                set alertWindow to first window whose subrole is "AXDialog"
                try
                    click button "\(escapedButton)" of alertWindow
                on error
                    click button 1 of alertWindow
                end try
            end tell
        end tell
        return "acknowledged"
        """
        return await AppleScriptChannel.executeAppleScript(script).isSuccess
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
        newTrackAutoConfirmed: Bool
    ) {
        guard kind != .none else { return }
        extras["reconciled_modal_kind"] = reconcileKindLabel(kind)
        extras["reconciled_action"] = action
        if newTrackAutoConfirmed {
            extras["new_track_dialog_auto_confirmed"] = true
        }
    }
}
