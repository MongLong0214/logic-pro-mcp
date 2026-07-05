import ApplicationServices
import AppKit
import Foundation

/// Region surface: enumerate arrange regions, move-to-playhead, and select-last.
extension AccessibilityChannel {
    // MARK: - Regions

    /// Read all regions (MIDI/audio clips) currently shown in the arrange area.
    ///
    /// Uses AX traversal: locate the "트랙 콘텐츠"/"Track Content" AXGroup, collect
    /// AXLayoutItem children whose AXHelp matches Logic's region-description pattern,
    /// and parse bar positions from the localized help string.
    ///
    /// Track index is assigned by matching region Y-midpoint to the closest track-header
    /// Y-midpoint. If no track headers can be read (e.g. scrolled offscreen), returns
    /// index -1 so the caller can still see the regions.
    static func defaultGetRegions(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        switch enumerateRegionItems(runtime: runtime) {
        case .failure(let err):
            return .error(err.message)
        case .success(let result):
            // When the array is empty, surface traversal counters so we can tell
            // "no regions exist" from "parser missed them" without re-running a probe.
            if result.regions.isEmpty {
                return .success("{\"regions\":[],\"_debug\":{\"layoutItems\":\(result.layoutItemCount),\"nonRegion\":\(result.nonRegionCount)}}")
            }
            // Tuple-element keypath inference fails in some Swift versions; map
            // explicitly to the RegionInfo array instead of `\.info`.
            return encodeResult(result.regions.map { $0.info })
        }
    }

    /// Result of region traversal. `regions` contains both the AX element
    /// (for read-back like AXSelected) and the parsed RegionInfo.
    struct RegionEnumerationResult {
        let regions: [(item: AXUIElement, info: RegionInfo)]
        let layoutItemCount: Int
        let nonRegionCount: Int
    }

    /// Lightweight error wrapper so `enumerateRegionItems` can carry the
    /// existing diagnostic strings through `Result` without forcing every
    /// caller to define a typed enum. `String` itself does not conform to
    /// `Error`, so this minimal wrapper is the smallest viable adapter.
    struct RegionEnumerationError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func normalizeRegionGroupDescription(_ description: String) -> String {
        description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    private static func isExplicitTrackContentDescription(_ description: String) -> Bool {
        let normalized = normalizeRegionGroupDescription(description)
        return AXLocalePolicy.trackContentExplicit.labels.contains(normalized)
    }

    private static func isGenericContentDescription(_ description: String) -> Bool {
        let normalized = normalizeRegionGroupDescription(description)
        return AXLocalePolicy.trackContentGeneric.labels.contains(normalized)
    }

