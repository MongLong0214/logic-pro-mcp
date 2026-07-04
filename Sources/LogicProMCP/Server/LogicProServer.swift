import CoreMIDI
import Foundation
import MCP

private func emitMIDIPacket(to source: MIDIEndpointRef, bytes: [UInt8]) {
    let bufferSize = max(MemoryLayout<MIDIPacketList>.size, MemoryLayout<MIDIPacketList>.size + bytes.count)
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    buffer.withUnsafeMutableBytes { rawBuf in
        let packetList = rawBuf.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
        var pkt = MIDIPacketListInit(packetList)
        bytes.withUnsafeBufferPointer { dataBuf in
            guard let base = dataBuf.baseAddress else { return }
            pkt = MIDIPacketListAdd(packetList, bufferSize, pkt, 0, bytes.count, base)
        }
        MIDIReceived(source, packetList)
    }
}

struct ServerCompositionSnapshot: Sendable, Equatable {
    let channelIDs: [ChannelID]
    let toolNames: [String]
    let resourceURIs: [String]
    let templateURIs: [String]
    let startupBanner: String
}

enum ServerCatalog {
    static let tools: [Tool] = [
        TransportDispatcher.tool,
        TrackDispatcher.tool,
        MixerDispatcher.tool,
        MIDIDispatcher.tool,
        EditDispatcher.tool,
        NavigateDispatcher.tool,
        ProjectDispatcher.tool,
        AudioDispatcher.tool,
        SystemDispatcher.tool,
        PluginsDispatcher.tool,
    ]

    /// O(1) membership set for the registered tool names — used by the
    /// protocol-boundary validation to reject an unknown `tools/call` name.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    static func startupBanner(channelCount: Int) -> String {
        "Starting \(ServerConfig.serverName) v\(ServerConfig.serverVersion) — \(tools.count) tools, \(ResourceProvider.resources.count) resources, \(channelCount) channels"
    }

    static func snapshot(channelIDs: [ChannelID]) -> ServerCompositionSnapshot {
        ServerCompositionSnapshot(
            channelIDs: channelIDs,
            toolNames: tools.map(\.name),
            resourceURIs: ResourceProvider.resources.map(\.uri),
            templateURIs: ResourceProvider.templates.map(\.uriTemplate),
            startupBanner: startupBanner(channelCount: channelIDs.count)
        )
    }
}

struct LogicProServerHandlers: Sendable {
    let listTools: @Sendable (ListTools.Parameters) async -> ListTools.Result
    let callTool: @Sendable (CallTool.Parameters) async -> CallTool.Result
    let listResources: @Sendable (ListResources.Parameters) async -> ListResources.Result
    let readResource: @Sendable (ReadResource.Parameters) async throws -> ReadResource.Result
    let listResourceTemplates: @Sendable (ListResourceTemplates.Parameters) async -> ListResourceTemplates.Result
}

struct LogicProServerRuntimeOverrides: @unchecked Sendable {
    var cleanupStartupArtifacts: (@Sendable () -> Void)?
    var startPorts: (@Sendable () async throws -> Void)?
    var registerChannels: (@Sendable () async -> Void)?
    var startChannels: (@Sendable () async -> ChannelRouter.StartReport)?
    var startPoller: (@Sendable () async -> Void)?
    var registerHandlers: (@Sendable () async -> Void)?
    var serve: (@Sendable () async throws -> Void)?
    var stopPoller: (@Sendable () async -> Void)?
    var stopChannels: (@Sendable () async -> Void)?
    var stopPorts: (@Sendable () async -> Void)?
}

/// Internal lifecycle plan executed serially by the server startup path.
/// The stored closures may capture actor references, so we keep the plan local
/// and run it immediately rather than sharing it across concurrent contexts.
struct ServerRuntimePlan: @unchecked Sendable {
    let startPorts: () async throws -> Void
    let registerChannels: () async -> Void
    let startChannels: () async -> ChannelRouter.StartReport
    let startPoller: () async -> Void
    let registerHandlers: () async -> Void
    let serve: () async throws -> Void
    let stopPoller: () async -> Void
    let stopChannels: () async -> Void
    let stopPorts: () async -> Void
    let startupError: ([ChannelID: String]) -> Error

    func run() async throws {
        try await startPorts()
        await registerChannels()

        let startReport = await startChannels()
        if startReport.hasDegraded {
            let summary = startReport.degraded
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue): \($0.value)" }
                .joined(separator: "; ")
            Log.warn("Starting in degraded mode — \(summary)", subsystem: "server")
        }
        if startReport.hasFailures {
            await stopChannels()
            await stopPorts()
            throw startupError(startReport.failures)
        }

        await startPoller()

        do {
            await registerHandlers()
            try await serve()
        } catch {
            await stopPoller()
            await stopChannels()
            await stopPorts()
            throw error
        }

        await stopPoller()
        await stopChannels()
        await stopPorts()
    }
}

final class LogicMutationGate: @unchecked Sendable {
    /// Opaque claim returned by `tryAcquire` and required by `release`. The
    /// `epoch` makes release idempotent and reclaim-safe: a holder that was
    /// reclaimed for staleness cannot release a successor that happens to share
    /// the same operation name.
    struct Claim: Equatable, Sendable {
        fileprivate let epoch: UInt64
        let operation: String
    }

