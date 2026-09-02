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
        /// A dialog has the stem-specific per-track control and exactly one
        /// measured button label. The associated values make the missing
        /// measurement actionable and tell `finish()` whether Cancel is known.
        case partiallyMeasured(recognized: String, notMeasured: String)
        /// An AXDialog appeared after AXPick, but its buttons use no measured
        /// stem-export labels. Its OS-localized Open-panel title is deliberately
        /// not used as a fallback signal.
        case unmeasured(String)
    }

    /// A progress observation keeps an unavailable AX read distinct from an
    /// observed absence. A transient failure must never advance completion.
    enum ProgressPresence: Sendable, Equatable {
        case present
        case absent
        case unavailable
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
        /// Completion could not be established after the Export route. The
        /// Boolean is evidence-derived: it is true only when the panel
        /// disappeared or the progress dialog appeared after the press.
        case uncertain(String, exportEffectObserved: Bool)
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
        /// Attempts Export. Its AX status is intentionally not returned: the
        /// driver judges the press only by the post-press observations below.
        func pressExport()
        func progressWindowPresence() -> ProgressPresence
        /// Attempts Cancel. The subsequent `exportPanelPresence()` readback,
        /// not this action's return, establishes whether the panel closed.
        func closeExportPanel()
    }

    static func drive(
        destination: String,
        surface: Surface,
        progressPollAttempts: Int,
        sleep: @escaping @Sendable (UInt64) async -> Void,
        pollIntervalNanos: UInt64,
        monotonicNowNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) async -> Outcome {
        // AC-6: every exit attempts Cancel and then observes the panel's
        // absence. A press action is not a close confirmation.
        func finish(_ outcome: Outcome) -> Outcome {
            surface.closeExportPanel()
            switch surface.exportPanelPresence() {
            case .absent:
                return outcome
            case .present:
                switch outcome {
                case .refused:
                    return .refused("stem_export_panel_remained_open_after_close_attempt")
                case .completed:
                    return .uncertain("stem_export_panel_remained_open_after_close_attempt", exportEffectObserved: true)
                case let .uncertain(_, exportEffectObserved):
                    return .uncertain("stem_export_panel_remained_open_after_close_attempt", exportEffectObserved: exportEffectObserved)
                }
            case .unavailable:
                switch outcome {
                case .refused:
                    return .refused("readback_unavailable: stem_export_panel_close_not_observed")
                case .completed:
                    return .uncertain("readback_unavailable: stem_export_panel_close_not_observed", exportEffectObserved: true)
                case let .uncertain(_, exportEffectObserved):
                    return .uncertain("readback_unavailable: stem_export_panel_close_not_observed", exportEffectObserved: exportEffectObserved)
                }
            case let .partiallyMeasured(recognized, notMeasured):
                let leftOpen = "stem_export_panel_left_open_after_close_attempt: recognized=\(recognized); not_measured=\(notMeasured)"
                switch outcome {
                case .refused:
                    return .refused(leftOpen)
                case .completed:
                    return .uncertain(leftOpen, exportEffectObserved: true)
                case let .uncertain(_, exportEffectObserved):
                    return .uncertain(leftOpen, exportEffectObserved: exportEffectObserved)
                }
            case let .unmeasured(reason):
                let leftOpen = "stem_export_panel_left_open_unmeasured: \(reason)"
                switch outcome {
                case .refused:
                    return .refused(leftOpen)
                case .completed:
                    return .uncertain(leftOpen, exportEffectObserved: true)
                case let .uncertain(_, exportEffectObserved):
                    return .uncertain(leftOpen, exportEffectObserved: exportEffectObserved)
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
        let panelWaitStarted = monotonicNowNanos()
        while true {
            switch surface.exportPanelPresence() {
            case .present:
                break
            case .absent:
                let now = monotonicNowNanos()
                let elapsed = now >= panelWaitStarted ? now - panelWaitStarted : UInt64.max
                guard elapsed < exportPanelObservationDeadlineNanos,
                      pollIntervalNanos > 0 else {
                    return finish(.refused(
                        "stem_export_panel_not_observed_after_bounded_wait_elapsed"
                    ))
                }
                let remainingWaitNanos = exportPanelObservationDeadlineNanos - elapsed
                let nextWaitNanos = min(pollIntervalNanos, remainingWaitNanos)
                await sleep(nextWaitNanos)
                continue
            case .unavailable:
                return finish(.refused("readback_unavailable: stem_export_panel_not_observed_after_axpick"))
            case let .partiallyMeasured(recognized, notMeasured):
                return finish(.refused(
                    "stem_export_panel_partially_measured: recognized=\(recognized); not_measured=\(notMeasured)"
                ))
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
        surface.pressExport()
        var sawProgressWindow = false
        var sawExportEffect = false
        var progressReadFailed = false
        var panelReadFailed = false
        for attempt in 0..<max(1, progressPollAttempts) {
            switch surface.exportPanelPresence() {
            case .absent:
                // The panel's observed disappearance is evidence that the press
                // landed, but not alone evidence that the export completed.
                sawExportEffect = true
            case .unavailable:
                panelReadFailed = true
            case .present, .partiallyMeasured, .unmeasured:
                break
            }
            switch surface.progressWindowPresence() {
            case .present:
                sawProgressWindow = true
                sawExportEffect = true
            case .absent:
                if sawProgressWindow {
                    return finish(.completed)
                }
            case .unavailable:
                progressReadFailed = true
            }
            if attempt + 1 < max(1, progressPollAttempts) {
                await sleep(pollIntervalNanos)
            }
        }
        if progressReadFailed || panelReadFailed {
            return finish(.uncertain(
                "readback_unavailable: stem_export_effect_or_progress_not_observed_after_press",
                exportEffectObserved: sawExportEffect
            ))
        }
        if sawProgressWindow {
            return finish(.uncertain(
                "stem_progress_window_did_not_disappear_within_budget",
                exportEffectObserved: true
            ))
        }
        if sawExportEffect {
            return finish(.uncertain(
                "stem_export_effect_observed_but_progress_window_not_observed",
                exportEffectObserved: true
            ))
        }
        return finish(.uncertain(
            "stem_export_press_effect_not_observed",
            exportEffectObserved: false
        ))
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
    private let directoryListing: @Sendable (String) -> DirectoryListing
    private let navigationNowNanos: @Sendable () -> UInt64
    private let navigationSleep: @Sendable (UInt64) -> Void

    enum DirectoryListing: Sendable, Equatable {
        case empty
        case hasEntries
        case unavailable
    }

    // Live navigation took 60 ms (volume root), 206 ms and 402 ms to materialize
    // the next column. Poll for 5 s at 50 ms intervals — ~12x the slowest of those.
    // The multiplier is deliberately large because a sibling measurement on this
    // same panel already exceeded its own observed maximum: the panel appeared
    // within 1005-1108 ms across eight samples and then took 1601 ms on a later
    // run. Idle-machine samples set the floor for these budgets, never the ceiling,
    // and a column that is merely slow must not be reported as a column that never
    // came. The bound stays finite so a genuinely stuck panel still refuses.
    private static let destinationNavigationDeadlineNanos: UInt64 = 5_000_000_000
    private static let destinationNavigationPollIntervalNanos: UInt64 = 50_000_000

    init(
        runtime: AXLogicProElements.Runtime = .production,
        directoryListing: @escaping @Sendable (String) -> DirectoryListing = { path in
            do {
                return try FileManager.default.contentsOfDirectory(atPath: path).isEmpty
                    ? .empty
                    : .hasEntries
            } catch {
                return .unavailable
            }
        },
        navigationNowNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        navigationSleep: @escaping @Sendable (UInt64) -> Void = { duration in
            Thread.sleep(forTimeInterval: Double(duration) / 1_000_000_000)
        }
    ) {
        self.runtime = runtime
        self.directoryListing = directoryListing
        self.navigationNowNanos = navigationNowNanos
        self.navigationSleep = navigationSleep
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
        // Status is not evidence that the menu materialised. `resolveStemLeaf`
        // observes the enabled leaf only after both menu-opening attempts.
        _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
        return true
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
        // The leaf observation below, rather than this status, proves that the
        // submenu became readable.
        _ = AXHelpers.performAction(export, kAXPressAction as String, runtime: runtime.ax)
        return .available
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
        switch panelAssessments() {
        case .failure:
            return .unavailable
        case let .success(assessments):
            guard assessments.count == 1, let assessment = assessments.first else {
                return assessments.isEmpty ? .absent : .unavailable
            }
            switch assessment {
            case .recognized:
                return .present
            case let .partiallyMeasured(_, recognized, notMeasured, _):
                return .partiallyMeasured(recognized: recognized, notMeasured: notMeasured)
            case .unmeasured:
                return .unmeasured(ProjectStemExportPanelDriver.panelLabelNotMeasuredReason)
            }
        }
    }

    /// Identifies the destination popup structurally, never by ordinal.
    ///
    /// The live panel carries SIX popup buttons — destination, dither, file
    /// format, bit depth, normalization, and end-silence trimming. Taking
    /// `.first` was reading whichever one AX traversal happened to yield, and
    /// measurement showed that order is not stable between reads. It is also the
    /// ordinal-selection pattern this project forbids outright.
    ///
    /// Measured 2026-09-02: exactly one of the six exposes an AXTitle (`위치:`);
    /// the other five report nil. That is a structural property of the panel, not
    /// a linguistic one, so it identifies the control without needing the label
    /// measured in every locale. More or fewer than one titled popup refuses
    /// rather than picking.
    func destinationPopupValue() -> String? {
        guard let panel = exportPanel() else { return nil }
        let titled = popupButtons(in: panel).filter { popup in
            let title: String? = AXHelpers.getTitle(popup, runtime: runtime.ax)
            return !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard titled.count == 1, let popup = titled.first else { return nil }
        // The VALUE is the folder; the TITLE was only the identity.
        return AXHelpers.getValue(popup, runtime: runtime.ax) as? String
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
        switch deepestListedAncestor(of: wanted, in: panel) {
        case .failure:
            return .refused("readback_unavailable: stem_destination_browser_entries_unreadable")
        case let .success(.some(listedDirectory)):
            startingDirectory = listedDirectory
        case .success(nil):
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

    func pressExport() {
        guard case let .success(assessments) = panelAssessments(),
              assessments.count == 1,
              case let .recognized(_, export, _) = assessments[0] else {
            return
        }
        // A status-zero AXPress can be a no-op and a failed status can still
        // coincide with a real press. `drive` observes panel/progress effects.
        _ = AXHelpers.performAction(export, kAXPressAction as String, runtime: runtime.ax)
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
    /// The comparison is owned by `AXLocalePolicy`, so this localized AX title
    /// follows the same policy route as every other measured UI label.
    func progressWindowPresence() -> ProjectStemExportPanelDriver.ProgressPresence {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return .unavailable }
        switch AXHelpers.getAXUIElementArrayRead(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) {
        case .failure, .success(.malformed):
            return .unavailable
        case .success(.absent):
            return .absent
        case let .success(.elements(windows)):
            for window in windows {
                switch AXHelpers.getAttributeResult(
                    window, kAXTitleAttribute as String, runtime: runtime.ax
                ) as Result<String?, AXHelpers.AXStatusError> {
                case .failure:
                    return .unavailable
                case let .success(title):
                    if let title, AXLocalePolicy.progressWindowTitleMatches(title) {
                        return .present
                    }
                }
            }
            return .absent
        }
    }

    func closeExportPanel() {
        guard case let .success(assessments) = panelAssessments(), assessments.count == 1 else {
            return
        }
        let cancel: AXUIElement?
        switch assessments[0] {
        case let .recognized(_, _, dismiss):
            cancel = dismiss
        case let .partiallyMeasured(_, recognized, _, dismiss):
            cancel = recognized == AXLocalePolicy.stemExportDismissButton.canonical ? dismiss : nil
        case .unmeasured:
            cancel = nil
        }
        guard let cancel else { return }
        // The following panel observation, not this action status, confirms close.
        _ = AXHelpers.performAction(cancel, kAXPressAction as String, runtime: runtime.ax)
    }

    private func exportPanel() -> AXUIElement? {
        guard case let .success(assessments) = panelAssessments(),
              assessments.count == 1,
              case let .recognized(panel, _, _) = assessments[0] else {
            return nil
        }
        return panel
    }

    private enum PanelAssessment {
        case recognized(AXUIElement, AXUIElement, AXUIElement)
        case partiallyMeasured(AXUIElement, recognized: String, notMeasured: String, dismiss: AXUIElement?)
        case unmeasured(AXUIElement)
    }

    private enum PanelReadFailure: Error {
        case unavailable
    }

    /// Surveys dialogs without flattening a failed child or label read into an
    /// empty descendant list. The panel signature requires all three facts:
    /// AXDialog, the per-track popup, and the measured buttons. This avoids
    /// cancelling a user's unrelated two-button export dialog.
    private func panelAssessments() -> Result<[PanelAssessment], PanelReadFailure> {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .failure(.unavailable)
        }
        switch AXHelpers.getAXUIElementArrayRead(
            app, kAXWindowsAttribute as String, runtime: runtime.ax
        ) {
        case .failure, .success(.malformed):
            return .failure(.unavailable)
        case .success(.absent):
            return .success([])
        case let .success(.elements(windows)):
            var assessments: [PanelAssessment] = []
            for window in windows {
                switch assessPanel(window) {
                case .failure:
                    return .failure(.unavailable)
                case let .success(assessment):
                    if let assessment { assessments.append(assessment) }
                }
            }
            return .success(assessments)
        }
    }

    private func assessPanel(_ window: AXUIElement) -> Result<PanelAssessment?, PanelReadFailure> {
        switch AXHelpers.getAttributeResult(
            window, kAXSubroleAttribute as String, runtime: runtime.ax
        ) as Result<String?, AXHelpers.AXStatusError> {
        case let .failure(error):
            guard Self.absentAttributeStatuses.contains(error.raw) else {
                return .failure(.unavailable)
            }
            // No subrole at all means this is not the dialog we are looking for.
            return .success(nil)
        case let .success(subrole):
            guard subrole == (kAXDialogSubrole as String) else { return .success(nil) }
        }

        let descendants: [AXUIElement]
        switch descendantsResult(of: window, maxDepth: 12) {
        case .failure:
            return .failure(.unavailable)
        case let .success(elements):
            descendants = elements
        }

        var buttons: [(element: AXUIElement, label: String)] = []
        var popupHasPerTrackValue = false
        var popupCount = 0
        var titledPopupCount = 0
        for element in descendants {
            let role: String?
            switch AXHelpers.getAttributeResult(
                element, kAXRoleAttribute as String, runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .failure(error):
                guard Self.absentAttributeStatuses.contains(error.raw) else {
                    return .failure(.unavailable)
                }
                role = nil
            case let .success(value):
                role = value
            }
            if role == (kAXButtonRole as String) {
                switch elementTextResult(element) {
                case .failure:
                    return .failure(.unavailable)
                case let .success(label):
                    if let label { buttons.append((element, label)) }
                }
            } else if role == (kAXPopUpButtonRole as String) {
                popupCount += 1
                switch elementTextResult(element) {
                case .failure:
                    return .failure(.unavailable)
                case let .success(label):
                    popupHasPerTrackValue = popupHasPerTrackValue
                        || AXLocalePolicy.oneFilePerTrackPopupValue.matches(label)
                }
                switch AXHelpers.getAttributeResult(
                    element, kAXTitleAttribute as String, runtime: runtime.ax
                ) as Result<String?, AXHelpers.AXStatusError> {
                case let .failure(error):
                    // An untitled popup is exactly what the five decoys are; the
                    // absence IS the discriminator, not a failure to observe it.
                    guard Self.absentAttributeStatuses.contains(error.raw) else {
                        return .failure(.unavailable)
                    }
                case let .success(title):
                    if !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        titledPopupCount += 1
                    }
                }
            }
        }

        let commits = buttons.filter { AXLocalePolicy.stemExportCommitButton.matches($0.label) }
        let dismisses = buttons.filter { AXLocalePolicy.stemExportDismissButton.matches($0.label) }
        guard commits.count <= 1, dismisses.count <= 1 else {
            return .failure(.unavailable)
        }
        switch (commits.first, dismisses.first) {
        case let (.some(commit), .some(dismiss)):
            // The two button labels alone are a generic macOS dialog shape. A
            // measured per-track value is the stem-specific witness for a fully
            // recognised panel.
            guard popupHasPerTrackValue else { return .success(nil) }
            return .success(.recognized(window, commit.element, dismiss.element))
        case (.some, nil):
            // In a partially measured locale the per-track value itself can be
            // unmeasured. A popup still distinguishes this panel shape from the
            // bare two-button dialog that must never be cancelled.
            guard popupCount > 0 else { return .success(nil) }
            return .success(.partiallyMeasured(
                window,
                recognized: AXLocalePolicy.stemExportCommitButton.canonical,
                notMeasured: AXLocalePolicy.stemExportDismissButton.canonical,
                dismiss: nil
            ))
        case let (nil, .some(dismiss)):
            guard popupCount > 0 else { return .success(nil) }
            return .success(.partiallyMeasured(
                window,
                recognized: AXLocalePolicy.stemExportDismissButton.canonical,
                notMeasured: AXLocalePolicy.stemExportCommitButton.canonical,
                dismiss: dismiss.element
            ))
        case (nil, nil):
            // With no measured label there is no safe commit or cancel action.
            // The uniquely titled destination popup is the remaining measured
            // export-panel structure; report the modal as unmeasured so the
            // outcome honestly says it was left open.
            guard titledPopupCount == 1 else { return .success(nil) }
            return .success(.unmeasured(window))
        }
    }

    /// AX statuses that mean "this element does not expose that attribute", as
    /// distinct from "the attribute could not be read".
    ///
    /// The production runtime's status-preserving seam turns EVERY non-success
    /// status into an error, so a button that simply has no `AXValue` — which is
    /// most of them — arrives here looking exactly like a failed read. Measured on
    /// the live export panel: 348 elements walked, 0 genuine failures, 60 leaves
    /// answering kAXErrorNoValue for `AXChildren`, and the very first titled
    /// button answering it for `AXValue`. Treating those as failures made the
    /// panel permanently unassessable: every exit reported
    /// `stem_export_panel_close_not_observed` while the modal stayed open on
    /// screen.
    ///
    /// Narrowed here rather than in AXHelpers on purpose: other callers depend on
    /// the shared projection's current meaning, and widening a shared definition
    /// to clear one blocker is how the next one gets made.
    private static let absentAttributeStatuses: Set<Int32> = [
        AXError.noValue.rawValue,
        AXError.attributeUnsupported.rawValue,
    ]

    /// One read for the whole driver, so "the attribute is not there" can never be
    /// mistaken for "the attribute could not be read" at ANY site.
    ///
    /// Three separate sites were fixed one at a time before this existed — the
    /// children walk, the button text, then the browser entries — each one
    /// surfacing only after the previous fix let the live run get one stage
    /// further. The property, not the instance, is that the production runtime's
    /// status-preserving seam reports an absent attribute as an error.
    private func readAttribute<T>(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Result<T?, PanelReadFailure> {
        switch AXHelpers.getAttributeResult(
            element, attribute, runtime: runtime.ax
        ) as Result<T?, AXHelpers.AXStatusError> {
        case let .failure(error):
            guard Self.absentAttributeStatuses.contains(error.raw) else {
                return .failure(.unavailable)
            }
            return .success(nil)
        case let .success(value):
            return .success(value)
        }
    }

    private func descendantsResult(
        of root: AXUIElement,
        maxDepth: Int
    ) -> Result<[AXUIElement], PanelReadFailure> {
        guard maxDepth > 0 else { return .success([]) }
        switch AXHelpers.childrenResult(root, runtime: runtime.ax) {
        case let .failure(error):
            // "This element has no children" is an ANSWER, not a failed read.
            // A leaf — AXStaticText, AXImage — reports kAXErrorNoValue (-25212)
            // or kAXErrorAttributeUnsupported (-25205) for kAXChildren, and
            // AXHelpers.projectChildrenStatus turns every non-success status into
            // an error. Treating those two as read failures made the very first
            // leaf poison the whole subtree: measured on the live export panel,
            // 348 elements visited, 0 genuine failures, and 60 of these — so the
            // panel could never be assessed and every exit reported
            // `stem_export_panel_close_not_observed` while the modal stayed open.
            //
            // Narrowed here rather than in AXHelpers on purpose: other callers
            // depend on the shared projection's current meaning, and widening a
            // shared definition to clear one blocker is how the next one gets made.
            guard Self.absentAttributeStatuses.contains(error.raw) else {
                return .failure(.unavailable)
            }
            return .success([])
        case let .success(children):
            var descendants: [AXUIElement] = []
            for child in children {
                descendants.append(child)
                switch descendantsResult(of: child, maxDepth: maxDepth - 1) {
                case .failure:
                    return .failure(.unavailable)
                case let .success(nested):
                    descendants.append(contentsOf: nested)
                }
            }
            return .success(descendants)
        }
    }

    private func elementTextResult(
        _ element: AXUIElement
    ) -> Result<String?, PanelReadFailure> {
        for attribute in [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
        ] {
            switch AXHelpers.getAttributeResult(
                element, attribute, runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .failure(error):
                guard Self.absentAttributeStatuses.contains(error.raw) else {
                    return .failure(.unavailable)
                }
                continue
            case let .success(value):
                if let value { return .success(value) }
            }
        }
        return .success(nil)
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

        // The sidebar's display name only chooses a candidate. It is confirmed
        // only when the browser exposes entries whose parent is the requested
        // volume root path.
        // A zero AX status only says the write was accepted. It does not say
        // Finder's browser changed, so its Boolean return is intentionally not
        // used as a success signal.
        _ = AXHelpers.setAttribute(
            outline,
            kAXSelectedRowsAttribute as String,
            [row] as CFArray,
            runtime: runtime.ax
        )
        switch waitsForSidebarSelection(of: row, in: outline) {
        case .confirmed:
            break
        case .unavailable:
            return .refused(
                "readback_unavailable: stem_destination_volume_root_not_confirmed:\(volumeName):\(root)"
            )
        case .notConfirmed:
            return .refused("stem_destination_volume_root_not_confirmed:\(volumeName):\(root)")
        }
        switch waitsForDirectoryListing(of: root, in: panel) {
        case .confirmed:
            return .selected
        case .unavailable:
            return .refused(
                "readback_unavailable: stem_destination_volume_path_not_confirmed:\(volumeName):\(root)"
            )
        case .notConfirmed:
            return .refused("stem_destination_volume_path_not_confirmed:\(volumeName):\(root)")
        }
    }

    private func selectListedComponent(
        at path: String,
        named component: String,
        in panel: AXUIElement
    ) -> ProjectStemExportPanelDriver.DestinationSelection {
        let entries: [AXUIElement]
        switch browserPathFields(in: panel) {
        case .failure:
            return .refused("readback_unavailable: stem_destination_browser_entries_unreadable")
        case let .success(fields):
            entries = fields.filter { $0.path == path }.map(\.element)
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
        let listingExpectation = directoryListing(path)
        guard listingExpectation != .unavailable else {
            return .refused("readback_unavailable: stem_destination_component_directory_unreadable:\(component)")
        }
        switch waitsForSelection(
            of: path,
            in: list,
            panel: panel,
            requireObservedNavigation: listingExpectation == .hasEntries
        ) {
        case .confirmed:
            break
        case .unavailable:
            return .refused("readback_unavailable: stem_destination_component_not_confirmed:\(component)")
        case .notConfirmed:
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
    ///
    /// For a non-empty directory, both signals are required. A genuinely empty
    /// destination has no listable child entry to witness navigation; its
    /// selection readback remains the only confirmation. A panel that echoes a
    /// selection without navigating cannot be distinguished for an empty
    /// destination. Safety then rests downstream: if the export lands elsewhere,
    /// this destination contains no new audio and the executor refuses with
    /// `stem_audio_files_not_observed_after_progress_completion`, so this is an
    /// unintended write, never a false success.
    private enum NavigationConfirmation {
        case confirmed
        case notConfirmed
        case unavailable
    }

    private func waitsForSelection(
        of path: String,
        in list: AXUIElement?,
        panel: AXUIElement,
        requireObservedNavigation: Bool
    ) -> NavigationConfirmation {
        guard let list else { return .notConfirmed }
        let started = navigationNowNanos()
        var sawReadFailure = false
        while true {
            switch selectionReadsBack(path, in: list) {
            case .failure:
                sawReadFailure = true
            case let .success(selectionMatches):
                if selectionMatches {
                    guard requireObservedNavigation else { return .confirmed }
                    switch listsChildren(of: path, in: panel) {
                    case .failure:
                        sawReadFailure = true
                    case .success(true):
                        return .confirmed
                    case .success(false):
                        break
                    }
                }
            }
            let now = navigationNowNanos()
            let elapsed = now >= started ? now - started : UInt64.max
            guard elapsed < Self.destinationNavigationDeadlineNanos else {
                return sawReadFailure ? .unavailable : .notConfirmed
            }
            let remaining = Self.destinationNavigationDeadlineNanos - elapsed
            navigationSleep(min(Self.destinationNavigationPollIntervalNanos, remaining))
        }
    }

    /// The sidebar hop's equivalent: read the outline's selection back and check
    /// the row we wrote is the row it now reports. Measured 2026-09-02 —
    /// `AXSelectedRows` reads back one row labelled `Macintosh HD` after the write.
    private func waitsForSidebarSelection(
        of row: AXUIElement,
        in outline: AXUIElement
    ) -> NavigationConfirmation {
        let started = navigationNowNanos()
        var sawReadFailure = false
        while true {
            switch AXHelpers.getAXUIElementArrayRead(
                outline, kAXSelectedRowsAttribute as String, runtime: runtime.ax
            ) {
            case .failure, .success(.malformed):
                sawReadFailure = true
            case .success(.absent):
                break
            case let .success(.elements(selected)):
                if selected.contains(where: { CFEqual($0, row) }) {
                    return .confirmed
                }
            }
            let now = navigationNowNanos()
            let elapsed = now >= started ? now - started : UInt64.max
            guard elapsed < Self.destinationNavigationDeadlineNanos else {
                return sawReadFailure ? .unavailable : .notConfirmed
            }
            let remaining = Self.destinationNavigationDeadlineNanos - elapsed
            navigationSleep(min(Self.destinationNavigationPollIntervalNanos, remaining))
        }
    }

    private func waitsForDirectoryListing(
        of directory: String,
        in panel: AXUIElement
    ) -> NavigationConfirmation {
        let started = navigationNowNanos()
        var sawReadFailure = false
        while true {
            switch listsChildren(of: directory, in: panel) {
            case .failure:
                sawReadFailure = true
            case .success(true):
                return .confirmed
            case .success(false):
                break
            }
            let now = navigationNowNanos()
            let elapsed = now >= started ? now - started : UInt64.max
            guard elapsed < Self.destinationNavigationDeadlineNanos else {
                return sawReadFailure ? .unavailable : .notConfirmed
            }
            let remaining = Self.destinationNavigationDeadlineNanos - elapsed
            navigationSleep(min(Self.destinationNavigationPollIntervalNanos, remaining))
        }
    }

    /// Reads the list's selection back and compares AXURLs. A zero status from
    /// the write says only that the write was accepted.
    private func selectionReadsBack(
        _ path: String,
        in list: AXUIElement
    ) -> Result<Bool, PanelReadFailure> {
        let selected: [AXUIElement]
        switch AXHelpers.getAXUIElementArrayRead(
            list, kAXSelectedChildrenAttribute as String, runtime: runtime.ax
        ) {
        case .failure, .success(.malformed):
            return .failure(.unavailable)
        case .success(.absent):
            return .success(false)
        case let .success(.elements(elements)):
            selected = elements
        }
        for group in selected {
            switch browserPathFields(in: group, maxDepth: 4) {
            case .failure:
                return .failure(.unavailable)
            case let .success(fields):
                if fields.contains(where: { $0.path == path }) { return .success(true) }
            }
        }
        return .success(false)
    }

    private func listsChildren(
        of directory: String,
        in panel: AXUIElement
    ) -> Result<Bool, PanelReadFailure> {
        browserPathFields(in: panel).map { fields in
            fields.contains {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == directory
            }
        }
    }

    private func deepestListedAncestor(
        of path: String,
        in panel: AXUIElement
    ) -> Result<String?, PanelReadFailure> {
        browserPathFields(in: panel).map { fields in
            let directories = Set(fields.map {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path
            })
            return directories
                .filter { isDirectory($0, anAncestorOf: path) }
                .max { $0.count < $1.count }
        }
    }

    /// AXURL is a CFURL, never a CFString. Measured on the live export panel on
    /// 2026-09-02: of the entries carrying AXURL, 4 of 4 read as NSURL and 0 as
    /// String. Reading it as a String returned nil for every entry, which emptied
    /// the whole browser census silently — the destination stage then believed no
    /// ancestor was listed and refused on every machine. A String read here is not
    /// a stricter check; it is a guaranteed-empty one.
    private func browserPathFields(
        in root: AXUIElement,
        maxDepth: Int = 16
    ) -> Result<[(element: AXUIElement, path: String)], PanelReadFailure> {
        switch descendantsResult(of: root, maxDepth: maxDepth) {
        case .failure:
            return .failure(.unavailable)
        case let .success(descendants):
            var fields: [(element: AXUIElement, path: String)] = []
            for element in descendants {
                switch readAttribute(element, kAXRoleAttribute as String) as Result<String?, PanelReadFailure> {
        case .failure:
            return .failure(.unavailable)
                case let .success(role):
                    guard role == (kAXTextFieldRole as String) else { continue }
                }
                switch urlPath(of: element) {
                case .failure:
                    return .failure(.unavailable)
                case let .success(.some(path)):
                    fields.append((element, path))
                case .success(nil):
                    break
                }
            }
            return .success(fields)
        }
    }

    private func urlPath(
        of field: AXUIElement
    ) -> Result<String?, PanelReadFailure> {
        switch readAttribute(field, kAXURLAttribute as String) as Result<NSURL?, PanelReadFailure> {
        case .failure:
            return .failure(.unavailable)
        case let .success(url):
            return .success(url?.path.flatMap(normalizedFilePath))
        }
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
