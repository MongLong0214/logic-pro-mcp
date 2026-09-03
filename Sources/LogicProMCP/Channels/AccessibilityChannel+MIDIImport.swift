import ApplicationServices
import AppKit
import Foundation

/// MIDI file import surface (midi.import_file): AX menu navigation and imported-region readback.
extension AccessibilityChannel {
    // MARK: - MIDI file import

    /// Tokens that mark a track header as a GM Device / external-MIDI synth
    /// lane rather than an audible Software Instrument track. Logic's multi-track
    /// SMF open creates these "GM Device N" / External MIDI lanes, which route to
    /// a General MIDI device and bounce silent (#128). Matching is
    /// case-insensitive substring. Kept narrow on purpose: a Software Instrument
    /// track named "MIDI Bass" must NOT trip this — only the literal Logic lane
    /// names ("GM Device", "External MIDI", "External Instrument") do.
    static let gmDeviceLaneTokens: [String] = [
        "gm device", "general midi", "external midi", "external instrument"
    ]

    /// Pure classifier: given the track-header names observed AFTER an import and
    /// the count BEFORE, return the newly-created lane names that are GM Device /
    /// external-MIDI (i.e. silent-on-bounce) lanes. Deterministic + unit-testable
    /// without live AX. Only the *new* lanes (suffix beyond `beforeCount`) are
    /// inspected so a pre-existing GM Device track never poisons a clean import.
    static func gmDeviceLanesAmongNewTracks(
        names: [String],
        beforeCount: Int
    ) -> [String] {
        guard beforeCount >= 0, names.count > beforeCount else { return [] }
        let newLanes = names.suffix(from: min(beforeCount, names.count))
        return newLanes.filter { name in
            let lower = name.lowercased()
            return gmDeviceLaneTokens.contains { lower.contains($0) }
        }
    }

    enum MIDIImportRegionReadback {
        /// The regions read, and whether that read covered the WHOLE arrangement.
        ///
        /// The completeness travelled with the enumeration all along and was dropped at this call
        /// site — which is why an import that worked, on a project larger than the viewport, was
        /// reported as a definite failure (#576). It is carried now.
        case success([RegionInfo], complete: Bool)
        case failure(String)

        var regions: [RegionInfo]? {
            if case .success(let regions, _) = self { return regions }
            return nil
        }

        var isComplete: Bool {
            if case .success(_, let complete) = self { return complete }
            return false
        }
    }

    private static func defaultMIDIImportRegionInfos(
        runtime: AXLogicProElements.Runtime
    ) -> MIDIImportRegionReadback {
        switch enumerateRegionItems(runtime: runtime) {
        case .success(let result):
            return .success(result.regions.map { $0.info }, complete: result.coversWholeArrangement)
        case .failure(let error):
            return .failure(error.message)
        }
    }

    private static func midiImportRegionKey(_ region: RegionInfo) -> String {
        [
            region.name,
            String(region.trackIndex),
            String(region.startBar),
            String(region.endBar),
            region.kind,
        ].joined(separator: "|")
    }

    private static func midiImportRegionFields(_ region: RegionInfo) -> [String: Any] {
        var fields: [String: Any] = [
            "name": region.name,
            "track_index": region.trackIndex,
            "start_bar": region.startBar,
            "end_bar": region.endBar,
            "kind": region.kind,
        ]
        if let rawHelp = region.rawHelp, !rawHelp.isEmpty {
            fields["raw_help"] = rawHelp
        }
        return fields
    }

    private static func newMIDIRegionsForImport(
        afterRegions: [RegionInfo],
        beforeRegionKeys: Set<String>?,
        beforeCount: Int,
        afterCount: Int
    ) -> [RegionInfo] {
        afterRegions.filter { region in
            region.kind.lowercased() == "midi"
                && region.trackIndex >= beforeCount
                && region.trackIndex < afterCount
                && beforeRegionKeys?.contains(midiImportRegionKey(region)) != true
        }
    }

    private static func addedMIDIRegionsForImport(
        afterRegions: [RegionInfo],
        beforeRegionKeys: Set<String>?
    ) -> [RegionInfo] {
        guard let beforeRegionKeys else { return [] }
        return afterRegions.filter { region in
            region.kind.lowercased() == "midi"
                && !beforeRegionKeys.contains(midiImportRegionKey(region))
        }
    }

