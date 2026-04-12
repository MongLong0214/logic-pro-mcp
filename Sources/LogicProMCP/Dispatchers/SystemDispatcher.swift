import Foundation
import MCP

struct SystemDispatcher {
    private struct HealthResponse: Encodable {
        struct MCUSection: Encodable {
            let connected: Bool
            let registeredAsDevice: Bool
            let lastFeedbackAt: Date?
            let feedbackStale: Bool
            let portName: String

            enum CodingKeys: String, CodingKey {
                case connected
                case registeredAsDevice = "registered_as_device"
                case lastFeedbackAt = "last_feedback_at"
                case feedbackStale = "feedback_stale"
                case portName = "port_name"
            }
        }

        struct ChannelSection: Encodable {
            let channel: String
            let available: Bool
            let ready: Bool
            let latencyMs: Double?
            let detail: String
            let verificationStatus: String

            enum CodingKeys: String, CodingKey {
                case channel
                case available
                case ready
                case latencyMs = "latency_ms"
                case detail
                case verificationStatus = "verification_status"
            }
        }

        struct CacheSection: Encodable {
            let pollMode: String
            let transportAgeSec: Double
            let trackCount: Int
            let project: String

            enum CodingKeys: String, CodingKey {
                case pollMode = "poll_mode"
                case transportAgeSec = "transport_age_sec"
                case trackCount = "track_count"
                case project
            }
        }

        struct PermissionsSection: Encodable {
            let accessibility: Bool
            let automation: Bool
            let automationGranted: Bool?
            let accessibilityStatus: String
            let automationStatus: String
            let automationVerifiable: Bool

            enum CodingKeys: String, CodingKey {
                case accessibility
                case automation
                case automationGranted = "automation_granted"
                case accessibilityStatus = "accessibility_status"
                case automationStatus = "automation_status"
                case automationVerifiable = "automation_verifiable"
            }
        }

        struct ProcessSection: Encodable {
            let memoryMb: Double
            let cpuPercent: Double
            let uptimeSec: Int

            enum CodingKeys: String, CodingKey {
                case memoryMb = "memory_mb"
                case cpuPercent = "cpu_percent"
                case uptimeSec = "uptime_sec"
            }
        }

        let logicProRunning: Bool
        let logicProHasWindow: Bool
        let logicProHasDocument: Bool
        let logicProVersion: String
        let mcu: MCUSection
        let channels: [ChannelSection]
        let cache: CacheSection
        let permissions: PermissionsSection
        let process: ProcessSection

        enum CodingKeys: String, CodingKey {
            case logicProRunning = "logic_pro_running"
            case logicProHasWindow = "logic_pro_has_window"
            case logicProHasDocument = "logic_pro_has_document"
            case logicProVersion = "logic_pro_version"
            case mcu
            case channels
            case cache
            case permissions
            case process
        }
    }

