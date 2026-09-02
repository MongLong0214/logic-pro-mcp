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
        /// A required candidate-window observation failed. This is not an
        /// empty census: another editor may exist behind the unreadable AX
        /// boundary, so choosing a visible candidate would be unsound.
        case unreadable(AXHelpers.AXStatusError)
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

    /// Find an OPEN plug-in editor whose title equals `trackName` and whose
    /// direct `AXStaticText` children contain a plug-in name for `pluginID`
    /// through the verified catalog's observed-name aliases. A slider
    /// description can corroborate that binding or, when explicitly required,
    /// additionally constrain it.
    ///
    /// Measured for stock Logic editors only: their direct static-text children
    /// contain the English plug-in display name in both editor and Controls
    /// views, but its position varies and other labels are localized. The AX
    /// title and one direct static-text value are the *track* name, so that
    /// value is excluded before catalog lookup. Third-party editors and
    /// catalog/display-name differences remain unmeasured, so their observed
    /// names must resolve through `VerifiedPluginCatalog` rather than being
    /// accepted by raw string comparison.
    static func pluginWindowMatch(
        forTrackName trackName: String,
        matchingPluginID pluginID: String,
        matchingSliderDescription axDescription: String?,
        requiringMatchingSlider: Bool = true,
        runtime: Runtime = .production
    ) -> PluginWindowMatch {
        let target = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        var match: AXUIElement?
        var mismatchedObservedNames: [String] = []
        var foundMismatchedCandidate = false
        let candidates: [PluginEditorWindowCandidate]
        switch pluginEditorWindowCandidates(runtime: runtime) {
        case let .success(observed):
            candidates = observed
        case let .failure(error):
            return .unreadable(error)
        }
        for candidate in candidates {
            guard candidate.title == target else { continue }
            let observedNames: [String]
            switch pluginWindowHeaderStaticTextValues(in: candidate, runtime: runtime.ax) {
            case let .success(observed):
                observedNames = observed
            case let .failure(error):
                return .unreadable(error)
            }
            let headerMatchesPlugin = pluginWindowHeaderNames(
                observedNames,
                containPluginID: pluginID,
                excludingTrackName: candidate.title,
                callerTrackName: target
            )
            let sliderWitness: Result<PluginSliderMatch, AXHelpers.AXStatusError>? = axDescription.map {
                pluginWindowSliderMatchResult(
                    in: candidate.element,
                    axDescription: $0,
                    runtime: runtime.ax
                )
            }
            guard headerMatchesPlugin else {
                // A header-only binding has no parameter precondition: the
                // requested track title plus catalog-resolved header identity
                // are sufficient to refuse a same-track wrong editor. For the
                // legacy slider path, retain the narrower diagnostic rule.
                if !requiringMatchingSlider {
                    foundMismatchedCandidate = true
                    mismatchedObservedNames.append(contentsOf: observedNames)
                    continue
                }
                switch sliderWitness {
                case .some(.success(.ambiguous)):
                    return .ambiguous
                case .some(.success(.unique)):
                    foundMismatchedCandidate = true
                    mismatchedObservedNames.append(contentsOf: observedNames)
                    continue
                case .some(.success(.none)), nil:
                    continue
                case let .some(.failure(error)):
                    return .unreadable(error)
                }
            }
            // Header identity always selects the candidate. A slider witness
            // is mandatory only for the native-editor parameter path; Controls
            // view deliberately removes descriptions from its sliders.
            if requiringMatchingSlider {
                switch sliderWitness {
                case .some(.success(.none)), nil:
                    continue
                case .some(.success(.ambiguous)):
                    return .ambiguous
                case .some(.success(.unique)):
                    break
                case let .some(.failure(error)):
                    return .unreadable(error)
                }
            }
            guard match == nil else { return .ambiguous }
            match = candidate.element
        }
        if let match {
            return .unique(match)
        }
        if foundMismatchedCandidate {
            return .pluginIdentityMismatch(observedNames: Array(Set(mismatchedObservedNames)).sorted())
        }
        return .none
    }

    /// Return every OPEN plug-in editor whose title identifies `trackName` and
    /// whose direct static-text header maps to `pluginID`. This deliberately
    /// does not require a parameter control: duplicate-insert acquisition uses
    /// it to prove which editor the slot's open control created *before* the
    /// parameter-specific slider match runs.
    ///
    /// The same direct-header rule as `pluginWindowMatch` is retained here; a
    /// window title, descendant text, or geometry is not evidence of plug-in
    /// identity. The direct static-text value equal to the window title is the
    /// track name and is explicitly not a plug-in-name candidate.
    static func matchingPluginEditorWindows(
        forTrackName trackName: String,
        matchingPluginID pluginID: String,
        runtime: Runtime = .production
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        let target = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [PluginEditorWindowCandidate]
        switch pluginEditorWindowCandidates(runtime: runtime) {
        case let .success(observed):
            candidates = observed
        case let .failure(error):
            return .failure(error)
        }
        var matches: [AXUIElement] = []
        for candidate in candidates where candidate.title == target {
            let observedNames: [String]
            switch pluginWindowHeaderStaticTextValues(in: candidate, runtime: runtime.ax) {
            case let .success(observed):
                observedNames = observed
            case let .failure(error):
                return .failure(error)
            }
            if pluginWindowHeaderNames(
                observedNames,
                containPluginID: pluginID,
                excludingTrackName: candidate.title,
                callerTrackName: target
            ) {
                matches.append(candidate.element)
            }
        }
        return .success(matches)
    }

    /// Every currently open plug-in editor window. Duplicate-instance
    /// acquisition snapshots this before it presses an insert control, then
    /// requires its accepted candidate to be a newly observed AX element.
    static func pluginEditorWindows(
        runtime: Runtime = .production
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        pluginEditorWindowCandidates(runtime: runtime).map { $0.map(\.element) }
    }

    /// Whether the exact AX window element remains in the application's
    /// observed window list. `nil` means the list itself could not be read, so
    /// a caller must not claim that a close was observed.
    static func pluginEditorWindowIsOpen(
        _ window: AXUIElement,
        runtime: Runtime = .production
    ) -> Bool? {
        guard let app = appRoot(runtime: runtime),
              let windows: [AXUIElement] = AXHelpers.getAttribute(
                  app, kAXWindowsAttribute, runtime: runtime.ax
              ) else {
            return nil
        }
        return windows.contains { CFEqual($0, window) }
    }

    private static func pluginWindowHeaderNames(
        _ observedNames: [String],
        containPluginID pluginID: String,
        excludingTrackName title: String,
        callerTrackName target: String
    ) -> Bool {
        observedNames.contains { observedName in
            // Logic exposes the track name in both AXTitle and a direct static
            // text child. A track called "Compressor" must not authenticate a
            // Noise Gate window as Compressor merely because both have a
            // Threshold slider. Keep both values here: the caller-resolved
            // track name is a second defense if Logic normalizes AXTitle.
            guard observedName != title, observedName != target else { return false }
            return VerifiedPluginCatalog.pluginID(forObservedName: observedName) == pluginID
        }
    }

    private struct PluginEditorWindowCandidate {
        let element: AXUIElement
        let title: String
        let directChildren: [(element: AXUIElement, role: String?)]
    }

    /// Enumerate only windows whose plugin-editor classification was fully
    /// observed. `noValue` and `attributeUnsupported` are observations that an
    /// optional AX field is absent, so they classify as no windows / no
    /// children / no matching field. Any other failed status is returned to
    /// the caller: a choice cannot safely discard an editor whose
    /// classification could not be completed.
    private static func pluginEditorWindowCandidates(
        runtime: Runtime
    ) -> Result<[PluginEditorWindowCandidate], AXHelpers.AXStatusError> {
        guard let app = appRoot(runtime: runtime) else { return .success([]) }
        let windows: [AXUIElement]
        switch AXHelpers.getAXUIElementArrayRead(
            app,
            kAXWindowsAttribute as String,
            runtime: runtime.ax
        ) {
        case let .success(.elements(observed)):
            windows = observed
        case .success(.absent):
            // The AX attribute answered absent, which is an observed empty
            // census rather than a failed enumeration.
            windows = []
        case .success(.malformed):
            return .failure(.malformedAttribute)
        case let .failure(error) where error.isDefinitiveAbsence:
            // `AXWindows` is absent when there are no windows to enumerate;
            // that is an observed empty census, not an unreadable one.
            windows = []
        case let .failure(error):
            return .failure(error)
        }

        var candidates: [PluginEditorWindowCandidate] = []
        for window in windows {
            let subrole: String?
            switch AXHelpers.getAttributeResult(
                window,
                kAXSubroleAttribute as String,
                runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                subrole = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                subrole = nil
            case let .failure(error):
                return .failure(error)
            }
            guard subrole == (kAXDialogSubrole as String) else { continue }

            let closeButton: AXUIElement?
            switch AXHelpers.getAttributeResult(
                window,
                kAXCloseButtonAttribute as String,
                runtime: runtime.ax
            ) as Result<AXUIElement?, AXHelpers.AXStatusError> {
            case let .success(observed):
                closeButton = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                closeButton = nil
            case let .failure(error):
                return .failure(error)
            }
            guard closeButton != nil else { continue }

            let children: [AXUIElement]
            switch AXHelpers.childrenResult(window, runtime: runtime.ax) {
            case let .success(observed):
                children = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                children = []
            case let .failure(error):
                return .failure(error)
            }
            var directChildren: [(element: AXUIElement, role: String?)] = []
            for child in children {
                let role: String?
                switch AXHelpers.getAttributeResult(
                    child,
                    kAXRoleAttribute as String,
                    runtime: runtime.ax
                ) as Result<String?, AXHelpers.AXStatusError> {
                case let .success(observed):
                    role = observed
                case let .failure(error) where error.isDefinitiveAbsence:
                    role = nil
                case let .failure(error):
                    return .failure(error)
                }
                directChildren.append((child, role))
            }
            let hasBypass: Bool
            do {
                var found = false
                for child in directChildren where child.role == (kAXCheckBoxRole as String)
                    || child.role == (kAXButtonRole as String) {
                    switch hasExactLabelResult(
                        child.element,
                        matching: AXLocalePolicy.pluginBypassControl,
                        runtime: runtime.ax
                    ) {
                    case let .success(matches):
                        found = found || matches
                    case let .failure(error):
                        throw error
                    }
                }
                hasBypass = found
            } catch let error as AXHelpers.AXStatusError {
                return .failure(error)
            } catch {
                return .failure(.malformedAttribute)
            }
            guard hasBypass else { continue }

            let role: String?
            switch AXHelpers.getAttributeResult(
                window,
                kAXRoleAttribute as String,
                runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                role = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                role = nil
            case let .failure(error):
                return .failure(error)
            }
            guard role == (kAXWindowRole as String) else { continue }

            let title: String?
            switch AXHelpers.getAttributeResult(
                window,
                kAXTitleAttribute as String,
                runtime: runtime.ax
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                title = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                title = nil
            case let .failure(error):
                return .failure(error)
            }
            candidates.append(PluginEditorWindowCandidate(
                element: window,
                title: (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                directChildren: directChildren
            ))
        }
        return .success(candidates)
    }

    /// Status-preserving exact-label matcher used only while a window is being
    /// classified for an imminent selection. An absent label field is a normal
    /// non-match; a failed read is never silently converted to one.
    private static func hasExactLabelResult(
        _ element: AXUIElement,
        matching labelSet: AXLocalePolicy.LabelSet,
        runtime: AXHelpers.Runtime
    ) -> Result<Bool, AXHelpers.AXStatusError> {
        for attribute in [
            kAXIdentifierAttribute as String,
            kAXDescriptionAttribute as String,
            kAXTitleAttribute as String,
            kAXHelpAttribute as String,
        ] {
            let value: String?
            switch AXHelpers.getAttributeResult(
                element,
                attribute,
                runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                value = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                value = nil
            case let .failure(error):
                return .failure(error)
            }
            if labelSet.matches(value, mode: .exactStrict) {
                return .success(true)
            }
        }
        return .success(false)
    }

    /// Return direct static-text values without falling back to a title,
    /// descendant, or fixed child index. An absent AXValue is no header name;
    /// every other failed header read refuses the caller's window choice.
    private static func pluginWindowHeaderStaticTextValues(
        in candidate: PluginEditorWindowCandidate,
        runtime: AXHelpers.Runtime
    ) -> Result<[String], AXHelpers.AXStatusError> {
        var values: [String] = []
        for child in candidate.directChildren where child.role == (kAXStaticTextRole as String) {
            let value: String?
            switch AXHelpers.getAttributeResult(
                child.element,
                kAXValueAttribute as String,
                runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                value = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                value = nil
            case let .failure(error):
                return .failure(error)
            }
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty {
                values.append(trimmed)
            }
        }
        return .success(values)
    }

    /// Find the parameter `AXSlider` inside a plugin window by its
    /// `AXDescription` (T0 evidence: the ONLY stable identifier — `AXIdentifier`
    /// is an unstable NSView id, and unnamed params share the locale word for
    /// "slider"). Matches against the window's slider descendants; the match is
    /// case-insensitive on the trimmed description.
    enum PluginWindowSliderResolution {
        case none
        case unique(AXUIElement)
        case ambiguous
    }

    static func pluginWindowSliderResolution(
        in window: AXUIElement,
        axDescription: String,
        runtime: AXHelpers.Runtime = .production
    ) -> PluginWindowSliderResolution {
        switch pluginWindowSliderMatchResult(
            in: window,
            axDescription: axDescription,
            runtime: runtime
        ) {
        case .success(.none), .failure:
            return .none
        case let .success(.unique(slider)):
            return .unique(slider)
        case .success(.ambiguous):
            return .ambiguous
        }
    }

    static func pluginWindowSlider(
        in window: AXUIElement,
        axDescription: String,
        runtime: AXHelpers.Runtime = .production
    ) -> AXUIElement? {
        if case let .unique(slider) = pluginWindowSliderResolution(
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

    private static func pluginWindowSliderMatchResult(
        in window: AXUIElement,
        axDescription: String,
        runtime: AXHelpers.Runtime
    ) -> Result<PluginSliderMatch, AXHelpers.AXStatusError> {
        let target = axDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return .success(.none) }
        let sliders: [AXUIElement]
        switch AXHelpers.censusDescendantResult(
            of: window,
            role: kAXSliderRole,
            maxDepth: 4,
            runtime: runtime
        ) {
        case let .success(census):
            sliders = census.matches
        case let .failure(error):
            return .failure(error)
        }
        var matches: [AXUIElement] = []
        for slider in sliders {
            let description: String?
            switch AXHelpers.getAttributeResult(
                slider,
                kAXDescriptionAttribute as String,
                runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case let .success(observed):
                description = observed
            case let .failure(error) where error.isDefinitiveAbsence:
                description = nil
            case let .failure(error):
                return .failure(error)
            }
            let trimmed = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.caseInsensitiveCompare(target) == .orderedSame {
                matches.append(slider)
            }
        }
        guard let first = matches.first else { return .success(.none) }
        return .success(matches.count == 1 ? .unique(first) : .ambiguous)
    }

}
