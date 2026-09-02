import ApplicationServices
import Foundation

/// The measured, deliberately small write surface for Logic's host-provided
/// Controls view. A parameter name belongs to its AXRow, not to the control:
/// this locator binds the row's AXStaticText label to exactly one control in
/// that row and never inherits AX traversal position.
///
/// Only AXCheckBox actuation is qualified. AXSlider's advertised settable
/// value/increment actions were measured on 2026-09-02 to be inert;
/// AXPopUpButton selection has not been measured. Both roles are returned as
/// explicit refusals and are never actuated here.
enum ControlsViewBooleanParameterWriter {
    enum LocatorFailure: String, Sendable, Equatable {
        case controlsViewTableNotFound
        case controlsViewTableAmbiguous
        case rowLabelMissing
        case rowLabelAmbiguous
        case rowLabelNotFound
        case rowStructureInvalid
        case controlMissing
        case controlAmbiguous
        case accessibilityReadFailed
        case accessibilityReadMalformed
        case checkboxNotFound
        case sliderNotActuable
        case popupUnmeasured
        case unsupportedControlRole

        var observation: String {
            switch self {
            case .controlsViewTableNotFound:
                return "no unique AXTable was available after selecting Controls view"
            case .controlsViewTableAmbiguous:
                return "more than one AXTable was available after selecting Controls view"
            case .rowLabelMissing:
                return "the Controls-view AXRow exposes no AXStaticText label inside an AXCell"
            case .rowLabelAmbiguous:
                return "the Controls-view AXRow exposes more than one AXStaticText label inside its cells"
            case .rowLabelNotFound:
                return "no Controls-view AXRow label matched the requested parameter"
            case .rowStructureInvalid:
                return "the labelled Controls-view AXRow did not expose one AXCell with its label and control as siblings"
            case .controlMissing:
                return "the labelled Controls-view AXRow exposes no candidate control"
            case .controlAmbiguous:
                return "the labelled Controls-view AXRow exposes several candidate controls; no control was chosen by position"
            case .accessibilityReadFailed:
                return "an AX role, child list, or label-value read failed while binding the Controls-view AXRow; no partially classified control was used"
            case .accessibilityReadMalformed:
                return "the Controls-view AXRows attribute returned a malformed payload; an undecodable row list is not evidence that the table is empty"
            case .checkboxNotFound:
                return "the labelled Controls-view AXRow did not resolve to an AXCheckBox"
            case .sliderNotActuable:
                return "Controls-view AXSlider actuation is refused: on 2026-09-02 direct AXValue set and AXIncrement both reported success but the measured slider did not change"
            case .popupUnmeasured:
                return "Controls-view AXPopUpButton actuation is refused: selection has not been measured, so no menu action is guessed"
            case .unsupportedControlRole:
                return "the labelled Controls-view row resolved to an unsupported control role"
            }
        }
    }

    enum PluginWindowView: String, Sendable, Equatable {
        case controls
        case editor

        fileprivate var labels: AXLocalePolicy.LabelSet {
            switch self {
            case .controls:
                AXLocalePolicy.pluginWindowControlsViewMenuItem
            case .editor:
                AXLocalePolicy.pluginWindowEditorViewMenuItem
            }
        }
    }

    /// These reads select the AX element that will receive an action. A failed
    /// read therefore refuses instead of silently dropping a candidate and
    /// risking an action on a different element.
    enum ViewEvidenceReadFailure: Error, Sendable, Equatable {
        case switcherCensus(AXHelpers.AXStatusError)
        case switcherDescription(AXHelpers.AXStatusError)
        case menuItemCensus(AXHelpers.AXStatusError)
        case menuItemEnabled(AXHelpers.AXStatusError)
        case sliderCensus(AXHelpers.AXStatusError)
        case sliderDescription(AXHelpers.AXStatusError)

        var observation: String {
            switch self {
            case let .switcherCensus(error):
                return "the plugin-window View-switcher census failed (AXChildren/AXRole status \(error.diagnosticLabel))"
            case let .switcherDescription(error):
                return "the plugin-window View-switcher AXDescription read failed (status \(error.diagnosticLabel))"
            case let .menuItemCensus(error):
                return "the scoped View-menu item census failed (AXChildren/AXRole/AXTitle/AXDescription status \(error.diagnosticLabel))"
            case let .menuItemEnabled(error):
                return "the scoped View-menu item's AXEnabled read failed (status \(error.diagnosticLabel))"
            case let .sliderCensus(error):
                return "the plugin-window AXSlider census failed (AXChildren/AXRole status \(error.diagnosticLabel))"
            case let .sliderDescription(error):
                return "a plugin-window AXSlider AXDescription read failed (status \(error.diagnosticLabel))"
            }
        }
    }

    struct ViewStructureObservation: Sendable, Equatable {
        /// Counts are taken by a fresh classifier census at the structure
        /// deadline. `nil` means that exact count could not be read then; it is
        /// not a zero inferred from an unreadable AX subtree.
        let tableCount: Int?
        let rowCount: Int?
        let describedSliderCount: Int?
        let waitedMilliseconds: Int
    }

    enum ViewSwitchFailure: Sendable, Equatable {
        case viewSwitcherNotFound
        case viewSwitcherAmbiguous
        case unmeasuredLocale
        case entryViewNotConfirmed
        case viewEvidenceReadFailed(ViewEvidenceReadFailure)
        case viewMenuDidNotAppearBeforeDeadline
        case viewMenuReadFailed(AXHelpers.AXStatusError)
        case viewMenuAmbiguous
        case viewMenuItemNotFound(PluginWindowView)
        case viewMenuItemAmbiguous(PluginWindowView)
        case viewMenuItemDisabled(PluginWindowView)
        case viewStructureDidNotConfirm(PluginWindowView, ViewStructureObservation)

