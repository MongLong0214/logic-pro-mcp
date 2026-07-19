import AppKit
import CoreGraphics
import Foundation

/// Consent-based server automation of the one-time key-command assignment that
/// the coordinate-free record-arm path requires.
///
/// Why this exists: on real Logic 12.3 the track-header "Record Enable"
/// checkbox advertises AXPress but AXPress is a **no-op** (returns success yet
/// the value never flips — unlike Solo, which does flip on AXPress), the value
/// is not settable, and no menu item record-enables a track. The only
/// coordinate-free way to arm is Logic's "Toggle Track Record Enable" key
/// command — which ships **unassigned**, and Logic 12.2+ blocks programmatic
/// key-command *import*. So the assignment must be made through the Key Commands
/// GUI. This type does that entirely coordinate-free (no mouse/CGEvent-mouse):
///   1. Option+K keystroke opens the Key Commands window.
///   2. The command list is collapsed by TYPING the command name into the search
///      field (real keystrokes trigger Logic's live filter; a programmatic
///      AXValue set does not), avoiding a ~26s walk of the unfiltered list.
///      Logic auto-selects the single filtered result, so this DELIBERATELY does
///      NOT match the command element by its flat text nor set AXSelected/
///      AXFocused on it: live, that element's text is doubled/elusive (the only
///      reliably readable text is the search field echoing the typed query) and
///      an explicit AXSelected/AXFocused set does not take. Instead the filter is
///      confirmed *settled* the cheap, live-readable way — the search field
///      echoes the typed command name. That confirmation is best-effort: if it
///      cannot be observed the run STILL proceeds, because the functional
///      arm-flip (step 5) is the real target-correctness gate.
///   3. The "Learn by Key Label" **AXCheckBox** is driven via AXPress (it is a
///      checkbox, not a button — the reason an earlier button-only hunt missed
///      it), the chord is sent as a CGEvent **keyboard** chord (keystrokes are
///      not coordinates), then Learn is toggled back off.
///   4. Foreign-ownership (no rows to enumerate, no readback): the just-sent
///      chord could already be owned by another command. Logic's "Learn by Key
///      Label" raises a modal reassignment ALERT ONLY when the chord is already
///      assigned to a DIFFERENT command; on a free chord (or a re-bind of the
///      same command to the same chord) no modal appears. A conflict alert ⇒ the
///      chord is foreign-owned ⇒ the reassignment is DECLINED (never confirmed —
///      that would STEAL the chord) and setup fails closed `foreign_chord_owner`.
///   5. Success is proven FUNCTIONALLY, never by reading a KC assignment back
///      (live, matching the command by text and reading its key-assignment glyph
///      back are not viable). After closing the window and re-focusing Logic, the
///      server drives a REAL record-arm through the arm actuator using the EXACT
///      captured chord and observes `isArmed` flip. A flip proves the chord is
///      bound to the record-arm command (right target, functionally) ⇒ State A
///      "configured and verified". No flip ⇒ fail closed (the assignment did not
///      take). This is the 7ba469b live-proven verification.
///   6. The window is closed via **AXPress on its close button** — never a
///      second Option+K, which would type into the focused search field and
///      leave the window open (starving track reads).
///
/// Consent is mandatory (Isaac's rule: never modify the user's Logic config
/// without consent). Every hard gate's success is judged by a polled OBSERVED
/// effect (window appeared / search focused / checkbox value changed / arm
/// flipped), never by an AX action's return code. The chord is NEVER sent unless
/// consent, the known-safe-keycode gate, Logic-frontmost + Key-Commands-focused,
/// and Learn-observed-on all pass. On any hard gate whose effect does not
/// materialise it fails closed with an actionable manual-fallback hint.
enum ArmKeyCommandSetup {
    /// EN command name / checkbox title. Locale-dependent: non-EN Logic shows
    /// localised strings, so a non-EN run fails closed (Learn never observes on,
    /// or the arm-flip never lands) rather than mis-assigning. (Future:
    /// AXLocalePolicy.)
    static let commandName = "Toggle Track Record Enable"
    static let learnCheckboxTitle = "Learn by Key Label"

