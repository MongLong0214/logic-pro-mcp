import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor ParameterPlanReadChannel: Channel {
    nonisolated let id: ChannelID = .accessibility
    let gate: VerifiedOpGate
    let fault: String
    let registry: TargetRegistry?
    var calls: [(String, [String: String])] = []
    init(gate: VerifiedOpGate, fault: String = "", registry: TargetRegistry? = nil) {
        self.gate = gate; self.fault = fault; self.registry = registry
    }
    func start() async throws {}
    func stop() async {}
    func healthCheck() async -> ChannelHealth { .healthy() }
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        calls.append((operation, params))
        #expect(operation == "plugin.get_param_verified")
        #expect(params["value"] == nil)
        let acquired = gate.tryAcquire()
        #expect(!acquired, "The entire plan must retain the existing verified UI lease")
        if acquired { gate.release() }
        let param = params["param"] ?? ""
        if fault == "unreadable", param == "threshold" {
            return .error(HonestContract.encodeV2StateC(error: .readbackUnavailable, extras: [
                "parameter_read_status": "unreadable", "write_attempted": false,
                "plugin_view_restore_observed": false,
            ]))
        }
        let changed = fault == "external_edit" && calls.count > 2
        if fault == "context_lost", calls.count == 3, let registry { await registry.bumpTopologyGeneration() }
        let observedRaw: Any
        let rawUnit: String
        let observedDisplay: String
        switch param {
        case "threshold":
            observedRaw = changed ? 52 : 51
            rawUnit = "normalized"
            observedDisplay = "51 %"
        case "ratio":
            observedRaw = 18
            rawUnit = "raw_ax_value"
            observedDisplay = "2.1:1"
        default:
            observedRaw = true
            rawUnit = "boolean"
            observedDisplay = "On"
        }
        return .success(HonestContract.encodeV2StateA(extras: [
            "operation": "logic_plugins.get_param_verified", "param": param,
            "target_identity": ["track_index": 0, "insert": 6, "plugin_id": "logic.stock.effect.compressor"],
            "parameter_read_status": "read", "observation_scope": "current_insert_parameter",
            "observed_raw": observedRaw, "raw_unit": rawUnit, "observed_display": observedDisplay,
            "verify_source": "ax_plugin_window", "write_attempted": false,
            "plugin_view_restore_observed": true,
            "verified": fault != "unverified",
        ]))
    }
}

@Suite(.serialized)
struct Issue955SupportedParameterPlanTests {
    private func request(_ param: String, _ value: Value, _ unit: String) -> Value {
        .object(["param": .string(param), "value": value, "unit": .string(unit)])
    }

    private func fixture(fault: String = "") async -> (StateCache, TargetRegistry, TargetReference, ChannelRouter, ParameterPlanReadChannel, VerifiedOpGate) {
        let cache = StateCache(), registry = TargetRegistry(), router = ChannelRouter(), gate = VerifiedOpGate()
        let project = ProjectInfo(name: "Parameter plan fixture", filePath: "/tmp/lpm-parameter-plan.logicx")
        await cache.updateProject(project)
        await cache.updateTracks([TrackState(id: 0, name: "Plan track", type: .audio)])
        let snapshot = await registry.currentSnapshot
        _ = await registry.snapshotForObservedProject(project, ifCurrent: snapshot, stoppingWhen: { false })
        let descriptor = TargetDescriptor(trackIndex: 0, trackName: "Plan track")
        let reference = await registry.bind(kind: .pluginInsert, descriptor: descriptor,
            fingerprint: TargetRefResolver.pluginInsertFingerprint(descriptor: descriptor, insert: 6,
                pluginIdentity: "logic.stock.effect.compressor"))
        let channel = ParameterPlanReadChannel(gate: gate, fault: fault, registry: registry)
        await router.register(channel)
        return (cache, registry, reference, router, channel, gate)
    }

    @Test func parameterPlanIsRegisteredReadOnlyWithExactReferenceAndRequestedSubset() throws {
        let spec = try #require(OperationRegistry.spec(tool: "logic_plugins", command: "plan_parameter_changes"))
        #expect(spec.mutability == .readOnly)
        #expect(spec.allowedParams.contains("target_ref"))
        #expect(spec.allowedParams.contains("changes"))
        #expect(!spec.allowedParams.contains("mode"))
        #expect(!spec.allowedParams.contains("confirmation"))
        let description = try #require(PluginsDispatcher.tool.description)
        #expect(description.contains("plan_parameter_changes"))
    }

