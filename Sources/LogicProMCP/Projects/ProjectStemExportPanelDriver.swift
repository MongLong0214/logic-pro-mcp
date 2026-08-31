import ApplicationServices
import Foundation

/// The one measured UI route that makes a Logic per-track export.  Its surface
/// is deliberately semantic and injectable: AX status codes are not evidence
/// that a menu or button action landed, so the driver tests the observations
/// that make each transition safe instead of testing a collection of calls.
enum ProjectStemExportPanelDriver {
    static let stemLeafPickAction = kAXPickAction as String
    enum PanelPresence: Sendable, Equatable {
        case present
        case absent
        case unavailable
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
        func openExportMenu() -> Bool
        /// Resolve the enabled leaf only after both parent menus are open.
        func resolveStemLeaf() -> Bool
        /// Popup menu leaves require AXPick; AXPress is a measured silent no-op.
        func pickStemLeaf()
        /// Distinguishes an observed absence from a failed AX readback. A
        /// close press is never evidence that AC-6 has been met.
        func exportPanelPresence() -> PanelPresence
        func destinationPopupValue() -> String?
        /// Selects a folder element in the export panel's browser. It must
        /// never type a path, because typing dismisses this panel in Logic.
        func selectDestinationBrowserElement(at path: String) -> Bool
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
            }
        }

        // AC-1: menu opening strictly precedes the enablement read in
        // `resolveStemLeaf`. The fake surface records this order.
        guard surface.openFileMenu() else {
            return finish(.refused("stem_export_file_menu_unavailable"))
        }
        guard surface.openExportMenu() else {
            return finish(.refused("stem_export_export_menu_unavailable"))
        }
        guard surface.resolveStemLeaf() else {
            return finish(.refused("stem_export_menu_leaf_unavailable_after_open"))
        }
        surface.pickStemLeaf()
        switch surface.exportPanelPresence() {
        case .present:
            break
        case .absent:
            return finish(.refused("stem_export_panel_not_observed_after_axpick"))
        case .unavailable:
            return finish(.refused("readback_unavailable: stem_export_panel_not_observed_after_axpick"))
        }

        let beforeDestination = surface.destinationPopupValue()
        guard surface.selectDestinationBrowserElement(at: destination) else {
            return finish(.refused("stem_destination_browser_selection_failed"))
        }
        guard let afterDestination = surface.destinationPopupValue(),
              destinationChanged(from: beforeDestination, to: afterDestination),
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

private final class AXSurface: ProjectStemExportPanelDriver.Surface, @unchecked Sendable {
    private let runtime: AXLogicProElements.Runtime

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

    func openExportMenu() -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let export = menuItem(in: app, matching: isExportMenuTitle) else {
            return false
        }
        return AXHelpers.performAction(export, kAXPressAction as String, runtime: runtime.ax)
    }

    func resolveStemLeaf() -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let leaf = menuItem(in: app, matching: ProjectStemExportPanelDriver.stemLeafTitleMatches) else {
            return false
        }
        // This read intentionally happens here, after `openFileMenu` and
        // `openExportMenu`; closed-menu enablement is not a valid observation.
        let enabled: NSNumber? = AXHelpers.getAttribute(
            leaf, kAXEnabledAttribute as String, runtime: runtime.ax
        )
        return enabled?.boolValue == true
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
        let count = exportPanels(in: windows).count
        switch count {
        case 0: return .absent
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

    func selectDestinationBrowserElement(at path: String) -> Bool {
        guard let panel = exportPanel() else { return false }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        // The browser exposes folder rows and cells. Count BOTH role sets and
        // then require one path-bearing match, rather than inheriting AX tree
        // order when the same folder is presented twice.
        let rows = AXHelpers.censusDescendant(
            of: panel, role: kAXRowRole as String, maxDepth: 16, runtime: runtime.ax
        )
        let cells = AXHelpers.censusDescendant(
            of: panel, role: kAXCellRole as String, maxDepth: 16, runtime: runtime.ax
        )
        let folders = (rows.matches + cells.matches).filter { element in
            let texts = [
                elementText(element),
                AXHelpers.getAttribute(element, kAXURLAttribute as String, runtime: runtime.ax) as String?,
            ].compactMap { $0 }
            return texts.contains { text in
                normalizedFilePath(text) == wanted
            }
        }
        guard folders.count == 1, let folder = folders.first else {
            return false
        }
        // Browser rows/cells are not popup menu leaves, so use their ordinary
        // press action. There is deliberately no keyboard path fallback.
        return AXHelpers.performAction(folder, kAXPressAction as String, runtime: runtime.ax)
    }

    func oneFilePerTrackIsActive() -> Bool {
        guard let panel = exportPanel() else { return false }
        return popupButtons(in: panel).contains { popup in
            (elementText(popup) ?? "").caseInsensitiveCompare("One File per Track") == .orderedSame
        }
    }

    func pressExport() -> Bool {
        guard let panel = exportPanel(),
              let export = buttons(in: panel).first(where: {
                  (elementText($0) ?? "").caseInsensitiveCompare("Export") == .orderedSame
              }) else {
            return false
        }
        return AXHelpers.performAction(export, kAXPressAction as String, runtime: runtime.ax)
    }

    func progressWindowPresent() -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return false }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) ?? []
        return windows.contains {
            (AXHelpers.getTitle($0, runtime: runtime.ax) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "Logic Pro"
        }
    }

    func closeExportPanel() -> Bool {
        guard let panel = exportPanel(),
              let cancel = buttons(in: panel).first(where: {
                  (elementText($0) ?? "").caseInsensitiveCompare("Cancel") == .orderedSame
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
            let titles = Set(buttons(in: window).compactMap(elementText))
            return titles.contains("Export") && titles.contains("Cancel")
        }
    }

    private func menuItem(
        in app: AXUIElement,
        matching predicate: (String) -> Bool
    ) -> AXUIElement? {
        let census = AXHelpers.censusDescendant(
            of: app, role: kAXMenuItemRole as String, maxDepth: 12, runtime: runtime.ax
        )
        let matches = census.matches.filter {
            predicate(AXHelpers.getTitle($0, runtime: runtime.ax) ?? "")
        }
        return matches.count == 1 ? matches[0] : nil
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

    private func isExportMenuTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Export") == .orderedSame
    }

    /// Selection rewrites this title (for example `1 Track as Audio File…`),
    /// so an exact canonical-title matcher would be a false route guarantee.
}

extension ProjectStemExportPanelDriver {
    /// Selection rewrites this title (for example `1 Track as Audio File…`),
    /// so an exact canonical-title matcher would be a false route guarantee.
    static func stemLeafTitleMatches(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("track")
            && normalized.contains("audio file")
            && !normalized.contains("selected")
    }
}
