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

    /// Selects the Beats display mode in the main window's control bar.
    static func selectBeats(runtime: AXLogicProElements.Runtime = .production) -> Switch {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime),
              let popup = popup(in: window, runtime: runtime.ax) else {
            return .unavailable("display_mode_popup_not_found")
        }
        return selectBeats(in: popup, window: window, runtime: runtime.ax)
    }

    /// Puts the leased popup back to its original mode, if the lease still holds.
    static func restore(_ lease: Lease, runtime: AXLogicProElements.Runtime = .production) -> Restore {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .refused("display_mode_window_changed")
        }
        return restore(lease, window: window, popup: popup(in: window, runtime: runtime.ax), runtime: runtime.ax)
    }

    static func selectBeats(in popup: AXUIElement, window: AXUIElement, runtime: AXHelpers.Runtime) -> Switch {
        guard let original = title(of: popup, runtime: runtime) else {
            return .unavailable("display_mode_unreadable")
        }
        guard !isBeats(original) else {
            return .unavailable("display_mode_already_beats")
        }
        guard press(in: popup, runtime: runtime, item: { menu in
            AXLocalePolicy.censusDescendant(
                of: menu, role: kAXMenuItemRole as String, matching: AXLocalePolicy.beatsDisplayModeItem,
                mode: .exact, maxDepth: 2, runtime: runtime)
        }) else {
            return .unavailable("display_mode_beats_item_not_pressed")
        }
        guard let now = settledTitle(of: popup, runtime: runtime, until: isBeats), isBeats(now) else {
            // The press was issued but the popup does not read Beats. If it reads anything other
            // than what it showed, put that back; a popup that never left `original` needs nothing.
            if title(of: popup, runtime: runtime) != original {
                _ = pressTitle(original, in: popup, runtime: runtime)
            }
            return .unavailable("display_mode_did_not_change")
        }
        return .switched(Lease(
            original: original, window: window, windowTitle: AXHelpers.getTitle(window, runtime: runtime),
            popup: popup))
    }

    /// `window` and `popup` are what the main window and its control bar hold now.
    static func restore(
        _ lease: Lease, window: AXUIElement, popup: AXUIElement?, runtime: AXHelpers.Runtime
    ) -> Restore {
        guard CFEqual(window, lease.window),
              AXHelpers.getTitle(window, runtime: runtime) == lease.windowTitle else {
            return .refused("display_mode_window_changed")
        }
        guard let popup, CFEqual(popup, lease.popup) else {
            return .refused("display_mode_popup_changed")
        }
        guard let now = title(of: popup, runtime: runtime) else {
            return .refused("display_mode_unreadable")
        }
        if now == lease.original { return .restored }
        // Only the mode this switch set is ours to undo; a later choice is the user's.
        guard isBeats(now) else { return .refused("display_mode_changed_since_switch") }
        guard pressTitle(lease.original, in: popup, runtime: runtime),
              settledTitle(of: popup, runtime: runtime, until: { $0 == lease.original }) == lease.original else {
            return .refused("display_mode_not_restored")
        }
        return .restored
    }

    private static func pressTitle(_ title: String, in popup: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        press(in: popup, runtime: runtime, item: { menu in
            AXHelpers.censusDescendant(
                of: menu, role: kAXMenuItemRole as String, title: title, maxDepth: 2, runtime: runtime)
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

    /// The popup's title once it satisfies `done`, or its last reading after about two seconds.
    /// Logic updates the popup's AXValue after the menu press returns (measured 2026-10-26 on
    /// Logic 12.4: an immediate read still showed the previous mode while the switch went through),
    /// so a single read right after the press would report a switch that happened as one that did
    /// not, and leave the mode changed.
    private static func settledTitle(
        of popup: AXUIElement, runtime: AXHelpers.Runtime, until done: (String) -> Bool
    ) -> String? {
        var reading = title(of: popup, runtime: runtime)
        for _ in 0..<40 {
            if let reading, done(reading) { break }
            usleep(50_000)
            reading = title(of: popup, runtime: runtime)
        }
        return reading
    }

    /// `.exact` compares the whole trimmed title, so `Beats & Project` is not Beats.
    private static func isBeats(_ title: String) -> Bool {
        AXLocalePolicy.beatsDisplayModeItem.matches(title, mode: .exact)
    }

    /// Opens the popup's menu and presses the one item `item` finds in it. Any other count cancels
    /// the menu and presses nothing.
    private static func press(
        in popup: AXUIElement, runtime: AXHelpers.Runtime, item: (AXUIElement) -> AXHelpers.Census
    ) -> Bool {
        guard AXHelpers.performAction(popup, kAXShowMenuAction as String, runtime: runtime) else {
            return false
        }
        // The menu can materialise after AXShowMenu returns; wait for it briefly.
        var menu: AXUIElement?
        for attempt in 0..<20 {
            menu = AXHelpers.getChildren(popup, runtime: runtime).first {
                AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
            }
            if menu != nil { break }
            if attempt < 19 { usleep(50_000) }
        }
        guard let menu else { return false }
        let census = item(menu)
        guard census.candidates == 1, let item = census.element else {
            _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime)
            return false
        }
        return AXHelpers.performAction(item, kAXPressAction as String, runtime: runtime)
    }
}
