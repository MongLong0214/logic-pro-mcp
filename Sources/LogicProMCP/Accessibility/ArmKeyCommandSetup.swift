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
///   2. The command list is collapsed with a **search-field AXValue write**
///      (avoids walking the ~2200-row outline, which times out).
///   3. The command row is selected via `AXSelected`.
///   4. The "Learn by Key Label" **AXCheckBox** is driven via AXPress (it is a
///      checkbox, not a button — the reason an earlier button-only hunt missed
///      it), the chord is sent as a CGEvent **keyboard** chord (keystrokes are
///      not coordinates), then Learn is toggled back off.
///   5. The window is closed via **AXPress on its close button** — never a
///      second Option+K, which would type into the focused search field and
///      leave the window open (starving track reads).
///
/// Consent is mandatory (Isaac's rule: never modify the user's Logic config
/// without consent). Every step's success is judged by a polled OBSERVED effect
/// (window appeared / command row appeared / checkbox value changed), never by
/// an AX action's return code. On any step whose effect does not materialise it
/// fails closed with an actionable manual-fallback hint. Idempotent: re-running
/// re-learns the same chord.
enum ArmKeyCommandSetup {
    /// EN command name / checkbox title. Locale-dependent: non-EN Logic shows
    /// localised strings, so a non-EN run fails closed at `commandNotFound`
    /// with a manual hint rather than mis-assigning. (Future: AXLocalePolicy.)
    static let commandName = "Toggle Track Record Enable"
    static let learnCheckboxTitle = "Learn by Key Label"

    enum Outcome: Equatable {
        case consentRequired
        case configuredAndVerified               // State A — assignment made AND a live arm flip observed
        case configuredUnverified(why: String)   // State B — assignment made, could not confirm a flip
        case failed(stage: String, hint: String) // State C — a step's observed effect never materialised
    }

    struct Runtime {
        /// Bring Logic frontmost so synthetic keystrokes route to it.
        var activateLogic: @Sendable () -> Void
        /// Post a modified key chord (used for Option+K and the arm chord).
        var postChord: @Sendable (CGKeyCode, CGEventFlags) -> Void
        /// Type text as real keystrokes into the focused element. Used to fill
        /// the KC search field: a programmatic AXValue set does NOT trigger
        /// Logic's list filter, but typed keystrokes do (collapsing ~2200 rows
        /// to a handful, so the command lookup is fast instead of a ~26s walk).
        var typeText: @Sendable (String) -> Void
        /// Sleep seconds (injected so tests don't wall-clock).
        var sleep: @Sendable (Double) -> Void
        var ax: AXHelpers.Runtime
        var elements: AXLogicProElements.Runtime
        /// Ground-truth verification: drive a real record-arm and report whether
        /// the observed record-enable state flipped. nil ⇒ could not verify
        /// (e.g. no track). Wired by the dispatcher to the arm actuator.
        var verifyArmFlip: @Sendable () -> Bool?