    private let lock = NSLock()
    private var activeOperation: String?
    private var acquiredAt: Date?
    /// Set when the command deadline abandons the current holder (#201). A
    /// timed-out holder is reclaimable after the much shorter `timedOutReclaimGrace`
    /// rather than the blanket `staleHolderTTL`, so one hung transport/track op
    /// cannot pin the entire write surface for minutes.
    private var timedOutAt: Date?
    private var epoch: UInt64 = 0

    /// Staleness safety valve. The #112 deadline frees the stdio loop on a hang,
    /// but the gate is released only when the (possibly wedged) detached work
    /// finally returns. If a mutating op's work never returns — every per-call
    /// timeout (AX messaging 2.5s, `BoundedProcessRunner`) bounds this in
    /// practice, but a future unbounded path could not — the gate would stay
    /// held forever and lock out every mutation server-wide. A holder older than
    /// this TTL is reclaimed so the server always recovers. Set far above the
    /// longest command deadline so a healthy long-running op never trips it.
    private let staleHolderTTL: TimeInterval

    /// #201: once the command deadline has ABANDONED a mutating op, the server
    /// already gave up on it — holding the gate for the full `staleHolderTTL`
    /// (minutes) needlessly locks out every other mutation. After the deadline
    /// marks the holder timed-out, the gate is reclaimable after this short
    /// grace, set comfortably above the worst-case single blocked AX call
    /// (≈2.5s) so the abandoned work has unwound before a successor proceeds.
    private let timedOutReclaimGrace: TimeInterval

    init(staleHolderTTL: TimeInterval = 360, timedOutReclaimGrace: TimeInterval = 15) {
        self.staleHolderTTL = staleHolderTTL
        self.timedOutReclaimGrace = timedOutReclaimGrace
    }

    func tryAcquire(operation: String, now: Date = Date()) -> Claim? {
        lock.lock()
        defer { lock.unlock() }
        if let active = activeOperation, let since = acquiredAt {
            if let timedOutAt, now.timeIntervalSince(timedOutAt) >= timedOutReclaimGrace {
                Log.warn(
                    "Reclaiming timed-out mutation gate from \(active) (grace \(Int(timedOutReclaimGrace))s elapsed) — prior op was abandoned by the command deadline",
                    subsystem: "server"
                )
            } else if now.timeIntervalSince(since) >= staleHolderTTL {
                Log.warn(
                    "Reclaiming stale mutation gate from \(active) held \(Int(now.timeIntervalSince(since)))s (TTL \(Int(staleHolderTTL))s) — prior op may still be wedged",
                    subsystem: "server"
                )
            } else {
                return nil
            }
        }
        epoch &+= 1
        activeOperation = operation
        acquiredAt = now
        timedOutAt = nil
        return Claim(epoch: epoch, operation: operation)
    }

    /// Mark the current holder (if `claim` still owns the gate) as abandoned by
    /// the command deadline, starting the short `timedOutReclaimGrace` window.
    /// Epoch-guarded so a late mark from an abandoned op cannot affect a
    /// successor that already reclaimed the gate.
    func markTimedOut(_ claim: Claim, now: Date = Date()) {
        lock.lock()
        if epoch == claim.epoch {
            timedOutAt = now
        }
        lock.unlock()
    }

    func release(_ claim: Claim) {
        lock.lock()
        if epoch == claim.epoch {
            activeOperation = nil
            acquiredAt = nil
            timedOutAt = nil
        }
        lock.unlock()
    }

    func currentOperation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeOperation
    }
}

