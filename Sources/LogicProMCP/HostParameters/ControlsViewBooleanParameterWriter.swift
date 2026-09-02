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
        case controlMissing
        case controlAmbiguous
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
            case .controlMissing:
                return "the labelled Controls-view AXRow exposes no candidate control"
            case .controlAmbiguous:
                return "the labelled Controls-view AXRow exposes several candidate controls; no control was chosen by position"
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

    enum ViewSwitchFailure: Sendable, Equatable {
        case viewSwitcherNotFound
        case viewSwitcherAmbiguous
        case unmeasuredLocale
        case entryViewNotConfirmed
        case viewMenuNotFound
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
                return "the bound plugin window exposed neither a described native-editor AXSlider nor Controls-view rows with no described AXSlider; its entry view was not confirmed"
            case .viewMenuNotFound:
                return "the measured View switcher exposed no scoped AXMenu after AXShowMenu"
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
        case refused(ViewSwitchFailure)
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
        private let runtime: AXHelpers.Runtime
        private var restorationFinished = false

        fileprivate init(
            window: AXUIElement,
            switcher: AXUIElement,
            entryView: PluginWindowView,
            didSwitch: Bool,
            runtime: AXHelpers.Runtime
        ) {
            self.window = window
            self.switcher = switcher
            self.entryView = entryView
            self.didSwitch = didSwitch
            self.runtime = runtime
        }

        /// Restoration is idempotent. A failed restore is logged and exposed
        /// in successful write metadata by the caller; the already-observed
        /// parameter-write verdict is never recast as though it had not run.
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
                return ViewRestoration(
                    attempted: true,
                    confirmed: false,
                    observedStructure: observedView(in: window, runtime: runtime)?.rawValue
                )
            }
        }
    }

    private enum ViewChangeResult {
        case confirmed(switched: Bool)
        case refused(ViewSwitchFailure)
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
        confirmationTimeout: TimeInterval = viewConfirmationTimeout,
        runtime: AXHelpers.Runtime = .production
    ) -> ViewPreparationResult {
        let menuButtons = AXHelpers.censusDescendant(
            of: window, role: kAXMenuButtonRole, maxDepth: 5, runtime: runtime
        ).matches
        let measured = menuButtons.filter {
            AXLocalePolicy.pluginWindowViewSwitcher.matches(
                AXHelpers.getDescription($0, runtime: runtime),
                mode: .exact
            )
        }
        guard measured.count == 1, let switcher = measured.first else {
            if measured.count > 1 {
                return .refused(.viewSwitcherAmbiguous)
            }
            return .refused(menuButtons.isEmpty ? .viewSwitcherNotFound : .unmeasuredLocale)
        }

        guard let entryView = observedView(in: window, runtime: runtime) else {
            return .refused(.entryViewNotConfirmed)
        }

        switch switchView(
            to: targetView,
            in: window,
            switcher: switcher,
            confirmationTimeout: confirmationTimeout,
            runtime: runtime
        ) {
        case let .confirmed(switched):
            return .ready(ViewSession(
                window: window,
                switcher: switcher,
                entryView: entryView,
                didSwitch: switched,
                runtime: runtime
            ))
        case let .refused(failure):
            // A pressed menu item can have changed the view even when the
            // target structure did not settle before its deadline. Re-select
            // the entry view best-effort before refusing, so failed selection
            // paths do not strand it.
            _ = switchView(
                to: entryView,
                in: window,
                switcher: switcher,
                confirmationTimeout: confirmationTimeout,
                runtime: runtime
            )
            return .refused(failure)
        }
    }

    /// The native editor is signaled by a parameter-bearing slider. Controls
    /// is signaled only by its table rows *and* the absence of every slider
    /// description, so a stale title or a shared zoom/view menu cannot alter
    /// this result.
    private static func observedView(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> PluginWindowView? {
        let sliders = AXHelpers.censusDescendant(
            of: window, role: kAXSliderRole, maxDepth: 8, runtime: runtime
        ).matches
        if sliders.contains(where: { slider in
            guard let description = AXHelpers.getDescription(slider, runtime: runtime) else {
                return false
            }
            return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return .editor
        }
        return controlsViewRowsArePresent(in: window, runtime: runtime) ? .controls : nil
    }

    private static func switchView(
        to targetView: PluginWindowView,
        in window: AXUIElement,
        switcher: AXUIElement,
        confirmationTimeout: TimeInterval,
        runtime: AXHelpers.Runtime
    ) -> ViewChangeResult {
        guard observedView(in: window, runtime: runtime) != targetView else {
            return .confirmed(switched: false)
        }

        // AX's action status is intentionally not the verdict. The scoped menu
        // tree is observed after this one request; no retry ladder can turn an
        // unmeasured locale or a missing menu into evidence.
        _ = AXHelpers.performAction(switcher, kAXShowMenuAction as String, runtime: runtime)
        let menus = AXHelpers.censusDescendant(
            of: switcher, role: kAXMenuRole, maxDepth: 4, runtime: runtime
        ).matches
        guard menus.count == 1, let menu = menus.first else {
            return .refused(menus.isEmpty ? .viewMenuNotFound : .viewMenuAmbiguous)
        }
        let entries = AXLocalePolicy.censusDescendant(
            of: menu,
            role: kAXMenuItemRole,
            matching: targetView.labels,
            maxDepth: 3,
            runtime: runtime
        ).matches
        guard entries.count == 1, let target = entries.first else {
            return .refused(entries.isEmpty
                ? .viewMenuItemNotFound(targetView)
                : .viewMenuItemAmbiguous(targetView)
            )
        }
        _ = AXHelpers.performAction(target, kAXPressAction as String, runtime: runtime)
        guard waitForView(
            targetView,
            in: window,
            timeout: confirmationTimeout,
            runtime: runtime
        ) else {
            return .refused(.viewStructureDidNotConfirm(targetView))
        }
        return .confirmed(switched: true)
    }

    private static let viewConfirmationTimeout: TimeInterval = 1.5
    private static let viewConfirmationPollInterval: TimeInterval = 0.05

    private static func waitForView(
        _ expected: PluginWindowView,
        in window: AXUIElement,
        timeout: TimeInterval,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if observedView(in: window, runtime: runtime) == expected {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(viewConfirmationPollInterval, remaining))
        } while Date() < deadline
        return false
    }

    private static func controlsViewRowsArePresent(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let tables = AXHelpers.censusDescendant(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        ).matches
        guard tables.count == 1, let table = tables.first else { return false }
        let rows: [AXUIElement]
        switch AXHelpers.getAXUIElementArrayRead(
            table,
            kAXRowsAttribute as String,
            runtime: runtime
        ) {
        case let .success(.elements(observed)):
            rows = observed
        case .success(.absent):
            rows = AXHelpers.getChildren(table, runtime: runtime).filter {
                AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String)
            }
        case .success(.malformed), .failure:
            return false
        }
        return rows.contains { AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String) }
    }

    /// Resolve a row-label address without positional fallbacks. A candidate
    /// means any interactive AX role that could share the row, so a checkbox
    /// cannot win merely because it happened to be first beside an unqualified
    /// control.
    static func locate(
        label requestedLabel: String,
        in window: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> LocateResult {
        let tables = AXHelpers.censusDescendant(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        ).matches
        guard tables.count == 1, let table = tables.first else {
            return .refused(tables.isEmpty ? .controlsViewTableNotFound : .controlsViewTableAmbiguous)
        }
        let rows: [AXUIElement]
        switch AXHelpers.getAXUIElementArrayRead(
            table,
            kAXRowsAttribute as String,
            runtime: runtime
        ) {
        case let .success(.elements(observed)):
            rows = observed
        case .success(.absent):
            rows = AXHelpers.getChildren(table, runtime: runtime).filter {
                AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String)
            }
        case .success(.malformed), .failure:
            return .refused(.controlsViewTableNotFound)
        }

        let target = normalizedLabel(requestedLabel)
        var matchingRows: [[AXUIElement]] = []
        var sawMissingLabel = false
        var sawAmbiguousLabel = false
        for row in rows where AXHelpers.getRole(row, runtime: runtime) == (kAXRowRole as String) {
            let labels = rowLabels(in: row, runtime: runtime)
            guard labels.count == 1, let label = labels.first else {
                sawMissingLabel = sawMissingLabel || labels.isEmpty
                sawAmbiguousLabel = sawAmbiguousLabel || labels.count > 1
                continue
            }
            if normalizedLabel(label) == target {
                matchingRows.append(candidateControls(in: row, runtime: runtime))
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
        let role = AXHelpers.getRole(control, runtime: runtime)
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

    private static func rowLabels(
        in row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [String] {
        let cells = AXHelpers.findAllDescendants(
            of: row,
            role: kAXCellRole,
            maxDepth: 4,
            runtime: runtime
        )
        return cells.flatMap { cell in
            AXHelpers.findAllDescendants(
                of: cell,
                role: kAXStaticTextRole,
                maxDepth: 4,
                runtime: runtime
            ).compactMap { text in
                let value = AXValueExtractors.extractTextValue(text, runtime: runtime)
                let normalized = normalizedLabel(value ?? "")
                return normalized.isEmpty ? nil : normalized
            }
        }
    }

    private static func candidateControls(
        in row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        AXHelpers.findAllDescendants(of: row, maxDepth: 5, runtime: runtime).filter { element in
            let role = AXHelpers.getRole(element, runtime: runtime)
            return interactiveControlRoles.contains(role ?? "")
        }
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
