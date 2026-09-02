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
                return "the labelled Controls-view AXRow did not place its label and control in sibling AXCells"
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
        case refused(ViewSwitchFailure, targetSelectionAttempted: Bool)
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
            if targetSelectionAttempted {
                _ = switchView(
                    to: entryView,
                    in: window,
                    switcher: switcher,
                    menuAppearanceTimeout: menuAppearanceTimeout,
                    confirmationTimeout: confirmationTimeout,
                    forceSelection: true,
                    runtime: runtime
                )
            }
            return .refused(failure)
        }
    }

    /// The native editor is signaled by a parameter-bearing slider. Controls
    /// requires at least one AXRow with a nonempty AXStaticText label in one
    /// AXCell and an interactive control in a sibling AXCell; a browser/preset
    /// table has no such parameter-control pair, so its rows cannot prove
    /// Controls. A title-only slider is Editor evidence only when that Controls
    /// discriminator is absent.
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
        if controlsViewStateIsBound(in: window, runtime: runtime) {
            return .controls
        }
        return sliders.isEmpty ? nil : .editor
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
        guard forceSelection || observedView(in: window, runtime: runtime) != targetView else {
            return .confirmed(switched: false)
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
                : .viewMenuItemAmbiguous(targetView),
                targetSelectionAttempted: false
            )
        }
        _ = AXHelpers.performAction(target, kAXPickAction as String, runtime: runtime)
        guard waitForView(
            targetView,
            in: window,
            timeout: confirmationTimeout,
            runtime: runtime
        ) else {
            return .refused(.viewStructureDidNotConfirm(targetView), targetSelectionAttempted: true)
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

    private static func controlsViewStateIsBound(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let tables = AXHelpers.censusDescendant(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime
        ).matches
        guard tables.count == 1, let table = tables.first else { return false }
        guard let rows = controlsRows(in: table, runtime: runtime) else { return false }
        // Heading and section rows have no interactive control in the live
        // table. A Controls view is bound by the presence of at least one
        // measured label/control pair, not by requiring every row to be one.
        return rows.contains { rowCarriesParameterPair($0, runtime: runtime) }
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
        guard let rows = controlsRows(in: table, runtime: runtime) else {
            return .refused(.controlsViewTableNotFound)
        }

        let target = normalizedLabel(requestedLabel)
        var matchingRows: [[AXUIElement]] = []
        var sawMissingLabel = false
        var sawAmbiguousLabel = false
        for row in rows where AXHelpers.getRole(row, runtime: runtime) == (kAXRowRole as String) {
            guard let cells = rowCells(in: row, runtime: runtime) else {
                sawMissingLabel = true
                continue
            }
            let labels = rowLabels(in: cells, runtime: runtime)
            guard labels.count == 1, let label = labels.first else {
                sawMissingLabel = sawMissingLabel || labels.isEmpty
                sawAmbiguousLabel = sawAmbiguousLabel || labels.count > 1
                continue
            }
            if normalizedLabel(label.value) == target {
                guard controlsAreConfinedToCells(in: row, cells: cells, runtime: runtime) else {
                    return .refused(.rowStructureInvalid)
                }
                guard candidateControls(in: label.cell, runtime: runtime).isEmpty else {
                    return .refused(.rowStructureInvalid)
                }
                let siblingCells = cells.filter { !CFEqual($0, label.cell) }
                matchingRows.append(candidateControls(in: siblingCells, runtime: runtime))
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

    /// `AXRows` has two absence answers: a successful empty attribute and the
    /// `noValue`/`attributeUnsupported` AX statuses. Only those answers may use
    /// AXChildren as the alternate table representation; every other status is
    /// a read failure and therefore cannot establish a Controls table.
    private static func controlsRows(
        in table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        switch AXHelpers.getAXUIElementArrayRead(
            table,
            kAXRowsAttribute as String,
            runtime: runtime
        ) {
        case let .success(.elements(rows)):
            return rows
        case .success(.absent):
            switch AXHelpers.childrenResult(table, runtime: runtime) {
            case let .success(children):
                return children.filter {
                    AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String)
                }
            case .failure:
                return nil
            }
        case .failure(let error) where error.isDefinitiveAbsence:
            switch AXHelpers.childrenResult(table, runtime: runtime) {
            case let .success(children):
                return children.filter {
                    AXHelpers.getRole($0, runtime: runtime) == (kAXRowRole as String)
                }
            case .failure:
                return nil
            }
        case .success(.malformed), .failure:
            return nil
        }
    }

    private struct RowLabel {
        let cell: AXUIElement
        let value: String
    }

    private static func rowCells(
        in row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement]? {
        switch AXHelpers.childrenResult(row, runtime: runtime) {
        case let .success(children):
            return children.filter {
                AXHelpers.getRole($0, runtime: runtime) == (kAXCellRole as String)
            }
        case .failure:
            return nil
        }
    }

    private static func rowLabels(
        in cells: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> [RowLabel] {
        cells.flatMap { cell in
            AXHelpers.findAllDescendants(
                of: cell,
                role: kAXStaticTextRole,
                maxDepth: 4,
                runtime: runtime
            ).compactMap { text in
                let value = AXValueExtractors.extractTextValue(text, runtime: runtime)
                let normalized = normalizedLabel(value ?? "")
                return normalized.isEmpty ? nil : RowLabel(cell: cell, value: normalized)
            }
        }
    }

    private static func candidateControls(
        in element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        AXHelpers.findAllDescendants(of: element, maxDepth: 5, runtime: runtime).filter { candidate in
            let role = AXHelpers.getRole(candidate, runtime: runtime)
            return interactiveControlRoles.contains(role ?? "")
        }
    }

    private static func candidateControls(
        in cells: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> [AXUIElement] {
        cells.flatMap { candidateControls(in: $0, runtime: runtime) }
    }

    private static func controlsAreConfinedToCells(
        in row: AXUIElement,
        cells: [AXUIElement],
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let controlsInCells = candidateControls(in: cells, runtime: runtime)
        let controlsInRow = candidateControls(in: row, runtime: runtime)
        guard controlsInCells.count == controlsInRow.count else { return false }
        return controlsInRow.allSatisfy { candidate in
            controlsInCells.contains { CFEqual($0, candidate) }
        }
    }

    private static func rowCarriesParameterPair(
        _ row: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let cells = rowCells(in: row, runtime: runtime) else {
            return false
        }
        let labels = rowLabels(in: cells, runtime: runtime)
        guard labels.count == 1,
              let label = labels.first,
              controlsAreConfinedToCells(in: row, cells: cells, runtime: runtime) else {
            return false
        }
        // Keep the classifier's discriminator identical to `locate`'s binding:
        // a control beside the label in its own AXCell is not a parameter pair.
        // Otherwise an invalid row could certify Controls even though writes
        // correctly refuse to bind it.
        guard candidateControls(in: label.cell, runtime: runtime).isEmpty else {
            return false
        }
        return candidateControls(
            in: cells.filter { !CFEqual($0, label.cell) },
            runtime: runtime
        ).count == 1
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
