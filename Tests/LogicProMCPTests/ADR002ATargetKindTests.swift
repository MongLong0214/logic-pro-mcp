import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor ADR002ATestChannel: Channel {
    nonisolated let id: ChannelID
    private let inventoryResponse: String?
    private(set) var executedOperations: [(String, [String: String])] = []

    init(id: ChannelID, inventoryResponse: String? = nil) {
        self.id = id
        self.inventoryResponse = inventoryResponse
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOperations.append((operation, params))
        if operation == "plugin.get_inventory", let inventoryResponse {
            return .success(inventoryResponse)
        }
        return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "ADR-002-a synthetic channel")
    }

    func operations() -> [(String, [String: String])] {
        executedOperations
    }
}

@Suite(.serialized)
struct ADR002ATargetKindTests {
    private func cacheWithTracks() async -> StateCache {
        let cache = StateCache()
        await cache.updateTracks([
            TrackState(id: 0, name: "Kick", type: .audio),
            TrackState(id: 1, name: "Snare", type: .audio),
            TrackState(id: 2, name: "Bass", type: .audio),
        ])
        return cache
    }

    private func router(
        inventoryResponse: String? = nil,
        ids: [ChannelID] = [.accessibility]
    ) async -> (ChannelRouter, [ADR002ATestChannel]) {
        let router = ChannelRouter()
        let channels = ids.map { ADR002ATestChannel(id: $0, inventoryResponse: inventoryResponse) }
        for channel in channels {
            await router.register(channel)
        }
        return (router, channels)
    }

    private func customPluginFingerprint(
        index: Int = 2,
        name: String = "Bass",
        insert: Int,
        plugin: String?
    ) -> String {
        let descriptor = TargetDescriptor(trackIndex: index, trackName: name)
        return "\(descriptor.fingerprint)|insert=\(insert)|plugin=\(plugin ?? "")"
    }

    private func object(_ result: CallTool.Result) -> [String: Any] {
        sharedJSONObject(sharedToolText(result)) ?? [:]
    }

    @Test
    func testMixerResourceEmitsStableFirstClassMixerStripRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cacheWithTracks()
            await cache.updateChannelStrips([ChannelStripState(trackIndex: 2)])
            let registry = TargetRegistry()
            let router = ChannelRouter()