    enum Outcome: Equatable {
        case consentRequired
        case configuredAndVerified
        case configuredUnverified(why: String)
        /// The resolved chord's keyCode is NOT in the known-safe key-glyph map,
        /// so it cannot be reasoned about safely (an unmapped placeholder chord
        /// could STEAL a chord another command owns). Learn is refused before the
        /// window is opened and before any key is posted (fail-closed config
        /// error, mapped to `arm_key_config_invalid`).
        case configInvalid(hint: String)
        /// A setup step failed. `writeAttempted` is true once any Key Commands
        /// mutation (the Learn toggle or the assignment chord) has been posted,
        /// so the State C envelope reports honestly whether Logic's Key Commands
        /// surface was already touched before the failure.
        case failed(stage: String, hint: String, writeAttempted: Bool)
    }

    struct Runtime {
        /// Bring Logic frontmost so synthetic keystrokes route to it.
        var activateLogic: @Sendable () -> Void
        var logicIsFrontmost: @Sendable () -> Bool = { true }
        /// Post a modified key chord (used for Option+K and the arm chord).
        var postChord: @Sendable (CGKeyCode, CGEventFlags) -> Void
        /// Type text as real keystrokes into the focused element. Used to fill
        /// the KC search field: a programmatic AXValue set does NOT trigger
        /// Logic's list filter, but typed keystrokes do (collapsing ~2200 rows
        /// to a handful, so the command lookup is fast instead of a ~26s walk).
        var typeText: @Sendable (String) -> Void
        /// Sleep seconds (injected so tests don't wall-clock).
        var sleep: @Sendable (Double) -> Void
        var isCancelled: @Sendable () -> Bool = { Task.isCancelled }
        var ax: AXHelpers.Runtime
        var elements: AXLogicProElements.Runtime
        /// Ground-truth verification: drive a real record-arm and report whether
        /// the observed record-enable state flipped. nil ⇒ could not verify
        /// (e.g. no track). Wired by the dispatcher to the arm actuator.
        var verifyArmFlip: @Sendable (CGKeyCode, CGEventFlags) -> Bool?

        static func production(
            verifyArmFlip: @escaping @Sendable (CGKeyCode, CGEventFlags) -> Bool?
        ) -> Runtime {
            Runtime(
                activateLogic: {
                    _ = ProcessUtils.activateLogicPro()
                },
                logicIsFrontmost: ProcessUtils.Runtime.production.logicIsFrontmost,
                postChord: { keyCode, flags in
                    _ = AXMouseHelper.Runtime.production.postFlaggedKeyEvent(keyCode, flags)
                },
                typeText: { AXMouseHelper.typeText($0) },
                sleep: { Thread.sleep(forTimeInterval: $0) },
                ax: .production,
                elements: .production,
                verifyArmFlip: verifyArmFlip
            )
        }
    }

    private static let optionKKeyCode: CGKeyCode = 40          // kVK_ANSI_K
    private static let optionFlag: CGEventFlags = .maskAlternate

