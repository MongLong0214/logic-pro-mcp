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
    /// acts only while all three are still the ones it switched (#1420: restore under the same
    /// project/window/control ownership).
    struct Lease: @unchecked Sendable, Equatable {
        let original: String
        let window: AXUIElement
        let windowTitle: String?
        let popup: AXUIElement

        static func == (lhs: Lease, rhs: Lease) -> Bool {
            lhs.original == rhs.original && lhs.windowTitle == rhs.windowTitle
                && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.popup, rhs.popup)
        }
    }

    enum Switch: Equatable, Sendable {
        /// The popup now reads Beats; the lease says what to restore and where.
        case switched(Lease)
        /// Nothing was switched; the reason says which step could not be observed or performed.
        case unavailable(String)
    }

    enum Restore: Equatable, Sendable {
        /// The popup reads the original mode again.
        case restored
        /// Not restored; the reason says why. Nothing was pressed unless the lease was still held.
        case refused(String)
    }

    /// Deadlines for the waits after each press, in the shape of `QuantizeTiming`: `.live` for
    /// Logic, `.immediate` for tests that need no wait. Measured on Logic 12.4 (6707), en-US, on
    /// 2026-10-26 with a 25 ms poll across ten switches each way between "Beats & Project" and
    /// "Beats" (twenty presses for the close):
    struct Timing: Sendable {
        /// AXShowMenu → the popup's AXMenu child: 27–31 ms. 2 s is ControlsViewBooleanParameterWriter's
        /// measured View-menu timeout (28–46 ms there).
        var menuOpenTimeout: TimeInterval = 2.0
        /// AXPress on a mode item → the popup's AXValue reading that mode: 171–180 ms; an immediate
        /// read still shows the previous mode. About a 4× margin over the 180 ms maximum.
        var modeConfirmationTimeout: TimeInterval = 0.75
        /// AXPress on a mode item → no AXMenu under the popup: 363–382 ms, and no Logic window at
        /// the popup-menu layer: 395–416 ms. About a 4× margin over the 416 ms maximum.
        var menuCloseTimeout: TimeInterval = 1.75
        /// AXPress on Beats → the Playhead Position group exposing bar, beat, division and tick:
        /// 371–392 ms (back to two sliders 371–459 ms). About a 4× margin over 459 ms. Used by
        /// callers that reread the transport after a switch.
        var positionComponentsTimeout: TimeInterval = 2.0
        var pollInterval: TimeInterval = 0.05

        static let live = Timing()
        static let immediate = Timing(
            menuOpenTimeout: 0, modeConfirmationTimeout: 0, menuCloseTimeout: 0,
            positionComponentsTimeout: 0, pollInterval: 0)
    }

    /// Selects the Beats display mode in the main window's control bar.
    static func selectBeats(
        runtime: AXLogicProElements.Runtime = .production, timing: Timing = .live
    ) -> Switch {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let popup = popup(in: window, runtime: runtime.ax) else {
            return .unavailable("display_mode_popup_not_found")
        }
        return selectBeats(in: popup, window: window, runtime: runtime, timing: timing)
    }

    /// Puts the leased popup back to its original mode, if the lease still holds.
    static func restore(
        _ lease: Lease, runtime: AXLogicProElements.Runtime = .production, timing: Timing = .live
    ) -> Restore {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .refused("display_mode_window_changed")
        }
        return restore(lease, window: window, popup: popup(in: window, runtime: runtime.ax),
                       runtime: runtime, timing: timing)
    }

    static func selectBeats(
        in popup: AXUIElement, window: AXUIElement, runtime: AXLogicProElements.Runtime, timing: Timing
    ) -> Switch {
        guard let original = title(of: popup, runtime: runtime.ax) else {
            return .unavailable("display_mode_unreadable")
        }
        guard !isBeats(original) else {
            return .unavailable("display_mode_already_beats")
        }
        switch press(in: popup, runtime: runtime, timing: timing, item: { menu in
            AXLocalePolicy.censusDescendant(
                of: menu, role: kAXMenuItemRole as String, matching: AXLocalePolicy.beatsDisplayModeItem,
                mode: .exact, maxDepth: 2, runtime: runtime.ax)
        }) {
        case .pressed: break
        case .notPressed: return .unavailable("display_mode_beats_item_not_pressed")
        case .menuNotClosed: return .unavailable("display_mode_menu_not_closed")
        }
        guard let now = waitForMode(of: popup, runtime: runtime.ax, timing: timing, until: isBeats),
              isBeats(now) else {
            // The press was issued but the popup does not read Beats. If it reads anything other
            // than what it showed, put that back; a popup that never left `original` needs nothing.
            if title(of: popup, runtime: runtime.ax) != original {
                _ = pressTitle(original, in: popup, runtime: runtime, timing: timing)
            }
            return .unavailable("display_mode_did_not_change")
        }
        return .switched(Lease(
            original: original, window: window, windowTitle: AXHelpers.getTitle(window, runtime: runtime.ax),
            popup: popup))
    }

    /// `window` and `popup` are what the main window and its control bar hold now.
    static func restore(
        _ lease: Lease, window: AXUIElement, popup: AXUIElement?,
        runtime: AXLogicProElements.Runtime, timing: Timing
    ) -> Restore {
        guard CFEqual(window, lease.window),
              AXHelpers.getTitle(window, runtime: runtime.ax) == lease.windowTitle else {
            return .refused("display_mode_window_changed")
        }
        guard let popup, CFEqual(popup, lease.popup) else {
            return .refused("display_mode_popup_changed")
        }
        guard let now = title(of: popup, runtime: runtime.ax) else {
            return .refused("display_mode_unreadable")
        }
        if now == lease.original { return .restored }
        // Only the mode this switch set is ours to undo; a later choice is the user's.
        guard isBeats(now) else { return .refused("display_mode_changed_since_switch") }
        switch pressTitle(lease.original, in: popup, runtime: runtime, timing: timing) {
        case .pressed: break
        case .notPressed: return .refused("display_mode_not_restored")
        case .menuNotClosed: return .refused("display_mode_menu_not_closed")
        }
        guard waitForMode(of: popup, runtime: runtime.ax, timing: timing,
                          until: { $0 == lease.original }) == lease.original else {
            return .refused("display_mode_not_restored")
        }
        return .restored
    }

    private enum PressOutcome {
        /// The item was pressed and the menu this press opened is gone.
        case pressed
        /// Nothing was pressed; the menu this press opened is gone.
        case notPressed
        /// A menu this press opened could not be certified closed.
        case menuNotClosed
    }

    private static func pressTitle(
        _ title: String, in popup: AXUIElement, runtime: AXLogicProElements.Runtime, timing: Timing
    ) -> PressOutcome {
        press(in: popup, runtime: runtime, timing: timing, item: { menu in
            AXHelpers.censusDescendant(
                of: menu, role: kAXMenuItemRole as String, title: title, maxDepth: 2, runtime: runtime.ax)
        })
    }

    /// Exactly one display-mode popup inside the window's control bar, or nil.
    private static func popup(in window: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        guard let bar = AXLogicProElements.getControlBar(in: window, runtime: runtime) else { return nil }
        let census = AXLocalePolicy.censusDescendant(
            of: bar, role: kAXPopUpButtonRole as String, matching: AXLocalePolicy.displayModePopupLabel,
            mode: .exactStrict, maxDepth: 8, runtime: runtime)
        return census.candidates == 1 ? census.element : nil
    }

    /// The popup's AXValue is the selected mode's title (`Beats & Project` in the default).
    private static func title(of popup: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        AXHelpers.getValue(popup, runtime: runtime) as? String
    }

    /// The popup's mode once it satisfies `done`, or a fresh reading taken after the deadline
    /// (not the last poll reported as an end-of-wait fact).
    private static func waitForMode(
        of popup: AXUIElement, runtime: AXHelpers.Runtime, timing: Timing, until done: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timing.modeConfirmationTimeout)
        repeat {
            if let reading = title(of: popup, runtime: runtime), done(reading) { return reading }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            pause(timing, remaining: remaining)
        } while Date() < deadline
        return title(of: popup, runtime: runtime)
    }

    /// The AXMenu children the popup holds now.
    private static func menus(under popup: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement] {
        AXHelpers.getChildren(popup, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
        }
    }

    /// The one menu AXShowMenu opened under the popup, or nil at the deadline or when there is more
    /// than one (nothing to own).
    private static func waitForMenu(
        under popup: AXUIElement, runtime: AXHelpers.Runtime, timing: Timing
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timing.menuOpenTimeout)
        repeat {
            let open = menus(under: popup, runtime: runtime)
            if !open.isEmpty { return open.count == 1 ? open[0] : nil }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            pause(timing, remaining: remaining)
        } while Date() < deadline
        return nil
    }

    /// As `quantizePopupAbsenceCertified`: no AXMenu under the popup, and no Logic window at the
    /// popup-menu layer. A fresh observation, not a lock.
    private static func menuAbsenceCertified(
        under popup: AXUIElement, runtime: AXLogicProElements.Runtime
    ) -> Bool {
        guard menus(under: popup, runtime: runtime.ax).isEmpty,
              let pid = runtime.logicProPID(), let windows = runtime.onScreenWindowList() else { return false }
        return LogicOnScreenWindows.popupMenuCount(windows, logicPID: pid) == 0
    }

    /// Waits for the menu to close; if it is still open at the deadline, cancels it only when it is
    /// still exactly the menu this press opened (as Quantize's owned cleanup does), then certifies
    /// its absence once more. Never posts a global Escape or cancels a menu it did not open.
    private static func closeOwnedMenu(
        _ menu: AXUIElement, under popup: AXUIElement, runtime: AXLogicProElements.Runtime, timing: Timing
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timing.menuCloseTimeout)
        repeat {
            if menuAbsenceCertified(under: popup, runtime: runtime) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            pause(timing, remaining: remaining)
        } while Date() < deadline
        let open = menus(under: popup, runtime: runtime.ax)
        if open.count == 1, CFEqual(open[0], menu),
           case .success(let actions) = AXHelpers.getActionNamesResult(menu, runtime: runtime.ax),
           actions.contains(kAXCancelAction as String) {
            _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime.ax)
        }
        return menuAbsenceCertified(under: popup, runtime: runtime)
    }

    private static func pause(_ timing: Timing, remaining: TimeInterval) {
        if timing.pollInterval > 0 { Thread.sleep(forTimeInterval: min(timing.pollInterval, remaining)) }
    }

    /// `.exact` compares the whole trimmed title, so `Beats & Project` is not Beats.
    private static func isBeats(_ title: String) -> Bool {
        AXLocalePolicy.beatsDisplayModeItem.matches(title, mode: .exact)
    }

    /// Opens the popup's menu and presses the one item `item` finds in it, then waits for the menu
    /// to close. Any other item count, or a cancelled task, presses nothing and closes the menu.
    private static func press(
        in popup: AXUIElement, runtime: AXLogicProElements.Runtime, timing: Timing,
        item: (AXUIElement) -> AXHelpers.Census
    ) -> PressOutcome {
        guard AXHelpers.performAction(popup, kAXShowMenuAction as String, runtime: runtime.ax),
              let menu = waitForMenu(under: popup, runtime: runtime.ax, timing: timing) else {
            return menuAbsenceCertified(under: popup, runtime: runtime) ? .notPressed : .menuNotClosed
        }
        let census = item(menu)
        guard !Task.isCancelled, census.candidates == 1, let item = census.element else {
            let closeImmediately = Timing(menuCloseTimeout: 0, pollInterval: 0)
            return closeOwnedMenu(menu, under: popup, runtime: runtime, timing: closeImmediately)
                ? .notPressed : .menuNotClosed
        }
        _ = AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime.ax)
        return closeOwnedMenu(menu, under: popup, runtime: runtime, timing: timing) ? .pressed : .menuNotClosed
    }
}