    static let tool = Tool(
        name: "logic_system",
        description: """
            Diagnostics and help for the Logic Pro MCP server. \
            Commands: health, permissions, refresh_cache, help. \
            Params by command: \
            help -> { category: String } (returns full param docs for a dispatcher); \
            refresh_cache -> {} (force AX re-poll); \
            Others -> {}
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("System command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache,
        poller: StatePoller? = nil
    ) async -> CallTool.Result {
        switch command {
        case "health":
            let report = await router.healthReport()
            var entries: [HealthResponse.ChannelSection] = []
            for (id, health) in report.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                entries.append(
                    .init(
                        channel: id.rawValue,
                        available: health.available,
                        ready: health.ready,
                        latencyMs: health.latencyMs.map { Double(String(format: "%.1f", $0)) ?? $0 },
                        detail: health.detail,
                        verificationStatus: health.verificationStatus.rawValue
                    )
                )
            }
            let snap = await cache.snapshot()
            let mcu = await cache.getMCUConnection()
            let permissions = PermissionChecker.check()
            let process = ProcessUtils.currentProcessMetrics()
            let lastFeedbackAge = mcu.lastFeedbackAt.map { Date().timeIntervalSince($0) }
            let logicProPID = ProcessUtils.logicProPID()
            let logicProRunning = logicProPID != nil || (report[.appleScript]?.available ?? false)
            let logicProHasWindow = ProcessUtils.hasVisibleWindow()
            let logicProHasDocument = await cache.getHasDocument()
            let health = HealthResponse(
                logicProRunning: logicProRunning,
                logicProHasWindow: logicProHasWindow,
                logicProHasDocument: logicProHasDocument,
                logicProVersion: ProcessUtils.logicProVersion() ?? "unknown",
                mcu: .init(
                    connected: mcu.isConnected,
                    registeredAsDevice: mcu.registeredAsDevice,
                    lastFeedbackAt: mcu.lastFeedbackAt,
                    feedbackStale: mcu.isConnected && (lastFeedbackAge ?? .infinity) > 5.0,
                    portName: mcu.portName
                ),
                channels: entries,
                cache: .init(
                    pollMode: snap.pollMode,
                    transportAgeSec: Double(String(format: "%.1f", snap.transportAge)) ?? snap.transportAge,
                    trackCount: snap.trackCount,
                    project: snap.projectName
                ),
                permissions: .init(
                    accessibility: permissions.accessibility,
                    automation: permissions.automationLogicPro,
                    automationGranted: permissions.automationVerifiable ? permissions.automationLogicPro : nil,
                    accessibilityStatus: permissions.accessibilityState.rawValue,
                    automationStatus: permissions.automationState.rawValue,
                    automationVerifiable: permissions.automationVerifiable
                ),
                process: .init(
                    memoryMb: Double(String(format: "%.1f", process.memoryMB)) ?? process.memoryMB,
                    cpuPercent: Double(String(format: "%.1f", process.cpuPercent)) ?? process.cpuPercent,
                    uptimeSec: process.uptimeSec
                )
            )
            let json = encodeJSON(health)
            return toolTextResult(json)

        case "permissions":
            let status = PermissionChecker.check()
            return toolTextResult(status.summary)

        case "refresh_cache":
            await cache.recordToolAccess()
            if let poller {
                await poller.refreshNow()
                return toolTextResult("State refresh completed via AX fallback poller.")
            }
            return toolTextResult("State refresh triggered. Cache will be updated on next poll cycle.")

        case "help":
            let category = params["category"]?.stringValue ?? "all"
            let helpText = Self.helpText(for: category)
            return toolTextResult(helpText)

        default:
            return toolTextResult(
                "Unknown system command: \(command). Available: health, permissions, refresh_cache, help",
                isError: true
            )
        }
    }

    // MARK: - Help text

    private static func helpText(for category: String) -> String {
        switch category {
        case "transport":
            return """
                logic_transport commands:
                  play              -> {} — Start playback
                  stop              -> {} — Stop playback
                  record            -> {} — Start recording
                  pause             -> {} — Pause playback
                  rewind            -> {} — Rewind
                  fast_forward      -> {} — Fast forward
                  toggle_cycle      -> {} — Toggle cycle/loop mode
                  toggle_metronome  -> {} — Toggle metronome
                  toggle_count_in   -> {} — Toggle count-in
                  set_tempo         -> { tempo: Float } — Set BPM (20-999)
                  goto_position     -> { bar: Int } or { time: "HH:MM:SS:FF" }
                  set_cycle_range   -> { start: Int, end: Int } — Bar numbers

                Read state via resource: logic://transport/state
                """

        case "tracks":
            return """
                logic_tracks commands:
                  select            -> { index: Int } or { name: String }
                  create_audio      -> {} — New audio track
                  create_instrument -> {} — New software instrument track
                  create_drummer    -> {} — New Drummer track
                  create_external_midi -> {} — New external MIDI track
                  delete            -> { index: Int }
                  duplicate         -> { index: Int }
                  rename            -> { index: Int, name: String }
                  mute              -> { index: Int, enabled: Bool }
                  solo              -> { index: Int, enabled: Bool }
                  arm               -> { index: Int, enabled: Bool }
                  set_automation    -> { index: Int, mode: String } (read/write/touch/latch/trim)

                Read state via resources: logic://tracks, logic://tracks/{index}
                """

        case "mixer":
            return """
                logic_mixer commands:
                  set_volume        -> { track: Int, value: Float } (0.0-1.0)
                  set_pan           -> { track: Int, value: Float } (-1.0 to 1.0)
                  set_master_volume -> { value: Float }
                  insert_plugin     -> { track: Int, slot: Int, name: String }
                  bypass_plugin     -> { track: Int, slot: Int, bypassed: Bool }
                  set_plugin_param  -> { track: Int, insert: 0, param: Int, value: Float } — selected track via Scripter

                Read state via resource: logic://mixer
                """

        case "midi":
            return """
                logic_midi commands:
                  send_note         -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }
                  send_chord        -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }
                  send_cc           -> { controller: Int, value: Int, channel: Int }
                  send_program_change -> { program: Int, channel: Int }
                  send_pitch_bend   -> { value: Int, channel: Int } (-8192 to 8191)
                  send_aftertouch   -> { value: Int, channel: Int }
                  send_sysex        -> { bytes: [Int] } or { data: String }
                  create_virtual_port -> { name: String }
                  step_input        -> { note: Int, duration: String|Int }
                  mmc_play          -> {}
                  mmc_stop          -> {}
                  mmc_record        -> {}
                  mmc_locate        -> { bar: Int } or { time: "HH:MM:SS:FF" }

                Read ports via resource: logic://midi/ports
                """

        case "edit":
            return """
                logic_edit commands:
                  undo              -> {} — Undo last action
                  redo              -> {} — Redo last undone action
                  cut               -> {} — Cut selection
                  copy              -> {} — Copy selection
                  paste             -> {} — Paste at playhead
                  delete            -> {} — Delete selection
                  select_all        -> {} — Select all
                  split             -> {} — Split at playhead
                  join              -> {} — Join selected regions
                  quantize          -> { value: String } ("1/4", "1/8", "1/16")
                  bounce_in_place   -> {} — Bounce selection to audio
                  normalize         -> {} — Normalize audio
                  duplicate         -> {} — Duplicate selection
                  toggle_step_input -> {} — Toggle Step Input Keyboard
                """

        case "navigate":
            return """
                logic_navigate commands:
                  goto_bar          -> { bar: Int }
                  goto_marker       -> { index: Int } or { name: String }
                  create_marker     -> { name: String }
                  delete_marker     -> { index: Int }
                  rename_marker     -> { index: Int, name: String }
                  zoom_to_fit       -> {}
                  set_zoom          -> { level: String } ("in", "out", "fit")
                  toggle_view       -> { view: String } (mixer, piano_roll, score,
                                       step_editor, library, inspector, automation)
                """

        case "project":
            return """
                logic_project commands:
                  new               -> {} — Create new project
                  open              -> { path: String } — Open .logicx file
                  save              -> {} — Save current project
                  save_as           -> { path: String } — Save to new path
                  close             -> {} — Close project
                  bounce            -> {} — Open bounce dialog
                  launch            -> {} — Launch Logic Pro
                  quit              -> {} — Quit Logic Pro

                Read project info via resource: logic://project/info
                """

        case "system":
            return """
                logic_system commands:
                  health            -> {} — Channel status + cache info
                  permissions       -> {} — macOS permission status
                  refresh_cache     -> {} — Force AX re-poll
                  help              -> { category: String } — Param docs per category

                Categories: transport, tracks, mixer, midi, edit, navigate, project, system

                Read health via resource: logic://system/health

                Manual channel approval CLI:
                  LogicProMCP --approve-channel MIDIKeyCommands
                  LogicProMCP --approve-channel Scripter
                  LogicProMCP --list-approvals
                  LogicProMCP --revoke-channel <channel>
                """

        default:
            return """
                Logic Pro MCP — 8 dispatcher tools + 6 resources + 1 template

                Tools (actions):
                  logic_transport  — Transport control (play, stop, record, tempo...)
                  logic_tracks     — Track management (create, mute, solo, arm...)
                  logic_mixer      — Mixer control (volume, pan, plugins...)
                  logic_midi       — MIDI operations (notes, CC, MMC...)
                  logic_edit       — Editing (undo, cut, quantize...)
                  logic_navigate   — Navigation + views (markers, zoom, toggle views...)
                  logic_project    — Project lifecycle (open, save, bounce...)
                  logic_system     — Diagnostics + help

                Resources (reads — zero tool cost):
                  logic://transport/state  — Transport state
                  logic://tracks           — All tracks
                  logic://mixer            — Mixer state
                  logic://project/info     — Project info
                  logic://midi/ports       — MIDI ports
                  logic://system/health    — System health

                Resource templates:
                  logic://tracks/{index}   — Single track detail

                Use: logic_system(command: "help", params: {category: "transport"})
                for detailed command docs per category.
                """
        }
    }
}
