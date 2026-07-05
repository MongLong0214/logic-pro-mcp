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
    private var libraryScanInProgress: Bool = false
    private var pluginScanInProgress: Bool = false
    // v3.1.0 (T6) — split the single `lastScan` into three source-keyed caches.
    // Panel scans certify Panel presence; disk scans provide the full local
    // candidate catalog; `lastScan` remains populated for legacy callers that
    // only ask for "any recent scan".
    private var lastScan: LibraryRoot? = nil
    private var lastPanelScan: LibraryRoot? = nil
    private var lastDiskScan: LibraryRoot? = nil
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
            // E15: atomic check-and-set within actor step (no suspension points).
            // Library and plugin AX scans are mutually exclusive — either one in
            // flight rejects the other so we never run two concurrent AX-tree
            // traversals of Logic. Each scan still clears only its OWN flag.
            if libraryScanInProgress || pluginScanInProgress {
                return .error("Library scan already in progress")
            }
            libraryScanInProgress = true
            defer { libraryScanInProgress = false }
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
            // v3.1.0 (T6) + #222 — panel hits win; disk hits are loadable
            // candidates only when no panel cache has proved the path absent.
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
            // E15: mutually exclusive with library.scan_all — either AX-tree scan
            // in flight rejects the other. Each scan still clears only its OWN flag.
            if libraryScanInProgress || pluginScanInProgress {
                return .error("AX scan already in progress")
            }
            pluginScanInProgress = true
            defer { pluginScanInProgress = false }
            let settleMs = Int(params["submenuOpenDelayMs"] ?? "250") ?? 250
            return await AccessibilityChannel.runLivePluginPresetScan(
                runtime: runtime.logicRuntime, settleMs: settleMs
            )
        case "track.set_instrument":
            // #135/#141/#222 — wire a cache-backed pre-resolver. A Panel cache
            // can certify a path as Panel-present; an already-captured disk
            // cache can fail fast for non-leaf factory paths, but we do not
            // create a fresh disk scan here. Disk inventory is not the same
            // denominator as the live Panel inventory, and treating an implicit
            // disk miss as a hard Panel miss reintroduces the #222 contract bug.
            let panelScanSnapshot = self.lastPanelScan
            let diskScanSnapshot = self.lastDiskScan
            let staging = AccessibilityChannel.LibraryPanelStaging(
                isPanelOpen: { rt in LibraryAccessor.isLibraryPanelOpen(runtime: rt) },
                openPanel: { rt in await AccessibilityChannel.openLibraryPanelViaKeyCommand(runtime: rt) },
                resolvePathKind: { path in
                    if let panelRoot = panelScanSnapshot,
                       let panelResolution = LibraryAccessor.resolvePath(path, in: panelRoot),
                       panelResolution.exists {
                        if let diskRoot = diskScanSnapshot,
                           let diskResolution = LibraryAccessor.resolvePath(path, in: diskRoot),
                           diskResolution.exists,
                           diskResolution.kind != .leaf {
                            return diskResolution.kind
                        }
                        return panelResolution.kind
                    }
                    if let diskRoot = diskScanSnapshot,
                       let diskResolution = LibraryAccessor.resolvePath(path, in: diskRoot),
                       diskResolution.exists {
                        return diskResolution.kind
                    }
                    return nil
                },
                resolvePath: { path in
                    if let root = panelScanSnapshot,
                       let resolution = LibraryAccessor.resolvePath(path, in: root) {
                        return resolution.exists
                    }
                    if let root = diskScanSnapshot,
                       let resolution = LibraryAccessor.resolvePath(path, in: root) {
                        return resolution.exists
                    }
                    return nil   // no cache → undecided, attempt nav
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
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
        }

        // Precondition: only start the scan if the Library panel is actually open.
        // This is a < 100 ms AX check and avoids descending into a multi-second
        // probe chain that has no Library to walk. Run FIRST so we bail before
        // any expensive setup (probe construction, snapshot extraction).
        guard LibraryAccessor.isLibraryPanelOpen(runtime: runtime) else {
            Log.info("scan_all: preflight failed in \(Int(Date().timeIntervalSince(t0) * 1000))ms — panel closed", subsystem: "ax")
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
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
            return .error("Library panel not found. Open Library (Y) in Logic Pro.")
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
        default:
            break
        }
    }

    // MARK: - v3.0.5 disk-backed scan

    /// v3.0.5 — filesystem-backed `library.scan_all`. Enumerates the user
    /// Logic Library and Logic Pro app-bundle Instrument patch roots, dedupes
    /// relative `.patch` paths, and produces a schema-identical `LibraryRoot`
    /// to the AX scan, but with full depth. Falls back to the legacy AX scan if
    /// no configured bundle can be scanned. Populates `lastScan` so
    /// `library.resolve_path` works against the disk tree.
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

    static func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
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
