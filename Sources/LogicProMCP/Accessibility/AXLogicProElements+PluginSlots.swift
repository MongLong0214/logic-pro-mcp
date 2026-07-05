import ApplicationServices
import Foundation


extension AXLogicProElements {
    static func pluginSlots(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [PluginSlotState] {
        var plugins: [PluginSlotState] = []
        for child in AXHelpers.getChildren(strip, runtime: runtime) {
            guard let name = occupiedPluginSlotName(child, runtime: runtime) else {
                continue
            }
            plugins.append(PluginSlotState(
                index: plugins.count,
                name: name,
                isBypassed: pluginSlotBypassState(child, runtime: runtime) ?? false
            ))
        }
        return plugins
    }

    /// Read state of an insert slot, kept SEPARATE from `name` so an occupied
    /// slot whose name could not be read is never mistaken for an empty one
    /// (rev-4 D4). Raw values double as the public `get_inventory.read_status`
    /// strings ("empty"/"ok"/"unreadable") per requirements R3.
    enum SlotReadStatus: String, Sendable, Equatable {
        case empty
        case occupiedReadable = "ok"
        case occupiedUnreadable = "unreadable"
    }

    struct PluginInsertSlot {
        /// PHYSICAL slot position. Preserved across unreadable occupied slots
        /// so an explicit `insert: N` always addresses the same physical slot
        /// (rev-4 D1 — drift fix).
        let index: Int
        let element: AXUIElement
        let name: String?
        let isBypassed: Bool?
        let readStatus: SlotReadStatus

        var occupied: Bool { readStatus != .empty }

        /// "Safe to write into" — true ONLY for a verified-empty slot. An
        /// occupied slot whose name is unreadable returns false so the legacy
        /// `insert_plugin` occupied-slot guard cannot silently overwrite it
        /// (rev-4 D4 / AC21). Do NOT reduce this back to `name == nil`.
        var isEmpty: Bool { readStatus == .empty }
    }

    /// Enumerate a strip's audio-plugin insert slots WITHOUT dropping any slot.
    ///
    /// rev-4 D1: the previous implementation `continue`d past an occupied slot
    /// whose name was unreadable and renumbered with `slots.count`, so a
    /// physical insert 3 could be reported as insert 2. Now every recognised
    /// slot — empty, occupied-readable, occupied-unreadable — keeps its
    /// physical position; only non-slot children (fader / pan / sends / I/O)
    /// are skipped, which never shifts a slot index relative to other slots.
    static func audioPluginInsertSlots(
        in strip: AXUIElement,
        runtime: AXHelpers.Runtime = .production
    ) -> [PluginInsertSlot] {
        var slots: [PluginInsertSlot] = []
        let children = AXHelpers.getChildren(strip, runtime: runtime)
        for (offset, child) in children.enumerated() {
            if isEmptyAudioPluginSlot(child, siblings: children, offset: offset, runtime: runtime) {
                slots.append(PluginInsertSlot(
                    index: slots.count,
                    element: child,
                    name: nil,
                    isBypassed: nil,
                    readStatus: .empty
                ))
            } else if isOccupiedPluginSlotElement(child, runtime: runtime) {
                // Slot position is confirmed by structure (bypass + open/menu
                // children); the name may still be unreadable.
                let name = pluginSlotDisplayName(child, runtime: runtime)
                slots.append(PluginInsertSlot(
                    index: slots.count,
                    element: child,
                    name: name,
                    isBypassed: pluginSlotBypassState(child, runtime: runtime),
                    readStatus: name == nil ? .occupiedUnreadable : .occupiedReadable
                ))
            }
            // else: not an insert slot — skip without consuming an index.
        }
        return slots
    }

    // internal (not private): called cross-file from the +Mixer extension (WS3 AC1 split).
    static func sliderText(
        _ slider: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> (text: String, isVolumeFader: Bool, isPanControl: Bool) {
        let text = elementSearchText(slider, runtime: runtime)
        let isSend = AXLocalePolicy.sliderSendHint.containsAny(in: text)
        let isZoom = AXLocalePolicy.sliderZoomHint.containsAny(in: text)
        let isVolume = !isSend && !isZoom && AXLocalePolicy.sliderVolumeHint.containsAny(in: text)
        let isPan = !isSend && !isZoom && AXLocalePolicy.sliderPanHint.containsAny(in: text)
        return (text, isVolume, isPan)
    }

    /// Structural predicate: is this element an OCCUPIED audio-plugin insert
    /// slot, regardless of whether its name can be read? An occupied slot is an
    /// AXGroup carrying both a bypass control and an open/menu control. Split
    /// out of `occupiedPluginSlotName` (rev-4 D4) so the enumerator can mark a
    /// slot occupied-but-unreadable instead of dropping it.
    static func isOccupiedPluginSlotElement(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXGroupRole as String) else {
            return false
        }
        let children = AXHelpers.getChildren(element, runtime: runtime)
        let hasBypass = children.contains { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginBypassControl.containsAny(in: text)
        }
        let hasOpenOrMenu = children.contains { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginOpenOrListControl.containsAny(in: text)
        }
        if hasBypass && hasOpenOrMenu {
            return true
        }
        // Locale-neutral fallback: Logic's occupied insert row is a short group
        // containing one bypass checkbox plus two action buttons (open + list).
        // This avoids depending on localized child descriptions such as
        // "바이패스"/"열기"/"목록"; the automation row has only one button and
        // is therefore not promoted.
        return isLanguageNeutralOccupiedPluginSlotElement(element, runtime: runtime)
    }

    /// Extract a usable plugin display name from an occupied slot group, or nil
    /// if the description is missing or is an automation-mode label (not a
    /// plugin name). Returning nil means "occupied but unreadable".
    static func pluginSlotDisplayName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let description = AXHelpers.getDescription(element, runtime: runtime)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return nil
        }
        let lower = description.lowercased()
        guard !AXLocalePolicy.pluginAutomationLabelExact.matches(lower, mode: .exactStrict),
              !AXLocalePolicy.pluginAutomationLabelSubstring.containsAny(in: lower) else {
            return nil
        }
        return description
    }

    /// Name of an occupied plugin slot, or nil if the element is not an
    /// occupied slot or its name is unreadable. Preserved as the composition of
    /// the structural predicate + name extractor so the wire-path `pluginSlots`
    /// enumerator keeps its exact prior behaviour (occupied-readable only).
    private static func occupiedPluginSlotName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard isOccupiedPluginSlotElement(element, runtime: runtime) else {
            return nil
        }
        return pluginSlotDisplayName(element, runtime: runtime)
    }

    private static func isEmptyAudioPluginSlot(
        _ element: AXUIElement,
        siblings: [AXUIElement],
        offset: Int,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXButtonRole as String) else {
            return false
        }
        // Logic Pro 12.2 exposes a short (~9 px) "Audio Plug-in" button at the
        // bottom of some strips. Live E2E showed that it is an add/append affordance
        // rather than an addressable insert row: clicking it mounts into a different
        // real slot. When AXSize is available, exclude these short stubs so
        // `insert:N` only names rows that can actually be targeted.
        if let size = AXHelpers.getSize(element, runtime: runtime),
           size.height > 0, size.height < 12 {
            return false
        }
        let text = elementSearchText(element, runtime: runtime)
        let isAudioSlot = AXLocalePolicy.audioPluginSlotLabel.containsAny(in: text)
        let isSendOrIO = AXLocalePolicy.sendOrIOControlLabel.containsAny(in: text)
        if isAudioSlot && !isSendOrIO {
            return true
        }
        return isLanguageNeutralEmptyAudioPluginSlot(
            element, siblings: siblings, offset: offset, runtime: runtime
        )
    }

    private static func pluginSlotBypassState(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool? {
        let children = AXHelpers.getChildren(element, runtime: runtime)
        guard let bypass = children.first(where: { child in
            let text = elementSearchText(child, runtime: runtime)
            return AXLocalePolicy.pluginBypassControl.containsAny(in: text)
        }) ?? children.first(where: { child in
            (AXHelpers.getRole(child, runtime: runtime) ?? "") == (kAXCheckBoxRole as String)
        }) else {
            return nil
        }
        return AXValueExtractors.extractButtonState(bypass, runtime: runtime)
    }

    private static func isLanguageNeutralOccupiedPluginSlotElement(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard pluginSlotFrame(element, runtime: runtime) != nil else { return false }
        let children = AXHelpers.getChildren(element, runtime: runtime)
        let hasCheckbox = children.contains {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXCheckBoxRole as String)
        }
        let buttonCount = children.filter {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXButtonRole as String)
        }.count
        return hasCheckbox && buttonCount >= 2
    }

    private static func isLanguageNeutralEmptyAudioPluginSlot(
        _ element: AXUIElement,
        siblings: [AXUIElement],
        offset: Int,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard languageNeutralEmptySlotCandidate(element, runtime: runtime),
              let frame = pluginSlotFrame(element, runtime: runtime) else {
            return false
        }

        var clusterCount = 1
        var cursor = offset - 1
        var lastFrame = frame
        while cursor >= 0,
              let other = pluginSlotFrame(siblings[cursor], runtime: runtime),
              languageNeutralEmptySlotCandidate(siblings[cursor], runtime: runtime),
              pluginSlotFramesAlign(frame, other),
              pluginSlotFramesAreAdjacent(lastFrame, other) {
            clusterCount += 1
            lastFrame = other
            cursor -= 1
        }
        cursor = offset + 1
        lastFrame = frame
        while cursor < siblings.count,
              let other = pluginSlotFrame(siblings[cursor], runtime: runtime),
              languageNeutralEmptySlotCandidate(siblings[cursor], runtime: runtime),
              pluginSlotFramesAlign(frame, other),
              pluginSlotFramesAreAdjacent(lastFrame, other) {
            clusterCount += 1
            lastFrame = other
            cursor += 1
        }
        if clusterCount >= 3 {
            return true
        }

        for neighborOffset in [offset - 1, offset + 1] where siblings.indices.contains(neighborOffset) {
            let neighbor = siblings[neighborOffset]
            guard isLanguageNeutralOccupiedPluginSlotElement(neighbor, runtime: runtime),
                  let neighborFrame = pluginSlotFrame(neighbor, runtime: runtime),
                  pluginSlotFramesAlign(frame, neighborFrame),
                  pluginSlotFramesAreAdjacent(frame, neighborFrame) else {
                continue
            }
            return true
        }
        return false
    }

    private static func languageNeutralEmptySlotCandidate(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXButtonRole as String),
              pluginSlotFrame(element, runtime: runtime) != nil else {
            return false
        }
        let subrole: String? = AXHelpers.getAttribute(
            element, kAXSubroleAttribute as String, runtime: runtime
        )
        guard subrole != (kAXSwitchSubrole as String) else { return false }
        guard AXHelpers.getChildren(element, runtime: runtime).isEmpty else { return false }
        return !isKnownNonInsertButtonText(elementSearchText(element, runtime: runtime))
    }

    private static func pluginSlotFrame(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CGRect? {
        guard let position = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime),
              size.width >= 44,
              size.height >= 12,
              size.height <= 24 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pluginSlotFramesAlign(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 3
            && abs(lhs.width - rhs.width) <= 3
            && abs(lhs.height - rhs.height) <= 6
    }

    private static func pluginSlotFramesAreAdjacent(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minY - rhs.minY) <= max(lhs.height, rhs.height) + 6
    }

    private static func isKnownNonInsertButtonText(_ text: String) -> Bool {
        AXLocalePolicy.nonInsertButtonText.containsAny(in: text)
    }

    // internal (not private): called cross-file from the core AXLogicProElements
    // window classifiers and the +Mixer extension (WS3 AC1 split).
    static func elementSearchText(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String {
        [
            AXHelpers.getIdentifier(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
            AXHelpers.getTitle(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    // MARK: - Plugin Windows (verified parameter write — T5)

    /// Resolve the display name of the track header at `index` (0-based), or nil
    /// when the header is absent / unnamed. The verified parameter write matches
    /// the open plugin window by this name (T0 evidence: a stock-effect plugin
    /// window's AX title is the TRACK name, not the plugin name).
    static func trackName(at index: Int, runtime: Runtime = .production) -> String? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        let name = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax).name
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // `extractTrackState` falls back to "Untitled" when no name is readable;
        // treat that as "no resolvable name" rather than a window-title match key.
        guard !trimmed.isEmpty, trimmed != "Untitled" else { return nil }
        return trimmed
    }

    /// Find an OPEN plugin window whose AX title equals `trackName` AND which
    /// exposes a 1-level `AXSlider` matching `axDescription`. T0 evidence: a
    /// stock-effect plugin window is a separate `AXWindow`/`AXDialog` titled with
    /// the track name; its parameter controls are flat `AXSlider`s at the
    /// window's first child level, and only `AXDescription` is a stable matcher.
    ///
    /// Returns nil when no such window is open (the caller then attempts to open
    /// one, or fails closed). Both the title match and the slider presence are
    /// required so an unrelated same-titled window is never mistaken for the
    /// plugin window.
    static func openPluginWindow(
        forTrackName trackName: String,
        matchingSliderDescription axDescription: String,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        guard let app = appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        let target = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        for window in windows {
            let title = (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title == target else { continue }
            if pluginWindowSlider(in: window, axDescription: axDescription, runtime: runtime.ax) != nil {
                return window
            }
        }
        return nil
    }

    /// Find the parameter `AXSlider` inside a plugin window by its
    /// `AXDescription` (T0 evidence: the ONLY stable identifier — `AXIdentifier`
    /// is an unstable NSView id, and unnamed params share the locale word for
    /// "slider"). Matches against the window's slider descendants; the match is
    /// case-insensitive on the trimmed description.
    static func pluginWindowSlider(
        in window: AXUIElement,
        axDescription: String,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        let target = axDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let sliders = AXHelpers.findAllDescendants(
            of: window, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        return sliders.first { slider in
            let desc = (AXHelpers.getDescription(slider, runtime: runtime) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return desc.caseInsensitiveCompare(target) == .orderedSame
        }
    }

}