    @Test func parameterPlanReadsBeforeValuesAndReturnsScopedDeterministicDiffWithoutWriting() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, channel, gate) = await fixture()
            // A real existing B0 dispatch is the fixture's positive control.
            let control = await PluginsDispatcher.handle(verifiedGate: gate, command: "get_param_verified",
                params: ["target_ref": .string(reference.rawValue), "param": "threshold"],
                router: router, cache: cache, targetRegistry: registry)
            #expect(try #require(sharedJSONObject(sharedToolText(control)))["observed_raw"] as? Int == 51)
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([
                    request("threshold", .int(38), "normalized"), request("limiter_on", .int(1), "boolean"),
                ])], router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(object["state"] as? String == "A")
            #expect(object["observation_scope"] as? String == "requested_supported_subset")
            #expect(object["target_ref"] as? String == reference.rawValue)
            #expect(try #require(object["complete"] as? Bool))
            #expect(!((try #require(object["write_attempted"] as? Bool))))
            let entries = try #require(object["entries"] as? [[String: Any]])
            #expect(entries.count == 2)
            #expect(entries[0]["param"] as? String == "limiter_on")
            #expect(entries[0]["status"] as? String == "unchanged")
            #expect(entries[1]["param"] as? String == "threshold")
            #expect(entries[1]["observed_before"] as? Double == 51)
            #expect(entries[1]["requested_value"] as? Double == 38)
            #expect(entries[1]["delta"] as? Double == -13)
            #expect(entries[1]["status"] as? String == "change")
            #expect(await channel.calls.count == 5) // control + two complete observation sweeps
            #expect(gate.tryAcquire())
            gate.release()
        }
    }

    @Test func parameterPlanCanDiffAReadOnlyScalarWithoutGrantingApplicationAuthority() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, channel, gate) = await fixture()
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([
                    request("ratio", .int(25), "raw_ax_value"),
                ])], router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(object["state"] as? String == "A")
            #expect(try #require(object["complete"] as? Bool))
            #expect(!((try #require(object["application_authorized"] as? Bool))))
            #expect(!((try #require(object["write_attempted"] as? Bool))))
            let entry = try #require((object["entries"] as? [[String: Any]])?.first)
            #expect(entry["param"] as? String == "ratio")
            #expect(entry["raw_unit"] as? String == "raw_ax_value")
            #expect(entry["observed_before"] as? Double == 18)
            #expect(entry["requested_value"] as? Double == 25)
            #expect(entry["delta"] as? Double == 7)
            #expect(entry["status"] as? String == "change")
            #expect(await channel.calls.count == 2)
            #expect(gate.tryAcquire())
            gate.release()
        }
    }

    @Test(arguments: ["missing_unit", "out_of_range", "extra_field", "duplicate"])
    func invalidLaterChangeRefusesWholePlanBeforeAnyRead(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, channel, gate) = await fixture()
            let bad: Value
            switch fault {
            case "missing_unit": bad = .object(["param": "limiter_on", "value": .int(1)])
            case "out_of_range": bad = request("limiter_on", .int(2), "boolean")
            case "extra_field": bad = .object(["param": "limiter_on", "value": .int(1), "unit": "boolean", "apply": true])
            default: bad = request("threshold", .int(25), "normalized")
            }
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([request("threshold", .int(38), "normalized"), bad])],
                router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(object["state"] as? String == "C")
            #expect(!((try #require(object["complete"] as? Bool))))
            #expect(try #require(object["entries"] as? [[String: Any]]).count == 2)
            #expect(await channel.calls.isEmpty)
        }
    }

    @Test func planPreservesUnsupportedUnknownAndMissingFieldsRatherThanInventingCompleteness() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, channel, gate) = await fixture()
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([
                    request("gain", .int(1), "normalized"), request("not_a_parameter", .int(1), "raw_ax_value"),
                    .object(["value": .int(1), "unit": "boolean"]),
                ])], router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            let entries = try #require(object["entries"] as? [[String: Any]])
            #expect(entries.count == 3)
            #expect(Set(entries.compactMap { $0["status"] as? String }) == ["unsupported", "unknown_parameter", "invalid_request"])
            #expect(!((try #require(object["complete"] as? Bool))))
            #expect(await channel.calls.isEmpty)
        }
    }

    @Test(arguments: ["unreadable", "external_edit"])
    func incompleteOrChangedReadDoesNotProduceACompleteBeforeState(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, channel, gate) = await fixture(fault: fault)
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([
                    request("threshold", .int(38), "normalized"), request("limiter_on", .int(1), "boolean"),
                ])], router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(!((try #require(object["complete"] as? Bool))))
            #expect(object["state"] as? String != "A")
            let entries = try #require(object["entries"] as? [[String: Any]])
            let threshold = try #require(entries.first { $0["param"] as? String == "threshold" })
            #expect(threshold["status"] as? String == (fault == "unreadable" ? "unreadable" : "unstable"))
            #expect(threshold["observed_before"] == nil)
            #expect(await channel.calls.allSatisfy { $0.0 == "plugin.get_param_verified" && $0.1["value"] == nil })
        }
    }

    @Test(arguments: ["unverified", "context_lost"])
    func partialPlanRetainsRequestsAndRejectsLostObservationAuthority(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, channel, gate) = await fixture(fault: fault)
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([
                    request("threshold", .int(38), "normalized"), request("limiter_on", .int(1), "boolean"),
                ])], router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(object["state"] as? String == "C")
            #expect(!((try #require(object["complete"] as? Bool))))
            let entries = try #require(object["entries"] as? [[String: Any]])
            #expect(entries.count == 2)
            #expect(entries.allSatisfy { $0["requested"] is [String: Any] })
            if fault == "context_lost" {
                #expect(await channel.calls.count == 3)
                #expect(entries.allSatisfy { $0["status"] as? String == "context_lost" && $0["observed_before"] == nil })
            }
            #expect(await channel.calls.allSatisfy { $0.0 == "plugin.get_param_verified" })
        }
    }

    @Test func planProtocolRejectsADiffThatDoesNotMatchItsPreservedRequest() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let (cache, registry, reference, router, _, gate) = await fixture()
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: ["target_ref": .string(reference.rawValue), "changes": .array([
                    request("limiter_on", .int(1), "boolean"),
                ])], router: router, cache: cache, targetRegistry: registry)
            var object = try #require(sharedJSONObject(sharedToolText(result)))
            let oracle = try #require(SemanticOracleTable.byOperationID[.pluginsPlanParameterChanges])
            #expect(oracle.independentReadbackDeferral != nil)
            let accepted: Bool = try #require(oracle.evaluate(
                responseData: JSONSerialization.data(withJSONObject: object), readbackData: Data()) as Bool?)
            #expect(accepted)
            var entries = try #require(object["entries"] as? [[String: Any]])
            entries[0]["requested_value"] = 0
            entries[0]["delta"] = -1
            entries[0]["status"] = "change"
            object["entries"] = entries
            let mutated: Bool = try #require(oracle.evaluate(
                responseData: JSONSerialization.data(withJSONObject: object), readbackData: Data()) as Bool?)
            #expect(!mutated)
        }
    }

    @Test(arguments: ["track", "insert", "plugin", "write_input", "disabled_refs", "busy"])
    func planRefusesWrongTargetsOrWriteInputsWithoutAcquiringAReader(fault: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(fault != "disabled_refs") {
            let (cache, registry, reference, router, channel, gate) = await fixture()
            var params: [String: Value] = ["target_ref": .string(reference.rawValue),
                "changes": .array([request("threshold", .int(38), "normalized")])]
            switch fault {
            case "track": params["track"] = .int(1)
            case "insert": params["insert"] = .int(7)
            case "plugin": params["plugin"] = "Gain"
            case "write_input": params["mode"] = "duplicate_applyback"
            case "busy": #expect(gate.tryAcquire())
            default: break
            }
            let result = await PluginsDispatcher.handle(verifiedGate: gate, command: "plan_parameter_changes",
                params: params, router: router, cache: cache, targetRegistry: registry)
            let object = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(object["state"] as? String == "C")
            #expect(await channel.calls.isEmpty)
            if fault == "busy" { gate.release() }
        }
    }
}
