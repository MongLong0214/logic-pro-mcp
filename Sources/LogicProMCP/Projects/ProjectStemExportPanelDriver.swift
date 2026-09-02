import ApplicationServices
import Foundation

/// The one measured UI route that makes a Logic per-track export.  Its surface
/// is deliberately semantic and injectable: AX status codes are not evidence
/// that a menu or button action landed, so the driver tests the observations
/// that make each transition safe instead of testing a collection of calls.
enum ProjectStemExportPanelDriver {
    static let stemLeafPickAction = kAXPickAction as String
    static let exportMenuLabelNotMeasuredReason =
        "stem_export_export_menu_label_not_measured_for_current_locale"
    static let stemLeafLabelNotMeasuredReason =
        "stem_export_all_tracks_audio_file_label_not_measured_for_current_locale"
    static let panelLabelNotMeasuredReason =
        "stem_export_panel_label_not_measured_for_current_locale"
    // Live Logic observation on 2026-09-01, 8 samples: the panel appeared
    // 1005-1108 ms after AXPick on an idle machine. The deadline is 10,000 ms —
    // ~9x the observed maximum — because the samples describe the cheap case and
    // this wait exists for the expensive one: a machine under export load, where
    // a panel that is merely slow would otherwise be reported as a panel that
    // never appeared. Waiting longer costs nothing when the panel arrives in ~1 s;
    // a thin budget converts load into a false refusal. The bound stays finite so
    // a genuinely absent panel still refuses rather than hanging.
    static let exportPanelObservationDeadlineNanos: UInt64 = 10_000_000_000

    enum PanelPresence: Sendable, Equatable {
        case present
        case absent
        case unavailable
        /// An AXDialog appeared after AXPick, but its buttons use no measured
        /// stem-export labels. Its OS-localized Open-panel title is deliberately
        /// not used as a fallback signal.
        case unmeasured(String)
    }

    enum MenuAvailability: Sendable, Equatable {
        case available
        case unavailable(String)
    }

    enum DestinationSelection: Sendable, Equatable {
        case selected
        case refused(String)
    }

    enum Outcome: Sendable, Equatable {
        /// The Export button was pressed and the transient progress dialog was
        /// observed to disappear.
        case completed
        /// No Export click was made. The associated State C must expose
        /// `write_attempted:false`.
        case refused(String)
        /// Export was pressed, but completion could not be established. The
        /// caller must report State B rather than claim success.
        case uncertain(String)
    }

    protocol Surface: AnyObject, Sendable {
        /// Must materialize the File menu before `resolveStemLeaf` reads
        /// enabled state. Logic reports false enablement on closed menus.
        func openFileMenu() -> Bool
        /// Carries an exact failure reason because a locale without a measured
        /// Export label must refuse rather than fall back to a guessed title.
        func openExportMenu() -> MenuAvailability
        /// Resolve the enabled leaf only after both parent menus are open.
        /// Carries an exact failure reason because only measured all-tracks
        /// leaf labels are safe to pick.
        func resolveStemLeaf() -> MenuAvailability
        /// Popup menu leaves require AXPick; AXPress is a measured silent no-op.
        func pickStemLeaf()
        /// Distinguishes an observed absence from a failed AX readback. A
        /// close press is never evidence that AC-6 has been met.
        func exportPanelPresence() -> PanelPresence
        func destinationPopupValue() -> String?
        /// Selects a folder element in the export panel's browser. It must
        /// never type a path, because typing dismisses this panel in Logic.
        /// Selects a destination entirely through the measured AX browser
        /// primitive. A refusal names the failed component so `finish()` can
        /// still cancel a partially navigated panel.
        func selectDestinationBrowserElement(at path: String) -> DestinationSelection
        /// Reads the current per-track popup value; it does not infer enablement
        /// from the control merely existing.
        func oneFilePerTrackIsActive() -> Bool
        func pressExport() -> Bool
        func progressWindowPresent() -> Bool
        /// Attempts Cancel. The subsequent `exportPanelPresence()` readback,
        /// not this action's return, establishes whether the panel closed.
        @discardableResult func closeExportPanel() -> Bool
    }