        var observation: String {
            switch self {
            case .viewSwitcherNotFound:
                return "no plugin-window AXMenuButton was available to resolve the Controls view switcher"
            case .viewSwitcherAmbiguous:
                return "more than one AXMenuButton matched the measured View AXDescription"
            case .unmeasuredLocale:
                return "the plugin-window View AXDescription is not measured for this locale; no view name was guessed"
            case .entryViewNotConfirmed:
                return "the bound plugin window exposed neither a described native-editor AXSlider, an absent AXTable, nor one Controls-view AXTable with a label-and-sibling-control row; its entry view was not confirmed"
            case let .viewEvidenceReadFailed(error):
                return "view selection refused because \(error.observation); this is distinct from a missing switcher or menu item"
            case .viewMenuDidNotAppearBeforeDeadline:
                return "the measured View switcher exposed no scoped AXMenu before the menu-appearance deadline after AXPress"
            case let .viewMenuReadFailed(error):
                return "the measured View switcher's scoped AXMenu read failed after AXPress (AXChildren/AXRole status \(error.diagnosticLabel)); this is distinct from a menu-appearance deadline"
            case .viewMenuAmbiguous:
                return "the measured View switcher exposed several scoped AXMenus"
            case let .viewMenuItemNotFound(view):
                return "the scoped View menu exposed no measured \(view.labels.canonical) item"
            case let .viewMenuItemAmbiguous(view):
                return "the scoped View menu exposed several measured \(view.labels.canonical) items"
            case let .viewMenuItemDisabled(view):
                return "the scoped View menu's measured \(view.labels.canonical) item did not expose AXEnabled == true, so AXPick was refused"
            case let .viewStructureDidNotConfirm(expected, _):
                return "after selecting the measured \(expected.labels.canonical) item, the bound plugin window did not expose the expected \(expected.rawValue) structure before the confirmation deadline"
            }
        }

        /// Structured observations for a `plugin_view_not_confirmed` envelope.
        /// Keep the phase separate from the prose observation so an intermittent
        /// refusal can be grouped without parsing a user-facing sentence.
        var responseDiagnostics: [String: Any] {
            switch self {
            case .viewMenuDidNotAppearBeforeDeadline:
                return ["plugin_view_switch_phase": "menu_never_appeared"]
            case .viewMenuAmbiguous:
                return ["plugin_view_switch_phase": "menu_ambiguous"]
            case .viewMenuItemNotFound:
                return ["plugin_view_switch_phase": "item_not_found"]
            case .viewMenuItemAmbiguous:
                return ["plugin_view_switch_phase": "item_ambiguous"]
            case .viewMenuItemDisabled:
                return ["plugin_view_switch_phase": "item_not_enabled"]
            case let .viewStructureDidNotConfirm(_, observed):
                return [
                    "plugin_view_switch_phase": "pick_performed_structure_never_confirmed",
                    "plugin_view_structure_table_count": observed.tableCount ?? NSNull(),
                    "plugin_view_structure_row_count": observed.rowCount ?? NSNull(),
                    "plugin_view_structure_described_slider_count": observed.describedSliderCount ?? NSNull(),
                    "plugin_view_structure_waited_ms": observed.waitedMilliseconds,
                ]
            case .viewSwitcherNotFound:
                return ["plugin_view_switch_phase": "switcher_not_found"]
            case .viewSwitcherAmbiguous:
                return ["plugin_view_switch_phase": "switcher_ambiguous"]
            case .unmeasuredLocale:
                return ["plugin_view_switch_phase": "switcher_locale_unmeasured"]
            case .entryViewNotConfirmed:
                return ["plugin_view_switch_phase": "entry_view_not_confirmed"]
            case .viewEvidenceReadFailed:
                return ["plugin_view_switch_phase": "view_evidence_read_failed"]
            case .viewMenuReadFailed:
                return ["plugin_view_switch_phase": "menu_read_failed"]
            }
        }
    }

    enum LocatedControl {
        case checkBox(AXUIElement)
        case slider
        case popup
        case unsupported

        var failure: LocatorFailure? {
            switch self {
            case .checkBox:
                return nil
            case .slider:
                return .sliderNotActuable
            case .popup:
                return .popupUnmeasured
            case .unsupported:
                return .unsupportedControlRole
            }
        }
    }

    enum LocateResult {
        case found(LocatedControl)
        case refused(LocatorFailure)
    }

    enum ViewPreparationResult {
        case ready(ViewSession)
        case refused(ViewSwitchFailure, restoration: ViewRestoration?)
    }

    struct ViewRestoration: Sendable, Equatable {
        let attempted: Bool
        let confirmed: Bool
        let observedStructure: String?
        let entryView: PluginWindowView

        /// Only an observed structure different from the recorded entry view
        /// proves that the operation left the plug-in view changed. A failed
        /// restoration confirmation with no readable current view is unobserved,
        /// not evidence of a changed view.
        var leftViewChanged: Bool {
            observedStructure.map { $0 != entryView.rawValue } ?? false
        }
    }

    /// Owns one confirmed temporary view selection. Its caller restores this
    /// exact entry view on every exit path, including a locator refusal.
    final class ViewSession: @unchecked Sendable {
        private let window: AXUIElement
        private let windowRefresher: () -> AXUIElement?
        private let entryView: PluginWindowView
        private let didSwitch: Bool
        private let menuAppearanceTimeout: TimeInterval
        private let runtime: AXHelpers.Runtime
        private var restorationFinished = false

        fileprivate init(
            window: AXUIElement,
            windowRefresher: @escaping () -> AXUIElement?,
            entryView: PluginWindowView,
            didSwitch: Bool,
            menuAppearanceTimeout: TimeInterval,
            runtime: AXHelpers.Runtime
        ) {
            self.window = window
            self.windowRefresher = windowRefresher
            self.entryView = entryView
            self.didSwitch = didSwitch
            self.menuAppearanceTimeout = menuAppearanceTimeout
            self.runtime = runtime
        }

