import MCP

struct HandlerDependencies: Sendable {
    let router: ChannelRouter
    let cache: StateCache
    let targetRegistry: TargetRegistry
    let poller: StatePoller
    let dialogPresent: @Sendable () -> Bool
    let supportBundleExporter: SystemDispatcher.SupportBundleExporter?
    let sagaJournal: SagaJournal
    let mutationGate: LogicMutationGate?
    /// Explicit seam for the project lifecycle AppleScript executor.
    /// `nil` = production osascript path. Tests (notably the executable
    /// dispatch census) inject a stub so exercising `launch`/`quit` cases
    /// can never touch the real app lifecycle.
    let projectLifecycleExecute: (@Sendable (String) async -> ProjectDispatcher.LifecycleExecution)?
    /// PRD-007: explicit seam for the LIVE AX track-header scan that the
    /// index-binding ratchet corroborates a bare index against. `nil` =
    /// production `AXLogicProElements.trackNames()`. Tests inject a fixed
    /// surface so `.corroborated` ops stay deterministically exercisable
    /// end-to-end — without this seam the only way to drive them through the
    /// real handler would be live AX, and their index path would silently drop
    /// out of the deterministic census.
    let liveTrackNames: (@Sendable () -> [Int: String]?)?

    init(
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry,
        poller: StatePoller,
        dialogPresent: @escaping @Sendable () -> Bool,
        supportBundleExporter: SystemDispatcher.SupportBundleExporter?,
        sagaJournal: SagaJournal = SagaJournal(),
        mutationGate: LogicMutationGate? = nil,
        projectLifecycleExecute: (@Sendable (String) async -> ProjectDispatcher.LifecycleExecution)? = nil,
        liveTrackNames: (@Sendable () -> [Int: String]?)? = nil
    ) {
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.poller = poller
        self.dialogPresent = dialogPresent
        self.supportBundleExporter = supportBundleExporter
        self.sagaJournal = sagaJournal
        self.mutationGate = mutationGate
        self.projectLifecycleExecute = projectLifecycleExecute
        self.liveTrackNames = liveTrackNames
    }

    /// The live header reader to hand a dispatcher: the injected seam when a
    /// test supplies one, else the production AX scan.
    var liveTrackNamesReader: @Sendable () -> [Int: String]? {
        liveTrackNames ?? { AXLogicProElements.trackNames() }
    }
}

typealias OperationHandler = @Sendable (
    HandlerDependencies,
    [String: Value]
) async -> CallTool.Result

enum OperationHandlerRegistry {
    struct Binding: Sendable {
        let id: OperationID
        let tool: String
        let command: String
        let handler: OperationHandler
    }

    private struct Key: Hashable, Sendable {
        let tool: String
        let command: String

        var description: String { "\(tool):\(command)" }
    }

    static let bindings: [Binding] = OperationRegistry.specs.map { spec in
        Binding(
            id: spec.id,
            tool: spec.tool.rawValue,
            command: spec.command,
            handler: makeHandler(tool: spec.tool, command: spec.command)
        )
    }

    private static let handlersByID = bindings.reduce(into: [OperationID: OperationHandler]()) {
        $0[$1.id] = $1.handler
    }

    private static let handlersByKey = bindings.reduce(into: [Key: OperationHandler]()) {
        $0[Key(tool: $1.tool, command: $1.command)] = $1.handler
    }

    private static let validated: Void = {
        let errors = validationErrors()
        guard errors.isEmpty else {
            fatalError("Operation handler registry invariant failed:\n\(errors.joined(separator: "\n"))")
        }
    }()

    static func handler(for operationID: OperationID) -> OperationHandler? {
        validate()
        return handlersByID[operationID]
    }

    static func handler(tool: String, command: String) -> OperationHandler? {
        validate()
        return handlersByKey[Key(tool: tool, command: command)]
    }

