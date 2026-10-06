@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Suite("#965 inspect_session reaches fresh population acquisition", .serialized)
struct Issue965FreshPopulationAcquisitionTests {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var attributes: [String] = []
        func record(_ attribute: String) { lock.withLock { attributes.append(attribute) } }
        var count: Int { lock.withLock { attributes.count } }
        var helpCount: Int { lock.withLock { attributes.filter { $0 == kAXHelpAttribute as String }.count } }
    }

    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let reads = Reads()
        let app: AXUIElement
        let window: AXUIElement
        let rail: AXUIElement
        let header: AXUIElement

        init() {
            app = builder.element(965_900)
            window = builder.element(965_901)
            rail = builder.element(965_902)
            header = builder.element(965_903)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(window, kAXTitleAttribute as String, "Session - Tracks")
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setRole(rail, kAXListRole as String)
            builder.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            builder.setRole(header, kAXLayoutItemRole as String)
            builder.setAttribute(header, kAXTitleAttribute as String, " Fresh track ")
            builder.setAttribute(header, kAXSelectedAttribute as String, false)
            builder.setChildren(header, [])
            builder.setChildren(rail, [header])
            builder.setChildren(window, [rail])
        }

        func channel(unreadableRail: Bool = false) -> AccessibilityChannel {
            AccessibilityChannel(runtime: .axBacked(
                isTrusted: { true }, isLogicProRunning: { true }, hasVisibleWindow: { true },
                logicRuntime: builder.makeLogicRuntime(
                    appElement: app,
                    attributeValueHandler: { _, attribute in reads.record(attribute); return nil },
                    childrenResultHandler: { element in
                        unreadableRail && CFEqual(element, rail)
                            ? .failure(.init(raw: AXError.cannotComplete.rawValue)) : nil
                    },
                    setAttributeHandler: nil, performActionHandler: nil,
                    executeAppleScript: { _ in .error("fixture forbids AppleScript") }
                )
            ))
        }
    }

    private func inspect(
        fixture: Fixture, unreadableRail: Bool = false, cancelBeforeRead: Bool = false,
        hasVisibleWindow: Bool = true,
        domains: [String] = ["tracks", "strips"],
        keyboardFocus: @escaping @Sendable () -> AccessibilityChannel.LogicKeyboardFocus = { .notTextEditing }
    ) async throws -> CallTool.Result {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Session"))
        await cache.updateTracks([TrackState(id: 0, name: "Old cached track", type: .audio)])
        await cache.updateChannelStrips([ChannelStripState(trackIndex: 0, name: "Old cached strip")])
        let gate = LogicMutationGate()
        let dependencies = HandlerDependencies(
            router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
            poller: StatePoller(axChannel: fixture.channel(unreadableRail: unreadableRail), cache: cache,
                                runtime: .init(hasVisibleWindow: { hasVisibleWindow }, projectFileReader: .unavailable,
                                               keyboardFocus: keyboardFocus)),
            dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
            liveTrackNames: { [:] }, projectFileReader: .unavailable
        )
        let handler = try #require(OperationHandlerRegistry.handler(
            tool: "logic_project", command: "inspect_session"
        ))
        let params: [String: Value] = ["domains": .array(domains.map(Value.string))]
        return await LogicProServer.runWithDeadline(
            tool: "logic_project", command: "inspect_session", commandParams: params,
            mutationGate: gate
        ) {
            if cancelBeforeRead { withUnsafeCurrentTask { $0?.cancel() } }
            return await handler(dependencies, params)
        }
    }

    @Test func registeredInspectionDoesNotRepublishTheOldCache() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Session"))
            await cache.updateTracks([TrackState(id: 0, name: "Old cached track", type: .audio)])
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(
                router: ChannelRouter(), cache: cache, targetRegistry: TargetRegistry(),
                poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable)),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: .unavailable
            )
            let handler = try #require(OperationHandlerRegistry.handler(
                tool: "logic_project", command: "inspect_session"
            ))
            let params: [String: Value] = ["domains": .array([.string("tracks")])]
            let result = await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", commandParams: params,
                mutationGate: gate
            ) { await handler(dependencies, params) }
            let isError = result.isError ?? false
            #expect(!isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "],
                    "a fresh request must read after its invocation, not re-date the old cache")
            #expect(tracks["coverage"] as? String == "partial")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func failedRequestedReadsDoNotBorrowOlderRows() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, unreadableRail: true)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            for key in ["tracks", "strips"] {
                let domain = try #require(body[key] as? [String: Any])
                #expect(domain["coverage"] as? String == "unavailable")
                #expect(try #require(domain["rows"] as? [[String: Any]]).isEmpty,
                        "an unread requested domain is not the cached population")
            }
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test(arguments: ["tracks", "strips"])
    func sourceAndCoverageDistinguishUnrequestedFromFailedDomains(requested: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, domains: [requested])
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let sources = try #require(body["sources"] as? [String: Any])
            let unrequested = requested == "tracks" ? "strips" : "tracks"
            let omitted = try #require(body[unrequested] as? [String: Any])
            #expect(omitted["coverage"] as? String == "unavailable")
            #expect(omitted["reasons"] as? [String] == ["domain_not_requested"])
            #expect(sources[unrequested] as? String == "not_requested")
            #expect(sources[requested] as? String == (requested == "tracks" ? "ax_request_read" : "ax_request_unavailable"))
        }
    }

    @Test func noVisibleWindowCannotEscapeTheInertPollerBoundary() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, hasVisibleWindow: false)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            for key in ["tracks", "strips"] {
                let domain = try #require(body[key] as? [String: Any])
                #expect(domain["coverage"] as? String == "unavailable")
                #expect(try #require(domain["rows"] as? [[String: Any]]).isEmpty)
            }
            #expect(fixture.reads.count == 0,
                    "the no-window runtime must not reach even injected AX, much less production AX")
        }
    }

    @Test(arguments: [false, true])
    func freshAcquisitionCannotEndAnInlineEdit(editingBeginsDuringRead: Bool) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, keyboardFocus: {
                !editingBeginsDuringRead || fixture.reads.count > 0
                    ? .textEditing(role: kAXTextFieldRole as String, byInsertionPoint: false)
                    : .notTextEditing
            })
            let isError = result.isError ?? false
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "readback_unavailable")
            #expect(body["snapshot_id"] == nil)
            #expect(fixture.reads.helpCount == 0,
                    "AXHelp is not a harmless read while the user is editing a name")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func cancellationBeforeAcquisitionProducesNoReplacementReport() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture, cancelBeforeRead: true)
            let isError = result.isError ?? false
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "cancelled")
            #expect(body["snapshot_id"] == nil)
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func unstableLivePopulationIsNotACurrentRepairBaseline() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = StateCache()
            let project = ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx")
            let tracks = [TrackState(id: 0, name: "Name before a concurrent edit", type: .audio)]
            await cache.updateProject(project)
            await cache.updateTracks(tracks)
            let boundary = await cache.captureBoundary(watching: SessionPopulationObservation.watchedSections)
            let now = Date()
            let accepted = try #require(await cache.acceptFreshPopulation(
                .init(project: project, tracks: tracks, strips: [], fileTrackCount: nil,
                      beganAt: now, endedAt: now, stable: false),
                ifCurrent: boundary, stoppingWhen: { false }
            ))
            let capture = await SessionPopulationObservation.capture(
                cache: cache, targetRegistry: nil, fileReader: .unavailable, accepted: accepted
            )
            #expect(capture.before == capture.after,
                    "the counterexample requires an unchanged cache but changing live observations")
            #expect(!(await cache.inspectionIsCurrent(capture)))
            #expect(SessionPopulationObservation.trackRowReadbackReasons(capture: capture)
                .contains(.livePopulationMoved))
            let report = SessionPopulationObservation.build(
                request: .init(domains: [.tracks, .strips, .associations, .hierarchy, .routing, .color]),
                capture: capture
            )
            for reasons in [report.tracks.reasons, report.strips.reasons, report.associations.reasons,
                            report.hierarchy.reasons, report.routing?.reasons ?? [], report.color?.reasons ?? []] {
                #expect(reasons.contains(.livePopulationMoved),
                        "live instability must not be misreported as a cache movement")
            }
        }
    }

    @Test func cancelledTasksCannotMintTrackOrProjectReferences() async throws {
        let registry = TargetRegistry()
        let snapshot = await registry.currentSnapshot
        let project = ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx")
        let track = TrackState(id: 0, name: "Fresh name", type: .audio)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let tracks = await TrackReferenceIssuance.issue(for: [track], registry: registry, snapshot: snapshot)
            let projectResult = await ProjectReferenceIssuance.issue(cached: project, registry: registry, snapshot: snapshot)
            return (tracks, projectResult)
        }
        let (tracks, projectResult) = await task.value
        #expect(tracks == nil)
        if case .stale = projectResult {} else { Issue.record("cancelled project issuance minted a target") }
        let trackDescriptor = TargetDescriptor(trackIndex: track.id, trackName: track.name)
        #expect(await registry.issuedReference(kind: .track, descriptor: trackDescriptor,
                                               fingerprint: trackDescriptor.fingerprint, snapshot: snapshot) == nil)
        let projectDescriptor = try #require(ProjectReferenceIssuance.descriptor(
            name: project.name, filePath: project.filePath, epoch: snapshot.projectEpoch
        ))
        #expect(await registry.issuedReference(kind: .project, descriptor: projectDescriptor,
                                               fingerprint: projectDescriptor.fingerprint, snapshot: snapshot) == nil)
    }

    @Test func cancelledPublicationCannotRetainANewReport() async throws {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx"))
        let epoch = await cache.auditSnapshot().projectEpoch
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.retainSessionReport(id: "cancelled-report", json: "{}",
                                                  capturedEpoch: epoch, capturedPath: "/tmp/Session.logicx")
        }
        #expect(!(await task.value))
        #expect(await cache.retainedSessionReport(id: "cancelled-report") == nil)
    }

    @Test func unboundFreshRowsCannotIssueProjectScopedTargets() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = Fixture()
            let result = try await inspect(fixture: fixture)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let tracks = try #require(body["tracks"] as? [String: Any])
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.compactMap { $0["name"] as? String } == [" Fresh track "])
            #expect(rows.allSatisfy { $0["track_ref"] == nil },
                    "unbound fresh rows are readable observations, not project-scoped write targets")
            #expect(tracks["coverage"] as? String == "partial")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }

    @Test func externalDocumentSwitchCannotReuseAnEarlierTrackReference() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let fixture = Fixture()
            let ownedDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lpm965-fresh-targets-" + UUID().uuidString, isDirectory: true)
            let oldBundle = ownedDirectory.appendingPathComponent("Old.logicx", isDirectory: true)
            let newBundle = ownedDirectory.appendingPathComponent("New.logicx", isDirectory: true)
            try FileManager.default.createDirectory(at: oldBundle, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: ownedDirectory) }
            fixture.builder.setAttribute(fixture.window, kAXDocumentAttribute as String, newBundle.absoluteString)
            let cache = StateCache()
            let oldProject = ProjectInfo(name: "Session", filePath: oldBundle.path)
            await cache.updateProject(oldProject)
            let registry = TargetRegistry()
            let oldSnapshot = await registry.currentSnapshot
            _ = await ProjectReferenceIssuance.issue(cached: oldProject, registry: registry, snapshot: oldSnapshot)
            let oldIssued = try #require(await TrackReferenceIssuance.issue(
                for: [TrackState(id: 0, name: " Fresh track ", type: .audio)],
                registry: registry, snapshot: oldSnapshot
            ))
            let oldReference = try #require(oldIssued.byRow.first ?? nil)
            let gate = LogicMutationGate()
            let dependencies = HandlerDependencies(
                router: ChannelRouter(), cache: cache, targetRegistry: registry,
                poller: StatePoller(axChannel: fixture.channel(), cache: cache,
                                    runtime: .init(hasVisibleWindow: { true }, projectFileReader: .unavailable)),
                dialogPresent: { false }, supportBundleExporter: nil, mutationGate: gate,
                liveTrackNames: { [:] }, projectFileReader: .unavailable
            )
            let handler = try #require(OperationHandlerRegistry.handler(tool: "logic_project", command: "inspect_session"))
            let params: [String: Value] = ["domains": .array([.string("tracks")])]
            let result = await LogicProServer.runWithDeadline(
                tool: "logic_project", command: "inspect_session", commandParams: params, mutationGate: gate
            ) { await handler(dependencies, params) }
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let project = try #require(body["project"] as? [String: Any])
            #expect(project["file_path"] as? String == newBundle.path)
            let rows = try #require((body["tracks"] as? [String: Any])?["rows"] as? [[String: Any]])
            #expect(rows.first?["track_ref"] as? String != oldReference.rawValue)
            #expect(await registry.resolve(oldReference) == nil,
                    "a matching raw name and ordinal in a different document is not the earlier target")
            #expect(fixture.builder.setCalls.isEmpty && fixture.builder.actionCalls.isEmpty)
        }
    }
}