/// Main MCP server for Logic Pro integration.
/// Exposes 10 dispatcher tools + 18 resources + 11 templates, routing through
/// the ChannelRouter to the appropriate macOS communication channel.
actor LogicProServer {
    private let server: Server
    private let router: ChannelRouter
    private let cache: StateCache
    private let poller: StatePoller
    private let portManager: MIDIPortManager
    private let manualValidationStore: ManualValidationStore

    // Channel instances (7 channels — PRD §4.1)
    private let coreMIDIChannel: CoreMIDIChannel
    private let mcuChannel: MCUChannel
    private let keyCommandsChannel: MIDIKeyCommandsChannel
    private let scripterChannel: ScripterChannel
    private let axChannel: AccessibilityChannel
    private let cgEventChannel: CGEventChannel
    private let appleScriptChannel: AppleScriptChannel
    private let runtimeOverrides: LogicProServerRuntimeOverrides?
    /// #201: after the command deadline abandons a mutating op, the gate is
    /// reclaimable this many seconds later so one hung op cannot pin the whole
    /// write surface for the full stale-holder TTL. Single source of truth for
    /// the gate's grace and the timeout envelope's `gate_reclaim_after_sec`.
    static let mutationGateReclaimGraceSeconds: Double = 15
    private let mutationGate = LogicMutationGate(timedOutReclaimGrace: LogicProServer.mutationGateReclaimGraceSeconds)

    init(
        runtimeOverrides: LogicProServerRuntimeOverrides? = nil,
        pollerRuntime: StatePoller.Runtime = .production
    ) {
        self.runtimeOverrides = runtimeOverrides
        self.server = Server(
            name: ServerConfig.serverName,
            version: ServerConfig.serverVersion,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        self.router = ChannelRouter()
        self.cache = StateCache()
        self.portManager = MIDIPortManager()
        self.manualValidationStore = ManualValidationStore()

        // Legacy channels
        let midiEngine = MIDIEngine()
        self.coreMIDIChannel = CoreMIDIChannel(engine: midiEngine, portManager: portManager)
        self.axChannel = AccessibilityChannel()
        self.cgEventChannel = CGEventChannel()
        self.appleScriptChannel = AppleScriptChannel()

        // New v2 channels (MCU, KeyCommands, Scripter)
        // These use MockMCUTransport at init — replaced with real transport in start()
        // For production, we create a real CoreMIDI-backed transport in start()
        let mcuTransport = ProductionMCUTransport(portManager: portManager)
        let mcuAXReadback = MCUChannel.AXReadback(
            readVolume: { track in
                guard let fader = AXLogicProElements.findFader(trackIndex: track) else { return nil }
                return AXValueExtractors.extractLogicMixerFaderValue(fader)
            },
            readPan: { track in
                guard let pan = AXLogicProElements.findPanKnob(trackIndex: track) else { return nil }
                return AXValueExtractors.extractCenteredSliderValue(pan)
            }
        )
        self.mcuChannel = MCUChannel(transport: mcuTransport, cache: cache, axReadback: mcuAXReadback)

        let keyCmdTransport = ProductionKeyCmdTransport(portManager: portManager)
        self.keyCommandsChannel = MIDIKeyCommandsChannel(
            transport: keyCmdTransport,
            approvalStore: manualValidationStore
        )

        let scripterTransport = ProductionKeyCmdTransport(portManager: portManager, portName: "LogicProMCP-Scripter-Internal")
        self.scripterChannel = ScripterChannel(
            transport: scripterTransport,
            approvalStore: manualValidationStore
        )

        self.poller = StatePoller(axChannel: axChannel, cache: cache, runtime: pollerRuntime)
    }

    enum StartupError: Error, CustomStringConvertible {
        case channelStartupFailed([ChannelID: String])

        var description: String {
            switch self {
            case .channelStartupFailed(let failures):
                let summary = failures
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue): \($0.value)" }
                    .joined(separator: "; ")
                return "Channel startup failed — \(summary)"
            }
        }
    }

    // MARK: - Tool Registration (10 dispatchers)

    func makeHandlers(dialogPresent: @escaping @Sendable () -> Bool = { false }) -> LogicProServerHandlers {
        let router = self.router
        let cache = self.cache
        let poller = self.poller
        let mutationGate = self.mutationGate

        return LogicProServerHandlers(
            listTools: { _ in
                ListTools.Result(tools: ServerCatalog.tools)
            },
            callTool: { params in
                let name = params.name
                let command = params.arguments?["command"]?.stringValue ?? ""
                let cmdParams: [String: Value] = params.arguments?["params"]?.objectValue ?? [:]

                await cache.recordToolAccess()

                // #112: every tool dispatch runs under a server-side deadline.
                // A wedged/occluded Logic session (modal dialog up, AX server
                // unresponsive) makes multi-message AX operations block far past
                // the client's tools/call timeout, surfacing as a bare "timeout"
                // and — worse — stalling the stdio read loop so every subsequent
                // command also hangs. The deadline converts that into a typed
                // `operation_timeout` State C and frees the loop. Deadlines are
                // set well above each command's healthy completion time, so a
                // normal op can never false-trip (verified across the full live
                // surface); only a genuine hang is bounded.
                return await Self.runWithDeadline(tool: name, command: command, mutationGate: mutationGate) {
                    switch name {
                    case "logic_transport":
                        return await TransportDispatcher.handle(
                            command: command,
                            params: cmdParams,
                            router: router,
                            cache: cache,
                            dialogPresent: dialogPresent
                        )
                    case "logic_tracks":
                        return await TrackDispatcher.handle(
                            command: command,
                            params: cmdParams,
                            router: router,
                            cache: cache,
                            dialogPresent: dialogPresent
                        )
                    case "logic_mixer":
                        return await MixerDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                    case "logic_midi":
                        return await MIDIDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                    case "logic_edit":
                        return await EditDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                    case "logic_navigate":
                        return await NavigateDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                    case "logic_project":
                        return await ProjectDispatcher.handle(
                            command: command,
                            params: cmdParams,
                            router: router,
                            cache: cache,
                            dialogPresent: dialogPresent
                        )
                    case "logic_audio":
                        return AudioDispatcher.handle(command: command, params: cmdParams)
                    case "logic_system":
                        return await SystemDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache, poller: poller)
                    case "logic_plugins":
                        return await PluginsDispatcher.handle(command: command, params: cmdParams, router: router, cache: cache)
                    default:
                        return toolTextResult("Unknown tool: \(name)", isError: true)
                    }
                }
            },
            listResources: { _ in
                // #215: always advertise the full static catalog so discovery
                // matches the documented "18 static resources" and the URIs
                // that are directly readable. `logic://mcu/state` stays listed
                // even when the MCU surface is offline — a direct read returns
                // a meaningful `{ connected: false, … }` payload, so hiding it
                // from the list while it remained readable was the discrepancy.
                ListResources.Result(
                    resources: ResourceProvider.resources,
                    nextCursor: nil
                )
            },
            readResource: { params in
                // #199: bound every resource read with the same liveness backstop
                // as tool calls. A live-route-backed read on a wedged Logic
                // session must return a typed operation_timeout body, never leave
                // the client with no JSON-RPC response.
                try await Self.runResourceReadWithDeadline(uri: params.uri) {
                    try await ResourceHandlers.read(uri: params.uri, cache: cache, router: router)
                }
            },
            listResourceTemplates: { _ in
                ListResourceTemplates.Result(
                    templates: ResourceProvider.templates
                )
            }
        )
    }

    // MARK: - #112 command deadline (stdio-loop liveness backstop)

    /// Commands that legitimately take many seconds against live AX: full
    /// Library / preset tree walks, SMF import, and the guarded bounce/export
    /// state machines. They get a much longer deadline so the backstop never
    /// false-trips them, while still bounding a genuine hang.
    private static let longRunningCommands: Set<String> = [
        "scan_library", "scan_plugin_presets", "list_library", "record_sequence",
        "import_file", "bounce", "export_run", "export_resume", "open", "save_as",
    ]

    /// Medium-cost commands that drive multi-step AX menu/library navigation.
    private static let mediumRunningCommands: Set<String> = [
        "set_instrument", "insert_verified", "set_param_verified",
        "cleanup_apply", "new", "save", "close", "quit", "play_sequence",
    ]

    /// Per-command server-side deadline in seconds. Set far above each
    /// command's healthy completion time (sub-second for the fast tier) so a
    /// normal op can never false-trip; only a wedged/occluded Logic session
    /// that would otherwise hang the stdio loop is bounded.
    static func commandDeadlineSeconds(tool: String, command: String) -> Double {
        if longRunningCommands.contains(command) { return 300 }
        if mediumRunningCommands.contains(command) { return 90 }
        return 25
    }

    static func deadlineTimeoutResult(
        tool: String,
        command: String,
        seconds: Double,
        mutationMayStillBeRunning: Bool = false
    ) -> CallTool.Result {
        let operation = operationName(tool: tool, command: command)
        var extras: [String: Any] = [
            "operation": operation,
            "timeout_sec": seconds,
            "recovery_hint": "Logic Pro may be busy, occluded, or showing a modal dialog. Dismiss any dialog and retry; check logic_system.health.",
        ]
        if mutationMayStillBeRunning {
            // #201: the abandoned op's effect is unknown, so this result is not
            // itself safe to retry — but the gate no longer pins the session
            // indefinitely. It auto-reclaims `gate_reclaim_after_sec` after this
            // timeout, so unrelated mutating commands recover on their own
            // (their `mutating_operation_in_progress` refusal is `safe_to_retry`).
            extras["safe_to_retry"] = false
            extras["underlying_operation_stopped"] = false
            extras["mutation_gate"] = "reclaimable_after_grace"
            extras["gate_reclaim_after_sec"] = Self.mutationGateReclaimGraceSeconds
        }
        let body = HonestContract.encodeStateC(
            error: .operationTimeout,
            hint: "\(operation) exceeded the \(Int(seconds))s server-side deadline and was abandoned so the stdio loop stays responsive.",
            extras: extras
        )
        return toolTextResult(body, isError: true)
    }

    static func mutationInProgressResult(
        tool: String,
        command: String,
        activeOperation: String?
    ) -> CallTool.Result {
        let operation = operationName(tool: tool, command: command)
        let body = HonestContract.encodeStateC(
            error: .mutatingOperationInProgress,
            hint: "\(operation) refused because a previous mutating Logic operation has not finished yet.",
            extras: [
                "operation": operation,
                "active_operation": activeOperation as Any? ?? NSNull(),
                // No write was attempted (the gate refused before dispatch), so
                // the caller can safely retry once the in-flight op releases the
                // gate — matching the sibling `verified_op_in_progress` and the
                // HonestContract `safe_to_retry` semantics (write_attempted:false).
                "safe_to_retry": true,
                "write_attempted": false,
            ]
        )
        return toolTextResult(body, isError: true)
    }

    /// Race the dispatch `work` against a per-command deadline. Whichever
    /// finishes first resumes the caller; on timeout we return a typed
    /// `operation_timeout` State C without waiting for non-cooperative blocking
    /// work to unwind. The orphaned synchronous AX work (if any) is left to
    /// finish and is discarded — the point is to free the stdio loop, not to
    /// pretend cooperative cancellation can interrupt a blocked system call.
    static func runWithDeadline(
        tool: String,
        command: String,
        deadlineOverride: Double? = nil,
        mutationGate: LogicMutationGate? = nil,
        work: @escaping @Sendable () async -> CallTool.Result
    ) async -> CallTool.Result {
        let deadline = deadlineOverride ?? commandDeadlineSeconds(tool: tool, command: command)
        let operation = operationName(tool: tool, command: command)
        let heldMutationGate: LogicMutationGate?
        let heldClaim: LogicMutationGate.Claim?
        if isMutatingCommand(tool: tool, command: command), let mutationGate {
            guard let claim = mutationGate.tryAcquire(operation: operation) else {
                return mutationInProgressResult(
                    tool: tool,
                    command: command,
                    activeOperation: mutationGate.currentOperation()
                )
            }
            heldMutationGate = mutationGate
            heldClaim = claim
        } else {
            heldMutationGate = nil
            heldClaim = nil
        }
        return await withCheckedContinuation { continuation in
            let race = DeadlineRace()
            let timeoutHandle = DeadlineTimeoutHandle()
            let workTask = Task.detached(priority: .userInitiated) {
                let result = await work()
                if let heldClaim { heldMutationGate?.release(heldClaim) }
                let didWin = race.resume(continuation, returning: result)
                if didWin {
                    timeoutHandle.cancel()
                }
            }
            let timeoutTask = DispatchWorkItem {
                let didWin = race.resume(
                    continuation,
                    returning: Self.deadlineTimeoutResult(
                        tool: tool,
                        command: command,
                        seconds: deadline,
                        mutationMayStillBeRunning: heldMutationGate != nil
                    )
                )
                if didWin {
                    workTask.cancel()
                    // #201: the deadline has abandoned this op. Start the gate's
                    // bounded reclaim grace so a successor mutation recovers
                    // without waiting for the (possibly wedged) work to return or
                    // for the multi-minute stale-holder TTL. Epoch-guarded: if the
                    // work later returns and releases, that wins harmlessly first.
                    if let heldMutationGate, let heldClaim {
                        heldMutationGate.markTimedOut(heldClaim)
                    }
                }
            }
            timeoutHandle.set(timeoutTask)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + deadline,
                execute: timeoutTask
            )
        }
    }

    // MARK: - #199 resource-read deadline (resources had NO backstop)

    /// Resource reads (`logic://…`) had no deadline wrapper, unlike tool calls.
    /// A read backed by a live AX route (`logic://transport/state`,
    /// `logic://tracks/{i}/regions`) on a wedged/occluded Logic session could
    /// block past the client's read timeout and leave it with NO JSON-RPC
    /// response (#199). This backstop bounds every resource read the same way
    /// the #112 deadline bounds tool calls. Set to match the fast tool tier so a
    /// healthy read (sub-second) can never false-trip; only a genuine hang trips.
    static let resourceReadDeadlineSeconds: Double = 25

    /// Typed `operation_timeout` envelope returned as the resource body when a
    /// read exceeds its deadline — a bounded JSON-RPC response the client can
    /// classify, instead of a hang with no response.
    static func resourceReadTimeoutResult(uri: String, seconds: Double) -> ReadResource.Result {
        let body = HonestContract.encodeStateC(
            error: .operationTimeout,
            hint: "Resource read \(uri) exceeded the \(Int(seconds))s server-side deadline and was abandoned so the stdio loop stays responsive.",
            extras: [
                "uri": uri,
                "timeout_sec": seconds,
                "recovery_hint": "Logic Pro may be busy, occluded, or showing a modal dialog. Dismiss any dialog and retry; check logic_system.health.",
            ]
        )
        return ReadResource.Result(contents: [.text(body, uri: uri, mimeType: "application/json")])
    }

    /// Race a throwing resource read against `resourceReadDeadlineSeconds`. A
    /// genuine read error (invalid URI, etc.) is rethrown unchanged so existing
    /// JSON-RPC error semantics are preserved; only a deadline overrun is
    /// converted into a typed `operation_timeout` resource body. Mirrors
    /// `runWithDeadline` but for the read-only `ReadResource.Result` shape, so
    /// it never touches the mutation gate.
    static func runResourceReadWithDeadline(
        uri: String,
        deadlineOverride: Double? = nil,
        work: @escaping @Sendable () async throws -> ReadResource.Result
    ) async throws -> ReadResource.Result {
        let deadline = deadlineOverride ?? resourceReadDeadlineSeconds
        return try await withCheckedThrowingContinuation { continuation in
            let race = ResourceDeadlineRace()
            let timeoutHandle = DeadlineTimeoutHandle()
            let workTask = Task.detached(priority: .userInitiated) {
                do {
                    let result = try await work()
                    if race.resume(continuation, returning: result) { timeoutHandle.cancel() }
                } catch {
                    if race.resume(continuation, throwing: error) { timeoutHandle.cancel() }
                }
            }
            let timeoutTask = DispatchWorkItem {
                let didWin = race.resume(
                    continuation,
                    returning: Self.resourceReadTimeoutResult(uri: uri, seconds: deadline)
                )
                if didWin {
                    workTask.cancel()
                }
            }
            timeoutHandle.set(timeoutTask)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + deadline,
                execute: timeoutTask
            )
        }
    }

    private static let mutatingCommandsByTool: [String: Set<String>] = [
        "logic_transport": [
            "play", "stop", "record", "pause", "rewind", "fast_forward", "toggle_cycle",
            "toggle_metronome", "set_tempo", "goto_position", "set_cycle_range", "toggle_count_in",
        ],
        "logic_tracks": [
            "select", "create_audio", "create_instrument", "create_drummer", "create_external_midi",
            "delete", "duplicate", "rename", "mute", "solo", "arm", "arm_only", "record_sequence",
            "set_automation", "set_instrument",
            // NOTE: list_library / scan_library / scan_plugin_presets are read-only
            // queries (cache/disk/AX reads that transiently move + restore AX
            // selection but do not change project state). They intentionally stay
            // OUT of the mutation gate so a multi-minute library scan cannot block
            // every real write — and so a slow scan can never wedge the gate. They
            // still carry the long-running deadline via `longRunningCommands`.
        ],
        "logic_mixer": [
            "set_volume", "set_pan", "set_master_volume", "set_plugin_param", "insert_plugin",
        ],
        "logic_midi": [
            "send_note", "send_chord", "send_cc", "send_program_change", "send_pitch_bend",
            "send_aftertouch", "send_sysex", "play_sequence", "import_file", "create_virtual_port",
            "step_input", "mmc_play", "mmc_stop", "mmc_record", "mmc_locate",
        ],
        "logic_edit": [
            "undo", "redo", "cut", "copy", "paste", "delete", "select_all", "split", "join",
            "quantize", "bounce_in_place", "normalize", "duplicate", "toggle_step_input",
        ],
        "logic_navigate": [
            "goto_bar", "goto_marker", "create_marker", "delete_marker", "rename_marker",
            "zoom_to_fit", "set_zoom", "toggle_view",
        ],
        "logic_project": [
            "new", "open", "save", "save_as", "close", "bounce", "launch", "quit",
            "export_run", "export_resume", "cleanup_apply",
        ],
        "logic_plugins": ["set_param_verified", "insert_verified"],
    ]

    static func isMutatingCommand(tool: String, command: String) -> Bool {
        mutatingCommandsByTool[tool]?.contains(command) == true
    }

    private static func operationName(tool: String, command: String) -> String {
        command.isEmpty ? tool : "\(tool).\(command)"
    }

    private final class DeadlineRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        @discardableResult
        func resume(
            _ continuation: CheckedContinuation<CallTool.Result, Never>,
            returning result: CallTool.Result
        ) -> Bool {
            lock.lock()
            if resumed {
                lock.unlock()
                return false
            }
            resumed = true
            lock.unlock()
            continuation.resume(returning: result)
            return true
        }
    }

    /// #199 throwing-capable single-winner race for the resource-read deadline.
    /// Like `DeadlineRace` but resumes a `CheckedContinuation<…, Error>` and can
    /// resume with either a value (read success / timeout body) or a thrown
    /// error (genuine read failure), guaranteeing the continuation resumes once.
    private final class ResourceDeadlineRace: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        @discardableResult
        func resume(
            _ continuation: CheckedContinuation<ReadResource.Result, Error>,
            returning result: ReadResource.Result
        ) -> Bool {
            lock.lock()
            if resumed { lock.unlock(); return false }
            resumed = true
            lock.unlock()
            continuation.resume(returning: result)
            return true
        }

        @discardableResult
        func resume(
            _ continuation: CheckedContinuation<ReadResource.Result, Error>,
            throwing error: Error
        ) -> Bool {
            lock.lock()
            if resumed { lock.unlock(); return false }
            resumed = true
            lock.unlock()
            continuation.resume(throwing: error)
            return true
        }
    }

    private final class DeadlineTimeoutHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: DispatchWorkItem?
        private var cancelled = false

        func set(_ task: DispatchWorkItem) {
            lock.lock()
            if cancelled {
                lock.unlock()
                task.cancel()
                return
            }
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            self.task = nil
            lock.unlock()
            task?.cancel()
        }
    }

    /// #218: MCP list methods paginate everything into a single page — the
    /// server never issues a `nextCursor`. So ANY cursor a client sends is a
    /// stale/fabricated continuation token. Per the MCP pagination guidance,
    /// reject it with `-32602 invalidParams` instead of silently returning the
    /// first page (which makes a fresh read indistinguishable from a broken
    /// continuation and hides client/harness pagination bugs). Absent cursor
    /// (nil) is the normal first-page read and passes.
    static func invalidCursorError(_ cursor: String?, method: String) -> MCPError? {
        guard let cursor else { return nil }
        return .invalidParams(
            "Invalid pagination cursor for \(method): \"\(cursor)\". "
                + "This server returns all results in a single page and never issues a nextCursor, "
                + "so no cursor value is valid."
        )
    }

    /// Protocol-boundary validation for `tools/call`, applied by the SDK
    /// registration wrapper BEFORE dispatch. Returns the JSON-RPC error the
    /// server must raise for a malformed request, or nil when the call is
    /// well-formed enough to dispatch.
    ///
    /// #216 + #217: reject a malformed `tools/call` at the protocol boundary
    /// with `-32602 invalidParams` (not a `result` carrying `isError: true`,
    /// which protocol clients classify as a tool-level failure). Two
    /// malformations, checked in order:
    ///  * #216 — the tool `name` is not a registered tool.
    ///  * #217 — the schema-required `command` argument is missing or empty
    ///    (previously dispatched as an empty command → misleading domain error
    ///    "Unknown system command: ."). Validates command PRESENCE only; a
    ///    present command whose command-specific params are missing (e.g.
    ///    `set_tempo` with no `tempo`) still dispatches and returns the
    ///    dispatcher's typed domain `invalid_params` State C.
    /// Single source of truth for the wire behavior; the dispatch switch's
    /// `default: "Unknown tool"` branch remains only as unreachable defense.
    static func toolCallProtocolError(name: String, arguments: [String: Value]?) -> MCPError? {
        guard ServerCatalog.toolNames.contains(name) else {
            return .invalidParams("Unknown tool: \(name)")
        }
        let command = arguments?["command"]?.stringValue
        if command == nil || command?.isEmpty == true {
            return .invalidParams("Missing required argument 'command' for tool '\(name)'")
        }
        return nil
    }

    private func registerTools() async {
        let handlers = makeHandlers(dialogPresent: { AXLogicProElements.dialogPresent() })
        await server.withMethodHandler(ListTools.self) { params in
            if let error = Self.invalidCursorError(params.cursor, method: "tools/list") { throw error }
            return await handlers.listTools(params)
        }
        await server.withMethodHandler(CallTool.self) { params in
            // #216/#217: reject a malformed tools/call (unknown tool name or
            // missing/empty required command) with a JSON-RPC error before dispatch.
            if let error = Self.toolCallProtocolError(name: params.name, arguments: params.arguments) {
                throw error
            }
            return await handlers.callTool(params)
        }
    }

    // MARK: - Resource Registration (18 resources + 11 templates)

    private func registerResources() async {
        let handlers = makeHandlers()
        await server.withMethodHandler(ListResources.self) { params in
            if let error = Self.invalidCursorError(params.cursor, method: "resources/list") { throw error }
            return await handlers.listResources(params)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await handlers.readResource(params)
        }

        await server.withMethodHandler(ListResourceTemplates.self) { params in
            if let error = Self.invalidCursorError(params.cursor, method: "resources/templates/list") { throw error }
            return await handlers.listResourceTemplates(params)
        }
    }

    // MARK: - Server Lifecycle

    func compositionSnapshot() -> ServerCompositionSnapshot {
        ServerCatalog.snapshot(channelIDs: registeredChannels().map(\.id))
    }

    func start() async throws {
        if let cleanupStartupArtifacts = runtimeOverrides?.cleanupStartupArtifacts {
            cleanupStartupArtifacts()
        } else {
            SMFWriter.cleanupStartupOrphanFiles()
        }
        let plan = runtimePlan()
        try await plan.run()
    }

    /// Tear down the server in the same order that `ServerRuntimePlan.run`
    /// uses on its happy path: poller → channels → ports. Idempotent — actors
    /// underneath swallow repeat stop calls. Used by the SIGTERM/SIGINT path
    /// in `MainEntrypoint` so signal-driven shutdown actually cleans up the
    /// virtual MIDI ports, AX poller, and channel transports instead of
    /// leaking them on `exit(0)`.
    func stop() async {
        if let stopPoller = runtimeOverrides?.stopPoller {
            await stopPoller()
        } else {
            await poller.stopImmediately()
        }
        if let stopChannels = runtimeOverrides?.stopChannels {
            await stopChannels()
        } else {
            await router.stopAll(excluding: [.accessibility])
        }
        if let stopPorts = runtimeOverrides?.stopPorts {
            await stopPorts()
        } else {
            await portManager.stop()
        }
    }

    private func runtimePlan() -> ServerRuntimePlan {
        let server = self.server
        let router = self.router
        let poller = self.poller
        let portManager = self.portManager
        let channels = registeredChannels()
        let snapshot = ServerCatalog.snapshot(channelIDs: channels.map(\.id))

        return ServerRuntimePlan(
            startPorts: {
                if let startPorts = self.runtimeOverrides?.startPorts {
                    try await startPorts()
                } else {
                    do {
                        try await portManager.start()
                    } catch {
                        Log.warn("MIDI port manager unavailable — continuing degraded: \(error)", subsystem: "server")
                    }
                }
            },
            registerChannels: {
                if let registerChannels = self.runtimeOverrides?.registerChannels {
                    await registerChannels()
                } else {
                    for channel in channels {
                        await router.register(channel)
                    }
                }
            },
            startChannels: {
                if let startChannels = self.runtimeOverrides?.startChannels {
                    return await startChannels()
                }
                return await router.startAll()
            },
            startPoller: {
                if let startPoller = self.runtimeOverrides?.startPoller {
                    await startPoller()
                } else {
                    await poller.start()
                }
            },
            registerHandlers: {
                if let registerHandlers = self.runtimeOverrides?.registerHandlers {
                    await registerHandlers()
                } else {
                    await self.registerTools()
                    await self.registerResources()
                }
            },
            serve: {
                if let serve = self.runtimeOverrides?.serve {
                    try await serve()
                } else {
                    Log.info(snapshot.startupBanner, subsystem: "server")
                    // #220: serialize stdout frame writes so concurrent large
                    // responses can never interleave/corrupt the newline-
                    // delimited stream (the SDK StdioTransport's reentrant
                    // partial-write retry allows that under concurrency).
                    let transport = SerializedStdioTransport()
                    try await server.start(transport: transport)
                    await server.waitUntilCompleted()
                }
            },
            stopPoller: {
                if let stopPoller = self.runtimeOverrides?.stopPoller {
                    await stopPoller()
                } else {
                    await poller.stopImmediately()
                }
            },
            stopChannels: {
                if let stopChannels = self.runtimeOverrides?.stopChannels {
                    await stopChannels()
                } else {
                    await router.stopAll(excluding: [.accessibility])
                }
            },
            stopPorts: {
                if let stopPorts = self.runtimeOverrides?.stopPorts {
                    await stopPorts()
                } else {
                    await portManager.stop()
                }
            },
            startupError: {
                StartupError.channelStartupFailed($0)
            }
        )
    }

    private func registeredChannels() -> [any Channel] {
        [
            mcuChannel,
            keyCommandsChannel,
            scripterChannel,
            coreMIDIChannel,
            axChannel,
            cgEventChannel,
            appleScriptChannel,
        ]
    }
}