    static func fallbackHandler(tool: String, command: String) -> OperationHandler? {
        validate()
        guard let toolID = ToolID(rawValue: tool) else { return nil }
        let isRegistered = OperationRegistry.spec(tool: tool, command: command) != nil
            && handledCommands(for: toolID).contains(command)
        guard isRegistered || notExposedCommands(for: toolID).contains(command) else { return nil }
        return makeHandler(tool: toolID, command: command)
    }

    private static func handledCommands(for tool: ToolID) -> Set<String> {
        switch tool {
        case .logicTransport: TransportDispatcher.handledCommands
        case .logicMixer: MixerDispatcher.handledCommands
        case .logicNavigate: NavigateDispatcher.handledCommands
        case .logicAudio: AudioDispatcher.handledCommands
        case .logicSystem: SystemDispatcher.handledCommands
        case .logicPlugins: PluginsDispatcher.handledCommands
        case .logicEdit: EditDispatcher.handledCommands
        case .logicProject: ProjectDispatcher.handledCommands
        case .logicMidi: MIDIDispatcher.handledCommands
        case .logicTracks: TrackDispatcher.handledCommands
        }
    }

    static func notExposedCommands(for tool: ToolID) -> Set<String> {
        switch tool {
        case .logicMixer: MixerDispatcher.notExposedCommands
        case .logicTracks: TrackDispatcher.notExposedCommands
        default: []
        }
    }

    static func validate() {
        _ = validated
    }

