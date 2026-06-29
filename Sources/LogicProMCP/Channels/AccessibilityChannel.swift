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
    // v3.1.0 (T6) — split the single `lastScan` into three source-keyed caches
    // so a `mode:disk` call no longer poisons the panel-only view that
    // `library.resolve_path` needs for Load-via-Library (panel-only paths
    // never load from disk-only entries). `lastScan` remains populated with
    // whichever cache was last written so legacy call sites that ask for
    // "any recent scan" still work; new code reads the source-specific cache.
    private var lastScan: LibraryRoot? = nil
    private var lastPanelScan: LibraryRoot? = nil
    private var lastDiskScan: LibraryRoot? = nil
    private var lastBothScan: LibraryRoot? = nil
    private var lastScanSource: String? = nil
    private var lastRoutedCategory: String? = nil
    private var lastRoutedPreset: String? = nil

    enum MixerTarget {
        case volume
        case pan
    }

    struct PluginInsertSpec: Sendable {
        let canonicalName: String
        let aliases: [String]
        let menuPaths: [[String]]

        func matches(_ observed: String) -> Bool {
            let normalizedObserved = Self.normalize(observed)
            return aliases.map(Self.normalize).contains(normalizedObserved)
        }

        private static func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// v3.0.6 — testable scan-mode dispatch. Centralizes the
    /// "params["mode"] → which scanner" decision so router tests can
    /// assert it without actually running an AX probe or disk walk.
    enum ScanMode: String {
        case ax
        case disk
        case both
    }

    /// Parse the `mode` param for `library.scan_all`. Nil/empty/unknown values
    /// default to `.disk`, the only unattended scanner that does not click
    /// through Logic's live Library panel. Explicit `ax` preserves the legacy
    /// Panel-authoritative scan for callers that can tolerate UI mutation.
    static func parseScanMode(_ raw: String?) -> ScanMode {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return .disk }
        return ScanMode(rawValue: raw) ?? .disk
    }

    static func managedMIDIImportDirectoryPrefixes() -> [String] {
        [SMFWriter.temporaryDirectoryPrefix()]
    }

    static func validatedMIDIImportPath(_ path: String) -> String? {
        guard path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }

        let requestedURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard requestedURL.pathExtension.lowercased() == "mid" else { return nil }

        guard SMFWriter.isManagedTemporaryMIDIFile(requestedURL.path) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return requestedURL.path
    }

    struct Runtime: @unchecked Sendable {
        let isTrusted: @Sendable () -> Bool
        let isLogicProRunning: @Sendable () -> Bool
        let hasVisibleWindow: @Sendable () -> Bool
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
        // v3.1.5 AppleScript-primary helpers (markersAppleScript /
        // projectInfoAppleScript / tracksAppleScript) removed in v3.1.8 —
        // see Issue #7. The dictionary terms they relied on (tracks /
        // markers / tempo) don't exist in Logic 12.x; the project-file
        // fallback now lives in `ResourceHandlers.read*`.
        let logicRuntime: AXLogicProElements.Runtime

        init(
            isTrusted: @escaping @Sendable () -> Bool,
            isLogicProRunning: @escaping @Sendable () -> Bool,
            hasVisibleWindow: @escaping @Sendable () -> Bool = { true },
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
            self.hasVisibleWindow = hasVisibleWindow
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
            hasVisibleWindow: @escaping @Sendable () -> Bool = { ProcessUtils.hasVisibleWindow() },
            logicRuntime: AXLogicProElements.Runtime = .production,
            controlBarMouseRuntime: AXMouseHelper.Runtime = .production,
            trackRenameMouseRuntime: AXMouseHelper.Runtime = .production,
            processRuntime: ProcessUtils.Runtime = .production,
            runTempoFallback: @escaping @Sendable (String) -> Bool = { tempo in
                AccessibilityChannel.runTempoFallbackScript(tempo: tempo)
            }
        ) -> Runtime {
            Runtime(
                isTrusted: isTrusted,
                isLogicProRunning: isLogicProRunning,
                hasVisibleWindow: hasVisibleWindow,
                appRoot: { AXLogicProElements.appRoot(runtime: logicRuntime) },
                transportState: { AccessibilityChannel.defaultGetTransportState(runtime: logicRuntime) },
                toggleTransportButton: {
                    AccessibilityChannel.defaultToggleTransportButton(
                        named: $0,
                        runtime: logicRuntime,
                        mouseRuntime: controlBarMouseRuntime
                    )
                },
                setTempo: {
                    AccessibilityChannel.defaultSetTempo(
                        params: $0,
                        runtime: logicRuntime,
                        mouseRuntime: controlBarMouseRuntime,
                        runFallback: runTempoFallback
                    )
                },
                setCycleRange: { AccessibilityChannel.defaultSetCycleRange(params: $0, runtime: logicRuntime) },
                tracks: { AccessibilityChannel.defaultGetTracks(runtime: logicRuntime) },
                selectedTrack: { AccessibilityChannel.defaultGetSelectedTrack(runtime: logicRuntime) },
                selectTrack: { await AccessibilityChannel.defaultSelectTrack(params: $0, runtime: logicRuntime) },
                setTrackToggle: { AccessibilityChannel.defaultSetTrackToggle(params: $0, button: $1, runtime: logicRuntime) },
                renameTrack: {
                    AccessibilityChannel.defaultRenameTrack(
                        params: $0,
                        runtime: logicRuntime,
                        mouseRuntime: trackRenameMouseRuntime,
                        processRuntime: processRuntime
                    )
                },
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
        case "transport.pause":
            // Logic has no distinct pause control; the Stop button halts the
            // playhead in place, which is exactly the verified pause target.
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

        case "nav.set_zoom_level":
            // #109: verified zoom via the writable Horizontal-Zoom AXSlider.
            return AccessibilityChannel.defaultSetZoomLevel(
                params: params, runtime: runtime.logicRuntime
            )

        // MARK: - Track reads
        case "track.get_tracks":
            // v3.1.8 (Issue #7) — AX-only at the channel layer. The v3.1.5
            // AppleScript-primary fallback was removed because Logic 12.x
            // dropped `tracks` from its scripting dictionary (always
            // returned -2753). The project-file count fallback now lives
            // in `ResourceHandlers.readTracks` where placeholder rows can
            // be emitted to resource consumers without poisoning the
            // shared StateCache.
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
            // v3.1.2 P2-1 — explicit State C `not_implemented` so callers
            // (and the router's terminal-error gate) can distinguish a
            // structural "this surface does not exist" from a transient AX
            // write failure. Logic Pro 12.0.1 does not expose track-color
            // mutation through the Accessibility API — the color swatch in
            // the inspector is a custom-drawn AppKit control with no AX
            // children or settable attributes.
            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "Track color is not exposed via AX in Logic Pro 12.0.1. Use Logic Pro UI directly."
            ))

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
            // "mode" selects between disk (default, filesystem-backed,
            // Panel-taxonomy mapped), ax (legacy live Panel walk), or both
            // (diff report).
            switch Self.parseScanMode(params["mode"]) {
            case .disk:
                return await self.runDiskScan(runtime: runtime.logicRuntime)
            case .both:
                return await self.runBothScan(runtime: runtime.logicRuntime)
            case .ax:
                return await self.runLiveScan(runtime: runtime.logicRuntime)
            }
        case "library.resolve_path":
            // v3.1.0 (T6) — panel-only lookups prefer the panel cache because
            // only panel entries are loadable via `selectPath`. Disk-only
            // entries are returned with `source:"disk-only"` + `loadable:false`
            // and a warning, which lets the client avoid calling
            // `set_instrument` against a path that will fail deterministically.
            return AccessibilityChannel.resolveLibraryPath(
                params: params,
                lastPanelScan: lastPanelScan,
                lastDiskScan: lastDiskScan,
                lastScan: lastScan,
                lastScanSource: lastScanSource
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
            // #135/#141 — wire a cache-backed pre-resolver from the live
            // Panel-scan cache (read-only). Only the AX/panel cache counts:
            // disk-mode scan does NOT satisfy set_instrument's live-panel
            // requirement, so we resolve against `lastPanelScan` only. A nil
            // cache → undecided (attempt nav), preserving prior behavior.
            let panelScanSnapshot = self.lastPanelScan
            let staging = AccessibilityChannel.LibraryPanelStaging(
                isPanelOpen: { rt in LibraryAccessor.isLibraryPanelOpen(runtime: rt) },
                openPanel: { rt in await AccessibilityChannel.openLibraryPanelViaKeyCommand(runtime: rt) },
                resolvePath: { path in
                    guard let root = panelScanSnapshot,
                          let resolution = LibraryAccessor.resolvePath(path, in: root) else {
                        return nil   // no cache → undecided, attempt nav
                    }
                    return resolution.exists
                }
            )
            let result = await AccessibilityChannel.setTrackInstrument(
                params: params, runtime: runtime.logicRuntime, staging: staging
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
                expectedTrackType: .softwareInstrument,
                runtime: runtime.logicRuntime
            )
        case "track.create_audio":
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 오디오 트랙",
                english: "New Audio Track",
                expectedTrackType: .audio,
                runtime: runtime.logicRuntime
            )
        case "track.create_drummer":
            // Logic 12.0.1+: menu renamed to "Session Player SI" with Drummer as
            // a sub-option in the dialog. Try Logic 12 menu first; fall back to
            // Logic 11's "Drummer 트랙" for older installs.
            let l12 = await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 Session Player SI 트랙…",
                english: "New Session Player SI Track…",
                expectedTrackType: .drummer,
                runtime: runtime.logicRuntime
            )
            if l12.isSuccess { return l12 }
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 Drummer 트랙",
                english: "New Drummer Track",
                expectedTrackType: .drummer,
                runtime: runtime.logicRuntime
            )
        case "track.create_external_midi":
            return await AccessibilityChannel.createTrackViaMenu(
                korean: "새로운 외부 MIDI 트랙",
                english: "New External MIDI Track",
                expectedTrackType: .externalMIDI,
                runtime: runtime.logicRuntime
            )

        case "track.delete":
            return await AccessibilityChannel.defaultDeleteTrack(
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
            // Restrict to the SMFWriter-managed temp dir after resolving
            // symlinks and path traversal. Raw MCP callers cannot point the
            // AX open-panel keystroke at arbitrary files on the user's
            // filesystem; the legitimate producer is TrackDispatcher.record_sequence.
            guard let safePath = AccessibilityChannel.validatedMIDIImportPath(path) else {
                return .error("midi.import_file path must be a server-managed LogicProMCP temp .mid")
            }
            return await runtime.importMIDIFile(safePath)

        // MARK: - Navigation
        case "nav.get_markers":
            // History: v3.1.5 used an AppleScript-primary path
            // (`tell front document → markers`) — Logic 12.x dictionary
            // doesn't expose `markers` so it was always failing; removed
            // in v3.1.8. v3.1.8's `AXRuler`-structural fallback also
            // returned empty on Logic 12.2 (Apple removed the role from
            // the arrange window AX subtree entirely). v3.1.9
            // (`AXLogicProElements.enumerateMarkers`) now scrapes the
            // dedicated Marker List window's `AXTable` first, falls
            // through to `AXRuler` for Logic 11.x, then keyword match
            // for Logic 10.x. See PRD-issue7-logic12-read-paths.md for
            // the strategy hierarchy.
            return runtime.markers()
        case "nav.rename_marker":
            // Issue #143 — marker renaming has no verified AX write path on
            // Logic 12.x (the Marker List table cells are not settable via
            // AX), so this surface is genuinely unbuilt. Return an explicit
            // State C `not_implemented` envelope instead of a free-form string:
            // a free-form `.error` falls through the router's single-channel
            // chain and is re-wrapped as `channels_exhausted`, which conflates
            // "feature not built" with "all channels failed". `not_implemented`
            // is in `terminalErrorCodes`, so the router surfaces it verbatim,
            // and the hint points callers at the create+delete workaround.
            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "Marker renaming is not implemented via AX in Logic Pro 12.x. Workaround: nav.delete_marker the target then nav.create_marker with the new name."
            ))

        // MARK: - Project
        case "project.get_info":
            // v3.1.8 (Issue #7) — AppleScript-primary fallback removed
            // (Logic 12.x dropped the `tempo` / `time signature` /
            // `count of tracks` terms). The AX path returns the window
            // title only; `ResourceHandlers.readProjectInfo` performs
            // per-field merge with `MetaData.plist` for tempo / tsig /
            // trackCount.
            return runtime.projectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return AccessibilityChannel.defaultGetRegions(runtime: runtime.logicRuntime)
        case "region.move_to_playhead":
            return await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(runtime: runtime.logicRuntime)
        case "region.select_last":
            return await AccessibilityChannel.defaultSelectLastRegion(runtime: runtime.logicRuntime)
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.insert":
            return await AccessibilityChannel.defaultInsertPlugin(params: params, runtime: runtime.logicRuntime)
        // plugin.bypass / plugin.remove are still intentionally absent from
        // the public contract; no verified AX readback path exists for them.
        case "plugin.list":
            return .error("Plugin list reading not yet implemented via AX")

        // MARK: - Verified plugin surface (logic_plugins.*)
        // Drift-safe inventory and verified live plugin writes. These route
        // through AX/CGEvent only, with readback as the only State-A authority
        // and State-C fail-closed behavior for unsupported or drifting UI.
        case "plugin.get_inventory":
            return await AccessibilityChannel.defaultGetPluginInventory(params: params, runtime: runtime.logicRuntime)
        case "plugin.set_param_verified":
            return await AccessibilityChannel.defaultSetParamVerified(params: params, runtime: runtime.logicRuntime)
        case "plugin.insert_verified":
            return await AccessibilityChannel.defaultInsertVerified(params: params, runtime: runtime.logicRuntime)

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    nonisolated func healthCheck() async -> ChannelHealth {
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
        guard let transport = AXLogicProElements.getControlBar(runtime: runtime)
                ?? AXLogicProElements.getTransportBar(runtime: runtime) else {
            return .error("Cannot locate transport bar")
        }
        var state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime.ax)
        if let isPlaying = AXLogicProElements.readControlBarCheckboxValue(
            named: "재생", englishName: "Play", runtime: runtime
        ) {
            state.isPlaying = isPlaying
        }
        if let isRecording = AXLogicProElements.readControlBarCheckboxValue(
            named: "녹음", englishName: "Record", runtime: runtime
        ) {
            state.isRecording = isRecording
        }
        if let isCycleEnabled = AXLogicProElements.readControlBarCheckboxValue(
            named: "사이클", englishName: "Cycle", runtime: runtime
        ) {
            state.isCycleEnabled = isCycleEnabled
        }
        if let isMetronomeEnabled = AXLogicProElements.readControlBarCheckboxValue(
            named: "메트로놈 클릭", englishName: "Metronome", runtime: runtime
        ) {
            state.isMetronomeEnabled = isMetronomeEnabled
        }
        return encodeResult(state)
    }

    private static func defaultToggleTransportButton(
        named name: String,
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
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
                korean: "녹음",
                english: "Record",
                desired: false,
                runtime: runtime,
                mouseRuntime: mouseRuntime
            )
        }
        if let mapping = controlBarMapping[name] {
            if let desired = mapping.desired {
                // Conditional toggle: only click if current != desired
                if let result = AccessibilityChannel.setControlBarCheckboxValue(
                    korean: mapping.korean,
                    english: mapping.english,
                    desired: desired,
                    runtime: runtime,
                    mouseRuntime: mouseRuntime
                ) {
                    return result
                }
            } else {
                // Unconditional toggle
                if let result = AccessibilityChannel.clickControlBarCheckbox(
                    korean: mapping.korean,
                    english: mapping.english,
                    runtime: runtime,
                    mouseRuntime: mouseRuntime
                ) {
                    return result
                }
            }
        }
        // Legacy fallback: search by role=Button with title/description.
        guard let button = AXLogicProElements.findTransportButton(named: name, runtime: runtime) else {
            var extras = transportLookupDiagnostics(named: name, runtime: runtime)
            extras["button"] = name
            extras["recovery_hint"] =
                "Bring Logic's main arrange window frontmost and dismiss any plugin, chooser, or modal window covering the transport controls."
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "transport button '\(name)' not located in the visible Logic transport UI",
                extras: extras
            ))
        }
        guard AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "AXPress failed on transport button '\(name)'",
                extras: ["button": name]
            ))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: ["button": name, "via": "legacy-axpress"]
        ))
    }

    private static func transportLookupDiagnostics(
        named name: String,
        runtime: AXLogicProElements.Runtime
    ) -> [String: Any] {
        let mainWindow = AXLogicProElements.mainWindow(runtime: runtime)
        let windowTitle = mainWindow.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? ""
        let controlBar = AXLogicProElements.getControlBar(runtime: runtime)
        let transportBar = AXLogicProElements.getTransportBar(runtime: runtime)
        return [
            "requested_button": name,
            "window_title": windowTitle,
            "control_bar_present": controlBar != nil,
            "transport_bar_present": transportBar != nil,
            "control_bar_checkboxes": controlBar.map {
                transportLandmarkLabels(root: $0, role: kAXCheckBoxRole, runtime: runtime)
            } ?? [],
            "transport_buttons": transportBar.map {
                transportLandmarkLabels(root: $0, role: kAXButtonRole, runtime: runtime)
            } ?? []
        ]
    }

    private static func transportLandmarkLabels(
        root: AXUIElement,
        role: String,
        runtime: AXLogicProElements.Runtime
    ) -> [String] {
        let elements = AXHelpers.findAllDescendants(
            of: root,
            role: role,
            maxDepth: 4,
            runtime: runtime.ax
        )
        var seen = Set<String>()
        var labels: [String] = []
        for element in elements {
            let candidates = [
                AXHelpers.getTitle(element, runtime: runtime.ax),
                AXHelpers.getDescription(element, runtime: runtime.ax),
                AXHelpers.getIdentifier(element, runtime: runtime.ax)
            ]
            for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
                labels.append(candidate)
                break
            }
            if labels.count >= 12 { break }
        }
        return labels
    }

    private static func defaultSetTempo(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production,
        runFallback: @escaping @Sendable (String) -> Bool = runTempoFallbackScript
    ) -> ChannelResult {
        guard let tempoStr = params["bpm"] ?? params["tempo"], let tempoValue = Double(tempoStr) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "transport.set_tempo requires 'tempo' or 'bpm' (Double)"
            ))
        }
        guard tempoValue >= 5.0 && tempoValue <= 990.0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "tempo \(tempoStr) out of slider range (5.0 .. 990.0)",
                extras: ["requested": tempoValue]
            ))
        }

        let baseExtras: [String: Any] = ["requested": tempoValue]

        if let slider = AXLogicProElements.findTempoSlider(runtime: runtime) {
            guard let position = AXHelpers.getPosition(slider, runtime: runtime.ax),
                  let size = AXHelpers.getSize(slider, runtime: runtime.ax) else {
                AXHelpers.setAttribute(slider, kAXValueAttribute, tempoStr as CFTypeRef, runtime: runtime.ax)
                _ = AXHelpers.performAction(slider, kAXConfirmAction, runtime: runtime.ax)
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: baseExtras.merging(["via": "slider-direct"]) { _, new in new }
                ))
            }
            let center = CGPoint(
                x: position.x + size.width / 2,
                y: position.y + size.height / 2
            )
            AXMouseHelper.doubleClick(at: center, runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.12)
            AXMouseHelper.typeNumericString(tempoStr, runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.05)
            AXMouseHelper.pressReturn(runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.15)

            if let finalValue = AXHelpers.getValue(slider, runtime: runtime.ax) as? Double,
               abs(finalValue - tempoValue) < 1.0 {
                return .success(HonestContract.encodeStateA(
                    extras: baseExtras.merging(["observed": finalValue, "via": "slider"]) { _, new in new }
                ))
            }

            AXMouseHelper.pressEscape(runtime: mouseRuntime)
            Thread.sleep(forTimeInterval: 0.05)
            let current = (AXHelpers.getValue(slider, runtime: runtime.ax) as? Double) ?? 0
            let delta = tempoValue - current
            let stepsInt = Int((abs(delta) / 10.0).rounded())
            if stepsInt > 0 {
                let action = delta > 0 ? kAXIncrementAction : kAXDecrementAction
                for _ in 0..<stepsInt {
                    _ = AXHelpers.performAction(slider, action, runtime: runtime.ax)
                }
            }
            if let afterIncrement = AXHelpers.getValue(slider, runtime: runtime.ax) as? Double {
                // Honest Contract (#189): the slider-increment fallback steps in
                // 10-BPM granularity, so it only reaches the requested tempo by
                // coincidence. Report success ONLY when the observed value matches
                // the request within tolerance; ANY readback mismatch fails closed
                // with State C — a write path must never report success when the
                // observed tempo differs from the requested tempo.
                if abs(afterIncrement - tempoValue) < 1.0 {
                    return .success(HonestContract.encodeStateA(
                        extras: baseExtras.merging([
                            "observed": afterIncrement,
                            "via": "slider-increment"
                        ]) { _, new in new }
                    ))
                }
                return .error(HonestContract.encodeStateC(
                    error: .readbackMismatch,
                    hint: "tempo write fell back to a 10-BPM increment step that did not land on the requested value (typed entry didn't commit); the slider cannot represent this exact tempo via increment",
                    extras: baseExtras.merging([
                        "observed": afterIncrement,
                        "via": "slider-increment",
                        "write_attempted": true,
                        "safe_to_retry": true
                    ]) { _, new in new }
                ))
            }
        }

        let tempoLandmarks = tempoControlLandmarks(runtime: runtime)
        let missingHint = tempoControlMissingHint(landmarks: tempoLandmarks)
        let missingExtras = baseExtras.merging(tempoLandmarks) { _, new in new }

        if shouldAttemptTempoFallback(landmarks: tempoLandmarks) && runFallback(tempoStr) {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "tempo fallback executed but no tempo readback was available",
                extras: missingExtras.merging(["via": "keyboard-fallback"]) { _, new in new }
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .elementNotFound,
            hint: missingHint,
            extras: missingExtras
        ))
    }

    private static func tempoControlLandmarks(
        runtime: AXLogicProElements.Runtime
    ) -> [String: Any] {
        let window = AXLogicProElements.mainWindow(runtime: runtime)
        let controlBar = AXLogicProElements.getControlBar(runtime: runtime)
        let transportBar = AXLogicProElements.getTransportBar(runtime: runtime)

        return [
            "main_window_title": (window.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? "") as Any,
            "dialog_present": AXLogicProElements.dialogPresent(runtime: runtime),
            "control_bar_found": controlBar != nil,
            "transport_bar_found": transportBar != nil,
            "track_header_count": AXLogicProElements.allTrackHeaders(runtime: runtime).count,
            "control_bar_slider_descriptions": tempoLandmarkStrings(
                in: controlBar,
                role: kAXSliderRole,
                runtime: runtime.ax
            ),
            "transport_slider_descriptions": tempoLandmarkStrings(
                in: transportBar,
                role: kAXSliderRole,
                runtime: runtime.ax
            ),
            "control_bar_checkbox_labels": tempoLandmarkCheckboxLabels(
                in: controlBar,
                runtime: runtime.ax
            ),
        ]
    }

    private static func tempoControlMissingHint(landmarks: [String: Any]) -> String {
        let dialogPresent = landmarks["dialog_present"] as? Bool ?? false
        let trackHeaderCount = landmarks["track_header_count"] as? Int ?? 0
        let controlBarFound = landmarks["control_bar_found"] as? Bool ?? false
        let transportBarFound = landmarks["transport_bar_found"] as? Bool ?? false

        if dialogPresent {
            return "tempo slider not located while a Logic dialog is present. Dismiss the dialog, clear the Create New Track prompt if visible, and retry."
        }
        if trackHeaderCount == 0 {
            return "tempo slider not located: no track headers are visible yet. Clear the Create New Track dialog or create a software instrument track first."
        }
        if !controlBarFound && !transportBarFound {
            return "tempo slider not located: Logic's Control Bar and transport UI were both absent from the AX tree. Ensure the project window is frontmost and fully loaded, then retry."
        }
        if !controlBarFound {
            return "tempo slider not located in Logic's Control Bar. Ensure the project window is frontmost and the Control Bar is visible, then retry."
        }
        return "tempo slider not located in Logic control bar; ensure Logic Pro is frontmost with an open project"
    }

    private static func shouldAttemptTempoFallback(landmarks: [String: Any]) -> Bool {
        let dialogPresent = landmarks["dialog_present"] as? Bool ?? false
        let trackHeaderCount = landmarks["track_header_count"] as? Int ?? 0
        let controlBarFound = landmarks["control_bar_found"] as? Bool ?? false
        let transportBarFound = landmarks["transport_bar_found"] as? Bool ?? false

        return !dialogPresent && trackHeaderCount > 0 && (controlBarFound || transportBarFound)
    }

    private static func tempoLandmarkStrings(
        in root: AXUIElement?,
        role: String,
        runtime: AXHelpers.Runtime
    ) -> [String] {
        guard let root else { return [] }
        let descendants = AXHelpers.findAllDescendants(
            of: root,
            role: role,
            maxDepth: 6,
            runtime: runtime
        )
        var values: [String] = []
        for element in descendants {
            let label = [
                AXHelpers.getDescription(element, runtime: runtime),
                AXHelpers.getTitle(element, runtime: runtime),
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            if let label, !values.contains(label) {
                values.append(label)
            }
        }
        return values
    }

    private static func tempoLandmarkCheckboxLabels(
        in root: AXUIElement?,
        runtime: AXHelpers.Runtime
    ) -> [String] {
        tempoLandmarkStrings(in: root, role: kAXCheckBoxRole, runtime: runtime)
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
        // 5s hard cap — script intent is < 1.5s, anything longer means Logic
        // is unresponsive (modal dialog stuck, focus lost, etc.).
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5.0,
            outputLimitBytes: 4 * 1024
        ) else {
            return false
        }
        return output.exitCode == 0
    }

    static func defaultSetCycleRange(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        runFallback: @escaping @Sendable (String, String) -> Bool = runCycleRangeFallbackScript
    ) -> ChannelResult {
        guard let startStr = params["start"], let endStr = params["end"] else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "set_cycle_range requires explicit 'start' and 'end'",
                extras: ["operation": "transport.set_cycle_range"]
            ))
        }
        // Normalise input: accept plain bar int ("5") or full bar/beat string ("5.1.1.1").
        let startPos = startStr.contains(".") ? startStr : "\(startStr).1.1.1"
        let endPos = endStr.contains(".") ? endStr : "\(endStr).1.1.1"
        let requested = cycleRangeRequested(start: startPos, end: endPos)

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
                let sSet = AXHelpers.setAttribute(
                    s, kAXValueAttribute, startPos as CFTypeRef, runtime: runtime.ax
                )
                AXHelpers.performAction(s, kAXConfirmAction, runtime: runtime.ax)
                let eSet = AXHelpers.setAttribute(
                    e, kAXValueAttribute, endPos as CFTypeRef, runtime: runtime.ax
                )
                AXHelpers.performAction(e, kAXConfirmAction, runtime: runtime.ax)

                // v3.1.0 (T5) — read back the two cycle locator fields and
                // build a 3-state Honest Contract envelope. Schema now
                // matches the osascript fallback: both paths emit
                // `{start, end, via, verified, requested, observed}`.
                let extras: [String: Any] = [
                    "operation": "transport.set_cycle_range",
                    "start": startPos,
                    "end": endPos,
                    "via": "ax",
                    "method": "ax_cycle_locator_text_fields",
                    "requested": requested
                ]
                if !sSet || !eSet {
                    // v3.1.0 (Ralph-2 / M-1) — State C must route through
                    // `.error(...)` so the MCP envelope's isError:true is
                    // set. The prior `.success(...)` wrapping produced an
                    // inconsistent signal vs. `track.select`'s State C.
                    return .error(HonestContract.encodeStateC(
                        error: .axWriteFailed,
                        hint: "setAttribute on cycle locator failed",
                        extras: extras
                    ))
                }
                let startReadBack: String? = AXHelpers.getAttribute(
                    s, kAXValueAttribute, runtime: runtime.ax
                )
                let endReadBack: String? = AXHelpers.getAttribute(
                    e, kAXValueAttribute, runtime: runtime.ax
                )
                let observed: [String: Any] = [
                    "start": startReadBack as Any? ?? NSNull(),
                    "end": endReadBack as Any? ?? NSNull()
                ]
                var merged = extras
                merged["observed"] = observed
                if startReadBack == nil || endReadBack == nil {
                    return .success(HonestContract.encodeStateB(
                        reason: .readbackUnavailable, extras: merged
                    ))
                }
                if startReadBack == startPos && endReadBack == endPos {
                    return .success(HonestContract.encodeStateA(extras: merged))
                }
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch, extras: merged
                ))
            }

            let transportLandmarks = cycleRangeLandmarks(
                runtime: runtime,
                transport: transport,
                textFields: texts
            )
            if runFallback(startPos, endPos) {
                return .error(HonestContract.encodeStateC(
                    error: .readbackUnavailable,
                    hint: "set_cycle_range could drive Logic's 'Set Locators' dialog fallback, but this build exposes no deterministic numeric locator readback; refusing to claim success without observed start/end locators",
                    extras: [
                        "operation": "transport.set_cycle_range",
                        "method": "osascript_set_locators_dialog",
                        "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                        "requested": requested,
                        "observed": cycleRangeObserved(start: nil, end: nil),
                        "write_attempted": true,
                        "safe_to_retry": false,
                        "what_was_attempted": "locate numeric cycle locator AX text fields, then drive Logic's 'Set Locators' dialog as a fallback",
                        "what_was_observed": "Logic exposes no cycle start/end AX text fields in the transport bar, so the fallback write could not be independently read back",
                        "scanned_landmarks": transportLandmarks,
                        "recovery_hint": "Set the cycle range manually in Logic or select a region and use Logic's 'Set Locators by Selection' command before bounce/export."
                    ]
                ))
            }

            return .error(HonestContract.encodeStateC(
                error: .notImplemented,
                hint: "set_cycle_range could not find numeric cycle locator fields and could not complete the 'Set Locators' dialog fallback. This Logic build/session does not expose a verifiable numeric cycle locator automation path.",
                extras: [
                    "operation": "transport.set_cycle_range",
                    "method": "ax_cycle_locator_text_fields",
                    "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                    "requested": requested,
                    "observed": cycleRangeObserved(start: nil, end: nil),
                    "write_attempted": false,
                    "safe_to_retry": false,
                    "what_was_attempted": "locate numeric cycle locator AX text fields, then open Logic's 'Set Locators' dialog as a fallback",
                    "what_was_observed": "Logic exposes no cycle start/end AX text fields in the transport bar and the fallback dialog could not be completed",
                    "scanned_landmarks": transportLandmarks,
                    "recovery_hint": "Set the cycle range manually in Logic or select a region and use Logic's 'Set Locators by Selection' command before bounce/export."
                ]
            ))
        }

        let missingTransportLandmarks = cycleRangeLandmarks(runtime: runtime)
        if runFallback(startPos, endPos) {
            // Fail closed when the fallback may have written but we still have
            // no observed numeric locator readback surface.
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "set_cycle_range could drive Logic's 'Set Locators' dialog fallback, but no transport bar was locatable for independent numeric locator readback",
                extras: [
                    "operation": "transport.set_cycle_range",
                    "method": "osascript_set_locators_dialog",
                    "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                    "requested": requested,
                    "observed": cycleRangeObserved(start: nil, end: nil),
                    "write_attempted": true,
                    "safe_to_retry": false,
                    "what_was_attempted": "find the transport bar, then drive Logic's 'Set Locators' dialog as a fallback",
                    "what_was_observed": "no transport bar was locatable for AX readback, so the fallback write could not be independently verified",
                    "scanned_landmarks": missingTransportLandmarks,
                    "recovery_hint": "Bring the arrange window to the front and set the cycle range manually before bounce/export."
                ]
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .notImplemented,
            hint: "set_cycle_range could not locate Logic's transport bar or a verifiable numeric cycle locator surface. The MCP server cannot currently set numeric cycle locators programmatically in this UI state.",
            extras: [
                "operation": "transport.set_cycle_range",
                "method": "ax_cycle_locator_text_fields",
                "attempted_methods": ["ax_cycle_locator_text_fields", "osascript_set_locators_dialog"],
                "requested": requested,
                "observed": cycleRangeObserved(start: nil, end: nil),
                "write_attempted": false,
                "safe_to_retry": false,
                "what_was_attempted": "find Logic's transport bar and numeric cycle locator fields",
                "what_was_observed": "no transport bar was locatable and the fallback dialog path could not be completed",
                "scanned_landmarks": missingTransportLandmarks,
                "recovery_hint": "Bring the arrange window to the front and set the cycle range manually before bounce/export."
            ]
        ))
    }

    private static func cycleRangeRequested(start: String, end: String) -> [String: Any] {
        ["start": start, "end": end]
    }

    private static func cycleRangeObserved(start: String?, end: String?) -> [String: Any] {
        ["start": start ?? NSNull(), "end": end ?? NSNull()]
    }

    private static func cycleRangeLandmarks(
        runtime: AXLogicProElements.Runtime,
        transport: AXUIElement? = nil,
        textFields: [AXUIElement]? = nil
    ) -> [String: Any] {
        let window = AXLogicProElements.mainWindow(runtime: runtime)
        let resolvedTransport = transport ?? AXLogicProElements.getTransportBar(runtime: runtime)
        let resolvedTextFields: [AXUIElement]
        if let textFields {
            resolvedTextFields = textFields
        } else if let resolvedTransport {
            resolvedTextFields = AXHelpers.findAllDescendants(
                of: resolvedTransport,
                role: kAXTextFieldRole,
                maxDepth: 6,
                runtime: runtime.ax
            )
        } else {
            resolvedTextFields = []
        }

        let textFieldSnapshots: [[String: Any]] = Array(resolvedTextFields.prefix(6)).map { field in
            let value: String? = AXHelpers.getAttribute(field, kAXValueAttribute, runtime: runtime.ax)
            return [
                "role": AXHelpers.getRole(field, runtime: runtime.ax) ?? NSNull(),
                "title": AXHelpers.getTitle(field, runtime: runtime.ax) ?? NSNull(),
                "description": AXHelpers.getDescription(field, runtime: runtime.ax) ?? NSNull(),
                "identifier": AXHelpers.getIdentifier(field, runtime: runtime.ax) ?? NSNull(),
                "value": value ?? NSNull(),
            ]
        }

        let cycleCheckbox = AXLogicProElements.findControlBarCheckbox(
            named: "사이클",
            englishName: "Cycle",
            runtime: runtime
        )

        return [
            "main_window_found": window != nil,
            "main_window_title": window.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_bar_found": resolvedTransport != nil,
            "transport_role": resolvedTransport.flatMap { AXHelpers.getRole($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_title": resolvedTransport.flatMap { AXHelpers.getTitle($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_description": resolvedTransport.flatMap { AXHelpers.getDescription($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_identifier": resolvedTransport.flatMap { AXHelpers.getIdentifier($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_child_count": resolvedTransport.flatMap { AXHelpers.getChildCount($0, runtime: runtime.ax) } ?? NSNull(),
            "transport_text_field_count": resolvedTextFields.count,
            "transport_text_fields": textFieldSnapshots,
            "cycle_checkbox_found": cycleCheckbox != nil,
            "cycle_checkbox_value": cycleCheckbox.flatMap { AXHelpers.getValue($0, runtime: runtime.ax) } ?? NSNull(),
        ]
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
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5.0,
            outputLimitBytes: 4 * 1024
        ), output.exitCode == 0 else {
            return false
        }
        let result = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            // v3.1.0 (T3) — missing track is a hard failure; no retry will
            // help. Keep legacy error-string path for ChannelResult.error so
            // existing callers that look at .isSuccess still see a failure,
            // but encode the structured envelope.
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: ["requested": index]
            ))
        }
        // v3.0.3+ — activate Logic so any coord-click fallback can land, then
        // go through the AX-native selection ladder.
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) via AX or coord click",
                extras: ["requested": index]
            ))
        }

        // v3.1.0 (T3) — verifyTrackSelection already retries 6× at 100ms
        // intervals internally (see TrackSelectionVerification). We surface
        // the outcome as a 3-state Honest Contract response rather than the
        // legacy free-form text. Existing `verified:true/false` JSON path
        // stays valid because the new envelope still contains those keys.
        let verification = await verifyTrackSelection(index: index, runtime: runtime)
        let base: [String: Any] = ["requested": index, "selected": index]
        switch verification {
        case .verified:
            return .success(HonestContract.encodeStateA(extras: base.merging([
                "observed": index
            ]) { _, new in new }))
        case .selectionMetadataUnavailable:
            // Ralph-2 / W1 (guardian iter2) — retry budget exhausted: the
            // read-back metadata never surfaced across 6×100ms attempts.
            // Docs (README, CHANGELOG, API.md, PRD) consistently
            // promise `retry_exhausted` for this case; emitting
            // `readback_unavailable` here would make the enum an orphan.
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: base.merging(["observed": NSNull()]) { _, new in new }
            ))
        case .mismatch(let selectedIndex):
            // v3.1.0 (Ralph-2 / P2-2) — read-back succeeded but returned a
            // different index. That's the textbook `readback_mismatch` case
            // per docs/API.md (State B taxonomy).
            // `retry_exhausted` stays reserved for
            // `.selectionMetadataUnavailable` — read-back metadata never
            // appeared across the retry budget. Clients switching on
            // `reason` can now pick accept-and-diverge (mismatch) vs.
            // back-off-and-refetch (retry_exhausted) correctly.
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "observed": selectedIndex as Any? ?? NSNull()
                ]) { _, new in new }
            ))
        case .trackDisappeared:
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) disappeared during selection verification",
                extras: base
            ))
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
        let baseExtras: [String: Any] = [
            "track": index,
            "button": buttonName,
            "requested": desired,
            "verification_source": "ax_value"
        ]

        if let cur = current, cur == desired {
            return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                "observed": desired,
                "action": "no-op"
            ]) { _, new in new }))
        }

        func readCurrent() -> Bool? {
            guard let v = AXHelpers.getValue(button, runtime: runtime.ax) else { return nil }
            if let n = v as? NSNumber { return n.boolValue }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            if let s = v as? String { return s == "1" || s.lowercased() == "true" }
            return nil
        }

        // #106: Logic 12.x track-header M/S/R checkboxes are `settable=false`
        // and ignore `AXPress`/`AXConfirm`/value writes entirely — only a real
        // mouse click at the control toggles Logic's internal state
        // (live-confirmed: AXPress leaves the value at 0 indefinitely; a HID
        // click flips it to 1 within ~350 ms). The earlier fixed 50 ms
        // read-back was also too fast for Logic to publish the new AX value
        // after a successful click, so even the arm path (whose locator did
        // find the checkbox) reported a false `ax_write_failed` *after*
        // physically toggling the control — a silent malfunction. The write
        // now polls the read-back up to a per-strategy deadline, and the
        // mouse-click last resort brings Logic frontmost first so the synthetic
        // click lands on the (un-occluded) track header.
        func pollMatched(deadlineMs: Int) -> Bool {
            let deadline = Date().addingTimeInterval(Double(deadlineMs) / 1000.0)
            repeat {
                if let after = readCurrent(), after == desired { return true }
                usleep(40_000)
            } while Date() < deadline
            return false
        }

        let strategies: [(name: String, pollMs: Int, action: () -> Void)] = [
            ("press", 160, { _ = AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) }),
            ("confirm", 160, { _ = AXHelpers.performAction(button, kAXConfirmAction, runtime: runtime.ax) }),
            ("value-nsnumber", 160, {
                let n: NSNumber = desired ? 1 : 0
                AXHelpers.setAttribute(button, kAXValueAttribute, n as CFTypeRef, runtime: runtime.ax)
            }),
            ("value-cfbool", 160, {
                let b: CFBoolean = desired ? kCFBooleanTrue : kCFBooleanFalse
                AXHelpers.setAttribute(button, kAXValueAttribute, b, runtime: runtime.ax)
            }),
            ("mouse-click", 1_000, {
                _ = ProcessUtils.Runtime.production.activateLogicPro()
                usleep(120_000)
                Self.postMouseClickAt(element: button, runtime: runtime.ax)
            }),
        ]
        for strategy in strategies {
            strategy.action()
            if pollMatched(deadlineMs: strategy.pollMs) {
                return .success(HonestContract.encodeStateA(extras: baseExtras.merging([
                    "observed": desired,
                    "action": strategy.name
                ]) { _, new in new }))
            }
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "tried press/confirm/value-nsnumber/value-cfbool/mouse-click; read-back never matched on track \(index) \(buttonName)=\(desired)",
            extras: baseExtras
        ))
    }

    /// Simulate a real user mouse-click at the screen center of an AX element.
    /// Used as a last resort when AXPress / AXValue writes don't propagate to
    /// Logic Pro's internal handlers (observed with Logic 12 rec-arm checkboxes).
    private static func postMouseClickAt(element: AXUIElement, runtime: AXHelpers.Runtime) {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let pr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        // H2 (P2-5): fail-closed on non-AXValue / wrong-subtype rather than
        // posting a click at (0,0).
        guard pr == .success, sr == .success,
              let pt = AXHelpers.point(fromRawAttribute: posValue),
              let sz = AXHelpers.size(fromRawAttribute: sizeValue) else { return }
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
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production,
        processRuntime: ProcessUtils.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "track.rename requires 'index' (Int) and 'name' (String)"
            ))
        }
        let truncatedName = String(name.prefix(255))
        let baseExtras: [String: Any] = ["track": index, "requested": truncatedName]

        func observedTrackName() -> String? {
            AXLogicProElements.trackName(at: index, runtime: runtime)
        }

        func verifiedResult(via: String) -> ChannelResult? {
            guard let observed = observedTrackName(), observed == truncatedName else { return nil }
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": observed,
                    "via": via
                ]) { _, new in new }
            ))
        }

        if let currentName = observedTrackName(), currentName == truncatedName {
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": currentName,
                    "via": "no-op"
                ]) { _, new in new }
            ))
        }

        guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track at index \(index) not found",
                extras: baseExtras
            ))
        }

        if let field = AXLogicProElements.findTrackNameField(trackIndex: index, runtime: runtime) {
            AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax)
            AXHelpers.setAttribute(field, kAXValueAttribute, truncatedName as CFTypeRef, runtime: runtime.ax)
            AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
            usleep(50_000)
            if let verified = verifiedResult(via: "ax_set_value") {
                return verified
            }
        }

        _ = ProcessUtils.activateLogicPro(runtime: processRuntime)
        guard selectTrackForRename(index: index, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to select track \(index) before rename",
                extras: baseExtras
            ))
        }
        raiseTrackWindowForRename(index: index, runtime: runtime)

        let click = clickTrackMenu(
            ["Rename Track", "트랙 이름 변경", "이름 변경"],
            menuName: "트랙",
            englishMenuName: "Track",
            runtime: runtime
        )
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > Rename Track menu item not found / not pressable",
                extras: baseExtras
            ))
        }

        usleep(150_000)
        AXMouseHelper.typeText(truncatedName, runtime: mouseRuntime)
        usleep(50_000)
        AXMouseHelper.pressReturn(runtime: mouseRuntime)
        usleep(150_000)

        if let verified = verifiedResult(via: "track_menu") {
            return verified
        }

        AXMouseHelper.pressEscape(runtime: mouseRuntime)
        usleep(50_000)
        let observed = observedTrackName()
        return .success(HonestContract.encodeStateB(
            reason: observed == nil ? .readbackUnavailable : .readbackMismatch,
            extras: baseExtras.merging([
                "observed": observed as Any? ?? NSNull(),
                "via": "track_menu"
            ]) { _, new in new }
        ))
    }

    private static func raiseTrackWindowForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) {
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime),
              let window: AXUIElement = AXHelpers.getAttribute(header, kAXWindowAttribute, runtime: runtime.ax)
        else {
            return
        }
        _ = AXHelpers.performAction(window, kAXRaiseAction, runtime: runtime.ax)
        usleep(50_000)
    }

    private static func selectTrackForRename(
        index: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) -> Bool {
        let initialHeaders = AXLogicProElements.allTrackHeaders(runtime: runtime)
        guard index >= 0 && index < initialHeaders.count else { return false }
        if AXValueExtractors.extractSelectedState(initialHeaders[index], runtime: runtime.ax) == true {
            return true
        }

        guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
            return false
        }

        var sawSelectionMetadata = false
        for attempt in 0..<6 {
            let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
            guard index < headers.count else { return false }

            let selectionStates = headers.map { AXValueExtractors.extractSelectedState($0, runtime: runtime.ax) }
            if selectionStates.contains(where: { $0 != nil }) {
                sawSelectionMetadata = true
            }
            if selectionStates[index] == true {
                return true
            }
            if attempt < 5 {
                usleep(100_000)
            }
        }
        return !sawSelectionMetadata
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
                if AXLocalePolicy.elementMatches(btn, AXLocalePolicy.cancelButton, runtime: runtime.ax) {
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
            if AXLocalePolicy.elementMatches(button, AXLocalePolicy.saveConfirmationButton, runtime: runtime.ax) {
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
                return .success(HonestContract.encodeStateA(
                    extras: ["requested": path, "observed": path, "via": "save-dialog"]
                ))
            }
        }

        let pathWithExt = path.hasSuffix(".logicx") ? path : path + ".logicx"
        if FileManager.default.fileExists(atPath: pathWithExt) {
            return .success(HonestContract.encodeStateA(
                extras: ["requested": path, "observed": pathWithExt, "via": "save-dialog-with-ext"]
            ))
        }

        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "Save As dialog completed but no file appeared at requested path within 5s",
            extras: ["requested": path]
        ))
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
        expectedTrackType: TrackType,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        guard AXLogicProElements.mainWindow(runtime: runtime) != nil else {
            return .error("No document open for track creation")
        }

        let beforeTracks = observedTrackStates(runtime: runtime)
        let beforeCount = beforeTracks.count

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
        let dialogConfirmationAttempted = midCount == beforeCount
        if dialogConfirmationAttempted {
            // Track not created yet — assume New Track dialog is awaiting confirmation
            sendReturnKey()
        }

        return await verifyTrackCreation(
            title: menuClickedTitle,
            expectedTrackType: expectedTrackType,
            beforeTracks: beforeTracks,
            dialogConfirmationAttempted: dialogConfirmationAttempted,
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
        expectedTrackType: TrackType,
        beforeTracks: [TrackState],
        dialogConfirmationAttempted: Bool,
        runtime: AXLogicProElements.Runtime
    ) async -> ChannelResult {
        let beforeCount = beforeTracks.count
        var lastObservedCount = beforeCount

        let extras: [String: Any] = [
            "menu_clicked": title,
            "track_count_before": beforeCount,
            "requested_delta": 1,
            "dialog_confirmation_attempted": dialogConfirmationAttempted,
            "observed_track_type": expectedTrackType.rawValue,
            "track_type_verification_source": "menu_clicked",
            "verification_source": "track_count_delta"
        ]

        for attempt in 0..<4 {
            let currentTracks = observedTrackStates(runtime: runtime)
            let currentCount = currentTracks.count
            lastObservedCount = currentCount
            if currentCount > beforeCount {
                var merged = extras.merging([
                    "track_count_after": currentCount,
                    "observed_delta": currentCount - beforeCount
                ]) { _, new in new }
                if let observedTrack = observedCreatedTrack(before: beforeTracks, after: currentTracks) {
                    merged["observed_track_index"] = observedTrack.id
                    merged["observed_track_name"] = observedTrack.name
                    merged["observed_track_type_inferred"] = observedTrack.type.rawValue
                }
                return .success(HonestContract.encodeStateA(extras: merged))
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        var merged = extras.merging([
            "track_count_after": lastObservedCount,
            "observed_delta": lastObservedCount - beforeCount
        ]) { _, new in new }
        let dialogPresent = AXLogicProElements.dialogPresent(runtime: runtime)
        merged["dialog_present"] = dialogPresent
        if dialogPresent {
            merged["waiting_for_user"] = true
            return .success(HonestContract.encodeStateB(
                reason: .retryExhausted,
                extras: merged
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "track count did not increase after '\(title)' click within 4×1s budget",
            extras: merged
        ))
    }

    private static func observedTrackStates(
        runtime: AXLogicProElements.Runtime = .production
    ) -> [TrackState] {
        AXLogicProElements.allTrackHeaders(runtime: runtime).enumerated().map { index, header in
            AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
        }
    }

    private static func observedCreatedTrack(
        before: [TrackState],
        after: [TrackState]
    ) -> TrackState? {
        if let selected = after.first(where: { $0.isSelected }) {
            return selected
        }
        guard after.count == before.count + 1 else {
            return after.last
        }
        var prefix = 0
        while prefix < before.count,
              trackCreationSignature(before[prefix]) == trackCreationSignature(after[prefix]) {
            prefix += 1
        }
        if prefix < after.count {
            return after[prefix]
        }
        return after.last
    }

    private static func trackCreationSignature(_ track: TrackState) -> String {
        [
            track.name,
            track.type.rawValue,
            String(track.isMuted),
            String(track.isSoloed),
            String(track.isArmed),
            track.color ?? ""
        ].joined(separator: "|")
    }

    /// Delete the currently-selected track via the `트랙 → 트랙 삭제` menu and
    /// verify the track count decremented by 1 within a 4×1s budget. Returns
    /// State A on confirmed delta, State B `retry_exhausted` if AX poll never
    /// catches the decrement, State C if the menu click itself fails.
    static func defaultDeleteTrack(
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        let beforeCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
        let click = clickTrackMenu("트랙 삭제", menuName: "트랙", englishMenuName: "Track", runtime: runtime)
        guard click.isSuccess else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Track > 트랙 삭제 menu item not found / not pressable",
                extras: ["track_count_before": beforeCount]
            ))
        }

        let extras: [String: Any] = [
            "menu_clicked": "트랙 삭제",
            "track_count_before": beforeCount,
            "requested_delta": -1
        ]

        var lastObservedCount = beforeCount
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let currentCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
            lastObservedCount = currentCount
            if currentCount < beforeCount {
                let merged = extras.merging([
                    "track_count_after": currentCount,
                    "observed_delta": currentCount - beforeCount
                ]) { _, new in new }
                return .success(HonestContract.encodeStateA(extras: merged))
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }

        let merged = extras.merging([
            "track_count_after": lastObservedCount,
            "observed_delta": lastObservedCount - beforeCount
        ]) { _, new in new }
        return .success(HonestContract.encodeStateB(
            reason: .retryExhausted,
            extras: merged
        ))
    }

    private static func clickTrackMenu(
        _ menuItemTitle: String,
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        clickTrackMenu([menuItemTitle], menuName: menuName, englishMenuName: englishMenuName, runtime: runtime)
    }

    private static func clickTrackMenu(
        _ menuItemTitles: [String],
        menuName: String = "트랙",
        englishMenuName: String = "Track",
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        for menuTitle in [menuName, englishMenuName] {
            for itemTitle in menuItemTitles {
                guard let item = AXLogicProElements.menuItem(path: [menuTitle, itemTitle], runtime: runtime) else {
                    continue
                }
                guard AXHelpers.performAction(item, kAXPressAction, runtime: runtime.ax) else {
                    return .error("Failed to click menu item: \(itemTitle)")
                }
                return .success("{\"menu_clicked\":\"\(itemTitle)\"}")
            }
        }
        let joinedTitles = menuItemTitles.joined(separator: " | ")
        return .error("Cannot find menu item: \(menuName) > \(joinedTitles)")
    }

    // MARK: - Mixer

    private static func defaultGetMixerState(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let volume = AXLogicProElements.findVolumeFader(in: strip, runtime: runtime.ax)
                .flatMap { AXValueExtractors.extractLogicMixerFaderValue($0, runtime: runtime.ax) }
                ?? 0.0
            let pan = AXLogicProElements.findPanControl(in: strip, runtime: runtime.ax)
                .flatMap { AXValueExtractors.extractCenteredSliderValue($0, runtime: runtime.ax) }
                ?? 0.0

            var state = ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            )
            state.plugins = AXLogicProElements.pluginSlots(in: strip, runtime: runtime.ax)
            state.pluginsSource = "ax"
            channelStrips.append(state)
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
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let volume = AXLogicProElements.findVolumeFader(in: strip, runtime: runtime.ax)
            .flatMap { AXValueExtractors.extractLogicMixerFaderValue($0, runtime: runtime.ax) }
            ?? 0.0
        let pan = AXLogicProElements.findPanControl(in: strip, runtime: runtime.ax)
            .flatMap { AXValueExtractors.extractCenteredSliderValue($0, runtime: runtime.ax) }
            ?? 0.0

        var state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        state.plugins = AXLogicProElements.pluginSlots(in: strip, runtime: runtime.ax)
        state.pluginsSource = "ax"
        return encodeResult(state)
    }

    static func pluginInsertSpec(named rawName: String) -> PluginInsertSpec? {
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "gain":
            return PluginInsertSpec(
                canonicalName: "Gain",
                aliases: ["Gain"],
                menuPaths: [
                    ["Utility", "Gain", "스테레오"],
                    ["Utility", "Gain", "Stereo"],
                    ["유틸리티", "Gain", "스테레오"],
                    ["유틸리티", "Gain", "Stereo"],
                ]
            )
        case "compressor":
            return PluginInsertSpec(
                canonicalName: "Compressor",
                aliases: ["Compressor"],
                menuPaths: [
                    ["Dynamics", "Compressor", "스테레오"],
                    ["Dynamics", "Compressor", "Stereo"],
                    ["다이내믹스", "Compressor", "스테레오"],
                    ["다이내믹스", "Compressor", "Stereo"],
                ]
            )
        case "channel eq", "channeleq":
            return PluginInsertSpec(
                canonicalName: "Channel EQ",
                aliases: ["Channel EQ"],
                menuPaths: [
                    ["Channel EQ", "스테레오"],
                    ["Channel EQ", "Stereo"],
                    ["EQ", "Channel EQ", "스테레오"],
                    ["EQ", "Channel EQ", "Stereo"],
                ]
            )
        default:
            return nil
        }
    }

    static func defaultInsertPlugin(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        selectPlugin: (PluginInsertSpec, AXUIElement, AXHelpers.Runtime) async -> Bool = selectLivePluginFromOpenMenu,
        rollback: () -> Bool = undoLastLogicAction,
        readbackTimeoutMs: Int = 2_000
    ) async -> ChannelResult {
        guard let trackRaw = params["track"] ?? params["track_index"] ?? params["index"],
              let track = Int(trackRaw), track >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "insert_plugin requires explicit 'track' (Int >= 0)"
            ))
        }
        guard let slotRaw = params["slot"] ?? params["insert"],
              let slotIndex = Int(slotRaw), slotIndex >= 0 else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "insert_plugin requires explicit 'slot' (Int >= 0)"
            ))
        }
        guard let pluginName = params["plugin_name"] ?? params["plugin"] ?? params["name"],
              let spec = pluginInsertSpec(named: pluginName) else {
            let requestedPluginName: Any
            if let rawPluginName = params["plugin_name"] ?? params["plugin"] ?? params["name"] {
                requestedPluginName = rawPluginName
            } else {
                requestedPluginName = NSNull()
            }
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "unsupported plugin for insert_plugin. Supported stock plugins: Gain, Compressor, Channel EQ",
                extras: ["requested_plugin_name": requestedPluginName]
            ))
        }
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Cannot locate visible mixer for insert_plugin"
            ))
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard track < strips.count else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "track index out of range for visible mixer",
                extras: ["track": track, "visible_strips": strips.count]
            ))
        }
        let strip = strips[track]
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strip, runtime: runtime.ax)
        guard slotIndex < slots.count else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "plugin slot out of range for visible mixer strip",
                extras: ["track": track, "slot": slotIndex, "visible_slots": slots.count]
            ))
        }
        let targetSlot = slots[slotIndex]
        guard targetSlot.isEmpty else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "slot_occupied: refusing to replace existing plugin",
                extras: [
                    "track": track,
                    "slot": slotIndex,
                    "existing_plugin_name": targetSlot.name ?? NSNull(),
                ]
            ))
        }

        _ = AXHelpers.performAction(targetSlot.element, kAXPressAction, runtime: runtime.ax)
        try? await Task.sleep(for: .milliseconds(250))
        guard await selectPlugin(spec, app, runtime.ax) else {
            dismissOpenMenu()
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "plugin menu selection failed",
                extras: ["track": track, "slot": slotIndex, "plugin_name": spec.canonicalName]
            ))
        }

        let observed = await pollPluginSlotName(
            track: track,
            slot: slotIndex,
            runtime: runtime,
            timeoutMs: readbackTimeoutMs
        )
        var extras: [String: Any] = [
            "track": track,
            "slot": slotIndex,
            "plugin_name": spec.canonicalName,
            "observed_plugin_name": observed ?? NSNull(),
            "verify_source": "ax_plugin_slot",
        ]
        if let observed, spec.matches(observed) {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        extras["rollback_attempted"] = true
        extras["rollback_succeeded"] = rollback()
        extras["requested_plugin_name"] = spec.canonicalName
        if observed == nil {
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: extras
            ))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackMismatch,
            extras: extras
        ))
    }

    private static func pollPluginSlotName(
        track: Int,
        slot: Int,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int
    ) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let mixer = AXLogicProElements.getMixerArea(runtime: runtime) {
                let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
                if track < strips.count {
                    let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
                    if slot < slots.count, let name = slots[slot].name {
                        return name
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func selectLivePluginFromOpenMenu(
        spec: PluginInsertSpec,
        app: AXUIElement,
        runtime: AXHelpers.Runtime
    ) async -> Bool {
        guard let rootMenu = findAudioPluginRootMenu(in: app, runtime: runtime) else {
            return false
        }
        for path in spec.menuPaths {
            if await pressMenuPath(path, rootMenu: rootMenu, runtime: runtime) {
                return true
            }
        }
        return false
    }

    private static func pressMenuPath(
        _ path: [String],
        rootMenu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) async -> Bool {
        guard !path.isEmpty else { return false }
        var menu = rootMenu
        for segment in path.dropLast() {
            guard let item = menuItem(named: segment, in: menu, runtime: runtime) else {
                return false
            }
            if AXHelpers.getChildren(item, runtime: runtime).first(where: {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuRole as String)
            }) == nil {
                _ = AXHelpers.performAction(item, kAXPressAction, runtime: runtime)
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let submenu = AXHelpers.getChildren(item, runtime: runtime).first(where: {
                (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuRole as String)
            }) else {
                return false
            }
            menu = submenu
        }
        guard let leaf = menuItem(named: path[path.count - 1], in: menu, runtime: runtime) else {
            return false
        }
        return AXHelpers.performAction(leaf, kAXPressAction, runtime: runtime)
    }

    private static func menuItem(
        named title: String,
        in menu: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        AXHelpers.getChildren(menu, runtime: runtime).first {
            (AXHelpers.getRole($0, runtime: runtime) ?? "") == (kAXMenuItemRole as String)
                && AXHelpers.getTitle($0, runtime: runtime) == title
        }
    }

    private static func findAudioPluginRootMenu(
        in element: AXUIElement,
        runtime: AXHelpers.Runtime,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth <= 8 else { return nil }
        if (AXHelpers.getRole(element, runtime: runtime) ?? "") == (kAXMenuRole as String) {
            let titles = Set(AXHelpers.getChildren(element, runtime: runtime).compactMap {
                AXHelpers.getTitle($0, runtime: runtime)
            })
            if titles.contains("Audio Units"),
               titles.contains("Utility") || titles.contains("유틸리티"),
               titles.contains("Channel EQ") {
                return element
            }
        }
        for child in AXHelpers.getChildren(element, runtime: runtime) {
            if let found = findAudioPluginRootMenu(in: child, runtime: runtime, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func dismissOpenMenu() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func undoLastLogicAction() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
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

        // Fail closed when Logic is running in a headless/no-window state.
        // Without this guard, AX can expose stale Library descendants from a
        // previous session and the scan may descend into a long probe despite
        // there being no visible project window to operate on.
        guard self.runtime.hasVisibleWindow() else {
            Log.info("scan_all: preflight failed — no visible Logic window", subsystem: "ax")
            return .error("Library panel not found. Open Library (⌘L) in Logic Pro.")
        }

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
            writeJSON: { root in Self.writeInventoryJSON(root, source: "ax") },
            onComplete: { root in await channel.setLastScan(root, source: "panel") },
            settleDelayMs: 150
        )
        guard let r = result else {
            return .error("Library panel not found. Open Library (⌘L) in Logic Pro.")
        }
        // v3.1.0 (T6) — AX scan response now includes `source:"panel"` so
        // clients can distinguish it from disk/both responses and route
        // `resolve_path` queries against the correct cache.
        return Self.encodeLibraryRoot(r.root, sourceTag: "panel")
    }

    /// Test-only seam for T6 cache-split coverage. Production call sites go
    /// through `runLiveScan` / `runDiskScan` / `runBothScan`. Internal so
    /// the `@testable import` surface sees it, external does not.
    func seedLastScanForTest(_ root: LibraryRoot, source: String) {
        setLastScan(root, source: source)
    }

    private func setLastScan(_ root: LibraryRoot, source: String) {
        self.lastScan = root
        self.lastScanSource = source
        switch source {
        case "panel":
            self.lastPanelScan = root
        case "disk":
            self.lastDiskScan = root
        case "both":
            self.lastBothScan = root
        default:
            break
        }
    }

    // MARK: - v3.0.5 disk-backed scan

    /// v3.0.5 — filesystem-backed `library.scan_all`. Enumerates
    /// `~/Music/Logic Pro Library.bundle/Patches/Instrument/` and produces a
    /// schema-identical `LibraryRoot` to the AX scan, but with full depth.
    /// Falls back to the legacy AX scan if the bundle is missing or unreadable
    /// (custom installs, Jam-Pack-only users, permission errors). Populates
    /// `lastScan` so `library.resolve_path` works against the disk tree.
    private func runDiskScan(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let t0 = Date()
        Log.info("scan_all: entering runDiskScan (mode=disk)", subsystem: "ax")
        do {
            let root = try LibraryDiskScanner.scan()
            let durationMs = Int(Date().timeIntervalSince(t0) * 1000)
            Log.info(
                "scan_all: disk scan ok — \(root.leafCount) leaves, \(root.folderCount) folders in \(durationMs)ms",
                subsystem: "ax"
            )
            self.setLastScan(root, source: "disk")
            _ = Self.writeInventoryJSON(root, source: "disk")
            return Self.encodeLibraryRoot(root, sourceTag: "disk")
        } catch {
            Log.warn(
                "scan_all: disk scan failed (\(error)); falling back to AX scan",
                subsystem: "ax"
            )
            return await self.runLiveScan(runtime: runtime)
        }
    }

    /// v3.0.5 — run both disk and AX scans, return a diff summary. Useful
    /// for verifying coverage parity and catching schema drift between
    /// Logic's disk layout and its Library Panel exposure. The AX scan is
    /// kicked off after the disk scan because the AX scan both takes longer
    /// and requires the Library Panel to be open — if the panel is closed
    /// the disk result still ships and the AX block degrades to a zero-leaf
    /// stub with `axAvailable:false`.
    private func runBothScan(runtime: AXLogicProElements.Runtime) async -> ChannelResult {
        let diskRoot: LibraryRoot
        do {
            diskRoot = try LibraryDiskScanner.scan()
        } catch {
            return .error("Disk scan failed: \(error); fall back to mode=ax")
        }
        self.setLastScan(diskRoot, source: "both")
        _ = Self.writeInventoryJSON(diskRoot, source: "disk")

        // Best-effort AX scan. If the panel is closed we still emit a diff
        // structure with ax={available:false, leafCount:0, ...} so clients
        // can detect the degraded case without parsing an error string.
        var axLeafCount = 0
        var axNodeCount = 0
        var axAvailable = false
        if LibraryAccessor.isLibraryPanelOpen(runtime: runtime) {
            let probe = Self.buildLiveTreeProbe(runtime: runtime)
            if let axRoot = await LibraryAccessor.enumerateTree(
                maxDepth: 12, settleDelayMs: 150, probe: probe
            ) {
                axLeafCount = axRoot.leafCount
                axNodeCount = axRoot.nodeCount
                axAvailable = true
                // v3.1.0 (Ralph-2 / C3) — mode=both did not previously expose
                // its AX scan to `resolve_path`. The disk tree was stored as
                // `lastBothScan` + `lastScan`, but `lastPanelScan` stayed nil,
                // so resolve_path hit the legacy fallback and labelled every
                // match `loadable:false` regardless of Panel presence. We
                // now seed `lastPanelScan` from the inline AX scan too so
                // Panel-loadable paths are correctly classified after
                // `scan_library {mode:"both"}`.
                self.lastPanelScan = axRoot
            }
        }

        let onlyOnDisk = max(0, diskRoot.leafCount - axLeafCount)
        let summary = """
        {"mode":"both","disk":{"leafCount":\(diskRoot.leafCount),"folderCount":\(diskRoot.folderCount),"nodeCount":\(diskRoot.nodeCount)},"ax":{"available":\(axAvailable),"leafCount":\(axLeafCount),"nodeCount":\(axNodeCount)},"diff":{"onlyOnDisk":\(onlyOnDisk)}}
        """
        return .success(summary)
    }

    /// Shared JSON encoder path used by disk / ax scan success branches so
    /// both modes emit identical formatting (sorted keys, no pretty-print).
    /// v3.1.0 (T6) — callers pass a `sourceTag` (panel|disk|both) that gets
    /// merged into the response envelope so clients can tell which scanner
    /// produced the tree without needing `scan_library` params echoed back.
    private static func encodeLibraryRoot(
        _ root: LibraryRoot, sourceTag: String = "panel"
    ) -> ChannelResult {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(root)
            guard let s = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode library inventory JSON")
            }
            // Wrap the raw LibraryRoot JSON in an envelope that names the
            // source scanner. Additive: legacy consumers that parsed the
            // raw root now must read `.root`, but the field is present
            // regardless of source so the schema is stable.
            let wrapped = "{\"source\":\"\(sourceTag)\",\"root\":\(s)}"
            return .success(wrapped)
        } catch {
            return .error("JSON encode failed: \(error)")
        }
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
        // 3. Locate Setting popup
        guard let popup = PluginInspector.findSettingPopupAX(in: pluginWin) else {
            return .error("Setting popup not found in plugin window")
        }
        // 4. Open the menu — AX-first ladder. AXShowMenu is the canonical popup
        //    action per NSAccessibility; AXPress sometimes works on Logic's
        //    custom popups; CGEvent click is the last-resort fallback.
        //    T0 verdict (v0.6) said raw AXPress was unreliable — we re-test here
        //    and only fall through to CGEvent if both AX actions fail to surface
        //    the AXMenu within the settle window.
        var menu: AXUIElement?
        let axOpenActions = [kAXShowMenuAction, kAXPressAction]
        for action in axOpenActions {
            if AXHelpers.performAction(popup, action, runtime: runtime.ax) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let found = PluginInspector.findOpenSettingMenuAX(in: appRoot) {
                    menu = found
                    break
                }
            }
        }
        if menu == nil {
            guard let center = PluginInspector.centerPoint(of: popup) else {
                return .error("Setting popup has no readable position/size; AXShowMenu/AXPress also failed")
            }
            guard LibraryAccessor.productionMouseClick(at: center) else {
                return .error("AXShowMenu/AXPress failed and CGEvent click on Setting popup also failed (Post-Event permission?)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            menu = PluginInspector.findOpenSettingMenuAX(in: appRoot)
        }
        guard let menu = menu else {
            return .error("Setting menu did not appear after AXShowMenu/AXPress/CGEvent (or already dismissed)")
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
    ///
    /// v3.0.4 NOTE: The 14× undercount of `scan_library` (345 leaves vs 4,891+
    /// disk `.patch` files) is caused by the `return []` at depth 2+ in this
    /// probe. A correct deep scan requires a non-destructive
    /// folder-vs-leaf discriminator BEFORE clicking, because clicking a
    /// preset-leaf in Logic's Library actually loads it onto the focused
    /// track — you cannot "probe by clicking" without mutating the user's
    /// project. The discriminator exists in the AX tree (column-2 items
    /// have an `AXDisclosureTriangle` sibling or an `AXChildren` attribute
    /// for subfolders; leaves have neither) but live-characterising Logic's
    /// exact AX exposure safely requires an offline probe session which was
    /// not available for v3.0.4.
    ///
    /// v3.0.5 RESOLUTION: This AX probe is no longer the default path —
    /// `library.scan_all` defaults to `{mode:"disk"}` which enumerates the
    /// factory Library bundle on disk (no click, no mutation, full coverage).
    /// This AX probe is preserved for `{mode:"ax"}` (legacy clients and diff
    /// mode) and still carries its 2-level limitation.
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

    /// v3.0.6 — size threshold that triggers a warn-level log on encode. We
    /// do not truncate or paginate (would break schema); just surface the
    /// signal so the next maintenance window can decide whether to chunk.
    private static let inventoryWarnBytes = 1_048_576   // 1 MiB

    /// Tag the encoded JSON with a `source` marker so downstream consumers
    /// can tell whether the file came from an AX scan (Panel-authoritative,
    /// may undercount) or a disk scan (full coverage, Panel-taxonomy mapped).
    /// The v3.0.5 bug was that the disk-mode path silently overwrote the
    /// AX-canonical file with no version tag. v3.0.6 also writes disk scans
    /// to a distinct file (`library-inventory-disk.json`) so the AX snapshot
    /// remains untouched unless explicitly refreshed by an AX scan.
    ///
    /// - Parameters:
    ///   - root: the LibraryRoot payload.
    ///   - source: either `"ax"` or `"disk"`. Controls both the embedded
    ///     `"source"` field and the destination filename.
    /// - Returns: true iff the file was written successfully.
    private static func writeInventoryJSON(_ root: LibraryRoot, source: String = "ax") -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard var rootData = try? encoder.encode(root) else { return false }

        // Inject a top-level `"source"` field by rewriting the outermost
        // `{` to `{ "source": "...",`. Cheaper than reflecting the whole
        // LibraryRoot into a dictionary, and avoids perturbing the Codable
        // contract used by clients that deserialize LibraryRoot directly
        // from a `scan_all` MCP response.
        let injection = "\n  \"source\" : \"\(source)\",".data(using: .utf8) ?? Data()
        // Find the first `{` byte and splice after it.
        if let firstBraceIdx = rootData.firstIndex(of: UInt8(ascii: "{")) {
            rootData.insert(contentsOf: injection, at: rootData.index(after: firstBraceIdx))
        }

        if rootData.count > inventoryWarnBytes {
            Log.warn(
                "Library inventory JSON is \(rootData.count) bytes (>1MiB); consider paginating library.scan_all in a future release",
                subsystem: "library"
            )
        }

        let fm = FileManager.default
        let resDir = fm.currentDirectoryPath + "/Resources"
        if !fm.fileExists(atPath: resDir) {
            try? fm.createDirectory(atPath: resDir, withIntermediateDirectories: true)
        }
        // Disk scans go to a distinct file so an AX snapshot survives a
        // disk scan. AX scans own the canonical filename.
        let filename = source == "disk" ? "library-inventory-disk.json" : "library-inventory.json"
        let path = resDir + "/" + filename
        do {
            try rootData.write(to: URL(fileURLWithPath: path), options: .atomic)
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
        // H2 (P2-5): fail-closed on non-AXValue / wrong-subtype rather than
        // deriving a (0,0)-based viewport.
        guard let p = AXHelpers.point(fromRawAttribute: posValue),
              let s = AXHelpers.size(fromRawAttribute: sizeValue) else { return nil }
        return (p.y, p.y + s.height)
    }

    private struct ResolvePathResponse: Encodable {
        let exists: Bool
        let kind: String?
        let matchedPath: String?
        let children: [String]?
        let reason: String?
        // v3.1.0 (T6) — when the match comes from the disk scan but not the
        // panel scan, `source` is `"disk-only"` and `loadable` is false so
        // clients know not to attempt `set_instrument` on this path.
        // When the match exists in the panel scan (or we only have a panel
        // scan), `source` is `"panel"` and `loadable` is true.
        let source: String?
        let loadable: Bool?
        let warning: String?
    }

    private struct SetInstrumentResponse: Encodable {
        let category: String
        let preset: String
        let path: String
    }

    /// v3.1.0 (T2) — read back the Library Panel's currently-selected preset
    /// and compare against the just-requested leaf. Used by `setTrackInstrument`
    /// to produce an Honest Contract 3-state response. Returns the observed
    /// preset name (or nil when the panel doesn't expose a current-selection
    /// attribute, which we treat as `readback_unavailable`).
    static func readBackLibraryPreset(
        runtime: AXLogicProElements.Runtime = .production
    ) -> String? {
        let inv = LibraryAccessor.enumerate(runtime: runtime)
        return inv?.currentPreset
    }

    private static func resolveLibraryPath(
        params: [String: String],
        lastPanelScan: LibraryRoot?,
        lastDiskScan: LibraryRoot?,
        lastScan: LibraryRoot?,
        lastScanSource: String?
    ) -> ChannelResult {
        guard let path = params["path"], !path.isEmpty else {
            return .error("Missing 'path' parameter for library.resolve_path")
        }
        // v3.1.0 (T6) — resolution ladder:
        //  1. If panel cache has the path, return source:"panel", loadable:true
        //  2. Else if disk cache has it, return source:"disk-only",
        //     loadable:false + warning (can't be loaded via AX Library Panel)
        //  3. Else fall back to the legacy `lastScan` (whatever was written
        //     most recently) so callers that only ran one scan still work.
        //  4. Else return exists:false.
        // Panel cache: take the hit only if the path exists there. A
        // `PathResolution(exists:false)` means the segment wasn't found in
        // the panel tree — fall through to the disk cache before declaring
        // the entry unloadable.
        if let root = lastPanelScan,
           let res = LibraryAccessor.resolvePath(path, in: root), res.exists {
            return encodeOrError(ResolvePathResponse(
                exists: true, kind: res.kind?.rawValue,
                matchedPath: res.matchedPath, children: res.children,
                reason: nil, source: "panel", loadable: true, warning: nil
            ))
        }
        if let root = lastDiskScan,
           let res = LibraryAccessor.resolvePath(path, in: root), res.exists {
            return encodeOrError(ResolvePathResponse(
                exists: true, kind: res.kind?.rawValue,
                matchedPath: res.matchedPath, children: res.children,
                reason: nil, source: "disk-only", loadable: false,
                warning: "Path exists on disk but isn't exposed via Logic's Library Panel. set_instrument will fail for this entry; run scan_library with mode=ax to see Panel-loadable paths."
            ))
        }
        // Legacy fallback — use whatever cache was last populated.
        guard let root = lastScan else {
            return encodeOrError(ResolvePathResponse(
                exists: false, kind: nil, matchedPath: nil, children: nil,
                reason: "No cached library scan; call scan_library first",
                source: nil, loadable: nil, warning: nil
            ))
        }
        guard let res = LibraryAccessor.resolvePath(path, in: root) else {
            return encodeOrError(ResolvePathResponse(
                exists: false, kind: nil, matchedPath: nil, children: nil,
                reason: nil, source: lastScanSource, loadable: nil, warning: nil
            ))
        }
        // If lastScanSource is "disk" or "both" and we didn't find the path
        // in lastPanelScan above, treat as disk-only.
        let isPanelLoadable = lastScanSource == "panel"
        return encodeOrError(ResolvePathResponse(
            exists: res.exists,
            kind: res.kind?.rawValue,
            matchedPath: res.matchedPath,
            children: res.children,
            reason: nil,
            source: lastScanSource,
            loadable: isPanelLoadable ? res.exists : false,
            warning: isPanelLoadable ? nil : "Path resolved from \(lastScanSource ?? "unknown") cache; may not be loadable via Library Panel."
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

    /// Injectable staging seam for `setTrackInstrument`'s Library-panel
    /// precondition + path pre-resolution. Production wires live AX reads + a
    /// ⌘L auto-open; tests inject deterministic outcomes (panel closed/open,
    /// path present/absent) without driving real Logic UI. #131/#135/#141.
    struct LibraryPanelStaging: Sendable {
        /// Read-only: is the Library panel currently open?
        let isPanelOpen: @Sendable (AXLogicProElements.Runtime) -> Bool
        /// Attempt to open the Library panel (⌘L / View > Show Library). Best
        /// effort; the caller re-checks `isPanelOpen` afterwards.
        let openPanel: @Sendable (AXLogicProElements.Runtime) async -> Void
        /// Pre-resolve the requested path against the cached inventory WITHOUT
        /// touching live AX. Returns:
        ///   .some(true)  → path is known to EXIST in the cache (attempt nav)
        ///   .some(false) → path is known to be ABSENT (fail closed, do not nav)
        ///   nil          → no cache available / cannot decide (attempt nav)
        let resolvePath: @Sendable (String) -> Bool?

        static let production = LibraryPanelStaging(
            isPanelOpen: { rt in LibraryAccessor.isLibraryPanelOpen(runtime: rt) },
            openPanel: { rt in await AccessibilityChannel.openLibraryPanelViaKeyCommand(runtime: rt) },
            // Static call site has no instance cache; the channel wires a
            // cache-backed resolver at the dispatch site. Default = undecided.
            resolvePath: { _ in nil }
        )
    }

    /// Best-effort Library-panel open via ⌘L (Logic's default "Show/Hide
    /// Library" key command). Mirrors the existing osascript keystroke pattern
    /// used by `runTempoFallbackScript`. No verification here — the caller
    /// re-checks `isLibraryPanelOpen` after a settle. v3.6.x (#131/#135/#141).
    static func openLibraryPanelViaKeyCommand(
        runtime: AXLogicProElements.Runtime = .production
    ) async {
        _ = ProcessUtils.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let script = """
        tell application "System Events"
            tell process "Logic Pro"
                set frontmost to true
                delay 0.15
                keystroke "l" using command down
            end tell
        end tell
        """
        _ = BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5.0,
            outputLimitBytes: 4 * 1024
        )
    }

    /// One-shot, thread-safe latch so a deadline race resumes its continuation
    /// exactly once. #131 robustness.
    private final class DeadlineLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Run a blocking Library-navigation closure under a hard wall-clock
    /// deadline. Returns the closure's result, or `nil` if the deadline elapsed
    /// first. The closure runs on a global queue (never the cooperative pool) so
    /// a wedged AX surface can't stall the stdio loop; if it overruns it is
    /// abandoned (the operation still returns bounded) rather than hanging
    /// indefinitely. #131 — set_instrument must never hang on an unresponsive
    /// Library panel.
    private static func runWithDeadline(
        seconds: Double,
        _ work: @escaping @Sendable () -> Bool
    ) async -> Bool? {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            let latch = DeadlineLatch()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                if latch.claim() { cont.resume(returning: result) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if latch.claim() { cont.resume(returning: nil) }
            }
        }
    }

    static func setTrackInstrument(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        staging: LibraryPanelStaging = .production
    ) async -> ChannelResult {
        // Resolve path-OR-legacy. Path wins when both provided.
        let pathParam = params["path"].flatMap { $0.isEmpty ? nil : $0 }
        let catParam = params["category"].flatMap { $0.isEmpty ? nil : $0 }
        let presetParam = params["preset"].flatMap { $0.isEmpty ? nil : $0 }

        // v3.0.4 — N-segment navigation. Logic's Library is a 2-column sliding
        // "finder column" view: top-level Bass has 4 presets, top-level
        // Synthesizer has 14 subfolders (Arpeggiated, Bass, Lead, Pad, …) and
        // each of those subfolders holds the actual preset leaves. Pre-3.0.4
        // logic took `parts[0]` + `parts[last]` which dropped all middle
        // segments — so `Synthesizer/Bass/Acid Etched Bass` resolved to
        // category=Synthesizer, preset=Acid Etched Bass, and failed because
        // column 2 at that point only held Synthesizer's subfolders.
        let pathSegments: [String]
        let resolvedPath: String
        if let p = pathParam {
            guard let parts = LibraryAccessor.parsePath(p), parts.count >= 2 else {
                return .error("Invalid 'path': must have at least 2 segments (e.g. 'Bass/Sub Bass' or 'Synthesizer/Bass/Acid Etched Bass')")
            }
            pathSegments = parts
            resolvedPath = p
        } else if let c = catParam, let pr = presetParam {
            pathSegments = [c, pr]
            resolvedPath = "\(c)/\(pr)"
        } else {
            return .error("Missing path or (category+preset) for track.set_instrument")
        }
        let category = pathSegments[0]
        let preset = pathSegments[pathSegments.count - 1]
        let requestedTrackIndex: Int?
        if let indexStr = params["index"] {
            guard let index = Int(indexStr), index >= 0 else {
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: "track.set_instrument 'index' must be a non-negative integer",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: NSNull(),
                        targetTrackName: NSNull()
                    )
                ))
            }
            requestedTrackIndex = index
        } else {
            requestedTrackIndex = nil
        }

        // v3.0.3+ — select target track via the Apple-public AX-first
        // selection ladder (AXPress → AXSelected → child AXPress → coord
        // click fallback). Logic must be frontmost for the last step to
        // register, so activate first regardless of which step ends up
        // committing.
        _ = ProcessUtils.Runtime.production.activateLogicPro()
        try? await Task.sleep(nanoseconds: 150_000_000)   // window raise settle

        var targetTrackIndex = requestedTrackIndex
        var targetTrackName: Any = NSNull()

        if let index = requestedTrackIndex {
            guard AXLogicProElements.findTrackHeader(at: index, runtime: runtime) != nil else {
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "Track at index \(index) not found",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: index,
                        targetTrackName: NSNull()
                    )
                ))
            }
            if let name = AXLogicProElements.trackName(at: index, runtime: runtime) {
                targetTrackName = name
            }
            if !CGPreflightPostEventAccess() {
                return .error("Event-post permission required (Accessibility → Input Monitoring). Grant in System Settings.")
            }
            guard AXLogicProElements.selectTrackViaAX(at: index, runtime: runtime) else {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "Failed to select track \(index) before instrument load",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: index,
                        targetTrackName: targetTrackName
                    )
                ))
            }

            let selectionVerification = await verifyTrackSelection(index: index, runtime: runtime)
            if let refreshedName = AXLogicProElements.trackName(at: index, runtime: runtime) {
                targetTrackName = refreshedName
            }
            let selectionBase = setInstrumentBaseExtras(
                requestedPath: resolvedPath,
                category: category,
                preset: preset,
                targetTrackIndex: index,
                targetTrackName: targetTrackName
            )
            switch selectionVerification {
            case .verified:
                break
            case .selectionMetadataUnavailable:
                return .error(HonestContract.encodeStateC(
                    error: .trackSelectionFailed,
                    hint: "Track \(index) selection could not be verified before instrument load",
                    extras: selectionBase.merging([
                        "observed": NSNull(),
                        "observed_patch_name": NSNull(),
                        "target_track_selection_verified": false,
                        "target_track_selection_reason": HonestContract.UncertainReason.retryExhausted.rawValue,
                        "target_track_selection_observed_index": NSNull(),
                        "target_track_selection_verify_source": "ax_selected"
                    ]) { _, new in new }
                ))
            case .mismatch(let selectedIndex):
                return .error(HonestContract.encodeStateC(
                    error: .trackSelectionFailed,
                    hint: "Track \(index) selection settled on a different track before instrument load",
                    extras: selectionBase.merging([
                        "observed": NSNull(),
                        "observed_patch_name": NSNull(),
                        "target_track_selection_verified": false,
                        "target_track_selection_reason": HonestContract.UncertainReason.readbackMismatch.rawValue,
                        "target_track_selection_observed_index": selectedIndex as Any? ?? NSNull(),
                        "target_track_selection_verify_source": "ax_selected"
                    ]) { _, new in new }
                ))
            case .trackDisappeared:
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "Track at index \(index) disappeared during selection verification",
                    extras: selectionBase.merging([
                        "observed": NSNull(),
                        "observed_patch_name": NSNull(),
                        "target_track_selection_verified": false,
                        "target_track_selection_reason": HonestContract.UncertainReason.readbackUnavailable.rawValue,
                        "target_track_selection_observed_index": NSNull(),
                        "target_track_selection_verify_source": "ax_selected"
                    ]) { _, new in new }
                ))
            }

            try? await Task.sleep(nanoseconds: 300_000_000)   // Library rebind to new track
        } else if let selectedTrack = selectedTrackIdentity(runtime: runtime) {
            targetTrackIndex = selectedTrack.index
            targetTrackName = selectedTrack.name ?? NSNull()
        }

        // #131 — TRACK-TYPE awareness. Loading a software-instrument Library
        // patch onto a GM Device / External MIDI strip is not a supported
        // operation: those lanes route to a General-MIDI device and bounce
        // silent (root cause of #128). Detect the unsupported target up front
        // and fail closed with a TYPED `unsupported_track_type` error instead
        // of letting selectPath produce the misleading "Library path not fully
        // resolvable". Only enforced when we have a concrete target index whose
        // header we can read; an indeterminate target falls through unchanged.
        if let idx = targetTrackIndex,
           let header = AXLogicProElements.findTrackHeader(at: idx, runtime: runtime) {
            let observedType = AXValueExtractors.extractTrackState(
                from: header, index: idx, runtime: runtime.ax
            ).type
            if observedType == .externalMIDI {
                return .error(HonestContract.encodeStateC(
                    error: .unsupportedTrackType,
                    hint: "Target track \(idx) is a GM Device / External MIDI strip; software-instrument Library patches cannot be loaded onto it. Target a Software Instrument track instead.",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: idx,
                        targetTrackName: targetTrackName
                    ).merging([
                        "observed_track_type": observedType.rawValue,
                        "precondition": "wrong_target_type"
                    ]) { _, new in new }
                ))
            }
        }

        // #135/#141 — Library-panel PRECONDITION. selectPath walks AXStaticText
        // rows in the VISIBLE Library browser; if the panel is closed those
        // rows do not exist and selectPath fails with the misleading
        // "Library path not fully resolvable" even when the path is valid.
        // Mirror scan_all's guard: if the panel is closed, try to auto-open it
        // (⌘L), settle, and re-check; if it still cannot be staged, fail closed
        // with a TYPED `library_panel_unavailable` error and an actionable hint
        // — NOT ax_write_failed.
        if !staging.isPanelOpen(runtime) {
            await staging.openPanel(runtime)
            try? await Task.sleep(nanoseconds: 400_000_000)   // panel slide-in settle
            if !staging.isPanelOpen(runtime) {
                return .error(HonestContract.encodeStateC(
                    error: .libraryPanelUnavailable,
                    hint: "Library panel not found. Open Library (⌘L) in Logic Pro, then retry.",
                    extras: setInstrumentBaseExtras(
                        requestedPath: resolvedPath,
                        category: category,
                        preset: preset,
                        targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                        targetTrackName: targetTrackName
                    ).merging(["precondition": "panel_closed"]) { _, new in new }
                ))
            }
        }

        // #135/#141 — PRE-RESOLVE the requested path against the cached
        // inventory (read-only, no live AX). This distinguishes a genuine
        // "path does not exist" (terminal precondition — do NOT attempt nav)
        // from "path exists but live AX nav failed" (still surfaces below as
        // ax_write_failed, a retry/timing signal). `resolvePath` returns nil
        // when no cache is available, in which case we attempt nav as before.
        if staging.resolvePath(resolvedPath) == false {
            return .error(HonestContract.encodeStateC(
                error: .pathNotInLibrary,
                hint: "Library path '\(resolvedPath)' was not found in the scanned inventory. Run scan_library and pick an existing path.",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                ).merging(["precondition": "missing_path"]) { _, new in new }
            ))
        }

        // v3.0.4 — walk every segment in order. For 2-segment paths this
        // behaves exactly like the prior selectCategory + selectPreset pair.
        // For 3+ segment paths (Synthesizer/Bass/Acid Etched Bass), each
        // intermediate segment slides the Library view so the next segment's
        // column-2 lookup resolves against the correct subfolder.
        // #131 robustness — bound the live Library navigation with a hard
        // deadline. An invalid path (or a panel left in a bad state by a prior
        // invalid attempt) can make the AX traversal stall far past any client
        // timeout, hanging the stdio loop. Fail closed with a typed State C
        // instead of hanging. The happy path resolves in a few seconds, well
        // under this ceiling.
        let navOutcome = await AccessibilityChannel.runWithDeadline(seconds: 15) {
            LibraryAccessor.selectPath(segments: pathSegments, runtime: runtime)
        }
        guard let didSelect = navOutcome else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "set_instrument Library navigation exceeded 15s and was abandoned — the Library panel's AX surface is unresponsive (a prior invalid-path attempt can leave it wedged). Re-open the Library (⌘L) and retry; restart Logic if it persists. Run scan_library first so an unknown path fails fast as path_not_in_library instead of navigating live.",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                ).merging(["precondition": "library_nav_timeout"]) { _, new in new }
            ))
        }
        guard didSelect else {
            // v3.1.0 (T2) — `selectPath` returns false when any segment's AX
            // write failed OR the segment's AXStaticText was not found in the
            // currently-visible browser. Both are hard failures — the patch
            // never loaded.
            //
            // v3.1.0 (Ralph-2 / M-1) — State C returns via `.error(...)` to
            // match `track.select`'s State C envelope. Previously this was
            // `.success(...)` which masked isError:false on the MCP wire and
            // broke clients switching on envelope-level error state.
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Library path not fully resolvable: \(resolvedPath)",
                extras: setInstrumentBaseExtras(
                    requestedPath: resolvedPath,
                    category: category,
                    preset: preset,
                    targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
                    targetTrackName: targetTrackName
                )
            ))
        }
        try? await Task.sleep(nanoseconds: 800_000_000) // let Logic load the instrument

        // v3.1.0 (T2) — Honest Contract read-back. The Library Panel's
        // AXList reports the currently-selected preset via its
        // `AXSelectedChildren` attribute. When present and matching, we
        // return State A (verified:true). When present but different, State
        // B with `readback_mismatch`. When not exposed at all (Logic build
        // dependent), State B with `readback_unavailable`.
        let observed = AccessibilityChannel.readBackLibraryPreset(runtime: runtime)
        var base = setInstrumentBaseExtras(
            requestedPath: resolvedPath,
            category: category,
            preset: preset,
            targetTrackIndex: targetTrackIndex as Any? ?? NSNull(),
            targetTrackName: targetTrackName
        )
        base["observed"] = observed ?? NSNull()
        base["observed_patch_name"] = observed ?? NSNull()
        base["verify_source"] = "library_selected_children"
        if requestedTrackIndex != nil {
            base["target_track_selection_verified"] = true
            base["target_track_selection_reason"] = "verified"
            base["target_track_selection_observed_index"] = targetTrackIndex as Any? ?? NSNull()
            base["target_track_selection_verify_source"] = "ax_selected"
        }
        if let observed {
            if observed == preset {
                return .success(HonestContract.encodeStateA(
                    extras: base.merging(["readback_state": "verified"]) { _, new in new }
                ))
            }
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: base.merging([
                    "readback_state": HonestContract.UncertainReason.readbackMismatch.rawValue
                ]) { _, new in new }
            ))
        }
        return .success(HonestContract.encodeStateB(
            reason: .readbackUnavailable,
            extras: base.merging([
                "readback_state": HonestContract.UncertainReason.readbackUnavailable.rawValue
            ]) { _, new in new }
        ))
    }

    private static func setInstrumentBaseExtras(
        requestedPath: String,
        category: String,
        preset: String,
        targetTrackIndex: Any,
        targetTrackName: Any
    ) -> [String: Any] {
        [
            "requested": preset,
            "requested_patch_name": preset,
            "requested_category": category,
            "requested_path": requestedPath,
            "category": category,
            "preset": preset,
            "path": requestedPath,
            "target_track_index": targetTrackIndex,
            "target_track_name": targetTrackName
        ]
    }

    private static func selectedTrackIdentity(
        runtime: AXLogicProElements.Runtime
    ) -> (index: Int, name: String?)? {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        for (index, header) in headers.enumerated() {
            guard AXValueExtractors.extractSelectedState(header, runtime: runtime.ax) == true else {
                continue
            }
            let state = AXValueExtractors.extractTrackState(from: header, index: index, runtime: runtime.ax)
            let trimmed = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return (index, trimmed.isEmpty ? nil : trimmed)
        }
        return nil
    }

    // MARK: - Control-bar playhead position helper

    /// Set the playhead to a specific bar. Two paths:
    /// 1) `탐색 → 이동 → 위치…` dialog (precise, auto-extends project, requires
    ///    at least one region in arrange — menu item is disabled on empty project)
    /// 2) Control-bar 마디 slider (clamps to project length; silently stops at
    ///    end when requested bar exceeds length)
    /// Accepts `{"bar": Int}` or `{"position": "B.B.S.S"}`.
    /// #109: set the arrange horizontal zoom to `level` (1...10) by writing the
    /// Horizontal-Zoom AXSlider (range 0...1, level 1 = fully out, 10 = fully
    /// in) and reading it back. Returns verified State A on a confirmed write,
    /// State B if the read-back can't confirm it. If the slider can't be found,
    /// returns a plain (non-terminal) error so the router falls back to the
    /// key-command channel.
    static func defaultSetZoomLevel(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        // Malformed input fails closed as terminal State C: a bad level must NOT
        // fall through to the key-command channel (which doesn't validate and
        // would fire a generic zoom). Mirrors gotoPositionViaBarSlider's guard.
        guard let levelStr = params["level"], let level = Int(levelStr), (1...10).contains(level) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "nav.set_zoom_level requires 'level' (Int 1..10)",
                extras: ["operation": "nav.set_zoom"]
            ))
        }
        // Slider absent is NOT terminal: plain error lets the router fall back to
        // the key-command / CGEvent channels.
        guard let slider = AXLogicProElements.findHorizontalZoomSlider(runtime: runtime) else {
            return .error("Horizontal Zoom slider not found — falling back to key command")
        }
        let target = Double(level - 1) / 9.0
        let before = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        _ = AXValueExtractors.setSliderValue(slider, target, runtime: runtime.ax)
        usleep(120_000)
        let after = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        let extras: [String: Any] = [
            "operation": "nav.set_zoom",
            "axis": "horizontal",
            "level": level,
            "requested": target,
            "observed_before": before ?? NSNull(),
            "observed": after ?? NSNull(),
            "observed_after": after ?? NSNull(),
            "verify_source": "ax_zoom_slider",
        ]
        if let after, abs(after - target) < 0.02 {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        return .success(HonestContract.encodeStateB(
            reason: after == nil ? .readbackUnavailable : .readbackMismatch,
            extras: extras
        ))
    }

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
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "goto_position requires 'bar' (Int 1..9999) or 'position' (B.B.S.S)"
            ))
        }

        let baseExtras: [String: Any] = ["requested": "\(bar).1.1.1"]

        let dialogResult = await gotoPositionViaDialog(bar: bar)
        if case .success = dialogResult { return dialogResult }

        guard let slider = AXLogicProElements.findControlBarBarSlider(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Neither goto-position dialog nor 마디 slider available",
                extras: baseExtras
            ))
        }
        let setOK = AXHelpers.setAttribute(
            slider, kAXValueAttribute, NSNumber(value: bar), runtime: runtime.ax
        )
        if !setOK {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "Failed to set 마디 slider value",
                extras: baseExtras
            ))
        }
        if let beatSlider = AXLogicProElements.findControlBarBeatSlider(runtime: runtime) {
            _ = AXHelpers.setAttribute(
                beatSlider, kAXValueAttribute, NSNumber(value: 1), runtime: runtime.ax
            )
        }
        _ = AXHelpers.performAction(slider, kAXConfirmAction, runtime: runtime.ax)

        let observedBar = (AXHelpers.getValue(slider, runtime: runtime.ax) as? NSNumber)?.intValue
        let observedPos = observedBar.map { "\($0).1.1.1" }
        let extras = baseExtras.merging([
            "observed": observedPos ?? NSNull(),
            "via": "slider"
        ]) { _, new in new }
        if let observedBar, observedBar == bar {
            return .success(HonestContract.encodeStateA(extras: extras))
        }
        if observedBar != nil {
            return .success(HonestContract.encodeStateB(reason: .readbackMismatch, extras: extras))
        }
        return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
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
            // #105: this State B reports only that the Go-To-Position dialog
            // keystroke was sent; the playhead is verified independently by
            // `TransportDispatcher.finalizeGotoPositionResult` via a transport-
            // state read-back. Earlier this carried a `note` claiming the
            // playhead was "not read back" — which the finalize step then
            // contradicted by reading it back and gating `verified` on it, so a
            // verified State A shipped a self-contradictory note. The provenance
            // (`via:"dialog"`) plus finalize's `verification_source` /
            // `observed` / `verified` fields describe the outcome honestly
            // without it.
            return .success(HonestContract.encodeStateB(
                reason: .readbackUnavailable,
                extras: [
                    "requested": "\(bar).1.1.1",
                    "via": "dialog"
                ]
            ))
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
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
    ) -> ChannelResult? {
        guard let cb = AXLogicProElements.findControlBarCheckbox(
            named: korean, englishName: english, runtime: runtime
        ) else {
            return nil
        }
        let before = controlBarCheckboxValue(cb, runtime: runtime)
        var attempts: [String] = []

        for strategy in controlBarClickStrategies(
            element: cb,
            runtime: runtime,
            mouseRuntime: mouseRuntime
        ) {
            guard strategy.action() else {
                attempts.append("\(strategy.name):failed")
                continue
            }
            attempts.append(strategy.name)
            if let before {
                if let after = waitForControlBarCheckboxValue(
                    cb,
                    runtime: runtime,
                    matching: { $0 != before }
                ) {
                    return .success(HonestContract.encodeStateA(
                        extras: [
                            "button": english,
                            "control": korean,
                            "observed": after,
                            "previous": before,
                            "action": strategy.name,
                            "attempts": attempts
                        ]
                    ))
                }
            } else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "button": english,
                        "control": korean,
                        "action": strategy.name,
                        "attempts": attempts
                    ]
                ))
            }
        }

        if let before {
            return .error(HonestContract.encodeStateC(
                error: .readbackMismatch,
                hint: "control-bar checkbox '\(english)' did not change after real click / AXPress attempts",
                extras: [
                    "button": english,
                    "control": korean,
                    "observed": before,
                    "attempts": attempts,
                    "safe_to_retry": true
                ]
            ))
        }
        return .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "control-bar checkbox '\(english)' had no readable value and no click strategy succeeded",
            extras: [
                "button": english,
                "control": korean,
                "attempts": attempts,
                "safe_to_retry": true
            ]
        ))
    }

    /// Ensure a control-bar checkbox matches `desired` state. Reads current
    /// value and clicks only if it differs. Returns nil if the checkbox
    /// cannot be located (caller may fall back).
    private static func setControlBarCheckboxValue(
        korean: String,
        english: String,
        desired: Bool,
        runtime: AXLogicProElements.Runtime = .production,
        mouseRuntime: AXMouseHelper.Runtime = .production
    ) -> ChannelResult? {
        guard let cb = AXLogicProElements.findControlBarCheckbox(
            named: korean, englishName: english, runtime: runtime
        ) else {
            return nil
        }
        guard let current = controlBarCheckboxValue(cb, runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "control-bar checkbox '\(english)' current value is unreadable; refusing unsafe toggle-click for desired=\(desired)",
                extras: [
                    "button": english,
                    "control": korean,
                    "requested": desired,
                    "safe_to_retry": true
                ]
            ))
        }
        let baseExtras: [String: Any] = [
            "button": english,
            "control": korean,
            "requested": desired
        ]
        if current == desired {
            return .success(HonestContract.encodeStateA(
                extras: baseExtras.merging([
                    "observed": desired,
                    "action": "no-op"
                ]) { _, new in new }
            ))
        }

        var attempts: [String] = []
        for strategy in controlBarClickStrategies(
            element: cb,
            runtime: runtime,
            mouseRuntime: mouseRuntime
        ) {
            guard strategy.action() else {
                attempts.append("\(strategy.name):failed")
                continue
            }
            attempts.append(strategy.name)
            if let observed = waitForControlBarCheckboxValue(
                cb,
                runtime: runtime,
                matching: { $0 == desired }
            ) {
                return .success(HonestContract.encodeStateA(
                    extras: baseExtras.merging([
                        "observed": observed,
                        "action": strategy.name,
                        "attempts": attempts
                    ]) { _, new in new }
                ))
            }
        }

        let observed = controlBarCheckboxValue(cb, runtime: runtime) as Any
        return .error(HonestContract.encodeStateC(
            error: .readbackMismatch,
            hint: "control-bar checkbox '\(english)' did not reach desired=\(desired) after real click / AXPress attempts",
            extras: baseExtras.merging([
                "observed": observed,
                "attempts": attempts,
                "safe_to_retry": true
            ]) { _, new in new }
        ))
    }

    private struct ControlBarClickStrategy {
        let name: String
        let action: () -> Bool
    }

    private static func controlBarClickStrategies(
        element: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        mouseRuntime: AXMouseHelper.Runtime
    ) -> [ControlBarClickStrategy] {
        [
            ControlBarClickStrategy(name: "mouse-click", action: {
                guard let position = AXHelpers.getPosition(element, runtime: runtime.ax),
                      let size = AXHelpers.getSize(element, runtime: runtime.ax),
                      position.x.isFinite,
                      position.y.isFinite,
                      size.width.isFinite,
                      size.height.isFinite,
                      size.width > 0,
                      size.height > 0 else {
                    return false
                }
                let center = CGPoint(
                    x: position.x + size.width / 2,
                    y: position.y + size.height / 2
                )
                return AXMouseHelper.click(at: center, runtime: mouseRuntime)
            }),
            ControlBarClickStrategy(name: "axpress", action: {
                AXHelpers.performAction(element, kAXPressAction, runtime: runtime.ax)
            }),
            ControlBarClickStrategy(name: "axconfirm", action: {
                AXHelpers.performAction(element, kAXConfirmAction, runtime: runtime.ax)
            }),
        ]
    }

    private static func controlBarCheckboxValue(
        _ element: AXUIElement,
        runtime: AXLogicProElements.Runtime
    ) -> Bool? {
        guard let raw = AXHelpers.getValue(element, runtime: runtime.ax) else { return nil }
        if let n = raw as? NSNumber { return n.boolValue }
        if let b = raw as? Bool { return b }
        if let i = raw as? Int { return i != 0 }
        if let s = raw as? String {
            let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) { return true }
            if ["0", "false", "no", "off"].contains(normalized) { return false }
        }
        return nil
    }

    private static func waitForControlBarCheckboxValue(
        _ element: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        matching predicate: (Bool) -> Bool
    ) -> Bool? {
        for _ in 0..<12 {
            usleep(50_000)
            if let value = controlBarCheckboxValue(element, runtime: runtime),
               predicate(value) {
                return value
            }
        }
        return nil
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
        let operation = target == .volume ? "mixer.set_volume" : "mixer.set_pan"
        let targetIdentity: [String: Any] = [
            "track_index": index,
            "control": label,
        ]

        // #107: target the per-track fader/pan slider in the track HEADER. It is
        // the same channel parameter as the mixer-strip control but identity-safe
        // (it belongs to exactly track `index`, so we can never write the wrong
        // strip the way positional indexing into a 2-strip Inspector mixer could)
        // and is available without the Mixer being visible. Logic ignores AXValue
        // writes on these sliders entirely (live-confirmed: `set 0.5` leaves a
        // 0.76 fader unmoved) — only AXIncrement/AXDecrement detents move them,
        // in deterministic ~10-raw-unit steps. We converge to the nearest
        // representable detent and read back every step.
        let slider: AXUIElement?
        switch target {
        case .volume: slider = AXLogicProElements.findTrackHeaderVolumeFader(at: index, runtime: runtime)
        case .pan:    slider = AXLogicProElements.findTrackHeaderPanControl(at: index, runtime: runtime)
        }
        guard let slider else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "Cannot locate \(label) control for track \(index)",
                extras: [
                    "operation": operation,
                    "track": index,
                    "requested": value,
                    "target_identity": targetIdentity,
                    "recovery_hint": "Ensure track \(index) exists and the Tracks area is shown.",
                ]
            ))
        }
        guard let range = AXValueExtractors.extractSliderRange(slider, runtime: runtime.ax),
              range.max > range.min else {
            return .error(HonestContract.encodeStateC(
                error: .readbackUnavailable,
                hint: "\(label) slider for track \(index) exposes no AX range",
                extras: [
                    "operation": operation, "track": index, "requested": value,
                    "target_identity": targetIdentity, "verify_source": "ax_slider",
                ]
            ))
        }

        func readContract() -> Double? {
            switch target {
            case .volume: return AXValueExtractors.extractLogicMixerFaderValue(slider, runtime: runtime.ax)
            case .pan:    return AXValueExtractors.headerPanContract(slider, range: range, runtime: runtime.ax)
            }
        }
        let observedBefore = readContract()

        // Desired raw AX value for the requested contract value.
        let targetRaw: Double
        switch target {
        case .volume:
            targetRaw = AXValueExtractors.logicMixerFaderContractToRaw(value, range: range)
        case .pan:
            let center = (range.min + range.max) / 2.0
            let half = (range.max - range.min) / 2.0
            targetRaw = center + min(max(value, -1.0), 1.0) * half
        }

        // Closed-loop AXIncrement/AXDecrement nudge toward `targetRaw`. Stops on
        // reaching/crossing the target (landing on the nearer detent) or when no
        // detent moves the value (rail / unresponsive).
        var current = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        var steps = 0
        var stagnant = 0
        let maxSteps = 64
        while let cur = current, steps < maxSteps {
            if abs(cur - targetRaw) < 0.5 { break }
            let goingUp = cur < targetRaw
            _ = AXHelpers.performAction(slider, goingUp ? kAXIncrementAction : kAXDecrementAction, runtime: runtime.ax)
            steps += 1
            usleep(25_000)
            guard let next = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax) else { break }
            let crossed = (cur < targetRaw && next >= targetRaw) || (cur > targetRaw && next <= targetRaw)
            if crossed {
                // Land on whichever of cur/next is closer to the target.
                if abs(cur - targetRaw) < abs(next - targetRaw) {
                    _ = AXHelpers.performAction(slider, goingUp ? kAXDecrementAction : kAXIncrementAction, runtime: runtime.ax)
                    usleep(25_000)
                }
                break
            }
            if next == cur { stagnant += 1; if stagnant >= 2 { break } } else { stagnant = 0 }
            current = next
        }

        let observedRaw = AXValueExtractors.extractSliderValue(slider, runtime: runtime.ax)
        let observedAfter = readContract()
        // One detent is ~10 raw units; "verified" means we converged to the
        // nearest AX-representable detent (within ~half a detent of target).
        let convergedToNearestDetent = observedRaw.map { abs($0 - targetRaw) <= 6.0 } ?? false

        var baseExtras: [String: Any] = [
            "operation": operation,
            "track": index,
            "control": label,
            "requested": value,
            "target_identity": targetIdentity,
            "observed_before": observedBefore ?? NSNull(),
            "observed_after": observedAfter ?? NSNull(),
            "observed": observedAfter ?? NSNull(),
            "observed_raw": observedRaw ?? NSNull(),
            "target_raw": targetRaw,
            "detent_raw_step": 10,
            "verify_source": "ax_slider",
            "write_method": "ax_increment_decrement",
            "nudge_steps": steps,
            "quantization_note": "Logic exposes this fader to AX in ~10-raw-unit detents; observed is the nearest representable level to requested.",
        ]
        if convergedToNearestDetent, let actual = observedAfter {
            baseExtras["observed"] = actual
            return .success(HonestContract.encodeStateA(extras: baseExtras))
        }
        return .success(HonestContract.encodeStateB(
            reason: observedAfter == nil ? .readbackUnavailable : .readbackMismatch,
            extras: baseExtras
        ))
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

    // MARK: - Markers

    /// v3.1.9 (Issue #8) — Logic 12.2 marker subtree path.
    ///
    /// Single delegating wrapper around `AXLogicProElements.enumerateMarkers`
    /// (when the arrangement area exists) or its in-window scrape helper
    /// (when 12.2 has dropped the arrangement-area identifier). Pre-v3.1.9
    /// this function did its own copy of the marker-list-window strategy
    /// AND then called `enumerateMarkers(in:)` which redundantly retried
    /// the same lookup — boomer review flagged the double scrape.
    /// v3.1.9-final puts strategy ordering in `enumerateMarkers` and uses
    /// the in-window helper directly only when there is no arrangement
    /// area to pass.
    ///
    /// Behaviour matrix:
    ///
    /// | arrange area | marker list window | strategy |
    /// |--------------|--------------------|----------|
    /// | non-nil      | open / closed      | `enumerateMarkers(in: area)` runs all 3 strategies |
    /// | nil (12.2)   | open               | `enumerateMarkersFromListWindow` direct |
    /// | nil          | closed             | empty (honest, cache stamped) |
    ///
    /// The "empty as success" return on the no-surface case is intentional:
    /// it lets `StatePoller` write `[]` into the cache so resource handlers
    /// report `source: "ax_live"` rather than `source: "default"` — telling
    /// callers the poll ran and observed nothing rather than the poll
    /// never having run.
    private static func defaultGetMarkers(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        if let area = AXLogicProElements.getArrangementArea(runtime: runtime) {
            return encodeResult(AXLogicProElements.enumerateMarkers(in: area, runtime: runtime))
        }
        // Logic 12.2 commonly has no arrangement area identifier; fall
        // straight to the marker list window scrape without re-walking
        // strategies that require an arrange-area root.
        if let listWindow = AXLogicProElements.findMarkerListWindow(runtime: runtime) {
            return encodeResult(AXLogicProElements.enumerateMarkersFromListWindow(
                listWindow, runtime: runtime.ax
            ))
        }
        return encodeResult([MarkerState]())
    }

    // MARK: - Removed in v3.1.8 (Issue #7)
    //
    // The v3.1.5 AppleScript-primary read helpers (`markersViaAppleScript`,
    // `projectInfoViaAppleScript`, `tracksViaAppleScript`) have been removed.
    //
    // Background: v3.1.5 introduced these helpers because AX scrapes were
    // panel-focus dependent on Logic 12.x. The intent was to query
    // `tell front document → tracks / markers / tempo` directly. Logic Pro
    // 12.0+ ships an AppleScript scripting dictionary that does NOT expose
    // any of those terms — every call returns -2753 ("variable is not
    // defined"). The helpers therefore added a wasted IPC round-trip on
    // every poll without ever supplying real data on the targeted platform.
    //
    // The Issue #3/#4/#5 fix has moved to the resource layer
    // (`ResourceHandlers.readProjectInfo` / `readTracks`) which now reads
    // `MetaData.plist` directly via `LogicProjectFileReader` for the
    // project-file tier. The AX path stays as the live tier (hardened in
    // T6: strict `getTrackHeaders` / `allTrackHeaders`; AXRuler-based
    // `enumerateMarkers`).


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
