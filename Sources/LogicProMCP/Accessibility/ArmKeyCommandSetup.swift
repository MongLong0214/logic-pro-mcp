import AppKit
import CoreGraphics
import Foundation

/// Consent-based server automation of the one-time key-command assignment that
/// the coordinate-free record-arm path requires (#413).
///
/// Why this exists: on real Logic 12.3 the track-header "Record Enable" checkbox
/// advertises AXPress but AXPress is a no-op (it returns success yet the value
/// never flips — unlike Solo, which does flip on AXPress), the value is not
/// settable, and no menu item record-enables a track. The only coordinate-free
/// way to arm is Logic's "Toggle Track Record Enable" key command — which ships
/// unassigned, and Logic 12.2+ blocks programmatic key-command *import*. So the
/// assignment must be made through the Key Commands GUI. This type does that
/// entirely coordinate-free (no mouse / CGEvent-mouse):
///
///   0. Verify-first fast path — before any GUI work, drive a real record-arm
///      with the captured chord. If record-enable flips, the mapping already
///      exists; no configuration write is performed and the run returns State A
///      immediately (the verification mutation is observed and restored).
///   1. Option+K keystroke opens the Key Commands window (polled until present).
///      the found field is a structurally-identified AXSearchField within the KC
///      window (not merely the first text field).
///   2. The command list is collapsed by TYPING the command name into the search
///      field: typed keystrokes trigger Logic's live filter (collapsing ~2200
///      commands to a handful), whereas a programmatic AXValue write sets the field
///      text but does NOT drive the filter. Typing is gated on a definitive
///      OBSERVED positive focus (Logic frontmost + the search field reading
///      AXFocused == true); a nil/unreadable/false focus fails closed, posting zero
///      keys.
///   3. The filtered command is matched by IDENTITY. The list holds no AXRows —
///      commands are flat AXTextFields whose value carries the name (Logic
///      suffixes an edited command with a trailing " *"). The search field, which
///      now echoes the typed query, is excluded, the match must be exact and
///      unique (a non-unique filter is refused), and the enclosing AXRow — or the
///      flat element itself — is selected via `AXSelected`. Selection is READ
///      BACK and the selected element's identity RE-READ before proceeding, so
///      Learn can never bind onto an unconfirmed or wrong selection.
///   4. The "Learn by Key Label" AXCheckBox is ensured ON (pressed only when read
///      off) and its ON state READ BACK; if it never reports on the run FAILS
///      CLOSED without sending the chord. The chord is a CGEvent keyboard chord.
///      After the chord, ANY unexpected modal/sheet means the chord is already
///      owned by another command: the run DECLINES it (Cancel/Escape only — never
///      a confirm/replace/reassign control, which would steal the chord) and
///      fails closed, naming the observed dialog. Learn is then restored.
///   5. The window is closed via AXPress on its close button — never a second
///      Option+K, which would type into the focused search field and leave the
///      window open — and the close is READ BACK (polled until the window is
///      gone).
///   6. Success is proven FUNCTIONALLY: after re-focusing Logic, a real
///      record-arm is driven with the EXACT captured chord and `isArmed` is
///      observed to flip (then restored). A flip proves the chord is bound to the
///      record-arm command; no flip fails closed. State A is NEVER claimed without
///      this arm-flip proof.
///
/// Consent is mandatory: the server never modifies the user's Logic config
/// without it, and the consent gate precedes every side effect. Every step's
/// success is judged by a polled OBSERVED effect (window appeared / command
/// matched+selected / Learn value on / arm flipped / window gone), never by an AX
/// action's return code. On any step whose effect does not materialise the run
/// fails closed with an actionable manual-fallback hint. Prior art: PR #408.
enum ArmKeyCommandSetup {
    /// EN command name / checkbox title. Locale-dependent: non-EN Logic shows
    /// localised strings, so a non-EN run fails closed (the command is not
    /// matched, or the arm-flip never lands) rather than mis-assigning.
    static let commandName = "Toggle Track Record Enable"
    static let learnCheckboxTitle = "Learn by Key Label"

    /// How a State-A record-arm mapping was reached.
    enum WriteSource: String, Equatable {
        /// No key-command configuration write was performed.
        case none
        /// The mapping already worked; verify-first proved it functionally.
        case existingMappingVerify = "existing_mapping_verify"
        /// The mapping was assigned by driving the Key Commands GUI.
        case guiAssignment = "gui_assignment"
    }

    /// Raw, per-phase evidence accumulated during a run. It is surfaced verbatim
    /// in the result envelope so a State-A claim is auditable end to end and a
    /// failure reports exactly how far the drive got before it stopped.
    struct Evidence: Equatable {
        var writeSource: WriteSource = .none
        /// True once any Key Commands mutation (the Learn toggle or the
        /// assignment chord) has been posted, even if later restored.
        var configurationWriteAttempted = false
        /// True once a functional arm flip was driven (verify-first or the final
        /// verification).
        var verificationMutationAttempted = false
        /// Top-level cleanup honesty: the AND of every cleanup step this run
        /// actually drove (Learn restore + window close, plus the verification
        /// mutation's own restore where a flip was driven). The split fields below
        /// report each part so neither is over- nor under-claimed.
        var restored = false
        /// Whether "Learn by Key Label" was observed back at its prior value.
        var learnRestored = false
        /// Whether the verification mutation's own arm flip was restored: true when
        /// the functional verify flipped and restored, false when it did not, nil
        /// when no verify flip was driven (pre-verify exit, or no track).
        var verifyRestored: Bool?
        var windowOpened = false
        var searchTyped = false
        var matchIdentity: String?
        var matchCount: Int?
        var selectionReadback = false
        var learnBefore: Bool?
        var learnAfter: Bool?
        var chordPosted = false
        var conflictObserved: Bool?
        var closeConfirmed = false
        var armFlipObserved: Bool?

        /// Retry safety: true ONLY when this run left no unrestored mutation behind,
        /// so a caller can re-run without compounding partial state. A run that
        /// provably performed no host mutation (no configuration write attempted and
        /// no arm flip observed) is always safe; a run that mutated is safe only if
        /// every touched state was OBSERVED restored (`restored`). The server's
        /// deadline-timeout envelope reports its own `safe_to_retry:false` while a
        /// detached op may still be running — this field covers the synchronous
        /// outcomes where the run has fully returned.
        var safeToRetry: Bool {
            let mutated = configurationWriteAttempted || armFlipObserved == true
            return mutated ? restored : true
        }

