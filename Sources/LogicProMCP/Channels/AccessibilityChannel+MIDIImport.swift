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
        case success([RegionInfo])
        case failure(String)
    }

    private static func defaultMIDIImportRegionInfos(
        runtime: AXLogicProElements.Runtime
    ) -> MIDIImportRegionReadback {
        switch enumerateRegionItems(runtime: runtime) {
        case .success(let result):
            return .success(result.regions.map { $0.info })
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
        executeScript: @escaping @Sendable (String) async -> ChannelResult = { await AppleScriptChannel.executeAppleScript($0) },
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
                error: .permissionDenied,
                hint: "midi.import_file requires Automation access to System Events. Grant it in System Settings > Privacy & Security > Automation → allow your launcher app to control System Events, then retry.",
                extras: [
                    "permission": "automation_system_events",
                    "failure_stage": "preflight_system_events_permission",
                    "write_attempted": false,
                    "safe_to_retry": true,
                    "remediation": "System Settings > Privacy & Security > Automation → allow control of System Events",
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
        case .success(let regions):
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
        let script = """
        on importMIDI()
            tell application "Logic Pro" to activate
            delay 0.3
            tell application "System Events"
                -- Self-heal: dismiss a stale Import open-panel left by a prior
                -- failed run so repeated imports never stack file-open dialogs.
                tell process "Logic Pro"
                    repeat 4 times
                        if (exists (first window whose name is "Import")) or (exists (first window whose name is "가져오기")) then
                            key code 53
                            delay 0.25
                        else
                            exit repeat
                        end if
                    end repeat
                end tell
                tell process "Logic Pro"
                    try
                        click menu item "MIDI 파일…" of menu 1 of menu item "가져오기" of menu 1 of menu bar item "파일" of menu bar 1
                    on error
                        try
                            click menu item "MIDI File…" of menu 1 of menu item "Import" of menu 1 of menu bar item "File" of menu bar 1
                        on error errMsg
                            return "MENU_ERROR: " & errMsg
                        end try
                    end try
                end tell
                -- Poll for the file-open sheet to actually exist before typing
                -- the path. Up to ~5s (20 x 250ms). The Open panel attaches as a
                -- sheet (AXSheet) on the front window; some builds expose it as a
                -- standalone window with a chooser-style name instead.
                set fileOpenSeen to false
                repeat 20 times
                    tell process "Logic Pro"
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
                tell process "Logic Pro" to set frontmost to true
                delay 0.15
                keystroke "/"
                delay 0.4
                set goToSet to false
                repeat 20 times
                    tell process "Logic Pro"
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
                    tell process "Logic Pro"
                        try
                            key code 53
                            delay 0.2
                            key code 53
                        end try
                    end tell
                    return "DIALOG_NOT_FOUND: go-to-folder field did not accept the path"
                end if
                delay 0.3
                tell process "Logic Pro" to set frontmost to true
                delay 0.15
                keystroke return
                -- Navigating to + selecting the file can take >1s, so poll the
                -- Import button into an ENABLED state before clicking rather than
                -- racing a fixed delay (clicking too early imports nothing and
                -- leaves the panel open). ~4s (20 x 200ms).
                set importClicked to false
                repeat 20 times
                    tell process "Logic Pro"
                        try
                            set importDlg to first window whose name is "가져오기"
                            set ib to button "가져오기" of UI element 1 of importDlg
                            if (enabled of ib) then
                                click ib
                                set importClicked to true
                            end if
                        end try
                        if importClicked is false then
                            try
                                set importDlg to first window whose name is "Import"
                                set ib to button "Import" of UI element 1 of importDlg
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
                    tell process "Logic Pro"
                        repeat 3 times
                            if (exists (first window whose name is "Import")) or (exists (first window whose name is "가져오기")) then
                                key code 53
                                delay 0.2
                            else
                                exit repeat
                            end if
                        end repeat
                    end tell
                    return "IMPORT_BTN_ERROR: Import button never became enabled (file not selected)"
                end if
                -- Poll for the tempo dialog (subrole AXDialog) before dismissing
                -- rather than a fixed delay. ~3s (15 x 200ms).
                -- A lingering Import open-panel also has subrole AXDialog, so
                -- exclude it by name; only a genuine tempo alert counts.
                set tempoSeen to false
                repeat 15 times
                    tell process "Logic Pro"
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
                    tell process "Logic Pro"
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
                tell process "Logic Pro"
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
        let result = await executeScript(script)
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
            for attempt in 0..<10 {
                switch readRegionInfos() {
                case .success(let regions):
                    afterRegions = regions
                    afterRegionError = nil
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
                return .error(HonestContract.encodeStateC(
                    error: .readbackMismatch,
                    hint: "midi.import_file created a new track but did not create a verifiable MIDI region",
                    extras: extras
                ))
            }
            return .success(HonestContract.encodeStateA(extras: extras))
        case .error(let msg):
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
