import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("Issue 301 exact-instance Channel EQ state reader")
struct Issue301ChannelEQStateReaderTests {
    @Test func fullStateReadIsPublicReadOnlyAndHasNoWriteInputs() throws {
        let spec = try #require(OperationRegistry.spec(
            tool: "logic_plugins", command: "get_channel_eq_state_verified"
        ))
        #expect(spec.mutability == .readOnly)
        #expect(spec.verification == .readbackRequired)
        #expect(spec.allowedParams.contains("target_ref"))
        #expect(spec.allowedParams.contains("project_expected_path"))
        #expect(!spec.allowedParams.contains("value"))
        #expect(!spec.allowedParams.contains("mode"))
        #expect(ChannelRouter.routingTable["plugin.get_channel_eq_state_verified"] == [.accessibility])
    }

    @Test func publicReaderRefusesBareIndexWithoutRouting() async throws {
        let result = await PluginsDispatcher.handle(
            verifiedGate: VerifiedOpGate(), command: "get_channel_eq_state_verified",
            params: ["track": .int(0), "insert": .int(0)],
            router: ChannelRouter(), cache: StateCache()
        )
        let object = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(object["error"] as? String == "invalid_params")
    }

    @Test func stateReaderOracleRequiresEveryBandAndHonestRawDisplayScope() throws {
        let oracle = try #require(SemanticOracleTable.byOperationID[.pluginsGetChannelEQStateVerified])
        let fixture = try #require(SemanticOracleFixtures.byOperationID[.pluginsGetChannelEQStateVerified])
        #expect(oracle.evaluate(responseData: fixture.responseData, readbackData: fixture.readbackData) == true)
        for mutant in fixture.customMutants {
            #expect(oracle.evaluate(responseData: Data(mutant.response.utf8), readbackData: fixture.readbackData) == false)
        }
    }

    @Test func occupiedReferenceCorroborationAndSerializerRefuseBeforeRouting() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = StateCache()
            let project = ProjectInfo(name: "EQ test", filePath: "/tmp/lpm-301.logicx")
            await cache.updateProject(project)
            await cache.updateTracks([TrackState(id: 0, name: "EQ test", type: .audio)])
            let registry = TargetRegistry()
            let initial = await registry.currentSnapshot
            _ = await registry.snapshotForObservedProject(project, ifCurrent: initial, stoppingWhen: { false })
            let descriptor = TargetDescriptor(trackIndex: 0, trackName: "EQ test")
            let fingerprint = TargetRefResolver.pluginInsertFingerprint(
                descriptor: descriptor, insert: 0, pluginIdentity: "logic.stock.effect.channel_eq")
            let reference = await registry.bind(kind: .pluginInsert, descriptor: descriptor, fingerprint: fingerprint)
            let fixture = try #require(SemanticOracleFixtures.byOperationID[.pluginsGetChannelEQStateVerified])
            let channel = MockChannel(id: .accessibility, successEnvelope: fixture.response)
            let router = ChannelRouter()
            await router.register(channel)
            let gate = VerifiedOpGate()
            let control: [String: Value] = ["target_ref": .string(reference.rawValue)]
            func read(_ params: [String: Value]) async -> CallTool.Result {
                await PluginsDispatcher.handle(verifiedGate: gate, command: "get_channel_eq_state_verified",
                    params: params, router: router, cache: cache, targetRegistry: registry)
            }
            let first = try #require(sharedJSONObject(sharedToolText(await read(control))))
            #expect(first["state"] as? String == "A")
            #expect(first["target_ref"] as? String == reference.rawValue)
            #expect(first["target_fingerprint"] as? String == fingerprint)
            let requests: [([String: Value], String)] = [
                (["insert": .int(1)], "stale_target_reference"),
                (["track": .int(1)], "stale_target_reference"),
                (["plugin": .string("Compressor")], "stale_target_reference"),
                (["project_expected_path": .string("/tmp/wrong.logicx")], "project_identity_mismatch"),
                (["value": .int(240)], "invalid_params"),
                (["param": .string("low_shelf_frequency")], "invalid_params"),
            ]
            for (extra, expected) in requests {
                let answer = try #require(sharedJSONObject(sharedToolText(await read(control.merging(extra) { _, new in new }))))
                #expect(answer["state"] as? String == "C")
                #expect(answer["error"] as? String == expected)
            }
            #expect(await channel.executedOps.count == 1)
            #expect(gate.tryAcquire())
            let held = try #require(sharedJSONObject(sharedToolText(await read(control))))
            #expect(held["error"] as? String == "verified_op_in_progress")
            gate.release()
            let repeatRead = try #require(sharedJSONObject(sharedToolText(await read(control))))
            #expect(repeatRead["state"] as? String == "A")
            #expect(await channel.executedOps.count == 2)
            #expect(gate.tryAcquire())
            gate.release()
        }
    }
}
