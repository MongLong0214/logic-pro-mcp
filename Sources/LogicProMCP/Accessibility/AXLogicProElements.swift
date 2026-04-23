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

    /// Locate Logic Pro 12's control bar (컨트롤 막대 / Control Bar) — the AXGroup
    /// below the main arrange area that contains Play, Record, Cycle, Metronome,
    /// etc. as AXCheckBox widgets.
    static func getControlBar(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }

        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax)
        for group in groups {
            let desc = AXHelpers.getDescription(group, runtime: runtime.ax) ?? ""
            if desc == "컨트롤 막대" || desc.lowercased() == "control bar" {
                return group
            }
        }
        return nil
    }

    /// Find an AXCheckBox inside Logic Pro's control bar by its name.
    /// Common names (Korean): `녹음` (Record), `재생` (Play), `사이클` (Cycle),
    /// `카운트 인` (Count-in), `메트로놈 클릭` (Metronome).
    /// English equivalents are also attempted as a fallback.
    static func findControlBarCheckbox(
        named koreanName: String,
        englishName: String? = nil,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let checkboxes = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax
        )
        // Prefer title match (AXTitle) — which is what `name of` returns in AS
        for cb in checkboxes {
            let title = AXHelpers.getTitle(cb, runtime: runtime.ax) ?? ""
            if title == koreanName { return cb }
            if let en = englishName, title == en { return cb }
        }
        // Fallback: description match
        for cb in checkboxes {
            let desc = AXHelpers.getDescription(cb, runtime: runtime.ax) ?? ""
            if desc == koreanName { return cb }
            if let en = englishName, desc == en { return cb }
        }
        return nil
    }

    /// Find the 마디 (bar) slider in Logic Pro's control bar. Setting this
    /// slider's value moves the playhead to the given bar.
    static func findControlBarBarSlider(runtime: Runtime = .production) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let sliders = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax
        )
        for s in sliders {
            let desc = AXHelpers.getDescription(s, runtime: runtime.ax) ?? ""
            if desc == "마디" || desc.lowercased() == "bar" {
                return s
            }
        }
        return nil
    }

    /// Find the 템포 / Tempo slider in Logic's control bar. Double-clicking
    /// this slider opens an inline numeric-entry overlay (see
    /// AXMouseHelper.doubleClick for the exact interaction).
    ///
    /// Search order:
    ///   1. `getControlBar()` subtree (production path — AXGroup "컨트롤 막대")
    ///   2. `getTransportBar()` subtree (fallback — AXToolbar or "Transport" group)
    ///   3. Main window's entire slider descendants (last-resort, also covers
    ///      test doubles that build a minimal AX tree without the wrapper groups)
    static func findTempoSlider(runtime: Runtime = .production) -> AXUIElement? {
        let searchRoots: [AXUIElement] = [
            getControlBar(runtime: runtime),
            getTransportBar(runtime: runtime),
            mainWindow(runtime: runtime),
        ].compactMap { $0 }

        for root in searchRoots {
            let sliders = AXHelpers.findAllDescendants(
                of: root, role: kAXSliderRole, maxDepth: 8, runtime: runtime.ax
            )
            for s in sliders {
                let desc = (AXHelpers.getDescription(s, runtime: runtime.ax) ?? "").lowercased()
                if desc == "템포" || desc == "tempo" || desc == "bpm" {
                    return s
                }
            }
        }
        return nil
    }

    /// Find the 비트 (beat) slider in the control bar (optional — for sub-bar positioning).
    static func findControlBarBeatSlider(runtime: Runtime = .production) -> AXUIElement? {
        guard let controlBar = getControlBar(runtime: runtime) else { return nil }
        let sliders = AXHelpers.findAllDescendants(
            of: controlBar, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax
        )
        for s in sliders {
            let desc = AXHelpers.getDescription(s, runtime: runtime.ax) ?? ""
            if desc == "비트" || desc.lowercased() == "beat" {
                return s
            }
        }
        return nil
    }

    /// Read the current value (0/1) of a control-bar checkbox. Returns nil if
    /// the element can't be located or its value is not readable.
    static func readControlBarCheckboxValue(
        named koreanName: String,
        englishName: String? = nil,
        runtime: Runtime = .production
    ) -> Bool? {
        guard let cb = findControlBarCheckbox(
            named: koreanName, englishName: englishName, runtime: runtime
        ) else { return nil }
        if let n: NSNumber = AXHelpers.getAttribute(cb, kAXValueAttribute, runtime: runtime.ax) {
            return n.boolValue
        }
        if let b: Bool = AXHelpers.getAttribute(cb, kAXValueAttribute, runtime: runtime.ax) {
            return b
        }
        return nil
    }

    // MARK: - Tracks

    /// Returns true when Logic's main window is the Choose Project picker
    /// (shown when no project is open). Any AXOutline/AXTable inside the picker
    /// describes template choices, NOT tracks — misidentifying them yields
    /// bogus resource payloads and rename/mute ops that silently fail.
    static func isProjectPickerWindow(_ window: AXUIElement, runtime: Runtime) -> Bool {
        let title = (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "").lowercased()
        let pickerMarkers = ["프로젝트 선택", "choose a project", "choose project", "new from template"]
        return pickerMarkers.contains { title.contains($0) }
    }

    /// Find the track header area containing individual track rows.
    static func getTrackHeaders(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        if isProjectPickerWindow(window, runtime: runtime) { return nil }
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
    /// Locate the AXOutline containing the track list. v3.0.3 — used by
    /// set_instrument for AX-native track selection (bypasses the coordinate-
    /// based track header click which fails for off-viewport tracks).
    static func findTrackOutline(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        let outlines = AXHelpers.findAllDescendants(
            of: window, role: "AXOutline", maxDepth: 12, runtime: runtime.ax
        )
        for o in outlines {
            var rowsRaw: AnyObject?
            _ = AXUIElementCopyAttributeValue(o, "AXRows" as CFString, &rowsRaw)
            if let rows = rowsRaw as? [AXUIElement], !rows.isEmpty {
                // Pick the outline whose rows expose AXDisclosureLevel (track list
                // hallmark — other outlines like Library browser don't).
                var attrs: CFArray?
                AXUIElementCopyAttributeNames(rows[0], &attrs)
                if (attrs as? [String])?.contains("AXDisclosureLevel") == true {
                    return o
                }
            }
        }
        return nil
    }

    static func findTrackHeader(at index: Int, runtime: Runtime = .production) -> AXUIElement? {
        let rows = allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < rows.count else { return nil }
        return rows[index]
    }

    /// Select a track using Apple's standard AX API before falling back to
    /// synthesised mouse input. v3.0.9 breakthrough — Logic Pro 12 exposes the
    /// track-header rail as an `AXGroup` whose `AXSelectedChildren` attribute
    /// IS the project's authoritative track-selection input. This mirrors the
    /// AX pattern that already works for Library preset selection (v3.0.3):
    /// `SetAttr(parent, AXSelectedChildren, [targetChild])`.
    ///
    /// Prior versions (v3.0.3–v3.0.8) tried `AXPress` on the track header as
    /// step 1; `AXUIElementPerformAction` returned `.success` vacuously even
    /// though the header's only declared action is `AXShowMenu`, so the ladder
    /// exited early with a FALSE POSITIVE and selection never moved. That
    /// cascaded into `set_instrument` always loading onto whatever track was
    /// actually selected (usually index 0) regardless of the `index` param.
    ///
    /// The fix is a single AX write to the parent group. Fallbacks are kept
    /// for test doubles that expose the track-header structure without a
    /// writable `AXSelectedChildren` (and for extreme Logic build drift).
    ///
    /// Returns true when the set succeeded OR a fallback committed the
    /// selection (verified by the caller's `verifyTrackSelection`).
    static func selectTrackViaAX(
        at index: Int,
        runtime: Runtime = .production
    ) -> Bool {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return false }

        // Step 1 (v3.0.9 primary path) — AXSelectedChildren on parent group.
        // This is the one mechanism that ACTUALLY moves Logic's track selection
        // (live-verified: 10/10 indices on a 10-track project). Every other AX
        // action on the track header is a no-op for selection purposes.
        if let headersGroup = getTrackHeaders(runtime: runtime) {
            let arr = [header] as CFArray
            let r = AXUIElementSetAttributeValue(
                headersGroup,
                kAXSelectedChildrenAttribute as CFString,
                arr
            )
            if r == .success { return true }
        }

        // Step 2 — NSTableRow-style AXSelected=true (test-double path).
        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(header, "AXSelected" as CFString, &isSettable)
        if isSettable.boolValue {
            let r = AXUIElementSetAttributeValue(header, "AXSelected" as CFString, kCFBooleanTrue)
            if r == .success { return true }
        }

        // Step 3 — AXPress on the header itself (test doubles that expose it).
        if AXHelpers.performAction(header, kAXPressAction, runtime: runtime.ax) {
            return true
        }

        // Step 4 — child AXPress (some rows expose a selectable name label).
        for child in AXHelpers.getChildren(header, runtime: runtime.ax) {
            if AXHelpers.performAction(child, kAXPressAction, runtime: runtime.ax) {
                return true
            }
        }

        // Step 5 — last resort: coord click at the header's name area.
        var posRaw: AnyObject?
        var sizeRaw: AnyObject?
        guard
            AXUIElementCopyAttributeValue(header, kAXPositionAttribute as CFString, &posRaw) == .success,
            AXUIElementCopyAttributeValue(header, kAXSizeAttribute as CFString, &sizeRaw) == .success,
            let pr = posRaw, CFGetTypeID(pr) == AXValueGetTypeID(),
            let sr = sizeRaw, CFGetTypeID(sr) == AXValueGetTypeID()
        else { return false }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue((pr as! AXValue), .cgPoint, &pt)
        AXValueGetValue((sr as! AXValue), .cgSize, &sz)
        let clickPoint = CGPoint(x: pt.x + min(60, sz.width / 4), y: pt.y + sz.height / 2)
        return LibraryAccessor.productionMouseClick(at: clickPoint)
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
    /// Logic Pro 12 uses an `AXCheckBox` with description `녹음 활성화` (KR) or
    /// `Record Enable` (EN) inside each track header.
    static func findTrackArmButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        // Logic 12: per-track record-enable is an AXCheckBox
        let checkboxes = AXHelpers.findAllDescendants(
            of: header, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax
        )
        for cb in checkboxes {
            let desc = AXHelpers.getDescription(cb, runtime: runtime.ax) ?? ""
            if desc == "녹음 활성화" || desc == "Record Enable" || desc == "Record" {
                return cb
            }
        }
        // Legacy fallback: AXButton with description / title
        return findButtonByDescriptionPrefix(in: header, prefix: "Record", runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "R", runtime: runtime.ax)
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4, runtime: runtime.ax)
    }

    // MARK: - Markers

    /// Defensive upper bound on AX marker enumeration. Logic projects in the
    /// wild rarely exceed a few dozen markers; this cap keeps the AX traversal
    /// cost predictable even for pathological 10k-marker compositions.
    private static let markerLimit = 512

    /// Enumerate markers visible in the arrangement area's marker ruler.
    /// Logic Pro 12 renders the marker ruler as a row of AXStaticText elements
    /// (or AXGroup children) whose title/description contains the marker name.
    /// Position is extracted from the AXDescription or AXValue when available.
    static func enumerateMarkers(
        in arrangementArea: AXUIElement,
        runtime: Runtime = .production
    ) -> [MarkerState] {
        let markerKeywords = ["marker", "마커"]
        let groups = AXHelpers.findAllDescendants(
            of: arrangementArea, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax
        )
        var rulerElement: AXUIElement? = nil
        for group in groups {
            let id = AXHelpers.getIdentifier(group, runtime: runtime.ax)?.lowercased() ?? ""
            let desc = AXHelpers.getDescription(group, runtime: runtime.ax)?.lowercased() ?? ""
            let title = AXHelpers.getTitle(group, runtime: runtime.ax)?.lowercased() ?? ""
            let combined = "\(id) \(desc) \(title)"
            if markerKeywords.contains(where: { combined.contains($0) }) {
                rulerElement = group
                break
            }
        }
        guard let ruler = rulerElement else { return [] }

        let texts = AXHelpers.findAllDescendants(
            of: ruler, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax
        )
        var markers: [MarkerState] = []
        markers.reserveCapacity(min(texts.count, markerLimit))
        for (index, text) in texts.prefix(markerLimit).enumerated() {
            let name = AXHelpers.getTitle(text, runtime: runtime.ax)
                ?? AXHelpers.getDescription(text, runtime: runtime.ax)
                ?? axValueAsName(text, runtime: runtime.ax)
                ?? ""
            guard !name.isEmpty else { continue }
            let position = extractMarkerPosition(text, runtime: runtime.ax)
            markers.append(MarkerState(id: index, name: name, position: position ?? "\(index + 1).1.1.1"))
        }
        return markers
    }

    private static func axValueAsName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let v = AXValueExtractors.extractTextValue(element, runtime: runtime),
              !v.isEmpty, !looksLikeBarPosition(v) else { return nil }
        return v
    }

    private static func extractMarkerPosition(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let candidates = [
            AXValueExtractors.extractTextValue(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
        ]
        for candidate in candidates {
            guard let raw = candidate, !raw.isEmpty else { continue }
            if looksLikeBarPosition(raw) { return raw }
        }
        return nil
    }

    private static func looksLikeBarPosition(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 1, parts.count <= 4 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
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