    static func drive(
        destination: String,
        surface: Surface,
        progressPollAttempts: Int,
        sleep: @escaping @Sendable (UInt64) async -> Void,
        pollIntervalNanos: UInt64
    ) async -> Outcome {
        // AC-6: every exit attempts Cancel and then observes the panel's
        // absence. A press action is not a close confirmation.
        func finish(_ outcome: Outcome) -> Outcome {
            _ = surface.closeExportPanel()
            switch surface.exportPanelPresence() {
            case .absent:
                return outcome
            case .present:
                switch outcome {
                case .refused:
                    return .refused("stem_export_panel_remained_open_after_close_attempt")
                case .completed, .uncertain:
                    return .uncertain("stem_export_panel_remained_open_after_close_attempt")
                }
            case .unavailable:
                switch outcome {
                case .refused:
                    return .refused("readback_unavailable: stem_export_panel_close_not_observed")
                case .completed, .uncertain:
                    return .uncertain("readback_unavailable: stem_export_panel_close_not_observed")
                }
            case let .unmeasured(reason):
                // The initial observation already refused with the precise
                // missing-measurement reason. Do not replace it with a generic
                // close-readback error merely because an unmeasured panel cannot
                // be dismissed by a measured Cancel label. If one appears only
                // after a write, it prevents a success claim instead.
                switch outcome {
                case .refused:
                    return outcome
                case .completed, .uncertain:
                    return .uncertain(reason)
                }
            }
        }

        // AC-1: menu opening strictly precedes the enablement read in
        // `resolveStemLeaf`. The fake surface records this order.
        guard surface.openFileMenu() else {
            return finish(.refused("stem_export_file_menu_unavailable"))
        }
        switch surface.openExportMenu() {
        case .available:
            break
        case let .unavailable(reason):
            return finish(.refused(reason))
        }
        switch surface.resolveStemLeaf() {
        case .available:
            break
        case let .unavailable(reason):
            return finish(.refused(reason))
        }
        surface.pickStemLeaf()
        var panelWaitNanos: UInt64 = 0
        while true {
            switch surface.exportPanelPresence() {
            case .present:
                break
            case .absent:
                guard panelWaitNanos < exportPanelObservationDeadlineNanos,
                      pollIntervalNanos > 0 else {
                    return finish(.refused(
                        "stem_export_panel_not_observed_after_bounded_wait_elapsed"
                    ))
                }
                let remainingWaitNanos = exportPanelObservationDeadlineNanos - panelWaitNanos
                let nextWaitNanos = min(pollIntervalNanos, remainingWaitNanos)
                await sleep(nextWaitNanos)
                panelWaitNanos += nextWaitNanos
                continue
            case .unavailable:
                return finish(.refused("readback_unavailable: stem_export_panel_not_observed_after_axpick"))
            case let .unmeasured(reason):
                return finish(.refused(reason))
            }
            break
        }

        switch surface.selectDestinationBrowserElement(at: destination) {
        case .selected:
            break
        case let .refused(reason):
            return finish(.refused(reason))
        }
        // Confirm by identity, not by change. Logic's export panel reopens at the
        // last committed destination, so asking for that same folder produces no
        // change at all — requiring one made an already-correct panel permanently
        // unconfirmable (measured live 2026-09-02). The selection readback inside
        // `selectDestinationBrowserElement` is what proves the path; this popup
        // check is a second, weaker witness kept only to catch a panel that moved
        // somewhere else entirely.
        guard let afterDestination = surface.destinationPopupValue(),
              destinationDisplay(afterDestination, confirms: destination) else {
            return finish(.refused("stem_destination_not_confirmed_after_browser_selection"))
        }
        guard surface.oneFilePerTrackIsActive() else {
            return finish(.refused("stem_one_file_per_track_not_active"))
        }
        guard surface.pressExport() else {
            return finish(.refused("stem_export_button_not_pressed"))
        }

        var sawProgressWindow = false
        for attempt in 0..<max(1, progressPollAttempts) {
            let progressVisible = surface.progressWindowPresent()
            if sawProgressWindow && !progressVisible {
                return finish(.completed)
            }
            sawProgressWindow = sawProgressWindow || progressVisible
            if attempt + 1 < max(1, progressPollAttempts) {
                await sleep(pollIntervalNanos)
            }
        }
        return finish(sawProgressWindow
            ? .uncertain("stem_progress_window_did_not_disappear_within_budget")
            : .uncertain("readback_unavailable: stem_progress_window_not_observed"))
    }