    private static func normalizedAppleScriptPayload(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? String else {
            return trimmed
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Import a .mid file via Logic Pro's File → Import → MIDI File menu.
    /// Always creates a new MIDI track (Logic Pro's built-in behavior, OQ-3 confirmed).
    /// Uses osascript to coordinate the menu click, path-entry keystroke, and dialog dismissals.
    ///
    /// v3.6.x hardening (#140): the AppleScript no longer relies on a fixed
    /// `delay 1.5` to assume the file-open sheet appeared. It POLLS (up to ~5s)
    /// for the sheet to exist before issuing the path keystroke, and reports
    /// `FILEOPEN_SEEN` / `TEMPO_SEEN` flags plus a `DIALOG_NOT_FOUND` sentinel so
    /// an occluded-session miss (no sheet ever appeared) is distinguishable from
    /// a real import that created no track. The track-count delta is read with a
    /// bounded poll on the Swift side, not a single settle.
    ///
    /// v3.6.x audibility (#128): on the otherwise-State-A path, the created lane
    /// names are read back; if any new lane is a GM Device / external-MIDI synth
    /// lane the result is DOWNGRADED to State B `imported_as_gm_device` with a
    /// hint, because such lanes route to a General MIDI device and may bounce
    /// silent — a count delta alone must never be claimed audible-verified.
    static func defaultImportMIDIFile(
        systemEventsAuthorized: @Sendable () -> Bool = { PermissionChecker.checkSystemEventsAutomation() },
        path: String,
        runtime: AXLogicProElements.Runtime = .production,
        executeScript: @escaping @Sendable (String) async -> ChannelResult = {
            await AppleScriptChannel.executeAppleScript($0, timeout: ServerConfig.midiImportAppleScriptTimeout)
        },
        trackCount: (@Sendable () -> Int)? = nil,
        trackNames: (@Sendable () -> [String])? = nil,
        regionInfos: (@Sendable () -> MIDIImportRegionReadback)? = nil,
        deltaPoll: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
    ) async -> ChannelResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "midi.import_file: file not found",
                extras: ["requested": path]
            ))
        }
        // #188: the import below drives `tell application "System Events"`, a
        // distinct Automation TCC target from Logic Pro. If it is not authorized,
        // fail closed with a typed permission error BEFORE the mutation instead of
        // aborting mid-import with a bare Apple Events denial (health/permissions
        // could otherwise look green on the Logic-Pro automation line alone).
        guard systemEventsAuthorized() else {
            return .error(HonestContract.encodeStateC(
                error: .systemEventsAutomationDenied,
                hint: AppleScriptErrorClassifier.systemEventsAutomationDeniedHint,
                extras: [
                    "permission": "automation_system_events",
                    "failure_stage": "preflight_system_events_permission",
                    "write_attempted": false,
                    "safe_to_retry": false,
                    "remediation": AppleScriptErrorClassifier.systemEventsAutomationDeniedHint,
                ]
            ))
        }
        let readTrackCount = trackCount ?? { AXLogicProElements.allTrackHeaders(runtime: runtime).count }
        let readTrackNames = trackNames ?? {
            AXLogicProElements.allTrackHeaders(runtime: runtime).enumerated().map { index, header in
                AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax).name
            }
        }
        let readRegionInfos = regionInfos ?? {
            defaultMIDIImportRegionInfos(runtime: runtime)
        }
        let beforeCount = readTrackCount()
        let beforeRegionRead = readRegionInfos()
        let beforeRegions: [RegionInfo]?
        let beforeRegionError: String?
        switch beforeRegionRead {
        case .success(let regions, _):
            beforeRegions = regions
            beforeRegionError = nil
        case .failure(let error):
            beforeRegions = nil
            beforeRegionError = error
        }
        let beforeRegionKeys = beforeRegions.map { Set($0.map(midiImportRegionKey)) }
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Poll the file-open sheet into existence (mirrors the
        // `waitForControlBarCheckboxValue` / goto_position "first window whose
        // name is" pattern) instead of blindly sleeping 1.5s. ~5s budget at
        // 250ms granularity = 20 attempts. A sheet on a Logic process is a
        // `window whose subrole is "AXSheet"` (file chooser) — fall back to the
        // standard window if no sheet subrole is exposed on this build.
        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        // #519: bar/item/leaf names come from AXLocalePolicy's LabelSets (File/Import/MIDI
        // File…) instead of a hard-coded EN/KO literal pair — see AppleScriptMenuResolution.
        let importMenuBarResolution = AppleScriptMenuResolution.menuBarItem(
            AXLocalePolicy.fileMenuBar,
            variableName: "importBarName",
            notFoundError: "IMPORT_MENU_BAR_NOT_FOUND"
        )
        let importMenuItemResolution = AppleScriptMenuResolution.menuItem(
            AXLocalePolicy.importMenuItem,
            under: "menu bar item importBarName of menu bar 1",
            variableName: "importItemName",
            notFoundError: "IMPORT_MENU_ITEM_NOT_FOUND"
        )
        let midiFileMenuItemResolution = AppleScriptMenuResolution.menuItem(
            AXLocalePolicy.midiFileMenuItem,
            under: "menu item importItemName of menu 1 of menu bar item importBarName of menu bar 1",
            variableName: "midiFileItemName",
            notFoundError: "MIDI_FILE_MENU_ITEM_NOT_FOUND"
        )
        let script = """
        on importMIDI()
            \(logicProAppleScript.activateByBundleID)
            delay 0.3
            tell application "System Events"
                -- Self-heal: dismiss a stale Import open-panel left by a prior
                -- failed run so repeated imports never stack file-open dialogs.
                tell \(logicProAppleScript.systemEventsProcessTarget)
                    repeat 4 times
                        if (exists (first window whose name is "Import")) or (exists (first window whose name is "가져오기")) then
                            key code 53
                            delay 0.25
                        else
                            exit repeat
                        end if
                    end repeat
                end tell
                tell \(logicProAppleScript.systemEventsProcessTarget)
                    try
                        \(importMenuBarResolution)
                        \(importMenuItemResolution)
                        \(midiFileMenuItemResolution)
                        click menu item midiFileItemName of menu 1 of menu item importItemName of menu 1 of menu bar item importBarName of menu bar 1
                    on error errMsg
                        return "MENU_ERROR: " & errMsg
                    end try
                end tell
                -- Poll for the file-open sheet to actually exist before typing
                -- the path. Up to ~5s (20 x 250ms). The Open panel attaches as a
                -- sheet (AXSheet) on the front window; some builds expose it as a
                -- standalone window with a chooser-style name instead.
                set fileOpenSeen to false
                repeat 20 times
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        try
                            if (exists sheet 1 of window 1) then
                                set fileOpenSeen to true
                            end if
                        end try
                        if fileOpenSeen is false then
                            try
                                if (exists (first window whose subrole is "AXDialog")) then
                                    set fileOpenSeen to true
                                end if
                            end try
                        end if
                    end tell
                    if fileOpenSeen then exit repeat
                    delay 0.25
                end repeat
                if fileOpenSeen is false then
                    return "DIALOG_NOT_FOUND: file-open sheet did not appear"
                end if
                delay 0.2
                -- Open the "Go to the folder" field, then SET its value directly.
                -- Typing the path char-by-char proved unreliable (the field kept
                -- only the leading "/" because the second keystroke did not land
                -- in the freshly-opened sheet), which left the open panel stuck
                -- and stacked dialogs on the next call. Poll the field into
                -- existence across both window topologies Logic exposes
                -- (sheet-on-window-1 vs standalone AXDialog) and assign AXValue.
                tell \(logicProAppleScript.systemEventsProcessTarget) to set frontmost to true
                delay 0.15
                keystroke "/"
                delay 0.4
                set goToSet to false
                repeat 20 times
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        -- Only accept the assignment once the field actually
                        -- READS BACK our path, so a race that targets the wrong
                        -- early text field cannot exit the loop prematurely.
                        try
                            set goDlg to first window whose subrole is "AXDialog"
                            set value of text field 1 of sheet 1 of goDlg to "\(escapedPath)"
                            if (value of text field 1 of sheet 1 of goDlg) is "\(escapedPath)" then
                                set goToSet to true
                            end if
                        end try
                        if goToSet is false then
                            try
                                set value of text field 1 of sheet 1 of window 1 to "\(escapedPath)"
                                if (value of text field 1 of sheet 1 of window 1) is "\(escapedPath)" then
                                    set goToSet to true
                                end if
                            end try
                        end if
                    end tell
                    if goToSet then exit repeat
                    delay 0.15
                end repeat
                if goToSet is false then
                    -- self-clean so we never leave a stuck panel for the next call
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        try
                            key code 53
                            delay 0.2
                            key code 53
                        end try
                    end tell
                    return "DIALOG_NOT_FOUND: go-to-folder field did not accept the path"
                end if
                delay 0.3
                tell \(logicProAppleScript.systemEventsProcessTarget) to set frontmost to true
                delay 0.15
                keystroke return
                -- Navigating to + selecting the file can take >1s, so poll the
                -- Import button into an ENABLED state before clicking rather than
                -- racing a fixed delay (clicking too early imports nothing and
                -- leaves the panel open).
                --
                -- #594: this was 20 x 200ms, and four seconds is enough for a WARM Open panel and
                -- not for the first one in a freshly created document. Measured five times across
                -- two locales: every failure was the first import after `project.new`, and every
                -- retry seconds later reached State A. That is the opening move an agent makes, so
                -- the operation was failing at first contact and succeeding for anyone who ignored
                -- its error.
                --
                -- 60 x 200ms, and the loop now records WHAT IT SAW rather than only whether it
                -- clicked, so a timeout can say which of "no panel", "panel but no button" and
                -- "button never enabled" actually happened.
                set importClicked to false
                set sawPanel to false
                set sawButton to false
                repeat 60 times
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        try
                            set importDlg to first window whose name is "가져오기"
                            set sawPanel to true
                            set ib to button "가져오기" of UI element 1 of importDlg
                            set sawButton to true
                            if (enabled of ib) then
                                click ib
                                set importClicked to true
                            end if
                        end try
                        if importClicked is false then
                            try
                                set importDlg to first window whose name is "Import"
                                set sawPanel to true
                                set ib to button "Import" of UI element 1 of importDlg
                                set sawButton to true
                                if (enabled of ib) then
                                    click ib
                                    set importClicked to true
                                end if
                            end try
                        end if
                    end tell
                    if importClicked then exit repeat
                    delay 0.2
                end repeat
                if importClicked is false then
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        repeat 3 times
                            if (exists (first window whose name is "Import")) or (exists (first window whose name is "가져오기")) then
                                key code 53
                                delay 0.2
                            else
                                exit repeat
                            end if
                        end repeat
                    end tell
                    -- #594: report the observation, not an inference. The old message asserted
                    -- "(file not selected)" — a cause this code never checked, inferred from the
                    -- button not enabling. A caller told a cause that was never measured cannot tell
                    -- a slow panel from a wrong path, and this operation's whole contract is that it
                    -- does not state what it did not observe.
                    if sawPanel is false then
                        return "IMPORT_BTN_ERROR: the Import panel never appeared after the path was accepted"
                    else if sawButton is false then
                        return "IMPORT_BTN_ERROR: the Import panel appeared but exposed no Import button"
                    else
                        return "IMPORT_BTN_ERROR: the Import button stayed disabled for the whole wait after the path was accepted"
                    end if
                end if
                -- Poll for the tempo dialog (subrole AXDialog) before dismissing
                -- rather than a fixed delay. ~3s (15 x 200ms).
                -- A lingering Import open-panel also has subrole AXDialog, so
                -- exclude it by name; only a genuine tempo alert counts.
                set tempoSeen to false
                repeat 15 times
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        try
                            if (exists (first window whose subrole is "AXDialog" and name is not "Import" and name is not "가져오기")) then
                                set tempoSeen to true
                            end if
                        end try
                    end tell
                    if tempoSeen then exit repeat
                    delay 0.2
                end repeat
                if tempoSeen then
                    tell \(logicProAppleScript.systemEventsProcessTarget)
                        try
                            set tempoDlg to first window whose subrole is "AXDialog" and name is not "Import" and name is not "가져오기"
                            try
                                click button "아니요" of tempoDlg
                            on error
                                try
                                    click button "No" of tempoDlg
                                end try
                            end try
                        end try
                    end tell
                end if
                -- Final self-heal: if an Import open-panel is somehow still up
                -- (failed mid-flow), dismiss it so the next call starts clean.
                tell \(logicProAppleScript.systemEventsProcessTarget)
                    repeat 3 times
                        if (exists (first window whose name is "Import")) or (exists (first window whose name is "가져오기")) then
                            key code 53
                            delay 0.2
                        else
                            exit repeat
                        end if
                    end repeat
                end tell
                if tempoSeen then
                    return "OK TEMPO_SEEN"
                end if
            end tell
            return "OK"
        end importMIDI
        return importMIDI()
        """
        // #452: the only measurement of the segment the osascript bound governs.
        // The clock brackets the call rather than the executor, so it observes
        // whatever actually ran — wrapping the injected closure instead would
        // measure the wrapper and prove nothing about production. Recorded on
        // every outcome, including timeout, because a segment that hit its bound
        // is exactly the one an operator needs the number for.
        let segmentStart = ContinuousClock.now
        let result = await executeScript(script)
        await OperationTraceContext.record(
            .scriptSegmentCompleted,
            attributes: ["applescript_duration_ms": elapsedMilliseconds(since: segmentStart)]
        )
        switch result {
        case .success(let output):
            let scriptOutput = normalizedAppleScriptPayload(output)
            if scriptOutput.hasPrefix("MENU_ERROR") || scriptOutput.hasPrefix("IMPORT_BTN_ERROR") {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "midi.import_file menu/button click failed: \(scriptOutput)",
                    extras: [
                        "requested": path,
                        "track_count_before": beforeCount,
                        "file_open_dialog_seen": false,
                        "tempo_dialog_seen": false,
                    ]
                ))
            }
            if scriptOutput.hasPrefix("DIALOG_NOT_FOUND") {
                return .error(HonestContract.encodeStateC(
                    error: .dialogNotFound,
                    hint: "midi.import_file: \(scriptOutput). The File → Import → MIDI File open sheet never appeared (likely an occluded or unhealthy Logic session). No path keystroke was issued.",
                    extras: [
                        "requested": path,
                        "track_count_before": beforeCount,
                        "missing_element": "file_open_sheet",
                        "file_open_dialog_seen": false,
                        "tempo_dialog_seen": false,
                    ]
                ))
            }
            let fileOpenSeen = true
            let tempoSeen = scriptOutput.contains("TEMPO_SEEN")
            // Read-back via track-count delta. Logic always creates a new track
            // for MIDI import (OQ-3 confirmed). Bounded poll (5 x 100ms) for the
            // AX tree to reflect the new header, rather than a single settle.
            var afterCount = readTrackCount()
            for _ in 0..<5 {
                if afterCount > beforeCount { break }
                await deltaPoll()
                afterCount = readTrackCount()
            }
            var extras: [String: Any] = [
                "requested": path,
                "track_count_before": beforeCount,
                "track_count_after": afterCount,
                "observed_delta": afterCount - beforeCount,
                "via": "ax_menu_import",
                "file_open_dialog_seen": fileOpenSeen,
                "tempo_dialog_seen": tempoSeen,
            ]
            if let beforeRegions {
                extras["region_count_before"] = beforeRegions.count
            }
            if let beforeRegionError {
                extras["region_readback_before_error"] = beforeRegionError
            }
            var afterRegions: [RegionInfo]?
            var afterRegionError: String?
            var addedRegions: [RegionInfo] = []
            var importedRegions: [RegionInfo] = []
            // Whether the LAST successful post-write read covered the whole arrangement. Only that
            // reading decides the verdict below, so a stale completeness from an earlier attempt
            // must not survive into it.
            var afterReadbackComplete = false
            for attempt in 0..<10 {
                switch readRegionInfos() {
                case .success(let regions, let complete):
                    afterRegions = regions
                    afterRegionError = nil
                    afterReadbackComplete = complete
                    addedRegions = addedMIDIRegionsForImport(
                        afterRegions: regions,
                        beforeRegionKeys: beforeRegionKeys
                    )
                    importedRegions = newMIDIRegionsForImport(
                        afterRegions: regions,
                        beforeRegionKeys: beforeRegionKeys,
                        beforeCount: beforeCount,
                        afterCount: afterCount
                    )
                    if !importedRegions.isEmpty { break }
                case .failure(let error):
                    afterRegionError = error
                }
                if attempt < 9 {
                    await deltaPoll()
                }
            }
            if let afterRegions {
                extras["region_count_after"] = afterRegions.count
                extras["new_midi_region_count"] = addedRegions.count
                extras["new_midi_regions"] = addedRegions.map(midiImportRegionFields)
                extras["imported_region_count"] = importedRegions.count
                extras["imported_regions"] = importedRegions.map(midiImportRegionFields)
            }
            if let afterRegionError {
                extras["region_readback_after_error"] = afterRegionError
            }
            guard afterCount > beforeCount else {
                return .error(HonestContract.encodeStateC(
                    error: .readbackMismatch,
                    hint: "midi.import_file did not create a new track",
                    extras: extras
                ))
            }
            // #128 — audibility downgrade. A count delta proves a track was
            // created, NOT that it is audible. If any NEW lane is a GM Device /
            // external-MIDI synth lane, downgrade State A → State B so a caller
            // never treats it as a verified audible arrangement.
            let names = readTrackNames()
            let gmLanes = gmDeviceLanesAmongNewTracks(names: names, beforeCount: beforeCount)
            if !gmLanes.isEmpty {
                extras["imported_lanes"] = Array(names.suffix(from: min(beforeCount, names.count)))
                extras["gm_device_lanes"] = gmLanes
                extras["audible"] = false
                extras["hint"] = "Imported SMF lanes \(gmLanes) are GM Device / external-MIDI synth lanes that route to a General MIDI device and may bounce SILENT. Assign an audible Software Instrument (e.g. create a Software Instrument track and copy the regions, or re-import onto a Software Instrument track) before relying on the bounce."
                return .success(HonestContract.encodeStateB(
                    reason: .importedAsGMDevice,
                    extras: extras
                ))
            }
            if let afterRegionError {
                return .error(HonestContract.encodeStateC(
                    error: .readbackUnavailable,
                    hint: "midi.import_file created a new track, but AX region readback was unavailable: \(afterRegionError)",
                    extras: extras
                ))
            }
            guard !importedRegions.isEmpty else {
                // An empty region result is NOT evidence that no region was imported. The reader is
                // `enumerateRegionItems`, and `defaultGetRegions` publishes what it can see on every
                // successful read: `complete: false`, `scope: "visible_arrange_area"`,
                // `reason: "logic_ax_viewport_only"`. Logic only exposes regions for the part of the
                // arrangement in view, so once a project outgrows the viewport the freshly imported
                // track is off-screen and its region is unreadable.
                //
                // Measured on Logic 12.3, 2026-08-17, same binary and project, repeated calls:
                //
                //     track 13   verified: true, region read back
                //     track 14   track_count 14 -> 15, region_count 13 -> 13, no region found
                //     track 15   the same
                //
                // The import worked — Logic created the track — and the reading did not. Reporting
                // that as a definite failure sends the caller to retry, which creates a SECOND track
                // and a second region and fails again, compounding the mess it says did not happen.
                //
                // So this is State B: the write was attempted, the track-count delta confirms
                // something was created, and the region could not be confirmed by an instrument that
                // cannot see the whole arrangement. It is deliberately not conditional on a project
                // size — the reader never claims completeness, so an empty answer is never proof.
                // #576 made this branch State B unconditionally, because completeness was a hardcoded
                // `false` and an absent region could never be told from an unseen one. It is measured
                // now, so the sharper verdict comes back for the case where it is knowable: a readback
                // that covered the WHOLE arrangement and still found no imported region is evidence
                // that none was created.
                guard !afterReadbackComplete else {
                    extras["region_readback_complete"] = true
                    extras["region_readback_scope"] = "whole_arrangement"
                    return .error(HonestContract.encodeStateC(
                        error: .readbackMismatch,
                        hint: "midi.import_file created a new track but did not create a verifiable "
                            + "MIDI region. The region readback covered the whole arrangement, so "
                            + "this is an absence that was looked for, not one that was out of view.",
                        extras: extras
                    ))
                }
                extras["region_readback_complete"] = false
                extras["region_readback_scope"] = AccessibilityChannel.regionReadbackScope
                extras["region_readback_limit"] = AccessibilityChannel.regionReadbackLimitReason
                // Built before the call rather than inside the dictionary literal. As one
                // expression — a five-way `+` chain with interpolation, inside a dictionary
                // literal, passed to `merging` with a trailing closure — Swift type-checks the
                // whole thing at once, and whether that finishes inside the solver's limit depends
                // on the toolchain: it compiled here and timed out for a contributor pulling main
                // cold, which blocked their build entirely (#749).
                let readbackHint = "midi.import_file created a new track, but no imported MIDI "
                    + "region was visible to the region readback. That readback only covers the "
                    + "\(AccessibilityChannel.regionReadbackScope), so this is not evidence "
                    + "the import produced nothing — a track outside the visible arrangement "
                    + "reads the same way. Do NOT retry blindly: the track-count delta shows "
                    + "a track was already created, and a second call would create another."
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extras.merging(["hint": readbackHint]) { _, new in new }
                ))
            }
            return .success(HonestContract.encodeStateA(extras: extras))
        case .error(let msg):
            if HonestContract.stateCErrorCode(msg) == HonestContract.FailureError.systemEventsAutomationDenied.rawValue {
                return .error(msg)
            }
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "midi.import_file osascript failed: \(msg)",
                extras: [
                    "requested": path,
                    "track_count_before": beforeCount,
                    "file_open_dialog_seen": false,
                    "tempo_dialog_seen": false,
                ]
            ))
        }
    }

}
