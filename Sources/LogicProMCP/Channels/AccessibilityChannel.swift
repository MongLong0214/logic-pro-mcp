import ApplicationServices
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility
    private let runtime: Runtime

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
        let selectTrack: @Sendable ([String: String]) -> ChannelResult
        let setTrackToggle: @Sendable ([String: String], String) -> ChannelResult
        let renameTrack: @Sendable ([String: String]) -> ChannelResult
        let mixerState: @Sendable () -> ChannelResult
        let channelStrip: @Sendable ([String: String]) -> ChannelResult
        let setMixerValue: @Sendable ([String: String], MixerTarget) -> ChannelResult
        let projectInfo: @Sendable () -> ChannelResult

        static func axBacked(
            isTrusted: @escaping @Sendable () -> Bool = AXIsProcessTrusted,
            isLogicProRunning: @escaping @Sendable () -> Bool = { ProcessUtils.isLogicProRunning },
            logicRuntime: AXLogicProElements.Runtime = .production
        ) -> Runtime {
            Runtime(
                isTrusted: isTrusted,
                isLogicProRunning: isLogicProRunning,
                appRoot: { AXLogicProElements.appRoot(runtime: logicRuntime) },
                transportState: { AccessibilityChannel.defaultGetTransportState(runtime: logicRuntime) },
                toggleTransportButton: { AccessibilityChannel.defaultToggleTransportButton(named: $0, runtime: logicRuntime) },
                setTempo: { AccessibilityChannel.defaultSetTempo(params: $0, runtime: logicRuntime) },
                setCycleRange: AccessibilityChannel.defaultSetCycleRange,
                tracks: { AccessibilityChannel.defaultGetTracks(runtime: logicRuntime) },
                selectedTrack: { AccessibilityChannel.defaultGetSelectedTrack(runtime: logicRuntime) },
                selectTrack: { AccessibilityChannel.defaultSelectTrack(params: $0, runtime: logicRuntime) },
                setTrackToggle: { AccessibilityChannel.defaultSetTrackToggle(params: $0, button: $1, runtime: logicRuntime) },
                renameTrack: { AccessibilityChannel.defaultRenameTrack(params: $0, runtime: logicRuntime) },
                mixerState: { AccessibilityChannel.defaultGetMixerState(runtime: logicRuntime) },
                channelStrip: { AccessibilityChannel.defaultGetChannelStrip(params: $0, runtime: logicRuntime) },
                setMixerValue: { AccessibilityChannel.defaultSetMixerValue(params: $0, target: $1, runtime: logicRuntime) },
                projectInfo: { AccessibilityChannel.defaultGetProjectInfo(runtime: logicRuntime) }
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
        case "transport.set_tempo":
            return runtime.setTempo(params)
        case "transport.set_cycle_range":
            return runtime.setCycleRange(params)

        // MARK: - Track reads
        case "track.get_tracks":
            return runtime.tracks()
        case "track.get_selected":
            return runtime.selectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return runtime.selectTrack(params)
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

        // MARK: - Project save_as via AX dialog
        case "project.save_as":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.save_as")
            }
            return await AccessibilityChannel.saveAsViaAXDialog(path: path)

        // MARK: - Track creation via menu click
        case "track.create_instrument":
            return AccessibilityChannel.clickTrackMenu("새로운 소프트웨어 악기 트랙")
        case "track.create_audio":
            return AccessibilityChannel.clickTrackMenu("새로운 오디오 트랙")
        case "track.create_drummer":
            return AccessibilityChannel.clickTrackMenu("새로운 Drummer 트랙")
        case "track.create_external_midi":
            return AccessibilityChannel.clickTrackMenu("새로운 외부 MIDI 트랙")

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

        // MARK: - Navigation
        case "nav.get_markers":
            return .error("Marker reading not yet implemented via AX")
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return runtime.projectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

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
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let tempoStr = params["tempo"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar(runtime: runtime) else {
            return .error("Cannot locate transport bar")
        }
        // Find the tempo text field and set its value
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
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }
        return .error("Cannot locate tempo field")
    }

    private static func defaultSetCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private static func defaultGetTracks(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
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
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index, runtime: runtime) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to select track \(index)")
        }
        return .success("{\"selected\":\(index)}")
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
        guard AXHelpers.performAction(button, kAXPressAction, runtime: runtime.ax) else {
            return .error("Failed to click \(buttonName) on track \(index)")
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(buttonName)\"}")
    }

    private static func defaultRenameTrack(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index, runtime: runtime) else {
            return .error("Cannot find name field for track \(index)")
        }
        // Double-click to enter edit mode, then set value
        AXHelpers.performAction(field, kAXPressAction, runtime: runtime.ax)
        AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef, runtime: runtime.ax)
        AXHelpers.performAction(field, kAXConfirmAction, runtime: runtime.ax)
        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    // MARK: - Save As via AX Dialog

    private static func saveAsViaAXDialog(
        path: String,
        runtime: AXLogicProElements.Runtime = .production
    ) async -> ChannelResult {
        // Step 1: Trigger Save As via menu click (more reliable than CGEvent)
        let menuResult = clickTrackMenu("다른 이름으로 저장…", menuName: "파일", runtime: runtime)
        // Fallback to English
        let triggered: Bool
        switch menuResult {
        case .success:
            triggered = true
        case .error:
            // Try English menu
            let englishResult = clickMenuItem("Save As…", menuName: "File", runtime: runtime)
            triggered = englishResult.isSuccess
        }

        guard triggered else {
            return .error("Failed to open Save As dialog via menu")
        }

        // Step 2: Wait for save dialog sheet to appear (up to 3s)
        var sheet: AXUIElement?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            guard let window = AXLogicProElements.mainWindow(runtime: runtime) else { continue }
            // Look for a sheet (NSSavePanel appears as a sheet)
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

        // Step 3: Find filename text field and set value
        let filename = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: ".logicx", with: "")
        let textFields = AXHelpers.findAllDescendants(of: saveSheet, role: "AXTextField", runtime: runtime.ax)

        guard let filenameField = textFields.first else {
            return .error("Cannot find filename field in Save As dialog")
        }

        // Set filename
        AXHelpers.setAttribute(filenameField, kAXValueAttribute, filename as CFTypeRef, runtime: runtime.ax)
        // Focus and select all to replace
        AXHelpers.performAction(filenameField, kAXConfirmAction, runtime: runtime.ax)

        // Step 4: Set save location via path components
        // For now, navigate to the directory by using the Go To Folder approach
        // or set the full path in the filename field
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        // Use the combined path approach: set full path in the text field
        AXHelpers.setAttribute(filenameField, kAXValueAttribute, path as CFTypeRef, runtime: runtime.ax)

        // Step 5: Find and click Save button
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
            return .error("Cannot find Save button in Save As dialog")
        }

        // Step 6: Verify file exists (up to 5s)
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

    private static func defaultSetMixerValue(
        params: [String: String],
        target: MixerTarget,
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'index' or 'value' parameter")
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
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
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