    static func live(
        destination: String,
        progressPollAttempts: Int = 80,
        pollIntervalNanos: UInt64 = 250_000_000,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async -> Outcome {
        await drive(
            destination: destination,
            surface: AXSurface(),
            progressPollAttempts: progressPollAttempts,
            sleep: sleep,
            pollIntervalNanos: pollIntervalNanos
        )
    }

    static func destinationChanged(from before: String?, to after: String) -> Bool {
        guard let before else { return false }
        return before.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(after.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
    }

    /// Logic's measured destination popup showed the leaf name (`Logic`), not
    /// the full POSIX path. Accept either representation, but no arbitrary
    /// changed value: choosing the wrong visible folder is still a refusal.
    static func destinationDisplay(_ displayed: String, confirms path: String) -> Bool {
        let value = displayed.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        return value == destination.path || value == destination.lastPathComponent
    }
}

final class AXSurface: ProjectStemExportPanelDriver.Surface, @unchecked Sendable {
    private let runtime: AXLogicProElements.Runtime

    // Live navigation took 60 ms (volume root), 206 ms and 402 ms to materialize
    // the next column. Poll for 5 s at 50 ms intervals — ~12x the slowest of those.
    // The multiplier is deliberately large because a sibling measurement on this
    // same panel already exceeded its own observed maximum: the panel appeared
    // within 1005-1108 ms across eight samples and then took 1601 ms on a later
    // run. Idle-machine samples set the floor for these budgets, never the ceiling,
    // and a column that is merely slow must not be reported as a column that never
    // came. The bound stays finite so a genuinely stuck panel still refuses.
    private static let destinationNavigationDeadline: TimeInterval = 5.0
    private static let destinationNavigationPollInterval: TimeInterval = 0.05

    init(runtime: AXLogicProElements.Runtime = .production) {
        self.runtime = runtime
    }

    func openFileMenu() -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let menuBar: AXUIElement = AXHelpers.getAttribute(
                  app, "AXMenuBar", runtime: runtime.ax
              ),
              let item = AXLocalePolicy.findMenuBarItem(
                  in: menuBar,
                  matching: AXLocalePolicy.fileMenuBar,
                  runtime: runtime.ax
              ) else {
            return false
        }
        return AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
    }

    func openExportMenu() -> ProjectStemExportPanelDriver.MenuAvailability {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unavailable("stem_export_export_menu_unavailable")
        }
        let exports = menuItems(in: app, matching: ProjectStemExportPanelDriver.exportMenuTitleMatches)
        guard exports.count == 1, let export = exports.first else {
            return .unavailable(exports.isEmpty
                ? ProjectStemExportPanelDriver.exportMenuLabelNotMeasuredReason
                : "stem_export_export_menu_unavailable")
        }
        return AXHelpers.performAction(export, kAXPressAction as String, runtime: runtime.ax)
            ? .available
            : .unavailable("stem_export_export_menu_unavailable")
    }