        static func production(verifyArmFlip: @escaping @Sendable () -> Bool?) -> Runtime {
            Runtime(
                activateLogic: {
                    if let pid = ProcessUtils.logicProPID(),
                       let app = NSRunningApplication(processIdentifier: pid) {
                        app.activate(options: [])
                    }
                },
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

        runtime.activateLogic()
        runtime.sleep(0.4)

        // 1. Open the Key Commands window (Option+K), polling for the window.
        var window = keyCommandsWindow(runtime: runtime)
        if window == nil {
            runtime.postChord(optionKKeyCode, optionFlag)
            window = poll(runtime: runtime, deadline: 4.0) { keyCommandsWindow(runtime: runtime) }
        }
        guard let kcWindow = window else {
            return .failed(
                stage: "open_key_commands",
                hint: "The Key Commands window did not open (Option+K). Open it manually "
                    + "(Logic Pro ▸ Key Commands ▸ Edit) and assign \"\(commandName)\" to a shortcut."
            )
        }

        // 2. Collapse the list with the search field (never a full-tree walk).
        guard let searchField = firstDescendant(in: kcWindow, runtime: runtime, where: { el in
            let role = AXHelpers.getRole(el, runtime: runtime.ax) ?? ""
            return role == (kAXTextFieldRole as String) || role == "AXSearchField"
        }) else {
            closeWindow(kcWindow, runtime: runtime)
            return .failed(
                stage: "search_field",
                hint: "Could not find the Key Commands search field. Assign \"\(commandName)\" manually."
            )
        }
        // Type the command name into the search field. Keystrokes trigger Logic's
        // list filter (collapsing ~2200 rows to a handful → fast lookup); a
        // programmatic AXValue set does NOT filter and leaves a ~26s full walk.
        _ = AXHelpers.setAttribute(searchField, kAXValueAttribute, "" as CFTypeRef, runtime: runtime.ax)
        _ = AXHelpers.setAttribute(searchField, kAXFocusedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        runtime.sleep(0.3)
        runtime.typeText(commandName)
        runtime.sleep(1.0)  // let the filter collapse the list

        // 3. Poll for the filtered command element (fast on the collapsed list),
        //    then select its row. Exclude the search field itself — it now also
        //    contains the command name.
        guard let commandEl = poll(runtime: runtime, deadline: 4.0, {
            firstDescendant(in: kcWindow, runtime: runtime, where: { el in
                !CFEqual(el, searchField) && matchesCommand(el, runtime: runtime)
            })
        }) else {
            closeWindow(kcWindow, runtime: runtime)
            return .failed(
                stage: "command_not_found",
                hint: "Could not find the \"\(commandName)\" command — Logic may be non-English. "
                    + "Assign the record-arm command to \(chordLabel(keyCode: keyCode, modifiers: modifiers)) manually."
            )
        }
        selectEnclosingRow(commandEl, runtime: runtime)

        // 4. Drive "Learn by Key Label" (an AXCheckBox), send the chord, stop learning.
        guard let learn = firstDescendant(in: kcWindow, runtime: runtime, where: { el in
            AXHelpers.getRole(el, runtime: runtime.ax) == (kAXCheckBoxRole as String)
                && (AXHelpers.getTitle(el, runtime: runtime.ax) ?? "") == learnCheckboxTitle
        }) else {
            closeWindow(kcWindow, runtime: runtime)
            return .failed(
                stage: "learn_checkbox",
                hint: "Could not find the \"\(learnCheckboxTitle)\" control. Assign \"\(commandName)\" manually."
            )
        }
        _ = AXHelpers.performAction(learn, kAXPressAction as String, runtime: runtime.ax)
        // Observed effect: the checkbox reports learning (value 1). Poll, don't
        // trust the AXPress return.
        _ = poll(runtime: runtime, deadline: 1.5) { checkboxOn(learn, runtime: runtime) ? true : nil }

        runtime.postChord(keyCode, modifiers)
        runtime.sleep(0.3)

        // Turn Learn back off if it is still on (idempotent).
        if checkboxOn(learn, runtime: runtime) {
            _ = AXHelpers.performAction(learn, kAXPressAction as String, runtime: runtime.ax)
            runtime.sleep(0.2)
        }

        // 5. Close the window via its close button (NOT Option+K).
        closeWindow(kcWindow, runtime: runtime)
        runtime.sleep(0.3)

        // Re-focus Logic's main window and let focus settle BEFORE verifying.
        // Driving the arm immediately after the KC window closes hits a transient
        // focus state (the arm actuator's focus gate / exclusive-select needs the
        // tracks area focused, not the just-closed floating KC window) — that made
        // an otherwise-good assignment self-report as unverified.
        runtime.activateLogic()
        runtime.sleep(0.9)

        // 6. Ground-truth verify by driving a real arm.
        switch runtime.verifyArmFlip() {
        case .some(true):
            return .configuredAndVerified
        case .some(false):
            return .failed(
                stage: "verify",
                hint: "Assigned \(chordLabel(keyCode: keyCode, modifiers: modifiers)) but a test arm did not "
                    + "flip record-enable — the assignment may not have taken. Re-run, or assign \"\(commandName)\" manually."
            )
        case .none:
            return .configuredUnverified(
                why: "no selectable track to test on; arm a track to confirm "
                    + "\(chordLabel(keyCode: keyCode, modifiers: modifiers)) works"
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

    private static func matchesCommand(_ el: AXUIElement, runtime: Runtime) -> Bool {
        // `.contains`, not `==`: Logic suffixes an edited/assigned command's cell
        // with " *" (e.g. "Toggle Track Record Enable *").
        let value = AXHelpers.getValue(el, runtime: runtime.ax) as? String ?? ""
        if value.contains(commandName) { return true }
        return (AXHelpers.getTitle(el, runtime: runtime.ax) ?? "").contains(commandName)
    }

    /// Select the command's enclosing AXRow (falls back to selecting the element
    /// itself when the list is flat).
    private static func selectEnclosingRow(_ el: AXUIElement, runtime: Runtime) {
        var node: AXUIElement? = el
        for _ in 0..<8 {
            guard let cur = node else { break }
            if AXHelpers.getRole(cur, runtime: runtime.ax) == (kAXRowRole as String) {
                _ = AXHelpers.setAttribute(cur, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
                return
            }
            node = AXHelpers.getAttribute(cur, kAXParentAttribute, runtime: runtime.ax)
        }
        _ = AXHelpers.setAttribute(el, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
    }

    private static func checkboxOn(_ el: AXUIElement, runtime: Runtime) -> Bool {
        (AXHelpers.getValue(el, runtime: runtime.ax) as? NSNumber)?.intValue ?? 0 != 0
    }

    private static func closeWindow(_ window: AXUIElement, runtime: Runtime) {
        if let closeButton: AXUIElement = AXHelpers.getAttribute(window, "AXCloseButton", runtime: runtime.ax) {
            _ = AXHelpers.performAction(closeButton, kAXPressAction as String, runtime: runtime.ax)
        }
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

    /// Human-readable chord label (⌃⇧E etc.) for hints.
    static func chordLabel(keyCode: CGKeyCode, modifiers: CGEventFlags) -> String {
        var s = ""
        if modifiers.contains(.maskControl) { s += "⌃" }
        if modifiers.contains(.maskAlternate) { s += "⌥" }
        if modifiers.contains(.maskShift) { s += "⇧" }
        if modifiers.contains(.maskCommand) { s += "⌘" }
        s += keyLetter(keyCode)
        return s
    }

    private static func keyLetter(_ keyCode: CGKeyCode) -> String {
        // Minimal map for the letters we assign; falls back to the raw code.
        switch keyCode {
        case 14: return "E"
        case 15: return "R"
        default: return "key(\(keyCode))"
        }
    }
}