        /// Flatten to result-envelope extras. GUI-path fields are emitted only on
        /// the GUI-assignment path so an existing-mapping verify stays terse.
        var extras: [String: Any] {
            var out: [String: Any] = [
                "write_source": writeSource.rawValue,
                "configuration_write_attempted": configurationWriteAttempted,
                "verification_mutation_attempted": verificationMutationAttempted,
                "restored": restored,
                "safe_to_retry": safeToRetry,
            ]
            if writeSource == .guiAssignment {
                out["window_opened"] = windowOpened
                out["search_typed"] = searchTyped
                if let matchIdentity { out["match_identity"] = matchIdentity }
                if let matchCount { out["match_count"] = matchCount }
                out["selection_readback"] = selectionReadback
                if let learnBefore { out["learn_before"] = learnBefore }
                if let learnAfter { out["learn_after"] = learnAfter }
                out["chord_posted"] = chordPosted
                if let conflictObserved { out["conflict_observed"] = conflictObserved }
                out["learn_restored"] = learnRestored
                out["window_closed"] = closeConfirmed
                out["close_confirmed"] = closeConfirmed
                if let verifyRestored { out["verify_restored"] = verifyRestored }
            }
            if let armFlipObserved { out["arm_flip_observed"] = armFlipObserved }
            return out
        }
    }

    enum Outcome: Equatable {
        case consentRequired
        /// The resolved chord's keyCode is NOT in the known-safe key-glyph map, so
        /// a conflict with an existing command cannot be reasoned about safely
        /// (an unmapped placeholder chord could steal a chord another command
        /// owns). Refused before the window is opened and before any key is
        /// posted (mapped to `arm_key_config_invalid`).
        case configInvalid(hint: String)
        /// State A via the verify-first fast path — the mapping already worked.
        case alreadyConfigured(evidence: Evidence)
        /// State A via the GUI assignment path — assigned and functionally proven.
        case configuredAndVerified(evidence: Evidence)
        /// State B — the steps ran but no arm flip could confirm the assignment
        /// (e.g. no selectable track to test on).
        case configuredUnverified(why: String, evidence: Evidence)
        /// State C — a step's observed effect never materialised. `evidence`
        /// carries the per-phase progress (including whether a Key Commands write
        /// was already attempted) so the envelope reports honestly.
        case failed(stage: String, hint: String, evidence: Evidence)
    }

    /// Typed outcome of the functional arm-flip verification, so a partially
    /// mutated host is never treated the same as a cleanly unmapped one. From
    /// verify-first, only a clean `.unmapped` falls through to the GUI
    /// assignment; `.partialRestore`, `.couldNotPost`, AND `.environmentUnavailable`
    /// all fail closed (never pile GUI mutations onto a dirty/undrivable host, and
    /// never run a GUI assignment that could not be functionally verified). (#415)
    enum VerifyResult: Equatable {
        /// The chord flipped record-enable AND every mutation was restored.
        case verified
        /// The chord was posted, record-enable did NOT flip, and nothing was left
        /// mutated — safe to proceed to GUI assignment.
        case unmapped
        /// A flip or a restore (arm / selection / transport) failed after a
        /// mutation, so the host was left dirty — fail closed, naming what could
        /// not be restored.
        case partialRestore(detail: String)
        /// The verification chord could not be posted at all (e.g. focus/selection
        /// gates never let a key land) — distinct from "posted, no flip".
        case couldNotPost
        /// The environment could not be captured/tested (e.g. no selectable track).
        /// Nothing was mutated, but a GUI assignment could not be functionally
        /// verified either — verify-first fails closed WITHOUT opening the Key
        /// Commands GUI (`verify_environment_unavailable`). (#415)
        case environmentUnavailable
    }

    struct Runtime {
        /// Bring Logic frontmost so synthetic keystrokes route to it.
        var activateLogic: @Sendable () -> Void
        /// OBSERVED: Logic is the frontmost application right now.
        var logicIsFrontmost: @Sendable () -> Bool = { true }
        /// Post a modified key chord (Option+K, the assignment chord, Escape) and
        /// report whether the CGEvent post succeeded. The assignment chord's result
        /// gates State A honesty: a failed post must never be reported as posted.
        var postChord: @Sendable (CGKeyCode, CGEventFlags) -> Bool
        /// Type text as real keystrokes into the focused element (drives Logic's
        /// live list filter — a programmatic AXValue set does not filter). Checks
        /// cancellation before each code unit; returns false if the command deadline
        /// stopped it part-way, so the caller fails closed.
        var typeText: @Sendable (String) -> Bool
        /// Sleep seconds (injected so tests do not wall-clock).
        var sleep: @Sendable (Double) -> Void
        /// OBSERVED: the command deadline fired / this work was cancelled. Bound in
        /// production to `Task.isCancelled`, which the server's `runWithDeadline`
        /// flips by cancelling this work's detached task when the deadline elapses,
        /// so no new key is posted after a timeout.
        var isCancelled: @Sendable () -> Bool = { false }
        /// OBSERVED: this operation STILL owns the server mutation gate. Bound in
        /// production to the gate's live epoch check; a successor that reclaimed the
        /// gate makes this false, so — checked alongside `isCancelled` immediately
        /// before every forward key/AX mutation — a timed-out predecessor can never
        /// resume mutating after a successor acquired the gate (#413).
        var ownsGate: @Sendable () -> Bool = { true }
        var ax: AXHelpers.Runtime
        var elements: AXLogicProElements.Runtime
        /// Ground-truth verification: drive a real record-arm with the given chord
        /// and report the typed outcome (flip + restore, unmapped, partial restore,
        /// could-not-post, or environment-unavailable). Wired by the dispatcher to
        /// the arm actuator so setup and the runtime actuator stay in lockstep.
        var verifyArmFlip: @Sendable (CGKeyCode, CGEventFlags) -> VerifyResult

        static func production(
            verifyArmFlip: @escaping @Sendable (CGKeyCode, CGEventFlags) -> VerifyResult,
            ownsGate: @escaping @Sendable () -> Bool = { true }
        ) -> Runtime {
            Runtime(
                activateLogic: { _ = ProcessUtils.Runtime.production.activateLogicPro() },
                logicIsFrontmost: ProcessUtils.Runtime.production.logicIsFrontmost,
                postChord: { keyCode, flags in
                    AXMouseHelper.Runtime.production.postFlaggedKeyEvent(keyCode, flags)
                },
                // Stop typing mid-string on a deadline OR a lost gate — no key after
                // either boundary.
                typeText: { AXMouseHelper.typeText($0, isCancelled: { Task.isCancelled || !ownsGate() }) },
                sleep: { Thread.sleep(forTimeInterval: $0) },
                isCancelled: { Task.isCancelled },
                ownsGate: ownsGate,
                ax: .production,
                elements: .production,
                verifyArmFlip: verifyArmFlip
            )
        }
    }