    func resolveStemLeaf() -> ProjectStemExportPanelDriver.MenuAvailability {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unavailable("stem_export_menu_leaf_unavailable_after_open")
        }
        let leaves = menuItems(in: app, matching: ProjectStemExportPanelDriver.stemLeafTitleMatches)
        guard leaves.count == 1, let leaf = leaves.first else {
            return .unavailable(leaves.isEmpty
                ? ProjectStemExportPanelDriver.stemLeafLabelNotMeasuredReason
                : "stem_export_menu_leaf_unavailable_after_open")
        }
        // This read intentionally happens here, after `openFileMenu` and
        // `openExportMenu`; closed-menu enablement is not a valid observation.
        let enabled: NSNumber? = AXHelpers.getAttribute(
            leaf, kAXEnabledAttribute as String, runtime: runtime.ax
        )
        return enabled?.boolValue == true
            ? .available
            : .unavailable("stem_export_menu_leaf_unavailable_after_open")
    }

    func pickStemLeaf() {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let leaf = menuItem(in: app, matching: ProjectStemExportPanelDriver.stemLeafTitleMatches) else {
            return
        }
        // `AXPress` is a silent no-op for this popup leaf; AXPick is the
        // measured actuator. Its status code is not promoted to evidence — the
        // following panel observation is.
        _ = AXHelpers.performAction(
            leaf,
            ProjectStemExportPanelDriver.stemLeafPickAction,
            runtime: runtime.ax
        )
    }

    func exportPanelPresence() -> ProjectStemExportPanelDriver.PanelPresence {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unavailable
        }
        guard let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) else {
            return .unavailable
        }
        let panels = exportPanels(in: windows)
        let count = panels.count
        switch count {
        case 0:
            return hasUnmeasuredStemExportPanel(in: windows)
                ? .unmeasured(ProjectStemExportPanelDriver.panelLabelNotMeasuredReason)
                : .absent
        case 1: return .present
        default: return .unavailable
        }
    }

    func destinationPopupValue() -> String? {
        guard let panel = exportPanel(), let popup = popupButtons(in: panel).first else {
            return nil
        }
        return elementText(popup)
    }

    func selectDestinationBrowserElement(
        at path: String
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        guard let panel = exportPanel() else {
            return .refused("stem_destination_browser_panel_unavailable")
        }
        guard path.hasPrefix("/") else {
            return .refused("stem_destination_path_not_absolute")
        }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        let target = URL(fileURLWithPath: wanted)

        let startingDirectory: String
        if let listedDirectory = deepestListedAncestor(of: wanted, in: panel) {
            startingDirectory = listedDirectory
        } else {
            guard let volume = volume(containing: target) else {
                return .refused("stem_destination_volume_unresolvable")
            }
            switch selectVolumeRoot(named: volume.name, at: volume.root, in: panel) {
            case .selected:
                startingDirectory = volume.root
            case let .refused(reason):
                return .refused(reason)
            }
        }

        guard isDirectory(startingDirectory, anAncestorOf: wanted) else {
            return .refused("stem_destination_component_unresolved:\(wanted)")
        }

        var selectedPath = startingDirectory
        let remainingComponents = wanted.dropFirst(startingDirectory.count)
            .split(separator: "/")
            .map(String.init)
        for component in remainingComponents {
            selectedPath = URL(fileURLWithPath: selectedPath)
                .appendingPathComponent(component)
                .standardizedFileURL.path
            switch selectListedComponent(
                at: selectedPath,
                named: component,
                in: panel
            ) {
            case .selected:
                break
            case let .refused(reason):
                return .refused(reason)
            }
        }
        return .selected
    }

    func oneFilePerTrackIsActive() -> Bool {
        guard let panel = exportPanel() else { return false }
        return popupButtons(in: panel).contains { popup in
            AXLocalePolicy.oneFilePerTrackPopupValue.matches(elementText(popup))
        }
    }

    func pressExport() -> Bool {
        guard let panel = exportPanel(),
              let export = buttons(in: panel).first(where: {
                  AXLocalePolicy.stemExportCommitButton.matches(elementText($0))
              }) else {
            return false
        }
        return AXHelpers.performAction(export, kAXPressAction as String, runtime: runtime.ax)
    }

    /// The export progress dialog's title only LOOKS like `"Logic Pro"`. Measured
    /// on the live Korean UI, 2026-09-02, its scalars are
    /// `U+004C U+006F U+0067 U+0069 U+0063 U+00A0 U+0050 U+0072 U+006F` — the
    /// separator is a NO-BREAK SPACE. An `==` against `"Logic Pro"` is therefore
    /// false, and trimming cannot help because the character is interior, not at
    /// an edge. The consequence was silent and expensive: the export ran, the
    /// files landed, and the operation still reported
    /// `readback_unavailable: stem_progress_window_not_observed`, downgrading a
    /// real completion to State B.
    ///
    /// `LogicProTarget.normalizedProcessName` already exists for exactly this —
    /// it collapses every whitespace character to `U+0020`, so U+00A0 here and
    /// U+202F elsewhere both match while `LogicPro` with the separator removed
    /// still does not.
    func progressWindowPresent() -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return false }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        let wanted = LogicProTarget.normalizedProcessName("Logic Pro")
        return windows.contains {
            let title = (AXHelpers.getTitle($0, runtime: runtime.ax) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LogicProTarget.normalizedProcessName(title) == wanted
        }
    }

    func closeExportPanel() -> Bool {
        guard let panel = exportPanel(),
              let cancel = buttons(in: panel).first(where: {
                  AXLocalePolicy.stemExportDismissButton.matches(elementText($0))
              }) else {
            return false
        }
        return AXHelpers.performAction(cancel, kAXPressAction as String, runtime: runtime.ax)
    }

    private func exportPanel() -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        let panels = exportPanels(in: windows)
        return panels.count == 1 ? panels[0] : nil
    }

    private func exportPanels(in windows: [AXUIElement]) -> [AXUIElement] {
        windows.filter { window in
            let buttonTexts = buttons(in: window).compactMap(elementText)
            return buttonTexts.contains { AXLocalePolicy.stemExportCommitButton.matches($0) }
                && buttonTexts.contains { AXLocalePolicy.stemExportDismissButton.matches($0) }
        }
    }

    /// A post-AXPick AXDialog with buttons that match neither measured panel
    /// label set may be the export panel in an unmeasured locale. Its title is
    /// macOS's localized Open string, so it cannot safely refine this result.
    /// A dialog that matches only one known button remains merely a decoy, not
    /// a panel and not a locale measurement claim.
    private func hasUnmeasuredStemExportPanel(in windows: [AXUIElement]) -> Bool {
        windows.contains { window in
            let subrole: String? = AXHelpers.getAttribute(
                window, kAXSubroleAttribute as String, runtime: runtime.ax
            )
            guard subrole == (kAXDialogSubrole as String) else { return false }
            let buttonTexts = buttons(in: window).compactMap(elementText)
            guard !buttonTexts.isEmpty else { return false }
            return buttonTexts.allSatisfy {
                !AXLocalePolicy.stemExportCommitButton.matches($0)
                    && !AXLocalePolicy.stemExportDismissButton.matches($0)
            }
        }
    }

    private func menuItem(
        in app: AXUIElement,
        matching predicate: (String) -> Bool
    ) -> AXUIElement? {
        let matches = menuItems(in: app, matching: predicate)
        return matches.count == 1 ? matches[0] : nil
    }

    private func menuItems(
        in app: AXUIElement,
        matching predicate: (String) -> Bool
    ) -> [AXUIElement] {
        let census = AXHelpers.censusDescendant(
            of: app, role: kAXMenuItemRole as String, maxDepth: 12, runtime: runtime.ax
        )
        return census.matches.filter {
            predicate(AXHelpers.getTitle($0, runtime: runtime.ax) ?? "")
        }
    }

    private func buttons(in root: AXUIElement) -> [AXUIElement] {
        AXHelpers.findAllDescendants(of: root, role: kAXButtonRole as String, maxDepth: 12, runtime: runtime.ax)
    }

    private func popupButtons(in root: AXUIElement) -> [AXUIElement] {
        AXHelpers.findAllDescendants(of: root, role: kAXPopUpButtonRole as String, maxDepth: 12, runtime: runtime.ax)
    }

    private func elementText(_ element: AXUIElement) -> String? {
        let value = AXHelpers.getValue(element, runtime: runtime.ax) as? String
        return value ?? AXHelpers.getTitle(element, runtime: runtime.ax)
            ?? AXHelpers.getDescription(element, runtime: runtime.ax)
    }

    private func normalizedFilePath(_ value: String) -> String? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL.path
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private struct Volume {
        let root: String
        let name: String
    }

    private func volume(containing target: URL) -> Volume? {
        guard let values = try? target.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey]),
              let volumeURL = values.volume,
              let volumeName = values.volumeName else {
            return nil
        }
        return Volume(root: volumeURL.standardizedFileURL.path, name: volumeName)
    }

    /// The sidebar's volume label is user-settable and localized. There is no
    /// stable AX identifier or path attribute for it, so a missing or duplicate
    /// display-name match must refuse rather than guess at a sidebar row.
    private func selectVolumeRoot(
        named volumeName: String,
        at root: String,
        in panel: AXUIElement
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        let outlines = AXHelpers.censusDescendant(
            of: panel, role: kAXOutlineRole as String, maxDepth: 16, runtime: runtime.ax
        )
        guard outlines.matches.count == 1, let outline = outlines.matches.first else {
            return .refused("stem_destination_volume_outline_not_uniquely_resolvable")
        }
        let rows = AXHelpers.censusDescendant(
            of: outline, role: kAXRowRole as String, maxDepth: 16, runtime: runtime.ax
        ).matches
        let volumeRows = rows.filter { row in
            AXHelpers.censusDescendant(
                of: row, role: kAXStaticTextRole as String, maxDepth: 8, runtime: runtime.ax
            ).matches.contains { text in
                let value: String? = AXHelpers.getAttribute(
                    text, kAXValueAttribute as String, runtime: runtime.ax
                )
                return value?.trimmingCharacters(in: .whitespacesAndNewlines) == volumeName
            }
        }
        guard volumeRows.count == 1, let row = volumeRows.first else {
            return .refused(
                "stem_destination_volume_row_not_uniquely_resolvable:\(volumeName)"
            )
        }

        // The sidebar is an AXOutline, not an AXList, so there is no
        // AXSelectedChildren to read back here; the volume hop is confirmed by the
        // browser listing "/" contents.
        // A zero AX status only says the write was accepted. It does not say
        // Finder's browser changed, so its Boolean return is intentionally not
        // used as a success signal.
        _ = AXHelpers.setAttribute(
            outline,
            kAXSelectedRowsAttribute as String,
            [row] as CFArray,
            runtime: runtime.ax
        )
        guard waitsForSidebarSelection(of: row, in: outline) else {
            return .refused("stem_destination_volume_root_not_confirmed:\(volumeName)")
        }
        return .selected
    }

    private func selectListedComponent(
        at path: String,
        named component: String,
        in panel: AXUIElement
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        let entries = browserPathFields(in: panel).filter {
            urlPath(of: $0) == path
        }
        guard entries.count == 1, let entry = entries.first else {
            let failure = entries.isEmpty ? "not_listed" : "ambiguous"
            return .refused("stem_destination_component_\(failure):\(component)")
        }
        guard let group = ancestor(of: entry, role: kAXGroupRole as String, maxDepth: 8) else {
            return .refused("stem_destination_component_group_unresolved:\(component)")
        }
        guard let list = ancestor(of: group, role: kAXListRole as String, maxDepth: 8) else {
            return .refused("stem_destination_component_list_unresolved:\(component)")
        }

        // A successful AXSelectedChildren write is not navigation evidence; only
        // the selection readback or the child column below establishes it.
        _ = AXHelpers.setAttribute(
            list,
            kAXSelectedChildrenAttribute as String,
            [group] as CFArray,
            runtime: runtime.ax
        )
        guard waitsForSelection(of: path, in: list, panel: panel) else {
            return .refused("stem_destination_component_not_confirmed:\(component)")
        }
        return .selected
    }

    /// Confirms a navigation hop by PATH IDENTITY, never by a display name and
    /// never by the fact that something changed.
    ///
    /// Two signals qualify, both keyed on full POSIX paths:
    ///   1. the owning list reads back an `AXSelectedChildren` entry whose AXURL
    ///      is exactly this path;
    ///   2. the browser lists entries whose parent directory is exactly this path.
    ///
    /// The destination popup is deliberately NOT accepted here. It shows the
    /// folder's leaf name (`Logic`, `logic-pro-mcp-stem-test`), so it cannot tell
    /// this folder from a same-named folder elsewhere on the volume.
    ///
    /// Requiring the popup to have *changed* was worse than merely weak: Logic's
    /// export panel reopens at the last committed destination, so asking for that
    /// same folder produces no change at all, and an already-correct panel became
    /// permanently unconfirmable. Measured 2026-09-02 — this was the live failure
    /// `stem_destination_component_not_confirmed:logic-pro-mcp-stem-test`, where
    /// signal 2 was also silent because the target folder was empty. Signal 1
    /// answers both cases: measured the same day, the list read back
    /// `AXSelectedChildren = [/Users/isaac/Music/logic-pro-mcp-stem-test]`.
    private func waitsForSelection(
        of path: String,
        in list: AXUIElement?,
        panel: AXUIElement
    ) -> Bool {
        guard let list else { return false }
        let deadline = Date().addingTimeInterval(Self.destinationNavigationDeadline)
        repeat {
            if selectionReadsBack(path, in: list) {
                return true
            }
            Thread.sleep(forTimeInterval: Self.destinationNavigationPollInterval)
        } while Date() < deadline
        return false
    }

    /// The sidebar hop's equivalent: read the outline's selection back and check
    /// the row we wrote is the row it now reports. Measured 2026-09-02 —
    /// `AXSelectedRows` reads back one row labelled `Macintosh HD` after the write.
    private func waitsForSidebarSelection(of row: AXUIElement, in outline: AXUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(Self.destinationNavigationDeadline)
        repeat {
            let selected: [AXUIElement] = AXHelpers.getAttribute(
                outline, kAXSelectedRowsAttribute as String, runtime: runtime.ax
            ) ?? []
            if selected.contains(where: { CFEqual($0, row) }) {
                return true
            }
            Thread.sleep(forTimeInterval: Self.destinationNavigationPollInterval)
        } while Date() < deadline
        return false
    }

    /// Reads the list's selection back and compares AXURLs. A zero status from
    /// the write says only that the write was accepted.
    private func selectionReadsBack(_ path: String, in list: AXUIElement) -> Bool {
        let selected: [AXUIElement] = AXHelpers.getAttribute(
            list, kAXSelectedChildrenAttribute as String, runtime: runtime.ax
        ) ?? []
        return selected.contains { group in
            AXHelpers.censusDescendant(
                of: group, role: kAXTextFieldRole as String, maxDepth: 4, runtime: runtime.ax
            ).matches.contains { urlPath(of: $0) == path }
        }
    }

    private func listsChildren(of directory: String, in panel: AXUIElement) -> Bool {
        browserPathFields(in: panel).contains { field in
            guard let path = urlPath(of: field) else { return false }
            return URL(fileURLWithPath: path).deletingLastPathComponent().path == directory
        }
    }

    private func deepestListedAncestor(of path: String, in panel: AXUIElement) -> String? {
        let directories = Set(browserPathFields(in: panel).compactMap { field in
            urlPath(of: field).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        })
        return directories
            .filter { isDirectory($0, anAncestorOf: path) }
            .max { $0.count < $1.count }
    }

    private func browserPathFields(in panel: AXUIElement) -> [AXUIElement] {
        AXHelpers.censusDescendant(
            of: panel, role: kAXTextFieldRole as String, maxDepth: 16, runtime: runtime.ax
        ).matches.filter { urlPath(of: $0) != nil }
    }

    /// AXURL is a CFURL, never a CFString. Measured on the live export panel on
    /// 2026-09-02: of the entries carrying AXURL, 4 of 4 read as NSURL and 0 as
    /// String. Reading it as a String returned nil for every entry, which emptied
    /// the whole browser census silently — the destination stage then believed no
    /// ancestor was listed and refused on every machine. A String read here is not
    /// a stricter check; it is a guaranteed-empty one.
    private func urlPath(of field: AXUIElement) -> String? {
        let url: NSURL? = AXHelpers.getAttribute(
            field, kAXURLAttribute as String, runtime: runtime.ax
        )
        return url?.path.flatMap(normalizedFilePath)
    }

    private func ancestor(
        of element: AXUIElement,
        role: String,
        maxDepth: Int
    ) -> AXUIElement? {
        var current = element
        for _ in 0..<maxDepth {
            guard let parent: AXUIElement = AXHelpers.getAttribute(
                current, kAXParentAttribute as String, runtime: runtime.ax
            ) else {
                return nil
            }
            if AXHelpers.getRole(parent, runtime: runtime.ax) == role {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func isDirectory(_ directory: String, anAncestorOf path: String) -> Bool {
        directory == "/" || path == directory || path.hasPrefix(directory + "/")
    }

}

extension ProjectStemExportPanelDriver {
    static func exportMenuTitleMatches(_ title: String) -> Bool {
        AXLocalePolicy.exportMenuItem.matches(title)
    }

    static func stemLeafTitleMatches(_ title: String) -> Bool {
        AXLocalePolicy.allTracksAsAudioFilesMenuItem.matches(title)
    }
}