            let first = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let second = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let firstStrip = try #require(
                (sharedJSONObject(sharedResourceText(first))?["strips"] as? [[String: Any]])?.first
            )
            let secondStrip = try #require(
                (sharedJSONObject(sharedResourceText(second))?["strips"] as? [[String: Any]])?.first
            )
            let reference = try #require(firstStrip["mixer_strip_ref"] as? String)
            #expect(reference == secondStrip["mixer_strip_ref"] as? String)
            #expect(reference.hasPrefix("mix_"))

            let tracks = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let trackReference = try #require(
                (sharedJSONObject(sharedResourceText(tracks))?["data"] as? [[String: Any]])?.first?["track_ref"] as? String
            )
            #expect(trackReference.hasPrefix("trk_"))
            #expect(reference != trackReference)

            let binding = await registry.resolve(TargetReference(rawValue: reference))
            #expect(binding?.kind == .mixerStrip)
            #expect(binding?.observedFingerprint == TargetDescriptor(trackIndex: 2, trackName: "Bass").fingerprint)

            let individualFirst = try await ResourceHandlers.read(
                uri: "logic://mixer/2",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let individualSecond = try await ResourceHandlers.read(
                uri: "logic://mixer/2",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let individualFirstStrip = try #require(
                sharedJSONObject(sharedResourceText(individualFirst))?["strip"] as? [String: Any]
            )
            let individualSecondStrip = try #require(
                sharedJSONObject(sharedResourceText(individualSecond))?["strip"] as? [String: Any]
            )
            #expect(individualFirstStrip["mixer_strip_ref"] as? String == reference)
            #expect(individualFirstStrip["mixer_strip_ref"] as? String == individualSecondStrip["mixer_strip_ref"] as? String)
        }
    }

    @Test
    func testPluginInventoryEmitsStableFirstClassInsertRefs() async throws {
        let inventory = HonestContract.encodeV2StateA(extras: [
            "operation": "logic_plugins.get_inventory",
            "track": 2,
            "complete": true,
            "plugins": [
                [
                    "insert": 0,
                    "read_status": "ok",
                    "occupied": true,
                    "name": "Gain",
                    "plugin_id": "logic.stock.effect.gain",
                    "bypassed": false,
                ],
                [
                    "insert": 1,
                    "read_status": "empty",
                    "occupied": false,
                    "name": NSNull(),
                    "plugin_id": NSNull(),
                    "bypassed": NSNull(),
                ],
            ],
        ])
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cacheWithTracks()
            let (router, channels) = await router(inventoryResponse: inventory)
            let registry = TargetRegistry()

            let first = await PluginsDispatcher.handle(
                command: "get_inventory",
                params: ["track": .int(2)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let second = await PluginsDispatcher.handle(
                command: "get_inventory",
                params: ["track": .int(2)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            let firstPlugins = try #require(object(first)["plugins"] as? [[String: Any]])
            let secondPlugins = try #require(object(second)["plugins"] as? [[String: Any]])
            #expect(firstPlugins.count == 2)
            for index in firstPlugins.indices {
                let reference = try #require(firstPlugins[index]["plugin_insert_ref"] as? String)
                #expect(reference.hasPrefix("ins_"))
                #expect(reference == secondPlugins[index]["plugin_insert_ref"] as? String)
            }
            let binding = await registry.resolve(
                TargetReference(rawValue: firstPlugins[0]["plugin_insert_ref"] as! String)
            )
            #expect(binding?.kind == .pluginInsert)
            #expect(binding?.observedFingerprint.contains("insert=0") == true)
            #expect(binding?.observedFingerprint.contains("logic.stock.effect.gain") == true)
            #expect((await channels[0].operations()).count == 2)
        }
    }

    @Test
    func testPluginInventorySkipsRefsWhenSnapshotTurnsStaleBeforeBind() async throws {
        let inventory = HonestContract.encodeV2StateA(extras: [
            "operation": "logic_plugins.get_inventory",
            "track": 2,
            "complete": true,
            "plugins": [[
                "insert": 0,
                "read_status": "ok",
                "occupied": true,
                "name": "Gain",
                "plugin_id": "logic.stock.effect.gain",
            ]],
        ])
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cacheWithTracks()
            let registry = TargetRegistry()
            let snapshot = await registry.currentSnapshot
            await registry.bumpTopologyGeneration()

            let result = await PluginsDispatcher.addInventoryTargetReferences(
                to: toolTextResult(inventory),
                cache: cache,
                targetRegistry: registry,
                targetSnapshot: snapshot
            )
            let plugins = try #require(object(result)["plugins"] as? [[String: Any]])
            #expect(plugins[0]["plugin_insert_ref"] == nil)
        }
    }

    @Test
    func testMixerStripAndPluginInsertRefsResolveAndEchoFingerprintEvidence() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cacheWithTracks()
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let mixerReference = await registry.bind(
                kind: .mixerStrip,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let pluginFingerprint = customPluginFingerprint(insert: 0, plugin: "logic.stock.effect.gain")
            let pluginReference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: pluginFingerprint
            )
            let emptyInsertFingerprint = customPluginFingerprint(insert: 1, plugin: nil)
            let emptyInsertReference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: emptyInsertFingerprint
            )
            let (mixerRouter, mixerChannels) = await router()

            let volume = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(mixerReference.rawValue), "value": .double(0.5)],
                router: mixerRouter,
                cache: cache,
                targetRegistry: registry
            )
            let volumeBody = object(volume)
            #expect(volume.isError == false)
            #expect(volumeBody["target_ref"] as? String == mixerReference.rawValue)
            #expect(volumeBody["target_fingerprint"] as? String == descriptor.fingerprint)
            let mixerOperationsAfterVolume = await mixerChannels[0].operations()
            #expect(mixerOperationsAfterVolume.first?.1 == ["index": "2", "volume": "0.5"])

            let pan = await MixerDispatcher.handle(
                command: "set_pan",
                params: ["target_ref": .string(mixerReference.rawValue), "value": .double(-0.25)],
                router: mixerRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(pan.isError == false)
            #expect(object(pan)["target_fingerprint"] as? String == descriptor.fingerprint)

            let pluginParams: [String: Value] = [
                "target_ref": .string(pluginReference.rawValue),
                "plugin": .string("logic.stock.effect.gain"),
                "param": .string("gain_db"),
                "value": .double(0.5),
                "unit": .string("db"),
                "mode": .string("duplicate_applyback"),
                "project_expected_path": .string("/tmp/project.logicx"),
            ]
            let (pluginRouter, pluginChannels) = await router()
            let setParam = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: pluginParams,
                router: pluginRouter,
                cache: cache,
                targetRegistry: registry
            )
            let setParamBody = object(setParam)
            #expect(setParam.isError == false)
            #expect(setParamBody["target_ref"] as? String == pluginReference.rawValue)
            #expect(setParamBody["target_fingerprint"] as? String == pluginFingerprint)
            let pluginOperationsAfterSetParam = await pluginChannels[0].operations()
            #expect(pluginOperationsAfterSetParam.first?.1["track"] == "2")
            #expect(pluginOperationsAfterSetParam.first?.1["insert"] == "0")

            let (insertRouter, insertChannels) = await router()
            let insert = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [
                    "target_ref": .string(emptyInsertReference.rawValue),
                    "plugin": .string("Gain"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: insertRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(insert.isError == false)
            #expect(object(insert)["target_fingerprint"] as? String == emptyInsertFingerprint)
            let insertOperations = await insertChannels[0].operations()
            #expect(insertOperations.first?.1["track"] == "2")
            #expect(insertOperations.first?.1["insert"] == "1")
        }
    }

    @Test
    func testPluginInsertRefTrackNameDelimiterCannotChangeInsertIndex() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = StateCache()
            await cache.updateTracks([
                TrackState(id: 2, name: "X|insert=7", type: .audio),
            ])
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "X|insert=7")
            let fingerprint = customPluginFingerprint(
                index: 2,
                name: "X|insert=7",
                insert: 0,
                plugin: "logic.stock.effect.gain"
            )
            let reference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: fingerprint
            )
            let (router, channels) = await router()

            let result = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: [
                    "target_ref": .string(reference.rawValue),
                    "plugin": .string("logic.stock.effect.gain"),
                    "param": .string("gain_db"),
                    "value": .double(0.5),
                    "unit": .string("db"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            #expect(result.isError == false)
            #expect((await channels[0].operations()).first?.1["insert"] == "0")
        }
    }

    @Test
    func testMalformedPluginInsertFingerprintReturnsNilWithoutTrap() {
        for fingerprint in [
            "0:-1:x|insert=0|plugin=G",
            "0:9223372036854775807:x|insert=0|plugin=G",
        ] {
            #expect(TargetDescriptor.pluginInsertIndex(from: fingerprint) == nil)
        }
    }

    @Test
    func testWrongKindReferencesFailClosedBeforeMixerPluginOrTrackWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cacheWithTracks()
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let mixerReference = await registry.bind(
                kind: .mixerStrip,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let pluginReference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: customPluginFingerprint(insert: 1, plugin: "logic.stock.effect.gain")
            )
            let (router, channels) = await router()

            let mixerResult = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(pluginReference.rawValue), "value": .double(0.5)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(mixerResult.isError == true)
            #expect(object(mixerResult)["error"] as? String == "stale_target_reference")

            let pluginResult = await PluginsDispatcher.handle(
                command: "set_param_verified",
                params: [
                    "target_ref": .string(mixerReference.rawValue),
                    "plugin": .string("logic.stock.effect.gain"),
                    "param": .string("gain_db"),
                    "value": .double(0.5),
                    "unit": .string("db"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(pluginResult.isError == true)
            #expect(object(pluginResult)["error"] as? String == "stale_target_reference")

            let insertResult = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [
                    "target_ref": .string(mixerReference.rawValue),
                    "plugin": .string("Gain"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(insertResult.isError == true)
            #expect(object(insertResult)["error"] as? String == "stale_target_reference")

            let trackResult = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(mixerReference.rawValue)],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(trackResult.isError == true)
            #expect(object(trackResult)["error"] as? String == "stale_target_reference")
            #expect((await channels[0].operations()).isEmpty)
        }
    }

    @Test
    func testNewKindReferenceAfterTopologyBumpFailsClosedWithoutWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cacheWithTracks()
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let reference = await registry.bind(
                kind: .mixerStrip,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let before = await cache.getTracks().map { "\($0.id)|\($0.name)|\($0.volume)" }
            await registry.bumpTopologyGeneration()
            let (staleMixerRouter, channels) = await router()
            let result = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: staleMixerRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == true)
            #expect(object(result)["error"] as? String == "stale_target_reference")
            #expect((await channels[0].operations()).isEmpty)
            #expect(await cache.getTracks().map { "\($0.id)|\($0.name)|\($0.volume)" } == before)

            let pluginRegistry = TargetRegistry()
            let pluginReference = await pluginRegistry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: customPluginFingerprint(insert: 1, plugin: "logic.stock.effect.gain")
            )
            await pluginRegistry.bumpTopologyGeneration()
            let (pluginRouter, pluginChannels) = await router()
            let insert = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [
                    "target_ref": .string(pluginReference.rawValue),
                    "plugin": .string("Gain"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: pluginRouter,
                cache: cache,
                targetRegistry: pluginRegistry
            )
            #expect(insert.isError == true)
            #expect(object(insert)["error"] as? String == "stale_target_reference")
            #expect((await pluginChannels[0].operations()).isEmpty)
        }
    }

    @Test
    func testFlagOffNewTargetRefSupplyFailsClosedWithoutWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = await cacheWithTracks()
            let registry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let reference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: customPluginFingerprint(insert: 1, plugin: "logic.stock.effect.gain")
            )
            let (router, channels) = await router()
            let result = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [
                    "target_ref": .string(reference.rawValue),
                    "plugin": .string("Gain"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == true)
            #expect(object(result)["error"] as? String == "target_ref_unavailable")
            #expect((await channels[0].operations()).isEmpty)
        }
    }

    @Test
    func testTrackDuplicateBumpsTopologyExactlyOnce() async {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let cache = await cacheWithTracks()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let (duplicateRouter, _) = await router(ids: [.accessibility, .midiKeyCommands, .cgEvent])
            let result = await TrackDispatcher.handle(
                command: "duplicate",
                params: ["index": .int(2)],
                router: duplicateRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await registry.currentTopologyGeneration == 1)

            let (staleRouter, staleChannels) = await router()
            let stale = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(reference.rawValue)],
                router: staleRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(stale.isError == true)
            #expect(object(stale)["error"] as? String == "stale_target_reference")
            #expect((await staleChannels[0].operations()).isEmpty)
        }
    }

    @Test
    func testTrackSetInstrumentBumpsTopologyExactlyOnceAfterStateA() async {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let cache = await cacheWithTracks()
            let (router, _) = await router()
            let result = await TrackDispatcher.handle(
                command: "set_instrument",
                params: ["index": .int(2), "path": .string("/tmp/instrument.patch")],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await registry.currentTopologyGeneration == 1)
        }
    }

    @Test
    func testStateASetInstrumentInvalidatesPriorMixerStripReference() async {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let cache = await cacheWithTracks()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let reference = await registry.bind(
                kind: .mixerStrip,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            let (mutationRouter, _) = await router()
            let mutation = await TrackDispatcher.handle(
                command: "set_instrument",
                params: ["index": .int(2), "path": .string("/tmp/instrument.patch")],
                router: mutationRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(mutation.isError == false)
            #expect(await registry.currentTopologyGeneration == 1)

            let (staleRouter, staleChannels) = await router()
            let stale = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(reference.rawValue), "value": .double(0.5)],
                router: staleRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(stale.isError == true)
            #expect(object(stale)["error"] as? String == "stale_target_reference")
            #expect((await staleChannels[0].operations()).isEmpty)
        }
    }

    @Test
    func testLegacyPluginInsertBumpsTopologyExactlyOnceAfterStateA() async {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let cache = await cacheWithTracks()
            let (router, _) = await router()
            let result = await MixerDispatcher.handle(
                command: "insert_plugin",
                params: [
                    "track": .int(2),
                    "slot": .int(1),
                    "plugin_name": .string("Gain"),
                    "confirmed": .bool(true),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )
            #expect(result.isError == false)
            #expect(await registry.currentTopologyGeneration == 1)
        }
    }

    @Test
    func testStateALegacyPluginInsertInvalidatesPriorPluginInsertReference() async {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let cache = await cacheWithTracks()
            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let reference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: customPluginFingerprint(insert: 1, plugin: "logic.stock.effect.gain")
            )
            let (mutationRouter, _) = await router()
            let mutation = await MixerDispatcher.handle(
                command: "insert_plugin",
                params: [
                    "track": .int(2),
                    "slot": .int(1),
                    "plugin_name": .string("Gain"),
                    "confirmed": .bool(true),
                ],
                router: mutationRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(mutation.isError == false)
            #expect(await registry.currentTopologyGeneration == 1)

            let (staleRouter, staleChannels) = await router()
            let stale = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [
                    "target_ref": .string(reference.rawValue),
                    "plugin": .string("Gain"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/project.logicx"),
                ],
                router: staleRouter,
                cache: cache,
                targetRegistry: registry
            )
            #expect(stale.isError == true)
            #expect(object(stale)["error"] as? String == "stale_target_reference")
            #expect((await staleChannels[0].operations()).isEmpty)
        }
    }
}
