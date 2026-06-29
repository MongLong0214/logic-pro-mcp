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
        let cancelMarkers = ["cancel", "취소"]
        if let cancel = buttons.first(where: { name in
            cancelMarkers.contains { name.lowercased().contains($0) }
        }) {
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
    private static func isTrackHeadersGroup(
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

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole, runtime: runtime.ax) {
            return toolbar
        }
        if let toolbar = AXHelpers.findDescendant(of: window, role: kAXToolbarRole, maxDepth: 6, runtime: runtime.ax),
           looksLikeTransportContainer(toolbar, runtime: runtime.ax) {
            return toolbar
        }
        if let group = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport", runtime: runtime.ax) {
            return group
        }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax)
        if let candidate = groups.first(where: { looksLikeTransportContainer($0, runtime: runtime.ax) }) {
            return candidate
        }

        return looksLikeTransportContainer(window, runtime: runtime.ax) ? window : nil
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String, runtime: Runtime = .production) -> AXUIElement? {
        guard let transport = getTransportBar(runtime: runtime) else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(
            of: transport, role: kAXButtonRole, title: name, runtime: runtime.ax
        ) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4, runtime: runtime.ax)
        for button in buttons {
            if AXHelpers.getDescription(button, runtime: runtime.ax) == name {
                return button
            }
        }
        return nil
    }

    /// Locate Logic Pro 12's control bar (컨트롤 막대 / Control Bar) — the AXGroup
    /// below the main arrange area that contains Play, Record, Cycle, Metronome,
    /// etc. as AXCheckBox widgets.
    static func getControlBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax)
        for group in groups {
            let desc = AXHelpers.getDescription(group, runtime: runtime.ax) ?? ""
            if AXLocalePolicy.controlBarGroupLabel.matches(desc, mode: .exactStrict) {
                return group
            }
        }
        return nil
    }

    /// Find an AXCheckBox inside Logic Pro's control bar by its name.
    /// Common names (Korean): `녹음` (Record), `재생` (Play), `사이클` (Cycle),
    /// `카운트 인` (Count-in), `메트로놈 클릭` (Metronome).
    /// English equivalents are also attempted as a fallback.
    static func findControlBarCheckbox(
        named koreanName: String,
        englishName: String? = nil,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let checkboxes = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax
        )
        // Prefer title match (AXTitle) — which is what `name of` returns in AS
        for cb in checkboxes {
            let title = AXHelpers.getTitle(cb, runtime: runtime.ax) ?? ""
            if title == koreanName { return cb }
            if let en = englishName, title == en { return cb }
        }
        // Fallback: description match
        for cb in checkboxes {
            let desc = AXHelpers.getDescription(cb, runtime: runtime.ax) ?? ""
            if desc == koreanName { return cb }
            if let en = englishName, desc == en { return cb }
        }
        return nil
    }

    /// Find the 마디 (bar) slider in Logic Pro's control bar. Setting this
    /// slider's value moves the playhead to the given bar.
    static func findControlBarBarSlider(runtime: Runtime = .production) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let sliders = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax
        )
        for s in sliders {
            let desc = AXHelpers.getDescription(s, runtime: runtime.ax) ?? ""
            if AXLocalePolicy.barSliderLabel.matches(desc, mode: .exactStrict) {
                return s
            }
        }
        return nil
    }

    /// Find the 템포 / Tempo slider in Logic's control bar. Double-clicking
    /// this slider opens an inline numeric-entry overlay (see
    /// AXMouseHelper.doubleClick for the exact interaction).
    ///
    /// Search order:
    ///   1. `getControlBar()` subtree (production path — AXGroup "컨트롤 막대")
    ///   2. `getTransportBar()` subtree (fallback — AXToolbar or "Transport" group)
    ///   3. Main window's entire slider descendants (last-resort, also covers
    ///      test doubles that build a minimal AX tree without the wrapper groups)
    static func findTempoSlider(runtime: Runtime = .production) -> AXUIElement? {
        let searchRoots: [AXUIElement] = [
            getControlBar(runtime: runtime),
            getTransportBar(runtime: runtime),
            mainWindow(runtime: runtime),
        ].compactMap { $0 }

        for root in searchRoots {
            let sliders = AXHelpers.findAllDescendants(
                of: root, role: kAXSliderRole, maxDepth: 8, runtime: runtime.ax
            )
            for s in sliders {
                let desc = (AXHelpers.getDescription(s, runtime: runtime.ax) ?? "").lowercased()
                if AXLocalePolicy.tempoSliderLabel.matches(desc, mode: .exactStrict) {
                    return s
                }
            }
        }
        return nil
    }

    /// Find the 비트 (beat) slider in the control bar (optional — for sub-bar positioning).
    static func findControlBarBeatSlider(runtime: Runtime = .production) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let sliders = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax
        )
        for s in sliders {
            let desc = AXHelpers.getDescription(s, runtime: runtime.ax) ?? ""
            if AXLocalePolicy.beatSliderLabel.matches(desc, mode: .exactStrict) {
                return s
            }
        }
        return nil
    }

    /// Read the current value (0/1) of a control-bar checkbox. Returns nil if
    /// the element can't be located or its value is not readable.
    static func readControlBarCheckboxValue(
        named koreanName: String,
        englishName: String? = nil,
        runtime: Runtime = .production
    ) -> Bool? {
        guard let cb = findControlBarCheckbox(
            named: koreanName, englishName: englishName, runtime: runtime
        ) else { return nil }
        if let n: NSNumber = AXHelpers.getAttribute(cb, kAXValueAttribute, runtime: runtime.ax) {
            return n.boolValue
        }
        if let b: Bool = AXHelpers.getAttribute(cb, kAXValueAttribute, runtime: runtime.ax) {
            return b
        }
        return nil
    }

    // MARK: - Tracks

    /// Returns true when Logic's main window is the Choose Project picker
    /// (shown when no project is open). Any AXOutline/AXTable inside the picker
    /// describes template choices, NOT tracks — misidentifying them yields
    /// bogus resource payloads and rename/mute ops that silently fail.
    static func isProjectPickerWindow(_ window: AXUIElement, runtime: Runtime) -> Bool {
        let title = (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "").lowercased()
        return AXLocalePolicy.projectPickerWindow.containsAny(in: title)
    }

    /// Find the track header area containing individual track rows.
    /// v3.1.8 (Issue #7) — outline/table fallback restricted to elements
    /// whose direct children contain `kAXLayoutItemRole`. The unconditional
    /// "first outline/table" fallback (pre-v3.1.8) silently matched the
    /// Inspector subtree when the Mixer panel was focused, causing
    /// `track.get_tracks` to surface Inspector field labels (`Mute:`,
    /// `Loop:`, ...) as track names — the v3.1.4 regression reported in #3.
    static func getTrackHeaders(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        if isProjectPickerWindow(window, runtime: runtime) { return nil }
        // Contracted / test-path lookups first.
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXListRole, identifier: "Track Headers", runtime: runtime.ax
        ) {
            return area
        }
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Tracks", runtime: runtime.ax
        ) {
            return area
        }

        // Live Logic 12 commonly exposes the track header rail as an AXGroup
        // inside the left scroll area rather than as an AXList/AXOutline.
        // Prefer the language-neutral selected-children structure, with
        // known ko/en descriptions retained as an explicit compatibility path.
        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax)
        if let headerGroup = groups.first(where: {
            isTrackHeadersGroup($0, runtime: runtime.ax)
        }) {
            return headerGroup
        }

        // Hardened fallback: only accept outline / table whose direct
        // children contain at least one `AXLayoutItem` (the role Logic Pro
        // 12 uses for track header rows). This prevents the Inspector outline
        // — which contains AXGroup field rows, not AXLayoutItem — from being
        // returned as a "track headers" candidate.
        let outlines = AXHelpers.findAllDescendants(
            of: window, role: kAXOutlineRole, maxDepth: 8, runtime: runtime.ax
        )
        let tables = AXHelpers.findAllDescendants(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime.ax
        )
        for candidate in outlines + tables {
            let children = AXHelpers.getChildren(candidate, runtime: runtime.ax)
            let hasLayoutItem = children.contains {
                (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXLayoutItemRole as String)
            }
            if hasLayoutItem {
                return candidate
            }
        }
        return nil
    }

    /// Find a track header at a specific index (0-based).
    /// Locate the AXOutline containing the track list. v3.0.3 — used by
    /// set_instrument for AX-native track selection (bypasses the coordinate-
    /// based track header click which fails for off-viewport tracks).
    static func findTrackOutline(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        let outlines = AXHelpers.findAllDescendants(
            of: window, role: "AXOutline", maxDepth: 12, runtime: runtime.ax
        )
        for o in outlines {
            var rowsRaw: AnyObject?
            _ = AXUIElementCopyAttributeValue(o, "AXRows" as CFString, &rowsRaw)
            if let rows = rowsRaw as? [AXUIElement], !rows.isEmpty {
                // Pick the outline whose rows expose AXDisclosureLevel (track list
                // hallmark — other outlines like Library browser don't).
                var attrs: CFArray?
                AXUIElementCopyAttributeNames(rows[0], &attrs)
                if (attrs as? [String])?.contains("AXDisclosureLevel") == true {
                    return o
                }
            }
        }
        return nil
    }

    static func findTrackHeader(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        let rows = allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Select a track using Apple's standard AX API before falling back to
    /// synthesised mouse input. v3.0.9 breakthrough — Logic Pro 12 exposes the
    /// track-header rail as an `AXGroup` whose `AXSelectedChildren` attribute
    /// IS the project's authoritative track-selection input. This mirrors the
    /// AX pattern that already works for Library preset selection (v3.0.3):
    /// `SetAttr(parent, AXSelectedChildren, [targetChild])`.
    ///
    /// Prior versions (v3.0.3–v3.0.8) tried `AXPress` on the track header as
    /// step 1; `AXUIElementPerformAction` returned `.success` vacuously even
    /// though the header's only declared action is `AXShowMenu`, so the ladder
    /// exited early with a FALSE POSITIVE and selection never moved. That
    /// cascaded into `set_instrument` always loading onto whatever track was
    /// actually selected (usually index 0) regardless of the `index` param.
    ///
    /// The fix is a single AX write to the parent group. Fallbacks are kept
    /// for test doubles that expose the track-header structure without a
    /// writable `AXSelectedChildren` (and for extreme Logic build drift).
    ///
    /// Returns true when the set succeeded OR a fallback committed the
    /// selection (verified by the caller's `verifyTrackSelection`).
    static func selectTrackViaAX(
        at index: Int,
        runtime: Runtime = .production
    ) -> Bool {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return false }

        // Step 1 (v3.0.9 primary path) — AXSelectedChildren on parent group.
        // This is the one mechanism that ACTUALLY moves Logic's track selection
        // (live-verified: 10/10 indices on a 10-track project). Every other AX
        // action on the track header is a no-op for selection purposes.
        if let headersGroup = getTrackHeaders(runtime: runtime) {
            let arr = [header] as CFArray
            let r = AXUIElementSetAttributeValue(
                headersGroup,
                kAXSelectedChildrenAttribute as CFString,
                arr
            )
            if r == .success { return true }
        }

        // Step 2 — NSTableRow-style AXSelected=true (test-double path).
        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(header, "AXSelected" as CFString, &isSettable)
        if isSettable.boolValue {
            let r = AXUIElementSetAttributeValue(header, "AXSelected" as CFString, kCFBooleanTrue)
            if r == .success { return true }
        }

        // Step 3 — AXPress on the header itself (test doubles that expose it).
        if AXHelpers.performAction(header, kAXPressAction, runtime: runtime.ax) {
            return true
        }

        // Step 4 — child AXPress (some rows expose a selectable name label).
        for child in AXHelpers.getChildren(header, runtime: runtime.ax) {
            if AXHelpers.performAction(child, kAXPressAction, runtime: runtime.ax) {
                return true
            }
        }

        // Step 5 — last resort: coord click at the header's name area.
        var posRaw: AnyObject?
        var sizeRaw: AnyObject?
        guard
            AXUIElementCopyAttributeValue(header, kAXPositionAttribute as CFString, &posRaw) == .success,
            AXUIElementCopyAttributeValue(header, kAXSizeAttribute as CFString, &sizeRaw) == .success,
            // H2 (P2-5): fail-closed on non-AXValue / wrong-subtype rather than
            // a (0,0) misclick.
            let pt = AXHelpers.point(fromRawAttribute: posRaw),
            let sz = AXHelpers.size(fromRawAttribute: sizeRaw)
        else { return false }
        let clickPoint = CGPoint(x: pt.x + min(60, sz.width / 4), y: pt.y + sz.height / 2)
        return LibraryAccessor.productionMouseClick(at: clickPoint)
    }

    /// Enumerate all track header rows.
    /// v3.1.8 (Issue #7) — Inspector contamination is prevented at the
    /// CONTAINER level by `getTrackHeaders` (only outlines/tables with
    /// AXLayoutItem children pass the fallback). Once a container is
    /// trusted (whether by identifier match or layout-item fallback),
    /// children are accepted as-is. This preserves backward compatibility
    /// with fake AX trees that don't set explicit roles on test rows.
    static func allTrackHeaders(runtime: Runtime = .production) -> [AXUIElement] {
        guard let headers = getTrackHeaders(runtime: runtime) else { return [] }
        let directChildren = AXHelpers.getChildren(headers, runtime: runtime.ax)
        if !directChildren.isEmpty {
            if directChildren.contains(where: {
                (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXLayoutItemRole as String)
            }) {
                return directChildren.filter {
                    (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXLayoutItemRole as String)
                }
            }
            return directChildren
        }

        let layoutItems = AXHelpers.findAllDescendants(of: headers, role: kAXLayoutItemRole, maxDepth: 3, runtime: runtime.ax)
        if !layoutItems.isEmpty {
            return layoutItems
        }
        return []
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        // Legacy/test-path lookup. Older Logic builds and existing fake AX
        // trees expose the mixer with AXIdentifier="Mixer".
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return mixer
        }
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return mixer
        }

        // Logic Pro 12.2 exposes the visible bottom Mixer as:
        //   AXGroup(desc:"믹서") -> AXLayoutArea(desc:"믹서") -> AXLayoutItem strips
        // with no AXIdentifier. Do not fall back to the Inspector's small
        // two-strip "믹서" area; that would make a full mixer read silently
        // return only selected-track + output strips.
        return mixerAreaCandidates(in: window, runtime: runtime.ax)
            .sorted { lhs, rhs in
                if lhs.stripCount != rhs.stripCount { return lhs.stripCount > rhs.stripCount }
                return lhs.totalChildCount > rhs.totalChildCount
            }
            .first?
            .element
    }

    /// #107: the per-track volume fader inside the track HEADER (an AXSlider
    /// whose value-indicator reads "Volume"). Same channel parameter as the
    /// mixer-strip fader, but identity-safe — it belongs to exactly track
    /// `index` — and always present without the Mixer being visible. Logic
    /// ignores AXValue writes on it, so callers drive it with
    /// AXIncrement/AXDecrement detents.
    static func findTrackHeaderVolumeFader(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        return findVolumeFader(in: header, runtime: runtime.ax)
    }

    /// #107: the per-track pan slider inside the track HEADER. Its own
    /// description is empty; the "Pan"/"팬" label lives on its
    /// `AXValueIndicator` child. Falls back to the non-volume slider.
    static func findTrackHeaderPanControl(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        return findPanControlInHeader(header, runtime: runtime.ax)
    }

    /// Header-level pan-slider selection (split out for deterministic testing).
    static func findPanControlInHeader(_ header: AXUIElement, runtime: AXHelpers.Runtime = .production) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(of: header, role: kAXSliderRole, maxDepth: 4, runtime: runtime)
        if let pan = sliders.first(where: { slider in
            AXHelpers.getChildren(slider, runtime: runtime).contains { child in
                let desc = (AXHelpers.getDescription(child, runtime: runtime) ?? "").lowercased()
                return AXLocalePolicy.headerPanHint.containsAny(in: desc)
            }
        }) {
            return pan
        }
        // Fallback: the slider that is NOT the volume fader.
        let volume = findVolumeFader(in: header, runtime: runtime)
        return sliders.first { volume == nil || !CFEqual($0, volume!) }
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime) else { return nil }
        let strips = mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        return findVolumeFader(in: strip, runtime: runtime.ax)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime) else { return nil }
        let strips = mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        return findPanControl(in: strip, runtime: runtime.ax)
    }

    private struct MixerAreaCandidate {
        let element: AXUIElement
        let stripCount: Int
        let totalChildCount: Int
    }

    private static func mixerAreaCandidates(
        in root: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [MixerAreaCandidate] {
        var candidates: [MixerAreaCandidate] = []
        collectMixerAreaCandidates(
            root,
            runtime: runtime,
            depth: 0,
            ancestorIsInspector: false,
            into: &candidates
        )
        return candidates
    }

    private static func collectMixerAreaCandidates(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime,
        depth: Int,
        ancestorIsInspector: Bool,
        into candidates: inout [MixerAreaCandidate]
    ) {
        guard depth <= 12 else { return }

        let text = elementSearchText(element, runtime: runtime)
        let isInspector = ancestorIsInspector
            || AXLocalePolicy.mixerInspectorContext.containsAny(in: text)

        if !isInspector,
           isMixerNamedElement(element, runtime: runtime),
           isMixerContainerRole(AXHelpers.getRole(element, runtime: runtime)),
           hasDirectChannelStripChildren(element, runtime: runtime) {
            let strips = mixerChannelStrips(in: element, runtime: runtime)
            candidates.append(MixerAreaCandidate(
                element: element,
                stripCount: strips.count,
                totalChildCount: AXHelpers.getChildren(element, runtime: runtime).count
            ))
        }

        for child in AXHelpers.getChildren(element, runtime: runtime) {
            collectMixerAreaCandidates(
                child,
                runtime: runtime,
                depth: depth + 1,
                ancestorIsInspector: isInspector,
                into: &candidates
            )
        }
    }

    private static func isMixerContainerRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == (kAXGroupRole as String)
            || role == (kAXScrollAreaRole as String)
            || role == "AXLayoutArea"
    }

    private static func isMixerNamedElement(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let candidates = [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime)
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { AXLocalePolicy.mixerNamedElement.labels.contains($0) }
    }

    private static func hasDirectChannelStripChildren(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        !mixerChannelStrips(in: element, runtime: runtime).isEmpty
    }

    static func mixerChannelStrips(
        in mixer: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [AXUIElement] {
        let children = AXHelpers.getChildren(mixer, runtime: runtime)
        let layoutItems = children.filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXLayoutItemRole as String)
        }
        return layoutItems.isEmpty ? children : layoutItems
    }

    static func findVolumeFader(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(
            of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        if let described = sliders.first(where: { sliderText($0, runtime: runtime).isVolumeFader }) {
            return described
        }
        return sliders.first
    }

    static func findPanControl(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let sliders = AXHelpers.findAllDescendants(
            of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        if let described = sliders.first(where: { sliderText($0, runtime: runtime).isPanControl }) {
            return described
        }
        return sliders.count > 1 ? sliders[1] : nil
    }

    static func pluginSlots(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [PluginSlotState] {
        var plugins: [PluginSlotState] = []
        for child in AXHelpers.getChildren(strip, runtime: runtime) {
            guard let name = occupiedPluginSlotName(child, runtime: runtime) else {
                continue
            }
            plugins.append(PluginSlotState(
                index: plugins.count,
                name: name,
                isBypassed: pluginSlotBypassState(child, runtime: runtime) ?? false
            ))
        }
        return plugins
    }

    /// Read state of an insert slot, kept SEPARATE from `name` so an occupied
    /// slot whose name could not be read is never mistaken for an empty one
    /// (rev-4 D4). Raw values double as the public `get_inventory.read_status`
    /// strings ("empty"/"ok"/"unreadable") per requirements R3.
    enum SlotReadStatus: String, Sendable, Equatable {
        case empty
        case occupiedReadable = "ok"
        case occupiedUnreadable = "unreadable"
    }

    struct PluginInsertSlot {
        /// PHYSICAL slot position. Preserved across unreadable occupied slots
        /// so an explicit `insert: N` always addresses the same physical slot
        /// (rev-4 D1 — drift fix).
        let index: Int
        let element: AXUIElement
        let name: String?
        let isBypassed: Bool?
        let readStatus: SlotReadStatus

        var occupied: Bool { readStatus != .empty }

        /// "Safe to write into" — true ONLY for a verified-empty slot. An
        /// occupied slot whose name is unreadable returns false so the legacy
        /// `insert_plugin` occupied-slot guard cannot silently overwrite it
        /// (rev-4 D4 / AC21). Do NOT reduce this back to `name == nil`.
        var isEmpty: Bool { readStatus == .empty }
    }

    /// Enumerate a strip's audio-plugin insert slots WITHOUT dropping any slot.
    ///
    /// rev-4 D1: the previous implementation `continue`d past an occupied slot
    /// whose name was unreadable and renumbered with `slots.count`, so a
    /// physical insert 3 could be reported as insert 2. Now every recognised
    /// slot — empty, occupied-readable, occupied-unreadable — keeps its
    /// physical position; only non-slot children (fader / pan / sends / I/O)
    /// are skipped, which never shifts a slot index relative to other slots.
    static func audioPluginInsertSlots(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [PluginInsertSlot] {
        var slots: [PluginInsertSlot] = []
        let children = AXHelpers.getChildren(strip, runtime: runtime)
        for (offset, child) in children.enumerated() {
            if isEmptyAudioPluginSlot(child, siblings: children, offset: offset, runtime: runtime) {
                slots.append(PluginInsertSlot(
                    index: slots.count,
                    element: child,
                    name: nil,
                    isBypassed: nil,
                    readStatus: .empty
                ))
            } else if isOccupiedPluginSlotElement(child, runtime: runtime) {
                // Slot position is confirmed by structure (bypass + open/menu
                // children); the name may still be unreadable.
                let name = pluginSlotDisplayName(child, runtime: runtime)
                slots.append(PluginInsertSlot(
                    index: slots.count,
                    element: child,
                    name: name,
                    isBypassed: pluginSlotBypassState(child, runtime: runtime),
                    readStatus: name == nil ? .occupiedUnreadable : .occupiedReadable
                ))
            }
            // else: not an insert slot — skip without consuming an index.
        }
        return slots
    }

    private static func sliderText(
        _ slider: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> (text: String, isVolumeFader: Bool, isPanControl: Bool) {
        let text = elementSearchText(slider, runtime: runtime)
        let isSend = AXLocalePolicy.sliderSendHint.containsAny(in: text)
        let isZoom = AXLocalePolicy.sliderZoomHint.containsAny(in: text)
        let isVolume = !isSend && !isZoom && AXLocalePolicy.sliderVolumeHint.containsAny(in: text)
        let isPan = !isSend && !isZoom && AXLocalePolicy.sliderPanHint.containsAny(in: text)
        return (text, isVolume, isPan)
    }

    /// Structural predicate: is this element an OCCUPIED audio-plugin insert
    /// slot, regardless of whether its name can be read? An occupied slot is an
    /// AXGroup carrying both a bypass control and an open/menu control. Split
    /// out of `occupiedPluginSlotName` (rev-4 D4) so the enumerator can mark a
    /// slot occupied-but-unreadable instead of dropping it.
    static func isOccupiedPluginSlotElement(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXGroupRole as String) else {
            return false
        }
        let children = AXHelpers.getChildren(element, runtime: runtime)
        let hasBypass = children.contains { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginBypassControl.containsAny(in: text)
        }
        let hasOpenOrMenu = children.contains { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginOpenOrListControl.containsAny(in: text)
        }
        if hasBypass && hasOpenOrMenu {
            return true
        }
        // Locale-neutral fallback: Logic's occupied insert row is a short group
        // containing one bypass checkbox plus two action buttons (open + list).
        // This avoids depending on localized child descriptions such as
        // "바이패스"/"열기"/"목록"; the automation row has only one button and
        // is therefore not promoted.
        return isLanguageNeutralOccupiedPluginSlotElement(element, runtime: runtime)
    }

    /// Extract a usable plugin display name from an occupied slot group, or nil
    /// if the description is missing or is an automation-mode label (not a
    /// plugin name). Returning nil means "occupied but unreadable".
    static func pluginSlotDisplayName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let description = AXHelpers.getDescription(element, runtime: runtime)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return nil
        }
        let lower = description.lowercased()
        guard !AXLocalePolicy.pluginAutomationLabelExact.matches(lower, mode: .exactStrict),
              !AXLocalePolicy.pluginAutomationLabelSubstring.containsAny(in: lower) else {
            return nil
        }
        return description
    }

    /// Name of an occupied plugin slot, or nil if the element is not an
    /// occupied slot or its name is unreadable. Preserved as the composition of
    /// the structural predicate + name extractor so the wire-path `pluginSlots`
    /// enumerator keeps its exact prior behaviour (occupied-readable only).
    private static func occupiedPluginSlotName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard isOccupiedPluginSlotElement(element, runtime: runtime) else {
            return nil
        }
        return pluginSlotDisplayName(element, runtime: runtime)
    }

    private static func isEmptyAudioPluginSlot(
        _ element: AXUIElement,
        siblings: [AXUIElement],
        offset: Int,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXButtonRole as String) else {
            return false
        }
        // Logic Pro 12.2 exposes a short (~9 px) "Audio Plug-in" button at the
        // bottom of some strips. Live E2E showed that it is an add/append affordance
        // rather than an addressable insert row: clicking it mounts into a different
        // real slot. When AXSize is available, exclude these short stubs so
        // `insert:N` only names rows that can actually be targeted.
        if let size = AXHelpers.getSize(element, runtime: runtime),
           size.height > 0, size.height < 12 {
            return false
        }
        let text = elementSearchText(element, runtime: runtime)
        let isAudioSlot = AXLocalePolicy.audioPluginSlotLabel.containsAny(in: text)
        let isSendOrIO = AXLocalePolicy.sendOrIOControlLabel.containsAny(in: text)
        if isAudioSlot && !isSendOrIO {
            return true
        }
        return isLanguageNeutralEmptyAudioPluginSlot(
            element, siblings: siblings, offset: offset, runtime: runtime
        )
    }

    private static func pluginSlotBypassState(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool? {
        let children = AXHelpers.getChildren(element, runtime: runtime)
        guard let bypass = children.first(where: { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginBypassControl.containsAny(in: text)
        }) ?? children.first(where: { child in
            (AXHelpers.getRole(child, runtime: runtime) ?? "") == (kAXCheckBoxRole as String)
        }) else {
            return nil
        }
        return AXValueExtractors.extractButtonState(bypass, runtime: runtime)
    }

    private static func isLanguageNeutralOccupiedPluginSlotElement(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard pluginSlotFrame(element, runtime: runtime) != nil else { return false }
        let children = AXHelpers.getChildren(element, runtime: runtime)
        let hasCheckbox = children.contains {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXCheckBoxRole as String)
        }
        let buttonCount = children.filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXButtonRole as String)
        }.count
        return hasCheckbox && buttonCount >= 2
    }

    private static func isLanguageNeutralEmptyAudioPluginSlot(
        _ element: AXUIElement,
        siblings: [AXUIElement],
        offset: Int,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard languageNeutralEmptySlotCandidate(element, runtime: runtime),
              let frame = pluginSlotFrame(element, runtime: runtime) else {
            return false
        }

        var clusterCount = 1
        var cursor = offset - 1
        var lastFrame = frame
        while cursor >= 0,
              let other = pluginSlotFrame(siblings[cursor], runtime: runtime),
              languageNeutralEmptySlotCandidate(siblings[cursor], runtime: runtime),
              pluginSlotFramesAlign(frame, other),
              pluginSlotFramesAreAdjacent(lastFrame, other) {
            clusterCount += 1
            lastFrame = other
            cursor -= 1
        }
        cursor = offset + 1
        lastFrame = frame
        while cursor < siblings.count,
              let other = pluginSlotFrame(siblings[cursor], runtime: runtime),
              languageNeutralEmptySlotCandidate(siblings[cursor], runtime: runtime),
              pluginSlotFramesAlign(frame, other),
              pluginSlotFramesAreAdjacent(lastFrame, other) {
            clusterCount += 1
            lastFrame = other
            cursor += 1
        }
        if clusterCount >= 3 {
            return true
        }

        for neighborOffset in [offset - 1, offset + 1] where siblings.indices.contains(neighborOffset) {
            let neighbor = siblings[neighborOffset]
            guard isLanguageNeutralOccupiedPluginSlotElement(neighbor, runtime: runtime),
                  let neighborFrame = pluginSlotFrame(neighbor, runtime: runtime),
                  pluginSlotFramesAlign(frame, neighborFrame),
                  pluginSlotFramesAreAdjacent(frame, neighborFrame) else {
                continue
            }
            return true
        }
        return false
    }

    private static func languageNeutralEmptySlotCandidate(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXButtonRole as String),
              pluginSlotFrame(element, runtime: runtime) != nil else {
            return false
        }
        let subrole: String? = AXHelpers.getAttribute(
            element, kAXSubroleAttribute as String, runtime: runtime
        )
        guard subrole != (kAXSwitchSubrole as String) else { return false }
        guard AXHelpers.getChildren(element, runtime: runtime).isEmpty else { return false }
        return !isKnownNonInsertButtonText(elementSearchText(element, runtime: runtime))
    }

    private static func pluginSlotFrame(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CGRect? {
        guard let position = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime),
              size.width >= 44,
              size.height >= 12,
              size.height <= 24 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pluginSlotFramesAlign(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 3
            && abs(lhs.width - rhs.width) <= 3
            && abs(lhs.height - rhs.height) <= 6
    }

    private static func pluginSlotFramesAreAdjacent(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minY - rhs.minY) <= max(lhs.height, rhs.height) + 6
    }

    private static func isKnownNonInsertButtonText(_ text: String) -> Bool {
        AXLocalePolicy.nonInsertButtonText.containsAny(in: text)
    }

    private static func elementSearchText(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String {
        [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    // MARK: - Plugin Windows (verified parameter write — T5)

    /// Resolve the display name of the track header at `index` (0-based), or nil
    /// when the header is absent / unnamed. The verified parameter write matches
    /// the open plugin window by this name (T0 evidence: a stock-effect plugin
    /// window's AX title is the TRACK name, not the plugin name).
    static func trackName(at index: Int, runtime: Runtime = .production) -> String? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        let name = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax).name
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // `extractTrackState` falls back to "Untitled" when no name is readable;
        // treat that as "no resolvable name" rather than a window-title match key.
        guard !trimmed.isEmpty, trimmed != "Untitled" else { return nil }
        return trimmed
    }

    /// Find an OPEN plugin window whose AX title equals `trackName` AND which
    /// exposes a 1-level `AXSlider` matching `axDescription`. T0 evidence: a
    /// stock-effect plugin window is a separate `AXWindow`/`AXDialog` titled with
    /// the track name; its parameter controls are flat `AXSlider`s at the
    /// window's first child level, and only `AXDescription` is a stable matcher.
    ///
    /// Returns nil when no such window is open (the caller then attempts to open
    /// one, or fails closed). Both the title match and the slider presence are
    /// required so an unrelated same-titled window is never mistaken for the
    /// plugin window.
    static func openPluginWindow(
        forTrackName trackName: String,
        matchingSliderDescription axDescription: String,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        let target = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        for window in windows {
            let title = (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title == target else { continue }
            if pluginWindowSlider(in: window, axDescription: axDescription, runtime: runtime.ax) != nil {
                return window
            }
        }
        return nil
    }

    /// Find the parameter `AXSlider` inside a plugin window by its
    /// `AXDescription` (T0 evidence: the ONLY stable identifier — `AXIdentifier`
    /// is an unstable NSView id, and unnamed params share the locale word for
    /// "slider"). Matches against the window's slider descendants; the match is
    /// case-insensitive on the trimmed description.
    static func pluginWindowSlider(
        in window: AXUIElement,
        axDescription: String,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let target = axDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let sliders = AXHelpers.findAllDescendants(
            of: window, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        return sliders.first { slider in
            let desc = (AXHelpers.getDescription(slider, runtime: runtime) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return desc.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute, runtime: runtime.ax)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String], runtime: Runtime = .production) -> AXUIElement? {
        guard var current = getMenuBar(runtime: runtime) else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current, runtime: runtime.ax)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child, runtime: runtime.ax) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child, runtime: runtime.ax)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub, runtime: runtime.ax) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
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

    // MARK: - Track Controls

    /// Find a track-header toggle control (Mute / Solo / Record-enable).
    ///
    /// #106: Logic Pro 12.x renders all three as `AXCheckBox` elements
    /// (live-confirmed on 12.2: `desc="Mute"/"Solo"/"Record Enable"`,
    /// `settable=false`, only `AXPress`) — NOT `AXButton`. The prior Mute/Solo
    /// locators searched only `kAXButtonRole` and therefore returned nil on
    /// 12.x, so `track.set_mute`/`set_solo` never reached an executable AX
    /// write and the whole channel chain fell through to `channels_exhausted`.
    /// Only the arm locator searched checkboxes (which is why arm at least
    /// found its element). This unifies all three on the checkbox-first match
    /// using the centralized `AXLocalePolicy` label sets, keeping the legacy
    /// `AXButton` description/title fallback for build drift.
    static func findTrackToggleControl(
        in header: AXUIElement,
        labels: [String],
        legacyTitle: String,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        let checkboxes = AXHelpers.findAllDescendants(
            of: header, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax
        )
        if let match = checkboxes.first(where: { cb in
            guard let desc = AXHelpers.getDescription(cb, runtime: runtime.ax) else { return false }
            // Exact match preserves the historical arm locator semantics;
            // prefix match tolerates trailing state suffixes some builds append.
            return labels.contains(desc) || labels.contains { !$0.isEmpty && desc.hasPrefix($0) }
        }) {
            return match
        }
        // Legacy fallback: AXButton with description prefix / single-letter title.
        for label in labels {
            if let button = findButtonByDescriptionPrefix(in: header, prefix: label, runtime: runtime.ax) {
                return button
            }
        }
        return AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: legacyTitle, runtime: runtime.ax)
    }

    /// Find the mute button on a track header.
    static func findTrackMuteButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findTrackToggleControl(
            in: header, labels: AXLocalePolicy.trackMuteButton.labels, legacyTitle: "M", runtime: runtime
        )
    }

    /// Find the solo button on a track header.
    static func findTrackSoloButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findTrackToggleControl(
            in: header, labels: AXLocalePolicy.trackSoloButton.labels, legacyTitle: "S", runtime: runtime
        )
    }

    /// Find the record-arm button on a track header.
    /// Logic Pro 12 uses an `AXCheckBox` with description `녹음 활성화` (KR) or
    /// `Record Enable` (EN) inside each track header.
    static func findTrackArmButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findTrackToggleControl(
            in: header, labels: AXLocalePolicy.trackRecordEnableCheckbox.labels, legacyTitle: "R", runtime: runtime
        )
    }

    /// #109: the arrange Horizontal-Zoom AXSlider (range 0...1, settable).
    /// Logic honours AXValue writes here, so `set_zoom` can drive it directly
    /// with a verifiable read-back instead of an unmappable key command.
    static func findHorizontalZoomSlider(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        let labels = AXLocalePolicy.horizontalZoomSlider.labels
        return AXHelpers.findAllDescendants(of: window, role: kAXSliderRole, maxDepth: 16, runtime: runtime.ax)
            .first { slider in
                let desc = AXHelpers.getDescription(slider, runtime: runtime.ax) ?? ""
                return labels.contains { !$0.isEmpty && desc.contains($0) }
            }
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4, runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax)
    }

    // MARK: - Markers

    /// Defensive upper bound on AX marker enumeration. Logic projects in the
    /// wild rarely exceed a few dozen markers; this cap keeps the AX traversal
    /// cost predictable even for pathological 10k-marker compositions.
    private static let markerLimit = 512

    /// Enumerate user markers from the project. Strategy order reflects
    /// Logic AX surface drift across major versions:
    ///
    /// **v3.1.9 (Issue #8) — Logic 12.2+ primary**: scrape the dedicated
    /// **Marker List** window's `AXTable`. Logic 12.2 removed user markers
    /// from the main arrange window's AX subtree entirely (the `AXRuler`
    /// strategy that v3.1.8 introduced returns empty on 12.2 because there
    /// are zero `AXRuler` elements in the arrange window). The dedicated
    /// Marker List window — opened via `탐색 → 마커 목록 열기` /
    /// `Navigate → Open Marker List` — exposes markers as
    /// `AXRow → AXCell` rows with name in cell column 2 and position in
    /// cell column 1.
    ///
    /// **v3.1.8 — Logic 11.x fallback**: `AXRuler` structural position
    /// inside the arrange area (the second `AXRuler` is the marker ruler;
    /// the first is the timeline). Preserved for older builds whose marker
    /// ruler is still in the arrange-window subtree.
    ///
    /// **legacy keyword fallback**: scan `AXGroup` descriptions for
    /// `marker` / `마커`. Preserved for very old Logic versions.
    ///
    /// Strategy 1's data quality requires the user to keep the Marker List
    /// window open. Callers that need first-class markers without a
    /// pre-opened window can set `LOGIC_PRO_MCP_AUTO_OPEN_MARKER_LIST=1`
    /// in the environment to trigger a one-time menu click on first
    /// successful project poll (see `defaultGetMarkers` in
    /// `AccessibilityChannel`).
    static func enumerateMarkers(
        in arrangementArea: AXUIElement,
        runtime: Runtime = .production
    ) -> [MarkerState] {
        // Strategy 1 — Logic 12.2+: scrape the Marker List window's AXTable.
        if let listWindow = findMarkerListWindow(runtime: runtime) {
            let listMarkers = enumerateMarkersFromListWindow(listWindow, runtime: runtime.ax)
            if !listMarkers.isEmpty { return listMarkers }
        }

        // Strategy 2 — Logic 11.x: AXRuler-based.
        var rulerElement: AXUIElement? = nil
        let rulers = AXHelpers.findAllDescendants(
            of: arrangementArea, role: "AXRuler", maxDepth: 6, runtime: runtime.ax
        )
        if rulers.count >= 2 {
            rulerElement = rulers[1]
        } else if let only = rulers.first {
            rulerElement = only
        }

        // Strategy 3 — keyword fallback (oldest path).
        if rulerElement == nil {
            // #60: centralized marker-container keyword bag (read-only classifier).
            let markerKeywords = AXLocalePolicy.markerContainerKeywords.labels
            let groups = AXHelpers.findAllDescendants(
                of: arrangementArea, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax
            )
            for group in groups {
                let id = AXHelpers.getIdentifier(group, runtime: runtime.ax)?.lowercased() ?? ""
                let desc = AXHelpers.getDescription(group, runtime: runtime.ax)?.lowercased() ?? ""
                let title = AXHelpers.getTitle(group, runtime: runtime.ax)?.lowercased() ?? ""
                let combined = "\(id) \(desc) \(title)"
                if markerKeywords.contains(where: { combined.contains($0.lowercased()) }) {
                    rulerElement = group
                    break
                }
            }
        }

        guard let ruler = rulerElement else { return [] }

        let texts = AXHelpers.findAllDescendants(
            of: ruler, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax
        )
        var markers: [MarkerState] = []
        markers.reserveCapacity(min(texts.count, markerLimit))
        for (index, text) in texts.prefix(markerLimit).enumerated() {
            let name = AXHelpers.getTitle(text, runtime: runtime.ax)
                ?? AXHelpers.getDescription(text, runtime: runtime.ax)
                ?? axValueAsName(text, runtime: runtime.ax)
                ?? ""
            guard !name.isEmpty else { continue }
            let parsed = extractMarkerPosition(text, runtime: runtime.ax)
            markers.append(.fromParsed(parsed, ordinal: index, name: name))
        }
        return markers
    }

    /// Locate the open Marker List window (Logic 12.2+ surface). Title
    /// suffix matches:
    ///   - `*- 마커 목록` (Korean localisation)
    ///   - `*- Marker List` (English)
    ///
    /// Returns nil if no such window is open. Window enumeration uses the
    /// `kAXWindowsAttribute` array on the application root; test doubles
    /// that don't implement that attribute correctly fall through to nil.
    /// Title-suffix patterns for the Logic Marker List window across the
    /// localisations Apple ships. Match by suffix because the window title
    /// is `"<project name> - <localized 'Marker List'>"`. Extending this
    /// array is the safe path when a new locale surfaces; matching is
    /// `O(suffixes × windows)` so keep the list focused on actual Logic
    /// localisations.
    static let markerListWindowSuffixes: [String] = [
        "- 마커 목록",          // Korean
        "- Marker List",         // English
        "- マーカーリスト",      // Japanese
        "- マーカー一覧",        // Japanese (alt — older Logic)
        "- Liste des marqueurs", // French
        "- Markerliste",         // German
        "- Lista de marcadores", // Spanish
        "- Elenco marker",       // Italian
        "- 标记列表",            // Chinese (Simplified)
        "- 標記列表",            // Chinese (Traditional)
        "- Список меток",        // Russian
        "- Lista de marcadores", // Portuguese (PT/BR same form)
        "- Lijst met markers"    // Dutch
    ]

    static func findMarkerListWindow(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        return windows.first { window in
            guard let title = AXHelpers.getTitle(window, runtime: runtime.ax) else {
                return false
            }
            return markerListWindowSuffixes.contains { title.hasSuffix($0) }
        }
    }

    /// Read `MarkerState[]` from the Marker List window's `AXTable`.
    ///
    /// Observed structure on Logic Pro 12.2 (verified 2026-05-07 against
    /// `무제 15.logicx` with 3 user markers):
    /// ```
    /// AXTable
    ///   AXRow
    ///     AXCell  (Lock column — empty)
    ///     AXCell ─ AXGroup(desc="1 1 1 1 ")  ← position, space-separated B B D T
    ///     AXCell ─ AXCell(desc="마커 1")     ← marker name
    ///     AXCell ─ AXGroup(desc="∞")          ← length, ∞ for trailing marker
    /// ```
    /// We extract name from cell index 2's first child description, position
    /// from cell index 1's first child description (parsed via
    /// `parseMarkerListPosition` to the canonical `"bar.beat.div.tick"` form).
    static func enumerateMarkersFromListWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [MarkerState] {
        let tables = AXHelpers.findAllDescendants(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        )
        guard let table = tables.first else { return [] }

        let rows: [AXUIElement] = AXHelpers.getAttribute(
            table, "AXRows", runtime: runtime
        ) ?? AXHelpers.getChildren(table, runtime: runtime).filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXRowRole as String)
        }

        var markers: [MarkerState] = []
        markers.reserveCapacity(min(rows.count, markerLimit))
        for (index, row) in rows.prefix(markerLimit).enumerated() {
            let cells = AXHelpers.getChildren(row, runtime: runtime).filter {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXCellRole as String)
            }
            // Need at least 3 cells: [Lock, Position, Name, ...].
            guard cells.count >= 3 else { continue }
            let positionRaw = firstChildDescription(of: cells[1], runtime: runtime) ?? ""
            let nameRaw = firstChildDescription(of: cells[2], runtime: runtime) ?? ""
            let name = nameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let parsed = parseMarkerListPosition(positionRaw)
            markers.append(.fromParsed(parsed, ordinal: index, name: name))
        }
        return markers
    }

    /// `AXCell`s in Logic's Marker List Table carry a placeholder
    /// AXDescription that's always the localized word for "cell". Skip
    /// these when extracting the meaningful child content. Extending this
    /// set is the safe path when a new locale surfaces.
    static let markerCellPlaceholders: Set<String> = [
        "셀",       // Korean
        "Cell",     // English
        "セル",     // Japanese
        "Cellule",  // French
        "Zelle",    // German
        "Celda",    // Spanish (also "Célula" in some locales)
        "Cella",    // Italian
        "单元格",   // Chinese (Simplified)
        "儲存格",   // Chinese (Traditional)
        "Ячейка",   // Russian
        "Célula",   // Portuguese
        "Cel"       // Dutch
    ]

    /// First non-empty `AXDescription` in `cell`'s direct children, skipping
    /// the localized placeholder ("셀" / "Cell" / "セル" / etc.) that
    /// `AXCell`s carry by default. Falls through to the cell's own
    /// description / value if no child carries a meaningful one.
    private static func firstChildDescription(
        of cell: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let placeholder = markerCellPlaceholders
        for child in AXHelpers.getChildren(cell, runtime: runtime) {
            if let desc = AXHelpers.getDescription(child, runtime: runtime),
               !desc.isEmpty,
               !placeholder.contains(desc) {
                return desc
            }
            if let value = AXHelpers.getValue(child, runtime: runtime) as? String,
               !value.isEmpty {
                return value
            }
        }
        if let cellDesc = AXHelpers.getDescription(cell, runtime: runtime),
           !cellDesc.isEmpty,
           !placeholder.contains(cellDesc) {
            return cellDesc
        }
        if let value = AXHelpers.getValue(cell, runtime: runtime) as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    /// Logic Marker List 셀의 위치 문자열을 표준 "bar.beat.div.tick" 형태로 변환한다.
    ///
    /// 관찰된 입력 변형:
    /// - 한글 12.2: `"1 1 1 1"` (공백 구분, whole-bar)
    /// - 영문 12.2: `"146 4 4 240."` (공백 구분 + UI 끝 마침표)
    ///
    /// 정확히 4 컴포넌트, 각 ASCII 정수 1 이상이어야 한다. Logic UI는 항상 4
    /// 컴포넌트를 노출하므로 1-3 컴포넌트는 비-position 셀(예: tempo)일 가능성으로
    /// nil 반환한다. 호출자는 `\(index+1).1.1.1` fallback을 사용한다.
    static func parseMarkerListPosition(_ raw: String) -> String? {
        // 끝의 마침표/콤마는 Logic UI rendering artifact — 반복 strip.
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, last == "." || last == "," {
            trimmed.removeLast()
        }
        // 공백/탭만 separator (Logic은 공백만 사용; 점은 끝에서만 의미).
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        // 정확히 4 컴포넌트 + ASCII 0-9만 (부호 prefix·Arabic-Indic 거부) + 1-based.
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  part.allSatisfy { $0.isASCII && $0.isNumber }
                      && (Int(part) ?? 0) >= 1
              }) else {
            return nil
        }
        return parts.joined(separator: ".")
    }

    private static func axValueAsName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let v = AXValueExtractors.extractTextValue(element, runtime: runtime),
              !v.isEmpty, !looksLikeBarPosition(v) else { return nil }
        return v
    }

    private static func extractMarkerPosition(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let candidates = [
            AXValueExtractors.extractTextValue(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
        ]
        for candidate in candidates {
            guard let raw = candidate, !raw.isEmpty else { continue }
            if looksLikeBarPosition(raw) { return raw }
        }
        return nil
    }

    private static func looksLikeBarPosition(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 1, parts.count <= 4 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Helpers

    private static func findButtonByDescriptionPrefix(
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

    private static func looksLikeTransportContainer(
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
