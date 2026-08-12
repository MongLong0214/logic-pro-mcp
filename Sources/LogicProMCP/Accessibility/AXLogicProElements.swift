import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    struct Runtime: @unchecked Sendable {
        let logicProPID: @Sendable () -> pid_t?
        let ax: AXHelpers.Runtime
        let executeAppleScript: @Sendable (String) async -> ChannelResult

        init(
            logicProPID: @escaping @Sendable () -> pid_t?,
            ax: AXHelpers.Runtime,
            executeAppleScript: @escaping @Sendable (String) async -> ChannelResult = {
                await AppleScriptChannel.executeAppleScript($0)
            }
        ) {
            self.logicProPID = logicProPID
            self.ax = ax
            self.executeAppleScript = executeAppleScript
        }

        static let production = Runtime(
            logicProPID: { ProcessUtils.logicProPID() },
            ax: .production,
            executeAppleScript: { await AppleScriptChannel.executeAppleScript($0) }
        )
    }

    /// A status-preserving arrange-window resolution for safety-critical reads.
    ///
    /// `mainWindow()` intentionally remains a best-effort discovery helper for
    /// ordinary UI work. A mutation verification, however, must distinguish an
    /// actual absence from an AX failure and must carry the *same* element into
    /// both its track and sheet reads. In particular, `AXMainWindow` reporting
    /// -25205/-25212 is a structural answer, not permission to call a later,
    /// unrelated `mainWindow()` lookup and combine its answer with this one.
    enum ArrangeWindowRead {
        case found(AXUIElement)
        case absent
        case unreadable
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

    /// Resolve the non-dialog arrange candidate once for a verification poll.
    /// The caller carries the returned element to every dependent observation;
    /// it must not re-run `mainWindow()` for a count, sheet scan, or presence
    /// check and accidentally combine three different AX snapshots.
    static func arrangeWindowRead(runtime: Runtime = .production) -> ArrangeWindowRead {
        guard let app = appRoot(runtime: runtime) else { return .unreadable }

        switch AXHelpers.getAttributeResult(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(.some(let windows)) where !windows.isEmpty:
            let nonDialogs = windows.filter { !isDialogWindow($0, runtime: runtime.ax) }
            guard !nonDialogs.isEmpty else {
                // A dialog is not an arrange-window witness. Returning the raw
                // main-window dialog here would let a zero count certify a
                // deletion even though no arrange tree was read.
                return .absent
            }
            if let arrange = nonDialogs.first(where: {
                hasTrackHeadersGroup($0, runtime: runtime.ax)
            }) {
                return .found(arrange)
            }
            // Keep the established main-window selection order. The caller still
            // requires a successful track-header enumeration below, so an
            // auxiliary non-dialog window cannot supply a count by itself.
            return .found(nonDialogs[0])
        case .success:
            return directArrangeWindowRead(app: app, runtime: runtime.ax)
        case .failure(let error) where isDefinitiveAXAbsence(error):
            return directArrangeWindowRead(app: app, runtime: runtime.ax)
        case .failure:
            return .unreadable
        }
    }

    private static func directArrangeWindowRead(
        app: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> ArrangeWindowRead {
        switch AXHelpers.getAttributeResult(
            app, kAXMainWindowAttribute as String, runtime: runtime
        ) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(.some(let window)):
            return .found(window)
        case .success(.none):
            return .absent
        case .failure(let error) where isDefinitiveAXAbsence(error):
            return .absent
        case .failure:
            return .unreadable
        }
    }

    private static func isDefinitiveAXAbsence(_ error: AXHelpers.AXStatusError) -> Bool {
        error.raw == AXError.attributeUnsupported.rawValue || error.raw == AXError.noValue.rawValue
    }

    /// Returns true when at least one of Logic's windows is currently a modal
    /// dialog (subrole `AXDialog` / `AXSystemDialog`). v3.1.1 (P1-2) — used
    /// by `StatePoller` and any caller that wants to short-circuit cache
    /// updates while a blocking sheet is up.
    static func dialogPresent(runtime: Runtime = .production) -> Bool {
        guard let app = appRoot(runtime: runtime) else { return false }
        guard let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) else { return true }
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

    /// #453: the blocking dialog together with the ELEMENT it was read from and
    /// its titled button elements.
    ///
    /// `BlockingDialogInfo` is `Sendable` and carries only strings, which is what
    /// makes it safe to publish as diagnostics — but it also means a caller that
    /// decides something from it has to find the dialog again to act, and "find
    /// the first AXDialog" evaluated a second time can resolve a DIFFERENT window.
    /// A caller that must act on precisely the window it classified takes this
    /// instead and holds the element, so identity is the element itself rather
    /// than a predicate re-run against whatever is frontmost at click time.
    struct BlockingDialogTarget {
        let element: AXUIElement
        let buttons: [(element: AXUIElement, title: String)]
        let info: BlockingDialogInfo
    }

    static func blockingDialogTarget(runtime: Runtime = .production) -> BlockingDialogTarget? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        guard let dialog = windows.first(where: { isBlockingDialogWindow($0, runtime: runtime.ax) }) else {
            return nil
        }
        return blockingDialogTarget(dialog, runtime: runtime)
    }

    /// Build a target from the exact top-level dialog a caller already scanned.
    /// This lets the complete modal reader reuse the normal non-blocking-dialog
    /// exclusions without replacing its classified window with a fresh ordinal
    /// search through `AXWindows`.
    static func blockingDialogTarget(
        _ dialog: AXUIElement,
        runtime: Runtime = .production
    ) -> BlockingDialogTarget? {
        guard isBlockingDialogWindow(dialog, runtime: runtime.ax) else { return nil }
        let subrole: String? = AXHelpers.getAttribute(dialog, kAXSubroleAttribute, runtime: runtime.ax)
        return blockingDialogTarget(
            dialog,
            observedSubrole: subrole,
            runtime: runtime
        )
    }

    /// Build a target from a window whose subrole was already read through a
    /// status-preserving scan. The complete modal reader must not discard that
    /// answer by asking the best-effort API a second time: a transient failure on
    /// the second request must not make an already-observed dialog disappear.
    static func blockingDialogTarget(
        _ dialog: AXUIElement,
        observedSubrole: String?,
        runtime: Runtime = .production
    ) -> BlockingDialogTarget? {
        guard isBlockingModalWindow(
            dialog,
            observedSubrole: observedSubrole,
            runtime: runtime.ax
        ) else { return nil }
        let title = (AXHelpers.getAttribute(dialog, kAXTitleAttribute, runtime: runtime.ax) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let role = observedSubrole ?? (kAXDialogSubrole as String)
        let owningWindow = (mainWindow(runtime: runtime).flatMap {
            AXHelpers.getTitle($0, runtime: runtime.ax)
        } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let buttons = titledButtons(of: dialog, runtime: runtime.ax)
        return BlockingDialogTarget(
            element: dialog,
            buttons: buttons,
            info: BlockingDialogInfo(
                title: title,
                role: role,
                owningWindow: owningWindow,
                buttonTitles: buttons.map(\.title),
                recoveryAction: blockingDialogRecoveryAction(title: title, buttons: buttons.map(\.title))
            )
        )
    }

    /// The dialog's actionable buttons: direct children with the button role and
    /// a non-empty trimmed title. Shared by the reader and the #453 re-check so
    /// "exactly one button" means the same thing at classify time and click time
    /// — two counts derived differently would let a gate pass on one definition
    /// and act on another.
    static func titledButtons(
        of dialog: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [(element: AXUIElement, title: String)] {
        AXHelpers.getChildren(dialog, runtime: runtime)
            .filter { AXHelpers.getRole($0, runtime: runtime) == (kAXButtonRole as String) }
            .compactMap { button in
                guard let title = AXHelpers.getTitle(button, runtime: runtime)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !title.isEmpty
                else { return nil }
                return (element: button, title: title)
            }
    }

    static func blockingDialogInfo(runtime: Runtime = .production) -> BlockingDialogInfo? {
        blockingDialogTarget(runtime: runtime)?.info
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

    static func isBlockingDialogWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute, runtime: runtime)
        guard subrole == (kAXDialogSubrole as String)
                || subrole == (kAXSystemDialogSubrole as String)
        else { return false }
        return isBlockingModalWindow(window, observedSubrole: subrole, runtime: runtime)
    }

    /// Applies the established non-blocking-dialog exclusions to a window whose
    /// modality was determined separately from `AXModal`. `AXSubrole` answers
    /// which modal kind this is; it does not decide whether the window blocks.
    /// A modal floating window has no current exclusion and therefore remains a
    /// blocker rather than being erased by the dialog-only exclusion helpers.
    static func isBlockingModalWindow(
        _ window: AXUIElement,
        observedSubrole: String?,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard observedSubrole == (kAXDialogSubrole as String)
                || observedSubrole == (kAXSystemDialogSubrole as String)
        else { return true }
        return !isKeyboardLayoutOverlayWindow(window, runtime: runtime)
            && !isPluginEditorWindow(window, observedSubrole: observedSubrole, runtime: runtime)
            && !isSmartControlsWindow(window, observedSubrole: observedSubrole, runtime: runtime)
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
    ///   3. a bypass-labeled toggle among the DIRECT children.
    /// A "toggle" is an `AXCheckBox` OR an `AXButton` (any subrole): the editor's
    /// toggle chrome ROLE-FLAPS with window focus on 12.3 — checkbox when the
    /// editor is key, button when it is not (live evidence `axwhy234b.out`,
    /// 2026-07-05: same 'Audio 1' window dumped minutes apart; Logic exposes the
    /// same toggle species as AXButton elsewhere, e.g. strip mute/solo).
    ///
    /// #381: a former conjunct 4 additionally required a compare- OR link-labeled
    /// toggle whose labels were English-only (empty locale `variants`, OQ-1), so a
    /// ko-KR (or any localized) plugin editor — which DOES carry a localized
    /// bypass toggle (`바이패스`) and a close-button
    /// attribute — failed conjunct 4 and was misclassified as BLOCKING, refusing
    /// unrelated ops while the editor was open. Conjunct 4 is dropped; conjunct 3
    /// is simultaneously TIGHTENED from substring to EXACT-field matching, because
    /// a substring bypass match is NOT modal-exclusive: Logic's own Bounce-in-Place
    /// dialog (reachable via `edit.bounce_in_place`) carries a "Bypass Effect
    /// Plug-ins" checkbox whose text CONTAINS "bypass" (adversarial review, #381
    /// B1). The editor's bypass toggle is labeled exactly `bypass`/`바이패스`
    /// (live `axwhy234.out`/`axwhy234b.out`), while the bounce checkbox is a
    /// longer phrase in every locale, so exact matching separates them without
    /// relying on conjunct 2. Honesty note: the premise that genuine modals carry
    /// no `kAXCloseButtonAttribute` is live-verified only for the #234 editor
    /// dumps, NOT for every modal class — conjunct 2 is treated as a narrowing
    /// guard, and the exact bypass label carries the discrimination. Unverified
    /// locales still fail conjunct 3 → stay blocking (fail-closed). Follows the
    /// `isKeyboardLayoutOverlayWindow` exclusion precedent.
    static func isPluginEditorWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute, runtime: runtime)
        return isPluginEditorWindow(window, observedSubrole: subrole, runtime: runtime)
    }

    /// As above, but reuse a caller's status-preserving subrole read.
    static func isPluginEditorWindow(
        _ window: AXUIElement,
        observedSubrole: String?,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard observedSubrole == (kAXDialogSubrole as String) else { return false }

        let closeButton: AXUIElement? = AXHelpers.getAttribute(
            window, kAXCloseButtonAttribute, runtime: runtime
        )
        guard closeButton != nil else { return false }

        // Scan AXCheckBox AND AXButton toggles — the labeled chrome role-flaps
        // with window focus (see doc comment).
        let directToggles = AXHelpers.getChildren(window, runtime: runtime).filter {
            let role = AXHelpers.getRole($0, runtime: runtime) ?? ""
            return role == (kAXCheckBoxRole as String) || role == (kAXButtonRole as String)
        }
        return directToggles.contains { child in
            hasExactLabel(child, matching: AXLocalePolicy.pluginBypassControl, runtime: runtime)
        }
    }

    /// True when ANY single label field (identifier, description, title, help) of
    /// `element` EXACTLY equals one of `labelSet`'s labels (trimmed,
    /// case-insensitive). Deliberately NOT a substring test over the joined
    /// `elementSearchText` aggregate: the non-blocking classifiers use this to
    /// tell chrome toggles labeled exactly `bypass`/`Smart Controls` apart from
    /// modal options that merely CONTAIN those words (e.g. the Bounce-in-Place
    /// dialog's "Bypass Effect Plug-ins" checkbox — #381 adversarial review B1).
    private static func hasExactLabel(
        _ element: AXUIElement,
        matching labelSet: AXLocalePolicy.LabelSet,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime)
        ]
        .contains { labelSet.matches($0, mode: .exact) }
    }

    /// #405: Logic 12 tags a Drummer track's "Smart Controls" pane with subrole
    /// `AXDialog` but — UNLIKE a plugin editor — WITHOUT a `kAXCloseButtonAttribute`
    /// (it is docked, not a floating editor), so `isPluginEditorWindow` (which
    /// requires the close-button, conjunct 2) never recognized it and it fell
    /// through to BLOCKING, refusing unrelated ops while the pane was open
    /// (live en-US evidence 2026-07: title `""`, subrole `AXDialog`, direct
    /// children include `Pad Controls`/`Kit Controls` buttons and a `Smart
    /// Controls` toggle, no close button).
    ///
    /// Recognized CONJUNCTIVELY, fail-closed on any missing conjunct:
    ///   1. subrole `AXDialog`;
    ///   2. an EMPTY window title — a NARROWING guard only, NOT the modal
    ///      discriminator: NSAlert-style confirmation dialogs (unsaved-changes,
    ///      delete, overwrite) commonly have an empty `AXTitle` too (their
    ///      headline is an `AXStaticText` child), so an empty title does NOT
    ///      separate a real alert from this pane. It only keeps TITLED windows
    ///      out of this branch;
    ///   3. a toggle among the DIRECT children (checkbox OR button, matching the
    ///      editor role-flap precedent) whose SINGLE label field EXACTLY equals
    ///      `Smart Controls` — this is the SOLE discriminator. Exact-field
    ///      matching (never substring over the joined search text) keeps a
    ///      button that merely mentions the phrase in a longer label or tooltip
    ///      from matching.
    /// The label is English-only (`pluginWindowSmartControlsControl` has empty
    /// `variants`, OQ-1 — the localized string is unverified), so a non-EN DMD
    /// pane fails conjunct 3 and conservatively STAYS blocking (fail-closed),
    /// mirroring the bypass-label OQ-1 posture. No known modal carries a control
    /// labeled exactly `Smart Controls`, and a titled one is excluded by
    /// conjunct 2 regardless.
    static func isSmartControlsWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let subrole: String? = AXHelpers.getAttribute(window, kAXSubroleAttribute, runtime: runtime)
        return isSmartControlsWindow(window, observedSubrole: subrole, runtime: runtime)
    }

    /// As above, but reuse a caller's status-preserving subrole read.
    static func isSmartControlsWindow(
        _ window: AXUIElement,
        observedSubrole: String?,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard observedSubrole == (kAXDialogSubrole as String) else { return false }

        let title: String = AXHelpers.getAttribute(window, kAXTitleAttribute, runtime: runtime) ?? ""
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let directToggles = AXHelpers.getChildren(window, runtime: runtime).filter {
            let role = AXHelpers.getRole($0, runtime: runtime) ?? ""
            return role == (kAXCheckBoxRole as String) || role == (kAXButtonRole as String)
        }
        return directToggles.contains { child in
            hasExactLabel(
                child, matching: AXLocalePolicy.pluginWindowSmartControlsControl, runtime: runtime
            )
        }
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
