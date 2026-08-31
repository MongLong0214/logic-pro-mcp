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

    enum PluginWindowMatch {
        case none
        case unique(AXUIElement)
        case ambiguous
        /// A candidate has the requested track and parameter control, but its
        /// direct static-text header does not prove the requested plug-in.
        /// `observedNames` is empty when those children exposed no readable
        /// values, which is deliberately not accepted as identity evidence.
        case pluginIdentityMismatch(observedNames: [String])
    }

    /// Resolve the display name of the track header at `index` (0-based), or nil
    /// when the header is absent / unnamed. The verified parameter write matches
    /// the open plugin window by this name (T0 evidence: a stock-effect plugin
    /// window's AX title is the TRACK name, not the plugin name).
    static func trackName(at index: Int, runtime: Runtime = .production) -> String? {
        guard let header = findTrackHeader(at: index, runtime: runtime) else { return nil }
        let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        guard track.liveIdentityBacked else { return nil }
        let trimmed = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func trackNames(runtime: Runtime = .production) -> [Int: String]? {
        let headers = allTrackHeaders(runtime: runtime)
        guard !headers.isEmpty else { return nil }
        var names: [Int: String] = [:]
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(
                from: header,
                index: index,
                runtime: runtime.ax
            )
            guard track.liveIdentityBacked else { return nil }
            let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            names[index] = name
        }
        return names
    }

    /// Find an OPEN plug-in editor whose title equals `trackName`, whose direct
    /// `AXStaticText` children name `pluginID` through the verified catalog's
    /// observed-name aliases, and which exposes exactly one matching slider.
    ///
    /// Measured for stock Logic editors only: their direct static-text children
    /// contain the English plug-in display name in both editor and Controls
    /// views, but its position varies and other labels are localized. Third-party
    /// editors and catalog/display-name differences remain unmeasured, so their
    /// observed names must resolve through `VerifiedPluginCatalog` rather than
    /// being accepted by raw string comparison.
    static func pluginWindowMatch(
        forTrackName trackName: String,
        matchingPluginID pluginID: String,
        matchingSliderDescription axDescription: String,
        runtime: Runtime = .production
    ) -> PluginWindowMatch {
        guard let app = appRoot(runtime: runtime) else { return .none }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        let target = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        var match: AXUIElement?
        var mismatchedObservedNames: [String] = []
        var foundMismatchedCandidate = false
        for window in windows {
            guard isPluginEditorWindow(window, runtime: runtime.ax) else { continue }
            guard AXHelpers.getRole(window, runtime: runtime.ax) == (kAXWindowRole as String) else { continue }
            let title = (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title == target else { continue }
            switch pluginWindowSliderMatch(in: window, axDescription: axDescription, runtime: runtime.ax) {
            case .none:
                continue
            case .ambiguous:
                return .ambiguous
            case .unique:
                let observedNames = pluginWindowHeaderStaticTextValues(in: window, runtime: runtime.ax)
                guard observedNames.contains(where: {
                    VerifiedPluginCatalog.pluginID(forObservedName: $0) == pluginID
                }) else {
                    foundMismatchedCandidate = true
                    mismatchedObservedNames.append(contentsOf: observedNames)
                    continue
                }
                guard match == nil else { return .ambiguous }
                match = window
            }
        }
        if let match {
            return .unique(match)
        }
        if foundMismatchedCandidate {
            return .pluginIdentityMismatch(observedNames: Array(Set(mismatchedObservedNames)).sorted())
        }
        return .none
    }

    /// Return only readable values of direct static-text children. Do not fall
    /// back to a title, a descendant, or a fixed child index: neither identifies
    /// the plug-in editor reliably.
    private static func pluginWindowHeaderStaticTextValues(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> [String] {
        AXHelpers.getChildren(window, runtime: runtime).compactMap { child in
            guard AXHelpers.getRole(child, runtime: runtime) == (kAXStaticTextRole as String),
                  let value = AXHelpers.getValue(child, runtime: runtime) as? String else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
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
        if case let .unique(slider) = pluginWindowSliderMatch(
            in: window,
            axDescription: axDescription,
            runtime: runtime
        ) {
            return slider
        }
        return nil
    }

    private enum PluginSliderMatch {
        case none
        case unique(AXUIElement)
        case ambiguous
    }

    private static func pluginWindowSliderMatch(
        in window: AXUIElement,
        axDescription: String,
        runtime: AXHelpers.Runtime
    ) -> PluginSliderMatch {
        let target = axDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return .none }
        let sliders = AXHelpers.findAllDescendants(
            of: window, role: kAXSliderRole, maxDepth: 4, runtime: runtime
        )
        let matches = sliders.filter { slider in
            let desc = (AXHelpers.getDescription(slider, runtime: runtime) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return desc.caseInsensitiveCompare(target) == .orderedSame
        }
        guard let first = matches.first else { return .none }
        return matches.count == 1 ? .unique(first) : .ambiguous
    }

}
