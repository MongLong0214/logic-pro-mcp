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

        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole, runtime: runtime.ax) {
            return toolbar
        }
        if let toolbar = AXHelpers.findDescendant(of: window, role: kAXToolbarRole, maxDepth: 6, runtime: runtime.ax),
           looksLikeTransportContainer(toolbar, runtime: runtime.ax) {
            return toolbar
        }
        if let group = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport", runtime: runtime.ax) {
            return group
        }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax)
        if let candidate = groups.first(where: { looksLikeTransportContainer($0, runtime: runtime.ax) }) {
            return candidate
        }

        return looksLikeTransportContainer(window, runtime: runtime.ax) ? window : nil
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
        // Contracted / test-path lookups first.
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXListRole, identifier: "Track Headers", runtime: runtime.ax
        ) {
            return area
        }
        if let area = AXHelpers.findDescendant(
            of: window, role: kAXScrollAreaRole, identifier: "Tracks", runtime: runtime.ax
        ) {
            return area
        }

        // Live Logic 12 commonly exposes the track header rail as AXGroup(desc: "트랙 헤더")
        // inside the left scroll area rather than as an AXList/AXOutline identifier.
        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax)
        if let headerGroup = groups.first(where: {
            let desc = (AXHelpers.getDescription($0, runtime: runtime.ax) ?? "").lowercased()
            return desc == "track headers" || desc == "트랙 헤더"
        }) {
            return headerGroup
        }

        if let outline = AXHelpers.findDescendant(of: window, role: kAXOutlineRole, maxDepth: 8, runtime: runtime.ax) {
            return outline
        }
        if let table = AXHelpers.findDescendant(of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime.ax) {
            return table
        }
        return nil
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        let rows = allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders(runtime: Runtime = .production) -> [AXUIElement] {
        guard let headers = getTrackHeaders(runtime: runtime) else { return [] }
        let directChildren = AXHelpers.getChildren(headers, runtime: runtime.ax)
        if !directChildren.isEmpty {
            if directChildren.contains(where: {
                (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXLayoutItemRole as String)
            }) {
                return directChildren.filter {
                    (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXLayoutItemRole as String)
                }
            }
            return directChildren
        }

        let layoutItems = AXHelpers.findAllDescendants(of: headers, role: kAXLayoutItemRole, maxDepth: 3, runtime: runtime.ax)
        if !layoutItems.isEmpty {
            return layoutItems
        }
        return []
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

    private static func looksLikeTransportContainer(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        let metadata = [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime)
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if metadata.contains("transport") || metadata.contains("control bar") || metadata.contains("컨트롤 막대") {
            return true
        }

        let transportKeywords = ["play", "stop", "record", "cycle", "loop", "metronome", "rewind", "forward", "재생", "녹음", "사이클", "메트로놈", "클릭"]
        let controls = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4, runtime: runtime)
            + AXHelpers.findAllDescendants(of: element, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime)
        let controlHits = controls.reduce(into: Set<String>()) { hits, control in
            let label = (
                AXHelpers.getDescription(control, runtime: runtime)
                    ?? AXHelpers.getTitle(control, runtime: runtime)
                    ?? ""
            ).lowercased()

            for keyword in transportKeywords where label.contains(keyword) {
                hits.insert(keyword)
            }
        }

        if controlHits.count >= 2 {
            return true
        }

        let sliderHits = AXHelpers.findAllDescendants(of: element, role: kAXSliderRole, maxDepth: 4, runtime: runtime).contains { slider in
            let description = AXHelpers.getDescription(slider, runtime: runtime)?.lowercased() ?? ""
            return description.contains("tempo")
                || description.contains("bpm")
                || description.contains("position")
                || description.contains("템포")
                || description.contains("재생헤드 위치")
                || description.contains("마디")
                || description.contains("비트")
        }

        let textRoles = [kAXStaticTextRole, kAXTextFieldRole]
        let textHits = textRoles.flatMap {
            AXHelpers.findAllDescendants(of: element, role: $0, maxDepth: 4, runtime: runtime)
        }.contains { text in
            let description = AXHelpers.getDescription(text, runtime: runtime)?.lowercased() ?? ""
            let value = (AXValueExtractors.extractTextValue(text, runtime: runtime) ?? "").lowercased()
            return description.contains("tempo")
                || description.contains("bpm")
                || description.contains("position")
                || description.contains("템포")
                || description.contains("재생헤드 위치")
                || value.contains(" bpm")
                || value.filter({ $0 == "." }).count >= 2
                || value.contains(":")
        }

        return (controlHits.count >= 1 && (textHits || sliderHits)) || sliderHits
    }
}
