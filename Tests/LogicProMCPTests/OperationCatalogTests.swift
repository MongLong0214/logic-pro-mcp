import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor CatalogSelectorProbeChannel: Channel {
    struct Invocation: Sendable, Equatable {
        let operation: String
        let params: [String: String]
    }

    nonisolated let id: ChannelID
    private var recorded: [Invocation] = []

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        recorded.append(Invocation(operation: operation, params: params))
        return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "catalog selector probe")
    }

    func invocations() -> [Invocation] {
        recorded
    }
}

@Suite("OperationCatalogTests", .serialized)
struct OperationCatalogTests {
    private static let uri = "logic://system/operations"

    // Plugin selectors are consumed after channel/AX routing, so deterministic headless proof is delegated to live qualification.
    private static let selectorsRequiringLiveQualificationByOperation: [OperationID: Set<String>] = [
        .pluginsGetInventory: ["index", "track"],
        .pluginsSetParamVerified: ["track"],
        .pluginsInsertVerified: ["track"],
    ]
    private static let selectorLiveQualificationReasonByOperation: [OperationID: String] = [
        .pluginsGetInventory: "AX inventory must expose the selected strip identity after ChannelRouter forwarding",
        .pluginsSetParamVerified: "AX apply-back must expose target_identity after verified preflight",
        .pluginsInsertVerified: "AX insert readback must expose target_identity after verified preflight",
    ]

