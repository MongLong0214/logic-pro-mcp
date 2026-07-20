import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite(.serialized)
struct ADR002BProjectTargetTests {
    private func fileReader() -> LogicProjectFileReader.Runtime {
        .init(
            currentDocumentPath: { nil },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            readPlistData: { _ in nil },
            mtime: { _ in nil },
            sleep: { _ in }
        )
    }

    private func cache(projectName: String = "Slice B", path: String = "/tmp/Slice B.logicx") async -> StateCache {
        let cache = StateCache()
        var project = ProjectInfo(name: projectName, filePath: path)
        project.lastUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        await cache.updateProject(project)
        await cache.updateTracks([
            TrackState(id: 0, name: "Kick", type: .audio),
            TrackState(id: 1, name: "Snare", type: .audio),
            TrackState(id: 2, name: "Bass", type: .audio),
        ])
        await cache.updateChannelStrips([ChannelStripState(trackIndex: 2)])
        return cache
    }

    private func router(id: ChannelID) async -> (ChannelRouter, MockChannel) {
        let router = ChannelRouter()
        let channel = MockChannel(id: id)
        await router.register(channel)
        return (router, channel)
    }

    private func resourceData(_ result: ReadResource.Result) throws -> [String: Any] {
        let envelope = try #require(sharedJSONObject(sharedResourceText(result)))
        return try #require(envelope["data"] as? [String: Any])
    }

    private func resourceDataBytes(_ result: ReadResource.Result) throws -> Data {
        try JSONSerialization.data(withJSONObject: resourceData(result), options: [.sortedKeys])
    }

    private func toolObject(_ result: CallTool.Result) throws -> [String: Any] {
        try #require(sharedJSONObject(sharedToolText(result)))
    }

    private func requireStateC(_ result: CallTool.Result) throws -> [String: Any] {
        let isError = try #require(result.isError)
        #expect(isError)
        let object = try toolObject(result)
        let state = try #require(object["state"] as? String)
        #expect(state == "C")
        let writeAttempted = try #require(object["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        return object
    }

