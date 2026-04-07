import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    struct Runtime: @unchecked Sendable {
        let logicProPID: @Sendable () -> pid_t?
        let ax: AXHelpers.Runtime

        static let production = Runtime(
            logicProPID: { ProcessUtils.logicProPID() },
            ax: .production
        )
    }

    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot(runtime: Runtime = .production) -> AXUIElement? {
        guard let pid = runtime.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid, runtime: runtime.ax)
    }

    /// Get the main window element.
    static func mainWindow(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        return AXHelpers.getAttribute(app, kAXMainWindowAttribute, runtime: runtime.ax)
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        // Logic Pro's transport is typically an AXToolbar or AXGroup near the top
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole, runtime: runtime.ax) {
            return toolbar
        }
        // Fallback: search for a group containing transport-like buttons
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport", runtime: runtime.ax)
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String, runtime: Runtime = .production) -> AXUIElement? {
        guard let transport = getTransportBar(runtime: runtime) else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(
            of: transport, role: kAXButtonRole, title: name, runtime: runtime.ax
        ) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4, runtime: runtime.ax)
        for button in buttons {
            if AXHelpers.getDescription(button, runtime: runtime.ax) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the track header area containing individual track rows.
    static func getTrackHeaders(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        // Track headers are typically in a scrollable list/table area
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXListRole, identifier: "Track Headers", runtime: runtime.ax
        ) {
            return area
        }
        // Fallback: look for an AXScrollArea containing AXRow or AXGroup children
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Tracks", runtime: runtime.ax
        ) {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXOutlineRole, maxDepth: 5, runtime: runtime.ax)
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let headers = getTrackHeaders(runtime: runtime) else { return nil }
        let rows = AXHelpers.getChildren(headers, runtime: runtime.ax)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders(runtime: Runtime = .production) -> [AXUIElement] {
        guard let headers = getTrackHeaders(runtime: runtime) else { return [] }
        return AXHelpers.getChildren(headers, runtime: runtime.ax)
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        // The mixer typically appears as a distinct group/scroll area
        if let mixer = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, identifier: "Mixer", runtime: runtime.ax
        ) {
            return mixer
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Mixer", runtime: runtime.ax)
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime) else { return nil }
        let strips = AXHelpers.getChildren(mixer, runtime: runtime.ax)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Fader is an AXSlider within the channel strip
        return AXHelpers.findDescendant(of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let mixer = getMixerArea(runtime: runtime) else { return nil }
        let strips = AXHelpers.getChildren(mixer, runtime: runtime.ax)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Pan is typically the second slider or a knob-type element
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax)
        // Convention: first slider = volume, second = pan (if present)
        return sliders.count > 1 ? sliders[1] : nil
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute, runtime: runtime.ax)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String], runtime: Runtime = .production) -> AXUIElement? {
        guard var current = getMenuBar(runtime: runtime) else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current, runtime: runtime.ax)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child, runtime: runtime.ax) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child, runtime: runtime.ax)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub, runtime: runtime.ax) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXGroupRole, identifier: "Arrangement", runtime: runtime.ax
        ) {
            return area
        }
        return AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Arrangement", runtime: runtime.ax
        )
    }

    // MARK: - Track Controls

    /// Find the mute button on a track header.
    static func findTrackMuteButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Mute", runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "M", runtime: runtime.ax)
    }

    /// Find the solo button on a track header.
    static func findTrackSoloButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Solo", runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "S", runtime: runtime.ax)
    }

    /// Find the record-arm button on a track header.
    static func findTrackArmButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findButtonByDescriptionPrefix(in: header, prefix: "Record", runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "R", runtime: runtime.ax)
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4, runtime: runtime.ax)
    }

    // MARK: - Helpers

    private static func findButtonByDescriptionPrefix(
        in element: AXUIElement,
        prefix: String,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button, runtime: runtime) else { return false }
            return desc.hasPrefix(prefix)
        }
    }
}
