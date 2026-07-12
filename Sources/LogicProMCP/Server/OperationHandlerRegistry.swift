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

    init(
        router: ChannelRouter,
        cache: StateCache,
        targetRegistry: TargetRegistry,
        poller: StatePoller,
        dialogPresent: @escaping @Sendable () -> Bool,
        supportBundleExporter: SystemDispatcher.SupportBundleExporter?,
        sagaJournal: SagaJournal = SagaJournal(),
        mutationGate: LogicMutationGate? = nil
    ) {
        self.router = router
        self.cache = cache
        self.targetRegistry = targetRegistry
        self.poller = poller
        self.dialogPresent = dialogPresent
        self.supportBundleExporter = supportBundleExporter
        self.sagaJournal = sagaJournal
        self.mutationGate = mutationGate
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
        return makeHandler(tool: toolID, command: command)
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
                    targetRegistry: dependencies.targetRegistry
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
                    mutationGate: dependencies.mutationGate
                )
            }
        case .logicPlugins:
            return { dependencies, params in
                await PluginsDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry
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
                await ProjectDispatcher.handle(
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
                await MIDIDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache
                )
            }
        case .logicTracks:
            return { dependencies, params in
                await TrackDispatcher.handle(
                    command: command,
                    params: params,
                    router: dependencies.router,
                    cache: dependencies.cache,
                    targetRegistry: dependencies.targetRegistry,
                    dialogPresent: dependencies.dialogPresent
                )
            }
        }
    }
}