    @Test
    func projectInfoEmitsStableFirstClassProjectRef() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cache()
            let registry = TargetRegistry()
            let router = ChannelRouter()
            let first = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: router,
                targetRegistry: registry,
                fileReader: fileReader()
            )
            let second = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: router,
                targetRegistry: registry,
                fileReader: fileReader()
            )

            let firstData = try resourceData(first)
            let secondData = try resourceData(second)
            let firstReference = try #require(firstData["project_ref"] as? String)
            let secondReference = try #require(secondData["project_ref"] as? String)
            #expect(firstReference == secondReference)
            #expect(firstReference.hasPrefix("prj_"))

            let binding = try #require(await registry.resolve(TargetReference(rawValue: firstReference)))
            #expect(binding.kind == .project)
            #expect(binding.observedFingerprint.contains("Slice B"))
            #expect(binding.observedFingerprint.contains("/tmp/Slice B.logicx"))
            #expect(binding.observedFingerprint.contains("epoch=0"))
        }
    }

    @Test
    func projectNewBumpsProjectEpochExactlyOnce() async throws {
        try await assertLifecycleBump(command: "new", params: [:])
    }

    @Test
    func projectOpenBumpsProjectEpochExactlyOnce() async throws {
        let path = try existingProjectPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await assertLifecycleBump(
            command: "open",
            params: ["path": .string(path), "confirmed": .bool(true)]
        )
    }

    @Test
    func projectSaveAsBumpsProjectEpochExactlyOnce() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("adr002b-save-as-(UUID().uuidString)")
            .appendingPathExtension("logicx")
            .path
        try await assertLifecycleBump(
            command: "save_as",
            params: ["path": .string(path), "confirmed": .bool(true)]
        )
    }

    @Test
    func projectSaveAsFlagOffPreservesCacheState() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            await cache.updateTracks([
                TrackState(id: 0, name: "Existing", type: .audio),
            ])
            let (router, _) = await router(id: .appleScript)

            let result = await ProjectDispatcher.handle(
                command: "save_as",
                params: ["path": .string("/tmp/adr002b-flag-off.logicx")],
                router: router,
                cache: cache
            )

            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(await cache.getTracks().map(\.name) == ["Existing"])
        }
    }

    @Test
    func projectCloseBumpsProjectEpochExactlyOnce() async throws {
        try await assertLifecycleBump(
            command: "close",
            params: ["saving": .string("no"), "confirmed": .bool(true)]
        )
    }

    @Test
    func projectSwitchBumpsProjectEpochExactlyOnce() async throws {
        let path = try existingProjectPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await assertLifecycleBump(
            command: "open",
            params: ["path": .string(path), "confirmed": .bool(true)]
        )
    }

    @Test
    func projectEpochBumpRejectsProjectTrackMixerPluginRefsBeforeWrite() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cache()
            let registry = TargetRegistry()
            let readRouter = ChannelRouter()
            let projectInfo = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: readRouter,
                targetRegistry: registry,
                fileReader: fileReader()
            )
            let projectData = try resourceData(projectInfo)
            let projectReference = try #require(projectData["project_ref"] as? String)

            let tracks = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: readRouter,
                targetRegistry: registry,
                fileReader: fileReader()
            )
            let tracksEnvelope = try #require(sharedJSONObject(sharedResourceText(tracks)))
            let trackRows = try #require(tracksEnvelope["data"] as? [[String: Any]])
            let trackReference = try #require(trackRows[2]["track_ref"] as? String)

            let mixer = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: readRouter,
                targetRegistry: registry
            )
            let mixerRows = try #require(sharedJSONObject(sharedResourceText(mixer))?["strips"] as? [[String: Any]])
            let mixerReference = try #require(mixerRows[0]["mixer_strip_ref"] as? String)

            let descriptor = TargetDescriptor(trackIndex: 2, trackName: "Bass")
            let pluginReference = await registry.bind(
                kind: .pluginInsert,
                descriptor: descriptor,
                fingerprint: "(descriptor.fingerprint)|insert=1|plugin=Gain"
            )
            await registry.bumpProjectEpoch()

            let (projectRouter, projectChannel) = await router(id: .appleScript)
            let projectResult = await ProjectDispatcher.handle(
                command: "new",
                params: ["project_ref": .string(projectReference)],
                router: projectRouter,
                cache: cache,
                targetRegistry: registry
            )
            let projectBody = try requireStateC(projectResult)
            #expect(try #require(projectBody["error"] as? String) == "stale_target_reference")
            #expect(await projectChannel.executedOps.isEmpty)

            let (trackRouter, trackChannel) = await router(id: .accessibility)
            let trackResult = await TrackDispatcher.handle(
                command: "select",
                params: ["target_ref": .string(trackReference)],
                router: trackRouter,
                cache: cache,
                targetRegistry: registry
            )
            let trackBody = try requireStateC(trackResult)
            #expect(try #require(trackBody["error"] as? String) == "stale_target_reference")
            #expect(await trackChannel.executedOps.isEmpty)

            let (mixerRouter, mixerChannel) = await router(id: .accessibility)
            let mixerResult = await MixerDispatcher.handle(
                command: "set_volume",
                params: ["target_ref": .string(mixerReference), "value": .double(0.5)],
                router: mixerRouter,
                cache: cache,
                targetRegistry: registry
            )
            let mixerBody = try requireStateC(mixerResult)
            #expect(try #require(mixerBody["error"] as? String) == "stale_target_reference")
            #expect(await mixerChannel.executedOps.isEmpty)

            let (pluginRouter, pluginChannel) = await router(id: .accessibility)
            let pluginResult = await PluginsDispatcher.handle(
                command: "insert_verified",
                params: [
                    "target_ref": .string(pluginReference.rawValue),
                    "plugin": .string("Gain"),
                    "mode": .string("duplicate_applyback"),
                    "project_expected_path": .string("/tmp/Slice B.logicx"),
                ],
                router: pluginRouter,
                cache: cache,
                targetRegistry: registry
            )
            let pluginBody = try requireStateC(pluginResult)
            #expect(try #require(pluginBody["error"] as? String) == "stale_target_reference")
            #expect(await pluginChannel.executedOps.isEmpty)
        }
    }

    @Test
    func foreignAndMalformedProjectRefsReturnTypedStateC() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await cache()
            let registry = TargetRegistry()
            let foreignRegistry = TargetRegistry()
            let descriptor = TargetDescriptor(trackIndex: -1, trackName: "Foreign Project")
            let foreignReference = await foreignRegistry.bind(
                kind: .project,
                descriptor: descriptor,
                fingerprint: descriptor.fingerprint
            )

            for rawReference in [foreignReference.rawValue, "prj_malformed"] {
                let (router, channel) = await router(id: .appleScript)
                let result = await ProjectDispatcher.handle(
                    command: "new",
                    params: ["project_ref": .string(rawReference)],
                    router: router,
                    cache: cache,
                    targetRegistry: registry
                )
                let body = try requireStateC(result)
                #expect(try #require(body["error"] as? String) == "stale_target_reference")
                #expect(await channel.executedOps.isEmpty)
            }
        }
    }

    @Test
    func projectInfoFlagOffIsByteIdenticalAndOmitsProjectRef() async throws {
        let cache = await cache()
        let router = ChannelRouter()
        let (withoutRegistry, withRegistry, data) = try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let withoutRegistryResult = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: router,
                fileReader: fileReader()
            )
            let withRegistryResult = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: router,
                targetRegistry: TargetRegistry(),
                fileReader: fileReader()
            )
            return (
                try resourceDataBytes(withoutRegistryResult),
                try resourceDataBytes(withRegistryResult),
                try resourceData(withRegistryResult)
            )
        }
        #expect(withoutRegistry == withRegistry)
        #expect(data["project_ref"] == nil)
    }

    private func assertLifecycleBump(
        command: String,
        params: [String: Value]
    ) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let registry = TargetRegistry()
            let (router, _) = await router(id: .appleScript)
            let result = await ProjectDispatcher.handle(
                command: command,
                params: params,
                router: router,
                cache: StateCache(),
                targetRegistry: registry
            )
            let v1 = try #require(result.isError)
            #expect(!v1)
            #expect(await registry.currentProjectEpoch == 1)
        }
    }

    private func existingProjectPath() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("adr002b-(UUID().uuidString)")
            .appendingPathExtension("logicx")
        let projectInfo = path.appendingPathComponent("Resources/ProjectInformation.plist")
        let projectData = path.appendingPathComponent("Alternatives/000/ProjectData")
        try FileManager.default.createDirectory(
            at: projectInfo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: projectData.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: projectInfo)
        try Data().write(to: projectData)
        return path.path
    }
}
