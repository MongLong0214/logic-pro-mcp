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

/// Answers State A so every read-only op runs its SUCCESS path. The refusing
/// mock above short-circuits each op at its first channel hop — which is
/// precisely why it can never prove where `writeBoundaryCrossed` is (or is
/// not) recorded. The read-only inverse gate uses this permissive probe
/// instead, so an op that wrongly recorded a write boundary on its happy path
/// is actually reached.
private actor OperationTraceReadOnlyProbeChannel: Channel {
    nonisolated let id: ChannelID

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        .success(HonestContract.encodeStateA(extras: ["operation": operation]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "operation trace read-only probe")
    }
}

/// Counts `recordWriteBoundary` calls independently of the trace store. This
/// is the load-bearing part of the zero-write census: `recordWriteBoundary`
/// fires the `onWriteBoundary` hook BEFORE its `guard let traceID` early
/// return, so a read-only op that crosses a write boundary is caught here even
/// though it starts no trace and therefore leaves the store empty.
private actor WriteBoundaryProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct OperationTraceCoverageFixtures {
    let projectPath: String
    let outputRoot: String
    let midiPath: String
}

/// Shared fixture for the #389 store-wide censuses: the same temp project /
/// output roots, all-channel router and seeded cache the mutating census builds,
/// so both censuses drive the real bound dispatchers over every mutating spec.
private struct OperationTraceCensusContext {
    let fixtures: OperationTraceCoverageFixtures
    let router: ChannelRouter
    let cache: StateCache
    let mutatingSpecs: [OperationSpec]
    let cleanup: @Sendable () -> Void
}

