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
    /// What the AX region enumeration can see, and why it can never claim more.
    ///
    /// Logic exposes region layout items only for the part of the arrangement currently in view, so
    /// `enumerateRegionItems` is scope-limited by construction. These two constants exist so the
    /// readers that DEPEND on that limitation name the same thing the inventory payload does —
    /// `midi.import_file` reported an empty region result as a definite failure while this file was
    /// already publishing `complete: false` on every read (#576).
    static let regionReadbackScope = "visible_arrange_area"
    static let regionReadbackLimitReason = "logic_ax_viewport_only"

    static func defaultGetRegions(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        switch enumerateRegionItems(runtime: runtime) {
        case .failure(let err):
            return .error(err.message)
        case .success(let result):
            let regions = result.regions.map { $0.info }
            // `complete` was hardcoded `false` on every successful read. Safe, but uninformative —
            // and it made every consumer fail closed forever, which is why `midi.import_file` could
            // not tell "no region" from "no region visible" (#576).
            //
            // It is now measured, and measured from the HEADERS rather than the regions: a track
            // carrying no regions produces no entry, so the highest observed `trackIndex` says
            // nothing about the tracks above it. `allTrackHeaders` is not viewport-limited —
            // measured on Logic 12.3, 21 of 21 while the region layer stopped at 13 — so "every
            // header is inside the visible bounds" answers the question directly, and fails closed
            // on a frame it cannot read.
            //
            // The headers are the VERTICAL axis only. A region at bar 33 lies far to the right of a
            // window whose every track header is visible, so the count of region items dropped for
            // being outside the window is required too — the first version of this rule checked only
            // the headers and would have called that arrangement completely read.
            let complete = result.coversWholeArrangement
            return encodeResult(RegionInventoryPayload(
                regions: regions,
                complete: complete,
                scope: complete ? "whole_arrangement" : regionReadbackScope,
                reason: complete ? nil : regionReadbackLimitReason,
                returnedCount: regions.count,
                debug: RegionInventoryPayload.Debug(
                    layoutItems: result.layoutItemCount,
                    nonRegion: result.nonRegionCount,
                    trackHeaders: result.trackHeaderCount,
                    trackHeadersInViewport: result.trackHeadersWithinViewport
                )
            ))
        }
    }

    /// Result of region traversal. `regions` contains both the AX element
    /// (for read-back like AXSelected) and the parsed RegionInfo.
    struct RegionEnumerationResult {
        let regions: [(item: AXUIElement, info: RegionInfo)]
        let layoutItemCount: Int
        let nonRegionCount: Int
        /// Every track in the project, viewport or not. `allTrackHeaders` is NOT viewport-limited —
        /// measured on Logic 12.3, 2026-08-17: 21 headers while the region layer stopped at 13.
        let trackHeaderCount: Int
        /// How many of those headers lie inside the window's visible bounds. This is the honest
        /// denominator for a completeness claim, and it is decidable WITHOUT the regions: a track
        /// carrying no regions produces no entry, so the highest observed `trackIndex` says nothing
        /// about the tracks above it.
        let trackHeadersWithinViewport: Int

        /// Region layout items the traversal found and then DROPPED for lying outside the window.
        ///
        /// This is the horizontal axis, and it is not implied by the header count: a region at bar 33
        /// sits far to the right of a window whose every track header is visible. An early version of
        /// this completeness rule checked only the headers and would have called that arrangement
        /// completely read — `testAccessibilityChannelAXBackedRegionsMarkViewportSubsetIncomplete`
        /// models exactly that shape and caught it.
        let regionItemsOutsideViewport: Int

        /// The enumeration saw the whole arrangement: every track was in view AND no region was
        /// dropped for being outside it.
        ///
        /// Zero headers is NOT complete: with nothing to bound the claim there is nothing to have
        /// covered, and reporting completeness there would make an unreadable arrangement look
        /// exhaustively read.
        var coversWholeArrangement: Bool {
            trackHeaderCount > 0
                && trackHeadersWithinViewport == trackHeaderCount
                && regionItemsOutsideViewport == 0
        }
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

    /// Whether a track header is inside the window's visible bounds.
    ///
    /// Deliberately NOT `isVisibleArrangeRegion`, which returns `true` when either frame is
    /// unreadable. That fail-OPEN is right when deciding whether to include a region it can see, and
    /// wrong here: an unreadable header would inflate a completeness claim, which is the direction
    /// that lets an absence be published as proof (#576).
    private static func headerIsWithinViewport(
        _ header: AXUIElement,
        within window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Bool {
        guard let windowFrame = frame(of: window, runtime: runtime),
              let headerFrame = frame(of: header, runtime: runtime),
              !windowFrame.isEmpty,
              !headerFrame.isEmpty else {
            return false
        }
        return headerFrame.intersects(windowFrame)
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
        var regionItemsOutsideViewport = 0
        for item in items {
            let help = AXHelpers.getHelp(item, runtime: runtime.ax) ?? ""
            let isRegion = AXLocalePolicy.regionHelpKeyword.containsAny(in: help)
            guard isRegion else { nonRegionCount += 1; continue }
            guard isVisibleArrangeRegion(item, within: window, runtime: runtime.ax) else {
                regionItemsOutsideViewport += 1
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
            nonRegionCount: nonRegionCount,
            trackHeaderCount: headers.count,
            trackHeadersWithinViewport: headers.filter {
                headerIsWithinViewport($0, within: window, runtime: runtime.ax)
            }.count,
            regionItemsOutsideViewport: regionItemsOutsideViewport
        ))
    }

    /// EVERY region Logic reports as selected, in enumeration order.
    ///
    /// `selectedRegionInfo` answers with the first one and that is not enough to verify a
    /// selection, because the write used to establish one is a toggle (see
    /// `defaultSelectLastRegion`) and leaves whatever else was selected alone.
    /// Asking "is the last region selected?" gets a yes while three others are also selected, and
    /// the operations that consume the selection then act on all four. The verifiable question is
    /// "is the selection exactly this one region?", and it needs the whole set.
    ///
    /// `nil` and `[]` are different answers and the callers depend on the difference: `nil` means
    /// the arrange area could not be enumerated at all, `[]` means it was and nothing is selected.
    /// The singular version below cannot tell those apart, which is the other half of why it is not
    /// enough. Note that a region whose `AXSelected` is UNREADABLE counts as not selected here — an
    /// unreadable attribute cannot be evidence of selection, and a caller demanding an exact set
    /// will fail closed on it rather than certify.
    static func selectedRegionInfos(
        runtime: AXLogicProElements.Runtime = .production
    ) -> [RegionInfo]? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime) else {
            return nil
        }
        return result.regions.filter { entry in
            guard let value: AnyObject = AXHelpers.getAttribute(
                entry.item, kAXSelectedAttribute, runtime: runtime.ax
            ), let number = value as? NSNumber else { return false }
            return number.boolValue
        }.map(\.info)
    }

    /// Currently selected region (AXLayoutItem with AXSelected=true) inside
    /// the arrange area. Returns nil when no AXLayoutItem reports
    /// `kAXSelectedAttribute = true`. Used by `region.move_to_playhead` for
    /// pre/post startBar diff.
    ///
    /// Answers with the FIRST such region and cannot say how many there are; see
    /// `selectedRegionInfos` for why that is not enough to verify a selection.
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
    /// The last region AND the element that carries it, by the same rule `lastRegionInfo` uses.
    ///
    /// #767 — `defaultSelectLastRegion` verified its work with `lastRegionInfo`, which sorts by
    /// `startBar` then `trackIndex`, while SELECTING with an AppleScript that walked
    /// `entire contents` and picked the largest screen coordinates. Two rules for "last" in one
    /// function: the check was right and the action was not, so the check could only ever report
    /// that the action had missed.
    static func lastRegionItem(
        runtime: AXLogicProElements.Runtime = .production
    ) -> (item: AXUIElement, info: RegionInfo, coversWholeArrangement: Bool)? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime),
              !result.regions.isEmpty else {
            return nil
        }
        // The enumeration knows whether it saw the whole arrangement, and a caller that says "the
        // last region" is making a claim over exactly that scope. Carrying the flag out with the
        // element is what lets the answer say which of the two things it means.
        guard let last = result.regions.sorted(by: { a, b in
            if a.info.startBar != b.info.startBar { return a.info.startBar < b.info.startBar }
            return a.info.trackIndex < b.info.trackIndex
        }).last else { return nil }
        return (last.item, last.info, result.coversWholeArrangement)
    }

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

        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        // #519: bar/item/leaf names come from AXLocalePolicy's LabelSets (Edit/Move/To
        // Playhead) instead of a hard-coded EN/KO literal pair — see AppleScriptMenuResolution.
        let editBarResolution = AppleScriptMenuResolution.menuBarItem(
            AXLocalePolicy.editMenuBar,
            variableName: "editBarName",
            notFoundError: "EDIT_MENU_BAR_NOT_FOUND"
        )
        let moveMenuItemResolution = AppleScriptMenuResolution.menuItem(
            AXLocalePolicy.moveMenuItem,
            under: "menu bar item editBarName of menu bar 1",
            variableName: "moveItemName",
            notFoundError: "MOVE_MENU_ITEM_NOT_FOUND"
        )
        let toPlayheadMenuItemResolution = AppleScriptMenuResolution.menuItem(
            AXLocalePolicy.toPlayheadMenuItem,
            under: "menu item moveItemName of menu 1 of menu bar item editBarName of menu bar 1",
            variableName: "toPlayheadItemName",
            notFoundError: "TO_PLAYHEAD_MENU_ITEM_NOT_FOUND"
        )
        let script = """
        \(logicProAppleScript.activateByBundleID)
        delay 0.1
        tell application "System Events"
            tell \(logicProAppleScript.systemEventsProcessTarget)
                try
                    \(editBarResolution)
                    \(moveMenuItemResolution)
                    \(toPlayheadMenuItemResolution)
                    click menu item toPlayheadItemName of menu 1 of menu item moveItemName of menu 1 of menu bar item editBarName of menu bar 1
                on error errMsg
                    return "MENU_ERROR: " & errMsg
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
                "post_region_name": post.name,
                "pre_track_index": pre.trackIndex,
                "post_track_index": post.trackIndex,
                "pre_start_bar": pre.startBar,
                "post_start_bar": post.startBar,
                "playhead_bar": playheadBar ?? NSNull()
            ]

            // The pre- and post-reads both ask Logic for "the selected region", and nothing forces
            // that to be the SAME region across the menu click. Without this, a selection that
            // drifted mid-click could certify State A on a region the caller never asked about,
            // purely because it happens to sit on the playhead. `startBar` cannot serve as the
            // identity here — it is the property this operation exists to change.
            //
            // A `trackIndex` of -1 is the enumeration saying it could not place the region against
            // a track header, so it is a readback gap and not a match.
            let sameRegion = post.name == pre.name
                && pre.trackIndex >= 0
                && post.trackIndex == pre.trackIndex
            guard sameRegion else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch,
                    extras: extrasBase.merging([
                        "note": "the region selected after the move is not the one selected before it"
                    ]) { _, new in new }
                ))
            }

            // Verified: the SAME region's startBar landed on the playhead bar (±1 tolerance
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
    /// Put Logic's selection on exactly one region: the last one in the arrange area.
    ///
    /// "Last" is the greatest start bar, ties broken by the greater track index — the ordering
    /// `lastRegionInfo` has always used. It is NOT "most recently created", which this comment
    /// claimed for two years while the code sorted by timeline position; a region dragged to the
    /// end of the song is the last one here however old it is.
    ///
    /// ## Why this is a composition and not a write
    ///
    /// No single actuator on this surface replaces a selection. Measured on Logic 12.3, ko-KR,
    /// 2026-09-04, against a project with two regions:
    ///
    ///   * `AXSelected = true` is settable, returns `.success`, and is a TOGGLE. Writing `true`
    ///     to the same region three times from an empty selection gives selected, DESELECTED,
    ///     selected. A setter would leave it selected. This is why the repository's older note
    ///     that the write "adds to the selection" is not quite the fact: adding is what a toggle
    ///     looks like when the target happened to be off, and it is also why an earlier harness
    ///     that wrote FALSE on every other region ended with eighteen selected and the target not.
    ///   * `AXPress` never selects. Two selected → zero; zero → zero; `.success` both times.
    ///   * the enclosing `AXLayoutArea` publishes `AXSelectedChildren` as NOT settable.
    ///
    /// So the selection is emptied first, using Logic's own `Deselect All`, and the toggle then
    /// runs against a known-empty selection — which is the one pre-state where a toggle and a
    /// setter agree. Measured in that order: 2 selected → Deselect All → 0 → write → exactly 1,
    /// and it is the target. Driven live three times in a row against an already-correct
    /// selection it stayed State A with a count of 1, which a toggle without the clear could not
    /// do. The menu item is addressed by its locale-free
    /// `AXIdentifier` (`deselectAll:`, unique among the Edit menu's 151 items), so this adds no new
    /// localized label to maintain.
    ///
    /// ## What the verdict rests on
    ///
    /// The emptied selection is READ back, not assumed, so the transition 0 → 1 is observed rather
    /// than inferred. That is what separates this from a no-op: without a known pre-state, calling
    /// this on an already-selected target is indistinguishable from doing nothing, and reporting
    /// State A for it would be exactly the `noop_unobservable` case the contract exists to name.
    /// State A therefore requires the post-state to be a set of exactly one region whose identity
    /// matches the target. Anything else is State B carrying the observed count.
    ///
    /// ## Limit
    ///
    /// `enumerateRegionItems` drops regions outside the visible arrange area, so "last" can mean
    /// the last region Logic is currently SHOWING. The enumeration knows which case it is —
    /// `coversWholeArrangement` is true only when every track header is in the viewport and no
    /// region item was dropped — and the envelope reports it as `whole_arrangement` or
    /// `visible_arrange_area` accordingly, rather than leaving the caller to assume the stronger
    /// one. When the scope is the narrower one, a region scrolled out of view does not participate
    /// in the ordering; closing that needs a way to enumerate the whole timeline, which this
    /// surface does not offer.
    static func defaultSelectLastRegion(
        runtime: AXLogicProElements.Runtime = .production,
        selectRegion: (@Sendable (AXUIElement, AXLogicProElements.Runtime) -> Bool)? = nil,
        deselectAll: (@Sendable (AXLogicProElements.Runtime) -> Bool)? = nil,
        settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 350_000_000) }
    ) async -> ChannelResult {
        // #767 — this used to drive an AppleScript that walked `entire contents` and picked the
        // largest screen coordinates. Two defects, either sufficient:
        //
        //   * `entire contents` returns an EMPTY list, without raising, for every application on
        //     macOS 26.3 — measured 2026-09-04 at 0 against 464 by a manual descent of the same
        //     window. The filter therefore ran over nothing and the handler reported NO_REGION for
        //     a project that had regions.
        //   * the filter was `20 < w < 2000 and 20 < h < 200`, which every TRACK HEADER satisfies.
        //     Measured on one window: 4 candidates, 3 of them headers. Picking the greatest Y then
        //     X landed on the region by a pixel of luck, and a project whose bottom track carries
        //     no region would have selected a header and called it the last region.
        //
        // The rule was already here and already right — `lastRegionInfo` sorts by `startBar` then
        // `trackIndex`, and this function used it to VERIFY a selection made by a different rule.
        // The check was correct and the action was not, so the check could only ever report that
        // the action had missed. Both now come from the same enumeration.
        guard let target = lastRegionItem(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "region.select_last: no region found in the visible arrange area"
            ))
        }

        let clearSelection = deselectAll ?? { runtime in
            guard let item = AXLogicProElements.menuItem(
                identifier: Self.deselectAllMenuIdentifier,
                inMenuBar: AXLocalePolicy.editMenuBar,
                runtime: runtime
            ) else { return false }
            // #606's gate: pressing a DISABLED menu item reports success and does nothing, so an
            // unreadable `AXEnabled` is refused for the same reason a false one is.
            let enabled: Bool? = AXHelpers.getAttribute(
                item, kAXEnabledAttribute as String, runtime: runtime.ax
            )
            guard enabled == true else { return false }
            return AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax)
        }
        let writeSelected = selectRegion ?? { element, runtime in
            AXHelpers.setAttribute(element, kAXSelectedAttribute, kCFBooleanTrue, runtime: runtime.ax)
        }

        // The actuator's answer is not the pre-state; the readback is. A `Deselect All` that
        // reports failure over an already-empty selection has still left the selection empty, and
        // one that reports success without emptying it has not. Its answer is carried in the
        // envelope for diagnosis only — the first live run of this code failed here because the
        // menu descent stopped one level short, and the gate refused rather than answering wrong.
        let deselectReported = clearSelection(runtime)
        await settle()
        guard let cleared = selectedRegionInfos(runtime: runtime) else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: [
                    "via": "deselect-all+ax-selected",
                    "note": "could not read the selection after Deselect All"
                ]
            ))
        }
        guard cleared.isEmpty else {
            // Without an empty pre-state the add-write cannot be distinguished from a no-op.
            return .success(HonestContract.encodeStateB(
                reason: .noopUnobservable,
                extras: [
                    "via": "deselect-all+ax-selected",
                    "selected_before_count": cleared.count,
                    "deselect_reported": deselectReported,
                    "note": "Deselect All did not empty the selection, so a write that only "
                        + "TOGGLES cannot be shown to have established this selection"
                ]
            ))
        }

        let writeReportedFailure = !writeSelected(target.item, runtime)
        await settle()

        let expected = target.info
        guard let selected = selectedRegionInfos(runtime: runtime) else {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: [
                    "via": "deselect-all+ax-selected",
                    "expected_name": expected.name,
                    "expected_start_bar": expected.startBar,
                    "note": "could not read the selection after the write"
                ]
            ))
        }

        // The write said no and the selection is still empty. Those agree, and they agree on a real
        // failure, so the contract fails closed rather than reporting an unreadable state.
        if selected.isEmpty, writeReportedFailure {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "region.select_last: the target region's AXSelected attribute could not be "
                    + "written and nothing is selected; no fallback was attempted"
            ))
        }

        // The target was chosen BEFORE the clear and two settle windows. If the arrangement moved
        // in between, the region that is last now is not the one this acted on, and matching the
        // post-state against a stale `expected` would certify the stale answer. Re-deriving costs
        // one enumeration and is the difference between "this is the last region" and "this was the
        // last region when I looked".
        let lastNow = lastRegionItem(runtime: runtime)?.info
        let targetIsStillLast = lastNow.map {
            $0.name == expected.name && $0.startBar == expected.startBar
                && $0.trackIndex == expected.trackIndex
        } ?? false

        var extras: [String: Any] = [
            "via": "deselect-all+ax-selected",
            "write_reported_success": !writeReportedFailure,
            "target_is_still_last": targetIsStillLast,
            "expected_name": expected.name,
            "expected_start_bar": expected.startBar,
            "expected_track_index": expected.trackIndex,
            "selected_count": selected.count,
            "scope": target.coversWholeArrangement ? "whole_arrangement" : Self.regionReadbackScope
        ]
        if !target.coversWholeArrangement {
            // "The last region Logic is showing" and "the last region" are different claims, and
            // only the enumeration can say which one this is.
            extras["scope_reason"] = Self.regionReadbackLimitReason
        }
        if let only = selected.first {
            extras["selected_name"] = only.name
            extras["selected_start_bar"] = only.startBar
            extras["selected_track_index"] = only.trackIndex
        }

        // State A is the whole selection being this one region, established BY THIS CALL, and still
        // the last region when the verdict is given. Three conditions, because dropping any one of
        // them certifies something that was not shown:
        //
        //   * the set, because "the target is among the selected" is not a claim a consumer of the
        //     selection can act on;
        //   * the write's own answer, because a target that something ELSE selected between the
        //     empty readback and the verdict satisfies the set test while this call established
        //     nothing — the readback is the verdict on the STATE, and it cannot speak to authorship;
        //   * the re-derived last, because the target was chosen three reads ago.
        //
        // A write that reported failure over a selection that nevertheless matches is State B, not
        // State C: the state is right and unexplained, which is exactly what unverified means.
        if selected.count == 1,
           !writeReportedFailure,
           targetIsStillLast,
           let only = selected.first,
           only.name == expected.name,
           only.startBar == expected.startBar,
           only.trackIndex == expected.trackIndex {
            return .success(HonestContract.encodeStateA(extras: extras))
        }

        return .success(HonestContract.encodeStateB(
            reason: .readbackMismatch,
            extras: extras
        ))
    }

    /// Logic's `Edit > Select > Deselect All`, addressed by the AppKit selector Logic wires the item
    /// to rather than by its title.
    ///
    /// A selector is not a translated string, so this SHOULD hold across locales — but "should" is
    /// the honest word: it was measured on one host, one build and one locale (ko-KR, 12.3, 6674),
    /// and the record that carries the measurement says exactly that in its limits. The lookup does
    /// not rely on the guess: it refuses when the identifier is absent, and refuses again when more
    /// than one item in the bounded region carries it, so a build where this assumption is wrong
    /// produces a refusal rather than a press on the wrong item.
    private static let deselectAllMenuIdentifier = "deselectAll:"

}
