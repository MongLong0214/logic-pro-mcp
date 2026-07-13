import Foundation
import MCP
import Testing
@testable import LogicProMCP

private let operationTraceCoverageFlagKey = "LOGIC_MCP_ADR005_OPERATION_TRACE"

private func replaceOperationTraceCoverageFlag(with value: String?) -> String? {
    let previous = getenv(operationTraceCoverageFlagKey).map { String(cString: $0) }
    if let value {
        setenv(operationTraceCoverageFlagKey, value, 1)
    } else {
        unsetenv(operationTraceCoverageFlagKey)
    }
    return previous
}

private actor OperationTraceCoverageChannel: Channel {
    nonisolated let id: ChannelID

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .error(HonestContract.encodeStateC(
            error: .axWriteFailed,
            hint: "Operation trace coverage mock refused \(operation)",
            extras: ["operation": operation]
        ))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "operation trace coverage mock")
    }
}

private struct OperationTraceCoverageFixtures {
    let projectPath: String
    let outputRoot: String
    let midiPath: String
}

private let operationTraceCoverageFileReader = LogicProjectFileReader.Runtime(
    currentDocumentPath: { nil },
    now: Date.init,
    readPlistData: { _ in nil },
    mtime: { _ in nil },
    sleep: { _ in }
)

extension OperationTraceTests {
    @Test func OperationTraceCoverageAllRegistryMutations() async throws {
        let previous = replaceOperationTraceCoverageFlag(with: "1")
        defer { _ = replaceOperationTraceCoverageFlag(with: previous) }

        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: outputRoot)
        }
        let project = try makeLogicxProject(in: projectRoot, named: "Trace Coverage")
        let resources = project.appendingPathComponent("Resources", isDirectory: true)
        let alternative = project.appendingPathComponent("Alternatives/000", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
        try Data().write(to: resources.appendingPathComponent("ProjectInformation.plist"))
        try Data().write(to: alternative.appendingPathComponent("ProjectData"))
        let midiFile = try SMFWriter.temporaryMIDIFile()
        try Data([0x4D, 0x54, 0x68, 0x64]).write(to: midiFile.fileURL)
        defer { SMFWriter.cleanupTemporaryMIDIFile(midiFile) }

        let fixtures = OperationTraceCoverageFixtures(
            projectPath: project.path,
            outputRoot: outputRoot.path,
            midiPath: midiFile.fileURL.path
        )
        let router = ChannelRouter()
        for channelID in ChannelID.allCases {
            await router.register(OperationTraceCoverageChannel(id: channelID))
        }
        let cache = StateCache()
        await cache.updateMarkers([
            MarkerState(id: 0, name: "Coverage Marker", position: "1.1.1.1", positionSource: .parser),
        ])

        let mutatingSpecs = OperationRegistry.specs.filter {
            $0.mutability == Mutability.`mutating`
        }
        #expect(OperationRegistry.specs.count == 107)
        #expect(mutatingSpecs.count == 86)

        for spec in mutatingSpecs {
            await OperationTraceStore.shared.clear()
            _ = await dispatchOperationTraceCoverageSpec(
                spec,
                params: operationTraceCoverageParams(for: spec.id, fixtures: fixtures),
                router: router,
                cache: cache
            )

            let matchingTrace = await OperationTraceStore.shared.recent(limit: 128)
                .first { $0.operationID == spec.id.rawValue }
            #expect(matchingTrace != nil, "Missing trace for \(spec.tool.rawValue).\(spec.command)")
            if let matchingTrace {
                #expect(
                    matchingTrace.events.contains { $0.phase == .requestReceived },
                    "Missing request.received for \(spec.id.rawValue)"
                )
                #expect(
                    matchingTrace.events.contains { $0.phase == .resultEmitted },
                    "Missing result.emitted for \(spec.id.rawValue)"
                )
                #expect(matchingTrace.completedAt != nil, "Incomplete trace for \(spec.id.rawValue)")
            }
        }

        await OperationTraceStore.shared.clear()
    }

    @Test func OperationTraceCoverageReadOnlyCommandsRemainTraceFree() async throws {
        let previous = replaceOperationTraceCoverageFlag(with: "1")
        defer { _ = replaceOperationTraceCoverageFlag(with: previous) }

        let fixtures = OperationTraceCoverageFixtures(
            projectPath: "/tmp/trace-coverage.logicx",
            outputRoot: "/tmp",
            midiPath: "/tmp/trace-coverage.mid"
        )
        let router = ChannelRouter()
        for channelID in ChannelID.allCases {
            await router.register(OperationTraceCoverageChannel(id: channelID))
        }
        let cache = StateCache()
        let readOnlyIDs: [OperationID] = [
            .audioAnalyzeFile,
            .pluginsGetInventory,
            .projectIsRunning,
            .midiListPorts,
            .tracksResolvePath,
        ]

        for operationID in readOnlyIDs {
            let spec = try #require(OperationRegistry.specs.first { $0.id == operationID })
            #expect(spec.mutability == .readOnly)
            await OperationTraceStore.shared.clear()
            _ = await dispatchOperationTraceCoverageSpec(
                spec,
                params: operationTraceCoverageParams(for: operationID, fixtures: fixtures),
                router: router,
                cache: cache
            )
            #expect(
                await OperationTraceStore.shared.recent(limit: 128).isEmpty,
                "Read-only command traced: \(spec.tool.rawValue).\(spec.command)"
            )
        }

        await OperationTraceStore.shared.clear()
    }

    @Test func OperationTraceCoverageProjectBlockingDialogsTraceWithoutBoundary() async throws {
        let previous = replaceOperationTraceCoverageFlag(with: "1")
        defer { _ = replaceOperationTraceCoverageFlag(with: previous) }

        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: outputRoot)
        }
        let project = try makeLogicxProject(in: projectRoot, named: "Trace Blocking")
        let exportParams: [String: Value] = [
            "projects": .array([.string(project.path)]),
            "output_root": .string(outputRoot.path),
            "artifacts": .array([.string("bounce")]),
            "confirmed": .bool(true),
        ]
        let cases: [(command: String, params: [String: Value])] = [
            ("new", [:]),
            ("save", [:]),
            ("export_run", exportParams),
            ("export_resume", exportParams),
        ]

        for testCase in cases {
            await OperationTraceStore.shared.clear()
            _ = await ProjectDispatcher.handle(
                command: testCase.command,
                params: testCase.params,
                router: ChannelRouter(),
                cache: StateCache(),
                dialogPresent: { true },
                cleanupAuditFileReader: operationTraceCoverageFileReader,
                exportOptions: fastOptions(identity: { nil })
            )

            let operationID = try #require(
                OperationRegistry.spec(tool: ProjectDispatcher.tool.name, command: testCase.command)?.id
            )
            let trace = try #require(
                await OperationTraceStore.shared.recent(limit: 8)
                    .first { $0.operationID == operationID.rawValue }
            )
            #expect(trace.events.contains { $0.phase == .requestReceived })
            #expect(!trace.events.contains { $0.phase == .writeBoundaryCrossed })
            #expect(trace.events.contains { $0.phase == .resultEmitted })
            #expect(trace.completedAt != nil)
        }

        await OperationTraceStore.shared.clear()
    }
}

