import Foundation
import MCP
import Testing
@testable import LogicProMCP

private actor TargetReferenceChannel: Channel {
    nonisolated let id: ChannelID
    private let succeeds: Bool
    private(set) var executedOps: [(String, [String: String])] = []

    init(id: ChannelID, succeeds: Bool = true) {
        self.id = id
        self.succeeds = succeeds
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        guard succeeds else { return .error("synthetic failure") }
        return .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "target-reference synthetic channel")
    }
}

@Suite(.serialized)
struct TargetRegistryTests {
    private func descriptor(index: Int = 0, name: String = "Kick") -> TargetDescriptor {
        TargetDescriptor(trackIndex: index, trackName: name)
    }

    @Test
    func testBindingIsStableAndOpaque() async throws {
        let registry = TargetRegistry(serverSessionID: UUID())
        let descriptor = descriptor()

        let first = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
        let second = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )

        #expect(first == second)
        #expect(first.rawValue.hasPrefix("trk_"))
        #expect(UUID(uuidString: String(first.rawValue.dropFirst("trk_".count))) != nil)
        #expect(!first.rawValue.contains(descriptor.trackName))
        #expect(await registry.resolve(first) != nil)
    }

    @Test
    func testTopologyGenerationInvalidatesBinding() async {
        let registry = TargetRegistry(serverSessionID: UUID())
        let descriptor = descriptor()
        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )

        await registry.bumpTopologyGeneration()

        #expect(await registry.resolve(reference) == nil)
        #expect(await registry.currentTopologyGeneration == 1)
    }

    @Test
    func testSnapshotBindingRejectsGenerationBumpBetweenSnapshotAndBind() async {
        let registry = TargetRegistry(serverSessionID: UUID())
        let descriptor = descriptor()
        let snapshot = await registry.currentSnapshot

        await registry.bumpTopologyGeneration()

        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint,
            snapshot: snapshot
        )

        #expect(reference == nil)
        #expect(await registry.currentTopologyGeneration == 1)
    }

    @Test
    func testSnapshotBindingRejectsEpochBumpBetweenSnapshotAndBind() async {
        let registry = TargetRegistry(serverSessionID: UUID())
        let descriptor = descriptor()
        let snapshot = await registry.currentSnapshot

        await registry.bumpProjectEpoch()

        let reference = await registry.bind(
            kind: .pluginInsert,
            descriptor: descriptor,
            fingerprint: "\(descriptor.fingerprint)|insert=0|plugin=G",
            snapshot: snapshot
        )

        #expect(reference == nil)
        #expect(await registry.currentProjectEpoch == 1)
    }

    @Test
    func testProjectEpochInvalidatesBinding() async {
        let registry = TargetRegistry(serverSessionID: UUID())
        let descriptor = descriptor()
        let reference = await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )

        await registry.bumpProjectEpoch()

        #expect(await registry.resolve(reference) == nil)
        #expect(await registry.currentProjectEpoch == 1)
    }

    @Test
    func testDifferentServerSessionCannotResolveBinding() async {
        let firstRegistry = TargetRegistry(serverSessionID: UUID())
        let secondRegistry = TargetRegistry(serverSessionID: UUID())
        let descriptor = descriptor()
        let reference = await firstRegistry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )

        #expect(await firstRegistry.resolve(reference) != nil)
        #expect(await secondRegistry.resolve(reference) == nil)
    }

    @Test
    func testRenameRejectsStaleReferenceAfterTopologyGenerationBump() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = descriptor()
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            await registry.bumpTopologyGeneration()

            let router = ChannelRouter()
            let channel = TargetReferenceChannel(id: .accessibility)
            await router.register(channel)
            let cache = StateCache()
            await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])

            let result = await TrackDispatcher.handle(
                command: "rename",
                params: [
                    "name": .string("New Kick"),
                    "target_ref": .string(reference.rawValue),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            #expect(result.isError == true)
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(await channel.executedOps.isEmpty)
        }
    }

    @Test
    func testRenameRejectsStaleReferenceAfterProjectEpochBump() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = descriptor()
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )
            await registry.bumpProjectEpoch()

            let router = ChannelRouter()
            let channel = TargetReferenceChannel(id: .accessibility)
            await router.register(channel)
            let cache = StateCache()
            await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])

            let result = await TrackDispatcher.handle(
                command: "rename",
                params: [
                    "name": .string("New Kick"),
                    "target_ref": .string(reference.rawValue),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            #expect(result.isError == true)
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(await channel.executedOps.isEmpty)
        }
    }

    @Test
    func testRenameRejectsMismatchedTargetReferenceWithoutWrite() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = descriptor(index: 0, name: "Kick")
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )

            let router = ChannelRouter()
            let channel = TargetReferenceChannel(id: .accessibility)
            await router.register(channel)
            let cache = StateCache()
            await cache.updateTracks([
                TrackState(id: 0, name: "Kick", type: .audio),
                TrackState(id: 1, name: "Bass", type: .audio),
            ])

            let result = await TrackDispatcher.handle(
                command: "rename",
                params: [
                    "index": .int(1),
                    "name": .string("Wrong Target"),
                    "target_ref": .string(reference.rawValue),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            #expect(result.isError == true)
            #expect(sharedJSONObject(sharedToolText(result))?["error"] as? String == "stale_target_reference")
            #expect(await channel.executedOps.isEmpty)
        }
    }

    @Test
    func testRenameAcceptsResolvedTargetReference() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let descriptor = descriptor(index: 0, name: "Kick")
            let reference = await registry.bind(
                kind: .track,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )

            let router = ChannelRouter()
            let channel = TargetReferenceChannel(id: .accessibility)
            await router.register(channel)
            let cache = StateCache()
            await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])

            let result = await TrackDispatcher.handle(
                command: "rename",
                params: [
                    "name": .string("New Kick"),
                    "target_ref": .string(reference.rawValue),
                ],
                router: router,
                cache: cache,
                targetRegistry: registry
            )

            #expect(result.isError == false)
            // rename keeps its pre-uniform `track_ref` echo (G8 backward compat)
            // AND carries the uniform `target_ref` evidence key.
            let payload = sharedJSONObject(sharedToolText(result))!
            #expect(payload["track_ref"] as! String == reference.rawValue)
            #expect(payload["target_ref"] as! String == reference.rawValue)
            let operations = await channel.executedOps
            #expect(operations.count == 1)
            #expect(operations.first?.0 == "track.rename")
            #expect(operations.first?.1 == ["index": "0", "name": "New Kick"])
        }
    }

    @Test
    func testTrackResourceEmitsOpaqueReferenceOnlyWhenEnabled() async throws {
        let registry = TargetRegistry()
        let cache = StateCache()
        await cache.updateTracks([TrackState(id: 0, name: "Kick", type: .audio)])

        let enabledReference = try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let first = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry
            )
            let second = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry
            )
            let firstData = try #require(sharedJSONObject(sharedResourceText(first))?["data"] as? [[String: Any]])
            let secondData = try #require(sharedJSONObject(sharedResourceText(second))?["data"] as? [[String: Any]])
            let firstReference = try #require(firstData.first?["track_ref"] as? String)
            #expect(firstReference == secondData.first?["track_ref"] as? String)
            #expect(firstReference.hasPrefix("trk_"))
            #expect(!firstReference.contains("Kick"))
            return firstReference
        }

        let disabled = try await FeatureFlags.withAdr002TargetRefForTests(false) {
            try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry
            )
        }
        let disabledData = try #require(sharedJSONObject(sharedResourceText(disabled))?["data"] as? [[String: Any]])
        #expect(disabledData.first?["track_ref"] == nil)
        #expect(enabledReference.hasPrefix("trk_"))
    }

    @Test
    func testSuccessfulMutationsBumpRegistryGenerations() async {
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let trackRegistry = TargetRegistry()
            let trackRouter = ChannelRouter()
            let accessibility = TargetReferenceChannel(id: .accessibility)
            let mcu = TargetReferenceChannel(id: .mcu)
            let keyCommands = TargetReferenceChannel(id: .midiKeyCommands)
            await trackRouter.register(accessibility)
            await trackRouter.register(mcu)
            await trackRouter.register(keyCommands)

            _ = await TrackDispatcher.handle(
                command: "create_audio",
                params: [:],
                router: trackRouter,
                cache: StateCache(),
                targetRegistry: trackRegistry
            )
            // PRD-007: delete/duplicate are `.corroborated` — they must clear
            // the binding gate to reach the write that bumps the generation.
            let liveNames = sharedLiveTrackNames([0: "Generation Track"])
            _ = await TrackDispatcher.handle(
                command: "delete",
                params: ["index": .int(0), "expected_name": .string("Generation Track")],
                router: trackRouter,
                cache: StateCache(),
                targetRegistry: trackRegistry,
                liveTrackNames: liveNames
            )
            _ = await TrackDispatcher.handle(
                command: "duplicate",
                params: ["index": .int(0), "expected_name": .string("Generation Track")],
                router: trackRouter,
                cache: StateCache(),
                targetRegistry: trackRegistry,
                liveTrackNames: liveNames
            )
            #expect(await trackRegistry.currentTopologyGeneration == 3)

            // insert_verified supplies no `track`, so the binding gate is skipped
            // (the channel reports the missing selector) and this still exercises
            // the generation bump exactly as before.
            _ = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [:],
                router: trackRouter,
                cache: StateCache(),
                targetRegistry: trackRegistry
            )
            #expect(await trackRegistry.currentTopologyGeneration == 4)

            let projectRegistry = TargetRegistry()
            let projectRouter = ChannelRouter()
            await projectRouter.register(TargetReferenceChannel(id: .appleScript))
            _ = await ProjectDispatcher.handle(
                command: "new",
                params: [:],
                router: projectRouter,
                cache: StateCache(),
                targetRegistry: projectRegistry
            )
            #expect(await projectRegistry.currentProjectEpoch == 1)
        }
    }

    @Test
    func testFailedOrFlagOffMutationDoesNotBumpGeneration() async {
        let failedRegistry = TargetRegistry()
        await FeatureFlags.withAdr002TargetRefForTests(true) {
            let router = ChannelRouter()
            await router.register(TargetReferenceChannel(id: .accessibility, succeeds: false))
            _ = await TrackDispatcher.handle(
                command: "create_audio",
                params: [:],
                router: router,
                cache: StateCache(),
                targetRegistry: failedRegistry
            )
        }
        #expect(await failedRegistry.currentTopologyGeneration == 0)

        let disabledRegistry = TargetRegistry()
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            let router = ChannelRouter()
            await router.register(TargetReferenceChannel(id: .accessibility))
            _ = await TrackDispatcher.handle(
                command: "create_audio",
                params: [:],
                router: router,
                cache: StateCache(),
                targetRegistry: disabledRegistry
            )
        }
        #expect(await disabledRegistry.currentTopologyGeneration == 0)
    }

    @Test
    func testRenameTargetReferenceFailsClosedWhenFeatureDisabled() async {
        await FeatureFlags.withAdr002TargetRefForTests(false) {
            #expect(FeatureFlags.adr002TargetRef == false)

            let router = ChannelRouter()
            let channel = MockChannel(id: .accessibility)
            await router.register(channel)

            let result = await TrackDispatcher.handle(
                command: "rename",
                params: [
                    "index": .int(2),
                    "name": .string("Legacy Rename"),
                    "target_ref": .string("trk_bogus"),
                ],
                router: router,
                cache: StateCache()
            )

            let body = sharedJSONObject(sharedToolText(result)) ?? [:]
            #expect(result.isError == true)
            #expect(body["error"] as? String == "target_ref_unavailable")
            #expect(body["write_attempted"] as? Bool == false)
            #expect(await channel.executedOps.isEmpty)
        }
    }
}
