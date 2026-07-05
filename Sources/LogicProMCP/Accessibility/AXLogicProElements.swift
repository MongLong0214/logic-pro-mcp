import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    struct Runtime: @unchecked Sendable {
        let logicProPID: @Sendable () -> pid_t?
        let ax: AXHelpers.Runtime

        static let production = Runtime(
            logicProPID: { ProcessUtils.logicProPID() },
            ax: .production
        )
    }

    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot(runtime: Runtime = .production) -> AXUIElement? {
        guard let pid = runtime.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid, runtime: runtime.ax)
    }

    /// Get the main window element.
    ///
    /// v3.1.1 (P1-2) — dialog-resilient lookup. When Logic has a modal dialog
    /// open (file-open panel, Bounce, tempo alert, save sheet, etc.) the
    /// system reports the dialog window as `kAXMainWindowAttribute`. Pre-3.1.1
    /// callers (`getTrackHeaders`, `getMixerArea`, `getControlBar`, …) walked
    /// down from that dialog and saw zero tracks / no transport — which the
    /// StatePoller then wrote into the cache as a phantom "empty project"
    /// state, breaking every track/mixer tool until the dialog was dismissed.
    ///
    /// New behavior:
    ///   1. Read every window via `kAXWindowsAttribute`.
    ///   2. Skip windows whose `AXSubrole` is `AXDialog` / `AXSystemDialog`
    ///      (modal sheets/panels).
    ///   3. Prefer a non-dialog window that contains the track-header rail
    ///      (the real arrange window).
    ///   4. Fall back to the first non-dialog window.
    ///   5. Only fall back to `kAXMainWindowAttribute` if no windows are
    ///      enumerable — preserves test-double behavior that builds a minimal
    ///      AX tree without a windows array.
    static func mainWindow(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }

        // Step 1 — enumerate all windows (test doubles may not implement this;
        // falls back to legacy mainWindow for those).
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        guard !windows.isEmpty else {
            return AXHelpers.getAttribute(app, kAXMainWindowAttribute, runtime: runtime.ax)
        }

        // Step 2 — partition into dialog vs non-dialog.
        let nonDialogs = windows.filter { !isDialogWindow($0, runtime: runtime.ax) }
        guard !nonDialogs.isEmpty else {
            // Every window is a dialog — fall through to the legacy main-window
            // lookup so callers that expect *something* still get an element.
            // Downstream `getTrackHeaders` will return nil → empty tracks, and
            // the StateCache empty-poll guard (P1-3) absorbs the transient.
            return AXHelpers.getAttribute(app, kAXMainWindowAttribute, runtime: runtime.ax)
        }

        // Step 3 — prefer the arrange window (has Track Headers group).
        if let arrange = nonDialogs.first(where: { hasTrackHeadersGroup($0, runtime: runtime.ax) }) {
            return arrange
        }

        // Step 4 — fallback: first non-dialog window.
        return nonDialogs.first
    }

    /// Returns true when at least one of Logic's windows is currently a modal
    /// dialog (subrole `AXDialog` / `AXSystemDialog`). v3.1.1 (P1-2) — used
    /// by `StatePoller` and any caller that wants to short-circuit cache
    /// updates while a blocking sheet is up.
    static func dialogPresent(runtime: Runtime = .production) -> Bool {
        guard let app = appRoot(runtime: runtime) else { return false }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        return windows.contains { isBlockingDialogWindow($0, runtime: runtime.ax) }
    }

    /// Identity of a blocking dialog/sheet, for #190 diagnostics: callers refuse
    /// mutations while one is present, and an actionable identity (title, role,
    /// owning window, buttons, recovery action) lets the operator/agent recover
    /// deterministically instead of guessing at a generic `blocking_dialog_present`.
    struct BlockingDialogInfo: Sendable, Equatable {
        let title: String
        let role: String
        let owningWindow: String
        let buttonTitles: [String]
        let recoveryAction: String
    }

    static func blockingDialogInfo(runtime: Runtime = .production) -> BlockingDialogInfo? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        guard let dialog = windows.first(where: { isBlockingDialogWindow($0, runtime: runtime.ax) }) else {
            return nil
        }
        let title = (AXHelpers.getAttribute(dialog, kAXTitleAttribute, runtime: runtime.ax) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let role = (AXHelpers.getAttribute(dialog, kAXSubroleAttribute, runtime: runtime.ax) ?? (kAXDialogSubrole as String))
        let owningWindow = (mainWindow(runtime: runtime).flatMap {
            AXHelpers.getTitle($0, runtime: runtime.ax)
        } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let buttons = AXHelpers.getChildren(dialog, runtime: runtime.ax)
            .filter { AXHelpers.getRole($0, runtime: runtime.ax) == (kAXButtonRole as String) }
            .compactMap { AXHelpers.getTitle($0, runtime: runtime.ax) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return BlockingDialogInfo(
            title: title,
            role: role,
            owningWindow: owningWindow,
            buttonTitles: buttons,
            recoveryAction: blockingDialogRecoveryAction(title: title, buttons: buttons)
        )
    }

    /// A safe, non-destructive recovery action for a blocking dialog. Prefers a
    /// Cancel-style button (which never saves or discards), then Escape; only
    /// names a different button when no cancel/escape path is exposed.
    private static func blockingDialogRecoveryAction(title: String, buttons: [String]) -> String {
        // Cancel-marker tokens centralized in AXLocalePolicy.cancelButton
        // (round-1 #8); `containsAny` is case-insensitive + diacritic-sensitive,
        // matching the original lowercased substring scan.
        if let cancel = buttons.first(where: { AXLocalePolicy.cancelButton.containsAny(in: $0) }) {
            return "Press \"\(cancel)\" to dismiss this dialog, then retry."
        }
        if !title.isEmpty {
            return "Dismiss the \"\(title)\" dialog (press Escape or its Cancel/close control), then retry."
        }
        return "Dismiss the blocking dialog (press Escape), then retry. Check logic_system.health for the current dialog state."
    }

    /// True when `window` carries an AXSubrole indicating a modal dialog/sheet.
    /// Logic 12 commonly tags Bounce/Save/Open/tempo-alert windows with one of:
    ///   AXDialog, AXSystemDialog, AXFloatingWindow (rare).
    /// We treat the first two as "dialog" — AXFloatingWindow stays a regular
    /// window because Logic uses it for the Library/Mixer detached panes.
    private static func isDialogWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute, runtime: runtime)
        guard let subrole else { return false }
        return subrole == (kAXDialogSubrole as String)
            || subrole == (kAXSystemDialogSubrole as String)
    }

    private static func isBlockingDialogWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard isDialogWindow(window, runtime: runtime) else { return false }
        return !isKeyboardLayoutOverlayWindow(window, runtime: runtime)
            && !isPluginEditorWindow(window, runtime: runtime)
    }

    /// #234: Logic 12.3 tags plugin-EDITOR windows with subrole `AXDialog` and a
    /// title equal to the track name, which tripped the v3.7.2 modal guard on
    /// unrelated ops (`project.save`, `track.select`) while an editor was open.
    /// On 12.2 those windows were plain (non-dialog), so this restores the 12.2
    /// baseline by excluding them for BOTH `dialogPresent` consumers (dispatcher
    /// modal guard AND StatePoller cache lifecycle — PRD D7).
    ///
    /// A plugin editor is told apart from a true modal by Logic's own plugin-
    /// window chrome, required CONJUNCTIVELY — any missing conjunct ⇒ not an
    /// editor ⇒ stays blocking (fail-closed):
    ///   1. subrole `AXDialog` (an `AXSystemDialog` is never an editor);
    ///   2. the window exposes `kAXCloseButtonAttribute` — the locale-neutral
    ///      handle the live 2026-07-04 probe closed the editor through; true
    ///      modal sheets do not carry one. This is the ATTRIBUTE, never the
    ///      child button's localized `desc='close'` text (PRD D4);
    ///   3. a bypass-labeled toggle among the DIRECT children;
    ///   4. a compare-labeled OR link-labeled toggle among the DIRECT children.
    /// A "toggle" is an `AXCheckBox` OR an `AXButton` (any subrole): the editor's
    /// toggle chrome ROLE-FLAPS with window focus on 12.3 — checkbox when the
    /// editor is key, button when it is not (live evidence `axwhy234b.out`,
    /// 2026-07-05: same 'Audio 1' window dumped minutes apart; Logic exposes the
    /// same toggle species as AXButton elsewhere, e.g. strip mute/solo). Compare
    /// chrome is preset-state-dependent — absent on a freshly-inserted plugin —
    /// while the channel-strip Link toggle is present from first open
    /// (`axwhy234.out`); either satisfies conjunct 4, and a true modal carries
    /// none of bypass/compare/link nor a close-button attribute. Follows the
    /// `isKeyboardLayoutOverlayWindow` exclusion precedent; compare/link labels
    /// are English-only (OQ-1) so non-EN locales stay blocking.
    private static func isPluginEditorWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute, runtime: runtime)
        guard subrole == (kAXDialogSubrole as String) else { return false }

        let closeButton: AXUIElement? = AXHelpers.getAttribute(
            window, kAXCloseButtonAttribute, runtime: runtime
        )
        guard closeButton != nil else { return false }

        // Scan AXCheckBox AND AXButton toggles — the labeled chrome role-flaps
        // with window focus (see doc comment). The close-button attribute conjunct
        // already gates out true modal sheets (they carry no close button), so
        // widening the toggle role cannot promote a real modal to an editor.
        let directToggles = AXHelpers.getChildren(window, runtime: runtime).filter {
            let role = AXHelpers.getRole($0, runtime: runtime) ?? ""
            return role == (kAXCheckBoxRole as String) || role == (kAXButtonRole as String)
        }
        let hasBypass = directToggles.contains { child in
            AXLocalePolicy.pluginBypassControl.containsAny(in: elementSearchText(child, runtime: runtime))
        }
        let hasCompareOrLink = directToggles.contains { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginWindowCompareControl.containsAny(in: text)
                || AXLocalePolicy.pluginWindowLinkControl.containsAny(in: text)
        }
        return hasBypass && hasCompareOrLink
    }

    private static func isKeyboardLayoutOverlayWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let title: String = AXHelpers.getAttribute(window, kAXTitleAttribute, runtime: runtime) ?? ""
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let children = AXHelpers.getChildren(window, runtime: runtime)
        guard children.count == 1 else { return false }
        let child = children[0]
        guard AXHelpers.getRole(child, runtime: runtime) == (kAXButtonRole as String) else { return false }
        let description: String = AXHelpers.getAttribute(child, kAXDescriptionAttribute, runtime: runtime) ?? ""
        return description.hasPrefix("com.apple.keylayout.")
    }

    /// True when `window` contains Logic's track-header rail. Used by
    /// `mainWindow()` to disambiguate the arrange window from auxiliary
    /// non-dialog windows (Library, Mixer detached pane, plugin windows).
    private static func hasTrackHeadersGroup(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let groups = AXHelpers.findAllDescendants(
            of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime
        )
        return groups.contains { group in
            isTrackHeadersGroup(group, runtime: runtime)
        }
    }

    /// Logic exposes the arrange track-header rail as an AXGroup with writable
    /// `AXSelectedChildren` pointing at its direct `AXLayoutItem` row children.
    /// Prefer that structure over localized text so new Logic languages do not
    /// need a code change just to locate the arrange window.
    // internal (not private): called cross-file from the +Tracks extension (WS3 AC1 split).
    static func isTrackHeadersGroup(
        _ group: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        if hasTrackHeaderSelectionStructure(group, runtime: runtime) {
            return true
        }
        return isTrackHeadersDescription(AXHelpers.getDescription(group, runtime: runtime))
    }

    private static func hasTrackHeaderSelectionStructure(
        _ group: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let layoutChildren = AXHelpers.getChildren(group, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXLayoutItemRole as String)
        }
        guard !layoutChildren.isEmpty,
              let selectedChildren: [AXUIElement] = AXHelpers.getAttribute(
                group,
                kAXSelectedChildrenAttribute,
                runtime: runtime
              ),
              !selectedChildren.isEmpty
        else {
            return false
        }
        return selectedChildren.contains { selected in
            layoutChildren.contains { $0 == selected }
        }
    }

    /// Matcher for Logic's track-header rail description. Logic has shipped
    /// both `Track Headers` and `Tracks header`. This stays as an explicit
    /// compatibility path, but structural detection above is preferred.
    private static func isTrackHeadersDescription(_ description: String?) -> Bool {
        guard let description else { return false }
        let normalized = description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace }
            .joined(separator: " ")
        return AXLocalePolicy.trackHeadersDescription.labels.contains(normalized)
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, identifier: "Arrangement", runtime: runtime.ax
        ) {
            return area
        }
        return AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Arrangement", runtime: runtime.ax
        )
    }

    // MARK: - Helpers

    // internal (not private): called cross-file from the +Tracks extension (WS3 AC1 split).
    static func findButtonByDescriptionPrefix(
        in element: AXUIElement,
        prefix: String,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button, runtime: runtime) else { return false }
            return desc.hasPrefix(prefix)
        }
    }

    // internal (not private): called cross-file from the +Transport extension (WS3 AC1 split).
    static func looksLikeTransportContainer(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let metadata = [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime)
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        // #60: centralized control-bar metadata + control-keyword token bags
        // (read-only classifiers). Same lowercased `.contains` semantics.
        if AXLocalePolicy.transportContainerMetadata.labels.contains(where: { metadata.contains($0.lowercased()) }) {
            return true
        }

        let transportKeywords = AXLocalePolicy.transportContainerControlKeywords.labels.map { $0.lowercased() }
        let controls = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
            + AXHelpers.findAllDescendants(of: element, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime)
        let controlHits = controls.reduce(into: Set<String>()) { hits, control in
            let label = (
                AXHelpers.getDescription(control, runtime: runtime)
                    ?? AXHelpers.getTitle(control, runtime: runtime)
                    ?? ""
            ).lowercased()

            for keyword in transportKeywords where label.contains(keyword) {
                hits.insert(keyword)
            }
        }

        if controlHits.count >= 2 {
            return true
        }

        // #60: centralized tempo/position slider hint token bag (read-only).
        let sliderHintTokens = AXLocalePolicy.transportSliderHints.labels.map { $0.lowercased() }
        let sliderHits = AXHelpers.findAllDescendants(of: element, role: kAXSliderRole, maxDepth: 4, runtime: runtime).contains { slider in
            let description = AXHelpers.getDescription(slider, runtime: runtime)?.lowercased() ?? ""
            return sliderHintTokens.contains { description.contains($0) }
        }

        let textRoles = [kAXStaticTextRole, kAXTextFieldRole]
        let textHits = textRoles.flatMap {
            AXHelpers.findAllDescendants(of: element, role: $0, maxDepth: 4, runtime: runtime)
        }.contains { text in
            let description = AXHelpers.getDescription(text, runtime: runtime)?.lowercased() ?? ""
            let value = (AXValueExtractors.extractTextValue(text, runtime: runtime) ?? "").lowercased()
            return AXLocalePolicy.transportTextFieldHint.containsAny(in: description)
                || value.contains(" bpm")
                || value.filter({ $0 == "." }).count >= 2
                || value.contains(":")
        }

        return (controlHits.count >= 1 && (textHits || sliderHits)) || sliderHits
    }
}