private func makeOperationTraceCensusContext() async throws -> OperationTraceCensusContext {
    let projectRoot = try makeExecTempDir()
    let outputRoot = try makeExecTempDir()
    let project = try makeLogicxProject(in: projectRoot, named: "Trace Census")
    let resources = project.appendingPathComponent("Resources", isDirectory: true)
    let alternative = project.appendingPathComponent("Alternatives/000", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
    try Data().write(to: resources.appendingPathComponent("ProjectInformation.plist"))
    try Data().write(to: alternative.appendingPathComponent("ProjectData"))
    let midiFile = try SMFWriter.temporaryMIDIFile()
    try Data([0x4D, 0x54, 0x68, 0x64]).write(to: midiFile.fileURL)

    let router = ChannelRouter()
    for channelID in ChannelID.allCases {
        await router.register(OperationTraceCoverageChannel(id: channelID))
    }
    let cache = StateCache()
    await cache.updateMarkers([
        MarkerState(id: 0, name: "Coverage Marker", position: "1.1.1.1", positionSource: .parser),
    ])
    return OperationTraceCensusContext(
        fixtures: OperationTraceCoverageFixtures(
            projectPath: project.path,
            outputRoot: outputRoot.path,
            midiPath: midiFile.fileURL.path
        ),
        router: router,
        cache: cache,
        mutatingSpecs: OperationRegistry.specs.filter { $0.mutability == Mutability.`mutating` },
        cleanup: {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: outputRoot)
            SMFWriter.cleanupTemporaryMIDIFile(midiFile)
        }
    )
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
        // PRD-011: bundle output must resolve inside the support-bundle root;
        // point the root at the temp tree so the census fixture stays contained.
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }

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
        #expect(OperationRegistry.specs.count == 110)
        #expect(mutatingSpecs.count == 87)

        // A mutating op that refuses BEFORE dispatch starts its trace (the
        // consent-first setup_arm_key, #413) starts no trace with the coverage
        // params (which carry no consent), so it is asserted to claim NO trace
        // coverage rather than to have a trace.
        let notOracledDeferrals: Set<OperationID> = [.systemSetupArmKey]

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
            if notOracledDeferrals.contains(spec.id) {
                #expect(matchingTrace == nil, "NOT-oracled deferral unexpectedly claimed trace coverage: \(spec.id.rawValue)")
                continue
            }
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

    /// ADR-005 zero-write census (inverse gate). Read-only ops start no trace
    /// by design, so the contract is an ABSENCE: for EVERY read-only registry
    /// spec — not a hand-picked sample — invoking the real bound handler must
    /// record no trace and cross no write boundary. Two independent assertions,
    /// because neither alone is sufficient: the store-empty check proves no
    /// trace was started, and the `onWriteBoundary` probe proves no write
    /// boundary was crossed even in the (correct) absence of a trace, which a
    /// store-only check is structurally blind to.
    ///
    /// Side-effect safety mirrors the executable dispatch census: every channel
    /// is a probe, the project lifecycle executor is stubbed through the
    /// dependencies seam, and the support-bundle exporter throws. Ops whose
    /// read path needs live AX return errors through the probe channels — the
    /// contract under test is trace/write-boundary absence, not success.
    @Test func OperationTraceCoverageEveryReadOnlyRegistrySpecIsTraceAndWriteFree() async throws {
        let previous = replaceOperationTraceCoverageFlag(with: "1")
        defer { _ = replaceOperationTraceCoverageFlag(with: previous) }

        let projectRoot = try makeExecTempDir()
        let outputRoot = try makeExecTempDir()
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: outputRoot)
        }
        let project = try makeLogicxProject(in: projectRoot, named: "Trace ReadOnly")
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
            await router.register(OperationTraceReadOnlyProbeChannel(id: channelID))
        }
        let cache = StateCache()
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
            supportBundleExporter: { _, _ in
                throw NSError(domain: "operation-trace-read-only-census", code: 1)
            },
            projectLifecycleExecute: { _ in
                ProjectDispatcher.LifecycleExecution(
                    executionError: nil,
                    timedOut: false,
                    terminationStatus: 0,
                    stderrOutput: ""
                )
            }
        )

        let readOnlySpecs = OperationRegistry.specs.filter { $0.mutability == .readOnly }
        let mutatingSpecs = OperationRegistry.specs.filter { $0.mutability == Mutability.`mutating` }
        #expect(OperationRegistry.specs.count == 110)
        #expect(readOnlySpecs.count == 23)
        // Mutability is total: the mutating census (87) and this inverse gate
        // (23) together account for every registered spec, so a new operation
        // cannot land outside both gates.
        #expect(readOnlySpecs.count + mutatingSpecs.count == OperationRegistry.specs.count)

        for spec in readOnlySpecs {
            let handler = try #require(
                OperationHandlerRegistry.handler(for: spec.id),
                Comment(rawValue: "\(spec.id.rawValue) has no bound handler")
            )
            await OperationTraceStore.shared.clear()
            let boundaryProbe = WriteBoundaryProbe()
            _ = await OperationTraceParentBoundary.$onWriteBoundary.withValue({
                await boundaryProbe.record()
            }) {
                await handler(
                    dependencies,
                    operationTraceCoverageParams(for: spec.id, fixtures: fixtures)
                )
            }

            let boundaryCount = await boundaryProbe.count
            #expect(
                boundaryCount == 0,
                Comment(rawValue: "Read-only command crossed a write boundary: \(spec.id.rawValue)")
            )
            let traces = await OperationTraceStore.shared.recent(limit: 128)
            #expect(
                traces.isEmpty,
                Comment(rawValue: "Read-only command traced: \(spec.tool.rawValue).\(spec.command)")
            )
            #expect(
                !traces.contains { trace in
                    trace.events.contains { $0.phase == .writeBoundaryCrossed }
                },
                Comment(rawValue: "Read-only command recorded writeBoundaryCrossed: \(spec.id.rawValue)")
            )
        }

        await OperationTraceStore.shared.clear()
    }

    /// #389 store-wide ORDERING census. For every mutating registry spec, no
    /// trace may place `writeBoundaryCrossed` before its first `channelStarted`:
    /// the boundary is committed BY the router at the channel it dispatches, so
    /// a boundary that precedes every channel is a boundary the op never crossed.
    /// Traces that have one phase but not the other are exempt — non-router
    /// writers (export/AppleScript) legitimately have a boundary and no channel,
    /// and a route that dispatched nothing legitimately has neither.
    @Test func OperationTraceWriteBoundaryNeverPrecedesChannelStartedCensus() async throws {
        let previous = replaceOperationTraceCoverageFlag(with: "1")
        defer { _ = replaceOperationTraceCoverageFlag(with: previous) }
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }

        let context = try await makeOperationTraceCensusContext()
        defer { context.cleanup() }

        var tracesWithBoth = 0
        for spec in context.mutatingSpecs {
            await OperationTraceStore.shared.clear()
            let traceContext = OperationTraceContext(mutationGateAcquired: true)
            _ = await OperationTraceContext.$current.withValue(traceContext) {
                await dispatchOperationTraceCoverageSpec(
                    spec,
                    params: operationTraceCoverageParams(for: spec.id, fixtures: context.fixtures),
                    router: context.router,
                    cache: context.cache
                )
            }
            for trace in await OperationTraceStore.shared.recent(limit: 128) {
                let phases = trace.events.map(\.phase)
                guard let boundary = phases.firstIndex(of: .writeBoundaryCrossed),
                      let firstChannel = phases.firstIndex(of: .channelStarted) else { continue }
                tracesWithBoth += 1
                #expect(
                    boundary >= firstChannel,
                    Comment(rawValue: "\(spec.id.rawValue): writeBoundaryCrossed at \(boundary) precedes first channelStarted at \(firstChannel)")
                )
            }
        }
        // Guard the guard: if no traced op ever produced both phases the loop
        // above would pass vacuously and prove nothing.
        #expect(tracesWithBoth > 0, "ordering census exercised no trace with both phases")

        await OperationTraceStore.shared.clear()
    }

    /// #389 store-wide PRESENCE census — the failure mode ordering is blind to.
    /// An op whose arm was forgotten (or whose scope closed before the route)
    /// records channels but NO boundary, and every ordering assertion still
    /// passes because the phase simply is not there. For each mutating spec that
    /// dispatched a channel under an armed write path, assert the boundary EXISTS
    /// at/after that channel.
    @Test func OperationTraceWriteBoundaryPresentForDispatchedMutationsCensus() async throws {
        let previous = replaceOperationTraceCoverageFlag(with: "1")
        defer { _ = replaceOperationTraceCoverageFlag(with: previous) }
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }

        let context = try await makeOperationTraceCensusContext()
        defer { context.cleanup() }

        // `eligible` = ops observed dispatching a channel in THIS run; `covered`
        // = those that also carried the boundary. The invariant is equality:
        // every op that reached a channel crossed a write boundary and must say
        // so. Deriving `eligible` from the run (rather than a hardcoded floor)
        // means a regression that silently drops armed coverage is caught at any
        // scale, not just below an arbitrary threshold.
        var eligible: [String] = []
        var covered: [String] = []
        for spec in context.mutatingSpecs {
            await OperationTraceStore.shared.clear()
            let traceContext = OperationTraceContext(mutationGateAcquired: true)
            // The probe counts commits independently of the store, so an op that
            // dispatches a channel with a nil/unregistered trace is still seen.
            let boundaryProbe = WriteBoundaryProbe()
            _ = await OperationTraceParentBoundary.$onWriteBoundary.withValue({
                await boundaryProbe.record()
            }) {
                await OperationTraceContext.$current.withValue(traceContext) {
                    await dispatchOperationTraceCoverageSpec(
                        spec,
                        params: operationTraceCoverageParams(for: spec.id, fixtures: context.fixtures),
                        router: context.router,
                        cache: context.cache
                    )
                }
            }

            guard let trace = await OperationTraceStore.shared.recent(limit: 128)
                .first(where: { $0.operationID == spec.id.rawValue }) else { continue }
            let phases = trace.events.map(\.phase)
            guard let firstChannel = phases.firstIndex(of: .channelStarted) else { continue }
            eligible.append(spec.id.rawValue)
            // A channel executed for a mutating op ⇒ the write boundary was
            // crossed and must be recorded at/after that channel.
            guard let boundary = phases.firstIndex(of: .writeBoundaryCrossed) else {
                Issue.record(Comment(rawValue: "\(spec.id.rawValue): dispatched a channel but recorded NO writeBoundaryCrossed"))
                continue
            }
            #expect(
                boundary >= firstChannel,
                Comment(rawValue: "\(spec.id.rawValue): boundary at \(boundary) precedes channelStarted at \(firstChannel)")
            )
            #expect(
                await boundaryProbe.count > 0,
                Comment(rawValue: "\(spec.id.rawValue): recorded a boundary but never fired the parent hook")
            )
            covered.append(spec.id.rawValue)
        }
        // The honest invariant: channel-dispatching ⇒ boundary-carrying, for
        // every op, with no coverage floor to hide behind.
        let missing = Set(eligible).subtracting(covered).sorted()
        #expect(
            covered.count == eligible.count,
            Comment(rawValue: "\(missing.count)/\(eligible.count) channel-dispatching ops carried no write boundary: \(missing)")
        )
        // Guard the guard: a refactor that stopped dispatching channels entirely
        // would make the equality above hold vacuously (0 == 0).
        #expect(
            eligible.count >= 40,
            Comment(rawValue: "presence census only saw \(eligible.count) channel-dispatching ops: \(eligible.sorted())")
        )

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