    static func validationErrors() -> [String] {
        var errors = OperationRegistry.validationErrors().map { "operation spec: \($0)" }
        let specs = OperationRegistry.specs
        let specIDs = Set(specs.map(\.id))
        let bindingIDs = bindings.map(\.id)
        let handlerIDs = Set(bindingIDs)
        let specKeys = Set(specs.map { Key(tool: $0.tool.rawValue, command: $0.command) })
        let bindingKeys = bindings.map { Key(tool: $0.tool, command: $0.command) }
        let handlerKeys = Set(bindingKeys)

        if bindings.count != specs.count {
            errors.append("binding count: expected \(specs.count), got \(bindings.count)")
        }

        let duplicateIDs = Dictionary(grouping: bindingIDs, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.map(\.rawValue).sorted()
        if !duplicateIDs.isEmpty {
            errors.append("duplicate handler IDs: \(duplicateIDs.joined(separator: ", "))")
        }

        let duplicateKeys = Dictionary(grouping: bindingKeys, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.map(\.description).sorted()
        if !duplicateKeys.isEmpty {
            errors.append("duplicate handler keys: \(duplicateKeys.joined(separator: ", "))")
        }

        let missingIDs = specIDs.subtracting(handlerIDs).map(\.rawValue).sorted()
        if !missingIDs.isEmpty {
            errors.append("missing handler IDs: \(missingIDs.joined(separator: ", "))")
        }
        let orphanIDs = handlerIDs.subtracting(specIDs).map(\.rawValue).sorted()
        if !orphanIDs.isEmpty {
            errors.append("orphan handler IDs: \(orphanIDs.joined(separator: ", "))")
        }

        let missingKeys = specKeys.subtracting(handlerKeys).map(\.description).sorted()
        if !missingKeys.isEmpty {
            errors.append("missing handler keys: \(missingKeys.joined(separator: ", "))")
        }
        let orphanKeys = handlerKeys.subtracting(specKeys).map(\.description).sorted()
        if !orphanKeys.isEmpty {
            errors.append("orphan handler keys: \(orphanKeys.joined(separator: ", "))")
        }

        if handlersByID.count != bindings.count {
            errors.append("operation ID table count: expected \(bindings.count), got \(handlersByID.count)")
        }
        if handlersByKey.count != bindings.count {
            errors.append("tool-command table count: expected \(bindings.count), got \(handlersByKey.count)")
        }

        for rawTool in OperationRegistry.registeredToolRawValues.sorted() {
            guard let tool = ToolID(rawValue: rawTool) else { continue }
            let notExposed = notExposedCommands(for: tool)
            let handledOverlap = notExposed.intersection(handledCommands(for: tool)).sorted()
            if !handledOverlap.isEmpty {
                errors.append("not-exposed/handled overlap for \(rawTool): \(handledOverlap.joined(separator: ", "))")
            }
            let registered = Set(specs.filter { $0.tool == tool }.map(\.command))
            let registryOverlap = notExposed.intersection(registered).sorted()
            if !registryOverlap.isEmpty {
                errors.append("not-exposed/registry overlap for \(rawTool): \(registryOverlap.joined(separator: ", "))")
            }
        }

        return errors
    }

    private static func makeHandler(tool: ToolID, command: String) -> OperationHandler {
        switch tool {
        case .logicTransport:
            return { dependencies, params in
                await TransportDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    dialogPresent: dependencies.dialogPresent
                )
            }
        case .logicMixer:
            return { dependencies, params in
                await MixerDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry,
                    // ADR-002 F5 — production dispatch supplies the live AX
                    // track-header reader so the target_ref mutation boundary
                    // fails closed on an out-of-band reorder.
                    liveTrackName: { AXLogicProElements.trackName(at: $0) },
                    liveTrackNames: dependencies.liveTrackNamesReader
                )
            }
        case .logicNavigate:
            return { dependencies, params in
                await NavigateDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache
                )
            }
        case .logicAudio:
            return { _, params in
                AudioDispatcher.handle(command: command, params: params)
            }
        case .logicSystem:
            return { dependencies, params in
                await SystemDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    poller: dependencies.poller,
                    supportBundleExporter: dependencies.supportBundleExporter,
                    targetRegistry: dependencies.targetRegistry,
                    dialogPresent: dependencies.dialogPresent,
                    sagaJournal: dependencies.sagaJournal,
                    mutationGate: dependencies.mutationGate,
                    // ADR-002 F5 — production dispatch supplies the live AX
                    // track-header reader so saga-replayed target_ref track/mixer
                    // steps fail closed on an out-of-band reorder.
                    liveTrackName: { AXLogicProElements.trackName(at: $0) },
                    liveTrackNames: dependencies.liveTrackNamesReader,
                    // LPMCP-PRD-004 — saga before-state/verification/compensation
                    // read the live AX surface, never the cache mirror.
                    sagaLiveReadback: .production
                )
            }
        case .logicPlugins:
            return { dependencies, params in
                await PluginsDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry,
                    liveTrackNames: dependencies.liveTrackNamesReader
                )
            }
        case .logicEdit:
            return { dependencies, params in
                await EditDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache
                )
            }
        case .logicProject:
            return { dependencies, params in
                if let lifecycle = dependencies.projectLifecycleExecute {
                    return await ProjectDispatcher.handle(
                        command: command,
                        params: params,
                        router: dependencies.router,
                        cache: dependencies.cache,
                        targetRegistry: dependencies.targetRegistry,
                        executeLifecycleScript: lifecycle,
                        dialogPresent: dependencies.dialogPresent
                    )
                }
                return await ProjectDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry,
                    dialogPresent: dependencies.dialogPresent
                )
            }
        case .logicMidi:
            return { dependencies, params in
                let result = await MIDIDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache
                )
                if command == "import_file",
                   FeatureFlags.adr002TargetRef,
                   toolResultIsVerified(result) {
                    await dependencies.targetRegistry.bumpTopologyGeneration()
                }
                return result
            }
        case .logicTracks:
            return { dependencies, params in
                await TrackDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry,
                    dialogPresent: dependencies.dialogPresent,
                    // ADR-002 F5 — production dispatch supplies the live AX
                    // track-header reader so the target_ref mutation boundary
                    // fails closed on an out-of-band reorder.
                    liveTrackName: { AXLogicProElements.trackName(at: $0) },
                    liveTrackNames: dependencies.liveTrackNamesReader
                )
            }
        }
    }
}
