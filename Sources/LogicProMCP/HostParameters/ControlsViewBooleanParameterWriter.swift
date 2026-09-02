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

    /// A classifier census is evidence for a view transition, not a search
    /// convenience. Keep its failed reads distinct from an empty census so an
    /// unreadable Editor signal or table cannot authorise a Controls write.
    enum ViewEvidenceReadFailure: Error, Sendable, Equatable {
        case switcherCensus(AXHelpers.AXStatusError)
        case switcherDescription(AXHelpers.AXStatusError)
        case sliderCensus(AXHelpers.AXStatusError)
        case sliderDescription(AXHelpers.AXStatusError)
        case menuItemCensus(AXHelpers.AXStatusError)
        case controlsTableCensus(AXHelpers.AXStatusError)
        case controlsTableRows(AXHelpers.AXStatusError)
        case controlsTableRow(AXHelpers.AXStatusError)

        var observation: String {
            switch self {
            case let .switcherCensus(error):
                return "the plugin-window View-switcher census failed (AXChildren/AXRole status \(error.diagnosticLabel))"
            case let .switcherDescription(error):
                return "the plugin-window View-switcher AXDescription read failed (status \(error.diagnosticLabel))"
            case let .sliderCensus(error):
                return "the native-editor AXSlider census failed (AXChildren/AXRole status \(error.diagnosticLabel))"
            case let .sliderDescription(error):
                return "a native-editor AXSlider AXDescription read failed (status \(error.diagnosticLabel))"
            case let .menuItemCensus(error):
                return "the scoped View-menu item census failed (AXChildren/AXRole/AXTitle/AXDescription status \(error.diagnosticLabel))"
            case let .controlsTableCensus(error):
                return "the Controls-table census failed (AXChildren/AXRole status \(error.diagnosticLabel))"
            case let .controlsTableRows(error):
                return "the candidate Controls table AXRows read failed (status \(error.diagnosticLabel))"
            case let .controlsTableRow(error):
                return "a candidate Controls-table row read failed (status \(error.diagnosticLabel))"
            }
        }
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
        case viewStructureDidNotConfirm(PluginWindowView)

        var observation: String {
            switch self {
            case .viewSwitcherNotFound:
                return "no plugin-window AXMenuButton was available to resolve the Controls view switcher"
            case .viewSwitcherAmbiguous:
                return "more than one AXMenuButton matched the measured View AXDescription"
            case .unmeasuredLocale:
                return "the plugin-window View AXDescription is not measured for this locale; no view name was guessed"
            case .entryViewNotConfirmed:
                return "the bound plugin window exposed neither a described native-editor AXSlider nor a Controls-view label-and-sibling-control row with no described AXSlider; its entry view was not confirmed"
            case let .viewEvidenceReadFailed(error):
                return "view classification refused because \(error.observation); this is distinct from a missing switcher, menu item, slider, or table"
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
            case let .viewStructureDidNotConfirm(expected):
                return "after selecting the measured \(expected.labels.canonical) item, the bound plugin window did not expose the expected \(expected.rawValue) structure before the confirmation deadline"
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
    }

    /// Owns one confirmed temporary view selection. Its caller restores this
    /// exact entry view on every exit path, including a locator refusal.
    final class ViewSession: @unchecked Sendable {
        private let window: AXUIElement
        private let switcher: AXUIElement
        private let entryView: PluginWindowView
        private let didSwitch: Bool
        private let menuAppearanceTimeout: TimeInterval
        private let runtime: AXHelpers.Runtime
        private var restorationFinished = false

        fileprivate init(
            window: AXUIElement,
            switcher: AXUIElement,
            entryView: PluginWindowView,
            didSwitch: Bool,
            menuAppearanceTimeout: TimeInterval,
            runtime: AXHelpers.Runtime
        ) {
            self.window = window
            self.switcher = switcher
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
                return ViewRestoration(attempted: false, confirmed: true, observedStructure: nil)
            }
            restorationFinished = true
            guard didSwitch else {
                return ViewRestoration(
                    attempted: false,
                    confirmed: true,
                    observedStructure: entryView.rawValue
                )
            }
            switch switchView(
                to: entryView,
                in: window,
                switcher: switcher,
                menuAppearanceTimeout: menuAppearanceTimeout,
                confirmationTimeout: viewConfirmationTimeout,
                runtime: runtime
            ) {
            case let .confirmed(switched):
                return ViewRestoration(
                    attempted: switched,
                    confirmed: true,
                    observedStructure: entryView.rawValue
                )
            case .refused:
                let observed: PluginWindowView?
                switch observedView(in: window, runtime: runtime) {
                case let .success(view):
                    observed = view
                case .failure:
                    observed = nil
                }
                return ViewRestoration(
                    attempted: true,
                    confirmed: observed == entryView,
                    observedStructure: observed?.rawValue
                )
            }
        }
    }

    private enum ViewChangeResult {
        case confirmed(switched: Bool)
        case refused(ViewSwitchFailure, targetSelectionAttempted: Bool)
    }

    private typealias ObservedViewResult = Result<PluginWindowView?, ViewEvidenceReadFailure>

    private enum ViewWaitResult {
        case confirmed
        case deadlineExpired
        case readFailed(ViewEvidenceReadFailure)
    }

    struct ToggleResult: Sendable, Equatable {
        let verified: Bool
        let pressAttempted: Bool
        let before: Bool?
        let observedAfterPress: Bool?
        let restoreAttempted: Bool
        let restoreObserved: Bool?
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
        runtime: AXHelpers.Runtime = .production
    ) -> ViewPreparationResult {
        let menuButtons: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXMenuButtonRole, maxDepth: 5, runtime: runtime
        ) {
        case let .success(census):
            menuButtons = census.matches
        case let .failure(error):
            return .refused(.viewEvidenceReadFailed(.switcherCensus(error)), restoration: nil)
        }
        var measured: [AXUIElement] = []
        for menuButton in menuButtons {
            let description: String?
            switch descriptionResult(of: menuButton, runtime: runtime) {
            case let .success(observed):
                description = observed
            case let .failure(error):
                return .refused(.viewEvidenceReadFailed(.switcherDescription(error)), restoration: nil)
            }
            if AXLocalePolicy.pluginWindowViewSwitcher.matches(description, mode: .exact) {
                measured.append(menuButton)
            }
        }
        guard measured.count == 1, let switcher = measured.first else {
            if measured.count > 1 {
                return .refused(.viewSwitcherAmbiguous, restoration: nil)
            }
            return .refused(menuButtons.isEmpty ? .viewSwitcherNotFound : .unmeasuredLocale, restoration: nil)
        }

        let entryView: PluginWindowView
        switch observedView(in: window, runtime: runtime) {
        case let .success(.some(observed)):
            entryView = observed
        case .success(nil):
            return .refused(.entryViewNotConfirmed, restoration: nil)
        case let .failure(error):
            return .refused(.viewEvidenceReadFailed(error), restoration: nil)
        }

        switch switchView(
            to: targetView,
            in: window,
            switcher: switcher,
            menuAppearanceTimeout: menuAppearanceTimeout,
            confirmationTimeout: confirmationTimeout,
            runtime: runtime
        ) {
        case let .confirmed(switched):
            return .ready(ViewSession(
                window: window,
                switcher: switcher,
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
                    switcher: switcher,
                    menuAppearanceTimeout: menuAppearanceTimeout,
                    confirmationTimeout: confirmationTimeout,
                    forceSelection: true,
                    runtime: runtime
                ) {
                case let .confirmed(switched):
                    restoration = ViewRestoration(
                        attempted: switched,
                        confirmed: true,
                        observedStructure: entryView.rawValue
                    )
                case .refused:
                    let observed: PluginWindowView?
                    switch observedView(in: window, runtime: runtime) {
                    case let .success(view):
                        observed = view
                    case .failure:
                        observed = nil
                    }
                    restoration = ViewRestoration(
                        attempted: true,
                        confirmed: observed == entryView,
                        observedStructure: observed?.rawValue
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
    /// table shape. Controls is then recognized by at least one row with one
    /// cell, one nonempty AXStaticText label, and a control in that label's
    /// sibling subtree. Every census and description read is status-preserving:
    /// an unreadable Editor signal refuses instead of disappearing and turning
    /// an arbitrary one-cell table into Controls evidence.
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
    ) -> ObservedViewResult {
        let sliderDescriptions: [String]
        switch nativeEditorSliderEvidence(in: window, runtime: runtime) {
        case let .success(observed):
            sliderDescriptions = observed
        case let .failure(error):
            return .failure(error)
        }
        if sliderDescriptions.contains(where: { !$0.isEmpty }) {
            return .success(.editor)
        }
        switch controlsViewStateIsBound(in: window, runtime: runtime) {
        case .success(true):
            return .success(.controls)
        case .success(false):
            return .success(sliderDescriptions.isEmpty ? nil : .editor)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Returns every native-editor slider description, preserving the exact
    /// census/description failure that would otherwise erase Editor evidence.
    /// A present-but-empty description is deliberately retained: bare sliders
    /// still distinguish an unconfirmed window from a Controls table, while
    /// only nonempty descriptions establish the native Editor view.
    private static func nativeEditorSliderEvidence(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[String], ViewEvidenceReadFailure> {
        let sliders: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXSliderRole, maxDepth: 8, runtime: runtime
        ) {
        case let .success(census):
            sliders = census.matches
        case let .failure(error):
            return .failure(.sliderCensus(error))
        }
        var descriptions: [String] = []
        for slider in sliders {
            let description: String?
            switch descriptionResult(of: slider, runtime: runtime) {
            case let .success(observed):
                description = observed
            case let .failure(error):
                return .failure(.sliderDescription(error))
            }
            descriptions.append(description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return .success(descriptions)
    }

    private static func switchView(
        to targetView: PluginWindowView,
        in window: AXUIElement,
        switcher: AXUIElement,
        menuAppearanceTimeout: TimeInterval,
        confirmationTimeout: TimeInterval,
        forceSelection: Bool = false,
        runtime: AXHelpers.Runtime
    ) -> ViewChangeResult {
        if !forceSelection {
            switch observedView(in: window, runtime: runtime) {
            case let .success(observed) where observed == targetView:
                return .confirmed(switched: false)
            case .success:
                break
            case let .failure(error):
                return .refused(.viewEvidenceReadFailed(error), targetSelectionAttempted: false)
            }
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
        _ = AXHelpers.performAction(target, kAXPickAction as String, runtime: runtime)
        switch waitForView(
            targetView,
            in: window,
            timeout: confirmationTimeout,
            runtime: runtime
        ) {
        case .confirmed:
            break
        case .deadlineExpired:
            return .refused(.viewStructureDidNotConfirm(targetView), targetSelectionAttempted: true)
        case let .readFailed(error):
            return .refused(.viewEvidenceReadFailed(error), targetSelectionAttempted: true)
        }
        return .confirmed(switched: true)
    }

    private static let viewMenuAppearanceTimeout: TimeInterval = 2.0
    private static let viewMenuAppearancePollInterval: TimeInterval = 0.05
    private static let viewConfirmationTimeout: TimeInterval = 1.5
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
        timeout: TimeInterval,
        runtime: AXHelpers.Runtime
    ) -> ViewWaitResult {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            switch observedView(in: window, runtime: runtime) {
            case let .success(observed) where observed == expected:
                return .confirmed
            case .success:
                break
            case let .failure(error):
                return .readFailed(error)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(viewConfirmationPollInterval, remaining))
        } while Date() < deadline
        return .deadlineExpired
    }

    private static func controlsViewStateIsBound(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<Bool, ViewEvidenceReadFailure> {
        let tables: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        ) {
        case let .success(census):
            tables = census.matches
        case let .failure(error):
            return .failure(.controlsTableCensus(error))
        }
        guard tables.count == 1, let table = tables.first else { return .success(false) }
        let rows: [AXUIElement]
        switch controlsRows(in: table, runtime: runtime) {
        case let .success(observed):
            rows = observed
        case let .failure(error):
            return .failure(.controlsTableRows(error))
        }
        // Heading and section rows have no interactive control in the live
        // table. A Controls view is bound by the presence of at least one
        // measured label/control pair, not by requiring every row to be one.
        for row in rows {
            switch rowCarriesParameterPair(row, runtime: runtime) {
            case .success(true):
                return .success(true)
            case .success(false):
                continue
            case let .failure(error):
                return .failure(.controlsTableRow(error))
            }
        }
        return .success(false)
    }

    /// Resolve a row-label address without positional fallbacks. A candidate
    /// means any interactive AX role that could share the row, so a checkbox
    /// cannot win merely because it happened to be first beside an unqualified
    /// control.
    ///
    /// An AXTable is not structurally self-identifying as the parameter table.
    /// This method accepts one only when the caller has already bound this
    /// window to the requested plug-in by header identity, this window has one
    /// table, no described native-editor slider, and one row whose catalogued
    /// requested label has one sibling control. AX exposes no stronger table
    /// identity fact; any failed part of that evidence refuses rather than
    /// weakening it to a missing match.
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
        switch nativeEditorSliderEvidence(in: window, runtime: runtime) {
        case let .success(descriptions) where descriptions.allSatisfy(\.isEmpty):
            break
        case .success:
            return .refused(.controlsViewTableNotFound)
        case .failure:
            return .refused(.accessibilityReadFailed)
        }
        let rows: [AXUIElement]
        switch controlsRows(in: table, runtime: runtime) {
        case let .success(observed):
            rows = observed
        case .failure:
            return .refused(.accessibilityReadFailed)
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
    /// verification causes one compensating press, followed by a readback that
    /// reports whether restoration to the before state was actually observed.
    static func pressAndVerify(
        _ checkbox: AXUIElement,
        requested: Bool,
        runtime: AXHelpers.Runtime = .production
    ) -> ToggleResult {
        guard let before = AXValueExtractors.extractButtonState(checkbox, runtime: runtime) else {
            return ToggleResult(
                verified: false,
                pressAttempted: false,
                before: nil,
                observedAfterPress: nil,
                restoreAttempted: false,
                restoreObserved: nil,
                refusal: "the Controls-view AXCheckBox AXValue could not be read before AXPress"
            )
        }
        guard before != requested else {
            return ToggleResult(
                verified: false,
                pressAttempted: false,
                before: before,
                observedAfterPress: before,
                restoreAttempted: false,
                restoreObserved: before,
                refusal: "the Controls-view AXCheckBox already has the requested state; AXPress would change it away, so no write was attempted"
            )
        }

        _ = AXHelpers.performAction(checkbox, kAXPressAction as String, runtime: runtime)
        let after = AXValueExtractors.extractButtonState(checkbox, runtime: runtime)
        if after == requested, after != before {
            return ToggleResult(
                verified: true,
                pressAttempted: true,
                before: before,
                observedAfterPress: after,
                restoreAttempted: false,
                restoreObserved: nil,
                refusal: nil
            )
        }

        // The first press may have landed even though its state did not verify.
        // One inverse press is the only available compensation; it is not a
        // retry of the requested write, and its result is observed separately.
        _ = AXHelpers.performAction(checkbox, kAXPressAction as String, runtime: runtime)
        let restored = AXValueExtractors.extractButtonState(checkbox, runtime: runtime)
        return ToggleResult(
            verified: false,
            pressAttempted: true,
            before: before,
            observedAfterPress: after,
            restoreAttempted: true,
            restoreObserved: restored.map { $0 == before },
            refusal: after == nil
                ? "the Controls-view AXCheckBox value could not be read after AXPress; restoration was attempted once"
                : "the Controls-view AXCheckBox did not change to the requested state after AXPress; AX status is not confirmation, and restoration was attempted once"
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
            return .success([])
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