// MARK: - Production Transports

/// Real MIDI transport for MCU channel using MIDIPortManager.
actor ProductionMCUTransport: MCUTransportProtocol {
    private let portManager: any VirtualPortManaging
    private let packetSink: @Sendable (MIDIEndpointRef, [UInt8]) -> Void
    private var port: MIDIPortManager.MIDIPortPair?
    private var onReceive: (@Sendable (MIDIFeedback.Event) -> Void)?

    init(
        portManager: any VirtualPortManaging,
        packetSink: @escaping @Sendable (MIDIEndpointRef, [UInt8]) -> Void = emitMIDIPacket
    ) {
        self.portManager = portManager
        self.packetSink = packetSink
    }

    func send(_ bytes: [UInt8]) async {
        guard let source = port?.source else {
            Log.warn("MCU port not started — dropping \(bytes.count) bytes", subsystem: "mcu")
            return
        }
        packetSink(source, bytes)
        MCUTrace.emit(.tx, bytes)
    }

    func start(onReceive: @escaping @Sendable (MIDIFeedback.Event) -> Void) async throws {
        self.onReceive = onReceive
        do {
            port = try await portManager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { [weak self] eventList, _ in
                guard let self else { return }
                // Parse UMP event list → MIDI 1.0 bytes → MIDIFeedback.Event
                // Use original eventList pointer (not a stack copy) for safe traversal
                let numPackets = Int(eventList.pointee.numPackets)
                guard numPackets > 0 else { return }
                var packetPtr = UnsafeRawPointer(eventList)
                    .advanced(by: MemoryLayout.offset(of: \MIDIEventList.packet)!)
                    .assumingMemoryBound(to: MIDIEventPacket.self)
                for _ in 0..<numPackets {
                    let wordCount = min(Int(packetPtr.pointee.wordCount), 64)
                    if wordCount > 0 {
                        let bytes: [UInt8] = withUnsafeBytes(of: packetPtr.pointee.words) { raw in
                            Array(raw.prefix(wordCount * 4))
                        }
                        MCUTrace.emit(.rx, bytes)
                        let events = MIDIFeedback.parseBytes(bytes)
                        for event in events {
                            Task { [weak self] in await self?.onReceive?(event) }
                        }
                    }
                    packetPtr = UnsafePointer(MIDIEventPacketNext(packetPtr))
                }
            }
        } catch {
            Log.warn("MCU port creation failed: \(error)", subsystem: "mcu")
            throw error
        }
    }

    func stop() async {
        port = nil
        // Phase 6 P2: drop the receive sink so a late inbound packet (the
        // MIDIPortManager destination callback can outlive `port = nil` until
        // portManager teardown) cannot deliver feedback into the cache after
        // the channel has stopped.
        onReceive = nil
    }
}

