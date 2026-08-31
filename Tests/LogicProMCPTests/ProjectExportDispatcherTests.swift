import Foundation
import Testing
@testable import LogicProMCP

@Suite("Project export dispatcher integration")
struct ProjectExportDispatcherTests {
    @Test("dispatcher export_run returns HC-truthful isError on a failed run")
    func dispatcherExportRunIsErrorOnFailure() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Dispatch Song")

        let router = await makeExportRouter()
        let options = fastOptions(identity: { "/Users/elsewhere/Wrong.logicx" })
        let cache = StateCache()

        let result = await ProjectDispatcher.handle(
            command: "export_run",
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
                "confirmed": .bool(true),
            ],
            router: router,
            cache: cache,
            exportOptions: options
        )

        #expect(try #require(result.isError))
        let text = sharedToolText(result)
        #expect(text.contains("\"schema\":\"logic_pro_mcp_export_run.v1\""))
        #expect(text.contains("\"status\":\"failed\""))
    }

    @Test("dispatcher export_run rejects invalid params before any execution")
    func dispatcherExportRunRejectsInvalidParams() async throws {
        let router = await makeExportRouter()
        let cache = StateCache()
        let options = fastOptions(identity: { nil })

        let result = await ProjectDispatcher.handle(
            command: "export_run",
            params: [
                "projects": .array([.string("/tmp/nope.logicx")]),
                "confirmed": .bool(true),
            ],
            router: router,
            cache: cache,
            exportOptions: options
        )

        #expect(try #require(result.isError))
        #expect(sharedToolText(result).contains("invalid_params"))
    }

    @Test("dispatcher export_run returns confirmation_required HC envelope when confirmed omitted")
    func dispatcherExportRunConfirmationRequired() async throws {
        let projDir = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projDir, named: "Gate Song")

        let router = await makeExportRouter()
        let options = fastOptions(identity: { project.path })
        let cache = StateCache()

        let result = await ProjectDispatcher.handle(
            command: "export_run",
            params: [
                "projects": .array([.string(project.path)]),
                "output_root": .string(outputRoot.path),
                "artifacts": .array([.string("bounce")]),
            ],
            router: router,
            cache: cache,
            exportOptions: options
        )

        #expect(try #require(result.isError))
        let text = sharedToolText(result)
        #expect(text.contains("\"status\":\"confirmation_required\""))
        #expect(text.contains("\"confirmed\":false"))
    }

    @Test("public export_run reaches the stem panel from the cache-backed inventory")
    func dispatcherStemRunUsesCachedProjectIdentityAndSubjects() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let project = try makeLogicxProject(in: projectRoot, named: "Public Stem")
        let cache = StateCache()
        var projectInfo = ProjectInfo()
        projectInfo.name = "Public Stem"
        projectInfo.filePath = project.path
        projectInfo.lastUpdated = Date()
        await cache.updateProject(projectInfo)
        await cache.updateTracks([
            TrackState(id: 0, name: "Piano", type: .softwareInstrument),
            TrackState(id: 1, name: "Bass", type: .audio),
        ])
        await cache.updateRegions([
            RegionState(id: "0:1", name: "Piano region", trackIndex: 0, startPosition: "1 1 1 1", endPosition: "2 1 1 1", length: "1 0 0 0"),
            RegionState(id: "1:1", name: "Bass region", trackIndex: 1, startPosition: "1 1 1 1", endPosition: "2 1 1 1", length: "1 0 0 0"),
        ], complete: true)

        let firstOutput = outputRoot.appendingPathComponent("opaque-piano.wav")
        let secondOutput = outputRoot.appendingPathComponent("opaque-bass.wav")
        let panelReached = BoolFlag()
        var options = fastOptions(identity: { project.path })
        options.driveStemExport = { _ in
            panelReached.set()
            _ = try? writeToneWav(at: firstOutput)
            _ = try? writeToneWav(at: secondOutput)
            return .completed
        }

        let result = await ProjectDispatcher.handle(
            command: "export_run",
            params: [
                "project": .string(project.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
                "confirmed": .bool(true),
            ],
            router: await makeExportRouter(),
            cache: cache,
            exportOptions: options
        )

        let resultIsError = result.isError ?? true
        #expect(!resultIsError)
        #expect(panelReached.isSet)
        let runData = try #require(sharedToolText(result).data(using: .utf8))
        let run = try JSONDecoder().decode(ProjectExportRunResult.self, from: runData)
        #expect(run.status == "uncertain")
        #expect(run.artifactsTotal == 2)
        let artifacts = try #require(run.projects.first?.artifacts)
        let subjects = artifacts.compactMap(\.subject)
        #expect(subjects.map(\.index) == [0, 1])
    }

    @Test("public stem plan rejects a region result from the prior project epoch")
    func dispatcherStemPlanRejectsCrossProjectRegionInventory() async throws {
        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        let oldProject = try makeLogicxProject(in: projectRoot, named: "Old Session")
        let newProject = try makeLogicxProject(in: projectRoot, named: "New Session")
        let cache = StateCache()
        var oldInfo = ProjectInfo()
        oldInfo.filePath = oldProject.path
        oldInfo.lastUpdated = Date()
        await cache.updateProject(oldInfo)
        let observedOldIdentity = await cache.currentProjectIdentity()
        let oldIdentity = try #require(observedOldIdentity)
        await cache.updateTracks([TrackState(id: 0, name: "Old Lead", type: .audio)])
        await cache.updateRegions([
            RegionState(id: "old:0", name: "Old region", trackIndex: 0, startPosition: "1 1 1 1", endPosition: "2 1 1 1", length: "1 0 0 0"),
        ], complete: true)

        var newInfo = ProjectInfo()
        newInfo.filePath = newProject.path
        newInfo.lastUpdated = Date()
        await cache.updateProject(newInfo)
        await cache.updateTracks([TrackState(id: 0, name: "New Lead", type: .audio)])
        let staleRegionWasApplied = await cache.updateRegions(
            [RegionState(id: "old:0", name: "Old region", trackIndex: 0, startPosition: "1 1 1 1", endPosition: "2 1 1 1", length: "1 0 0 0")],
            complete: true,
            ifCurrent: oldIdentity
        )

        let result = await ProjectDispatcher.handle(
            command: "export_plan",
            params: [
                "project": .string(newProject.path),
                "output_root": .string(outputRoot.path),
                "artifact": .string("stem"),
            ],
            router: ChannelRouter(),
            cache: cache
        )

        #expect(!staleRegionWasApplied)
        let resultIsError = result.isError ?? false
        #expect(resultIsError)
        let refusal = sharedToolText(result).contains("stem_subject_list_unavailable")
        #expect(refusal)
    }
}
