import ApplicationServices
import Foundation


extension AXLogicProElements {
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
            if AXLocalePolicy.controlBarGroupLabel.matches(desc, mode: .exactStrict) {
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
            if AXLocalePolicy.barSliderLabel.matches(desc, mode: .exactStrict) {
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
                if AXLocalePolicy.tempoSliderLabel.matches(desc, mode: .exactStrict) {
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
            if AXLocalePolicy.beatSliderLabel.matches(desc, mode: .exactStrict) {
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

}