        /// Restoration is idempotent. Its observed outcome is serialized by the
        /// caller before it returns either a successful write or a State C; the
        /// already-observed parameter-write verdict is never recast as though it
        /// had not run.
        func restore() -> ViewRestoration {
            guard !restorationFinished else {
                return ViewRestoration(
                    attempted: false,
                    confirmed: true,
                    observedStructure: nil,
                    entryView: entryView
                )
            }
            restorationFinished = true
            guard didSwitch else {
                return ViewRestoration(
                    attempted: false,
                    confirmed: true,
                    observedStructure: entryView.rawValue,
                    entryView: entryView
                )
            }
            switch switchView(
                to: entryView,
                in: window,
                windowRefresher: windowRefresher,
                menuAppearanceTimeout: menuAppearanceTimeout,
                confirmationTimeout: viewConfirmationTimeout,
                runtime: runtime
            ) {
            case let .confirmed(switched):
                return ViewRestoration(
                    attempted: switched,
                    confirmed: true,
                    observedStructure: entryView.rawValue,
                    entryView: entryView
                )
            case .refused:
                let observed: PluginWindowView?
                let currentWindow = refreshedWindow(window, windowRefresher: windowRefresher)
                if case let .success(.some(value)) = observedView(in: currentWindow, runtime: runtime) {
                    observed = value
                } else {
                    observed = nil
                }
                return ViewRestoration(
                    attempted: true,
                    confirmed: observed == entryView,
                    observedStructure: observed?.rawValue,
                    entryView: entryView
                )
            }
        }
    }

    private enum ViewChangeResult {
        case confirmed(switched: Bool)
        case refused(ViewSwitchFailure, targetSelectionAttempted: Bool)
    }

    private enum ViewWaitResult {
        case confirmed
        case deadlineExpired(ViewStructureObservation)
        case readFailed(ViewEvidenceReadFailure)
    }

    struct ToggleResult: Sendable, Equatable {
        let verified: Bool
        let pressAttempted: Bool
        let before: Bool?
        let observedAfterPress: Bool?
        let restoreAttempted: Bool
        let restoreObserved: Bool?
        let restoreObservedValue: Bool?
        let refusal: String?
    }

    /// Identify the entry view from the bound window's measured structure, then
    /// enter the requested view only when necessary. AXPress status and AXTitle
    /// are not confirmation: the requested structure must appear before the
    /// bounded confirmation deadline.
    static func prepareView(
        _ targetView: PluginWindowView,
        in window: AXUIElement,
        menuAppearanceTimeout: TimeInterval = viewMenuAppearanceTimeout,
        confirmationTimeout: TimeInterval = viewConfirmationTimeout,
        windowRefresher: (() -> AXUIElement?)? = nil,
        runtime: AXHelpers.Runtime = .production
    ) -> ViewPreparationResult {
        let effectiveWindowRefresher = windowRefresher ?? { window }
        let entryView: PluginWindowView
        let entryObservation = observedView(
            in: refreshedWindow(window, windowRefresher: effectiveWindowRefresher),
            runtime: runtime
        )
        switch entryObservation {
        case let .success(.some(observed)):
            entryView = observed
        case .success(.none):
            return .refused(.entryViewNotConfirmed, restoration: nil)
        case let .failure(error):
            return .refused(.viewEvidenceReadFailed(error), restoration: nil)
        }

        // A view already confirmed by its own positive evidence needs no
        // switcher read: no switcher will be acted on and there is no view to
        // restore. No further classifier read is needed once the requested
        // view was positively observed.
        guard entryView != targetView else {
            return .ready(ViewSession(
                window: window,
                windowRefresher: effectiveWindowRefresher,
                entryView: entryView,
                didSwitch: false,
                menuAppearanceTimeout: menuAppearanceTimeout,
                runtime: runtime
            ))
        }

        switch switchView(
            to: targetView,
            in: window,
            windowRefresher: effectiveWindowRefresher,
            menuAppearanceTimeout: menuAppearanceTimeout,
            confirmationTimeout: confirmationTimeout,
            runtime: runtime
        ) {
        case let .confirmed(switched):
            return .ready(ViewSession(
                window: window,
                windowRefresher: effectiveWindowRefresher,
                entryView: entryView,
                didSwitch: switched,
                menuAppearanceTimeout: menuAppearanceTimeout,
                runtime: runtime
            ))
        case let .refused(failure, targetSelectionAttempted):
            // A pressed menu item can have changed the view even when the
            // target structure did not settle before its deadline. Re-select
            // the entry view best-effort before refusing, so failed selection
            // paths do not strand it.
            let restoration: ViewRestoration?
            if targetSelectionAttempted {
                switch switchView(
                    to: entryView,
                    in: window,
                    windowRefresher: effectiveWindowRefresher,
                    menuAppearanceTimeout: menuAppearanceTimeout,
                    confirmationTimeout: confirmationTimeout,
                    forceSelection: true,
                    runtime: runtime
                ) {
                case let .confirmed(switched):
                    restoration = ViewRestoration(
                        attempted: switched,
                        confirmed: true,
                        observedStructure: entryView.rawValue,
                        entryView: entryView
                    )
                case .refused:
                    let observed: PluginWindowView?
                    let currentWindow = refreshedWindow(window, windowRefresher: effectiveWindowRefresher)
                    if case let .success(.some(value)) = observedView(in: currentWindow, runtime: runtime) {
                        observed = value
                    } else {
                        observed = nil
                    }
                    restoration = ViewRestoration(
                        attempted: true,
                        confirmed: observed == entryView,
                        observedStructure: observed?.rawValue,
                        entryView: entryView
                    )
                }
            } else {
                restoration = nil
            }
            return .refused(failure, restoration: restoration)
        }
    }