private func dispatchOperationTraceCoverageSpec(
    _ spec: OperationSpec,
    params: [String: Value],
    router: ChannelRouter,
    cache: StateCache
) async -> CallTool.Result {
    switch spec.tool {
    case .logicTransport:
        return await TransportDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache,
            sleep: { _ in }
        )
    case .logicMixer:
        return await MixerDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache
        )
    case .logicNavigate:
        return await NavigateDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache
        )
    case .logicAudio:
        return AudioDispatcher.handle(command: spec.command, params: params)
    case .logicSystem:
        return await SystemDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache,
            supportBundleExporter: { directory, onFirstWrite in
                await onFirstWrite()
                return .init(directory: directory, files: [
                    .init(name: "manifest.json", sha256: String(repeating: "a", count: 64)),
                ])
            }
        )
    case .logicPlugins:
        return await PluginsDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache
        )
    case .logicEdit:
        return await EditDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache
        )
    case .logicProject:
        return await ProjectDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache,
            isLogicProRunning: { spec.command == "quit" },
            executeLifecycleScript: { _ in
                ProjectDispatcher.LifecycleExecution(
                    executionError: "operation trace coverage mock",
                    timedOut: false,
                    terminationStatus: 1,
                    stderrOutput: ""
                )
            },
            sleep: { _ in },
            cleanupAuditFileReader: operationTraceCoverageFileReader,
            exportOptions: fastOptions(identity: { nil })
        )
    case .logicMidi:
        return await MIDIDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache
        )
    case .logicTracks:
        return await TrackDispatcher.handle(
            command: spec.command,
            params: params,
            router: router,
            cache: cache
        )
    }
}