    private static func frame(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> CGRect? {
        guard let position = AXHelpers.getPosition(element, runtime: runtime),
              let size = AXHelpers.getSize(element, runtime: runtime) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func isVisibleArrangeRegion(
        _ item: AXUIElement,
        within window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let windowFrame = frame(of: window, runtime: runtime),
              let itemFrame = frame(of: item, runtime: runtime),
              !windowFrame.isEmpty,
              !itemFrame.isEmpty else {
            return true
        }
        return itemFrame.intersects(windowFrame)
    }

    private static func classifyRegionKind(name: String, help: String) -> String {
        let searchable = "\(name) \(help)".lowercased()
        if AXLocalePolicy.regionKindDrummer.containsAny(in: searchable) {
            return "drummer"
        }
        if AXLocalePolicy.regionKindMidi.containsAny(in: searchable) {
            return "midi"
        }
        if AXLocalePolicy.regionKindAudio.containsAny(in: searchable) {
            return "audio"
        }
        return "unknown"
    }

    /// Walk the arrange area's "Track Content" group, collect every
    /// AXLayoutItem region with parsed bar positions and its underlying AX
    /// element handle. Shared across `defaultGetRegions`,
    /// `selectedRegionInfo`, and `lastRegionInfo`.
    static func enumerateRegionItems(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Result<RegionEnumerationResult, RegionEnumerationError> {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .failure(RegionEnumerationError("Cannot locate Logic Pro main window"))
        }
        let candidates = AXHelpers.findAllDescendants(
            of: window, role: kAXGroupRole, maxDepth: 14, runtime: runtime.ax
        )
        var contentGroup: AXUIElement? = nil
        var genericContentGroup: AXUIElement? = nil
        var groupDescSamples: [String] = []
        for g in candidates {
            let desc = AXHelpers.getDescription(g, runtime: runtime.ax) ?? ""
            if !desc.isEmpty { groupDescSamples.append(desc) }
            if isExplicitTrackContentDescription(desc) {
                contentGroup = g
                break
            }
            if genericContentGroup == nil, isGenericContentDescription(desc) {
                genericContentGroup = g
            }
        }
        if contentGroup == nil {
            contentGroup = genericContentGroup
        }
        guard let content = contentGroup else {
            let detailed = groupDescSamples.prefix(20).map { s -> String in
                let bytes = s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
                return "'\(s)'(\(s.unicodeScalars.count)=\(bytes))"
            }.joined(separator: " | ")
            return .failure(RegionEnumerationError(
                "Track Content group not found (scanned \(candidates.count) AXGroups; landmarks: \(detailed)). Recovery hint: ensure the Tracks arrange area is visible and not replaced by a modal, editor, or plugin window."
            ))
        }

        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let headerYs: [(index: Int, y: CGFloat)] = headers.enumerated().compactMap { pair in
            guard let p = AXHelpers.getPosition(pair.element, runtime: runtime.ax),
                  let s = AXHelpers.getSize(pair.element, runtime: runtime.ax) else { return nil }
            return (pair.offset, p.y + s.height / 2)
        }

        let items = AXHelpers.findAllDescendants(
            of: content, role: "AXLayoutItem", maxDepth: 10, runtime: runtime.ax
        )
        var regions: [(item: AXUIElement, info: RegionInfo)] = []
        var nonRegionCount = 0
        for item in items {
            let help = AXHelpers.getHelp(item, runtime: runtime.ax) ?? ""
            let isRegion = AXLocalePolicy.regionHelpKeyword.containsAny(in: help)
            guard isRegion else { nonRegionCount += 1; continue }
            guard isVisibleArrangeRegion(item, within: window, runtime: runtime.ax) else {
                continue
            }

            let name = AXHelpers.getDescription(item, runtime: runtime.ax) ?? ""
            let (startBar, endBar) = parseRegionBars(from: help)
            let kind = classifyRegionKind(name: name, help: help)

            var trackIndex = -1
            if let pos = AXHelpers.getPosition(item, runtime: runtime.ax),
               let size = AXHelpers.getSize(item, runtime: runtime.ax),
               !headerYs.isEmpty {
                let regionMidY = pos.y + size.height / 2
                let best = headerYs.min(by: { abs($0.y - regionMidY) < abs($1.y - regionMidY) })
                trackIndex = best?.index ?? -1
            }

            regions.append((
                item,
                RegionInfo(
                    name: name,
                    trackIndex: trackIndex,
                    startBar: startBar,
                    endBar: endBar,
                    kind: kind,
                    rawHelp: help
                )
            ))
        }
        return .success(RegionEnumerationResult(
            regions: regions,
            layoutItemCount: items.count,
            nonRegionCount: nonRegionCount
        ))
    }

    /// Currently selected region (AXLayoutItem with AXSelected=true) inside
    /// the arrange area. Returns nil when no AXLayoutItem reports
    /// `kAXSelectedAttribute = true`. Used by `region.move_to_playhead` for
    /// pre/post startBar diff.
    static func selectedRegionInfo(
        runtime: AXLogicProElements.Runtime = .production
    ) -> RegionInfo? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime) else {
            return nil
        }
        for entry in result.regions {
            if let value: AnyObject = AXHelpers.getAttribute(entry.item, kAXSelectedAttribute, runtime: runtime.ax),
               let n = value as? NSNumber, n.boolValue {
                return entry.info
            }
        }
        return nil
    }