    /// The native editor is signaled by a parameter-bearing slider. A described
    /// slider anywhere in the window is Editor evidence and wins over every
    /// table shape. Controls is confirmed only by one AXTable containing at
    /// least one row with one cell, one nonempty AXStaticText label, and a
    /// control in that label's sibling subtree. With no AXTable, Editor is
    /// confirmed by that observed absence.
    ///
    /// A successful nonempty AXDescription is positive Editor evidence. Once
    /// observed, it wins immediately over all later reads. Conversely, when no
    /// described slider was observed, a slider census or description failure
    /// leaves the view unknown: an unreadable editor candidate must not be
    /// erased so an unrelated table can become Controls evidence.
    ///
    /// Measured 2026-09-02, Compressor editor window "Absolute Zero": one
    /// AXTable at depth 2 had AXRows status 0 and 29 rows; every row had exactly
    /// one AXCell. `row[12]` was AXRow → AXCell → AXStaticText "Limiter On:"
    /// and AXCheckBox value "0" as siblings. `row[0]` was AXRow → AXCell →
    /// AXStaticText "Threshold:", an AXGroup-wrapped AXSlider, and a bare
    /// AXSlider with AXValueIndicator. No measured row used sibling AXCells for
    /// label/control. The two slider-shaped candidates are intentionally still
    /// ambiguous; this locator never chooses one by traversal position.
    private static func observedView(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<PluginWindowView?, ViewEvidenceReadFailure> {
        switch describedNativeEditorSliderEvidence(in: window, runtime: runtime) {
        case .described:
            return .success(.editor)
        case let .readFailed(error):
            return .failure(error)
        case .notDescribed:
            break
        }
        switch controlsViewStateIsBound(in: window, runtime: runtime) {
        case .controls:
            return .success(.controls)
        case .noTable:
            return .success(.editor)
        case .unconfirmed:
            return .success(nil)
        }
    }

    private enum SliderEvidence {
        case described
        case notDescribed
        case readFailed(ViewEvidenceReadFailure)
    }

    /// Scan until a described slider establishes Editor. Keep reading after an
    /// earlier failure so a later positive observation wins; if none is found,
    /// preserve the first failed read instead of treating it as negative evidence.
    private static func describedNativeEditorSliderEvidence(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> SliderEvidence {
        let sliders: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXSliderRole, maxDepth: 8, runtime: runtime
        ) {
        case let .success(census):
            sliders = census.matches
        case let .failure(error):
            return .readFailed(.sliderCensus(error))
        }
        var firstFailure: ViewEvidenceReadFailure?
        for slider in sliders {
            switch descriptionResult(of: slider, runtime: runtime) {
            case let .success(description):
                if !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    return .described
                }
            case let .failure(error):
                if firstFailure == nil {
                    firstFailure = .sliderDescription(error)
                }
            }
        }
        return firstFailure.map(SliderEvidence.readFailed) ?? .notDescribed
    }

    /// A view pick can re-render the editor subtree. Never carry the old
    /// AXMenuButton over that boundary: bind a current, uniquely described
    /// switcher immediately before every AXPress, including restoration.
    private enum MeasuredViewSwitcherResult {
        case found(AXUIElement)
        case refused(ViewSwitchFailure)
    }

    private static func measuredViewSwitcher(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MeasuredViewSwitcherResult {
        let menuButtons: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXMenuButtonRole, maxDepth: 5, runtime: runtime
        ) {
        case let .success(census):
            menuButtons = census.matches
        case let .failure(error):
            return .refused(.viewEvidenceReadFailed(.switcherCensus(error)))
        }
        var measured: [AXUIElement] = []
        var firstSwitcherDescriptionReadFailure: AXHelpers.AXStatusError?
        for menuButton in menuButtons {
            let description: String?
            switch descriptionResult(of: menuButton, runtime: runtime) {
            case let .success(observed):
                description = observed
            case let .failure(error):
                firstSwitcherDescriptionReadFailure = firstSwitcherDescriptionReadFailure ?? error
                continue
            }
            if AXLocalePolicy.pluginWindowViewSwitcher.matches(description, mode: .exact) {
                measured.append(menuButton)
            }
        }
        guard measured.count == 1, let switcher = measured.first else {
            if measured.count > 1 {
                return .refused(.viewSwitcherAmbiguous)
            }
            if let firstSwitcherDescriptionReadFailure {
                return .refused(.viewEvidenceReadFailed(.switcherDescription(firstSwitcherDescriptionReadFailure)))
            }
            return .refused(menuButtons.isEmpty ? .viewSwitcherNotFound : .unmeasuredLocale)
        }
        return .found(switcher)
    }

    private static func refreshedWindow(
        _ fallback: AXUIElement,
        windowRefresher: @escaping () -> AXUIElement?
    ) -> AXUIElement {
        windowRefresher() ?? fallback
    }

    private static func switchView(
        to targetView: PluginWindowView,
        in window: AXUIElement,
        windowRefresher: @escaping () -> AXUIElement?,
        menuAppearanceTimeout: TimeInterval,
        confirmationTimeout: TimeInterval,
        forceSelection: Bool = false,
        runtime: AXHelpers.Runtime
    ) -> ViewChangeResult {
        let currentWindow = refreshedWindow(window, windowRefresher: windowRefresher)
        if !forceSelection {
            // Preserve the fail-closed preflight: if no uniquely described
            // switcher can be read, refuse before treating a concurrent view
            // observation as a reason to skip selection. Do not retain this
            // element, though; the action below measures it again after the
            // view check in case Logic re-rendered in between.
            switch measuredViewSwitcher(in: currentWindow, runtime: runtime) {
            case .found:
                break
            case let .refused(error):
                return .refused(error, targetSelectionAttempted: false)
            }
            switch observedView(in: currentWindow, runtime: runtime) {
            case let .success(.some(observed)) where observed == targetView:
                return .confirmed(switched: false)
            case let .failure(error):
                return .refused(.viewEvidenceReadFailed(error), targetSelectionAttempted: false)
            case .success:
                break
            }
        }

        let switcher: AXUIElement
        let actionWindow = refreshedWindow(window, windowRefresher: windowRefresher)
        switch measuredViewSwitcher(in: actionWindow, runtime: runtime) {
        case let .found(observed):
            switcher = observed
        case let .refused(error):
            return .refused(error, targetSelectionAttempted: false)
        }

        // AX's action status is intentionally not the verdict. Live Logic
        // reveals this app-wide menu after AXPress, and its entry accepts only
        // AXPick; no retry ladder can turn another protocol into evidence.
        _ = AXHelpers.performAction(switcher, kAXPressAction as String, runtime: runtime)
        let menus: [AXUIElement]
        switch waitForScopedViewMenu(
            under: switcher,
            timeout: menuAppearanceTimeout,
            runtime: runtime
        ) {
        case let .found(observed):
            menus = observed
        case .deadlineExpired:
            return .refused(.viewMenuDidNotAppearBeforeDeadline, targetSelectionAttempted: false)
        case let .readFailed(error):
            return .refused(.viewMenuReadFailed(error), targetSelectionAttempted: false)
        }
        guard menus.count == 1, let menu = menus.first else {
            return .refused(.viewMenuAmbiguous, targetSelectionAttempted: false)
        }
        let entries: [AXUIElement]
        switch AXLocalePolicy.censusDescendantResult(
            of: menu,
            role: kAXMenuItemRole,
            matching: targetView.labels,
            maxDepth: 3,
            runtime: runtime
        ) {
        case let .success(census):
            entries = census.matches
        case let .failure(error):
            return .refused(.viewEvidenceReadFailed(.menuItemCensus(error)), targetSelectionAttempted: false)
        }
        guard entries.count == 1, let target = entries.first else {
            return .refused(entries.isEmpty
                ? .viewMenuItemNotFound(targetView)
                : .viewMenuItemAmbiguous(targetView),
                targetSelectionAttempted: false
            )
        }
        switch AXHelpers.getAttributeResult(
            target,
            kAXEnabledAttribute as String,
            runtime: runtime
        ) as Result<Bool?, AXHelpers.AXStatusError> {
        case .success(.some(true)):
            break
        case .success:
            return .refused(.viewMenuItemDisabled(targetView), targetSelectionAttempted: false)
        case let .failure(error):
            return .refused(.viewEvidenceReadFailed(.menuItemEnabled(error)), targetSelectionAttempted: false)
        }
        _ = AXHelpers.performAction(target, kAXPickAction as String, runtime: runtime)
        switch waitForView(
            targetView,
            in: window,
            windowRefresher: windowRefresher,
            timeout: confirmationTimeout,
            runtime: runtime
        ) {
        case .confirmed:
            break
        case let .deadlineExpired(observed):
            return .refused(
                .viewStructureDidNotConfirm(targetView, observed),
                targetSelectionAttempted: true
            )
        case let .readFailed(error):
            return .refused(.viewEvidenceReadFailed(error), targetSelectionAttempted: true)
        }
        return .confirmed(switched: true)
    }