    /// Run the consent-gated assignment. `keyCode`/`modifiers` default to
    /// Ctrl+Shift+E (the shipped arm chord); pass the resolved chord so setup
    /// and the runtime actuator stay in lockstep.
    static func run(
        consent: Bool,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        runtime: Runtime
    ) -> Outcome {
        guard consent else { return .consentRequired }

        // No-steal hard gate. A conflict is only detectable via Logic's
        // reassignment alert, which fires on the RENDERED chord; that is only
        // sound for keyCodes whose glyph is in the complete known-safe map. An
        // unmapped keyCode (e.g. an operator override to a custom key) renders a
        // placeholder ("key(40)") whose behaviour under Learn cannot be reasoned
        // about, so Learn could STEAL a chord. Refuse up front — before opening
        // the window or posting ANY key.
        guard isKnownSafeChordKeyCode(keyCode) else {
            return .configInvalid(
                hint: "The record-arm chord resolves to key code \(keyCode), which is not in the "
                    + "server's known-safe key-glyph map, so a conflict with an existing command "
                    + "cannot be reasoned about safely. No Key Commands window was opened and no key "
                    + "was posted. Use the default Ctrl+Shift+E, or set LOGIC_PRO_MCP_ARM_KEYCODE to a "
                    + "supported key (E=14, R=15)."
            )
        }

        // Honest telemetry: flips true at the first Key Commands mutation (Learn
        // toggle or the assignment chord) and never resets, so every subsequent
        // `.failed` reports whether Logic's KC surface was already touched.
        var writeAttempted = false
        func fail(stage: String, hint: String) -> Outcome {
            .failed(stage: stage, hint: hint, writeAttempted: writeAttempted)
        }

        var window = keyCommandsWindow(runtime: runtime)
        guard confirmLogicFrontmost(runtime: runtime) else {
            return closing(
                fail(
                    stage: "logic_not_frontmost",
                    hint: "Logic could not be confirmed frontmost; no key-command input was sent."
                ),
                window: window,
                runtime: runtime
            )
        }
        if window == nil {
            runtime.postChord(optionKKeyCode, optionFlag)
            window = poll(runtime: runtime, deadline: 4.0) { keyCommandsWindow(runtime: runtime) }
        }
        guard let kcWindow = window else {
            return closing(fail(
                stage: "open_key_commands",
                hint: "The Key Commands window did not open (Option+K). Open it manually "
                    + "(Logic Pro ▸ Key Commands ▸ Edit) and assign \"\(commandName)\" to a shortcut."
            ), window: keyCommandsWindow(runtime: runtime), runtime: runtime)
        }

        // ── FILTER FIRST ──────────────────────────────────────────────────
        // The command list MUST be collapsed by the search filter BEFORE Learn is
        // engaged. Live, the unfiltered list holds ~2200 commands (~28k AX nodes)
        // and typing the command name collapses the window to the matching command
        // (Logic auto-selects the single result). So: find + clear + focus the
        // search field, type the command name. These early failures predate any KC
        // mutation, so they exit via `closing` (close the window; nothing to
        // restore yet).
        guard let searchField = firstDescendant(in: kcWindow, runtime: runtime, where: { el in
            let role = AXHelpers.getRole(el, runtime: runtime.ax) ?? ""
            return role == (kAXTextFieldRole as String) || role == "AXSearchField"
        }) else {
            return closing(fail(
                stage: "search_field",
                hint: "Could not find the Key Commands search field. Assign \"\(commandName)\" manually."
            ), window: kcWindow, runtime: runtime)
        }
        guard AXHelpers.setAttribute(
            searchField, kAXValueAttribute, "" as CFTypeRef, runtime: runtime.ax
        ), (AXHelpers.getValue(searchField, runtime: runtime.ax) as? String) == "" else {
            return closing(fail(
                stage: "search_clear",
                hint: "The Key Commands search field could not be cleared safely. No command was changed."
            ), window: kcWindow, runtime: runtime)
        }
        guard AXHelpers.setAttribute(
            searchField, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax
        ), poll(runtime: runtime, deadline: 1.0, {
            let focused: NSNumber? = AXHelpers.getAttribute(
                searchField, kAXFocusedAttribute, runtime: runtime.ax
            )
            return focused?.boolValue == true ? true : nil
        }) == true,
        confirmLogicFrontmost(runtime: runtime),
        (AXHelpers.getAttribute(
            searchField, kAXFocusedAttribute, runtime: runtime.ax
        ) as NSNumber?)?.boolValue == true else {
            return closing(fail(
                stage: "search_focus",
                hint: "Logic's Key Commands search field focus could not be observed. No text was typed."
            ), window: kcWindow, runtime: runtime)
        }
        runtime.typeText(commandName)

        // ── FILTER-SETTLE (best-effort; NOT a hard gate) ──────────────────
        // After typing, wait for Logic's live filter to settle to the typed query
        // the cheap, live-readable way: the search field echoes the command name.
        // Live, matching the flat command element by text and setting AXSelected/
        // AXFocused on it are NOT viable, so this DELIBERATELY does neither and
        // trusts Logic to auto-select the single filtered result. If the settle
        // cannot be confirmed the run STILL proceeds — the functional arm-flip
        // (below) is the real target-correctness gate. The chord is still gated by
        // consent/keycode/focus/Learn, all enforced below.
        _ = poll(runtime: runtime, deadline: 3.0) {
            searchFilterSettled(searchField, to: commandName, runtime: runtime) ? true : nil
        }

        var learnControl: AXUIElement?
        var priorLearnState: Bool?
        var learnChangedByUs = false
        func cleaned(_ outcome: Outcome?) -> Outcome? {
            let learnRestored: Bool
            if let learnControl, let priorLearnState {
                learnRestored = restoreCheckbox(
                    learnControl,
                    to: priorLearnState,
                    changedByUs: learnChangedByUs,
                    runtime: runtime
                )
            } else {
                learnRestored = true
            }
            // Close the KC window. The window close is the AUTHORITATIVE cleanup:
            // it discards the transient filter and Logic's auto-selection
            // regardless, so only Learn (a persistent config toggle) and the
            // window close are fail-closed here.
            let windowClosed = closeWindow(kcWindow, runtime: runtime)
            if !learnRestored {
                return fail(
                    stage: "learn_restore",
                    hint: "Learn could not be restored and observed at its captured prior value."
                )
            }
            if !windowClosed {
                return fail(
                    stage: "close_key_commands",
                    hint: "The Key Commands window could not be observed closed. Close it manually before continuing."
                )
            }
            return outcome
        }

        // Engage "Learn by Key Label" and post the chord. There is no pre-check of
        // the command's existing assignment (reading it back by text is not live-
        // viable): Learn (re)binds the auto-selected filtered command to the chord,
        // and foreign ownership is caught by Logic's own reassignment alert after
        // the chord is posted.
        guard let learn = firstDescendant(in: kcWindow, runtime: runtime, where: { el in
            AXHelpers.getRole(el, runtime: runtime.ax) == (kAXCheckBoxRole as String)
                && (AXHelpers.getTitle(el, runtime: runtime.ax) ?? "") == learnCheckboxTitle
        }) else {
            return cleaned(fail(
                stage: "learn_checkbox",
                hint: "Could not find the \"\(learnCheckboxTitle)\" control. Assign \"\(commandName)\" manually."
            ))!
        }
        learnControl = learn
        guard let capturedLearnState = checkboxState(learn, runtime: runtime) else {
            return cleaned(fail(
                stage: "learn_state_unreadable",
                hint: "The Learn checkbox state was unreadable, so no assignment chord was sent."
            ))!
        }
        priorLearnState = capturedLearnState
        if !capturedLearnState {
            // Toggling Learn on mutates Logic's Key Commands surface — the first
            // KC mutation this run performs, so any failure from here must report
            // write_attempted honestly even though it is later restored.
            writeAttempted = true
            _ = AXHelpers.performAction(learn, kAXPressAction as String, runtime: runtime.ax)
            learnChangedByUs = true
        }
        guard poll(runtime: runtime, deadline: 1.5, {
            checkboxState(learn, runtime: runtime) == true ? true : nil
        }) == true else {
            return cleaned(fail(
                stage: "learn_enable",
                hint: "Learn was not observed on, so no assignment chord was sent."
            ))!
        }
        guard let observedLearnState = checkboxState(learn, runtime: runtime) else {
            return cleaned(fail(
                stage: "learn_state_unreadable",
                hint: "Learn became unreadable after setup enabled it; no assignment chord was sent."
            ))!
        }
        guard observedLearnState else {
            return cleaned(fail(
                stage: "learn_enable",
                hint: "Learn was not observed on immediately before the chord; no chord was sent."
            ))!
        }
        guard confirmLogicFrontmost(runtime: runtime) else {
            return cleaned(fail(
                stage: "logic_not_frontmost",
                hint: "Logic was not stably frontmost immediately before the chord; no chord was sent."
            ))!
        }
        guard focusedWindowIs(kcWindow, runtime: runtime) else {
            return cleaned(fail(
                stage: "key_commands_not_focused",
                hint: "The Key Commands window was not Logic's focused window; no chord was sent."
            ))!
        }
        guard !runtime.isCancelled() else {
            return cleaned(fail(
                stage: "deadline",
                hint: "Setup was cancelled before assignment; all captured UI state was restored."
            ))!
        }
        // The assignment chord is the definitive KC mutation (covers the case
        // where Learn was already on and the toggle above was skipped).
        writeAttempted = true
        runtime.postChord(keyCode, modifiers)
        runtime.sleep(0.3)
        // Foreign-owned detection WITHOUT a row list or readback: Logic's "Learn
        // by Key Label" raises a modal reassignment alert ONLY when the chord is
        // already assigned to another command. On a FREE chord no modal appears.
        // If one appears the chord is foreign-owned → DECLINE it (never confirm —
        // that would STEAL the chord) and fail closed. The subsequent `cleaned`
        // restores Learn and closes the window like every other exit path.
        if let alert = poll(runtime: runtime, deadline: 2.0, {
            conflictReassignmentAlert(near: kcWindow, runtime: runtime)
        }) {
            let dismissed = declineConflictAlert(alert, near: kcWindow, runtime: runtime)
            return cleaned(fail(
                stage: "foreign_chord_owner",
                hint: dismissed
                    ? "The requested chord is already owned by another command; Logic's reassignment "
                        + "was declined and the chord was not stolen or rebound."
                    : "The requested chord is already owned by another command; Logic's reassignment "
                        + "alert could not be dismissed automatically — decline it manually (Cancel). "
                        + "The chord was NOT reassigned."
            ))!
        }
        guard restoreCheckbox(
            learn,
            to: capturedLearnState,
            changedByUs: learnChangedByUs,
            runtime: runtime
        ) else {
            return cleaned(fail(
                stage: "learn_restore",
                hint: "Learn could not be restored and verified after the assignment chord."
            ))!
        }
        learnChangedByUs = false

        if let cleanupFailure = cleaned(nil) { return cleanupFailure }
        guard !runtime.isCancelled() else {
            return fail(
                stage: "deadline",
                hint: "Setup was cancelled after cleanup; no verification was attempted."
            )
        }
        guard confirmLogicFrontmost(runtime: runtime) else {
            return fail(
                stage: "logic_not_frontmost",
                hint: "Logic could not be confirmed frontmost for the live arm verification."
            )
        }

        // TARGET-CORRECTNESS + SUCCESS, proven functionally (not by readback):
        // drive a real record-arm with the EXACT chord and observe isArmed flip.
        // A flip proves the chord landed on the record-arm command; no flip ⇒ the
        // assignment did not take (or landed elsewhere) ⇒ fail closed.
        switch runtime.verifyArmFlip(keyCode, modifiers) {
        case .some(true):
            return .configuredAndVerified
        case .some(false):
            return fail(
                stage: "verify",
                hint: "The configured chord did not produce and restore an observed record-arm flip. "
                    + "No assignment success is claimed; verify \"\(commandName)\" manually."
            )
        case .none:
            return .configuredUnverified(
                why: "no live arm flip was observed, so assignment success is not claimed"
            )
        }
    }