    /// Right-most / latest region. "Last" = the entry with the largest
    /// `startBar`; ties broken by larger `trackIndex`. Used by
    /// `region.select_last` post-state verification.
    static func lastRegionInfo(
        runtime: AXLogicProElements.Runtime = .production
    ) -> RegionInfo? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime),
              !result.regions.isEmpty else {
            return nil
        }
        let sorted = result.regions.map { $0.info }.sorted { a, b in
            if a.startBar != b.startBar { return a.startBar < b.startBar }
            return a.trackIndex < b.trackIndex
        }
        return sorted.last
    }

    /// Parse the integer bar from `TransportState.position`
    /// ("Bar.Beat.Division.Tick"). Returns nil when the transport bar is not
    /// reachable or the position string can't be parsed.
    static func currentPlayheadBar(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Int? {
        guard let transport = AXLogicProElements.getTransportBar(runtime: runtime) else {
            return nil
        }
        let state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime.ax)
        let head = state.position.split(separator: ".").first.map(String.init) ?? ""
        return Int(head)
    }

    /// Extract (startBar, endBar) from Logic's localized region help text.
    /// Returns (-1, -1) if neither pattern matches — callers should inspect rawHelp.
    private static func parseRegionBars(from help: String) -> (Int, Int) {
        // Korean: "리전은 1 마디 에서 시작하여 2 마디 에서 끝납니다."
        // English: "Region starts at 128 bars and ends at 129 bars, MIDI region."
        let patterns = [
            #"리전은\s*(\d+)\s*마디.*?시작.*?(\d+)\s*마디.*?끝"#,
            #"(?i)region\s+starts\s+at\s+(?:bar\s+)?(\d+)(?:\s*bars?)?.*?ends\s+at\s+(?:bar\s+)?(\d+)(?:\s*bars?)?"#,
        ]
        for pat in patterns {
            guard let rx = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(help.startIndex..., in: help)
            guard let m = rx.firstMatch(in: help, range: range), m.numberOfRanges >= 3 else { continue }
            guard let r1 = Range(m.range(at: 1), in: help),
                  let r2 = Range(m.range(at: 2), in: help),
                  let s = Int(help[r1]), let e = Int(help[r2]) else { continue }
            return (s, e)
        }
        return (-1, -1)
    }

    // MARK: - Region repositioning

    /// Move the currently selected region to the playhead position via the
    /// `편집 → 이동 → 재생헤드로` menu (Edit → Move → To Playhead).
    ///
    /// State A path (v3.1.3): pre-snapshot the selected region's startBar via
    /// direct AX, run the menu click, settle, then re-read the same region's
    /// startBar AND the transport playhead bar. If post.startBar matches the
    /// playhead bar (±1 tolerance) → State A `verified:true`. If pre==post
    /// (no movement) or post≠playhead → State B `readback_mismatch`. If we
    /// can't read a selected region pre/post → State B `readback_unavailable`.
    static func defaultMoveSelectedRegionToPlayhead(
        runtime: AXLogicProElements.Runtime = .production,
        executeScript: @Sendable (String) async -> ChannelResult = { await AppleScriptChannel.executeAppleScript($0) },
        settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 350_000_000) }
    ) async -> ChannelResult {
        // Pre-state: snapshot the currently selected region (may be nil if
        // nothing is selected or the AX surface is unreadable).
        let pre = selectedRegionInfo(runtime: runtime)

        let script = """
        tell application "Logic Pro" to activate
        delay 0.1
        tell application "System Events"
            tell process "Logic Pro"
                try
                    click menu item "재생헤드로" of menu 1 of menu item "이동" of menu 1 of menu bar item "편집" of menu bar 1
                on error
                    try
                        click menu item "To Playhead" of menu 1 of menu item "Move" of menu 1 of menu bar item "Edit" of menu bar 1
                    on error errMsg
                        return "MENU_ERROR: " & errMsg
                    end try
                end try
            end tell
        end tell
        return "OK"
        """
        let result = await executeScript(script)
        switch result {
        case .success(let output):
            if output.hasPrefix("MENU_ERROR") {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "region.move_to_playhead menu click failed: \(output)"
                ))
            }
            // Settle window so Logic's AX tree updates before we re-read.
            await settle()

            let post = selectedRegionInfo(runtime: runtime)
            let playheadBar = currentPlayheadBar(runtime: runtime)

            // Without a pre-state we can't diff. State B readback_unavailable.
            guard let pre = pre else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": "applescript_menu",
                        "note": "no selected region pre-state",
                        "post_start_bar": post?.startBar ?? -1,
                        "playhead_bar": playheadBar ?? -1
                    ]
                ))
            }

            // Post readback unavailable (region disappeared / parser miss).
            guard let post = post, post.startBar > 0 else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": "applescript_menu",
                        "pre_start_bar": pre.startBar,
                        "playhead_bar": playheadBar ?? -1,
                        "note": "post startBar not readable"
                    ]
                ))
            }

            let extrasBase: [String: Any] = [
                "via": "applescript_menu",
                "region_name": pre.name,
                "pre_start_bar": pre.startBar,
                "post_start_bar": post.startBar,
                "playhead_bar": playheadBar ?? NSNull()
            ]

            // Verified: post.startBar landed on the playhead bar (±1 tolerance
            // for snap rounding). State A.
            if let head = playheadBar, abs(post.startBar - head) <= 1 {
                var extras = extrasBase
                extras["requested"] = head
                extras["observed"] = post.startBar
                return .success(HonestContract.encodeStateA(extras: extras))
            }

            // Position changed but didn't match playhead — Logic moved it
            // somewhere unexpected (snap behaviour / wrong target).
            if pre.startBar != post.startBar {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch,
                    extras: extrasBase
                ))
            }

            // pre == post → menu was a no-op (asked to move, nothing moved).
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extrasBase.merging(["note": "no position change"]) { _, new in new }
            ))
        case .error(let msg):
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "region.move_to_playhead failed: \(msg)"
            ))
        }
    }

    /// Select the most recently created (right-most / largest trackIndex)
    /// region in the arrange area by locating it via AX element position.
    /// Newly imported regions are usually already selected by Logic, but this
    /// provides a fallback when selection state is lost between operations.
    ///
    /// State A path (v3.1.3): after the AppleScript sets selection, re-read
    /// the AX tree to find the currently selected region and the "last"
    /// region (largest startBar). If they match → State A `verified:true`;
    /// otherwise State B `readback_mismatch` / `readback_unavailable`.
    static func defaultSelectLastRegion(
        runtime: AXLogicProElements.Runtime = .production,
        executeScript: @Sendable (String) async -> ChannelResult = { await AppleScriptChannel.executeAppleScript($0) },
        settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 350_000_000) }
    ) async -> ChannelResult {
        let script = """
        tell application "Logic Pro" to activate
        delay 0.1
        tell application "System Events"
            tell process "Logic Pro"
                set mainWin to first window
                set allItems to entire contents of mainWin
                set bestY to 0
                set bestX to 0
                set target to missing value
                repeat with anItem in allItems
                    try
                        if role of anItem is "AXLayoutItem" then
                            set s to size of anItem
                            set w to item 1 of s
                            set h to item 2 of s
                            -- Region heuristic: 20 < width < 2000, 20 < height < 200
                            if w > 20 and w < 2000 and h > 20 and h < 200 then
                                set p to position of anItem
                                set x to item 1 of p
                                set y to item 2 of p
                                if y > bestY or (y = bestY and x > bestX) then
                                    set bestY to y
                                    set bestX to x
                                    set target to anItem
                                end if
                            end if
                        end if
                    end try
                end repeat
                if target is missing value then
                    return "NO_REGION"
                end if
                -- Use AXPress / AXShowMenu may open contextual menu; instead set AXSelected
                try
                    set selected of target to true
                    return "SELECTED"
                on error
                    -- Fallback: click at center
                    set p to position of target
                    set s to size of target
                    set cx to (item 1 of p) + ((item 1 of s) / 2)
                    set cy to (item 2 of p) + ((item 2 of s) / 2)
                    click at {cx, cy}
                    return "CLICKED"
                end try
            end tell
        end tell
        """
        let result = await executeScript(script)
        switch result {
        case .success(let output):
            if output.contains("NO_REGION") {
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "region.select_last: no region found in arrange area"
                ))
            }
            // Settle window so Logic's AX tree reflects the new selection
            // before we re-read AXSelected.
            await settle()

            let method = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = lastRegionInfo(runtime: runtime)
            let selected = selectedRegionInfo(runtime: runtime)

            // Without a "last" region we can't even define the target.
            guard let expected = expected else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": method.isEmpty ? "applescript" : method,
                        "note": "could not enumerate regions for last-region target"
                    ]
                ))
            }

            // No selected region readback (AXSelected never came back true).
            guard let selected = selected else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": method.isEmpty ? "applescript" : method,
                        "expected_name": expected.name,
                        "expected_start_bar": expected.startBar,
                        "note": "no AXSelected region post-action"
                    ]
                ))
            }

            let extrasBase: [String: Any] = [
                "via": method.isEmpty ? "applescript" : method,
                "expected_name": expected.name,
                "expected_start_bar": expected.startBar,
                "expected_track_index": expected.trackIndex,
                "selected_name": selected.name,
                "selected_start_bar": selected.startBar,
                "selected_track_index": selected.trackIndex
            ]

            // Match by (name, startBar, trackIndex) triple — the same region
            // identity the resource exposes. State A on full match.
            if selected.name == expected.name
                && selected.startBar == expected.startBar
                && selected.trackIndex == expected.trackIndex {
                return .success(HonestContract.encodeStateA(extras: extrasBase))
            }

            // Selected ≠ last region (AppleScript heuristic picked a
            // different AXLayoutItem than our parsed-bar "last").
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extrasBase
            ))
        case .error(let msg):
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "region.select_last failed: \(msg)"
            ))
        }
    }

}