/// Real MIDI transport for KeyCmd/Scripter channels — send-only.
actor ProductionKeyCmdTransport: KeyCmdTransportProtocol {
    private let portManager: any VirtualPortManaging
    private let portName: String
    private let packetSink: @Sendable (MIDIEndpointRef, [UInt8]) -> Void
    private var port: MIDIPortManager.MIDIPortPair?
    private var startupError: String?

    init(
        portManager: any VirtualPortManaging,
        portName: String = "LogicProMCP-KeyCmd-Internal",
        packetSink: @escaping @Sendable (MIDIEndpointRef, [UInt8]) -> Void = emitMIDIPacket
    ) {
        self.portManager = portManager
        self.portName = portName
        self.packetSink = packetSink
    }

    func prepare() async throws {
        guard port == nil else { return }
        do {
            port = try await portManager.createSendOnlyPort(name: portName)
            startupError = nil
        } catch {
            startupError = "Failed to create virtual MIDI port '\(portName)': \(error)"
            Log.warn("KeyCmd port creation failed: \(error)", subsystem: "keycmd")
            throw error
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await prepare()
        guard let source = port?.source else {
            throw NSError(domain: "LogicProMCP.ProductionKeyCmdTransport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Virtual MIDI port '\(portName)' is unavailable"
            ])
        }
        packetSink(source, bytes)
    }

    func readiness() async -> KeyCmdTransportReadiness {
        if let port {
            return KeyCmdTransportReadiness(
                available: true,
                detail: "Virtual MIDI port '\(port.name)' is ready"
            )
        }
        if let startupError {
            return KeyCmdTransportReadiness(available: false, detail: startupError)
        }
        return KeyCmdTransportReadiness(
            available: false,
            detail: "Virtual MIDI port '\(portName)' has not been prepared"
        )
    }

    func stop() async {
        port = nil
        startupError = nil
    }
}