    private static let optionKKeyCode: CGKeyCode = 40          // kVK_ANSI_K
    private static let optionFlag: CGEventFlags = .maskAlternate
    private static let escapeKeyCode: CGKeyCode = 53           // kVK_Escape

    /// Run the consent-gated assignment. `keyCode`/`modifiers` default to
    /// Ctrl+Shift+E (the shipped arm chord); the resolved chord is passed so
    /// setup and the runtime actuator stay in lockstep.
    static func run(
        consent: Bool,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        runtime: Runtime
    ) -> Outcome {
        guard consent else { return .consentRequired }

        // No-steal hard gate. A conflict is only detectable via Logic's
        // reassignment alert, which fires on the RENDERED chord; that is only
        // sound for keyCodes whose glyph is in the known-safe map. An unmapped
        // keyCode renders a placeholder whose behaviour under Learn cannot be
        // reasoned about, so Learn could steal a chord. Refuse up front — before
        // any GUI work or verification mutation and before posting any key.
        guard isKnownSafeChordKeyCode(keyCode) else {
            return .configInvalid(
                hint: "The record-arm chord resolves to key code \(keyCode), which is not in the "
                    + "server's known-safe key-glyph map, so a conflict with an existing command "
                    + "cannot be reasoned about safely. No Key Commands window was opened and no key "
                    + "was posted. Use the default Ctrl+Shift+E, or set LOGIC_PRO_MCP_ARM_KEYCODE to a "
                    + "supported key (E=14, R=15)."
            )
        }
        // Bare chord (no modifiers) hard-refuse — BEFORE verify-first, so no key is
        // ever posted. A bare key is never a valid arm chord: bare 'r' IS transport
        // Record (posting it could start a recording), and any bare key triggers a
        // global command. Mirrors the runtime arm actuator's chord-validity policy
        // (single source of truth) so setup and the actuator never disagree.
        guard !AccessibilityChannel.armChordModifiersAreUnsafe(modifiers) else {
            return .configInvalid(
                hint: "The record-arm chord has no modifier keys. A bare key is never a valid arm chord "
                    + "(bare 'r' starts transport recording; any bare key triggers a global command). "
                    + "No Key Commands window was opened and no key was posted. Configure a modifier chord "
                    + "(default Ctrl+Shift+E), or set LOGIC_PRO_MCP_ARM_KEY_MODIFIERS to a non-empty chord."
            )
        }

        var evidence = Evidence()

        // A forward mutation may begin ONLY while the command deadline is unexpired
        // AND this operation still owns the server mutation gate. Checked immediately
        // before every key/AX mutation: a timed-out predecessor whose
        // gate a successor reclaimed stops here even before cancellation propagates,
        // so no key/AX mutation ever starts after the deadline or after ownership
        // transfers.
        func mutationBlocked() -> Bool { runtime.isCancelled() || !runtime.ownsGate() }

        // Deadline/ownership checkpoint before verify-first: the verify probe posts a
        // real chord (a mutation), so once the deadline has fired or the gate was
        // reclaimed it must not run — no new key is posted after either boundary.
        if mutationBlocked() {
            return .failed(
                stage: "deadline",
                hint: "Setup was cancelled by the command deadline before any verification; no key was posted.",
                evidence: evidence
            )
        }

        // Verify-first idempotent fast path: before touching the Key Commands GUI,
        // drive a real arm with the captured chord. Only a clean `.verified` short-
        // circuits to State A and only a clean `.unmapped` falls through to the GUI
        // path; every other outcome — `.environmentUnavailable` included — fails
        // closed (never pile GUI mutations onto a host we already left dirty,
        // could not drive, or could not functionally verify against). (#415)
        evidence.verificationMutationAttempted = true
        switch runtime.verifyArmFlip(keyCode, modifiers) {
        case .verified:
            evidence.writeSource = .existingMappingVerify
            // The verify-first flip is restored by the verifier; no GUI cleanup ran.
            evidence.verifyRestored = true
            evidence.restored = true
            evidence.armFlipObserved = true
            return .alreadyConfigured(evidence: evidence)
        case .unmapped:
            break   // clean unmapped is the ONLY outcome that proceeds to GUI
        case .environmentUnavailable:
            // No functional target could be safely prepared to test the chord, so
            // the existing mapping can be neither confirmed nor a new one verified.
            // State A is impossible without a flip, and a GUI assignment we could
            // not verify must never run — fail closed WITHOUT opening the Key
            // Commands GUI (no window, no key, no AX mutation).
            return .failed(
                stage: "verify_environment_unavailable",
                hint: "No selectable track was available to functionally test the record-arm chord, so setup "
                    + "could neither confirm an existing mapping nor verify a new one; no Key Commands change "
                    + "was made. Arm a track and re-run, or assign \"\(commandName)\" manually.",
                evidence: evidence
            )
        case .partialRestore(let detail):
            evidence.verifyRestored = false
            evidence.restored = false
            return .failed(
                stage: "verify_partial_restore",
                hint: "The verification arm flip could not be fully undone (\(detail)); the host may be "
                    + "left dirty, so setup refused to make any Key Commands change. Re-run once the track "
                    + "is settled, or assign \"\(commandName)\" manually.",
                evidence: evidence
            )
        case .couldNotPost:
            return .failed(
                stage: "verify_post_failed",
                hint: "Could not drive the verification chord to test the existing mapping (Logic did not "
                    + "accept the key). No Key Commands change was made. Re-run, or assign \"\(commandName)\" manually.",
                evidence: evidence
            )
        }
        evidence.writeSource = .guiAssignment

        func fail(stage: String, hint: String) -> Outcome {
            .failed(stage: stage, hint: hint, evidence: evidence)
        }

        // Deadline/ownership checkpoint BEFORE activating Logic and the first key
        // post: a timed-out or gate-reclaimed op must not even
        // bring Logic frontmost, let alone post Option+K.
        if mutationBlocked() {
            return fail(
                stage: "deadline",
                hint: "Setup was cancelled by the command deadline before the Key Commands window "
                    + "was opened; no key was posted."
            )
        }
        runtime.activateLogic()
        runtime.sleep(0.4)

        // 1. Open the Key Commands window (Option+K), polling for the window.
        var window = keyCommandsWindow(runtime: runtime)
        if window == nil {
            // Carry the Option+K post result (never a discarded Boolean): a failed
            // post is reported honestly and fails closed rather than polling on a
            // key Logic never accepted.
            guard runtime.postChord(optionKKeyCode, optionFlag) else {
                return fail(
                    stage: "open_key_commands",
                    hint: "Could not post Option+K to open the Key Commands window (Logic did not accept "
                        + "the key). Open it manually (Logic Pro ▸ Key Commands ▸ Edit) and assign "
                        + "\"\(commandName)\" to a shortcut."
                )
            }
            window = poll(runtime: runtime, deadline: 4.0) { keyCommandsWindow(runtime: runtime) }
        }
        guard let kcWindow = window else {
            return fail(
                stage: "open_key_commands",
                hint: "The Key Commands window did not open (Option+K). Open it manually "
                    + "(Logic Pro ▸ Key Commands ▸ Edit) and assign \"\(commandName)\" to a shortcut."
            )
        }
        evidence.windowOpened = true

        // Honest fail-closed for a command-deadline cancellation once the KC window
        // is open: run best-effort cleanup (restore Learn if it was pressed, close
        // the window) and report the OBSERVED results — never claim a restoration
        // that did not happen.
        func timedOut(learn: AXUIElement? = nil, learnWasOn: Bool = false) -> Outcome {
            let learnRestored: Bool
            if let learn {
                learnRestored = restoreLearn(learn, wasOn: learnWasOn, runtime: runtime)
                evidence.learnRestored = learnRestored
            } else {
                learnRestored = true   // Learn was never pressed — nothing to restore
            }
            let closed = closeWindow(kcWindow, runtime: runtime)
            evidence.closeConfirmed = closed
            evidence.restored = learnRestored && closed
            return fail(
                stage: "deadline",
                hint: "Setup was cancelled by the command deadline; no further key was posted. Cleanup — "
                    + (learn == nil ? "" : "\"\(learnCheckboxTitle)\" restored: \(learnRestored); ")
                    + "Key Commands window closed: \(closed)."
            )
        }

        // Record the OBSERVED result of a window-only cleanup (no Learn press or
        // chord happened yet on this path) so every pre-Learn failure reports its
        // real close result instead of discarding it. Nothing persistent was
        // mutated, so `restored` reflects whether the KC window actually closed.
        func recordWindowOnlyCleanup() {
            let closed = closeWindow(kcWindow, runtime: runtime)
            evidence.closeConfirmed = closed
            evidence.restored = closed
        }

        // Record the OBSERVED result of the post-Learn cleanup (restore Learn to its
        // captured prior state, close the window) so every failure path AFTER a Learn
        // press/engage reports its real cleanup outcome instead of discarding it.
        func recordLearnCleanup(_ learn: AXUIElement, wasOn: Bool) {
            let learnRestored = restoreLearn(learn, wasOn: wasOn, runtime: runtime)
            let closed = closeWindow(kcWindow, runtime: runtime)
            evidence.learnRestored = learnRestored
            evidence.closeConfirmed = closed
            evidence.restored = learnRestored && closed
        }

        // Ownership re-check after the window poll and before the next AX mutation:
        // an expired detached op must not resume mutating after the deadline.
        if mutationBlocked() { return timedOut() }

        // 2. Find the Key Commands SEARCH field by STRUCTURAL identity (an
        //    AXSearchField within the KC window) — not merely the first text field,
        //    which could be an unrelated surface that would then receive the typed
        //    query. Fail closed if no positively-identified search field is present.
        guard let searchField = firstDescendant(in: kcWindow, runtime: runtime, where: { el in
            let role = AXHelpers.getRole(el, runtime: runtime.ax) ?? ""
            let subrole: String? = AXHelpers.getAttribute(el, kAXSubroleAttribute, runtime: runtime.ax)
            return role == "AXSearchField" || subrole == (kAXSearchFieldSubrole as String)
        }) else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "search_field",
                hint: "Could not find the Key Commands search field (no AXSearchField in the window). "
                    + "Assign \"\(commandName)\" manually."
            )
        }
        // Collapse the list by TYPING the command name into the search field.
        // A direct kAXValue set changes the field TEXT but does NOT drive Logic's
        // live filter (the list never collapses), so typed keystrokes are required.
        // Before any keystroke, clear the field and REQUIRE a definitive
        // AXFocused == true on the search field: a nil/unreadable/false focus is NOT
        // proof the field owns keyboard input, so a synthetic key could reach the
        // wrong Logic surface. Fail closed in that case, posting ZERO keys.
        _ = AXHelpers.setAttribute(searchField, kAXValueAttribute, "" as CFTypeRef, runtime: runtime.ax)
        _ = AXHelpers.setAttribute(searchField, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        runtime.sleep(0.3)
        guard focusPositivelyEstablished(on: searchField, runtime: runtime) else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "search_focus",
                hint: "Could not confirm the Key Commands search field positively holds keyboard focus; "
                    + "refused to type (a key could have gone elsewhere). Assign \"\(commandName)\" manually."
            )
        }
        // Cancellation checkpoint before typing: the deadline may have fired while
        // waiting on focus — do not issue new keystrokes.
        if mutationBlocked() { return timedOut() }
        // typeText checks cancellation before EACH code unit; a false return means
        // the deadline fired mid-string, so fail closed (no more keys posted).
        guard runtime.typeText(commandName) else { return timedOut() }
        evidence.searchTyped = true
        runtime.sleep(1.0)  // let the filter collapse the list

        // 3. IDENTITY + SELECTED. Poll for the filtered command elements, EXCLUDING
        //    the search field (which now echoes the typed query). The match must be
        //    exact (tolerating a trailing " *") and unique.
        guard let matches = poll(runtime: runtime, deadline: 4.0, {
            let found = commandMatches(in: kcWindow, excluding: searchField, runtime: runtime)
            return found.isEmpty ? nil : found
        }) else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "command_not_found",
                hint: "Could not find the \"\(commandName)\" command — Logic may be non-English. "
                    + "Assign the record-arm command to \(chordLabel(keyCode: keyCode, modifiers: modifiers)) manually."
            )
        }
        evidence.matchCount = matches.count
        // A non-unique filter would let Learn bind onto an ambiguous selection.
        guard matches.count == 1, let commandEl = matches.first else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "command_ambiguous",
                hint: "The Key Commands filter for \"\(commandName)\" resolved to \(matches.count) commands, "
                    + "not exactly one; refused to Learn onto an ambiguous match. Assign \"\(commandName)\" manually."
            )
        }
        evidence.matchIdentity = commandIdentity(commandEl, runtime: runtime)

        // Ownership re-check after the command-match poll and before selecting the
        // row (an AX mutation): the deadline may have fired during the poll.
        if mutationBlocked() { return timedOut() }

        // Select the command's enclosing row (or the flat element), then READ BACK
        // that the selection actually took.
        let selectedNode = selectEnclosingRow(commandEl, runtime: runtime)
        guard poll(runtime: runtime, deadline: 1.5, {
            elementSelected(selectedNode, runtime: runtime) ? true : nil
        }) != nil else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "select_command",
                hint: "Found the \"\(commandName)\" command but Logic did not confirm its selection; "
                    + "refused to Learn onto an unconfirmed selection. Assign \"\(commandName)\" manually."
            )
        }
        // Post-selection identity re-read: the still-selected element carries the
        // right command name (nothing reselected out from under the selection).
        guard commandMatchesName(commandEl, runtime: runtime) else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "selection_identity_mismatch",
                hint: "The selected Key Commands entry no longer read as \"\(commandName)\" after selection; "
                    + "refused to Learn onto a mismatched selection. Assign \"\(commandName)\" manually."
            )
        }
        evidence.selectionReadback = true

        // 4. Drive "Learn by Key Label" (an AXCheckBox) to ON, then send the chord.
        guard let learn = firstDescendant(in: kcWindow, runtime: runtime, where: { el in
            AXHelpers.getRole(el, runtime: runtime.ax) == (kAXCheckBoxRole as String)
                && (AXHelpers.getTitle(el, runtime: runtime.ax) ?? "") == learnCheckboxTitle
        }) else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "learn_checkbox",
                hint: "Could not find the \"\(learnCheckboxTitle)\" control. Assign \"\(commandName)\" manually."
            )
        }
        // Capture Learn's prior state as a TRISTATE. If it is UNREADABLE we cannot
        // reason about it (pressing could toggle an actually-on Learn OFF, and a
        // later "restore" would compare against an invented prior) — fail closed
        // before any press or chord, never inventing a prior value.
        guard let learnWasOn = checkboxState(learn, runtime: runtime) else {
            recordWindowOnlyCleanup()
            return fail(
                stage: "learn_state_unreadable",
                hint: "Logic's \"\(learnCheckboxTitle)\" state was unreadable; refused to press or send "
                    + "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) (a checkbox whose state cannot "
                    + "be read must never be toggled). Assign \"\(commandName)\" manually."
            )
        }
        evidence.learnBefore = learnWasOn
        // Cancellation checkpoint before the Learn press (a Key Commands mutation).
        if mutationBlocked() { return timedOut() }
        // Ensure on, do not blind-toggle — a press on an already-on Learn would
        // turn it OFF and the chord would post while NOT learning.
        if !learnWasOn {
            // The first Key Commands mutation this run performs.
            evidence.configurationWriteAttempted = true
            _ = AXHelpers.performAction(learn, kAXPressAction as String, runtime: runtime.ax)
        }
        // The chord is only safe to send while Learn is OBSERVED on. If Learn never
        // engages (or becomes unreadable), fail closed before the chord.
        guard poll(runtime: runtime, deadline: 1.5, {
            checkboxState(learn, runtime: runtime) == true ? true : nil
        }) != nil else {
            recordLearnCleanup(learn, wasOn: learnWasOn)
            return fail(
                stage: "learn_engage",
                hint: "Could not confirm Logic's \"\(learnCheckboxTitle)\" mode engaged; refused to send "
                    + "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) (nothing was assigned). "
                    + "Assign \"\(commandName)\" manually."
            )
        }
        evidence.learnAfter = true
        // Re-confirm Logic is frontmost right before the chord — focus can shift
        // between engaging Learn and posting the key.
        guard runtime.logicIsFrontmost() else {
            recordLearnCleanup(learn, wasOn: learnWasOn)
            return fail(
                stage: "logic_not_frontmost",
                hint: "Logic left the foreground before \(chordLabel(keyCode: keyCode, modifiers: modifiers)) "
                    + "could be sent; refused to post it. Re-run, or assign \"\(commandName)\" manually."
            )
        }
        guard !mutationBlocked() else { return timedOut(learn: learn, learnWasOn: learnWasOn) }

        // Selection-identity TOCTOU: immediately before the chord, re-validate that
        // the selected node is STILL selected AND still reads as the target command.
        // A selection that drifted to a different command between the earlier
        // confirm and now must never receive the chord (it would assign the chord to
        // the wrong command). Fail closed, no chord posted.
        guard elementSelected(selectedNode, runtime: runtime),
              commandMatchesName(commandEl, runtime: runtime) else {
            recordLearnCleanup(learn, wasOn: learnWasOn)
            return fail(
                stage: "selection_drifted",
                hint: "The selected Key Commands entry changed after it was confirmed; refused to send "
                    + "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) onto a drifted selection. "
                    + "Assign \"\(commandName)\" manually."
            )
        }

        // Positive focus ownership immediately before the chord: the Key Commands
        // window must be Logic's focused/key window AND "Learn by Key Label" must
        // still read ON. Frontmost alone does not prove the KC surface owns the
        // keystroke (Logic's main window would treat the chord as a random key
        // command). Fail closed otherwise, no chord posted.
        guard focusedWindowIs(kcWindow, runtime: runtime),
              checkboxState(learn, runtime: runtime) == true else {
            recordLearnCleanup(learn, wasOn: learnWasOn)
            return fail(
                stage: "key_commands_not_focused",
                hint: "The Key Commands window was not Logic's focused window (or \"\(learnCheckboxTitle)\" "
                    + "was no longer engaged) immediately before \(chordLabel(keyCode: keyCode, modifiers: modifiers)); "
                    + "refused to post it. Re-run, or assign \"\(commandName)\" manually."
            )
        }

        // Snapshot the dialog windows already open BEFORE the chord, so a
        // pre-existing unrelated dialog (e.g. an open settings window) is never
        // mistaken for the reassignment alert the chord itself raises.
        let preChordDialogs = dialogWindows(runtime: runtime)
        evidence.configurationWriteAttempted = true
        // Assignment-chord post honesty: carry the CGEvent post result. A failed
        // post must NEVER be reported as posted or proceed to verify — fail closed
        // with chord_posted:false and best-effort cleanup.
        let chordPosted = runtime.postChord(keyCode, modifiers)
        evidence.chordPosted = chordPosted
        guard chordPosted else {
            recordLearnCleanup(learn, wasOn: learnWasOn)
            return fail(
                stage: "assignment_post_failed",
                hint: "The assignment chord \(chordLabel(keyCode: keyCode, modifiers: modifiers)) could not be "
                    + "posted (Logic did not accept the key); nothing was assigned. Re-run, or assign "
                    + "\"\(commandName)\" manually."
            )
        }
        runtime.sleep(0.3)

        // Foreign-owned detection without a readback: on a FREE chord Logic raises
        // no modal, so any NEWLY-appeared modal/sheet at this point means the chord
        // is already owned by another command. Decline it (Cancel/Escape only —
        // never a confirm/replace/reassign control, which would steal the chord)
        // and fail closed, naming the observed dialog.
        if let modal = poll(runtime: runtime, deadline: 2.0, {
            unexpectedModal(near: kcWindow, excluding: preChordDialogs, runtime: runtime)
        }) {
            evidence.conflictObserved = true
            let label = modalLabel(modal, runtime: runtime)
            let dismissed = declineModal(modal, near: kcWindow, excluding: preChordDialogs, runtime: runtime)
            // Report the cleanup honestly: by construction no reassignment happened,
            // so `restored` reflects whether Learn returned to its prior value and
            // the KC window closed.
            let learnRestored = restoreLearn(learn, wasOn: learnWasOn, runtime: runtime)
            let closedAfterConflict = closeWindow(kcWindow, runtime: runtime)
            evidence.learnRestored = learnRestored
            evidence.closeConfirmed = closedAfterConflict
            evidence.restored = learnRestored && closedAfterConflict
            return fail(
                stage: "chord_conflict",
                hint: dismissed
                    ? "Posting \(chordLabel(keyCode: keyCode, modifiers: modifiers)) raised a Logic dialog "
                        + "(\(label)); it was declined (Cancel) and no command was reassigned. The chord is "
                        + "already owned by another command — choose a different chord."
                    : "Posting \(chordLabel(keyCode: keyCode, modifiers: modifiers)) raised a Logic dialog "
                        + "(\(label)) that could not be dismissed automatically — decline it manually (Cancel). "
                        + "No command was reassigned."
            )
        }
        evidence.conflictObserved = false

        // Restore Learn to its prior state (idempotent) and close the window. The
        // Learn + window cleanup is the run-controlled part of `restored`; each
        // post-chord exit path below AND-s it (plus the verify's own restore where
        // a flip was driven) so a failed cleanup is never hidden.
        let learnRestored = restoreLearn(learn, wasOn: learnWasOn, runtime: runtime)

        // 5. Close the window via its close button (NOT Option+K), then confirm it
        //    actually closed — a stuck KC window starves track reads.
        let closed = closeWindow(kcWindow, runtime: runtime)
        evidence.learnRestored = learnRestored
        evidence.closeConfirmed = closed
        runtime.sleep(0.3)

        // Re-focus Logic's main window and let focus settle before verifying: the
        // arm actuator's exclusive-select needs the tracks area focused, not the
        // just-closed floating KC window.
        runtime.activateLogic()
        runtime.sleep(0.9)

        guard !mutationBlocked() else {
            // No verify flip was driven, so `restored` reflects only the Learn +
            // window cleanup that did run — reported with its OBSERVED results.
            evidence.restored = learnRestored && closed
            return fail(
                stage: "deadline",
                hint: "Setup was cancelled after the assignment; no verification was attempted. Cleanup — "
                    + "\"\(learnCheckboxTitle)\" restored: \(learnRestored); Key Commands window closed: \(closed)."
            )
        }

        // 6. Ground-truth verify by driving a real arm. State A is never claimed
        //    without this flip AND a clean cleanup.
        evidence.verificationMutationAttempted = true
        switch runtime.verifyArmFlip(keyCode, modifiers) {
        case .verified:
            evidence.armFlipObserved = true
            evidence.verifyRestored = true
            // State A requires the arm flip AND both cleanup steps: never claim
            // success while Learn is left on or the KC window is left open.
            guard learnRestored, closed else {
                evidence.restored = false
                return fail(
                    stage: "cleanup_incomplete",
                    hint: "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) was assigned and confirmed by a "
                        + "live arm flip, but the Key Commands surface was left dirty ("
                        + (learnRestored ? "" : "\"\(learnCheckboxTitle)\" still on; ")
                        + (closed ? "" : "Key Commands window still open; ")
                        + "close/reset it manually). Setup did not claim success."
                )
            }
            evidence.restored = true
            return .configuredAndVerified(evidence: evidence)
        case .unmapped:
            // The assignment chord was posted but a test arm did not flip — the
            // assignment did not take. Nothing was left mutated by the verify, so
            // its own restore is trivially true; `restored` reflects the Learn +
            // window cleanup.
            evidence.armFlipObserved = false
            evidence.verifyRestored = true
            evidence.restored = learnRestored && closed
            return fail(
                stage: "verify",
                hint: "Assigned \(chordLabel(keyCode: keyCode, modifiers: modifiers)) but a test arm did not "
                    + "flip record-enable — the assignment may not have taken. Re-run, or assign \"\(commandName)\" manually."
            )
        case .partialRestore(let detail):
            // The verify flip mutated the host and a restore failed — fail closed
            // and name what was left dirty.
            evidence.armFlipObserved = true
            evidence.verifyRestored = false
            evidence.restored = false
            return fail(
                stage: "verify_partial_restore",
                hint: "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) may have been assigned, but the "
                    + "verification arm flip could not be fully undone (\(detail)); the host was left dirty. "
                    + "Check the track/transport and re-run, or assign \"\(commandName)\" manually."
            )
        case .couldNotPost:
            evidence.verifyRestored = true
            evidence.restored = learnRestored && closed
            return fail(
                stage: "verify_post_failed",
                hint: "Assigned \(chordLabel(keyCode: keyCode, modifiers: modifiers)) but could not drive a "
                    + "verification arm flip (Logic did not accept the key), so success is not claimed. "
                    + "Re-run, or verify \"\(commandName)\" manually."
            )
        case .environmentUnavailable:
            // No track to test on: no verify flip was driven, so its own restore is
            // trivially true and `restored` reflects the Learn + window cleanup.
            evidence.verifyRestored = true
            evidence.restored = learnRestored && closed
            return .configuredUnverified(
                why: "no selectable track to test on; arm a track and re-run to confirm "
                    + "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) works",
                evidence: evidence
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

    /// Every flat command element whose identity matches `commandName` exactly
    /// (tolerating a trailing " *"), excluding the search field that echoes the
    /// typed query. On the collapsed filter this is the single command cell.
    private static func commandMatches(
        in window: AXUIElement,
        excluding searchField: AXUIElement,
        runtime: Runtime
    ) -> [AXUIElement] {
        descendants(in: window, runtime: runtime).filter { el in
            !CFEqual(el, searchField) && commandMatchesName(el, runtime: runtime)
        }
    }

    /// Whether `el` reads EXACTLY as the command name after trimming and dropping
    /// a trailing " *" (Logic suffixes an edited/assigned command's cell).
    private static func commandMatchesName(_ el: AXUIElement, runtime: Runtime) -> Bool {
        guard let text = commandIdentity(el, runtime: runtime) else { return false }
        return text == commandName
    }

    /// The normalized command text of `el` (value preferred, else title), trimmed
    /// and with a trailing "*" / " *" removed. nil when the element carries none.
    private static func commandIdentity(_ el: AXUIElement, runtime: Runtime) -> String? {
        let raw = (AXHelpers.getValue(el, runtime: runtime.ax) as? String)
            ?? AXHelpers.getTitle(el, runtime: runtime.ax)
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasSuffix("*") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Select the command's enclosing AXRow (falls back to selecting the element
    /// itself when the list is flat — the real Key Commands list holds no rows).
    /// Returns the node AXSelected was set on so the caller can read it back.
    private static func selectEnclosingRow(_ el: AXUIElement, runtime: Runtime) -> AXUIElement {
        var node: AXUIElement? = el
        for _ in 0..<8 {
            guard let cur = node else { break }
            if AXHelpers.getRole(cur, runtime: runtime.ax) == (kAXRowRole as String) {
                _ = AXHelpers.setAttribute(cur, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
                return cur
            }
            node = AXHelpers.getAttribute(cur, kAXParentAttribute, runtime: runtime.ax)
        }
        _ = AXHelpers.setAttribute(el, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        return el
    }

    /// Positive focus proof required before typing the filter query: Logic must be
    /// OBSERVED frontmost AND the field must READ a definitive `AXFocused == true`.
    /// A nil (unreadable) or false focus is NOT accepted — it is not proof the field
    /// owns keyboard input, so a synthetic key could land on the wrong Logic surface.
    private static func focusPositivelyEstablished(on field: AXUIElement, runtime: Runtime) -> Bool {
        guard runtime.logicIsFrontmost() else { return false }
        return poll(runtime: runtime, deadline: 1.0) {
            elementFocusedState(field, runtime: runtime) == true ? true : nil
        } != nil
    }

    /// Restore Learn to its prior state: turn it back off ONLY if it was off before
    /// AND currently DEFINITIVELY reads on (never press a checkbox whose state is
    /// unreadable). Returns whether Learn is DEFINITIVELY observed back at its prior
    /// value — an unreadable state is reported as NOT restored, never hidden.
    @discardableResult
    private static func restoreLearn(_ learn: AXUIElement, wasOn: Bool, runtime: Runtime) -> Bool {
        if !wasOn, checkboxState(learn, runtime: runtime) == true {
            _ = AXHelpers.performAction(learn, kAXPressAction as String, runtime: runtime.ax)
            runtime.sleep(0.2)
        }
        return checkboxState(learn, runtime: runtime) == wasOn
    }

    /// Observed checkbox state as a TRISTATE: true/false when the AX value is
    /// readable, nil when it is unreadable — so callers never coerce unknown to off
    /// (which would invent a prior state and could toggle an actually-on control).
    private static func checkboxState(_ el: AXUIElement, runtime: Runtime) -> Bool? {
        guard let value = AXHelpers.getValue(el, runtime: runtime.ax) else { return nil }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String {
            switch text.lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: return nil
            }
        }
        return nil
    }

    /// Whether `window` is Logic's currently focused (key) window — a positive proof
    /// that the Key Commands surface, not the main window, owns keyboard input.
    private static func focusedWindowIs(_ window: AXUIElement, runtime: Runtime) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime.elements),
              let focused: AXUIElement = AXHelpers.getAttribute(
                app, kAXFocusedWindowAttribute, runtime: runtime.ax
              ) else { return false }
        return CFEqual(focused, window)
    }

    /// Observed AXSelected (definitively true), used to confirm a selection took.
    private static func elementSelected(_ el: AXUIElement, runtime: Runtime) -> Bool {
        let n: NSNumber? = AXHelpers.getAttribute(el, kAXSelectedAttribute, runtime: runtime.ax)
        return (n?.intValue ?? 0) != 0
    }

    /// Observed AXFocused as an optional: true/false when readable, nil when the
    /// element does not expose focus state.
    private static func elementFocusedState(_ el: AXUIElement, runtime: Runtime) -> Bool? {
        let n: NSNumber? = AXHelpers.getAttribute(el, kAXFocusedAttribute, runtime: runtime.ax)
        return n.map { $0.intValue != 0 }
    }

    /// Close the window via its close button and poll until it is gone. Returns
    /// whether the window was observed closed.
    @discardableResult
    private static func closeWindow(_ window: AXUIElement, runtime: Runtime) -> Bool {
        if keyCommandsWindow(runtime: runtime) == nil { return true }
        if let closeButton: AXUIElement = AXHelpers.getAttribute(window, "AXCloseButton", runtime: runtime.ax) {
            _ = AXHelpers.performAction(closeButton, kAXPressAction as String, runtime: runtime.ax)
        }
        return poll(runtime: runtime, deadline: 2.0) {
            keyCommandsWindow(runtime: runtime) == nil ? true : nil
        } != nil
    }

    // MARK: - Conflict modal (decline only — never steal a chord)

    /// Button labels (lowercased) that DECLINE a Logic alert without confirming a
    /// reassignment. Confirm/replace/reassign/ok/yes are deliberately ABSENT: the
    /// decline path must never press them, since that would steal the chord.
    private static let declineLabels: Set<String> = [
        "cancel", "don't reassign", "dont reassign", "don't replace", "dont replace",
        "no", "keep", "keep existing", "keep current",
    ]

    /// The Logic windows currently carrying a dialog subrole. Snapshotted before
    /// the assignment chord and passed to `unexpectedModal` as `excluding`, so a
    /// dialog that was already open is never mistaken for the reassignment alert.
    private static func dialogWindows(runtime: Runtime) -> [AXUIElement] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime.elements) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) ?? []
        return windows.filter { win in
            let subrole: String? = AXHelpers.getAttribute(win, kAXSubroleAttribute, runtime: runtime.ax)
            return subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String)
        }
    }

    /// Any NEWLY-appeared modal/sheet on the Key Commands window or the Logic
    /// process after the chord. On a FREE chord Logic raises none, so any such
    /// modal is the reassignment alert. Detection is structural (AXSheet / dialog
    /// subrole), not keyword-based, so it is not English-only. Dialog windows in
    /// `excluding` (open BEFORE the chord) are ignored — only a post-chord-new
    /// dialog is the alert. Sheets are always inherently chord-raised, so they are
    /// never excluded. nil when the chord was free.
    private static func unexpectedModal(
        near kcWindow: AXUIElement,
        excluding preChordDialogs: [AXUIElement],
        runtime: Runtime
    ) -> AXUIElement? {
        var candidates: [AXUIElement] = []
        if let sheets: [AXUIElement] = AXHelpers.getAttribute(kcWindow, "AXSheets", runtime: runtime.ax) {
            candidates.append(contentsOf: sheets)
        }
        candidates.append(contentsOf: descendants(in: kcWindow, runtime: runtime, maxDepth: 4, maxNodes: 600)
            .filter { AXHelpers.getRole($0, runtime: runtime.ax) == (kAXSheetRole as String) })
        if let app = AXLogicProElements.appRoot(runtime: runtime.elements) {
            let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) ?? []
            for win in windows where !CFEqual(win, kcWindow) {
                if let sheets: [AXUIElement] = AXHelpers.getAttribute(win, "AXSheets", runtime: runtime.ax) {
                    candidates.append(contentsOf: sheets)
                }
                let subrole: String? = AXHelpers.getAttribute(win, kAXSubroleAttribute, runtime: runtime.ax)
                let isDialog = subrole == (kAXDialogSubrole as String)
                    || subrole == (kAXSystemDialogSubrole as String)
                if isDialog, !preChordDialogs.contains(where: { CFEqual($0, win) }) {
                    candidates.append(win)
                }
            }
        }
        return candidates.first
    }

    /// A short label for the observed modal (its title or first non-empty text)
    /// so the refusal names the dialog it declined.
    private static func modalLabel(_ modal: AXUIElement, runtime: Runtime) -> String {
        if let title = AXHelpers.getTitle(modal, runtime: runtime.ax)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        for el in descendants(in: modal, runtime: runtime, maxDepth: 6, maxNodes: 600) {
            if let text = (AXHelpers.getValue(el, runtime: runtime.ax) as? String
                ?? AXHelpers.getTitle(el, runtime: runtime.ax))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return "unexpected dialog"
    }

    /// Decline the modal (never confirm). Presses a Cancel/decline button, or
    /// Escape as a fallback, then polls for the modal to be observed gone. Returns
    /// whether it was dismissed.
    private static func declineModal(
        _ modal: AXUIElement,
        near kcWindow: AXUIElement,
        excluding preChordDialogs: [AXUIElement],
        runtime: Runtime
    ) -> Bool {
        let decline = descendants(in: modal, runtime: runtime, maxDepth: 6, maxNodes: 600).first { el in
            guard AXHelpers.getRole(el, runtime: runtime.ax) == (kAXButtonRole as String) else { return false }
            let label = (AXHelpers.getTitle(el, runtime: runtime.ax)
                ?? AXHelpers.getDescription(el, runtime: runtime.ax) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return declineLabels.contains(label)
        }
        if let decline {
            _ = AXHelpers.performAction(decline, kAXPressAction as String, runtime: runtime.ax)
        } else if !runtime.isCancelled(), runtime.ownsGate() {
            // No recognizable decline button — Escape cancels without confirming.
            // After the command deadline OR once the gate was reclaimed, post no key:
            // leave the modal (reported as not-dismissed) rather than issue a late
            // keystroke. Carry the Escape post result (no discarded Boolean):
            // a key Logic did not accept cannot have dismissed the dialog, so report
            // not-dismissed without a poll.
            guard runtime.postChord(escapeKeyCode, []) else { return false }
        }
        return poll(runtime: runtime, deadline: 2.0) {
            unexpectedModal(near: kcWindow, excluding: preChordDialogs, runtime: runtime) == nil ? true : nil
        } != nil
    }

    // MARK: - Tree walk / polling

    /// BFS for the first descendant satisfying `predicate`. `maxNodes` bounds the
    /// walk: the unfiltered Key Commands outline holds ~2200 rows (~28k nodes,
    /// ~26s), so bounding each call keeps it cheap and lets the caller poll until
    /// the typed filter collapses the tree.
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
    private static func poll<T>(runtime: Runtime, deadline: Double, _ probe: () -> T?) -> T? {
        let step = 0.2
        var elapsed = 0.0
        while elapsed <= deadline {
            if let v = probe() { return v }
            runtime.sleep(step)
            elapsed += step
        }
        return nil
    }

    // MARK: - Chord glyphs

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

    /// Whether `keyCode` renders to a KNOWN-SAFE key glyph the server can reason
    /// about against Logic's reassignment alert. Only such chords may be
    /// auto-assigned; an unmapped keyCode must be refused. The shipped default
    /// (Ctrl+Shift+E, keyCode 14) is covered.
    static func isKnownSafeChordKeyCode(_ keyCode: CGKeyCode) -> Bool {
        keyGlyph(keyCode) != nil
    }

    /// The known-safe key-glyph map. Deliberately narrow (E/R only); extend it
    /// with a live check, never a guess. `chordLabel` still renders a placeholder
    /// for hints on unmapped keys, but such chords never reach the assignment path.
    private static func keyGlyph(_ keyCode: CGKeyCode) -> String? {
        switch keyCode {
        case 14: return "E"
        case 15: return "R"
        default: return nil
        }
    }
}