private func operationTraceCoverageParams(
    for operationID: OperationID,
    fixtures: OperationTraceCoverageFixtures
) -> [String: Value] {
    switch operationID {
    case .systemExportSupportBundle:
        return ["dir": .string(URL(fileURLWithPath: fixtures.outputRoot)
            .appendingPathComponent("support-bundle").path)]
    case .transportSetTempo:
        return ["tempo": .double(120)]
    case .transportGotoPosition:
        return ["bar": .int(1)]
    case .transportSetCycleRange:
        return ["start": .int(1), "end": .int(2)]
    case .mixerSetVolume:
        return ["track": .int(0), "value": .double(0.5)]
    case .mixerSetPan:
        return ["track": .int(0), "value": .double(0)]
    case .mixerSetMasterVolume:
        return ["value": .double(0.5)]
    case .mixerSetPluginParam:
        return ["track": .int(0), "insert": .int(0), "param": .int(0), "value": .double(0.5)]
    case .mixerInsertPlugin:
        return [
            "track": .int(0), "slot": .int(0), "plugin_name": .string("Gain"),
            "confirmed": .bool(true),
        ]
    case .navigateGotoBar:
        return ["bar": .int(1)]
    case .navigateGotoMarker, .navigateDeleteMarker:
        return ["index": .int(0)]
    case .navigateCreateMarker:
        return ["name": .string("Coverage Marker")]
    case .navigateRenameMarker:
        return ["index": .int(0), "name": .string("Coverage Marker")]
    case .navigateSetZoom:
        return ["level": .string("fit")]
    case .navigateToggleView:
        return ["view": .string("mixer")]
    case .pluginsGetInventory:
        return ["track": .int(0)]
    case .pluginsSetParamVerified:
        return [
            "track": .int(0), "insert": .int(0), "plugin": .string("logic.stock.gain"),
            "param": .string("gain_db"), "value": .double(0), "unit": .string("dB"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string(fixtures.projectPath),
        ]
    case .pluginsInsertVerified:
        return [
            "track": .int(0), "insert": .int(0), "plugin": .string("Gain"),
            "mode": .string("duplicate_applyback"),
            "project_expected_path": .string(fixtures.projectPath),
        ]
    case .editQuantize:
        return ["value": .string("1/16")]
    case .projectOpen:
        return ["path": .string(fixtures.projectPath), "confirmed": .bool(true)]
    case .projectSaveAs:
        return [
            "path": .string(URL(fileURLWithPath: fixtures.outputRoot)
                .appendingPathComponent("Trace Coverage.logicx").path),
            "confirmed": .bool(true),
        ]
    case .projectClose:
        return ["saving": .string("no"), "confirmed": .bool(true)]
    case .projectBounce:
        return ["confirmed": .bool(false)]
    case .projectQuit:
        return ["confirmed": .bool(true)]
    case .projectExportRun, .projectExportResume:
        return [
            "projects": .array([.string(fixtures.projectPath)]),
            "output_root": .string(fixtures.outputRoot),
            "artifacts": .array([.string("bounce")]),
            "confirmed": .bool(false),
        ]
    case .projectCleanupApply:
        return ["step_id": .string("coverage-step"), "confirmed": .bool(true)]
    case .midiSendNote:
        return ["note": .int(60), "velocity": .int(100), "duration_ms": .int(100)]
    case .midiSendChord:
        return ["notes": .string("60,64,67"), "velocity": .int(100), "duration_ms": .int(100)]
    case .midiSendCC:
        return ["controller": .int(1), "value": .int(64)]
    case .midiSendProgramChange:
        return ["program": .int(1)]
    case .midiSendPitchBend:
        return ["value": .int(0)]
    case .midiSendAftertouch:
        return ["value": .int(64)]
    case .midiSendSysEx:
        return ["bytes": .array([.int(0xF0), .int(0x01), .int(0xF7)])]
    case .midiPlaySequence:
        return ["notes": .string("60,0,100")]
    case .midiImportFile:
        return ["path": .string(fixtures.midiPath)]
    case .midiCreateVirtualPort:
        return ["name": .string("Trace Coverage")]
    case .midiStepInput:
        return ["note": .int(60), "duration": .string("1/16")]
    case .midiMMCLocate:
        return ["bar": .int(1)]
    case .tracksSelect, .tracksDelete, .tracksDuplicate, .tracksArmOnly:
        return ["index": .int(0)]
    case .tracksRename:
        return ["index": .int(0), "name": .string("Trace Coverage")]
    case .tracksMute, .tracksSolo, .tracksArm:
        return ["index": .int(0), "enabled": .bool(true)]
    case .tracksRecordSequence:
        return ["notes": .string("60,0,100")]
    case .tracksSetAutomation:
        return ["index": .int(0), "mode": .string("read")]
    case .tracksSetInstrument:
        return ["index": .int(0), "path": .string("Pianos/Trace Coverage.patch")]
    case .tracksResolvePath:
        return ["path": .string("Pianos/Trace Coverage.patch")]
    case .audioAnalyzeFile:
        return ["path": .string("/tmp/trace-coverage-missing.wav")]
    default:
        return [:]
    }
}
