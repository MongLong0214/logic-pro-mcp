import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #965 t2: `logic_project.inspect_session` through the real dispatcher.
///
/// Every case drives `ProjectDispatcher.handle` with a `ChannelRouter()` that has no channels,
/// the inert project-file reader and a headless `StateCache`, so nothing here can reach Logic
/// (#866). The producer's rules are covered by `Issue965SessionPopulationTests`; these tests
/// cover the wiring: parameter parsing, the State C refusals, stable-reference parity with
/// `logic://tracks`, and the strict-validation census entry.
@Suite("#965 inspect_session command", .serialized)
struct Issue965InspectSessionCommandTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func populatedCache() async -> StateCache {
        let cache = StateCache()
        var project = ProjectInfo(name: "Session", filePath: "/tmp/Session.logicx")
        project.lastUpdated = Self.fixedDate
        await cache.updateProject(project)
        await cache.updateTracks([
            TrackState(id: 0, name: "Kick", type: .audio),
            TrackState(id: 1, name: "Snare", type: .audio),
            TrackState(id: 2, name: "Bass", type: .audio),
        ])
        return cache
    }

    private func inspect(
        _ params: [String: Value],
        cache: StateCache,
        targetRegistry: TargetRegistry?
    ) async -> CallTool.Result {
        await ProjectDispatcher.handle(
            command: "inspect_session",
            params: params,
            router: ChannelRouter(),
            cache: cache,
            targetRegistry: targetRegistry,
            cleanupAuditFileReader: .unavailable
        )
    }

    private func successBody(_ result: CallTool.Result) throws -> [String: Any] {
        let isError = result.isError ?? false
        #expect(!isError)
        return try #require(sharedJSONObject(sharedToolText(result)))
    }

    private func stateCBody(_ result: CallTool.Result) throws -> [String: Any] {
        let isError = try #require(result.isError)
        #expect(isError)
        let body = try #require(sharedJSONObject(sharedToolText(result)))
        #expect(body["state"] as? String == "C")
        let writeAttempted = try #require(body["write_attempted"] as? Bool)
        #expect(!writeAttempted)
        return body
    }

    private func section(_ body: [String: Any], _ key: String) throws -> [String: Any] {
        try #require(body[key] as? [String: Any], Comment(rawValue: key))
    }

    @Test("an empty cache is reported as unread, not as an empty session")
    func emptyCacheIsUnavailableNotEmpty() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let result = await inspect([:], cache: StateCache(), targetRegistry: nil)
            let body = try successBody(result)

            #expect(body["schema"] as? String == SessionPopulationObservation.schema)
            let readOnly = try #require(body["read_only"] as? Bool)
            #expect(readOnly)
            #expect(body["scope"] as? String == "whole_project")
            #expect(body["requested_domains"] as? [String] == ["tracks", "strips", "associations", "hierarchy"])

            let tracks = try section(body, "tracks")
            #expect(tracks["coverage"] as? String == "unavailable")
            let reasons = try #require(tracks["reasons"] as? [String])
            #expect(reasons.contains("no_live_track_read_yet"))
            let rows = try #require(tracks["rows"] as? [[String: Any]])
            #expect(rows.isEmpty)

            let overall = try section(body, "overall")
            let complete = try #require(overall["complete"] as? Bool)
            #expect(!complete)

            let project = try section(body, "project")
            #expect(project["status"] as? String == "references_disabled")
            #expect(project["project_ref"] == nil)

            let uiEffects = try section(body, "ui_effects")
            let navigated = try #require(uiEffects["navigation_performed"] as? Bool)
            #expect(!navigated)
            #expect(uiEffects["restoration"] as? String == "not_applicable")
        }
    }

    @Test("track references match logic://tracks on the same cache and registry")
    func trackRefsMatchTheTracksResource() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await populatedCache()
            let registry = TargetRegistry()

            let resource = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry,
                fileReader: .unavailable
            )
            let envelope = try #require(sharedJSONObject(sharedResourceText(resource)))
            let resourceRows = try #require(envelope["data"] as? [[String: Any]])
            var resourceRefs: [Int: String] = [:]
            for row in resourceRows {
                let index = try #require(row["id"] as? Int)
                resourceRefs[index] = try #require(row["track_ref"] as? String)
            }
            #expect(resourceRefs.count == 3)

            let result = await inspect([:], cache: cache, targetRegistry: registry)
            let body = try successBody(result)
            let tracks = try section(body, "tracks")
            let reportRows = try #require(tracks["rows"] as? [[String: Any]])
            var reportRefs: [Int: String] = [:]
            for row in reportRows {
                let index = try #require(row["track_index"] as? Int)
                reportRefs[index] = try #require(row["track_ref"] as? String)
            }
            #expect(reportRefs == resourceRefs)

            // Without a project-file count nothing rules out rows the rail does
            // not show, so a populated cache is `partial`, never `complete`.
            #expect(tracks["coverage"] as? String == "partial")
            let reasons = try #require(tracks["reasons"] as? [String])
            #expect(reasons.contains("hidden_tracks_unobserved"))
            let overall = try section(body, "overall")
            let complete = try #require(overall["complete"] as? Bool)
            #expect(!complete)

            let project = try section(body, "project")
            #expect(project["status"] as? String == "issued")
            let projectRef = try #require(project["project_ref"] as? String)
            #expect(!projectRef.isEmpty)
        }
    }

    @Test("allow_ui_navigation=true is refused as not_implemented with no report data")
    func allowUINavigationIsRefusedWithoutAReport() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = await populatedCache()
            let result = await inspect(
                ["allow_ui_navigation": .bool(true)],
                cache: cache,
                targetRegistry: nil
            )
            let body = try stateCBody(result)
            #expect(body["error"] as? String == "not_implemented")
            let navigated = try #require(body["navigation_performed"] as? Bool)
            #expect(!navigated)
            let hint = try #require(body["hint"] as? String)
            #expect(hint.contains("allow_ui_navigation"))
            #expect(body["tracks"] == nil)
            #expect(body["rows"] == nil)
            #expect(body["schema"] == nil)
        }
    }

    @Test("wrong types, unknown members and an empty domains list are invalid_params")
    func invalidDomainsAndScopeAreRejected() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = await populatedCache()
            let rejected: [(String, [String: Value])] = [
                ("unknown domain", ["domains": .array([.string("tracks"), .string("vibes")])]),
                ("domains not an array", ["domains": .string("tracks")]),
                ("non-string domain", ["domains": .array([.int(1)])]),
                ("empty domains", ["domains": .array([])]),
                ("unknown scope", ["scope": .string("everything")]),
                ("scope not a string", ["scope": .int(1)]),
                ("allow_ui_navigation not a bool", ["allow_ui_navigation": .string("yes")]),
            ]
            for (label, params) in rejected {
                let result = await inspect(params, cache: cache, targetRegistry: nil)
                let body = try stateCBody(result)
                #expect(body["error"] as? String == "invalid_params", Comment(rawValue: label))
                #expect(body["tracks"] == nil, Comment(rawValue: label))
            }
        }
    }

    @Test("scope and domains are echoed, and unrequested domains are absent")
    func scopeAndDomainsAreEchoed() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            let cache = await populatedCache()
            let result = await inspect(
                [
                    "scope": .string("selection"),
                    "domains": .array([.string("tracks"), .string("routing"), .string("tracks")]),
                    "allow_ui_navigation": .bool(false),
                ],
                cache: cache,
                targetRegistry: nil
            )
            let body = try successBody(result)
            #expect(body["scope"] as? String == "selection")
            #expect(body["requested_domains"] as? [String] == ["tracks", "routing"])
            let routing = try section(body, "routing")
            #expect(routing["coverage"] as? String == "unavailable")
            #expect(body["color"] == nil)
            let overall = try section(body, "overall")
            let complete = try #require(overall["complete"] as? Bool)
            #expect(!complete)
            #expect(overall["incomplete_domains"] as? [String] == ["tracks", "routing"])
        }
    }

    /// #291. Kills: a hard-coded routing section, or one built from a different read than
    /// `logic://mixer` — graph coverage must match over the same unchanged cache and registry,
    /// while the section ID belongs to its enclosing report, not a separate resource capture.
    @Test("the routing section carries matching graph coverage and its own capture identity")
    func routingSectionMirrorsTheMixerGraph() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await populatedCache()
            var busStrip = ChannelStripState(trackIndex: 0, output: "Bus 4")
            busStrip.sendSlots = []
            await cache.updateChannelStrips([busStrip, ChannelStripState(trackIndex: 1, output: "Stereo Output")])
            let registry = TargetRegistry()

            let mixer = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry
            )
            let mixerBody = try #require(sharedJSONObject(sharedResourceText(mixer)))
            let graph = try #require(mixerBody["routing_graph"] as? [String: Any])
            let graphCoverage = try #require(graph["coverage"] as? [String: Any])

            let result = await inspect(
                ["domains": .array([.string("routing")])],
                cache: cache,
                targetRegistry: registry
            )
            let body = try successBody(result)
            let routing = try section(body, "routing")
            let sectionGraph = try #require(routing["graph"] as? [String: Any])

            #expect(routing["coverage"] as? String == "partial")
            #expect(routing["reasons"] as? [String] == ["routing_graph_partial"])
            #expect(NSDictionary(dictionary: sectionGraph).isEqual(to: graphCoverage))
            let reportID = try #require(body["snapshot_id"] as? String)
            let routingID = try #require(routing["snapshot_id"] as? String)
            let mixerID = try #require(graph["snapshot_id"] as? String)
            #expect(routingID == reportID)
            #expect(reportID != mixerID)
            #expect(!reportID.isEmpty)
            let edges = try #require(graph["edges"] as? [[String: Any]])
            #expect(edges.map { $0["destination"] as? String } == ["bus_4"])
        }
    }

    @Test("a stale, foreign or malformed project_ref is refused before any capture")
    func staleProjectRefIsRefused() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await populatedCache()
            let registry = TargetRegistry()
            let info = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry,
                fileReader: .unavailable
            )
            let infoEnvelope = try #require(sharedJSONObject(sharedResourceText(info)))
            let infoData = try #require(infoEnvelope["data"] as? [String: Any])
            let projectRef = try #require(infoData["project_ref"] as? String)

            // The reference is current: the command accepts it and echoes it.
            let fresh = await inspect(["project_ref": .string(projectRef)], cache: cache, targetRegistry: registry)
            let freshBody = try successBody(fresh)
            let freshProject = try section(freshBody, "project")
            #expect(freshProject["project_ref"] as? String == projectRef)

            await registry.bumpProjectEpoch()
            for raw in [projectRef, "prj_malformed"] {
                let result = await inspect(["project_ref": .string(raw)], cache: cache, targetRegistry: registry)
                let body = try stateCBody(result)
                #expect(body["error"] as? String == "stale_target_reference", Comment(rawValue: raw))
                #expect(body["tracks"] == nil, Comment(rawValue: raw))
            }
        }
    }

    // SP-04: Logic switched to another project outside the server. The poller wrote it to the
    // cache, and no reader has bound it, so the registry still accepts the old project's ref.
    @Test("a project_ref the registry still accepts but the cache has left is refused, and nothing is bound")
    func projectRefForTheProjectTheCacheLeftIsRefused() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = await populatedCache()
            let registry = TargetRegistry()
            let info = try await ResourceHandlers.read(
                uri: "logic://project/info",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry,
                fileReader: .unavailable
            )
            let infoEnvelope = try #require(sharedJSONObject(sharedResourceText(info)))
            let infoData = try #require(infoEnvelope["data"] as? [String: Any])
            let projectRef = try #require(infoData["project_ref"] as? String)
            let boundBefore = try #require(await registry.currentProjectIdentity)

            var other = ProjectInfo(name: "Other", filePath: "/tmp/Other.logicx")
            other.lastUpdated = Self.fixedDate
            await cache.updateProject(other)
            await cache.updateTracks([TrackState(id: 0, name: "Pad", type: .audio)])
            // The scenario, not a registry bump: the ref still passes the pre-capture validator.
            let stillAccepted = await registry.resolveCurrentProject(TargetReference(rawValue: projectRef))
            #expect(stillAccepted != nil)

            let result = await inspect(["project_ref": .string(projectRef)], cache: cache, targetRegistry: registry)
            let body = try stateCBody(result)
            #expect(body["error"] as? String == "stale_target_reference")
            #expect(body["project_ref"] as? String == projectRef)
            #expect(body["schema"] == nil)
            #expect(body["project"] == nil)
            #expect(body["tracks"] == nil)
            let text = sharedToolText(result)
            #expect(!text.contains("Other"))
            #expect(!text.contains("Pad"))
            // Binding the captured project would have replaced the registry's current project.
            let boundAfter = try #require(await registry.currentProjectIdentity)
            #expect(boundAfter == boundBefore)
        }
    }

    @Test("strict validation rejects an unknown param and admits the declared ones")
    func unknownParamsAreRejectedByStrictValidation() throws {
        let rejected = try #require(LogicProServer.strictParamValidationResult(
            tool: ToolID.logicProject.rawValue,
            command: "inspect_session",
            params: ["index": .int(0)]
        ))
        let body = try stateCBody(rejected)
        #expect(body["error"] as? String == "invalid_params")
        #expect(body["unknown_params"] as? [String] == ["index"])

        let admitted = LogicProServer.strictParamValidationResult(
            tool: ToolID.logicProject.rawValue,
            command: "inspect_session",
            params: [
                "allow_ui_navigation": .bool(false),
                "domains": .array([.string("tracks")]),
                "project_ref": .string("prj_any"),
                "scope": .string("whole_project"),
            ]
        )
        #expect(admitted == nil)
    }
}
