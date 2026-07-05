import ApplicationServices
import Foundation


extension AXLogicProElements {
    // MARK: - Tracks

    /// Returns true when Logic's main window is the Choose Project picker
    /// (shown when no project is open). Any AXOutline/AXTable inside the picker
    /// describes template choices, NOT tracks — misidentifying them yields
    /// bogus resource payloads and rename/mute ops that silently fail.
    static func isProjectPickerWindow(_ window: AXUIElement, runtime: Runtime) -> Bool {
        let title = (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "").lowercased()
        return AXLocalePolicy.projectPickerWindow.containsAny(in: title)
    }

    /// Find the track header area containing individual track rows.
    /// v3.1.8 (Issue #7) — outline/table fallback restricted to elements
    /// whose direct children contain `kAXLayoutItemRole`. The unconditional
    /// "first outline/table" fallback (pre-v3.1.8) silently matched the
    /// Inspector subtree when the Mixer panel was focused, causing
    /// `track.get_tracks` to surface Inspector field labels (`Mute:`,
    /// `Loop:`, ...) as track names — the v3.1.4 regression reported in #3.
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

        // Live Logic 12 commonly exposes the track header rail as an AXGroup
        // inside the left scroll area rather than as an AXList/AXOutline.
        // Prefer the language-neutral selected-children structure, with
        // known ko/en descriptions retained as an explicit compatibility path.
        let groups = AXHelpers.findAllDescendants(of: window, role: kAXGroupRole, maxDepth: 8, runtime: runtime.ax)
        if let headerGroup = groups.first(where: {
            isTrackHeadersGroup($0, runtime: runtime.ax)
        }) {
            return headerGroup
        }

        // Hardened fallback: only accept outline / table whose direct
        // children contain at least one `AXLayoutItem` (the role Logic Pro
        // 12 uses for track header rows). This prevents the Inspector outline
        // — which contains AXGroup field rows, not AXLayoutItem — from being
        // returned as a "track headers" candidate.
        let outlines = AXHelpers.findAllDescendants(
            of: window, role: kAXOutlineRole, maxDepth: 8, runtime: runtime.ax
        )
        let tables = AXHelpers.findAllDescendants(
            of: window, role: kAXTableRole, maxDepth: 8, runtime: runtime.ax
        )
        for candidate in outlines + tables {
            let children = AXHelpers.getChildren(candidate, runtime: runtime.ax)
            let hasLayoutItem = children.contains {
                (AXHelpers.getRole($0, runtime: runtime.ax) ?? "") == (kAXLayoutItemRole as String)
            }
            if hasLayoutItem {
                return candidate
            }
        }
        return nil
    }

    /// Find a track header at a specific index (0-based).
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
            // H2 (P2-5): fail-closed on non-AXValue / wrong-subtype rather than
            // a (0,0) misclick.
            let pt = AXHelpers.point(fromRawAttribute: posRaw),
            let sz = AXHelpers.size(fromRawAttribute: sizeRaw)
        else { return false }
        let clickPoint = CGPoint(x: pt.x + min(60, sz.width / 4), y: pt.y + sz.height / 2)
        return LibraryAccessor.productionMouseClick(at: clickPoint)
    }

    /// Enumerate all track header rows.
    /// v3.1.8 (Issue #7) — Inspector contamination is prevented at the
    /// CONTAINER level by `getTrackHeaders` (only outlines/tables with
    /// AXLayoutItem children pass the fallback). Once a container is
    /// trusted (whether by identifier match or layout-item fallback),
    /// children are accepted as-is. This preserves backward compatibility
    /// with fake AX trees that don't set explicit roles on test rows.
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

    // MARK: - Track Controls

    /// Find a track-header toggle control (Mute / Solo / Record-enable).
    ///
    /// #106: Logic Pro 12.x renders all three as `AXCheckBox` elements
    /// (live-confirmed on 12.2: `desc="Mute"/"Solo"/"Record Enable"`,
    /// `settable=false`, only `AXPress`) — NOT `AXButton`. The prior Mute/Solo
    /// locators searched only `kAXButtonRole` and therefore returned nil on
    /// 12.x, so `track.set_mute`/`set_solo` never reached an executable AX
    /// write and the whole channel chain fell through to `channels_exhausted`.
    /// Only the arm locator searched checkboxes (which is why arm at least
    /// found its element). This unifies all three on the checkbox-first match
    /// using the centralized `AXLocalePolicy` label sets, keeping the legacy
    /// `AXButton` description/title fallback for build drift.
    static func findTrackToggleControl(
        in header: AXUIElement,
        labels: [String],
        legacyTitle: String,
        runtime: Runtime = .production
    ) -> AXUIElement? {
        let checkboxes = AXHelpers.findAllDescendants(
            of: header, role: kAXCheckBoxRole, maxDepth: 4, runtime: runtime.ax
        )
        if let match = checkboxes.first(where: { cb in
            guard let desc = AXHelpers.getDescription(cb, runtime: runtime.ax) else { return false }
            // Exact match preserves the historical arm locator semantics;
            // prefix match tolerates trailing state suffixes some builds append.
            return labels.contains(desc) || labels.contains { !$0.isEmpty && desc.hasPrefix($0) }
        }) {
            return match
        }
        // Legacy fallback: AXButton with description prefix / single-letter title.
        for label in labels {
            if let button = findButtonByDescriptionPrefix(in: header, prefix: label, runtime: runtime.ax) {
                return button
            }
        }
        return AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: legacyTitle, runtime: runtime.ax)
    }

    /// Find the mute button on a track header.
    static func findTrackMuteButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findTrackToggleControl(
            in: header, labels: AXLocalePolicy.trackMuteButton.labels, legacyTitle: "M", runtime: runtime
        )
    }

    /// Find the solo button on a track header.
    static func findTrackSoloButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findTrackToggleControl(
            in: header, labels: AXLocalePolicy.trackSoloButton.labels, legacyTitle: "S", runtime: runtime
        )
    }

    /// Find the record-arm button on a track header.
    /// Logic Pro 12 uses an `AXCheckBox` with description `녹음 활성화` (KR) or
    /// `Record Enable` (EN) inside each track header.
    static func findTrackArmButton(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return findTrackToggleControl(
            in: header, labels: AXLocalePolicy.trackRecordEnableCheckbox.labels, legacyTitle: "R", runtime: runtime
        )
    }

    /// #109: the arrange Horizontal-Zoom AXSlider (range 0...1, settable).
    /// Logic honours AXValue writes here, so `set_zoom` can drive it directly
    /// with a verifiable read-back instead of an unmappable key command.
    static func findHorizontalZoomSlider(runtime: Runtime = .production) -> AXUIElement? {
        guard let window = mainWindow(runtime: runtime) else { return nil }
        let labels = AXLocalePolicy.horizontalZoomSlider.labels
        return AXHelpers.findAllDescendants(of: window, role: kAXSliderRole, maxDepth: 16, runtime: runtime.ax)
            .first { slider in
                let desc = AXHelpers.getDescription(slider, runtime: runtime.ax) ?? ""
                return labels.contains { !$0.isEmpty && desc.contains($0) }
            }
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int, runtime: Runtime = .production) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex, runtime: runtime) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4, runtime: runtime.ax)
            ?? AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax)
    }

}