    // MARK: - Helpers

    static func keyCommandsWindow(runtime: Runtime) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime.elements) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) ?? []
        return windows.first { win in
            (AXHelpers.getTitle(win, runtime: runtime.ax) ?? "").contains("Key Command")
        }
    }

    private static func confirmLogicFrontmost(runtime: Runtime) -> Bool {
        runtime.activateLogic()
        let interval = Double(AccessibilityChannel.logicFrontmostPollIntervalMicros) / 1_000_000
        let timeout = Double(AccessibilityChannel.logicFrontmostStabilityTimeoutMicros) / 1_000_000
        let settle = Double(AccessibilityChannel.logicKeyWindowSettleMicros) / 1_000_000
        var stablePolls = 0
        var elapsed = 0.0
        while elapsed < timeout {
            stablePolls = runtime.logicIsFrontmost() ? stablePolls + 1 : 0
            runtime.sleep(interval)
            elapsed += interval
            if stablePolls == AccessibilityChannel.logicFrontmostStabilityPollCount {
                guard runtime.logicIsFrontmost() else {
                    stablePolls = 0
                    continue
                }
                runtime.sleep(settle)
                return runtime.logicIsFrontmost()
            }
        }
        return false
    }

    /// Whether Logic's live filter has settled to the typed query the cheap,
    /// live-readable way: the search field echoes the command name (live, the
    /// search-field echo was the ONLY reliably readable text on the filtered Key
    /// Commands window). Best-effort — the caller proceeds regardless; the
    /// functional arm-flip is the authoritative target-correctness gate.
    private static func searchFilterSettled(
        _ searchField: AXUIElement,
        to expected: String,
        runtime: Runtime
    ) -> Bool {
        guard let value = AXHelpers.getValue(searchField, runtime: runtime.ax) as? String else {
            return false
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    private static func elementText(_ element: AXUIElement, runtime: Runtime) -> String? {
        let texts = [
            AXHelpers.getValue(element, runtime: runtime.ax) as? String,
            AXHelpers.getTitle(element, runtime: runtime.ax),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        let distinct = Set(texts)
        guard distinct.count == 1 else { return nil }
        return distinct.first
    }

    private static func focusedWindowIs(_ window: AXUIElement, runtime: Runtime) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime.elements),
              let focused: AXUIElement = AXHelpers.getAttribute(
                app, kAXFocusedWindowAttribute, runtime: runtime.ax
              ) else { return false }
        return CFEqual(focused, window)
    }

    private static func checkboxState(_ element: AXUIElement, runtime: Runtime) -> Bool? {
        guard let value = AXHelpers.getValue(element, runtime: runtime.ax) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "0", "false": return false
            case "1", "true": return true
            default: return nil
            }
        }
        return nil
    }

    private static func restoreCheckbox(
        _ element: AXUIElement,
        to prior: Bool,
        changedByUs: Bool,
        runtime: Runtime
    ) -> Bool {
        if let current = checkboxState(element, runtime: runtime) {
            if current != prior {
                _ = AXHelpers.performAction(element, kAXPressAction as String, runtime: runtime.ax)
            }
        } else if changedByUs {
            _ = AXHelpers.performAction(element, kAXPressAction as String, runtime: runtime.ax)
        }
        return poll(runtime: runtime, deadline: 1.5, ignoreCancellation: true) {
            checkboxState(element, runtime: runtime) == prior ? true : nil
        } == true
    }

    private static func closing(
        _ outcome: Outcome,
        window: AXUIElement?,
        runtime: Runtime
    ) -> Outcome {
        guard let window else { return outcome }
        guard closeWindow(window, runtime: runtime) else {
            // Every `closing` call site is a pre-mutation early exit (before any
            // Learn toggle or chord), so no Key Commands write was attempted.
            return .failed(
                stage: "close_key_commands",
                hint: "The Key Commands window could not be observed closed. Close it manually before continuing.",
                writeAttempted: false
            )
        }
        return outcome
    }

    private static func closeWindow(_ window: AXUIElement, runtime: Runtime) -> Bool {
        if keyCommandsWindowAbsent(runtime: runtime) == true { return true }
        guard let closeButton: AXUIElement = AXHelpers.getAttribute(
            window, "AXCloseButton", runtime: runtime.ax
        ) else { return false }
        _ = AXHelpers.performAction(closeButton, kAXPressAction as String, runtime: runtime.ax)
        return poll(runtime: runtime, deadline: 2.0, ignoreCancellation: true) {
            keyCommandsWindowAbsent(runtime: runtime) == true ? true : nil
        } == true
    }

    private static func keyCommandsWindowAbsent(runtime: Runtime) -> Bool? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime.elements),
              let windows: [AXUIElement] = AXHelpers.getAttribute(
                app, kAXWindowsAttribute, runtime: runtime.ax
              ) else { return nil }
        return !windows.contains {
            (AXHelpers.getTitle($0, runtime: runtime.ax) ?? "").contains("Key Command")
        }
    }

    // MARK: - Foreign-chord conflict alert

    private static let escapeKeyCode: CGKeyCode = 53          // kVK_Escape

    /// Button labels (lowercased) that DECLINE Logic's reassignment alert — i.e.
    /// keep the existing owner and DO NOT steal the chord. Pressing any of these
    /// (or Escape) cancels the reassignment. "Reassign"/"Replace"/"OK" are
    /// deliberately absent: they would confirm the steal.
    private static let declineReassignLabels: Set<String> = [
        "cancel", "don't reassign", "dont reassign", "don't replace", "dont replace",
        "no", "keep", "keep existing", "keep current",
    ]

    /// Phrases (lowercased) that identify a modal as Logic's key-command conflict
    /// / reassignment alert. Corroborates the role scan so an unrelated sheet is
    /// never mistaken for the conflict and cancelled.
    private static let conflictAlertKeywords = [
        "already assigned", "already used", "already in use", "reassign", "replace",
    ]

    /// The modal conflict/reassignment alert Logic raises from "Learn by Key
    /// Label" when the just-sent chord is ALREADY owned by another command. On a
    /// FREE chord Logic raises no modal, so any conflict-worded AXSheet on the Key
    /// Commands window — or a conflict-worded AXDialog on the Logic process — at
    /// this point IS the conflict alert. Returns the modal element (so the caller
    /// can decline it and observe it dismissed) or nil when the chord was free.
    private static func conflictReassignmentAlert(
        near kcWindow: AXUIElement,
        runtime: Runtime
    ) -> AXUIElement? {
        var candidates: [AXUIElement] = []
        if let sheets: [AXUIElement] = AXHelpers.getAttribute(
            kcWindow, "AXSheets", runtime: runtime.ax
        ) {
            candidates.append(contentsOf: sheets)
        }
        candidates.append(contentsOf: descendants(
            in: kcWindow, runtime: runtime, maxDepth: 4, maxNodes: 600
        ).filter { AXHelpers.getRole($0, runtime: runtime.ax) == (kAXSheetRole as String) })
        if let app = AXLogicProElements.appRoot(runtime: runtime.elements) {
            let windows: [AXUIElement] = AXHelpers.getAttribute(
                app, kAXWindowsAttribute, runtime: runtime.ax
            ) ?? []
            for win in windows {
                if let sheets: [AXUIElement] = AXHelpers.getAttribute(
                    win, "AXSheets", runtime: runtime.ax
                ) {
                    candidates.append(contentsOf: sheets)
                }
                let subrole: String? = AXHelpers.getAttribute(
                    win, kAXSubroleAttribute, runtime: runtime.ax
                )
                if subrole == (kAXDialogSubrole as String)
                    || subrole == (kAXSystemDialogSubrole as String) {
                    candidates.append(win)
                }
            }
        }
        return candidates.first { alertMentionsConflict($0, runtime: runtime) }
    }

    private static func alertMentionsConflict(_ modal: AXUIElement, runtime: Runtime) -> Bool {
        let texts = descendants(in: modal, runtime: runtime, maxDepth: 6, maxNodes: 600)
            .compactMap { elementText($0, runtime: runtime)?.lowercased() }
        return texts.contains { text in
            conflictAlertKeywords.contains { text.contains($0) }
        }
    }

    /// Decline Logic's reassignment alert (never confirm — that would STEAL the
    /// chord). Presses a Cancel/Don't-Reassign button, or Escape as a fallback,
    /// then polls for the modal to be observed dismissed. Returns whether the
    /// alert is gone.
    private static func declineConflictAlert(
        _ alert: AXUIElement,
        near kcWindow: AXUIElement,
        runtime: Runtime
    ) -> Bool {
        let decline = descendants(in: alert, runtime: runtime, maxDepth: 6, maxNodes: 600)
            .first { el in
                guard AXHelpers.getRole(el, runtime: runtime.ax) == (kAXButtonRole as String) else {
                    return false
                }
                let label = (AXHelpers.getTitle(el, runtime: runtime.ax)
                    ?? AXHelpers.getDescription(el, runtime: runtime.ax) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return declineReassignLabels.contains(label)
            }
        if let decline {
            _ = AXHelpers.performAction(decline, kAXPressAction as String, runtime: runtime.ax)
        } else {
            // No recognizable decline button — Escape dismisses the alert without
            // confirming the reassignment.
            runtime.postChord(escapeKeyCode, [])
        }
        return poll(runtime: runtime, deadline: 2.0, ignoreCancellation: true) {
            conflictReassignmentAlert(near: kcWindow, runtime: runtime) == nil ? true : nil
        } == true
    }

    /// BFS for the first descendant satisfying `predicate` (AXHelpers'
    /// findAllDescendants only filters by role, so we walk with getChildren).
    /// `maxNodes` bounds the walk: the Key Commands outline holds ~2200 rows
    /// (~28k nodes to depth 18, ~26s), so an unbounded walk before the filter
    /// collapses the list would hang. Bounding each call keeps it cheap and lets
    /// the caller poll until the (typed) filter collapses the tree.
    private static func firstDescendant(
        in root: AXUIElement,
        runtime: Runtime,
        maxDepth: Int = 18,
        maxNodes: Int = 6000,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if predicate(node) { return node }
            if depth < maxDepth {
                for child in AXHelpers.getChildren(node, runtime: runtime.ax) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    private static func descendants(
        in root: AXUIElement,
        runtime: Runtime,
        maxDepth: Int = 18,
        maxNodes: Int = 6000
    ) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var result: [AXUIElement] = []
        while !queue.isEmpty, result.count < maxNodes {
            let (node, depth) = queue.removeFirst()
            result.append(node)
            if depth < maxDepth {
                for child in AXHelpers.getChildren(node, runtime: runtime.ax) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return result
    }

    /// Poll `probe` until it returns non-nil or the deadline elapses.
    private static func poll<T>(
        runtime: Runtime,
        deadline: Double,
        ignoreCancellation: Bool = false,
        _ probe: () -> T?
    ) -> T? {
        let step = 0.2
        var elapsed = 0.0
        while elapsed <= deadline {
            if !ignoreCancellation, runtime.isCancelled() { return nil }
            if let v = probe() { return v }
            runtime.sleep(step)
            elapsed += step
        }
        return nil
    }

    /// Human-readable chord label (⌃⇧E etc.) for hints.
    static func chordLabel(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        var s = ""
        if modifiers.contains(.maskControl) { s += "⌃" }
        if modifiers.contains(.maskAlternate) { s += "⌥" }
        if modifiers.contains(.maskShift) { s += "⇧" }
        if modifiers.contains(.maskCommand) { s += "⌘" }
        s += keyGlyph(keyCode) ?? "key(\(keyCode))"
        return s
    }

    /// Whether `keyCode` renders to a KNOWN-SAFE key glyph, i.e. one this server
    /// can reason about against Logic's reassignment alert. Only such chords may
    /// be auto-assigned: an unmapped keyCode cannot be reasoned about, so Learn
    /// must not post it (it could steal another command's chord). The shipped
    /// default (Ctrl+Shift+E, keyCode 14) is covered.
    static func isKnownSafeChordKeyCode(_ keyCode: CGKeyCode) -> Bool {
        keyGlyph(keyCode) != nil
    }

    /// The complete known-safe key-glyph map. A keyCode belongs here ONLY when
    /// its glyph is live-verified to match how Logic renders the same key. `nil`
    /// means "not safe to auto-assign"; callers must refuse rather than fall back
    /// to a placeholder. This is deliberately narrow (E/R only); extend it with a
    /// live check, never a guess. `chordLabel` still renders a placeholder for
    /// hints on unmapped keys, but such chords never reach the assignment path.
    private static func keyGlyph(_ keyCode: CGKeyCode) -> String? {
        switch keyCode {
        case 14: return "E"
        case 15: return "R"
        default: return nil
        }
    }
}
