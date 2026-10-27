@preconcurrency import ApplicationServices
import Foundation

/// #1420 — how many playhead components the control bar exposes is decided by its display-mode
/// popup, not by Logic: Logic's default "Beats & Project" shows bar and beat, "Beats" shows bar,
/// beat, division and tick (measured 2026-09-14 on Logic 12.3 in
/// `2026-09-14-the-transport-shows-ticks-when-the-display-mode-does`, and 2026-10-25 on Logic 12.4
/// in en-US). A caller that needs a tick-exact playhead switches to Beats for the reading and puts
/// the mode it found back afterwards. Switching changes the display only; no position moves.
enum ControlBarDisplayMode {
    /// What a switch acquired: the mode it found, and the window and popup it changed. A restore
    /// acts only while the same project, window and popup are still held (#1420: restore under the
    /// same project/window/control ownership).
    struct Lease: @unchecked Sendable, Equatable {
        let original: String
        let window: AXUIElement
        let windowTitle: String?
        let document: String
        let popup: AXUIElement

        static func == (lhs: Lease, rhs: Lease) -> Bool {
            lhs.original == rhs.original && lhs.windowTitle == rhs.windowTitle && lhs.document == rhs.document
                && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.popup, rhs.popup)
        }
    }

    enum Switch: Equatable, Sendable {
        /// The popup now reads Beats; the lease says what to restore and where.
        case switched(Lease)
        /// Nothing was switched; the reason says which step could not be observed or performed.
        case unavailable(String)
        /// A UI action had an effect that could not be settled. Callers must stop before their
        /// next write; when present, the lease is the only bounded inverse they may attempt.
        case unsettled(Lease?, String)
    }

    enum Restore: Equatable, Sendable {
        /// The popup reads the original mode again.
        case restored
        /// Not restored; the reason says why. Nothing was pressed unless the lease was still held.
        case refused(String)
    }

    /// Measured on Logic 12.4 (6707), en-US, on 2026-10-26 with a 25 ms poll across ten switches
    /// each way between "Beats & Project" and "Beats": AXShowMenu → the popup's AXMenu child was
    /// 27–31 ms. The timeout and poll are ControlsViewBooleanParameterWriter's measured View-menu
    /// values (28–46 ms there).
    static let menuAppearanceTimeout: TimeInterval = 2.0
    static let menuAppearancePollInterval: TimeInterval = 0.05
    /// Same measurement: AXPress on a mode item → the popup's AXValue reading that mode was
    /// 171–180 ms; an immediate read still shows the previous mode. 0.75 s is about a 4× margin
    /// over the 180 ms maximum.
    static let modeConfirmationTimeout: TimeInterval = 0.75
    static let modeConfirmationPollInterval: TimeInterval = 0.05
    /// Same measurement: AXPress on Beats → the Playhead Position group exposing bar, beat,
    /// division and tick was 371–392 ms (and back to two sliders 371–459 ms). 2 s is about a 4×
    /// margin over the 459 ms maximum. Used by callers that reread the transport after a switch.
    static let positionComponentsTimeout: TimeInterval = 2.0
    static let positionComponentsPollInterval: TimeInterval = 0.05

    /// Selects the Beats display mode in the main window's control bar.
    static func selectBeats(runtime: AXLogicProElements.Runtime = .production) -> Switch {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let popup = popup(in: window, runtime: runtime.ax) else {
            return .unavailable("display_mode_popup_not_found")
        }
        return selectBeats(
            in: popup, window: window, runtime: runtime.ax,
            currentOwner: {
                guard let currentWindow = AXLogicProElements.mainWindow(runtime: runtime) else { return nil }
                return (currentWindow, ControlBarDisplayMode.popup(in: currentWindow, runtime: runtime.ax))
            })
    }

    /// Puts the leased popup back to its original mode, if the lease still holds.
    static func restore(_ lease: Lease, runtime: AXLogicProElements.Runtime = .production) -> Restore {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .refused("display_mode_window_changed")
        }
        let heldPopup = popup(in: window, runtime: runtime.ax)
        return restore(
            lease, window: window, popup: heldPopup, runtime: runtime.ax,
            currentOwner: {
                guard let currentWindow = AXLogicProElements.mainWindow(runtime: runtime) else { return nil }
                return (currentWindow, popup(in: currentWindow, runtime: runtime.ax))
            })
    }

    static func selectBeats(
        in popup: AXUIElement, window: AXUIElement, runtime: AXHelpers.Runtime,
        currentOwner: (() -> (AXUIElement, AXUIElement?)?)? = nil
    ) -> Switch {
        guard let initialTitle = title(of: popup, runtime: runtime) else {
            return .unavailable("display_mode_unreadable")
        }
        guard let projectDocument = document(of: window, runtime: runtime) else {
            return .unavailable("display_mode_project_unreadable")
        }
        let windowTitle = AXHelpers.getTitle(window, runtime: runtime)
        let observation: MenuObservation
        switch openMenu(in: popup, runtime: runtime) {
        case .observed(let observed):
            observation = observed
        case .unavailable:
            let initialLease = Lease(
                original: initialTitle, window: window, windowTitle: windowTitle,
                document: projectDocument, popup: popup)
            if let refusal = leaseRefusal(
                initialLease, window: window, popup: popup, runtime: runtime,
                currentOwner: currentOwner
            ) {
                return .unsettled(nil, refusal)
            }
            return .unavailable("display_mode_beats_item_not_pressed")
        case .unsettled(let reason):
            return .unsettled(nil, reason)
        }
        guard let original = observation.selectedTitle else {
            return .unsettled(nil, "display_mode_menu_selection_unreadable")
        }
        let lease = Lease(
            original: original, window: window, windowTitle: windowTitle,
            document: projectDocument, popup: popup)
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            return cleanupSwitchFailure(
                lease, observation: observation, window: window, popup: popup, runtime: runtime,
                currentOwner: currentOwner, settledReason: refusal)
        }
        if isBeats(original) {
            return cleanupSwitchFailure(
                lease, observation: observation, window: window, popup: popup, runtime: runtime,
                currentOwner: currentOwner, settledReason: "display_mode_already_beats")
        }
        let originals = observation.items.filter { $0.title == original }
        let beats = observation.items.filter {
            AXLocalePolicy.beatsDisplayModeItem.matches($0.title, mode: .exact)
        }
        guard originals.count == 1, originals[0].checked, originals[0].enabled,
              beats.count == 1, beats[0].enabled,
              document(of: window, runtime: runtime) == projectDocument else {
            return cleanupSwitchFailure(
                lease, observation: observation, window: window, popup: popup, runtime: runtime,
                currentOwner: currentOwner, settledReason: "display_mode_beats_item_not_pressed")
        }
        guard actionAvailable(kAXPressAction as String, on: beats[0].element, runtime: runtime) else {
            return cleanupSwitchFailure(
                lease, observation: observation, window: window, popup: popup, runtime: runtime,
                currentOwner: currentOwner, settledReason: "display_mode_beats_item_not_pressed")
        }
        _ = AXHelpers.performAction(
            beats[0].element, kAXPressAction as String, runtime: runtime)
        let now = waitForMode(of: popup, runtime: runtime, until: isBeats)
        let changed = now.map(isBeats) == true
        var menuClosed = waitForMenuClosure(under: popup, runtime: runtime)
        if !menuClosed { menuClosed = cancel(observation.menu, under: popup, runtime: runtime) }
        guard menuClosed else {
            return .unsettled(lease, "display_mode_menu_not_closed")
        }
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            return .unsettled(lease, refusal)
        }
        if changed {
            // A false AX acknowledgement can still accompany an applied leaf action. Never
            // discard the only inverse merely because AXPress reported failure.
            return .switched(lease)
        }
        // The action's effect cannot be proved from AXValue. A false AX acknowledgement can still
        // accompany a changed checkmark, so it is not zero-write evidence. Do not consume
        // the inverse here and then expose the same lease for a second attempt. The caller owns
        // the sole bounded restoration attempt and must stop before its next write.
        return .unsettled(lease, "display_mode_change_unverified")
    }

    private static func cleanupSwitchFailure(
        _ lease: Lease, observation: MenuObservation, window: AXUIElement, popup: AXUIElement,
        runtime: AXHelpers.Runtime, currentOwner: (() -> (AXUIElement, AXUIElement?)?)?,
        settledReason: String
    ) -> Switch {
        guard cancel(observation.menu, under: popup, runtime: runtime) else {
            return .unsettled(lease, "display_mode_menu_not_closed")
        }
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            return .unsettled(lease, refusal)
        }
        return .unavailable(settledReason)
    }

    /// `window` and `popup` are what the main window and its control bar hold now.
    static func restore(
        _ lease: Lease, window: AXUIElement, popup: AXUIElement?, runtime: AXHelpers.Runtime,
        currentOwner: (() -> (AXUIElement, AXUIElement?)?)? = nil
    ) -> Restore {
        guard let popup else { return .refused("display_mode_popup_changed") }
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            return .refused(refusal)
        }
        let observation: MenuObservation
        switch openMenu(in: popup, runtime: runtime) {
        case .observed(let observed):
            observation = observed
        case .unavailable(let reason), .unsettled(let reason):
            return .refused(reason)
        }
        guard let now = observation.selectedTitle else {
            return .refused("display_mode_menu_selection_unreadable")
        }
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            _ = cancel(observation.menu, under: popup, runtime: runtime)
            return .refused(refusal)
        }
        if now == lease.original {
            guard cancel(observation.menu, under: popup, runtime: runtime) else {
                return .refused("display_mode_menu_not_closed")
            }
            if let refusal = leaseRefusal(
                lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
            ) {
                return .refused(refusal)
            }
            return .restored
        }
        // Only the checked mode this switch set is ours to undo; AXValue can still report Beats
        // after a later user selection and therefore is not cleanup authority.
        guard isBeats(now) else {
            guard cancel(observation.menu, under: popup, runtime: runtime) else {
                return .refused("display_mode_menu_not_closed")
            }
            if let refusal = leaseRefusal(
                lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
            ) {
                return .refused(refusal)
            }
            return .refused("display_mode_changed_since_switch")
        }
        let originals = observation.items.filter { $0.title == lease.original }
        guard originals.count == 1, originals[0].enabled,
              leaseRefusal(
                  lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
              ) == nil else {
            guard cancel(observation.menu, under: popup, runtime: runtime) else {
                return .refused("display_mode_menu_not_closed")
            }
            return .refused("display_mode_not_restored")
        }
        guard actionAvailable(kAXPressAction as String, on: originals[0].element, runtime: runtime) else {
            guard cancel(observation.menu, under: popup, runtime: runtime) else {
                return .refused("display_mode_menu_not_closed")
            }
            if let refusal = leaseRefusal(
                lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
            ) {
                return .refused(refusal)
            }
            return .refused("display_mode_not_restored")
        }
        _ = AXHelpers.performAction(originals[0].element, kAXPressAction as String, runtime: runtime)
        // This read is only a settling aid. AXValue can already be stale at the desired value, so
        // it is never sufficient restoration evidence by itself.
        _ = waitForMode(of: popup, runtime: runtime, until: { $0 == lease.original })
        var menuClosed = waitForMenuClosure(under: popup, runtime: runtime)
        if !menuClosed { menuClosed = cancel(observation.menu, under: popup, runtime: runtime) }
        guard menuClosed else {
            return .refused("display_mode_menu_not_closed")
        }
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            return .refused(refusal)
        }
        return verifyRestoredSelection(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner)
    }

    /// Proves the inverse from a fresh, complete menu census. The popup's AXValue is deliberately
    /// excluded: it may have shown the original mode before an ineffective inverse was pressed.
    private static func verifyRestoredSelection(
        _ lease: Lease, window: AXUIElement, popup: AXUIElement, runtime: AXHelpers.Runtime,
        currentOwner: (() -> (AXUIElement, AXUIElement?)?)?
    ) -> Restore {
        let observation: MenuObservation
        switch openMenu(in: popup, runtime: runtime) {
        case .observed(let observed):
            observation = observed
        case .unavailable(let reason), .unsettled(let reason):
            if let refusal = leaseRefusal(
                lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
            ) {
                return .refused(refusal)
            }
            return .refused(reason)
        }
        let restored = observation.selectedTitle == lease.original
        guard cancel(observation.menu, under: popup, runtime: runtime) else {
            return .refused("display_mode_menu_not_closed")
        }
        if let refusal = leaseRefusal(
            lease, window: window, popup: popup, runtime: runtime, currentOwner: currentOwner
        ) {
            return .refused(refusal)
        }
        return restored ? .restored : .refused("display_mode_not_restored")
    }

    private static func leaseRefusal(
        _ lease: Lease, window: AXUIElement, popup: AXUIElement, runtime: AXHelpers.Runtime,
        currentOwner: (() -> (AXUIElement, AXUIElement?)?)? = nil
    ) -> String? {
        guard CFEqual(window, lease.window),
              AXHelpers.getTitle(window, runtime: runtime) == lease.windowTitle else {
            return "display_mode_window_changed"
        }
        guard document(of: window, runtime: runtime) == lease.document else {
            return "display_mode_project_changed"
        }
        guard CFEqual(popup, lease.popup) else { return "display_mode_popup_changed" }
        if let currentOwner {
            guard let current = currentOwner() else { return "display_mode_window_changed" }
            guard CFEqual(current.0, window), CFEqual(current.0, lease.window) else {
                return "display_mode_window_changed"
            }
            guard let currentPopup = current.1,
                  CFEqual(currentPopup, popup), CFEqual(currentPopup, lease.popup) else {
                return "display_mode_popup_changed"
            }
        }
        return nil
    }

    /// Exactly one display-mode popup inside the window's control bar, or nil.
    private static func popup(in window: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        guard let bar = AXLogicProElements.getControlBar(in: window, runtime: runtime) else { return nil }
        let roleCensus: AXHelpers.Census
        switch AXHelpers.censusDescendantResult(
            of: bar, role: kAXPopUpButtonRole as String, maxDepth: 8, runtime: runtime,
            requiresCompleteTraversal: true
        ) {
        case .success(let observed):
            roleCensus = observed
        case .failure:
            return nil
        }
        var matches: [AXUIElement] = []
        for candidate in roleCensus.matches {
            switch AXLocalePolicy.elementMatchesResult(
                candidate, AXLocalePolicy.displayModePopupLabel, mode: .exactStrict,
                runtime: runtime
            ) {
            case .success(true):
                matches.append(candidate)
            case .success(false):
                continue
            case .failure:
                // An unreadable peer may be the same control. It cannot be dropped from a
                // uniqueness proof that authorizes AXShowMenu or a later leaf press.
                return nil
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The popup's AXValue is the selected mode's title (`Beats & Project` in the default).
    private static func title(of popup: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        AXHelpers.getValue(popup, runtime: runtime) as? String
    }

    private static func document(of window: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        let reading: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
            window, kAXDocumentAttribute as String, runtime: runtime)
        guard case .success(let raw) = reading, let document = raw as? String,
              !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return document
    }

    /// The popup's mode once it satisfies `done`, or a fresh reading taken after the deadline
    /// (not the last poll reported as an end-of-wait fact). See `modeConfirmationTimeout`.
    private static func waitForMode(
        of popup: AXUIElement, runtime: AXHelpers.Runtime, until done: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(modeConfirmationTimeout)
        repeat {
            if let reading = title(of: popup, runtime: runtime), done(reading) { return reading }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(modeConfirmationPollInterval, remaining))
        } while Date() < deadline
        return title(of: popup, runtime: runtime)
    }

    /// The popup's AXMenu child, which appears after AXShowMenu returns, or nil at the deadline.
    /// See `menuAppearanceTimeout`.
    private static func waitForMenu(under popup: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(menuAppearanceTimeout)
        repeat {
            if let menu = currentMenu(under: popup, runtime: runtime) { return menu }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(menuAppearancePollInterval, remaining))
        } while Date() < deadline
        return currentMenu(under: popup, runtime: runtime)
    }

    private static func currentMenu(under popup: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        guard let menus = observedMenus(under: popup, runtime: runtime), menus.count == 1 else { return nil }
        return menus[0]
    }

    private static func observedMenus(under popup: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement]? {
        guard case .success(let children) = AXHelpers.childrenResult(popup, runtime: runtime) else { return nil }
        var menus: [AXUIElement] = []
        for child in children {
            let role: Result<String?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime)
            guard case .success(.some(let value)) = role else { return nil }
            if value == kAXMenuRole as String { menus.append(child) }
        }
        return menus
    }

    private static func menuIsClosed(under popup: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        observedMenus(under: popup, runtime: runtime)?.isEmpty == true
    }

    private static func waitForMenuClosure(under popup: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        let deadline = Date().addingTimeInterval(modeConfirmationTimeout)
        repeat {
            if menuIsClosed(under: popup, runtime: runtime) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(modeConfirmationPollInterval, remaining))
        } while Date() < deadline
        return menuIsClosed(under: popup, runtime: runtime)
    }

    /// `.exact` compares the whole trimmed title, so `Beats & Project` is not Beats.
    private static func isBeats(_ title: String) -> Bool {
        AXLocalePolicy.beatsDisplayModeItem.matches(title, mode: .exact)
    }

    private struct MenuItem {
        let element: AXUIElement
        let title: String
        let enabled: Bool
        let checked: Bool
    }

    private struct MenuObservation {
        let menu: AXUIElement
        let items: [MenuItem]
        let selectedTitle: String?
    }

    private enum MenuAcquisition {
        /// A menu opened by this call and a complete item census.
        case observed(MenuObservation)
        /// This call's menu effect was fully settled and no write authority was acquired.
        case unavailable(String)
        /// The baseline or this call's UI effect could not be proved settled.
        case unsettled(String)
    }

    /// Opens the popup and proves the complete bounded menu before returning any write authority.
    /// An unreadable role/title/enabled/checkmark or subtree cancels the owned menu and refuses.
    private static func openMenu(in popup: AXUIElement, runtime: AXHelpers.Runtime) -> MenuAcquisition {
        guard let baseline = observedMenus(under: popup, runtime: runtime) else {
            return .unsettled("display_mode_menu_baseline_unreadable")
        }
        // Never adopt or dismiss a menu that was not opened by this call.
        guard baseline.isEmpty else {
            return .unsettled("display_mode_menu_already_open")
        }
        let acknowledged = AXHelpers.performAction(popup, kAXShowMenuAction as String, runtime: runtime)
        guard let menu = waitForMenu(under: popup, runtime: runtime) else {
            guard let after = observedMenus(under: popup, runtime: runtime) else {
                return .unsettled("display_mode_menu_state_unverified")
            }
            return after.isEmpty
                ? .unavailable("display_mode_menu_not_opened")
                : .unsettled("display_mode_menu_state_unverified")
        }
        guard acknowledged else {
            return cancel(menu, under: popup, runtime: runtime)
                ? .unavailable("display_mode_menu_not_opened")
                : .unsettled("display_mode_menu_not_closed")
        }
        let census: AXHelpers.Census
        switch AXHelpers.censusDescendantResult(
            of: menu, role: kAXMenuItemRole as String, maxDepth: 2, runtime: runtime,
            requiresCompleteTraversal: true
        ) {
        case .success(let observed): census = observed
        case .failure:
            return cancel(menu, under: popup, runtime: runtime)
                ? .unavailable("display_mode_menu_unreadable")
                : .unsettled("display_mode_menu_not_closed")
        }
        var items: [MenuItem] = []
        for element in census.matches {
            let titleRead: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, kAXTitleAttribute as String, runtime: runtime)
            let enabledRead: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, kAXEnabledAttribute as String, runtime: runtime)
            let markRead: Result<AnyObject?, AXHelpers.AXStatusError> = AXHelpers.getAttributeResult(
                element, "AXMenuItemMarkChar", runtime: runtime)
            guard case .success(let rawTitle) = titleRead, let title = rawTitle as? String,
                  case .success(let rawEnabled) = enabledRead, let enabled = rawEnabled as? Bool else {
                return cancel(menu, under: popup, runtime: runtime)
                    ? .unavailable("display_mode_menu_unreadable")
                    : .unsettled("display_mode_menu_not_closed")
            }
            let checked: Bool
            switch markRead {
            case .success(nil): checked = false
            case .success(let raw?):
                guard let mark = raw as? String else {
                    return cancel(menu, under: popup, runtime: runtime)
                        ? .unavailable("display_mode_menu_unreadable")
                        : .unsettled("display_mode_menu_not_closed")
                }
                checked = !mark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .failure(let error) where error.isDefinitiveAbsence:
                checked = false
            case .failure:
                return cancel(menu, under: popup, runtime: runtime)
                    ? .unavailable("display_mode_menu_unreadable")
                    : .unsettled("display_mode_menu_not_closed")
            }
            items.append(MenuItem(element: element, title: title, enabled: enabled, checked: checked))
        }
        let selected = items.filter(\.checked)
        guard selected.count == 1 else {
            return cancel(menu, under: popup, runtime: runtime)
                ? .unavailable("display_mode_menu_selection_unreadable")
                : .unsettled("display_mode_menu_not_closed")
        }
        return .observed(MenuObservation(menu: menu, items: items, selectedTitle: selected[0].title))
    }

    private static func actionAvailable(_ action: String, on element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard case .success(let actions) = AXHelpers.getActionNamesResult(element, runtime: runtime) else {
            return false
        }
        return actions.contains(action)
    }

    private static func cancel(_ menu: AXUIElement, under popup: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard actionAvailable(kAXCancelAction as String, on: menu, runtime: runtime),
              AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime) else { return false }
        return waitForMenuClosure(under: popup, runtime: runtime)
    }
}