/// PRD-007: the LIVE header surface the corroborated ops check against. Single
/// unique row so the seed-set ops clear the binding gate and their traced write
/// path stays exercised by this census.
let operationTraceCoverageTrackName = "Trace Coverage Track"
private let operationTraceCoverageLiveTrackNames: @Sendable () -> [Int: String]? = {
    [0: operationTraceCoverageTrackName]
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
            cache: cache,
            liveTrackNames: operationTraceCoverageLiveTrackNames
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
            cache: cache,
            liveTrackNames: operationTraceCoverageLiveTrackNames
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
            // PRD-007 `.corroborated`: the binding gate precedes the traced
            // write, so the trace census must clear it.
            OperationRegistry.corroborationParam: .string(operationTraceCoverageTrackName),
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
    case .tracksSelect, .tracksArmOnly:
        return ["index": .int(0)]
    case .tracksDelete, .tracksDuplicate:
        return [
            "index": .int(0),
            OperationRegistry.corroborationParam: .string(operationTraceCoverageTrackName),
        ]
    case .tracksRename:
        return ["index": .int(0), "name": .string("Trace Coverage")]
    case .tracksMute, .tracksSolo, .tracksArm:
        return ["index": .int(0), "enabled": .bool(true)]
    case .tracksRecordSequence:
        return ["notes": .string("60,0,100")]
    case .tracksSetAutomation:
        return ["index": .int(0), "mode": .string("read")]
    case .tracksSetInstrument:
        return [
            "index": .int(0),
            "path": .string("Pianos/Trace Coverage.patch"),
            OperationRegistry.corroborationParam: .string(operationTraceCoverageTrackName),
        ]
    case .tracksResolvePath:
        return ["path": .string("Pianos/Trace Coverage.patch")]
    case .audioAnalyzeFile:
        return ["path": .string("/tmp/trace-coverage-missing.wav")]
    default:
        return [:]
    }
}