    private func withOperationTraceEnvironment<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        let key = "LOGIC_MCP_ADR005_OPERATION_TRACE"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, "1", 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try await operation()
    }

    private static let legacyIgnoredParams: [OperationID: Set<String>] = [
        .tracksRecordSequence: ["instrument", "instrument_path"],
    ]
    private static let dispatcherRejectedParams: [OperationID: Set<String>] = [
        .midiPlaySequence: ["channel"],
        .midiSendSysEx: ["port"],
        .midiImportFile: ["port"],
        .midiListPorts: ["port"],
        .midiCreateVirtualPort: ["port"],
        .midiStepInput: ["port"],
        .midiMMCPlay: ["port"],
        .midiMMCStop: ["port"],
        .midiMMCRecord: ["port"],
        .midiMMCLocate: ["port"],
        .tracksRecordSequence: ["port"],
    ]
    private static let commandParams: [OperationID: Set<String>] = [
        .transportSetTempo: ["bpm", "tempo"],
        .transportGotoPosition: ["bar", "position"],
        .transportSetCycleRange: ["end", "start"],
        .mixerSetVolume: ["value", "volume"],
        .mixerSetPan: ["pan", "value"],
        .mixerSetMasterVolume: ["value", "volume"],
        .mixerSetPluginParam: ["insert", "param", "value"],
        .mixerInsertPlugin: [
            "confirmed", "insert", "name", "plugin", "plugin_name", "slot", "track_index",
        ],
        .navigateGotoBar: ["bar"],
        .navigateGotoMarker: ["name"],
        .navigateCreateMarker: ["name"],
        .navigateRenameMarker: ["name"],
        .navigateSetZoom: ["direction", "level"],
        .navigateToggleView: ["view"],
        .audioAnalyzeFile: [
            "expected_channel_count",
            "expected_duration_seconds",
            "expected_sample_rate",
            "max_decoded_frames",
            "max_duration_drift_seconds",
            "max_input_duration_seconds",
            "max_input_file_size_bytes",
            "max_peak_dbfs",
            "max_silence_ratio",
            "maximum_decoded_frames",
            "maximum_duration_drift_seconds",
            "maximum_input_duration_seconds",
            "maximum_input_file_size_bytes",
            "maximum_peak_dbfs",
            "maximum_silence_ratio",
            "min_duration_seconds",
            "min_file_size_bytes",
            "minimum_duration_seconds",
            "minimum_file_size_bytes",
            "near_silence_dbfs",
            "near_silence_threshold_dbfs",
            "output_root",
            "path",
        ],
        .systemListRecentTraces: ["limit"],
        .systemGetTrace: ["trace_id"],
        .systemClearTraces: ["confirmed"],
        .systemExportSupportBundle: ["dir"],
        .systemHelp: ["category"],
        .systemSagaPreflight: ["idempotency_key", "steps"],
        .systemSagaExecute: ["idempotency_key", "steps"],
        .systemSagaStatus: ["idempotency_key"],
        .systemSagaCancel: ["idempotency_key"],
        .pluginsGetInventory: ["track_index"],
        .pluginsSetParamVerified: [
            "insert", "mode", "param", "plugin", "plugin_id", "plugin_name",
            "project_expected_path", "unit", "value",
        ],
        .pluginsInsertVerified: [
            "insert", "mode", "plugin", "plugin_id", "plugin_name", "project_expected_path", "slot",
        ],
        .editQuantize: ["grid", "value"],
        .projectOpen: ["confirmed", "path"],
        .projectSaveAs: ["confirmed", "path"],
        .projectClose: ["confirmed", "saving"],
        .projectBounce: ["confirmed"],
        .projectQuit: ["confirmed"],
        .projectExportPlan: [
            "artifact", "artifacts", "collision_policy", "kind", "naming_policy",
            "outputRoot", "output_root", "path", "project", "projects",
        ],
        .projectExportRun: [
            "artifact", "artifacts", "collision_policy", "confirmed", "kind", "naming_policy",
            "outputRoot", "output_root", "path", "project", "projects",
        ],
        .projectExportResume: [
            "artifact", "artifacts", "collision_policy", "confirmed", "kind", "naming_policy",
            "outputRoot", "output_root", "path", "project", "projects",
        ],
        .projectCleanupApply: ["confirmed", "name", "names", "new_name", "stepId", "step_id"],
        .midiSendNote: ["channel", "duration_ms", "note", "port", "velocity"],
        .midiSendChord: ["channel", "duration_ms", "notes", "port", "velocity"],
        .midiSendCC: ["channel", "controller", "port", "value"],
        .midiSendProgramChange: ["channel", "port", "program"],
        .midiSendPitchBend: ["channel", "port", "value"],
        .midiSendAftertouch: ["channel", "port", "value"],
        .midiSendSysEx: ["bytes", "data"],
        .midiPlaySequence: ["notes", "port"],
        .midiImportFile: ["path"],
        .midiCreateVirtualPort: ["name"],
        .midiStepInput: ["duration", "note"],
        .midiMMCLocate: ["bar", "time"],
        .tracksSelect: ["name"],
        .tracksRename: ["name"],
        .tracksMute: ["enabled"],
        .tracksSolo: ["enabled"],
        .tracksArm: ["enabled"],
        .tracksRecordSequence: ["bar", "notes", "tempo"],
        .tracksSetAutomation: ["mode"],
        .tracksSetInstrument: ["category", "path", "preset"],
        .tracksScanLibrary: ["mode"],
        .tracksResolvePath: ["path"],
        .tracksScanPluginPresets: ["submenuOpenDelayMs"],
    ]

    private static func expectedAllowedParams(for spec: OperationSpec) -> Set<String> {
        var expected = spec.allowedParams.intersection(["index", "project_ref", "track"])
        if spec.target == .requiresStableTarget {
            expected.insert("target_ref")
        }
        return expected
            .union(commandParams[spec.id] ?? [])
            .union(legacyIgnoredParams[spec.id] ?? [])
    }

    private static func validSelectorParams(
        operationID: OperationID,
        key: String,
        value: Int
    ) -> [String: Value]? {
        var params: [String: Value] = [key: .int(value)]
        switch operationID {
        case .mixerSetVolume:
            params["value"] = .double(0.3)
        case .mixerSetPan:
            params["value"] = .double(0.25)
        case .mixerSetPluginParam:
            params["insert"] = .int(0)
            params["param"] = .int(0)
            params["value"] = .double(0.3)
        case .mixerInsertPlugin:
            params["slot"] = .int(0)
            params["plugin_name"] = .string("Gain")
            params["confirmed"] = .bool(true)
        case .navigateGotoMarker, .navigateDeleteMarker,
             .tracksSelect, .tracksDelete, .tracksDuplicate, .tracksArmOnly:
            break
        case .navigateRenameMarker, .tracksRename:
            params["name"] = .string("Selector Probe")
        case .tracksMute, .tracksSolo, .tracksArm:
            params["enabled"] = .bool(true)
        case .tracksSetAutomation:
            params["mode"] = .string("read")
        case .tracksSetInstrument:
            params["path"] = .string("/tmp/selector-probe.patch")
        default:
            return nil
        }
        return params
    }

    private func routedSelectorInvocations(
        spec: OperationSpec,
        key: String,
        value: Int
    ) async throws -> [CatalogSelectorProbeChannel.Invocation] {
        let router = ChannelRouter()
        let channels = ChannelID.allCases.map { CatalogSelectorProbeChannel(id: $0) }
        for channel in channels {
            await router.register(channel)
        }
        let cache = StateCache()
        await cache.updateTracks((0...8).map {
            TrackState(id: $0, name: "Track \($0)", type: .audio)
        })
        await cache.updateMarkers([
            MarkerState(id: 1, name: "Marker 1", position: "1.1.1.1"),
            MarkerState(id: 7, name: "Marker 7", position: "7.1.1.1"),
        ])
        let params = try #require(
            Self.validSelectorParams(operationID: spec.id, key: key, value: value),
            "\(spec.id.rawValue).\(key) requires an explicit valid-selector fixture"
        )
        let dependencies = HandlerDependencies(
            router: router,
            cache: cache,
            targetRegistry: TargetRegistry(),
            poller: StatePoller(
                axChannel: AccessibilityChannel(),
                cache: cache,
                runtime: .fastTest
            ),
            dialogPresent: { false },
            supportBundleExporter: nil
        )
        let handler = try #require(OperationHandlerRegistry.handler(for: spec.id))
        _ = await handler(dependencies, params)

        var invocations: [CatalogSelectorProbeChannel.Invocation] = []
        for channel in channels {
            invocations.append(contentsOf: await channel.invocations())
        }
        return invocations
    }

    private static func selectorEvidence(
        operationID: OperationID,
        invocations: [CatalogSelectorProbeChannel.Invocation]
    ) -> String? {
        if operationID == .navigateGotoMarker {
            return invocations.first { $0.operation == "transport.goto_position" }?
                .params["position"]
        }
        return invocations.lazy.compactMap { invocation in
            invocation.params["index"] ?? invocation.params["track"]
        }.first
    }

    private static func expectedSelectorEvidence(operationID: OperationID, value: Int) -> String {
        operationID == .navigateGotoMarker ? "\(value).1.1.1" : String(value)
    }

    private static func wire(_ value: Mutability) -> String {
        switch value {
        case .mutating: "mutating"
        case .readOnly: "read_only"
        }
    }

    private static func wire(_ value: TargetPolicy) -> String {
        switch value {
        case .none: "none"
        case .requiresStableTarget: "requires_stable_target"
        }
    }

    private static func wire(_ value: ConfirmationPolicy) -> String {
        switch value {
        case .none: "none"
        case .l1: "l1"
        case .l2: "l2"
        case .l3: "l3"
        }
    }

    private static func wire(_ value: VerificationPolicy) -> String {
        switch value {
        case .none: "none"
        case .readbackRequired: "readback_required"
        case .bestEffort: "best_effort"
        }
    }

    private static func wire(_ value: RetryPolicy) -> String {
        switch value {
        case .idempotent: "idempotent"
        case .beforeWriteBoundaryOnly: "before_write_boundary_only"
        case .neverAutomatic: "never_automatic"
        }
    }

    private static func wire(_ value: DeadlineClass) -> String {
        switch value {
        case .short: "short"
        case .medium: "medium"
        case .long: "long"
        }
    }

    private static func wire(_ value: AvailabilityPolicy) -> String {
        switch value {
        case .defaultInstall: "default_install"
        case .requiresProfile: "requires_profile"
        case .requiresKeyBinding: "requires_key_binding"
        case .experimental: "experimental"
        case .unsupported: "unsupported"
        }
    }

    @Test("trace commands use the registered strict MCP path")
    func traceCommandsUseRegisteredStrictMCPPath() async throws {
        let handlers = await LogicProServer().makeHandlers()

        try await withOperationTraceEnvironment {
            await OperationTraceStore.shared.clear()
            do {
                let expectedSpecs: [(String, String, Set<String>, ConfirmationPolicy)] = [
                    ("list_recent_traces", "system.list_recent_traces", ["limit"], .none),
                    ("get_trace", "system.get_trace", ["trace_id"], .none),
                    ("clear_traces", "system.clear_traces", ["confirmed"], .l2),
                ]
                #expect(OperationRegistry.specs.count == 107)
                for (command, operationID, allowedParams, confirmation) in expectedSpecs {
                    let spec = OperationRegistry.spec(tool: "logic_system", command: command)
                    #expect(spec?.id.rawValue == operationID, "\(command) must have one public spec")
                    #expect(spec?.mutability == .readOnly, "\(command) must bypass mutation gating")
                    #expect(spec?.confirmation == confirmation)
                    #expect(spec?.deadline == .short)
                    #expect(spec?.verification == VerificationPolicy.none)
                    #expect(spec?.allowedParams == allowedParams)
                    #expect(OperationHandlerRegistry.handler(
                        tool: "logic_system",
                        command: command
                    ) != nil)
                    #expect(OperationHandlerRegistry.fallbackHandler(
                        tool: "logic_system",
                        command: command
                    ) != nil)
                }

                let traceID = await OperationTraceStore.shared.start(operationID: "test.trace.seed")
                await OperationTraceStore.shared.record(traceID, phase: .inputValidated)
                await OperationTraceStore.shared.complete(traceID)

                let strictCases: [(String, [String: Value], [String])] = [
                    ("list_recent_traces", ["limit": .int(1)], ["limit"]),
                    ("get_trace", ["trace_id": .string(traceID.rawValue)], ["trace_id"]),
                    ("clear_traces", ["confirmed": .bool(true)], ["confirmed"]),
                ]
                for (command, validParams, allowedParams) in strictCases {
                    var params = validParams
                    params["__unknown"] = .bool(true)
                    let rejected = await handlers.callTool(.init(
                        name: "logic_system",
                        arguments: [
                            "command": .string(command),
                            "params": .object(params),
                        ]
                    ))
                    let body = sharedJSONObject(sharedToolText(rejected)) ?? [:]
                    #expect(rejected.isError == true, "\(command) must reject unknown keys")
                    #expect(body["state"] as? String == "C")
                    #expect(body["error"] as? String == "invalid_params")
                    #expect(body["unknown_params"] as? [String] == ["__unknown"])
                    #expect(body["allowed_params"] as? [String] == allowedParams)
                    #expect(body["write_attempted"] as? Bool == false)
                }

                let listed = await handlers.callTool(.init(
                    name: "logic_system",
                    arguments: [
                        "command": .string("list_recent_traces"),
                        "params": .object(["limit": .int(1)]),
                    ]
                ))
                let listedBody = sharedJSONObject(sharedToolText(listed)) ?? [:]
                let traces = listedBody["traces"] as? [[String: Any]]
                #expect(listed.isError != true)
                #expect(traces?.count == 1)
                #expect(traces?.first?["trace_id"] as? String == traceID.rawValue)

                let fetched = await handlers.callTool(.init(
                    name: "logic_system",
                    arguments: [
                        "command": .string("get_trace"),
                        "params": .object(["trace_id": .string(traceID.rawValue)]),
                    ]
                ))
                let fetchedBody = sharedJSONObject(sharedToolText(fetched)) ?? [:]
                #expect(fetched.isError != true)
                #expect(fetchedBody["trace_id"] as? String == traceID.rawValue)
                #expect(fetchedBody["operation_id"] as? String == "test.trace.seed")
                #expect((fetchedBody["events"] as? [[String: Any]])?.count == 1)

                let malformed = await handlers.callTool(.init(
                    name: "logic_system",
                    arguments: [
                        "command": .string("get_trace"),
                        "params": .object(["trace_id": .string("bad")]),
                    ]
                ))
                let malformedBody = sharedJSONObject(sharedToolText(malformed)) ?? [:]
                #expect(malformed.isError == true)
                #expect(malformedBody["state"] as? String == "C")
                #expect(malformedBody["error"] as? String == "invalid_params")
                #expect((malformedBody["hint"] as? String)?.contains("malformed") == true)

                let unconfirmedCases: [[String: Value]] = [
                    [:],
                    ["confirmed": .bool(false)],
                    ["confirmed": .string("true")],
                ]
                for params in unconfirmedCases {
                    let unconfirmed = await handlers.callTool(.init(
                        name: "logic_system",
                        arguments: [
                            "command": .string("clear_traces"),
                            "params": .object(params),
                        ]
                    ))
                    let unconfirmedBody = sharedJSONObject(sharedToolText(unconfirmed)) ?? [:]
                    #expect(unconfirmed.isError == true)
                    #expect(unconfirmedBody["state"] as? String == "C")
                    #expect(unconfirmedBody["error"] as? String == "invalid_params")
                    #expect((unconfirmedBody["hint"] as? String)?.contains("confirmed") == true)
                    #expect(await OperationTraceStore.shared.trace(traceID) != nil)
                }

                let cleared = await handlers.callTool(.init(
                    name: "logic_system",
                    arguments: [
                        "command": .string("clear_traces"),
                        "params": .object(["confirmed": .bool(true)]),
                    ]
                ))
                let clearedBody = sharedJSONObject(sharedToolText(cleared)) ?? [:]
                #expect(cleared.isError != true)
                #expect(clearedBody["success"] as? Bool == true)
                #expect(await OperationTraceStore.shared.trace(traceID) == nil)
            } catch {
                await OperationTraceStore.shared.clear()
                throw error
            }
            await OperationTraceStore.shared.clear()
        }
    }

    @Test("strict: advertised selectors use dispatcher proof or explicit live qualification")
    func advertisedSelectorsUseDispatcherProofOrLiveQualification() async throws {
        let handlers = await LogicProServer().makeHandlers()
        let advertised = OperationRegistry.specs.flatMap { spec in
            ["index", "track"].compactMap { key -> (OperationSpec, String)? in
                spec.allowedParams.contains(key) ? (spec, key) : nil
            }
        }
        let probes = advertised.filter {
            !(Self.selectorsRequiringLiveQualificationByOperation[$0.0.id]?.contains($0.1) ?? false)
        }

        #expect(advertised.filter { $0.1 == "index" }.count == 17)
        #expect(advertised.filter { $0.1 == "track" }.count == 16)
        #expect(advertised.count == 33)
        #expect(probes.filter { $0.1 == "index" }.count == 16)
        #expect(probes.filter { $0.1 == "track" }.count == 13)
        #expect(probes.count == 29)
        #expect(Self.selectorsRequiringLiveQualificationByOperation.values.reduce(0) { $0 + $1.count } == 4)
        #expect(
            Set(Self.selectorLiveQualificationReasonByOperation.keys)
                == Set(Self.selectorsRequiringLiveQualificationByOperation.keys)
        )

        for (id, keys) in Self.selectorsRequiringLiveQualificationByOperation {
            let spec = OperationRegistry.specs.first { $0.id == id }
            #expect(spec != nil, "\(id.rawValue) must remain registered")
            if let spec {
                #expect(spec.allowedParams.intersection(["index", "track"]) == keys)
            }
            let reason = try #require(Self.selectorLiveQualificationReasonByOperation[id])
            #expect(reason.contains("AX"))
        }

        for (spec, key) in probes {
            let result = await handlers.callTool(.init(
                name: spec.tool.rawValue,
                arguments: [
                    "command": .string(spec.command),
                    "params": .object([key: .string("xx")]),
                ]
            ))
            let body = try #require(
                sharedJSONObject(sharedToolText(result)),
                "\(spec.id.rawValue) malformed \(key) response must be typed JSON"
            )
            #expect(result.isError == true, "\(spec.id.rawValue) did not reject malformed \(key)")
            #expect(body["state"] as? String == "C", "\(spec.id.rawValue).\(key)")
            #expect(body["error"] as? String == "invalid_params", "\(spec.id.rawValue).\(key)")
            #expect(
                (body["hint"] as? String)?.contains(key) == true,
                "\(spec.id.rawValue) response did not identify malformed \(key)"
            )
        }

        for (spec, key) in probes {
            let first = try await routedSelectorInvocations(spec: spec, key: key, value: 1)
            let second = try await routedSelectorInvocations(spec: spec, key: key, value: 7)
            let firstEvidence = Self.selectorEvidence(operationID: spec.id, invocations: first)
            let secondEvidence = Self.selectorEvidence(operationID: spec.id, invocations: second)
            #expect(
                firstEvidence == Self.expectedSelectorEvidence(operationID: spec.id, value: 1),
                "\(spec.id.rawValue).\(key) did not forward selector 1"
            )
            #expect(
                secondEvidence == Self.expectedSelectorEvidence(operationID: spec.id, value: 7),
                "\(spec.id.rawValue).\(key) did not forward selector 7"
            )
            #expect(
                first != second,
                "\(spec.id.rawValue).\(key) distinct valid selectors routed identically"
            )
        }
    }

    @Test("strict: registered command rejects unknown params as typed State C")
    func strictUnknownParamsRejectedBeforeDispatch() async throws {
        let handlers = await LogicProServer().makeHandlers()
        let result = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_system",
                arguments: [
                    "command": .string("help"),
                    "params": .object([
                        "__unknown_b": .string("ignored today"),
                        "__unknown_a": .string("ignored today"),
                    ]),
                ]
            )
        )

        #expect(result.isError == true)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "C")
        #expect(body["error"] as? String == "invalid_params")
        #expect(body["unknown_params"] as? [String] == ["__unknown_a", "__unknown_b"])

        let malformed = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_system",
                arguments: [
                    "command": .string("help"),
                    "params": .string("not-an-object"),
                ]
            )
        )
        let malformedBody = try #require(sharedJSONObject(sharedToolText(malformed)))
        #expect(malformed.isError == true)
        #expect(malformedBody["state"] as? String == "C")
        #expect(malformedBody["error"] as? String == "invalid_params")
        #expect(malformedBody["expected_params_type"] as? String == "object")

        for key in ["index", "target_ref", "track"] {
            let rejected = try #require(
                LogicProServer.strictParamValidationResult(
                    tool: ToolID.logicTransport.rawValue,
                    command: "goto_position",
                    params: [key: .string("not consumed")]
                )
            )
            let rejectedBody = try #require(sharedJSONObject(sharedToolText(rejected)))
            #expect(rejected.isError == true)
            #expect(rejectedBody["state"] as? String == "C")
            #expect(rejectedBody["error"] as? String == "invalid_params")
            #expect(rejectedBody["unknown_params"] as? [String] == [key])
            #expect(rejectedBody["write_attempted"] as? Bool == false)
        }
    }

    @Test("strict: target_ref allowance exactly follows target policy")
    func targetRefAllowanceMatchesTargetPolicy() async throws {
        let handlers = await LogicProServer().makeHandlers()

        for spec in OperationRegistry.specs {
            let requiresTarget = spec.target == .requiresStableTarget
            #expect(spec.allowedParams.contains("target_ref") == requiresTarget, "\(spec.id.rawValue)")

            if requiresTarget {
                #expect(
                    LogicProServer.strictParamValidationResult(
                        tool: spec.tool.rawValue,
                        command: spec.command,
                        params: ["target_ref": .string("trk_probe")]
                    ) == nil,
                    "\(spec.id.rawValue)"
                )
            } else {
                let rejected: CallTool.Result
                if OperationRegistry.strictParamValidationOptOuts.contains(spec.id) {
                    rejected = await handlers.callTool(.init(
                        name: spec.tool.rawValue,
                        arguments: [
                            "command": .string(spec.command),
                            "params": .object(["target_ref": .string("trk_probe")]),
                        ]
                    ))
                } else {
                    rejected = try #require(LogicProServer.strictParamValidationResult(
                        tool: spec.tool.rawValue,
                        command: spec.command,
                        params: ["target_ref": .string("trk_probe")]
                    ))
                }
                let body = try #require(sharedJSONObject(sharedToolText(rejected)))
                #expect(rejected.isError == true, "\(spec.id.rawValue)")
                #expect(body["state"] as? String == "C", "\(spec.id.rawValue)")
                #expect(body["error"] as? String == "invalid_params", "\(spec.id.rawValue)")
                #expect(body["write_attempted"] as? Bool == false, "\(spec.id.rawValue)")
                if !OperationRegistry.strictParamValidationOptOuts.contains(spec.id) {
                    #expect(body["unknown_params"] as? [String] == ["target_ref"], "\(spec.id.rawValue)")
                }
            }
        }
    }

    @Test("strict: every registered operation rejects unknown keys and accepts its pinned keys")
    func strictRegistryWideInvariant() throws {
        #expect(OperationRegistry.specs.count == 107)
        #expect(Set(OperationRegistry.specs.map(\.id)) == Set(OperationID.allCases))

        for spec in OperationRegistry.specs {
            let expected = Self.expectedAllowedParams(for: spec)
            #expect(spec.allowedParams == expected, "\(spec.id.rawValue)")

            // Opt-out operations (the saga surfaces) bypass the generic gate and
            // validate params in their own dispatcher, so the generic gate must
            // return nil for them regardless of the params.
            if OperationRegistry.strictParamValidationOptOuts.contains(spec.id) {
                #expect(
                    LogicProServer.strictParamValidationResult(
                        tool: spec.tool.rawValue,
                        command: spec.command,
                        params: ["__unknown_param": .string("reject")]
                    ) == nil,
                    "\(spec.id.rawValue) opt-out should bypass the generic gate"
                )
                continue
            }

            for key in expected {
                #expect(
                    LogicProServer.strictParamValidationResult(
                        tool: spec.tool.rawValue,
                        command: spec.command,
                        params: [key: .string("fixture")]
                    ) == nil,
                    "\(spec.id.rawValue) rejected allowed param \(key)"
                )
            }

            for key in Self.dispatcherRejectedParams[spec.id] ?? [] {
                #expect(
                    LogicProServer.strictParamValidationResult(
                        tool: spec.tool.rawValue,
                        command: spec.command,
                        params: [key: .string("targeted dispatcher error")]
                    ) == nil,
                    "\(spec.id.rawValue) did not preserve dispatcher rejection for \(key)"
                )
            }

            let result = try #require(
                LogicProServer.strictParamValidationResult(
                    tool: spec.tool.rawValue,
                    command: spec.command,
                    params: ["__unknown_param": .string("reject")]
                )
            )
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "C", "\(spec.id.rawValue)")
            #expect(body["error"] as? String == "invalid_params", "\(spec.id.rawValue)")
            #expect(body["unknown_params"] as? [String] == ["__unknown_param"], "\(spec.id.rawValue)")
            #expect(body["allowed_params"] as? [String] == expected.sorted(), "\(spec.id.rawValue)")
        }
    }

    @Test("compatibility: strict opt-out and legacy ignored lists are explicit")
    func compatibilityListsArePinned() {
        // The saga surfaces opt out of the generic strict-param gate and do
        // their own richer (journal_scope-carrying) validation in SystemDispatcher.
        #expect(OperationRegistry.strictParamValidationOptOuts == [
            .systemSagaPreflight, .systemSagaExecute, .systemSagaStatus, .systemSagaCancel,
        ])
        #expect(OperationRegistry.legacyIgnoredParamsByOperation == Self.legacyIgnoredParams)
        #expect(OperationRegistry.dispatcherRejectedParamsByOperation == Self.dispatcherRejectedParams)
        let actualIndex = Set(OperationRegistry.specs.filter {
            $0.allowedParams.contains("index")
        }.map(\.id))
        let actualTrack = Set(OperationRegistry.specs.filter {
            $0.allowedParams.contains("track")
        }.map(\.id))
        let actualTargetRef = Set(OperationRegistry.specs.filter {
            $0.allowedParams.contains("target_ref")
        }.map(\.id))
        let targetBearing = Set(OperationRegistry.specs.filter {
            $0.target == .requiresStableTarget
        }.map(\.id))
        #expect(actualIndex.count == 17)
        #expect(actualTrack.count == 16)
        #expect(actualTargetRef == targetBearing)
        #expect(actualTargetRef.count == 14)
        for spec in OperationRegistry.specs {
            #expect(
                spec.allowedParams.isDisjoint(
                    with: Self.dispatcherRejectedParams[spec.id] ?? []
                ),
                "\(spec.id.rawValue) catalogs a dispatcher-rejected key as allowed"
            )
        }
    }

    @Test("compatibility: strict flag defaults on and flag-off preserves legacy pass-through")
    func compatibilityStrictFlagOff() async {
        #expect(FeatureFlags.adr003StrictParams)
        let handlers = await LogicProServer().makeHandlers()

        await FeatureFlags.withAdr003StrictParamsForTests(false) {
            #expect(
                LogicProServer.strictParamValidationResult(
                    tool: ToolID.logicSystem.rawValue,
                    command: "help",
                    params: ["__unknown_param": .string("legacy")]
                ) == nil
            )
        }

        let flag = "LOGIC_MCP_ADR003_STRICT_PARAMS"
        let previousFlag = getenv(flag).map { String(cString: $0) }
        setenv(flag, "0", 1)
        let legacyGoto = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_transport",
                arguments: [
                    "command": .string("goto_position"),
                    "params": .object([
                        "position": .string("1.1.1.1"),
                        "index": .int(0),
                    ]),
                ]
            )
        )
        if let previousFlag {
            setenv(flag, previousFlag, 1)
        } else {
            unsetenv(flag)
        }
        #expect(sharedToolText(legacyGoto).contains("unknown param(s): index"))

        await FeatureFlags.withAdr003StrictParamsForTests(true) {
            #expect(
                LogicProServer.strictParamValidationResult(
                    tool: ToolID.logicTracks.rawValue,
                    command: "record_sequence",
                    params: [
                        "instrument_path": .string("ignored:compatibility"),
                        "instrument": .string("ignored:compatibility"),
                    ]
                ) == nil
            )
        }

        let midiRejected = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_midi",
                arguments: [
                    "command": .string("play_sequence"),
                    "params": .object(["channel": .int(1)]),
                ]
            )
        )
        #expect(sharedToolText(midiRejected).contains("does not support top-level 'channel'"))

        let trackRejected = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_tracks",
                arguments: [
                    "command": .string("record_sequence"),
                    "params": .object(["port": .string("keycmd")]),
                ]
            )
        )
        #expect(sharedToolText(trackRejected).contains("port parameter not supported for record_sequence"))
    }

    @Test("catalog: exact URI reads the generated 107-operation catalog")
    func catalogReadsRegistryProjection() async throws {
        let result = try await ResourceHandlers.read(
            uri: Self.uri,
            cache: StateCache(),
            router: ChannelRouter()
        )
        let text = sharedResourceText(result)
        let body = try #require(sharedJSONObject(text))
        #expect(body["schema_version"] as? Int == 1)
        #expect(body["generated_at"] as? String != nil)
        #expect(body["operation_count"] as? Int == OperationRegistry.specs.count)
        let operations = try #require(body["operations"] as? [[String: Any]])
        #expect(operations.count == 107)
        #expect(text.contains("\n") == false)

        let ids = operations.compactMap { $0["id"] as? String }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == OperationRegistry.specs.count)

        let byID = Dictionary(uniqueKeysWithValues: operations.compactMap { row in
            (row["id"] as? String).map { ($0, row) }
        })
        for spec in OperationRegistry.specs {
            let row = try #require(byID[spec.id.rawValue], "missing \(spec.id.rawValue)")
            #expect(row["id"] as? String == spec.id.rawValue)
            #expect(row["tool"] as? String == spec.tool.rawValue)
            #expect(row["command"] as? String == spec.command)
            #expect(row["mutability"] as? String == Self.wire(spec.mutability))
            #expect(row["target"] as? String == Self.wire(spec.target))
            #expect(row["confirmation"] as? String == Self.wire(spec.confirmation))
            #expect(row["verification"] as? String == Self.wire(spec.verification))
            #expect(row["retry"] as? String == Self.wire(spec.retry))
            #expect(row["deadline"] as? String == Self.wire(spec.deadline))
            #expect(row["availability"] as? String == Self.wire(spec.availability))
            #expect(row["allowedParams"] as? [String] == spec.allowedParams.sorted())
            #expect(
                (row["allowedParams"] as? [String])?.contains("target_ref")
                    == (spec.target == .requiresStableTarget)
            )
            #expect(row["capability"] as? String == spec.capability.rawValue)
            #expect(
                row["dirtySections"] as? [String]
                    == spec.dirtySections.map(\.rawValue).sorted()
            )
            #expect(row.keys.sorted() == [
                "allowedParams", "availability", "capability", "command", "confirmation",
                "deadline", "dirtySections", "id", "mutability", "retry", "target",
                "tool", "verification",
            ])
        }

        let toolCommands = operations.compactMap { row -> String? in
            guard let tool = row["tool"] as? String, let command = row["command"] as? String else {
                return nil
            }
            return "\(tool):\(command)"
        }
        #expect(Set(toolCommands).count == OperationRegistry.specs.count)
    }

    @Test("catalog: exact URI is advertised only by resources/templates/list")
    func catalogUsesLiteralTemplateDiscoverySurface() async {
        let handlers = await LogicProServer().makeHandlers()
        let resources = await handlers.listResources(ListResources.Parameters())
        let templates = await handlers.listResourceTemplates(ListResourceTemplates.Parameters())

        #expect(!resources.resources.map(\.uri).contains(Self.uri))
        #expect(templates.templates.map(\.uriTemplate).filter { $0 == Self.uri }.count == 1)
    }

    @Test("unregistered commands stay rejected regardless of raw params")
    func unregisteredCommandRejectionIgnoresRawParams() async {
        let handlers = await LogicProServer().makeHandlers()
        let baseline = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_system",
                arguments: ["command": .string("__unknown__")]
            )
        )
        let withUnknownParams = await handlers.callTool(
            CallTool.Parameters(
                name: "logic_system",
                arguments: [
                    "command": .string("__unknown__"),
                    "params": .object(["__unknown_param": .string("preserve fallback")]),
                ]
            )
        )

        #expect(sharedToolText(withUnknownParams) == sharedToolText(baseline))
        #expect(withUnknownParams.isError == baseline.isError)
    }
}