    /// Measured on the live Compressor on 2026-09-03 with a 25 ms poll:
    /// AXPress → scoped View menu was 28–46 ms across ten switches (and 32–46
    /// ms across five first switches immediately after opening the editor).
    private static let viewMenuAppearanceTimeout: TimeInterval = 2.0
    private static let viewMenuAppearancePollInterval: TimeInterval = 0.05
    /// Measured on the live Compressor on 2026-09-03 with a 25 ms poll:
    /// AXPick → structural confirmation was 527–785 ms across ten switches;
    /// five first switches immediately after opening the editor were 529–711
    /// ms. Three seconds is about a 4× margin over the 785 ms maximum, not an
    /// unmeasured timing increase.
    private static let viewConfirmationTimeout: TimeInterval = 3.0
    private static let viewConfirmationPollInterval: TimeInterval = 0.05

    private enum ScopedViewMenuWaitResult {
        case found([AXUIElement])
        case deadlineExpired
        case readFailed(AXHelpers.AXStatusError)
    }

    /// The view menu is created below the switcher asynchronously. Preserve an
    /// unreadable AX subtree as a refusal instead of treating it as an empty
    /// menu and incorrectly claiming its appearance timed out.
    private static func waitForScopedViewMenu(
        under switcher: AXUIElement,
        timeout: TimeInterval,
        runtime: AXHelpers.Runtime
    ) -> ScopedViewMenuWaitResult {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            switch scopedViewMenus(under: switcher, runtime: runtime) {
            case let .success(menus) where !menus.isEmpty:
                return .found(menus)
            case .success:
                break
            case let .failure(error):
                return .readFailed(error)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(viewMenuAppearancePollInterval, remaining))
        } while Date() < deadline
        return .deadlineExpired
    }

    private static func scopedViewMenus(
        under switcher: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        var menus: [AXUIElement] = []
        if let error = collectScopedViewMenus(
            below: switcher,
            remainingDepth: 4,
            runtime: runtime,
            into: &menus
        ) {
            return .failure(error)
        }
        return .success(menus)
    }

    private static func collectScopedViewMenus(
        below element: AXUIElement,
        remainingDepth: Int,
        runtime: AXHelpers.Runtime,
        into menus: inout [AXUIElement]
    ) -> AXHelpers.AXStatusError? {
        guard remainingDepth > 0 else { return nil }
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case let .success(observed):
            children = observed
        case let .failure(error) where error.isDefinitiveAbsence:
            return nil
        case let .failure(error):
            return error
        }
        for child in children {
            let role: String?
            switch AXHelpers.getAttributeResult(
                child,
                kAXRoleAttribute as String,
                runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                role = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                role = nil
            case let .failure(error):
                return error
            }
            if role == (kAXMenuRole as String) {
                menus.append(child)
            }
            if let error = collectScopedViewMenus(
                below: child,
                remainingDepth: remainingDepth - 1,
                runtime: runtime,
                into: &menus
            ) {
                return error
            }
        }
        return nil
    }

    private static func waitForView(
        _ expected: PluginWindowView,
        in window: AXUIElement,
        windowRefresher: @escaping () -> AXUIElement?,
        timeout: TimeInterval,
        runtime: AXHelpers.Runtime
    ) -> ViewWaitResult {
        let started = Date()
        let deadline = started.addingTimeInterval(max(0, timeout))
        repeat {
            let currentWindow = refreshedWindow(window, windowRefresher: windowRefresher)
            switch observedView(in: currentWindow, runtime: runtime) {
            case let .success(.some(observed)) where observed == expected:
                return .confirmed
            case let .failure(error):
                return .readFailed(error)
            case .success:
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(viewConfirmationPollInterval, remaining))
        } while Date() < deadline
        // Read a fresh structural snapshot *after* the deadline, rather than
        // reporting the previous poll as though it were an end-of-wait fact.
        let deadlineWindow = refreshedWindow(window, windowRefresher: windowRefresher)
        return .deadlineExpired(viewStructureObservation(
            in: deadlineWindow,
            waitedMilliseconds: Int((Date().timeIntervalSince(started) * 1_000).rounded()),
            runtime: runtime
        ))
    }

    private static func viewStructureObservation(
        in window: AXUIElement,
        waitedMilliseconds: Int,
        runtime: AXHelpers.Runtime
    ) -> ViewStructureObservation {
        let sliders: [AXUIElement]?
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXSliderRole, maxDepth: 8, runtime: runtime
        ) {
        case let .success(census):
            sliders = census.matches
        case .failure:
            sliders = nil
        }
        let describedSliderCount: Int?
        if let sliders {
            var count = 0
            var descriptionWasUnreadable = false
            for slider in sliders {
                switch descriptionResult(of: slider, runtime: runtime) {
                case let .success(description):
                    if !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        count += 1
                    }
                case .failure:
                    descriptionWasUnreadable = true
                }
            }
            describedSliderCount = descriptionWasUnreadable ? nil : count
        } else {
            describedSliderCount = nil
        }

        let tables: [AXUIElement]?
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        ) {
        case let .success(census):
            tables = census.matches
        case .failure:
            tables = nil
        }
        let rowCount: Int?
        if let tables {
            var count = 0
            var rowsWereUnreadable = false
            for table in tables {
                switch controlsRows(in: table, runtime: runtime) {
                case let .success(rows):
                    count += rows.count
                case .failure:
                    rowsWereUnreadable = true
                }
            }
            rowCount = rowsWereUnreadable ? nil : count
        } else {
            rowCount = nil
        }
        return ViewStructureObservation(
            tableCount: tables?.count,
            rowCount: rowCount,
            describedSliderCount: describedSliderCount,
            waitedMilliseconds: waitedMilliseconds
        )
    }

    private enum ControlsTableEvidence {
        case controls
        case noTable
        case unconfirmed
    }

    private static func controlsViewStateIsBound(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> ControlsTableEvidence {
        let tables: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        ) {
        case let .success(census):
            tables = census.matches
        case .failure:
            return .unconfirmed
        }
        if tables.isEmpty { return .noTable }
        guard tables.count == 1, let table = tables.first else { return .unconfirmed }
        let rows: [AXUIElement]
        switch controlsRows(in: table, runtime: runtime) {
        case let .success(observed):
            rows = observed
        case .failure:
            return .unconfirmed
        }
        // Heading and section rows have no interactive control in the live
        // table. A Controls view is bound by the presence of at least one
        // measured label/control pair, not by requiring every row to be one.
        // A failed row read is not negative evidence and cannot erase a pair
        // observed in another row; without a pair, the table remains
        // unconfirmed rather than becoming Editor evidence.
        for row in rows {
            switch rowCarriesParameterPair(row, runtime: runtime) {
            case .success(true):
                return .controls
            case .success(false), .failure:
                continue
            }
        }
        return .unconfirmed
    }

    /// Resolve a row-label address without positional fallbacks. A candidate
    /// means any interactive AX role that could share the row, so a checkbox
    /// cannot win merely because it happened to be first beside an unqualified
    /// control.
    ///
    /// An AXTable is not structurally self-identifying as the parameter table.
    /// The guarantee here is deliberately limited: the caller has already
    /// bound the window by plug-in header identity, this window has exactly one
    /// AXTable, and the selected AXRow label equals the catalogued parameter's
    /// `controlsViewRowLabel`. AX exposes no stronger table identity fact. In
    /// particular, this does not claim that an unrelated one-table plug-in
    /// window can be distinguished by table structure alone.
    static func locate(
        label requestedLabel: String,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> LocateResult {
        let tables: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window,
            role: kAXTableRole,
            maxDepth: 8,
            runtime: runtime
        ) {
        case let .success(census):
            tables = census.matches
        case .failure:
            return .refused(.accessibilityReadFailed)
        }
        guard tables.count == 1, let table = tables.first else {
            return .refused(tables.isEmpty ? .controlsViewTableNotFound : .controlsViewTableAmbiguous)
        }
        let rows: [AXUIElement]
        switch controlsRows(in: table, runtime: runtime) {
        case let .success(observed):
            rows = observed
        case let .failure(error):
            return .refused(error == .malformedAttribute
                ? .accessibilityReadMalformed
                : .accessibilityReadFailed)
        }
        guard !rows.isEmpty else {
            return .refused(.controlsViewTableNotFound)
        }

        let target = normalizedLabel(requestedLabel)
        var matchingRows: [[AXUIElement]] = []
        var sawMissingLabel = false
        var sawAmbiguousLabel = false
        for row in rows {
            let rowRole: String?
            switch roleResult(of: row, runtime: runtime) {
            case let .success(observed):
                rowRole = observed
            case .failure:
                return .refused(.accessibilityReadFailed)
            }
            guard rowRole == (kAXRowRole as String) else { continue }
            let cells: [AXUIElement]
            switch rowCells(in: row, runtime: runtime) {
            case let .success(observed):
                cells = observed
            case .failure:
                return .refused(.accessibilityReadFailed)
            }
            guard !cells.isEmpty else {
                sawMissingLabel = true
                continue
            }
            let labels: [RowLabel]
            switch rowLabels(in: cells, runtime: runtime) {
            case let .success(observed):
                labels = observed
            case .failure:
                return .refused(.accessibilityReadFailed)
            }
            guard labels.count == 1, let label = labels.first else {
                sawMissingLabel = sawMissingLabel || labels.isEmpty
                sawAmbiguousLabel = sawAmbiguousLabel || labels.count > 1
                continue
            }
            if normalizedLabel(label.value) == target {
                guard cells.count == 1 else {
                    return .refused(.rowStructureInvalid)
                }
                let controls: [AXUIElement]
                switch candidateControls(
                    beside: label.element,
                    in: label.cell,
                    runtime: runtime
                ) {
                case let .success(observed):
                    controls = observed
                case .failure:
                    return .refused(.accessibilityReadFailed)
                }
                matchingRows.append(controls)
            }
        }

        guard matchingRows.count == 1, let controls = matchingRows.first else {
            if matchingRows.count > 1 {
                return .refused(.rowLabelAmbiguous)
            }
            if sawAmbiguousLabel { return .refused(.rowLabelAmbiguous) }
            if sawMissingLabel { return .refused(.rowLabelMissing) }
            return .refused(.rowLabelNotFound)
        }
        guard controls.count == 1, let control = controls.first else {
            return .refused(controls.isEmpty ? .controlMissing : .controlAmbiguous)
        }
        let role: String?
        switch roleResult(of: control, runtime: runtime) {
        case let .success(observed):
            role = observed
        case .failure:
            return .refused(.accessibilityReadFailed)
        }
        if role == (kAXCheckBoxRole as String) {
            return .found(.checkBox(control))
        }
        if role == (kAXSliderRole as String) {
            return .found(.slider)
        }
        if role == (kAXPopUpButtonRole as String) {
            return .found(.popup)
        }
        return .found(.unsupported)
    }

    /// A press status of zero is not success evidence. The checkbox must read
    /// back as *changed* and equal to the requested state. Any failed
    /// verification compensates only when the observed first read differs from
    /// the readable pre-press state; a no-op needs no second actuation.
    static func pressAndVerify(
        _ checkbox: AXUIElement,
        requested: Bool,
        runtime: AXHelpers.Runtime = .production
    ) -> ToggleResult {
        let before: Bool
        switch AXValueExtractors.extractButtonStateResult(checkbox, runtime: runtime) {
        case let .success(.some(observed)):
            before = observed
        case .success(.none):
            return ToggleResult(
                verified: false,
                pressAttempted: false,
                before: nil,
                observedAfterPress: nil,
                restoreAttempted: false,
                restoreObserved: nil,
                restoreObservedValue: nil,
                refusal: "the Controls-view AXCheckBox AXValue could not be read before AXPress"
            )
        case let .failure(error):
            return ToggleResult(
                verified: false,
                pressAttempted: false,
                before: nil,
                observedAfterPress: nil,
                restoreAttempted: false,
                restoreObserved: nil,
                restoreObservedValue: nil,
                refusal: "the Controls-view AXCheckBox AXValue read failed before AXPress (status \(error.diagnosticLabel))"
            )
        }
        guard before != requested else {
            return ToggleResult(
                verified: true,
                pressAttempted: false,
                before: before,
                observedAfterPress: before,
                restoreAttempted: false,
                restoreObserved: before,
                restoreObservedValue: before,
                refusal: nil
            )
        }

        _ = AXHelpers.performAction(checkbox, kAXPressAction as String, runtime: runtime)
        let after: Bool?
        let afterReadFailure: AXHelpers.AXStatusError?
        switch AXValueExtractors.extractButtonStateResult(checkbox, runtime: runtime) {
        case let .success(observed):
            after = observed
            afterReadFailure = nil
        case let .failure(error):
            after = nil
            afterReadFailure = error
        }
        if after == requested, after != before {
            return ToggleResult(
                verified: true,
                pressAttempted: true,
                before: before,
                observedAfterPress: after,
                restoreAttempted: false,
                restoreObserved: nil,
                restoreObservedValue: nil,
                refusal: nil
            )
        }

        // A readable pre-press state proves this first press was a no-op. Do
        // not send an unnecessary second press: it could be the first one that
        // lands and would change a request that must return failure.
        if after == before {
            return ToggleResult(
                verified: false,
                pressAttempted: true,
                before: before,
                observedAfterPress: after,
                restoreAttempted: false,
                restoreObserved: true,
                restoreObservedValue: before,
                refusal: "the Controls-view AXCheckBox did not change to the requested state after AXPress; the observed state already equals the pre-press state, so no compensating press was sent"
            )
        }

        // The first press may have landed even though its state did not verify.
        // One inverse press is the only available compensation; it is not a
        // retry of the requested write, and its result is observed separately.
        _ = AXHelpers.performAction(checkbox, kAXPressAction as String, runtime: runtime)
        let restored: Bool?
        let restorationReadFailure: AXHelpers.AXStatusError?
        switch AXValueExtractors.extractButtonStateResult(checkbox, runtime: runtime) {
        case let .success(observed):
            restored = observed
            restorationReadFailure = nil
        case let .failure(error):
            restored = nil
            restorationReadFailure = error
        }
        let refusal: String
        if let afterReadFailure {
            refusal = "the Controls-view AXCheckBox AXValue read failed after AXPress (status \(afterReadFailure.diagnosticLabel)); restoration was attempted once"
        } else if let restorationReadFailure {
            refusal = "the Controls-view AXCheckBox restoration AXValue read failed (status \(restorationReadFailure.diagnosticLabel)) after one compensating AXPress"
        } else {
            refusal = "the Controls-view AXCheckBox did not change to the requested state after AXPress; AX status is not confirmation, and restoration was attempted once"
        }
        return ToggleResult(
            verified: false,
            pressAttempted: true,
            before: before,
            observedAfterPress: after,
            restoreAttempted: true,
            restoreObserved: restored.map { $0 == before },
            restoreObservedValue: restored,
            refusal: refusal
        )
    }

    /// `AXRows` has two absence answers: a successful empty attribute and the
    /// `noValue`/`attributeUnsupported` AX statuses. Only those answers may use
    /// AXChildren as the alternate table representation; every other status is
    /// a read failure and therefore cannot establish a Controls table.
    private static func controlsRows(
        in table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        switch AXHelpers.getAXUIElementArrayRead(
            table,
            kAXRowsAttribute as String,
            runtime: runtime
        ) {
        case let .success(.elements(rows)):
            return .success(rows)
        case .success(.absent):
            return directChildrenWithRoles(of: table, runtime: runtime).map { children in
                children.compactMap { element, role in
                    role == (kAXRowRole as String) ? element : nil
                }
            }
        case .failure(let error) where error.isDefinitiveAbsence:
            return directChildrenWithRoles(of: table, runtime: runtime).map { children in
                children.compactMap { element, role in
                    role == (kAXRowRole as String) ? element : nil
                }
            }
        case .success(.malformed):
            return .failure(.malformedAttribute)
        case let .failure(error):
            return .failure(error)
        }
    }

    private struct RowLabel {
        let cell: AXUIElement
        let element: AXUIElement
        let value: String
    }

    private typealias ElementRole = (element: AXUIElement, role: String?)

    private static func rowCells(
        in row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        directChildrenWithRoles(of: row, runtime: runtime).map { children in
            children.compactMap { element, role in
                role == (kAXCellRole as String) ? element : nil
            }
        }
    }

    private static func rowLabels(
        in cells: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> Result<[RowLabel], AXHelpers.AXStatusError> {
        var labels: [RowLabel] = []
        for cell in cells {
            let children: [ElementRole]
            switch directChildrenWithRoles(of: cell, runtime: runtime) {
            case let .success(observed):
                children = observed
            case let .failure(error):
                return .failure(error)
            }
            for (element, role) in children where role == (kAXStaticTextRole as String) {
                let value: String?
                switch textValueResult(of: element, runtime: runtime) {
                case let .success(observed):
                    value = observed
                case let .failure(error):
                    return .failure(error)
                }
                let normalized = normalizedLabel(value ?? "")
                if !normalized.isEmpty {
                    labels.append(RowLabel(cell: cell, element: element, value: normalized))
                }
            }
        }
        return .success(labels)
    }

    private static func candidateControls(
        beside label: AXUIElement,
        in cell: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        let siblings: [ElementRole]
        switch directChildrenWithRoles(of: cell, runtime: runtime) {
        case let .success(observed):
            siblings = observed
        case let .failure(error):
            return .failure(error)
        }
        var controls: [AXUIElement] = []
        for sibling in siblings where !CFEqual(sibling.element, label) {
            switch collectCandidateControls(
                from: sibling.element,
                knownRole: sibling.role,
                remainingDepth: 5,
                runtime: runtime,
                into: &controls
            ) {
            case .success:
                continue
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(controls)
    }

    private static func rowCarriesParameterPair(
        _ row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<Bool, AXHelpers.AXStatusError> {
        let role: String?
        switch roleResult(of: row, runtime: runtime) {
        case let .success(observed):
            role = observed
        case let .failure(error):
            return .failure(error)
        }
        guard role == (kAXRowRole as String) else { return .success(false) }
        let cells: [AXUIElement]
        switch rowCells(in: row, runtime: runtime) {
        case let .success(observed):
            cells = observed
        case let .failure(error):
            return .failure(error)
        }
        guard cells.count == 1 else { return .success(false) }
        let labels: [RowLabel]
        switch rowLabels(in: cells, runtime: runtime) {
        case let .success(observed):
            labels = observed
        case let .failure(error):
            return .failure(error)
        }
        guard labels.count == 1, let label = labels.first else { return .success(false) }
        // The classifier intentionally requires only a label/control relation,
        // while `locate` requires exactly one candidate before it can bind a
        // write. Thus the measured Threshold row helps prove Controls even
        // though its two slider-shaped candidates still refuse actuation.
        return candidateControls(beside: label.element, in: label.cell, runtime: runtime)
            .map { !$0.isEmpty }
    }

    private static func roleResult(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element,
            kAXRoleAttribute as String,
            runtime: runtime
        )
        switch read {
        case let .success(role):
            return .success(role)
        case let .failure(error) where error.isDefinitiveAbsence:
            return .success(nil)
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func textValueResult(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let read: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element,
            kAXValueAttribute as String,
            runtime: runtime
        )
        switch read {
        case let .success(value):
            return .success(value as? String)
        case let .failure(error) where error.isDefinitiveAbsence:
            return .success(nil)
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func descriptionResult(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let read: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            element,
            kAXDescriptionAttribute as String,
            runtime: runtime
        )
        switch read {
        case let .success(value):
            return .success(value)
        case let .failure(error) where error.isDefinitiveAbsence:
            return .success(nil)
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func directChildrenWithRoles(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[ElementRole], AXHelpers.AXStatusError> {
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case let .success(observed):
            children = observed
        case let .failure(error) where error.isDefinitiveAbsence:
            children = []
        case let .failure(error):
            return .failure(error)
        }
        var observed: [ElementRole] = []
        for child in children {
            switch roleResult(of: child, runtime: runtime) {
            case let .success(role):
                observed.append((child, role))
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(observed)
    }

    private static func descendantElements(
        of element: AXUIElement,
        maxDepth: Int,
        runtime: AXHelpers.Runtime
    ) -> Result<[ElementRole], AXHelpers.AXStatusError> {
        var found: [ElementRole] = []
        switch collectDescendantElements(
            below: element,
            remainingDepth: maxDepth,
            runtime: runtime,
            into: &found
        ) {
        case .success:
            return .success(found)
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func collectDescendantElements(
        below element: AXUIElement,
        remainingDepth: Int,
        runtime: AXHelpers.Runtime,
        into found: inout [ElementRole]
    ) -> Result<Void, AXHelpers.AXStatusError> {
        guard remainingDepth > 0 else { return .success(()) }
        let children: [ElementRole]
        switch directChildrenWithRoles(of: element, runtime: runtime) {
        case let .success(observed):
            children = observed
        case let .failure(error):
            return .failure(error)
        }
        for child in children {
            found.append(child)
            switch collectDescendantElements(
                below: child.element,
                remainingDepth: remainingDepth - 1,
                runtime: runtime,
                into: &found
            ) {
            case .success:
                continue
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(())
    }

    private static func collectCandidateControls(
        from element: AXUIElement,
        knownRole: String?,
        remainingDepth: Int,
        runtime: AXHelpers.Runtime,
        into controls: inout [AXUIElement]
    ) -> Result<Void, AXHelpers.AXStatusError> {
        guard remainingDepth > 0 else { return .success(()) }
        if interactiveControlRoles.contains(knownRole ?? "") {
            controls.append(element)
        }
        let children: [ElementRole]
        switch directChildrenWithRoles(of: element, runtime: runtime) {
        case let .success(observed):
            children = observed
        case let .failure(error):
            return .failure(error)
        }
        for child in children {
            switch collectCandidateControls(
                from: child.element,
                knownRole: child.role,
                remainingDepth: remainingDepth - 1,
                runtime: runtime,
                into: &controls
            ) {
            case .success:
                continue
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(())
    }

    /// The first four roles are the Controls-view roles observed on 2026-09-02.
    /// The remaining standard interactive roles keep the cardinality rule
    /// fail-closed if a future UI exposes another control next to the checkbox.
    private static let interactiveControlRoles: Set<String> = [
        kAXCheckBoxRole as String,
        kAXSliderRole as String,
        kAXPopUpButtonRole as String,
        kAXRadioButtonRole as String,
        kAXButtonRole as String,
        kAXMenuButtonRole as String,
        kAXTextFieldRole as String,
        "AXComboBox",
        "AXIncrementor",
        "AXValueIndicator",
        "AXScrollBar",
    ]

    private static func normalizedLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutColon = trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : trimmed
        return withoutColon.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
