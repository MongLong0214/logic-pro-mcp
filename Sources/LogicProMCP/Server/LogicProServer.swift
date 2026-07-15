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
        toolWithOutputSchema(TransportDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(TrackDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(MixerDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(MIDIDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(EditDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(NavigateDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(ProjectDispatcher.tool, outputSchema: honestContractOutputSchema()),
        toolWithOutputSchema(AudioDispatcher.tool, outputSchema: genericObjectOutputSchema()),
        toolWithOutputSchema(SystemDispatcher.tool, outputSchema: genericObjectOutputSchema()),
        toolWithOutputSchema(PluginsDispatcher.tool, outputSchema: honestContractOutputSchema()),
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
    enum ReclaimPolicy: Equatable, Sendable {
        case automatic
        case releaseOnly
    }

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
    private var activeReclaimPolicy: ReclaimPolicy = .automatic
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

    func tryAcquire(
        operation: String,
        now: Date = Date(),
        reclaimPolicy: ReclaimPolicy = .automatic
    ) -> Claim? {
        lock.lock()
        defer { lock.unlock() }
        if let active = activeOperation, let since = acquiredAt {
            if activeReclaimPolicy == .releaseOnly {
                return nil
            } else if let timedOutAt, now.timeIntervalSince(timedOutAt) >= timedOutReclaimGrace {
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
        activeReclaimPolicy = reclaimPolicy
        return Claim(epoch: epoch, operation: operation)
    }

    /// Mark the current holder (if `claim` still owns the gate) as abandoned by
    /// the command deadline, starting the short `timedOutReclaimGrace` window.
    /// Epoch-guarded so a late mark from an abandoned op cannot affect a
    /// successor that already reclaimed the gate.
    func markTimedOut(_ claim: Claim, now: Date = Date()) {
        lock.lock()
        if epoch == claim.epoch, activeReclaimPolicy == .automatic {
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
            activeReclaimPolicy = .automatic
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
/// Exposes 10 dispatcher tools + 18 resources + 12 templates, routing through
/// the ChannelRouter to the appropriate macOS communication channel.
actor LogicProServer {
    private let server: Server
    private let router: ChannelRouter
    private let cache: StateCache
    private let targetRegistry: TargetRegistry
    private let sagaJournal: SagaJournal
    private let poller: StatePoller
    private let resourceSubscriptions: ResourceSubscriptionRegistry
    private let resourceNotifier: ResourceUpdateNotifier
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
    private let mutationGate: LogicMutationGate

    init(
        runtimeOverrides: LogicProServerRuntimeOverrides? = nil,
        pollerRuntime: StatePoller.Runtime = .production,
        sagaJournal: SagaJournal = SagaJournal(),
        mutationGate: LogicMutationGate? = nil
    ) {
        let server = Server(
            name: ServerConfig.serverName,
            version: ServerConfig.serverVersion,
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        let router = ChannelRouter()
        let cache = StateCache()
        let targetRegistry = TargetRegistry()
        let resourceSubscriptions = ResourceSubscriptionRegistry()
        let resourceNotifier = ResourceUpdateNotifier(registry: resourceSubscriptions)

        self.runtimeOverrides = runtimeOverrides
        self.server = server
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.sagaJournal = sagaJournal
        self.mutationGate = mutationGate ?? LogicMutationGate(
            timedOutReclaimGrace: LogicProServer.mutationGateReclaimGraceSeconds
        )
        self.resourceSubscriptions = resourceSubscriptions
        self.resourceNotifier = resourceNotifier
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

        self.poller = StatePoller(
            axChannel: axChannel,
            cache: cache,
            runtime: pollerRuntime,
            postPoll: { cacheKeys in
                await resourceNotifier.publishChangedResources(
                    cacheKeys: cacheKeys,
                    cache: cache,
                    router: router,
                    readResource: { uri, cache, router in
                        try await ResourceHandlers.read(
                            uri: uri,
                            cache: cache,
                            router: router,
                            targetRegistry: targetRegistry
                        )
                    }
                ) { uri in
                    try await server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
                }
            }
        )
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

    func makeHandlers(
        dialogPresent: @escaping @Sendable () -> Bool = { false },
        supportBundleExporter: SystemDispatcher.SupportBundleExporter? = nil
    ) -> LogicProServerHandlers {
        let router = self.router
        let cache = self.cache
        let poller = self.poller
        let mutationGate = self.mutationGate
        let targetRegistry = self.targetRegistry
        let sagaJournal = self.sagaJournal
        let handlerDependencies = HandlerDependencies(
            router: router,
            cache: cache,
            targetRegistry: targetRegistry,
            poller: poller,
            dialogPresent: dialogPresent,
            supportBundleExporter: supportBundleExporter,
            sagaJournal: sagaJournal,
            mutationGate: mutationGate
        )

        return LogicProServerHandlers(
            listTools: { _ in
                ListTools.Result(tools: ServerCatalog.tools)
            },
            callTool: { params in
                let name = params.name
                let command = params.arguments?["command"]?.stringValue ?? ""
                let rawCmdParams = params.arguments?["params"]
                if let invalidParams = Self.strictParamContainerValidationResult(
                    tool: name,
                    command: command,
                    params: rawCmdParams
                ) {
                    return invalidParams
                }
                let cmdParams: [String: Value] = rawCmdParams?.objectValue ?? [:]
                if let invalidParams = Self.strictParamValidationResult(
                    tool: name,
                    command: command,
                    params: cmdParams
                ) {
                    return invalidParams
                }

                let handler = OperationHandlerRegistry.handler(tool: name, command: command)
                let fallback = handler == nil
                    ? OperationHandlerRegistry.fallbackHandler(tool: name, command: command)
                    : nil
                if handler == nil, fallback == nil {
                    guard ToolID(rawValue: name) != nil else {
                        return toolTextResult("Unknown tool: \(name)", isError: true)
                    }
                    return toolStateCResult(
                        .invalidParams,
                        hint: "Command '\(command)' is not registered for MCP tool '\(name)'",
                        extras: [
                            "command": command,
                            "tool": name,
                            "write_attempted": false,
                        ]
                    )
                }

                if let projectFailure = await TargetRefResolver.validateProjectReference(
                    cmdParams,
                    targetRegistry: targetRegistry,
                    operation: "\(name).\(command)"
                ) {
                    return projectFailure
                }

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
                let sagaControlPath = Self.sagaControlBypassesGlobalMutationGate(
                    tool: name,
                    command: command
                )
                return await Self.runWithDeadline(
                    tool: name,
                    command: command,
                    mutationGate: sagaControlPath ? nil : mutationGate,
                    externallyManagedMutation: sagaControlPath && command == "saga_execute"
                ) {
                    if let handler {
                        return await handler(handlerDependencies, cmdParams)
                    }
                    guard let fallback else {
                        return toolTextResult("Unknown tool: \(name)", isError: true)
                    }
                    return await fallback(handlerDependencies, cmdParams)
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
                    try await ResourceHandlers.read(
                        uri: params.uri,
                        cache: cache,
                        router: router,
                        targetRegistry: targetRegistry
                    )
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

    /// Per-command server-side deadline in seconds. Set far above each
    /// command's healthy completion time (sub-second for the fast tier) so a
    /// normal op can never false-trip; only a wedged/occluded Logic session
    /// that would otherwise hang the stdio loop is bounded.
    static func commandDeadlineSeconds(tool: String, command: String) -> Double {
        OperationRegistry.deadlineSeconds(tool: tool, command: command) ?? 25
    }

    static func sagaControlBypassesGlobalMutationGate(tool: String, command: String) -> Bool {
        tool == ToolID.logicSystem.rawValue
            && (command == "saga_execute" || command == "saga_cancel")
    }

    static func deadlineTimeoutResult(
        tool: String,
        command: String,
        seconds: Double,
        mutationMayStillBeRunning: Bool = false,
        mutationGateReclaimableAfterGrace: Bool = true
    ) -> CallTool.Result {
        let operation = operationName(tool: tool, command: command)
        var extras: [String: Any] = [
            "operation": operation,
            "timeout_sec": seconds,
            "recovery_hint": "Logic Pro may be busy, occluded, or showing a modal dialog. Dismiss any dialog and retry; check logic_system.health.",
        ]
        if tool == ToolID.logicSystem.rawValue,
           ["saga_preflight", "saga_execute", "saga_status", "saga_cancel"].contains(command) {
            extras.merge(SagaWire.sessionFields) { _, new in new }
        }
        if mutationMayStillBeRunning {
            // #201: the abandoned op's effect is unknown, so this result is not
            // itself safe to retry — but the gate no longer pins the session
            // indefinitely. It auto-reclaims `gate_reclaim_after_sec` after this
            // timeout, so unrelated mutating commands recover on their own
            // (their `mutating_operation_in_progress` refusal is `safe_to_retry`).
            extras["safe_to_retry"] = false
            extras["underlying_operation_stopped"] = false
            if mutationGateReclaimableAfterGrace {
                extras["mutation_gate"] = "reclaimable_after_grace"
                extras["gate_reclaim_after_sec"] = Self.mutationGateReclaimGraceSeconds
            } else {
                extras["mutation_gate"] = "held_until_saga_unwinds"
            }
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
        externallyManagedMutation: Bool = false,
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
                            || externallyManagedMutation,
                        mutationGateReclaimableAfterGrace: !externallyManagedMutation
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

    static func isMutatingCommand(tool: String, command: String) -> Bool {
        OperationRegistry.spec(tool: tool, command: command)?.mutability == Mutability.`mutating`
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
    /// Single source of truth for the wire behavior; the registry route's
    /// `"Unknown tool"` result remains only as unreachable defense.
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

    static func strictParamValidationResult(
        tool: String,
        command: String,
        params: [String: Value]
    ) -> CallTool.Result? {
        guard let spec = strictValidationSpec(tool: tool, command: command) else { return nil }

        let recognizedParams = spec.allowedParams.union(
            OperationRegistry.dispatcherRejectedParamsByOperation[spec.id] ?? []
        )
        let unknownParams = Set(params.keys).subtracting(recognizedParams).sorted()
        guard !unknownParams.isEmpty else { return nil }

        let allowedParams = spec.allowedParams.sorted()
        return toolInvalidParamsResult(
            "Unknown parameters: \(unknownParams.joined(separator: ", ")). "
                + "Allowed parameters: \(allowedParams.joined(separator: ", ")).",
            extras: [
                "allowed_params": allowedParams,
                "operation": spec.id.rawValue,
                "unknown_params": unknownParams,
                "write_attempted": false,
            ]
        )
    }

    static func strictParamContainerValidationResult(
        tool: String,
        command: String,
        params: Value?
    ) -> CallTool.Result? {
        guard let spec = strictValidationSpec(tool: tool, command: command),
              let params,
              params.objectValue == nil else {
            return nil
        }
        return toolInvalidParamsResult(
            "Parameters for \(spec.id.rawValue) must be an object.",
            extras: [
                "expected_params_type": "object",
                "operation": spec.id.rawValue,
                "write_attempted": false,
            ]
        )
    }

    private static func strictValidationSpec(tool: String, command: String) -> OperationSpec? {
        guard FeatureFlags.adr003StrictParams,
              let spec = OperationRegistry.spec(tool: tool, command: command),
              !OperationRegistry.strictParamValidationOptOuts.contains(spec.id) else {
            return nil
        }
        return spec
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

    // MARK: - Resource Registration (18 resources + 12 templates)

    private func registerResources() async {
        let handlers = makeHandlers()
        let subscriptions = self.resourceSubscriptions
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

        await server.withMethodHandler(ResourceSubscribe.self) { params in
            try await subscriptions.subscribe(uri: params.uri)
            return Empty()
        }

        await server.withMethodHandler(ResourceUnsubscribe.self) { params in
            try await subscriptions.unsubscribe(uri: params.uri)
            return Empty()
        }
    }

    private func registerPrompts() async {
        await server.withMethodHandler(ListPrompts.self) { params in
            if let error = Self.invalidCursorError(params.cursor, method: "prompts/list") { throw error }
            return WorkflowPromptProvider.list()
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            try WorkflowPromptProvider.get(name: params.name)
        }
    }

    // MARK: - Server Lifecycle

    func compositionSnapshot() -> ServerCompositionSnapshot {
        ServerCatalog.snapshot(channelIDs: registeredChannels().map(\.id))
    }

    func start() async throws {
        await sagaJournal.clear()
        OperationHandlerRegistry.validate()
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
        await sagaJournal.clear()
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
        await resourceSubscriptions.clear()
        await resourceNotifier.reset()
    }

    func startProtocolProbe(transport: any Transport) async throws {
        await sagaJournal.clear()
        OperationHandlerRegistry.validate()
        await registerTools()
        await registerResources()
        await registerPrompts()
        try await server.start(transport: transport)
    }

    func stopProtocolProbe() async {
        await sagaJournal.clear()
        await server.stop()
        await resourceSubscriptions.clear()
        await resourceNotifier.reset()
    }

    func replaceTracksForTesting(_ tracks: [TrackState]) async {
        await cache.updateTracks(tracks)
    }

    func publishResourceChangesForTesting(_ cacheKeys: [ResourceCacheKey]) async {
        let targetRegistry = self.targetRegistry
        await resourceNotifier.publishChangedResources(
            cacheKeys: cacheKeys,
            cache: cache,
            router: router,
            readResource: { uri, cache, router in
                try await ResourceHandlers.read(
                    uri: uri,
                    cache: cache,
                    router: router,
                    targetRegistry: targetRegistry
                )
            }
        ) { uri in
            try await server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
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
                    await self.registerPrompts()
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
                await self.sagaJournal.clear()
                if let stopPoller = self.runtimeOverrides?.stopPoller {
                    await stopPoller()
                } else {
                    await poller.stopImmediately()
                }
                await self.resourceSubscriptions.clear()
                await self.resourceNotifier.reset()
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
    // v3.8.0 (P1 restart fix) — the CURRENT feedback sink, held in a stable
    // lock-guarded box rather than captured by value inside the CoreMIDI
    // callback. `MIDIPortManager.createBidirectionalPort` REUSES an existing
    // destination on restart WITHOUT re-registering the callback, so the
    // closure installed by the FIRST start() is the one CoreMIDI keeps firing.
    // If that closure captured the sink by value it would forever yield into
    // the first (now-finished) AsyncStream continuation — every feedback event
    // after any stop→start silently dropped. Holding the sink in a box that
    // the callback dereferences per event lets a restart's fresh continuation
    // yield be picked up by the reused callback. The box is read on the
    // CoreMIDI real-time thread, so access is NSLock-guarded and lock-light:
    // the lock spans only the pointer read/write, never the delivery call.
    private final class FeedbackSink: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (@Sendable (MIDIFeedback.Event) -> Void)?

        func set(_ newSink: (@Sendable (MIDIFeedback.Event) -> Void)?) {
            lock.lock()
            sink = newSink
            lock.unlock()
        }

        func deliver(_ event: MIDIFeedback.Event) {
            lock.lock()
            let current = sink
            lock.unlock()
            current?(event)
        }
    }

    private let portManager: any VirtualPortManaging
    private let packetSink: @Sendable (MIDIEndpointRef, [UInt8]) -> Void
    private let feedbackSink = FeedbackSink()
    private var port: MIDIPortManager.MIDIPortPair?

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
        // Publish the new sink BEFORE (re)creating the port so a reused
        // destination's already-registered callback immediately routes feedback
        // into this start()'s AsyncStream continuation.
        feedbackSink.set(onReceive)
        // Capture the stable box (NOT `onReceive` by value, NOT `self`): the
        // callback registered here may be reused verbatim across restarts, so
        // it must dereference whatever sink is current at delivery time.
        let sink = feedbackSink
        do {
            port = try await portManager.createBidirectionalPort(name: "LogicProMCP-MCU-Internal") { eventList, _ in
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
                        // v3.8.0 (WS6 / AC1) — deliver each parsed event to the
                        // CURRENT sink SYNCHRONOUSLY in arrival order. The
                        // previous per-event `Task { self.onReceive?(event) }`
                        // hop admitted events out of order (the 2-site race), so
                        // there is NO per-event Task here — FIFO is preserved.
                        // `sink` is a stable box (see FeedbackSink), so a restart
                        // that reuses this very callback still delivers into the
                        // fresh AsyncStream yield. Packets arriving after stop()
                        // read a nil sink (box cleared) and are dropped.
                        for event in MIDIFeedback.parseBytes(bytes) {
                            sink.deliver(event)
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
        // Clear the sink first so any packet delivered on a reused destination
        // after stop() reads nil and is dropped (post-stop-ignored contract),
        // then release the port reference.
        feedbackSink.set(nil)
        port = nil
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
