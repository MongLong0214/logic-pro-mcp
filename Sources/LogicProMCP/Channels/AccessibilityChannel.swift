import ApplicationServices
import AppKit
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility
    private let runtime: Runtime

    // T4: actor state for scanLibraryAll orchestration
    private var scanInProgress: Bool = false
    private var lastScan: LibraryRoot? = nil
    private var lastRoutedCategory: String? = nil
    private var lastRoutedPreset: String? = nil

    enum MixerTarget {
        case volume
        case pan
    }

    struct Runtime: @unchecked Sendable {
        let isTrusted: @Sendable () -> Bool
        let isLogicProRunning: @Sendable () -> Bool
        let appRoot: @Sendable () -> AXUIElement?
        let transportState: @Sendable () -> ChannelResult
        let toggleTransportButton: @Sendable (String) -> ChannelResult
        let setTempo: @Sendable ([String: String]) -> ChannelResult
        let setCycleRange: @Sendable ([String: String]) -> ChannelResult
        let tracks: @Sendable () -> ChannelResult
        let selectedTrack: @Sendable () -> ChannelResult
        let selectTrack: @Sendable ([String: String]) async -> ChannelResult
        let setTrackToggle: @Sendable ([String: String], String) -> ChannelResult
        let renameTrack: @Sendable ([String: String]) -> ChannelResult
        let mixerState: @Sendable () -> ChannelResult
        let channelStrip: @Sendable ([String: String]) -> ChannelResult
        let setMixerValue: @Sendable ([String: String], MixerTarget) -> ChannelResult
        let projectInfo: @Sendable () -> ChannelResult
        let markers: @Sendable () -> ChannelResult
        let importMIDIFile: @Sendable (String) async -> ChannelResult
        let logicRuntime: AXLogicProElements.Runtime

        init(
            isTrusted: @escaping @Sendable () -> Bool,
            isLogicProRunning: @escaping @Sendable () -> Bool,
            appRoot: @escaping @Sendable () -> AXUIElement?,
            transportState: @escaping @Sendable () -> ChannelResult,
            toggleTransportButton: @escaping @Sendable (String) -> ChannelResult,
            setTempo: @escaping @Sendable ([String: String]) -> ChannelResult,
            setCycleRange: @escaping @Sendable ([String: String]) -> ChannelResult,
            tracks: @escaping @Sendable () -> ChannelResult,
            selectedTrack: @escaping @Sendable () -> ChannelResult,
            selectTrack: @escaping @Sendable ([String: String]) async -> ChannelResult,
            setTrackToggle: @escaping @Sendable ([String: String], String) -> ChannelResult,
            renameTrack: @escaping @Sendable ([String: String]) -> ChannelResult,
            mixerState: @escaping @Sendable () -> ChannelResult,
            channelStrip: @escaping @Sendable ([String: String]) -> ChannelResult,
            setMixerValue: @escaping @Sendable ([String: String], MixerTarget) -> ChannelResult,
            projectInfo: @escaping @Sendable () -> ChannelResult,
            markers: @escaping @Sendable () -> ChannelResult = { .success("[]") },
            importMIDIFile: @escaping @Sendable (String) async -> ChannelResult = { _ in .error("importMIDIFile not wired") },
            logicRuntime: AXLogicProElements.Runtime = .production
        ) {
            self.isTrusted = isTrusted
            self.isLogicProRunning = isLogicProRunning
            self.appRoot = appRoot
            self.transportState = transportState
            self.toggleTransportButton = toggleTransportButton
            self.setTempo = setTempo
            self.setCycleRange = setCycleRange
            self.tracks = tracks
            self.selectedTrack = selectedTrack
            self.selectTrack = selectTrack
            self.setTrackToggle = setTrackToggle
            self.renameTrack = renameTrack
            self.mixerState = mixerState
            self.channelStrip = channelStrip
            self.setMixerValue = setMixerValue
            self.projectInfo = projectInfo
            self.markers = markers
            self.importMIDIFile = importMIDIFile
            self.logicRuntime = logicRuntime
        }

        static func axBacked(
            isTrusted: @escaping @Sendable () -> Bool = AXIsProcessTrusted,
            isLogicProRunning: @escaping @Sendable () -> Bool = { ProcessUtils.isLogicProRunning },
            logicRuntime: AXLogicProElements.Runtime = .production,
            runTempoFallback: @escaping @Sendable (String) -> Bool = { tempo in
                AccessibilityChannel.runTempoFallbackScript(tempo: tempo)
            }
        ) -> Runtime {
            Runtime(
                isTrusted: isTrusted,
                isLogicProRunning: isLogicProRunning,
                appRoot: { AXLogicProElements.appRoot(runtime: logicRuntime) },
                transportState: { AccessibilityChannel.defaultGetTransportState(runtime: logicRuntime) },
                toggleTransportButton: { AccessibilityChannel.defaultToggleTransportButton(named: $0, runtime: logicRuntime) },
                setTempo: { AccessibilityChannel.defaultSetTempo(params: $0, runtime: logicRuntime, runFallback: runTempoFallback) },
                setCycleRange: { AccessibilityChannel.defaultSetCycleRange(params: $0, runtime: logicRuntime) },
                tracks: { AccessibilityChannel.defaultGetTracks(runtime: logicRuntime) },
                selectedTrack: { AccessibilityChannel.defaultGetSelectedTrack(runtime: logicRuntime) },
                selectTrack: { await AccessibilityChannel.defaultSelectTrack(params: $0, runtime: logicRuntime) },
                setTrackToggle: { AccessibilityChannel.defaultSetTrackToggle(params: $0, button: $1, runtime: logicRuntime) },
                renameTrack: { AccessibilityChannel.defaultRenameTrack(params: $0, runtime: logicRuntime) },
                mixerState: { AccessibilityChannel.defaultGetMixerState(runtime: logicRuntime) },
                channelStrip: { AccessibilityChannel.defaultGetChannelStrip(params: $0, runtime: logicRuntime) },
                setMixerValue: { AccessibilityChannel.defaultSetMixerValue(params: $0, target: $1, runtime: logicRuntime) },
                projectInfo: { AccessibilityChannel.defaultGetProjectInfo(runtime: logicRuntime) },
                markers: { AccessibilityChannel.defaultGetMarkers(runtime: logicRuntime) },
                importMIDIFile: { await AccessibilityChannel.defaultImportMIDIFile(path: $0, runtime: logicRuntime) },
                logicRuntime: logicRuntime
            )
        }

        static let production = Runtime.axBacked()
    }

    init(runtime: Runtime = .production) {
        self.runtime = runtime
    }

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = runtime.isTrusted()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard runtime.isLogicProRunning() else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard runtime.isLogicProRunning() else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return runtime.transportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return runtime.toggleTransportButton("Cycle")
        case "transport.toggle_metronome":
            return runtime.toggleTransportButton("Metronome")
        case "transport.toggle_count_in":
            return runtime.toggleTransportButton("CountIn")

        case "transport.play":
            return runtime.toggleTransportButton("Play")
        case "transport.stop":
            return runtime.toggleTransportButton("Stop")
        case "transport.record":
            return runtime.toggleTransportButton("Record")

        case "transport.set_tempo":
            return runtime.setTempo(params)
        case "transport.set_cycle_range":
            return runtime.setCycleRange(params)

        case "transport.goto_position":
            return await AccessibilityChannel.gotoPositionViaBarSlider(
                params: params, runtime: runtime.logicRuntime
            )

        // MARK: - Track reads
        case "track.get_tracks":
            return runtime.tracks()
        case "track.get_selected":
            return runtime.selectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return await runtime.selectTrack(params)
        case "track.set_mute":
            return runtime.setTrackToggle(params, "Mute")
        case "track.set_solo":
            return runtime.setTrackToggle(params, "Solo")
        case "track.set_arm":
            return runtime.setTrackToggle(params, "Record")
        case "track.rename":
            return runtime.renameTrack(params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Library (instrument patch) operations
        case "library.list":
            return AccessibilityChannel.listLibrary(runtime: runtime.logicRuntime)
        case "library.scan_all":
            // E15: atomic check-and-set within actor step (no suspension points)
            if scanInProgress {
                return .error("Library scan already in progress")
            }
            scanInProgress = true
            defer { scanInProgress = false }
            return await self.runLiveScan(runtime: runtime.logicRuntime)
        case "library.resolve_path":
            return AccessibilityChannel.resolveLibraryPath(
                params: params, lastScan: lastScan
            )
        case "plugin.scan_presets":
            // F2 minimal scan handler — relies on currently-focused plugin window.
            // Full T6 (cache, persistence, axScanInProgress rename, AC-1.5b trackIndex
            // precedence) is follow-up. This handler delivers live menu enumeration.
            if scanInProgress {
                return .error("AX scan already in progress")
            }
            scanInProgress = true
            defer { scanInProgress = false }
            let settleMs = Int(params["submenuOpenDelayMs"] ?? "250") ?? 250
            return await AccessibilityChannel.runLivePluginPresetScan(
                runtime: runtime.logicRuntime, settleMs: settleMs
            )
        case "track.set_instrument":
            let result = await AccessibilityChannel.setTrackInstrument(
                params: params, runtime: runtime.logicRuntime
            )
            // T4 Tier-A cache population: remember what we routed for future scan restore.
            // Covers both legacy {category, preset} and path-mode {path} callers.
            if result.isSuccess {
                if let cat = params["category"], !cat.isEmpty,
                   let pre = params["preset"], !pre.isEmpty {
                    lastRoutedCategory = cat
                    lastRoutedPreset = pre
                } else if let path = params["path"],
                          let parts = LibraryAccessor.parsePath(path),
                          parts.count >= 2 {
                    lastRoutedCategory = parts[0]
                    lastRoutedPreset = parts[parts.count - 1]
                }
            }
            return result

        // MARK: - Project save_as via AX dialog
        case "project.save_as":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.save_as")
            }
            return await AccessibilityChannel.saveAsViaAXDialog(path: path, runtime: runtime.logicRuntime)

        // MARK: - Track creation via menu click
        case "track.create_instrument":
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 소프트웨어 악기 트랙",
                english: "New Software Instrument Track",
                runtime: runtime.logicRuntime
            )
        case "track.create_audio":
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 오디오 트랙",
                english: "New Audio Track",
                runtime: runtime.logicRuntime
            )
        case "track.create_drummer":
            // Logic 12.0.1+: menu renamed to "Session Player SI" with Drummer as
            // a sub-option in the dialog. Try Logic 12 menu first; fall back to
            // Logic 11's "Drummer 트랙" for older installs.
            let l12 = await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 Session Player SI 트랙…",
                english: "New Session Player SI Track…",
                runtime: runtime.logicRuntime
            )
            if l12.isSuccess { return l12 }
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 Drummer 트랙",
                english: "New Drummer Track",
                runtime: runtime.logicRuntime
            )
        case "track.create_external_midi":
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 외부 MIDI 트랙",
                english: "New External MIDI Track",
                runtime: runtime.logicRuntime
            )

        case "track.delete":
            // Logic 12 has no default keyboard shortcut for "Delete Track" —
            // CGEvent fallback was wrong (Cmd+Delete deletes regions, not the
            // track). Click the Track menu item directly.
            return AccessibilityChannel.clickTrackMenu(
                "트랙 삭제",
                menuName: "트랙",
                englishMenuName: "Track",
                runtime: runtime.logicRuntime
            )

        // MARK: - Mixer reads
        case "mixer.get_state":
            return runtime.mixerState()
        case "mixer.get_channel_strip":
            return runtime.channelStrip(params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return runtime.setMixerValue(params, .volume)
        case "mixer.set_pan":
            return runtime.setMixerValue(params, .pan)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - MIDI file import (AX menu navigation)
        case "midi.import_file":
            guard let path = params["path"] else {
                return .error("midi.import_file requires 'path'")
            }
            // Restrict to the SMFWriter-managed temp dir. Raw MCP callers
            // cannot point the AX open-panel keystroke at arbitrary files
            // on the user's filesystem — the only legitimate producer of
            // this operation is TrackDispatcher.record_sequence.
            guard path.hasPrefix("/tmp/LogicProMCP/"),
                  path.hasSuffix(".mid"),
                  !path.contains("..") else {
                return .error("midi.import_file path must be /tmp/LogicProMCP/*.mid")
            }
            return await runtime.importMIDIFile(path)

        // MARK: - Navigation
        case "nav.get_markers":
            return runtime.markers()
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return runtime.projectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return AccessibilityChannel.defaultGetRegions(runtime: runtime.logicRuntime)
        case "region.move_to_playhead":
            return await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead()
        case "region.select_last":
            return await AccessibilityChannel.defaultSelectLastRegion()
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        // plugin.insert / plugin.bypass / plugin.remove were removed from the
        // router in v2.2 — no public path reaches this branch for those ops.
        // plugin.list is still advertised while we wait for a real AX
        // enumeration; it is the only survivor here.
        case "plugin.list":
            return .error("Plugin list reading not yet implemented via AX")

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard runtime.isTrusted() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard runtime.isLogicProRunning() else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard runtime.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Transport

    private static func defaultGetTransportState(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar(runtime: runtime) else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime.ax)
        return encodeResult(state)
    }

    private static func defaultToggleTransportButton(
        named name: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        // Try the Logic Pro 12 control-bar checkbox first (Korean + English UI).
        // Falls back to legacy toolbar button search.
        let controlBarMapping: [String: (korean: String, english: String, desired: Bool?)] = [
            "Cycle":      ("사이클",        "Cycle",     nil),
            "Metronome":  ("메트로놈 클릭",  "Metronome", nil),
            "CountIn":    ("카운트 인",     "Count-in",  nil),
            "Play":       ("재생",          "Play",      true),
            "Stop":       ("재생",          "Play",      false),
            "Record":     ("녹음",          "Record",    true),
        ]
        // Stop semantics: clear Record too (else recording continues even after Play=false).
        // Avoids regression where stop() during recording leaves track in armed-record loop.
        if name == "Stop" {
            _ = AccessibilityChannel.setControlBarCheckboxValue(
                korean: "녹음", english: "Record", desired: false, runtime: runtime
            )
        }
        if let mapping = controlBarMapping[name] {
            if let desired = mapping.desired {
                // Conditional toggle: only click if current != desired
                if let result = AccessibilityChannel.setControlBarCheckboxValue(
                    korean: mapping.korean, english: mapping.english, desired: desired, runtime: runtime
                ) {
                    return result
                }
            } else {
                // Unconditional toggle
                if let result = AccessibilityChannel.clickControlBarCheckbox(
                    korean: mapping.korean, english: mapping.english, runtime: runtime
                ) {
                    return result
                }
            }
        }
        // Legacy fallback: search by role=Button with title/description.
        guard let button = AXLogicProElements.findTransportButton(named: name, runtime: runtime) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    private static func defaultSetTempo(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        runFallback: @escaping @Sendable (String) -> Bool = runTempoFallbackScript
    ) -> ChannelResult {
        // TransportDispatcher passes the value under "bpm"; legacy callers may
        // still send "tempo". Accept either to avoid silent contract drift.
        guard let tempoStr = params["bpm"] ?? params["tempo"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo'/'bpm' parameter")
        }
        // Try AX text field first
        if let transport = AXLogicProElements.getTransportBar(runtime: runtime) {
            let texts = AXHelpers.findAllDescendants(
                of: transport,
                role: kAXTextFieldRole,
                maxDepth: 4,
                runtime: runtime.ax
            )
            for field in texts {
                let desc = AXHelpers.getDescription(field, runtime: runtime.ax)?.lowercased() ?? ""
                if desc.contains("tempo") || desc.contains("bpm") {
                    AXHelpers.setAttribute(field, kAXValueAttribute, tempoStr as CFTypeRef, runtime: runtime.ax)
                    AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
                    return .success("{\"tempo\":\(tempoStr),\"via\":\"ax\"}")
                }
            }
        }
        // Fallback: AppleScript Tap-Tempo via Logic key command — at minimum locates
        // the tempo display element via System Events and types the value.
        // Logic Pro 12.0.1 transport bar exposes an AXButton whose AXDescription
        // contains the tempo number. Open Tempo entry via menu "탐색 → 템포…" if available.
        // osascript fallback was disabled — it opened a modal Tempo dialog that
        // grabs Logic's UI thread, and sustained calls killed the MCP server
        // via pipe/FD exhaustion (BrokenPipeError at §K in the matrix test).
        // If AX tempo field is unreachable, just return a clear error — users
        // can set tempo manually in Logic's transport bar.
        _ = runFallback // retain parameter for test injection compatibility
        return .error(
            "set_tempo: Logic's transport bar doesn't expose a tempo text field via AX in this build. " +
            "Set tempo manually in Logic's control bar (double-click the BPM display)."
        )
    }

    private static func runTempoFallbackScript(tempo: String) -> Bool {
        let script = """
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                delay 0.2
                -- Open Tempo & Project Settings (⌥+⌘+T)
                key code 17 using {command down, option down}
                delay 0.4
                -- The tempo input field should be focused; type new value
                keystroke "\(tempo)"
                delay 0.1
                key code 36
                delay 0.2
                key code 53
            end tell
        end tell
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        // Route output to the shared FileHandle.nullDevice — no FD opened per
        // invocation. Earlier attempt with FileHandle(forWritingAtPath:"/dev/null")
        // still leaked one FD per call because it wasn't explicitly closed.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        // 5s hard cap — script intent is < 1.5s, anything longer means Logic
        // is unresponsive (modal dialog stuck, focus lost, etc.).
        let deadline = Date().addingTimeInterval(5.0)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if task.isRunning { task.interrupt() }
            task.waitUntilExit() // reap zombie
            return false
        }
        return task.terminationStatus == 0
    }

    private static func defaultSetCycleRange(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        runFallback: @escaping @Sendable (String, String) -> Bool = runCycleRangeFallbackScript
    ) -> ChannelResult {
        guard let startStr = params["start"], let endStr = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        // Normalise input: accept plain bar int ("5") or full bar/beat string ("5.1.1.1").
        let startPos = startStr.contains(".") ? startStr : "\(startStr).1.1.1"
        let endPos = endStr.contains(".") ? endStr : "\(endStr).1.1.1"

        // AX path: locate cycle locator text fields in the transport bar.
        // Logic Pro exposes two text fields whose descriptions contain
        // "cycle" + "start"/"end" (both ko/en locales covered).
        if let transport = AXLogicProElements.getTransportBar(runtime: runtime) {
            let texts = AXHelpers.findAllDescendants(
                of: transport,
                role: kAXTextFieldRole,
                maxDepth: 6,
                runtime: runtime.ax
            )
            var startField: AXUIElement?
            var endField: AXUIElement?
            for field in texts {
                let desc = (AXHelpers.getDescription(field, runtime: runtime.ax) ?? "").lowercased()
                // Match on description fragments present in both Korean and English Logic builds.
                if startField == nil && (desc.contains("cycle") || desc.contains("사이클"))
                    && (desc.contains("start") || desc.contains("시작") || desc.contains("in") || desc.contains("left")) {
                    startField = field
                }
                if endField == nil && (desc.contains("cycle") || desc.contains("사이클"))
                    && (desc.contains("end") || desc.contains("끝") || desc.contains("out") || desc.contains("right")) {
                    endField = field
                }
            }
            if let s = startField, let e = endField {
                AXHelpers.setAttribute(s, kAXValueAttribute, startPos as CFTypeRef, runtime: runtime.ax)
                AXHelpers.performAction(s, kAXConfirmAction, runtime: runtime.ax)
                AXHelpers.setAttribute(e, kAXValueAttribute, endPos as CFTypeRef, runtime: runtime.ax)
                AXHelpers.performAction(e, kAXConfirmAction, runtime: runtime.ax)
                return .success("{\"start\":\"\(startPos)\",\"end\":\"\(endPos)\",\"via\":\"ax\"}")
            }
        }

        // Fallback: osascript using Logic's "Go To Position" dialog combined with
        // "Set Cycle Locators by Selection" isn't reliable without a region.
        // Use direct keystroke into the transport cycle display fields via
        // `click at` on the transport strip. Success is reported as unverified
        // because Logic's cycle locator state isn't readable via the cached
        // transport snapshot (cycle bar positions aren't in the state schema).
        if runFallback(startPos, endPos) {
            return .success("{\"start\":\"\(startPos)\",\"end\":\"\(endPos)\",\"via\":\"osascript\",\"verified\":false}")
        }
        return .error(
            "set_cycle_range: Logic's cycle locators aren't exposed as AX text fields in this build (tried ko/en locales). " +
            "Workarounds: (1) select the region covering the desired cycle and use Navigate > '선택 범위로 로케이터 설정 및 사이클 활성화'. " +
            "(2) Drag the upper ruler to set locators manually. " +
            "The MCP server cannot currently set numeric cycle locators programmatically."
        )
    }

    private static func runCycleRangeFallbackScript(startPos: String, endPos: String) -> Bool {
        // Strategy: use Logic's "Go To > Go To Beginning" (not ideal) — we instead
        // rely on the menu path "Navigate > Set Locators…" which opens a dialog
        // with start/end text fields. Keystroke start, Tab, end, Return.
        // Menu path (Logic 12, ko): "탐색 > 로케이터 설정…"; (en): "Navigate > Set Locators…"
        let script = """
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                delay 0.2
                -- Attempt Korean menu first
                try
                    click menu item "로케이터 설정…" of menu 1 of menu bar item "탐색" of menu bar 1
                on error
                    try
                        click menu item "Set Locators…" of menu 1 of menu bar item "Navigate" of menu bar 1
                    on error
                        return "no-menu"
                    end try
                end try
                delay 0.3
                keystroke "\(startPos)"
                key code 48   -- Tab
                delay 0.1
                keystroke "\(endPos)"
                delay 0.1
                key code 36   -- Return
                delay 0.2
                return "ok"
            end tell
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        // Stdout captured via Pipe (need the "ok" sentinel). Stderr discarded
        // via nullDevice to avoid the FD leak that killed the MCP server under
        // sustained matrix runs (sprint 51 osascript root cause).
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        // Read then close the pipe explicitly so its FDs release immediately
        // rather than lingering until Pipe deinit.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result == "ok"
    }

    // MARK: - Tracks

    private static func defaultGetTracks(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        if headers.isEmpty {
            // Empty is a valid steady state (no project open / project picker
            // front). Return an empty list so the StatePoller can overwrite
            // stale cache from a prior session instead of silently holding
            // onto ghost tracks that break rename/mute/arm ops on index 0.
            return encodeResult([TrackState]())
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private static func defaultGetSelectedTrack(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header, runtime: runtime.ax) == true {
                let track = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    private static func defaultSelectTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to select track \(index)")
        }

        let verification = await verifyTrackSelection(index: index, runtime: runtime)
        switch verification {
        case .verified:
            return .success("{\"selected\":\(index),\"verified\":true}")
        case .selectionMetadataUnavailable:
            return .success("{\"selected\":\(index),\"verified\":false}")
        case .mismatch(let selectedIndex):
            if let selectedIndex {
                return .error("Track selection did not settle on index \(index); current selected index is \(selectedIndex)")
            }
            return .error("Track selection did not settle on index \(index)")
        case .trackDisappeared:
            return .error("Track at index \(index) disappeared during selection verification")
        }
    }

    private static func defaultSetTrackToggle(
        params: [String: String],
        button buttonName: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": { AXLogicProElements.findTrackMuteButton(trackIndex: $0, runtime: runtime) }
        case "Solo": { AXLogicProElements.findTrackSoloButton(trackIndex: $0, runtime: runtime) }
        case "Record": { AXLogicProElements.findTrackArmButton(trackIndex: $0, runtime: runtime) }
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        // Press toggles state. To make `enabled: true/false` idempotent (the
        // user-visible contract), read current AXValue — only press when the
        // target state differs. This fixes the class of bug where `arm off`
        // was a silent no-op because MCU release-only was being sent and the
        // AX press was unconditionally toggling regardless of desired state.
        let desired: Bool = (params["enabled"] ?? "true") == "true"
        let current: Bool? = {
            if let raw = AXHelpers.getValue(button, runtime: runtime.ax) as? Int { return raw != 0 }
            if let raw = AXHelpers.getValue(button, runtime: runtime.ax) as? Bool { return raw }
            if let raw = AXHelpers.getValue(button, runtime: runtime.ax) as? NSNumber { return raw.boolValue }
            return nil
        }()
        if let cur = current, cur == desired {
            return .success("{\"track\":\(index),\"\(buttonName)\":\(desired),\"action\":\"no-op\"}")
        }

        func readCurrent() -> Bool? {
            guard let v = AXHelpers.getValue(button, runtime: runtime.ax) else { return nil }
            if let n = v as? NSNumber { return n.boolValue }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            if let s = v as? String { return s == "1" || s.lowercased() == "true" }
            return nil
        }

        // Escalating strategy: each step verified by read-back. Stops on success.
        // Logic Pro's custom AX checkboxes differ in what triggers them — some
        // respond to AXPress, some only to direct value writes, some need a
        // real mouse click at the button's screen position.
        let strategies: [(String, () -> Void)] = [
            ("press", { _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) }),
            ("confirm", { _ = AXHelpers.performAction(button, kAXConfirmAction, runtime: runtime.ax) }),
            ("value-nsnumber", {
                let n: NSNumber = desired ? 1 : 0
                AXHelpers.setAttribute(button, kAXValueAttribute, n as CFTypeRef, runtime: runtime.ax)
            }),
            ("value-cfbool", {
                let b: CFBoolean = desired ? kCFBooleanTrue : kCFBooleanFalse
                AXHelpers.setAttribute(button, kAXValueAttribute, b, runtime: runtime.ax)
            }),
            ("mouse-click", {
                Self.postMouseClickAt(element: button, runtime: runtime.ax)
            }),
        ]
        for (name, action) in strategies {
            action()
            // Logic Pro updates AX tree asynchronously after a click — a 50 ms
            // settle is enough on Apple Silicon for the rec-arm checkbox to
            // repaint and reflect the new value via AXValue.
            usleep(50_000)
            if let after = readCurrent(), after == desired {
                return .success("{\"track\":\(index),\"\(buttonName)\":\(desired),\"action\":\"\(name)\"}")
            }
        }
        return .error("Failed to set \(buttonName)=\(desired) on track \(index) — tried press/confirm/value/click, read-back never matched")
    }

    /// Simulate a real user mouse-click at the screen center of an AX element.
    /// Used as a last resort when AXPress / AXValue writes don't propagate to
    /// Logic Pro's internal handlers (observed with Logic 12 rec-arm checkboxes).
    private static func postMouseClickAt(element: AXUIElement, runtime: AXHelpers.Runtime) {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let pr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard pr == .success, sr == .success,
              let p = posValue, let s = sizeValue,
              CFGetTypeID(p) == AXValueGetTypeID(),
              CFGetTypeID(s) == AXValueGetTypeID() else { return }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue((p as! AXValue), .cgPoint, &pt)
        AXValueGetValue((s as! AXValue), .cgSize, &sz)
        let center = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
           let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func defaultRenameTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        let truncatedName = String(name.prefix(255))
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index, runtime: runtime) else {
            return .error("Cannot find name field for track \(index)")
        }
        // Double-click to enter edit mode, then set value
        AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax)
        AXHelpers.setAttribute(field, kAXValueAttribute, truncatedName as CFTypeRef, runtime: runtime.ax)
        AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
        return .success("{\"track\":\(index),\"name\":\"\(AppleScriptChannel.escapeJSON(truncatedName))\"}")
    }

    private enum TrackSelectionVerification {
        case verified
        case selectionMetadataUnavailable
        case mismatch(selectedIndex: Int?)
        case trackDisappeared
    }

    private static func verifyTrackSelection(
        index: Int,
        runtime: AXLogicProElements.Runtime
    ) async -> TrackSelectionVerification {
        var sawSelectionMetadata = false

        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index >= 0 && index < headers.count else {
                return .trackDisappeared
            }

            let selectionStates = headers.enumerated().map { offset, header in
                (offset, AXValueExtractors.extractSelectedState(header, runtime: runtime.ax))
            }
            if selectionStates.contains(where: { $0.1 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index].1 == true {
                return .verified
            }

            if attempt < 5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard sawSelectionMetadata else {
            return .selectionMetadataUnavailable
        }

        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let selectedIndex = headers.enumerated().first {
            AXValueExtractors.extractSelectedState($0.element, runtime: runtime.ax) == true
        }?.offset
        return .mismatch(selectedIndex: selectedIndex)
    }

    // MARK: - Save As via AX Dialog

    private static func saveAsViaAXDialog(
        path: String,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Validate path before setting it into the AX dialog
        guard AppleScriptSafety.isValidProjectPath(path, requireExisting: false) else {
            return .error("save_as requires an absolute .logicx project path")
        }

        // Step 1: Trigger Save As via menu click
        let koreanResult = clickMenuItem("다른 이름으로 저장…", menuName: "파일", runtime: runtime)
        let triggered = koreanResult.isSuccess
            || clickMenuItem("Save As…", menuName: "File", runtime: runtime).isSuccess

        guard triggered else {
            return .error("Failed to open Save As dialog via menu")
        }

        // Step 2: Wait for save dialog sheet to appear (up to 3s)
        var sheet: AXUIElement?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { continue }
            let children = AXHelpers.getChildren(window, runtime: runtime.ax)
            for child in children {
                let role = AXHelpers.getRole(child, runtime: runtime.ax)
                if role == "AXSheet" || role == "AXWindow" {
                    let descendants = AXHelpers.findAllDescendants(of: child, role: "AXTextField", runtime: runtime.ax)
                    if !descendants.isEmpty {
                        sheet = child
                        break
                    }
                }
            }
            if sheet != nil { break }
        }

        guard let saveSheet = sheet else {
            return .error("Save As dialog did not appear within 3 seconds")
        }

        // Helper: dismiss dialog on failure (press Escape to avoid blocking UI)
        func dismissDialog() {
            let cancelButtons = AXHelpers.findAllDescendants(of: saveSheet, role: "AXButton", runtime: runtime.ax)
            for btn in cancelButtons {
                let title = AXHelpers.getTitle(btn, runtime: runtime.ax) ?? ""
                if title.contains("취소") || title.contains("Cancel") {
                    AXHelpers.performAction(btn, kAXPressAction, runtime: runtime.ax)
                    return
                }
            }
        }

        // Step 3: Find filename text field and set full path
        let textFields = AXHelpers.findAllDescendants(of: saveSheet, role: "AXTextField", runtime: runtime.ax)
        guard let filenameField = textFields.first else {
            dismissDialog()
            return .error("Cannot find filename field in Save As dialog")
        }

        AXHelpers.setAttribute(filenameField, kAXValueAttribute, path as CFTypeRef, runtime: runtime.ax)
        // Confirm the text entry so the save panel updates its internal path state
        AXHelpers.performAction(filenameField, kAXConfirmAction, runtime: runtime.ax)
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for panel to process

        // Step 4: Find and click Save button
        let buttons = AXHelpers.findAllDescendants(of: saveSheet, role: "AXButton", runtime: runtime.ax)
        var saveClicked = false
        for button in buttons {
            let title = AXHelpers.getTitle(button, runtime: runtime.ax) ?? ""
            if title.contains("저장") || title.contains("Save") || title == "확인" || title == "OK" {
                AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax)
                saveClicked = true
                break
            }
        }

        guard saveClicked else {
            dismissDialog()
            return .error("Cannot find Save button in Save As dialog")
        }

        // Step 5: Verify file exists (up to 5s)
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            if FileManager.default.fileExists(atPath: path) {
                return .success("{\"saved_as\":\"\(AppleScriptChannel.escapeJSON(path))\"}")
            }
        }

        // File might be saved with .logicx extension appended
        let pathWithExt = path.hasSuffix(".logicx") ? path : path + ".logicx"
        if FileManager.default.fileExists(atPath: pathWithExt) {
            return .success("{\"saved_as\":\"\(AppleScriptChannel.escapeJSON(pathWithExt))\"}")
        }

        return .error("Save As completed but file not found at: \(path)")
    }

    private static func clickMenuItem(
        _ itemTitle: String,
        menuName: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let item = AXLogicProElements.menuItem(path: [menuName, itemTitle], runtime: runtime) else {
            return .error("Cannot find menu item: \(menuName) > \(itemTitle)")
        }
        guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to click: \(menuName) > \(itemTitle)")
        }
        return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
    }

    // MARK: - Track Creation via Menu

    private static func createTrackViaMenu(
        korean: String,
        english: String,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard AXLogicProElements.mainWindow(runtime: runtime) != nil else {
            return .error("No document open for track creation")
        }

        let beforeCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count

        // Try Korean locale first
        let result = clickTrackMenu(korean, menuName: "트랙", englishMenuName: "Track", runtime: runtime)
        let menuClickedTitle: String
        if result.isSuccess {
            menuClickedTitle = korean
        } else {
            // Fallback: English locale with English item title
            let fallback = clickTrackMenu(english, menuName: "Track", englishMenuName: "Track", runtime: runtime)
            guard fallback.isSuccess else { return fallback }
            menuClickedTitle = english
        }

        // Logic 12.0.1: menu click may show "새로운 트랙 생성" dialog (sometimes invisible
        // to AX tree). Strategy: poll track count briefly. If track was already
        // created without a dialog, do NOT send Return (avoids sending Enter to
        // unrelated focused targets). If still unchanged after 400ms, assume
        // dialog is up and send Return; verify after.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let midCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
        if midCount == beforeCount {
            // Track not created yet — assume New Track dialog is awaiting confirmation
            sendReturnKey()
        }

        return await verifyTrackCreation(
            title: menuClickedTitle,
            beforeCount: beforeCount,
            runtime: runtime
        )
    }

    /// Send Return key via CGEvent — used to auto-confirm Logic 12's
    /// "New Track" dialog (which is sometimes opaque to AX tree).
    private static func sendReturnKey() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let returnVK: CGKeyCode = 0x24
        if let down = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        usleep(20_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: returnVK, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    private static func verifyTrackCreation(
        title: String,
        beforeCount: Int,
        runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        var lastObservedCount = beforeCount

        for attempt in 0..<4 {
            let currentCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
            lastObservedCount = currentCount
            if currentCount > beforeCount {
                return .success(
                    "{\"menu_clicked\":\"\(AppleScriptChannel.escapeJSON(title))\",\"verified\":true,\"track_count_before\":\(beforeCount),\"track_count_after\":\(currentCount)}"
                )
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        return .error(
            "Track creation did not increase visible track count after menu click '\(title)' (before: \(beforeCount), after: \(lastObservedCount))"
        )
    }

    private static func clickTrackMenu(
        _ menuItemTitle: String,
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        if let item = AXLogicProElements.menuItem(path: [menuName, menuItemTitle], runtime: runtime) {
            guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
                return .error("Failed to click menu item: \(menuItemTitle)")
            }
            return .success("{\"menu_clicked\":\"\(menuItemTitle)\"}")
        }
        // Fallback: English menu names for non-Korean locales
        if let item = AXLogicProElements.menuItem(path: [englishMenuName, menuItemTitle], runtime: runtime) {
            guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
                return .error("Failed to click menu item: \(menuItemTitle)")
            }
            return .success("{\"menu_clicked\":\"\(menuItemTitle)\"}")
        }
        return .error("Cannot find menu item: \(menuName) > \(menuItemTitle)")
    }

    // MARK: - Mixer

    private static func defaultGetMixerState(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer, runtime: runtime.ax)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax)
            let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0, runtime: runtime.ax) } ?? 0.0
            let pan = sliders.count > 1
                ? AXValueExtractors.extractSliderValue(sliders[1], runtime: runtime.ax) ?? 0.0
                : 0.0

            channelStrips.append(ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            ))
        }
        return encodeResult(channelStrips)
    }

    private static func defaultGetChannelStrip(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer, runtime: runtime.ax)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4, runtime: runtime.ax)
        let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0, runtime: runtime.ax) } ?? 0.0
        let pan = sliders.count > 1
            ? AXValueExtractors.extractSliderValue(sliders[1], runtime: runtime.ax) ?? 0.0
            : 0.0

        let state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        return encodeResult(state)
    }

    // MARK: - Library operations

    private static func listLibrary(
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let inventory = LibraryAccessor.enumerate(runtime: runtime) else {
            return .error("Library panel not found. Open Library (⌘L) in Logic Pro.")
        }
        do {
            let data = try JSONEncoder().encode(inventory)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to serialize library inventory")
            }
            return .success(json)
        } catch {
            return .error("JSON encode failed: \(error)")
        }
    }

    /// Production `library.scan_all` path — wires ScanOrchestration + live TreeProbe,
    /// populates `lastScan` for resolve_path, restores Tier-A selection, writes JSON.
    private func runLiveScan(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let t0 = Date()
        Log.info("scan_all: entering runLiveScan", subsystem: "ax")

        // Precondition: only start the scan if the Library panel is actually open.
        // This is a < 100 ms AX check and avoids descending into a multi-second
        // probe chain that has no Library to walk. Run FIRST so we bail before
        // any expensive setup (probe construction, snapshot extraction).
        guard LibraryAccessor.isLibraryPanelOpen(runtime: runtime) else {
            Log.info("scan_all: preflight failed in \(Int(Date().timeIntervalSince(t0) * 1000))ms — panel closed", subsystem: "ax")
            return .error("Library panel not found. Open Library (⌘L) in Logic Pro.")
        }
        Log.info("scan_all: preflight OK in \(Int(Date().timeIntervalSince(t0) * 1000))ms", subsystem: "ax")

        let snapshot: (category: String, preset: String)? = {
            if let c = lastRoutedCategory, let p = lastRoutedPreset { return (c, p) }
            return nil
        }()
        let channel = self
        let probe = Self.buildLiveTreeProbe(runtime: runtime)

        // 150ms settle is empirically sufficient on Apple Silicon; 500ms was
        // overly conservative and pushed full Library scans past the client
        // read-timeout (observed 164s at 500ms vs ~50s at 150ms).
        let result = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: snapshot,
            restoreSelection: { c, p in
                let okCat = LibraryAccessor.selectCategory(named: c, runtime: runtime)
                if !okCat { return false }
                try? await Task.sleep(nanoseconds: 150_000_000)
                return LibraryAccessor.selectPreset(named: p, runtime: runtime)
            },
            writeJSON: { root in Self.writeInventoryJSON(root) },
            onComplete: { root in await channel.setLastScan(root) },
            settleDelayMs: 150
        )
        guard let r = result else {
            return .error("Library panel not found. Open Library (⌘L) in Logic Pro.")
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(r.root)
            guard let s = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode library inventory JSON")
            }
            return .success(s)
        } catch {
            return .error("JSON encode failed: \(error)")
        }
    }

    private func setLastScan(_ root: LibraryRoot) {
        self.lastScan = root
    }

    // MARK: - F2 plugin.scan_presets minimal handler (T0 verdict MIXED)

    /// Production `plugin.scan_presets` path — relies on currently-focused plugin
    /// window. CGEvent-clicks the Setting popup to open the menu, then walks via
    /// AXPress on AXMenuItems (T0 v0.6 empirical — popup AXPress unreliable, menu
    /// item AXPress 100% reliable). Returns serialized PluginPresetNode tree.
    /// Full T6 (cache, persistence, identity gate) is follow-up.
    static func runLivePluginPresetScan(
        runtime: AXLogicProElements.Runtime,
        settleMs: Int = 250
    ) async -> ChannelResult {
        // 1. Resolve Logic app root
        guard let appRoot = AXLogicProElements.appRoot(runtime: runtime) else {
            return .error("Logic Pro is not running")
        }
        // 2. Find focused plugin window (heuristic: has AXPopUpButton with "Preset"/"기본" value)
        guard let pluginWin = PluginInspector.findFocusedPluginWindowAX(in: appRoot) else {
            return .error("No plugin window with Setting dropdown found. Open an instrument plugin window first.")
        }
        // 3. Locate Setting popup + its center point
        guard let popup = PluginInspector.findSettingPopupAX(in: pluginWin) else {
            return .error("Setting popup not found in plugin window")
        }
        guard let center = PluginInspector.centerPoint(of: popup) else {
            return .error("Setting popup has no readable position/size")
        }
        // 4. CGEvent click to open menu (T0 verdict — popup AXPress unreliable)
        guard LibraryAccessor.productionMouseClick(at: center) else {
            return .error("CGEvent click on Setting popup failed (Post-Event permission?)")
        }
        // 5. Wait for menu to appear, then locate it
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let menu = PluginInspector.findOpenSettingMenuAX(in: appRoot) else {
            return .error("Setting menu did not appear after click (or already dismissed)")
        }
        // 6. Build live probe + walk
        let probe = PluginInspector.liveMenuProbe(rootMenu: menu, settleMs: settleMs)
        let scanStart = Date()
        do {
            let (root, cycleCount) = try await PluginInspector.enumerateMenuTree(
                probe: probe, maxDepth: maxPluginMenuDepth, settleMs: settleMs
            )
            let durationMs = Int(Date().timeIntervalSince(scanStart) * 1000)
            // 7. Dismiss menu
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            // 8. Compute counts
            let counts = AccessibilityChannel.countNodes(root)
            // 9. Build minimal cache (no persistence in this minimal handler)
            let cache = PluginPresetCache(
                schemaVersion: 1,
                pluginName: "(focused-plugin)",
                pluginIdentifier: "(unknown — T6 will resolve via AU registry)",
                pluginVersion: nil,
                contentHash: "(deferred)",
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                scanDurationMs: durationMs,
                measuredSubmenuOpenDelayMs: settleMs,
                truncatedBranches: counts.truncated,
                probeTimeouts: counts.probeTimeout,
                cycleCount: cycleCount,
                nodeCount: counts.total,
                leafCount: counts.leaf,
                folderCount: counts.folder,
                root: root
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            guard let s = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode plugin preset cache JSON")
            }
            return .success(s)
        } catch PluginError.menuMutated {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            return .error("Plugin menu mutated mid-scan; aborted")
        } catch PluginError.focusLost {
            return .error("Logic Pro lost focus mid-scan")
        } catch {
            return .error("Plugin scan failed: \(error)")
        }
    }

    /// Walk a `PluginPresetNode` tree and tally counts by kind.
    private static func countNodes(_ node: PluginPresetNode) -> (total: Int, leaf: Int, folder: Int, truncated: Int, probeTimeout: Int) {
        var total = 1
        var leaf = node.kind == .leaf ? 1 : 0
        var folder = node.kind == .folder ? 1 : 0
        var truncated = node.kind == .truncated ? 1 : 0
        var probeTimeout = node.kind == .probeTimeout ? 1 : 0
        for c in node.children {
            let s = countNodes(c)
            total += s.total
            leaf += s.leaf
            folder += s.folder
            truncated += s.truncated
            probeTimeout += s.probeTimeout
        }
        return (total, leaf, folder, truncated, probeTimeout)
    }

    /// Detects external (non-scanner) mutation of the Library panel during a scan.
    /// Compares column-1 category list against a snapshot taken at scan start.
    /// Scanner's own `selectCategory` clicks change column 2 content only — column 1
    /// category list is invariant under scanner actions.
    private final class MutationDetector: @unchecked Sendable {
        private let runtime: AXLogicProElements.Runtime
        private let initialCategories: [String]
        init(runtime: AXLogicProElements.Runtime) {
            self.runtime = runtime
            self.initialCategories = LibraryAccessor.enumerate(runtime: runtime)?.categories ?? []
        }
        func check() -> Bool {
            let current = LibraryAccessor.enumerate(runtime: runtime)?.categories ?? []
            return current != initialCategories
        }
    }

    /// Build a live TreeProbe for the current flat 2-level Logic Library:
    /// depth 0 → categories; depth 1 → click category + read presets; depth 2+ → leaf.
    private static func buildLiveTreeProbe(runtime: AXLogicProElements.Runtime) -> TreeProbe {
        let logicPID = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.logic10"
        })?.processIdentifier
        let detector = MutationDetector(runtime: runtime)
        return TreeProbe(
            childrenAt: { path in
                if path.isEmpty {
                    guard let inv = LibraryAccessor.enumerate(runtime: runtime) else { return nil }
                    return inv.categories
                }
                if path.count == 1 {
                    guard LibraryAccessor.selectCategory(named: path[0], runtime: runtime) else {
                        return nil
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return LibraryAccessor.currentPresets(runtime: runtime)
                }
                return []
            },
            focusOK: {
                guard let pid = logicPID else { return true }
                let sysWide = AXUIElementCreateSystemWide()
                var focusedApp: AnyObject?
                let r = AXUIElementCopyAttributeValue(
                    sysWide, kAXFocusedApplicationAttribute as CFString, &focusedApp
                )
                guard r == .success, let app = focusedApp,
                      CFGetTypeID(app) == AXUIElementGetTypeID() else { return true }
                let focusedElement = app as! AXUIElement
                var appPID: pid_t = 0
                AXUIElementGetPid(focusedElement, &appPID)
                return appPID == pid
            },
            mutationSinceLastCheck: { detector.check() },
            sleep: { ms in
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            },
            visitedHash: { path in
                path.joined(separator: "\u{0001}").hashValue
            }
        )
    }

    private static func writeInventoryJSON(_ root: LibraryRoot) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(root) else { return false }
        let fm = FileManager.default
        let resDir = fm.currentDirectoryPath + "/Resources"
        if !fm.fileExists(atPath: resDir) {
            try? fm.createDirectory(atPath: resDir, withIntermediateDirectories: true)
        }
        let path = resDir + "/library-inventory.json"
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            Log.warn("Library inventory write failed: \(error)", subsystem: "library")
            return false
        }
    }

    /// T6: compute the vertical viewport of the track list (Y min/max on screen).
    /// Returns nil if the scroll area isn't resolvable — callers fall through
    /// to click anyway (fail-open, documented in T6 EC-1).
    private static func trackViewport(runtime: AXLogicProElements.Runtime) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let headers = AXLogicProElements.getTrackHeaders(runtime: runtime) else { return nil }
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        _ = AXUIElementCopyAttributeValue(headers, kAXPositionAttribute as CFString, &posValue)
        _ = AXUIElementCopyAttributeValue(headers, kAXSizeAttribute as CFString, &sizeValue)
        guard let pr = posValue, let sr = sizeValue,
              CFGetTypeID(pr) == AXValueGetTypeID(),
              CFGetTypeID(sr) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue((pr as! AXValue), .cgPoint, &p)
        AXValueGetValue((sr as! AXValue), .cgSize, &s)
        return (p.y, p.y + s.height)
    }

    private struct ResolvePathResponse: Encodable {
        let exists: Bool
        let kind: String?
        let matchedPath: String?
        let children: [String]?
        let reason: String?
    }

    private struct SetInstrumentResponse: Encodable {
        let category: String
        let preset: String
        let path: String
    }

    private static func resolveLibraryPath(
        params: [String: String],
        lastScan: LibraryRoot?
    ) -> ChannelResult {
        guard let path = params["path"], !path.isEmpty else {
            return .error("Missing 'path' parameter for library.resolve_path")
        }
        guard let root = lastScan else {
            return encodeOrError(ResolvePathResponse(
                exists: false, kind: nil, matchedPath: nil, children: nil,
                reason: "No cached library scan; call scan_library first"
            ))
        }
        guard let res = LibraryAccessor.resolvePath(path, in: root) else {
            return encodeOrError(ResolvePathResponse(
                exists: false, kind: nil, matchedPath: nil, children: nil, reason: nil
            ))
        }
        return encodeOrError(ResolvePathResponse(
            exists: res.exists,
            kind: res.kind?.rawValue,
            matchedPath: res.matchedPath,
            children: res.children,
            reason: nil
        ))
    }

    private static func encodeOrError<T: Encodable>(_ value: T) -> ChannelResult {
        do {
            let data = try JSONEncoder().encode(value)
            guard let s = String(data: data, encoding: .utf8) else {
                return .error("Failed to serialize response")
            }
            return .success(s)
        } catch {
            return .error("JSON encode failed: \(error)")
        }
    }

    private static func setTrackInstrument(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Resolve path-OR-legacy. Path wins when both provided.
        let pathParam = params["path"].flatMap { $0.isEmpty ? nil : $0 }
        let catParam = params["category"].flatMap { $0.isEmpty ? nil : $0 }
        let presetParam = params["preset"].flatMap { $0.isEmpty ? nil : $0 }

        let resolvedCategory: String
        let resolvedPreset: String
        let resolvedPath: String
        if let p = pathParam {
            guard let parts = LibraryAccessor.parsePath(p), parts.count >= 2 else {
                return .error("Invalid 'path': must have at least category and preset segments")
            }
            // PRD AC-2.8: path must resolve to a leaf, not a folder. For production
            // flat Library (depth 2) a 2-segment path is inherently a leaf.
            // Deeper paths require cache check (T7); here we accept 2+ segments.
            resolvedCategory = parts[0]
            resolvedPreset = parts[parts.count - 1]
            resolvedPath = p
        } else if let c = catParam, let pr = presetParam {
            resolvedCategory = c
            resolvedPreset = pr
            resolvedPath = "\(c)/\(pr)"
        } else {
            return .error("Missing path or (category+preset) for track.set_instrument")
        }
        let category = resolvedCategory
        let preset = resolvedPreset

        // Select the target track first — Library loads the instrument onto
        // whichever track is currently focused. AXPressAction on track headers
        // is unreliable in Logic Pro 12; inject a real CGEvent mouse click at
        // the header's screen position (same pattern proven for Library).
        if let indexStr = params["index"], let index = Int(indexStr) {
            guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
                return .error("Track at index \(index) not found")
            }
            var posValue: AnyObject?
            var sizeValue: AnyObject?
            _ = AXUIElementCopyAttributeValue(header, kAXPositionAttribute as CFString, &posValue)
            _ = AXUIElementCopyAttributeValue(header, kAXSizeAttribute as CFString, &sizeValue)
            if let posRaw = posValue, let sizeRaw = sizeValue,
               CFGetTypeID(posRaw) == AXValueGetTypeID(),
               CFGetTypeID(sizeRaw) == AXValueGetTypeID() {
                var p = CGPoint.zero
                var s = CGSize.zero
                AXValueGetValue((posRaw as! AXValue), .cgPoint, &p)
                AXValueGetValue((sizeRaw as! AXValue), .cgSize, &s)
                // T6: viewport visibility check (AC-3.2 / E13)
                if let vp = AccessibilityChannel.trackViewport(runtime: runtime) {
                    let headerY = p.y + s.height / 2
                    if headerY < vp.minY || headerY > vp.maxY {
                        return .error("Track not visible; scroll tracklist to bring track \(index) into view")
                    }
                }
                // E10b: preflight Post-Event capability before any CGEvent mutation
                if !CGPreflightPostEventAccess() {
                    return .error("Event-post permission required (Accessibility → Input Monitoring). Grant in System Settings.")
                }
                // Click near the left edge of the header (name area), not center,
                // to avoid hitting record/mute/solo buttons on wider headers.
                let clickPoint = CGPoint(x: p.x + min(60, s.width / 4), y: p.y + s.height / 2)
                let clicked = LibraryAccessor.productionMouseClick(at: clickPoint)
                guard clicked else {
                    return .error("Failed to click track header at index \(index)")
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            } else {
                _ = AXHelpers.performAction(header, kAXPressAction, runtime: runtime.ax)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        // Select the category (injects CGEvent mouse click)
        guard LibraryAccessor.selectCategory(named: category, runtime: runtime) else {
            return .error("Category not found in Library: \(category)")
        }
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Select the preset (injects CGEvent mouse click)
        guard LibraryAccessor.selectPreset(named: preset, runtime: runtime) else {
            return .error("Preset not found in category '\(category)': \(preset)")
        }
        try? await Task.sleep(nanoseconds: 800_000_000) // let Logic load the instrument

        return encodeOrError(SetInstrumentResponse(
            category: category, preset: preset, path: resolvedPath
        ))
    }

    // MARK: - Control-bar playhead position helper

    /// Set the playhead to a specific bar. Two paths:
    /// 1) `탐색 → 이동 → 위치…` dialog (precise, auto-extends project, requires
    ///    at least one region in arrange — menu item is disabled on empty project)
    /// 2) Control-bar 마디 slider (clamps to project length; silently stops at
    ///    end when requested bar exceeds length)
    /// Accepts `{"bar": Int}` or `{"position": "B.B.S.S"}`.
    private static func gotoPositionViaBarSlider(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        var targetBar: Int? = nil
        if let barStr = params["bar"], let b = Int(barStr) {
            targetBar = b
        } else if let pos = params["position"] {
            if pos.contains(":") {
                return .error("AX gotoPosition cannot handle timecode (use MCU mmc_locate)")
            }
            let parts = pos.split(separator: ".")
            if let first = parts.first, let b = Int(first) {
                targetBar = b
            }
        }
        guard let bar = targetBar, (1...9999).contains(bar) else {
            return .error("goto_position requires 'bar' (Int 1..9999) or 'position' (B.B.S.S)")
        }

        // Try dialog first — the only way to reach bars beyond project length.
        let dialogResult = await gotoPositionViaDialog(bar: bar)
        if case .success = dialogResult { return dialogResult }

        // Fallback to slider (works when dialog is disabled — e.g., empty project).
        guard let slider = AXLogicProElements.findControlBarBarSlider(runtime: runtime) else {
            return .error("Neither goto-position dialog nor 마디 slider available")
        }
        let setOK = AXHelpers.setAttribute(
            slider, kAXValueAttribute, NSNumber(value: bar), runtime: runtime.ax
        )
        if !setOK {
            return .error("Failed to set 마디 slider")
        }
        if let beatSlider = AXLogicProElements.findControlBarBeatSlider(runtime: runtime) {
            _ = AXHelpers.setAttribute(
                beatSlider, kAXValueAttribute, NSNumber(value: 1), runtime: runtime.ax
            )
        }
        _ = AXHelpers.performAction(slider, kAXConfirmAction, runtime: runtime.ax)
        return .success("{\"position\":\"\(bar).1.1.1\",\"method\":\"slider\"}")
    }

    /// Move the playhead to `bar` via Logic Pro 12's `탐색 → 이동 → 위치…`
    /// (Navigate → Go To → Position) dialog. Reliable because the dialog auto-
    /// extends project length; however the menu item is disabled when no
    /// regions exist yet, in which case this returns an error and callers
    /// should try the slider fallback.
    private static func gotoPositionViaDialog(bar: Int) async -> ChannelResult {
        // Poll for the dialog's presence instead of relying on a fixed delay.
        // Without this guard, a slow machine (>500ms to render the dialog) would
        // send Cmd+A to the arrange area, selecting all regions unexpectedly.
        let script = """
        tell application "Logic Pro" to activate
        delay 0.2
        tell application "System Events"
            tell process "Logic Pro"
                try
                    set mi to menu item "위치…" of menu 1 of menu item "이동" of menu 1 of menu bar item "탐색" of menu bar 1
                on error errMsg
                    try
                        set mi to menu item "Position…" of menu 1 of menu item "Go To" of menu 1 of menu bar item "Navigate" of menu bar 1
                    on error errMsg2
                        return "MENU_NOT_FOUND: " & errMsg2
                    end try
                end try
                if not (enabled of mi) then
                    return "MENU_DISABLED"
                end if
                click mi
                -- Wait up to 3s for the dialog window to appear before typing,
                -- otherwise keystrokes would go to the arrange area and click
                -- Cmd+A there — silently "Select All Regions".
                set dialogReady to false
                repeat 30 times
                    delay 0.1
                    try
                        set _ to first window whose name is "위치로 이동"
                        set dialogReady to true
                        exit repeat
                    end try
                    try
                        set _ to first window whose name is "Go to Position"
                        set dialogReady to true
                        exit repeat
                    end try
                end repeat
                if not dialogReady then
                    return "DIALOG_NOT_READY"
                end if
            end tell
            delay 0.1
            keystroke "a" using command down
            delay 0.1
            keystroke "\(bar)"
            delay 0.1
            keystroke return
            delay 0.2
        end tell
        return "OK"
        """
        let result = await AppleScriptChannel.executeAppleScript(script)
        switch result {
        case .success(let output):
            if output.contains("MENU_DISABLED") {
                return .error("goto-position dialog disabled (project has no regions yet)")
            }
            if output.hasPrefix("MENU_NOT_FOUND") {
                return .error("goto-position menu not found: \(output)")
            }
            if output.contains("DIALOG_NOT_READY") {
                return .error("goto-position dialog did not appear within timeout")
            }
            return .success("{\"position\":\"\(bar).1.1.1\",\"method\":\"dialog\"}")
        case .error(let msg):
            return .error("goto-position dialog failed: \(msg)")
        }
    }

    // MARK: - Control-bar checkbox helpers (Logic Pro 12 transport)

    /// Click a control-bar checkbox by Korean/English name, toggling its value.
    /// Returns nil if the checkbox couldn't be located — callers may fall back.
    private static func clickControlBarCheckbox(
        korean: String,
        english: String,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult? {
        guard let cb = AXLogicProElements.findControlBarCheckbox(
            named: korean, englishName: english, runtime: runtime
        ) else {
            return nil
        }
        guard AXHelpers.performAction(cb, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to click control-bar checkbox: \(korean)")
        }
        return .success("{\"clicked\":\"\(korean)\"}")
    }

    /// Ensure a control-bar checkbox matches `desired` state. Reads current
    /// value and clicks only if it differs. Returns nil if the checkbox
    /// cannot be located (caller may fall back).
    private static func setControlBarCheckboxValue(
        korean: String,
        english: String,
        desired: Bool,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult? {
        guard let cb = AXLogicProElements.findControlBarCheckbox(
            named: korean, englishName: english, runtime: runtime
        ) else {
            return nil
        }
        let current = AXLogicProElements.readControlBarCheckboxValue(
            named: korean, englishName: english, runtime: runtime
        )
        if current == desired {
            return .success("{\"\(korean)\":\(desired),\"unchanged\":true}")
        }
        guard AXHelpers.performAction(cb, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to click control-bar checkbox: \(korean)")
        }
        return .success("{\"\(korean)\":\(desired)}")
    }

    private static func defaultSetMixerValue(
        params: [String: String],
        target: MixerTarget,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        // Accept both `value` (legacy) and `volume`/`pan` (dispatcher-side aliases)
        // — same contract-drift class of bug as transport.set_tempo's bpm/tempo.
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing 'index' parameter")
        }
        let label = target == .volume ? "volume" : "pan"
        guard let valueStr = params["value"] ?? params[label],
              let value = Double(valueStr) else {
            return .error("Missing 'value' or '\(label)' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index, runtime: runtime)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index, runtime: runtime)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value), runtime: runtime.ax)
        // Read-back verification — same honesty principle as set_tempo.
        let readBack: Double? = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        if let actual = readBack, abs(actual - value) < 0.01 {
            return .success("{\"\(label)\":\(value),\"track\":\(index),\"verified\":true}")
        }
        return .success("{\"\(label)\":\(value),\"track\":\(index),\"verified\":false,\"actual\":\(readBack ?? -1)}")
    }

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
    private static func defaultGetRegions(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .error("Cannot locate Logic Pro main window")
        }
        // Find the "Track Content" container — it holds all region AXLayoutItems as
        // descendants. Logic's arrange area may have multiple AXGroups so match by description.
        // Increase maxDepth to 14 — production Logic trees can run deeper than 10 under
        // the arrange area once plugin/library panels are open.
        let candidates = AXHelpers.findAllDescendants(
            of: window, role: kAXGroupRole, maxDepth: 14, runtime: runtime.ax
        )
        var contentGroup: AXUIElement? = nil
        var groupDescSamples: [String] = []
        for g in candidates {
            let desc = AXHelpers.getDescription(g, runtime: runtime.ax) ?? ""
            if !desc.isEmpty { groupDescSamples.append(desc) }
            // Logic's localized strings have varied over versions: "트랙 콘텐츠" (12.0),
            // just "콘텐츠" (some builds), "Track Content" (en). Accept any that contains
            // the stem — regions are the only content elements we care about underneath.
            let lower = desc.lowercased()
            if desc.contains("트랙 콘텐츠") || desc == "콘텐츠"
                || lower == "track content" || lower == "content" {
                contentGroup = g
                break
            }
        }
        guard let content = contentGroup else {
            // Return diagnostic so the caller can see what group descriptions WERE found.
            // Prevents silent "empty array" failures when Logic's localization differs.
            // Emit each sample with Unicode code-point count + hex bytes so whitespace/
            // hidden chars surface (was the problem chasing "콘텐츠" matching).
            let detailed = groupDescSamples.prefix(20).map { s -> String in
                let bytes = s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
                return "'\(s)'(\(s.unicodeScalars.count)=\(bytes))"
            }.joined(separator: " | ")
            return .error("Track Content group not found (scanned \(candidates.count) AXGroups; samples: \(detailed))")
        }

        // Track headers for Y→index mapping.
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        let headerYs: [(index: Int, y: CGFloat)] = headers.enumerated().compactMap { pair in
            guard let p = AXHelpers.getPosition(pair.element, runtime: runtime.ax),
                  let s = AXHelpers.getSize(pair.element, runtime: runtime.ax) else { return nil }
            return (pair.offset, p.y + s.height / 2)
        }

        // Collect all AXLayoutItems under content — regions look like:
        //   AXLayoutItem [d="<region name>" | h="리전은 N 마디 에서 시작하여 M 마디 에서 끝납니다., MIDI 리전. …"]
        // maxDepth=10 covers nested AXLayoutArea→AXLayoutItem structure seen in production.
        let items = AXHelpers.findAllDescendants(
            of: content, role: "AXLayoutItem", maxDepth: 10, runtime: runtime.ax
        )
        var regions: [RegionInfo] = []
        var nonRegionCount = 0
        for item in items {
            let help = AXHelpers.getHelp(item, runtime: runtime.ax) ?? ""
            // Heuristic: region help always contains "리전" (Korean) or "Region" (English).
            // Track-content-lane headers and other AXLayoutItems don't.
            let isRegion = help.contains("리전") || help.lowercased().contains("region")
            guard isRegion else { nonRegionCount += 1; continue }

            let name = AXHelpers.getDescription(item, runtime: runtime.ax) ?? ""
            // Parse "리전은 N 마디 에서 시작하여 M 마디 에서 끝납니다" or
            // "Region starts at bar N and ends at bar M".
            let (startBar, endBar) = parseRegionBars(from: help)

            // Detect kind from help text.
            let lower = help.lowercased()
            let kind: String
            if help.contains("MIDI") || lower.contains("midi") {
                kind = "midi"
            } else if help.contains("오디오") || lower.contains("audio") {
                kind = "audio"
            } else {
                kind = "unknown"
            }

            // Determine track index by Y match.
            var trackIndex = -1
            if let pos = AXHelpers.getPosition(item, runtime: runtime.ax),
               let size = AXHelpers.getSize(item, runtime: runtime.ax),
               !headerYs.isEmpty {
                let regionMidY = pos.y + size.height / 2
                let best = headerYs.min(by: { abs($0.y - regionMidY) < abs($1.y - regionMidY) })
                trackIndex = best?.index ?? -1
            }

            regions.append(RegionInfo(
                name: name,
                trackIndex: trackIndex,
                startBar: startBar,
                endBar: endBar,
                kind: kind,
                rawHelp: help
            ))
        }
        // When the array is empty, surface traversal counters so we can tell
        // "no regions exist" from "parser missed them" without re-running a probe.
        if regions.isEmpty {
            return .success("{\"regions\":[],\"_debug\":{\"layoutItems\":\(items.count),\"nonRegion\":\(nonRegionCount)}}")
        }
        return encodeResult(regions)
    }

    /// Extract (startBar, endBar) from Logic's localized region help text.
    /// Returns (-1, -1) if neither pattern matches — callers should inspect rawHelp.
    private static func parseRegionBars(from help: String) -> (Int, Int) {
        // Korean: "리전은 1 마디 에서 시작하여 2 마디 에서 끝납니다."
        // English (guessed, pending real-world sample): "Region starts at bar 1 and ends at bar 2"
        let patterns = [
            #"리전은\s*(\d+)\s*마디.*?시작.*?(\d+)\s*마디.*?끝"#,
            #"(?i)region\s+starts\s+at\s+bar\s+(\d+).*?ends\s+at\s+bar\s+(\d+)"#,
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

    // MARK: - Project

    private static func defaultGetProjectInfo(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window, runtime: runtime.ax) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - MIDI file import

    /// Import a .mid file via Logic Pro's File → Import → MIDI File menu.
    /// Always creates a new MIDI track (Logic Pro's built-in behavior, OQ-3 confirmed).
    /// Uses osascript to coordinate the menu click, path-entry keystroke, and dialog dismissals.
    static func defaultImportMIDIFile(
        path: String,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .error("midi.import_file file not found: \(path)")
        }
        // Escape path for osascript string literal (double-quote safe).
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Strip leading slash since "/" keystroke already triggers the path-entry sheet.
        let typedPath = escapedPath.hasPrefix("/") ? String(escapedPath.dropFirst()) : escapedPath
        let script = """
        on importMIDI()
            tell application "Logic Pro" to activate
            delay 0.3
            tell application "System Events"
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
                delay 1.5
                keystroke "/"
                delay 0.5
                keystroke "\(typedPath)"
                delay 0.3
                keystroke return
                delay 1.5
                tell process "Logic Pro"
                    try
                        set importDlg to first window whose name is "가져오기"
                        click button "가져오기" of UI element 1 of importDlg
                    on error
                        try
                            set importDlg to first window whose name is "Import"
                            click button "Import" of UI element 1 of importDlg
                        on error errMsg
                            return "IMPORT_BTN_ERROR: " & errMsg
                        end try
                    end try
                end tell
                delay 2.0
                -- Dismiss tempo dialog if it appears
                tell process "Logic Pro"
                    try
                        set tempoDlg to first window whose subrole is "AXDialog"
                        try
                            click button "아니요" of tempoDlg
                        on error
                            try
                                click button "No" of tempoDlg
                            end try
                        end try
                    end try
                end tell
            end tell
            return "OK"
        end importMIDI
        return importMIDI()
        """
        let result = await AppleScriptChannel.executeAppleScript(script)
        switch result {
        case .success(let output):
            if output.hasPrefix("MENU_ERROR") || output.hasPrefix("IMPORT_BTN_ERROR") {
                return .error("midi.import_file: \(output)")
            }
            return .success("{\"imported\":\"\(escapedPath)\",\"method\":\"ax_menu_import\"}")
        case .error(let msg):
            return .error("midi.import_file osascript failed: \(msg)")
        }
    }

    // MARK: - Region repositioning

    /// Move the currently selected region to the playhead position via the
    /// `편집 → 이동 → 재생헤드로` menu (Edit → Move → To Playhead).
    /// Assumes a region is already selected; otherwise the menu item is a no-op.
    static func defaultMoveSelectedRegionToPlayhead() async -> ChannelResult {
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
        let result = await AppleScriptChannel.executeAppleScript(script)
        switch result {
        case .success(let output):
            if output.hasPrefix("MENU_ERROR") {
                return .error("region.move_to_playhead: \(output)")
            }
            return .success("{\"moved\":true}")
        case .error(let msg):
            return .error("region.move_to_playhead failed: \(msg)")
        }
    }

    /// Select the most recently created (right-most / largest trackIndex)
    /// region in the arrange area by locating it via AX element position.
    /// Newly imported regions are usually already selected by Logic, but this
    /// provides a fallback when selection state is lost between operations.
    static func defaultSelectLastRegion() async -> ChannelResult {
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
        let result = await AppleScriptChannel.executeAppleScript(script)
        switch result {
        case .success(let output):
            if output.contains("NO_REGION") {
                return .error("region.select_last: no region found in arrange area")
            }
            return .success("{\"selected\":true,\"method\":\"\(output)\"}")
        case .error(let msg):
            return .error("region.select_last failed: \(msg)")
        }
    }

    // MARK: - Markers

    private static func defaultGetMarkers(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let area = AXLogicProElements.getArrangementArea(runtime: runtime) else {
            return .error("Cannot locate arrangement area for marker enumeration")
        }
        let markers = AXLogicProElements.enumerateMarkers(in: area, runtime: runtime)
        return encodeResult(markers)
    }

    // MARK: - JSON encoding

    private static func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
