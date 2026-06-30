import Foundation
import MCP

/// Handles MCP resource read requests for logic:// URIs.
struct ResourceHandlers {

    /// v3.1.0 (T7) — produce ISO8601 + cache_age_sec fields that every state
    /// resource wraps its payload in. `fetchedAt` is the cache's own clock;
    /// `cache_age_sec` is recomputed at read time so clients see the true
    /// age at the moment the resource is requested. Passing nil / distantPast
    /// collapses to `cache_age_sec: null` so clients can distinguish "never
    /// populated" from "populated X seconds ago".
    static func cacheEnvelope(fetchedAt: Date?) -> (ageSec: Any, fetchedAtISO: Any) {
        guard let fetchedAt, fetchedAt > .distantPast else {
            return (NSNull(), NSNull())
        }
        let age = Date().timeIntervalSince(fetchedAt)
        let iso = ISO8601DateFormatter.cacheFormatter.string(from: fetchedAt)
        return (age, iso)
    }

    /// Wrap an already-encoded JSON body (e.g. `[{...}]` or `{...}`) in the
    /// T7 cache envelope. Returns
    /// `{"cache_age_sec":…,"fetched_at":…,"ax_occluded":…[,extras…],"data":<body>}`.
    ///
    /// `ax_occluded` (v3.1.4): true when the StatePoller most recently observed
    /// a modal dialog or plugin floating window stealing AX focus from the
    /// arrange window. While occluded, cache values are deliberately preserved
    /// (no zero-out flap) — clients should treat the cache as "frozen at last
    /// non-occluded read" and decide whether to act on potentially-stale data.
    /// Defaults to false when `axOccluded` is omitted (caller didn't have
    /// access to the cache flag, e.g. when wrapping a synthesized body).
    ///
    /// `extras` (v3.1.8 — Issue #7): optional map of additional fields injected
    /// between `ax_occluded` and `data`. Used by tier-merging readers
    /// (`readProjectInfo`, `readTracks`, `readMixer`) to expose `source` (data
    /// provenance) and `last_saved_age_sec` (file mtime delta). When nil or
    /// empty, the envelope shape is byte-identical to v3.1.7. Keys are
    /// serialised in deterministic (sorted) order; unsupported value types
    /// (NSDate, custom classes, etc.) are skipped silently.
    static func wrapWithCacheEnvelope(
        bodyJSON: String,
        fetchedAt: Date?,
        axOccluded: Bool = false,
        extras: [String: Any]? = nil
    ) -> String {
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart: String = {
            if let a = age as? Double { return "\(a)" }
            return "null"
        }()
        let isoPart: String = {
            if let s = iso as? String { return "\"\(s)\"" }
            return "null"
        }()
        let extrasPart = encodeExtrasFragment(extras)
        return "{\"cache_age_sec\":\(agePart),\"fetched_at\":\(isoPart),\"ax_occluded\":\(axOccluded)\(extrasPart),\"data\":\(bodyJSON)}"
    }

    /// Serialise the optional extras map into a fragment that splices between
    /// `ax_occluded` and `data`. Returns an empty string when nil/empty so the
    /// envelope shape is byte-identical to v3.1.7 for callers passing nil.
    static func encodeExtrasFragment(_ extras: [String: Any]?) -> String {
        guard let extras, !extras.isEmpty else { return "" }
        // Filter unsupported types defensively; sortedKeys for determinism.
        let safe = extras.filter { _, value in JSONSerialization.isValidJSONObject(["v": value]) }
        guard !safe.isEmpty else { return "" }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
              var s = String(data: data, encoding: .utf8) else {
            return ""
        }
        // Strip outer braces, prefix with ","
        guard s.hasPrefix("{"), s.hasSuffix("}") else { return "" }
        s.removeFirst()
        s.removeLast()
        return s.isEmpty ? "" : ",\(s)"
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let cacheFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension ResourceHandlers {

    /// Handle a ReadResource request by URI.
    /// `fileReader` (v3.1.8): injectable LogicProjectFileReader.Runtime for
    /// project-info / tracks tier-merge fallback. Defaults to production.
    static func read(
        uri: String,
        cache: StateCache,
        router: ChannelRouter,
        fileReader: LogicProjectFileReader.Runtime = .production
    ) async throws -> ReadResource.Result {
        // Health must be side-effect free so the resource stays aligned with the tool contract.
        if uri == "logic://system/health" {
            return try await readSystemHealth(cache: cache, router: router, uri: uri)
        }

        await cache.recordToolAccess()

        if uri == "logic://stock-plugins" || uri.hasPrefix("logic://stock-plugins/") || uri.hasPrefix("logic://stock-plugins?") {
            return try readStockPluginResource(uri: uri)
        }

        if uri == "logic://stock-instruments" || uri.hasPrefix("logic://stock-instruments/") || uri.hasPrefix("logic://stock-instruments?") {
            return try readStockInstrumentResource(uri: uri)
        }

        if uri == "logic://session-players" || uri.hasPrefix("logic://session-players/") || uri.hasPrefix("logic://session-players?") {
            return try readSessionPlayerResource(uri: uri)
        }

        if uri == "logic://workflow-plans" || uri.hasPrefix("logic://workflow-plans/") || uri.hasPrefix("logic://workflow-plans?") {
            return try readWorkflowPlanResource(uri: uri)
        }

        if uri == "logic://workflow-skills" || uri.hasPrefix("logic://workflow-skills/") || uri.hasPrefix("logic://workflow-skills?") {
            return try readWorkflowSkillResource(uri: uri)
        }

        // hasDocument gate removed (post-hardening): the StatePoller's view
        // of "document open" can flap during normal Logic UI activity (focus
        // switches, plugin windows). Sustained-read tests showed 80/200 reads
        // erroring even when Logic clearly has a project open. Cache returns
        // empty data when state is genuinely empty — let the client distinguish
        // empty from missing rather than blanket-erroring on stale flags.

        // Handle parameterized URIs like logic://tracks/{index}/regions and logic://tracks/{index}
        if uri.hasPrefix("logic://tracks/") {
            let remainder = String(uri.dropFirst("logic://tracks/".count))
            if remainder.hasSuffix("/regions") {
                let indexStr = String(remainder.dropLast("/regions".count))
                if let index = Int(indexStr) {
                    return try await readTrackRegions(at: index, cache: cache, router: router, uri: uri)
                }
            }
            if let index = Int(remainder) {
                return try await readTrack(at: index, cache: cache, uri: uri)
            }
        }

        // logic://mixer/{strip} — individual channel strip by index.
        if uri.hasPrefix("logic://mixer/") {
            let indexStr = String(uri.dropFirst("logic://mixer/".count))
            if let index = Int(indexStr) {
                return try await readMixerStrip(at: index, cache: cache, uri: uri)
            }
        }

        switch uri {
        case "logic://transport/state":
            return try await readTransportState(cache: cache, router: router, uri: uri)

        case "logic://tracks":
            return try await readTracks(cache: cache, uri: uri, fileReader: fileReader)

        case "logic://mixer":
            return try await readMixer(cache: cache, uri: uri)

        case "logic://markers":
            return try await readMarkers(cache: cache, uri: uri)

        case "logic://project/info":
            return try await readProjectInfo(cache: cache, uri: uri, fileReader: fileReader)

        case "logic://project/audit":
            return try await readProjectAudit(cache: cache, uri: uri)

        case "logic://project/cleanup-plan":
            return try await readProjectCleanupPlan(cache: cache, uri: uri)

        case "logic://midi/ports":
            return try await readMIDIPorts(router: router, uri: uri)

        case "logic://mcu/state":
            return try await readMCUState(cache: cache, uri: uri)

        case "logic://library/inventory":
            return try await readLibraryInventory(uri: uri)

        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    // MARK: - Individual resource handlers

    private static func readTransportState(cache: StateCache, router: ChannelRouter, uri: String) async throws -> ReadResource.Result {
        let liveRefresh = await readLiveTransportState(router: router)
        if let liveState = liveRefresh.state {
            await cache.updateTransport(liveState)
        }

        let state = await cache.getTransport()
        let hasDocument = await cache.getHasDocument()
        let axOccluded = await cache.getAXOccluded()
        // v3.1.1 (T-9) — unified `{cache_age_sec, fetched_at, data}` envelope.
        // v3.1.4 — `ax_occluded` added so clients can detect when the
        // StatePoller is preserving cache through a modal-dialog or
        // plugin-window AX occlusion.
        let inner = encodeJSON(state)
        let body = """
            {"state":\(inner),"has_document":\(hasDocument)}
            """
        let json = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: state.lastUpdated,
            axOccluded: axOccluded,
            extras: transportStateEnvelopeExtras(liveRefresh: liveRefresh, cachedState: state)
        )
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    struct LiveTransportStateReadback: Sendable {
        let state: TransportState?
        let errorCode: String?
    }

    /// Live transport refresh shared by the `logic://transport/state`
    /// resource and post-write dispatcher verification.
    static func readLiveTransportState(router: ChannelRouter) async -> LiveTransportStateReadback {
        let result = await router.route(operation: "transport.get_state")
        guard result.isSuccess else {
            return LiveTransportStateReadback(
                state: nil,
                errorCode: HonestContract.stateCErrorCode(result.message) ?? "live_transport_read_failed"
            )
        }
        guard let state = decodeTransportState(result.message) else {
            return LiveTransportStateReadback(
                state: nil,
                errorCode: "undecodable_live_transport_state"
            )
        }
        return LiveTransportStateReadback(state: state, errorCode: nil)
    }

    private static func transportStateEnvelopeExtras(
        liveRefresh: LiveTransportStateReadback,
        cachedState: TransportState
    ) -> [String: Any] {
        if liveRefresh.state != nil {
            return ["source": "ax_live"]
        }

        let hasCachedState = cachedState.lastUpdated > .distantPast
        var extras: [String: Any] = [
            "source": hasCachedState ? "cache" : "default",
            "unverified": true,
            "stale": hasCachedState,
            "recovery_hint": "live transport refresh unavailable; focus Logic's Tracks window, dismiss modal or plugin dialogs, then retry or run logic_system refresh_cache."
        ]
        if let errorCode = liveRefresh.errorCode {
            extras["refresh_error"] = errorCode
        }
        return extras
    }

    private static func decodeTransportState(_ json: String) -> TransportState? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid transport lastUpdated timestamp: \(value)"
            )
        }
        return try? decoder.decode(TransportState.self, from: data)
    }

    /// Stock plugin discovery routing. Parsed with `URLComponents` so path and
    /// query are matched exactly: unknown subpaths, nested segments, and stray
    /// query parameters fail closed instead of silently degrading to a search
    /// or a detail lookup.
    private static func readStockPluginResource(uri: String) throws -> ReadResource.Result {
        try validateRawCatalogURIEncoding(uri, host: "stock-plugins")
        guard let components = URLComponents(string: uri),
              components.scheme == "logic",
              components.host == "stock-plugins" else {
            throw MCPError.invalidParams("Malformed stock plugin resource URI: \(uri)")
        }
        guard components.fragment == nil else {
            throw MCPError.invalidParams("logic://stock-plugins resources do not accept URI fragments")
        }
        try validateCanonicalCatalogPath(components, host: "stock-plugins")
        try validateCatalogSearchQuery(components, baseURI: "logic://stock-plugins")
        let segments = components.path.split(separator: "/").map(String.init)
        // Reject doubled or trailing slashes ("//census", "census/") — the
        // canonical reconstruction must reproduce the raw path exactly.
        let canonicalPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard components.path == canonicalPath else {
            throw MCPError.invalidParams("Malformed stock plugin resource path: \(components.path)")
        }
        let queryItems = components.queryItems ?? []
        let unknownParams = queryItems.map(\.name).filter { $0 != "query" }

        if segments.isEmpty {
            guard queryItems.isEmpty else {
                throw MCPError.invalidParams("logic://stock-plugins does not accept query parameters")
            }
            return readStockPlugins(uri: uri)
        }
        guard segments.count == 1 else {
            throw MCPError.invalidParams("Unknown stock plugin resource path: \(components.path)")
        }
        let segment = segments[0]

        if segment == "search" {
            guard unknownParams.isEmpty else {
                throw MCPError.invalidParams("Unsupported search parameters: \(unknownParams.joined(separator: ", "))")
            }
            let queries = queryItems.filter { $0.name == "query" }
            guard queries.count <= 1 else {
                throw MCPError.invalidParams("logic://stock-plugins/search accepts at most one query parameter")
            }
            return readStockPluginSearch(uri: uri, query: queries.first?.value ?? "")
        }
        guard queryItems.isEmpty else {
            throw MCPError.invalidParams("logic://stock-plugins/\(segment) does not accept query parameters")
        }
        if segment == "census" { return readStockPluginCensus(uri: uri) }
        if segment == "capabilities" { return readStockPluginCapabilities(uri: uri) }
        return try readStockPluginDetail(uri: uri, id: segment)
    }

    /// Stock instrument intelligence routing. The search endpoint is scoped to
    /// stock instruments only; Session Players have their own root/detail
    /// namespace because the MCP write surface differs.
    private static func readStockInstrumentResource(uri: String) throws -> ReadResource.Result {
        try validateRawCatalogURIEncoding(uri, host: "stock-instruments")
        guard let components = URLComponents(string: uri),
              components.scheme == "logic",
              components.host == "stock-instruments" else {
            throw MCPError.invalidParams("Malformed stock instrument resource URI: \(uri)")
        }
        guard components.fragment == nil else {
            throw MCPError.invalidParams("logic://stock-instruments resources do not accept URI fragments")
        }
        try validateCanonicalCatalogPath(components, host: "stock-instruments")
        try validateCatalogSearchQuery(components, baseURI: "logic://stock-instruments")
        let segments = components.path.split(separator: "/").map(String.init)
        let canonicalPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard components.path == canonicalPath else {
            throw MCPError.invalidParams("Malformed stock instrument resource path: \(components.path)")
        }
        let queryItems = components.queryItems ?? []
        let unknownParams = queryItems.map(\.name).filter { $0 != "query" }

        if segments.isEmpty {
            guard queryItems.isEmpty else {
                throw MCPError.invalidParams("logic://stock-instruments does not accept query parameters")
            }
            return readStockInstruments(uri: uri)
        }
        guard segments.count == 1 else {
            throw MCPError.invalidParams("Unknown stock instrument resource path: \(components.path)")
        }
        let segment = segments[0]

        if segment == "search" {
            guard unknownParams.isEmpty else {
                throw MCPError.invalidParams("Unsupported search parameters: \(unknownParams.joined(separator: ", "))")
            }
            let queries = queryItems.filter { $0.name == "query" }
            guard queries.count <= 1 else {
                throw MCPError.invalidParams("logic://stock-instruments/search accepts at most one query parameter")
            }
            return readStockInstrumentSearch(uri: uri, query: queries.first?.value ?? "")
        }
        guard queryItems.isEmpty else {
            throw MCPError.invalidParams("logic://stock-instruments/\(segment) does not accept query parameters")
        }
        return try readStockInstrumentDetail(uri: uri, id: segment)
    }

    /// Session Player intelligence routing. No search endpoint is advertised
    /// for this small category catalog; callers read root or a single ID.
    private static func readSessionPlayerResource(uri: String) throws -> ReadResource.Result {
        try validateRawCatalogURIEncoding(uri, host: "session-players")
        guard let components = URLComponents(string: uri),
              components.scheme == "logic",
              components.host == "session-players" else {
            throw MCPError.invalidParams("Malformed session player resource URI: \(uri)")
        }
        guard components.fragment == nil else {
            throw MCPError.invalidParams("logic://session-players resources do not accept URI fragments")
        }
        try validateCanonicalCatalogPath(components, host: "session-players")
        let segments = components.path.split(separator: "/").map(String.init)
        let canonicalPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard components.path == canonicalPath else {
            throw MCPError.invalidParams("Malformed session player resource path: \(components.path)")
        }
        let queryItems = components.queryItems ?? []

        if segments.isEmpty {
            guard queryItems.isEmpty else {
                throw MCPError.invalidParams("logic://session-players does not accept query parameters")
            }
            return readSessionPlayers(uri: uri)
        }
        guard segments.count == 1 else {
            throw MCPError.invalidParams("Unknown session player resource path: \(components.path)")
        }
        let segment = segments[0]
        guard queryItems.isEmpty else {
            throw MCPError.invalidParams("logic://session-players/\(segment) does not accept query parameters")
        }
        return try readSessionPlayerDetail(uri: uri, id: segment)
    }

    /// Workflow plan routing. These resources are dry-run only: they parse a
    /// prompt into a JSON plan and never call tools, channels, or router.
    private static func readWorkflowPlanResource(uri: String) throws -> ReadResource.Result {
        try validateRawCatalogURIEncoding(uri, host: "workflow-plans")
        guard let components = URLComponents(string: uri),
              components.scheme == "logic",
              components.host == "workflow-plans" else {
            throw MCPError.invalidParams("Malformed workflow plan resource URI: \(uri)")
        }
        guard components.fragment == nil else {
            throw MCPError.invalidParams("logic://workflow-plans resources do not accept URI fragments")
        }
        try validateCanonicalCatalogPath(components, host: "workflow-plans")
        try validateWorkflowPlanPromptQuery(components, baseURI: "logic://workflow-plans/session")

        let segments = components.path.split(separator: "/").map(String.init)
        let canonicalPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard components.path == canonicalPath else {
            throw MCPError.invalidParams("Malformed workflow plan resource path: \(components.path)")
        }
        guard segments == ["session"] else {
            throw MCPError.invalidParams("Unknown workflow plan resource path: \(components.path)")
        }

        let prompts = (components.queryItems ?? []).filter { $0.name == "prompt" }
        guard prompts.count == 1 else {
            throw MCPError.invalidParams("logic://workflow-plans/session requires exactly one prompt query parameter")
        }
        let prompt = prompts[0].value ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("logic://workflow-plans/session prompt must be non-empty")
        }
        return readSessionPlan(uri: uri, prompt: prompt)
    }

    /// Workflow skill routing. Parsed with `URLComponents` so path and query
    /// are matched exactly: unknown subpaths, nested segments, and stray query
    /// parameters fail closed instead of silently degrading to a search or a
    /// detail lookup.
    private static func readWorkflowSkillResource(uri: String) throws -> ReadResource.Result {
        try validateRawCatalogURIEncoding(uri, host: "workflow-skills")
        guard let components = URLComponents(string: uri),
              components.scheme == "logic",
              components.host == "workflow-skills" else {
            throw MCPError.invalidParams("Malformed workflow skill resource URI: \(uri)")
        }
        guard components.fragment == nil else {
            throw MCPError.invalidParams("logic://workflow-skills resources do not accept URI fragments")
        }
        try validateCanonicalCatalogPath(components, host: "workflow-skills")
        try validateCatalogSearchQuery(components, baseURI: "logic://workflow-skills")
        let segments = components.path.split(separator: "/").map(String.init)
        // Reject doubled or trailing slashes ("//schema", "schema/") — the
        // canonical reconstruction must reproduce the raw path exactly.
        let canonicalPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard components.path == canonicalPath else {
            throw MCPError.invalidParams("Malformed workflow skill resource path: \(components.path)")
        }
        let queryItems = components.queryItems ?? []
        let unknownParams = queryItems.map(\.name).filter { $0 != "query" }

        if segments.isEmpty {
            guard queryItems.isEmpty else {
                throw MCPError.invalidParams("logic://workflow-skills does not accept query parameters")
            }
            return readWorkflowSkills(uri: uri)
        }
        guard segments.count == 1 else {
            throw MCPError.invalidParams("Unknown workflow skill resource path: \(components.path)")
        }
        let segment = segments[0]

        if segment == "search" {
            guard unknownParams.isEmpty else {
                throw MCPError.invalidParams("Unsupported search parameters: \(unknownParams.joined(separator: ", "))")
            }
            let queries = queryItems.filter { $0.name == "query" }
            guard queries.count <= 1 else {
                throw MCPError.invalidParams("logic://workflow-skills/search accepts at most one query parameter")
            }
            return readWorkflowSkillSearch(uri: uri, query: queries.first?.value ?? "")
        }
        guard queryItems.isEmpty else {
            throw MCPError.invalidParams("logic://workflow-skills/\(segment) does not accept query parameters")
        }
        if segment == "schema" { return readWorkflowSkillSchema(uri: uri) }
        return try readWorkflowSkillDetail(uri: uri, id: segment)
    }

    private static func validateRawCatalogURIEncoding(_ uri: String, host: String) throws {
        let prefix = "logic://\(host)"
        guard uri.hasPrefix(prefix) else { return }
        let rest = String(uri.dropFirst(prefix.count))
        let withoutFragment = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let pathAndQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let rawPath = pathAndQuery.first ?? ""
        guard !rawPath.contains("%") else {
            throw MCPError.invalidParams("Malformed \(host) resource path: \(rawPath)")
        }
        if pathAndQuery.count > 1 {
            let rawQuery = pathAndQuery[1]
            guard percentEscapesAreWellFormed(rawQuery) else {
                throw MCPError.invalidParams("Malformed search query encoding: \(rawQuery)")
            }
        }
    }

    private static func validateCanonicalCatalogPath(_ components: URLComponents, host: String) throws {
        // URLComponents exposes `path` decoded. Compare against the raw
        // percent-encoded path so `%63ensus` cannot alias the canonical
        // `/census` route.
        guard components.percentEncodedPath == components.path else {
            throw MCPError.invalidParams("Malformed \(host) resource path: \(components.percentEncodedPath)")
        }
    }

    private static func validateCatalogSearchQuery(_ components: URLComponents, baseURI: String) throws {
        guard let rawQuery = components.percentEncodedQuery else { return }
        guard percentEscapesAreWellFormed(rawQuery) else {
            throw MCPError.invalidParams("Malformed search query encoding: \(rawQuery)")
        }
        // Search resources accept percent-encoded query *values*, but the
        // parameter name itself is part of the routing surface and must remain
        // canonical (`query`), not an encoded alias such as `qu%65ry`.
        for rawPair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = rawPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == "query" else {
                throw MCPError.invalidParams("Unsupported search parameters in \(baseURI): \(rawPair)")
            }
        }
    }

    private static func validateWorkflowPlanPromptQuery(_ components: URLComponents, baseURI: String) throws {
        guard let rawQuery = components.percentEncodedQuery else {
            throw MCPError.invalidParams("\(baseURI) requires a prompt query parameter")
        }
        guard percentEscapesAreWellFormed(rawQuery) else {
            throw MCPError.invalidParams("Malformed prompt query encoding: \(rawQuery)")
        }
        for rawPair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = rawPair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == "prompt" else {
                throw MCPError.invalidParams("Unsupported workflow plan parameters in \(baseURI): \(rawPair)")
            }
        }
    }

    private static func percentEscapesAreWellFormed(_ raw: String) -> Bool {
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "%" else {
                index = raw.index(after: index)
                continue
            }
            let first = raw.index(after: index)
            guard first < raw.endIndex else { return false }
            let second = raw.index(after: first)
            guard second < raw.endIndex else { return false }
            guard raw[first].isHexDigit, raw[second].isHexDigit else { return false }
            index = raw.index(after: second)
        }
        return true
    }

    private static func readSessionPlan(uri: String, prompt: String) -> ReadResource.Result {
        let json = encodeJSON(SessionPlanGenerator.plan(prompt: prompt), compact: true)
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockPlugins(uri: String) -> ReadResource.Result {
        let json = encodeJSON(StockPluginCatalog.productionSnapshot, compact: true)
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockPluginDetail(uri: String, id: String) throws -> ReadResource.Result {
        let snapshot = StockPluginCatalog.productionSnapshot
        guard let entry = StockPluginCatalog.entry(id: id, snapshot: snapshot) else {
            throw MCPError.invalidParams("Unknown stock plugin id: \(id)")
        }
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "logic_version": snapshot.logicVersion ?? NSNull(),
            "catalog_source": snapshot.catalogSource,
            "entry": jsonObject(entry),
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockInstruments(uri: String) -> ReadResource.Result {
        let json = encodeJSON(StockInstrumentCatalog.stockInstrumentSnapshot, compact: true)
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockInstrumentDetail(uri: String, id: String) throws -> ReadResource.Result {
        let snapshot = StockInstrumentCatalog.stockInstrumentSnapshot
        guard let entry = StockInstrumentCatalog.entry(id: id, snapshot: snapshot) else {
            throw MCPError.invalidParams("Unknown stock instrument id: \(id)")
        }
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "catalog_kind": snapshot.catalogKind,
            "entry": jsonObject(entry),
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockInstrumentSearch(uri: String, query: String) -> ReadResource.Result {
        let snapshot = StockInstrumentCatalog.stockInstrumentSnapshot
        let entries = StockInstrumentCatalog.search(query: query, snapshot: snapshot).map(jsonObject)
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "catalog_kind": snapshot.catalogKind,
            "query": query,
            "entries": entries,
            "result_count": entries.count,
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readSessionPlayers(uri: String) -> ReadResource.Result {
        let json = encodeJSON(StockInstrumentCatalog.sessionPlayerSnapshot, compact: true)
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readSessionPlayerDetail(uri: String, id: String) throws -> ReadResource.Result {
        let snapshot = StockInstrumentCatalog.sessionPlayerSnapshot
        guard let entry = StockInstrumentCatalog.entry(id: id, snapshot: snapshot) else {
            throw MCPError.invalidParams("Unknown session player id: \(id)")
        }
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "catalog_kind": snapshot.catalogKind,
            "entry": jsonObject(entry),
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readWorkflowSkills(uri: String) -> ReadResource.Result {
        let json = encodeJSON(WorkflowSkillCatalog.defaultSnapshot(), compact: true)
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readWorkflowSkillDetail(uri: String, id: String) throws -> ReadResource.Result {
        let snapshot = WorkflowSkillCatalog.defaultSnapshot()
        guard let workflow = WorkflowSkillCatalog.workflow(id: id, snapshot: snapshot) else {
            throw MCPError.invalidParams("Unknown workflow skill id: \(id)")
        }
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "workflow": jsonObject(workflow),
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockPluginSearch(uri: String, query: String) -> ReadResource.Result {
        let snapshot = StockPluginCatalog.productionSnapshot
        let entries = StockPluginCatalog.search(query: query, snapshot: snapshot).map(jsonObject)
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "logic_version": snapshot.logicVersion ?? NSNull(),
            "catalog_source": snapshot.catalogSource,
            "query": query,
            "entries": entries,
            "result_count": entries.count,
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readWorkflowSkillSearch(uri: String, query: String) -> ReadResource.Result {
        let snapshot = WorkflowSkillCatalog.defaultSnapshot()
        let workflows = WorkflowSkillCatalog.search(query: query, snapshot: snapshot).map(jsonObject)
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "query": query,
            "workflows": workflows,
            "result_count": workflows.count,
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockPluginCensus(uri: String) -> ReadResource.Result {
        let snapshot = StockPluginCatalog.productionSnapshot
        let counts = Dictionary(grouping: snapshot.entries, by: { $0.availabilityState.rawValue })
            .mapValues(\.count)
        let json = encodeJSONObject([
            "schema_version": snapshot.schemaVersion,
            "generated_at": snapshot.generatedAt,
            "logic_version": snapshot.logicVersion ?? NSNull(),
            "locale": snapshot.locale,
            "catalog_source": snapshot.catalogSource,
            "plugin_count": snapshot.pluginCount,
            "entries_by_state": counts,
            "validation": jsonObject(snapshot.validation),
        ])
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readStockPluginCapabilities(uri: String) -> ReadResource.Result {
        let json = encodeJSONObject(StockPluginCatalog.capabilities())
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    private static func readWorkflowSkillSchema(uri: String) -> ReadResource.Result {
        let json = encodeJSONObject(WorkflowSkillCatalog.schema())
        return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
    }

    /// v3.1.8 (Issue #7) — tier-merged track list read.
    ///
    /// Tier order:
    ///   1. Cache (live AX poll). If non-empty AND not Inspector-contaminated,
    ///      surface as-is, source: "ax_live".
    ///   2. LogicProjectFileReader's `NumberOfTracks`. Synthesise placeholder
    ///      rows (`name: "Track 1".."Track \(N)"`, `placeholder: true`).
    ///      Source: "ax_live_with_file_count" if poller has run before but
    ///      came up empty; "project_file" if poller never ran.
    ///   3. Empty array. Source: "default".
    ///
    /// Inspector contamination guard (boomer P0 / E10): when AX traversal
    /// returns >= 3 entries whose names ALL end in `:`, treat the data as the
    /// Inspector subtree leaking through (Logic Pro 12.x failure mode where a
    /// non-arrange panel is focused). Drop those rows and fall to Tier 2/3.
    /// The threshold of 3 prevents a legitimate single track named "MyMix:"
    /// from triggering false-positive contamination detection.
    ///
    /// **Critical (G5)**: this function is read-only with respect to cache.
    /// Placeholder rows are NEVER written back via `cache.updateTracks(...)`.
    /// Doing so would poison name-routed write actions like
    /// `track.select { name: "Track 5" }` in `TrackDispatcher.swift:44`.
    private static func readTracks(
        cache: StateCache,
        uri: String,
        fileReader: LogicProjectFileReader.Runtime
    ) async throws -> ReadResource.Result {
        var liveTracks = await cache.getTracks()
        let cacheFetchedAt = await cache.getTracksFetchedAt()
        let axOccluded = await cache.getAXOccluded()

        // Inspector contamination guard.
        if tracksAreInspectorContaminated(liveTracks) {
            liveTracks = []
        }

        var tracksOut: [TrackState] = []
        var source: String

        if !liveTracks.isEmpty {
            tracksOut = liveTracks
            source = "ax_live"
        } else {
            // Tier 2: synthesise placeholders from file count.
            let metadata = await LogicProjectFileReader.read(runtime: fileReader)
            if let count = metadata?.trackCount, count > 0 {
                tracksOut = (0..<count).map { idx in
                    TrackState(
                        id: idx,
                        name: "Track \(idx + 1)",
                        type: .unknown,
                        placeholder: true
                    )
                }
                source = cacheFetchedAt > .distantPast
                    ? "ax_live_with_file_count"
                    : "project_file"
            } else {
                source = "default"
            }
        }

        let body = encodeJSON(tracksOut)
        let json = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: cacheFetchedAt,
            axOccluded: axOccluded,
            extras: ["source": source]
        )
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// #200: an out-of-range / empty-state indexed-template read returns a typed,
    /// classifiable resource body (State C `index_out_of_range`) instead of a raw
    /// JSON-RPC `-32602`. `availableIndices` is the EXACT set of valid indices for
    /// the collection — `0..<count` for the positionally-indexed track list, but
    /// the actual `trackIndex` values for the mixer (whose strips are keyed by
    /// `trackIndex`, NOT array position, so a strip set can be non-contiguous,
    /// e.g. {0, 2, 4}). The hint therefore never asserts a contiguous `0..<N`
    /// range (which would mislead a client past a gap); it points at the parent
    /// collection and the body carries `available_indices` as the machine truth.
    static func indexOutOfRangeResult(
        uri: String,
        requestedIndex: Int,
        availableIndices: [Int],
        collection: String
    ) -> ReadResource.Result {
        let body = HonestContract.encodeStateC(
            error: .indexOutOfRange,
            hint: "No \(collection) at index \(requestedIndex); \(availableIndices.count) \(collection)(s) available. Read the parent collection resource for the current valid indices.",
            extras: [
                "uri": uri,
                "requested_index": requestedIndex,
                "available_count": availableIndices.count,
                "available_indices": availableIndices,
                "collection": collection,
            ]
        )
        return ReadResource.Result(
            contents: [.text(body, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTrack(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        if let track = await cache.getTrack(at: index) {
            let json = encodeJSON(track)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        // Tracks are positionally indexed (`getTrack(at:)` uses `tracks.indices`),
        // so the valid set is 0..<count.
        return indexOutOfRangeResult(
            uri: uri,
            requestedIndex: index,
            availableIndices: Array(0..<(await cache.getTracks().count)),
            collection: "track"
        )
    }

    /// B1 (#11) — `data_source` for `logic://mixer` strips. Strip volume/pan
    /// come from two writers: the AX poller (`updateChannelStrips`, which
    /// advances `mixerFetchedAt`) and MCU echo (`updateFader`/`updatePan`,
    /// which does NOT). So this labels the *poll* freshness — the canonical
    /// "is the AX-derived strip array current?" signal — while the separate
    /// `mcu_*` triplet lets a verification harness reason about the MCU echo
    /// path independently. `.distantPast` means no successful mixer poll has
    /// happened (the AX poll requires the Mixer panel to be visible), so the
    /// honest label is `mixer_not_visible` rather than a false freshness claim.
    /// Threshold mirrors `readProjectInfo`'s 5s `ax_live` window.
    static func mixerDataSource(fetchedAt: Date, now: Date = Date(), freshThreshold: Double = 5.0) -> String {
        guard fetchedAt > .distantPast else { return "mixer_not_visible" }
        return now.timeIntervalSince(fetchedAt) <= freshThreshold ? "ax_poll" : "cache_stale"
    }

    private static func readMixer(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let strips = await cache.getChannelStrips()
        let conn = await cache.getMCUConnection()
        let fetchedAt = await cache.getMixerFetchedAt()
        let axOccluded = await cache.getAXOccluded()
        let stripsJSON = encodeJSON(strips)
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart = (age as? Double).map { "\($0)" } ?? "null"
        let isoPart = (iso as? String).map { "\"\($0)\"" } ?? "null"
        // B1 (#11): provenance + MCU triplet so a duplicate-and-readback harness
        // can decide whether to trust the strips. `registered` is kept as a
        // one-release alias of `mcu_registered` for existing parsers.
        let dataSource = mixerDataSource(fetchedAt: fetchedAt)
        let ageMsPart = conn.lastFeedbackAgeMs().map { "\($0)" } ?? "null"
        let json = """
            {"cache_age_sec":\(agePart),"data_source":"\(dataSource)","fetched_at":\(isoPart),"ax_occluded":\(axOccluded),"mcu_connected":\(conn.isConnected),"mcu_registered":\(conn.registeredAsDevice),"mcu_last_feedback_age_ms":\(ageMsPart),"registered":\(conn.registeredAsDevice),"strips":\(stripsJSON)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// v3.1.8 (Issue #7) — tier-merged project info read.
    ///
    /// Tier order:
    ///   1. Cache (live AX poll) — preferred when `lastUpdated > .distantPast`
    ///      (poller has written real data). Source: "ax_live" if recent
    ///      (< 5s), else "cache".
    ///   2. Live track cache — fills `trackCount` from the same trusted
    ///      cache used by `logic://tracks` when ProjectInfo itself is name-only
    ///      and file metadata has no positive count.
    ///   3. LogicProjectFileReader — reads MetaData.plist for tempo / tsig /
    ///      trackCount when live cache is at struct defaults. Source:
    ///      "project_file" + last_saved_age_sec extra.
    ///   4. Struct defaults (ProjectInfo()). Source: "default".
    ///
    /// **Critical**: this function is read-only — it MUST NOT call
    /// `cache.updateProject(...)`. The poller is the sole writer to cache
    /// for project state. Mixing file values into cache would poison live
    /// reads from other resource paths (cache is a shared mutable surface).
    private static func readProjectInfo(
        cache: StateCache,
        uri: String,
        fileReader: LogicProjectFileReader.Runtime
    ) async throws -> ReadResource.Result {
        let snapshot = await cache.auditSnapshot()
        let cached = snapshot.project
        let projectFetchedAt = snapshot.projectFetchedAt
        let cachedTransport = snapshot.transport
        let cachedTracks = snapshot.tracks
        let tracksFetchedAt = snapshot.tracksFetchedAt
        // Cache is "fresh" if either (a) the poller has timestamped a write,
        // or (b) ProjectInfo's own lastUpdated is non-default. Either signal
        // means downstream consumers wrote real data.
        let cacheFresh = projectFetchedAt > .distantPast || cached.lastUpdated > .distantPast
        let transportFresh = cachedTransport.lastUpdated > .distantPast

        // Per-field merge (boomer P0): the existing AX `defaultGetProjectInfo`
        // populates ONLY `name` + `lastUpdated`; tempo / timeSignature /
        // trackCount stay at struct defaults (120, "4/4", 0). A whole-record
        // "cache fresh wins" rule would therefore mask the file's correct
        // values whenever the poller has run at least once. Instead, we:
        //   1. Start with cached values (preserves the AX-only `name`).
        //   2. Fill tempo/sample-rate from live transport when available.
        //   3. Fill trackCount from the trusted live track cache when
        //      ProjectInfo itself is still at its default count.
        //   4. Fill any remaining defaults from file metadata.
        //   5. `source` is "ax_live"/"cache" if any non-default field came
        //      from cache; otherwise "project_file"; otherwise "default".
        let metadata = await LogicProjectFileReader.read(runtime: fileReader)

        var info = cacheFresh ? cached : ProjectInfo()

        var fileContributed = false
        var cacheContributedLive = false
        let cachedProjectReferenceDate = [cached.lastUpdated, projectFetchedAt]
            .filter { $0 > .distantPast }
            .max()
        var cacheContributionDates: [Date] = []

        // tempo
        if cacheFresh && cached.tempo != 120.0 {
            cacheContributedLive = true
            if let date = cachedProjectReferenceDate { cacheContributionDates.append(date) }
        } else if transportFresh {
            info.tempo = cachedTransport.tempo
            cacheContributedLive = true
            cacheContributionDates.append(cachedTransport.lastUpdated)
        } else if let tempo = metadata?.tempo {
            info.tempo = tempo
            fileContributed = true
        }
        if transportFresh {
            info.sampleRate = cachedTransport.sampleRate
        }
        // timeSignature
        if cacheFresh && cached.timeSignature != "4/4" {
            cacheContributedLive = true
            if let date = cachedProjectReferenceDate { cacheContributionDates.append(date) }
        } else if let tsig = metadata?.timeSignatureString {
            info.timeSignature = tsig
            fileContributed = true
        }
        // trackCount
        if cacheFresh && cached.trackCount != 0 {
            cacheContributedLive = true
            if let date = cachedProjectReferenceDate { cacheContributionDates.append(date) }
        } else if let trackCount = trustedLiveTrackCount(cachedTracks, fetchedAt: tracksFetchedAt) {
            info.trackCount = trackCount
            cacheContributedLive = true
            cacheContributionDates.append(tracksFetchedAt)
        } else if let count = metadata?.trackCount, count > 0 {
            info.trackCount = count
            fileContributed = true
        }
        // filePath / name from cache wins; if cache empty, file supplies
        if !cacheFresh, let bp = metadata?.bundlePath {
            info.filePath = bp.path
            info.lastUpdated = metadata?.metadataMTime ?? .distantPast
        }

        var source: String
        var lastSavedAgeSec: Double?
        if !cacheFresh && !fileContributed && !cacheContributedLive {
            source = "default"
        } else if cacheContributedLive {
            // Cache supplied at least one real value — promote to ax_live/cache.
            let referenceDate = cacheContributionDates.max()
                ?? cachedProjectReferenceDate
                ?? .distantPast
            let age = Date().timeIntervalSince(referenceDate)
            source = age < 5 ? "ax_live" : "cache"
        } else if fileContributed {
            source = "project_file"
            if let mt = metadata?.metadataMTime {
                lastSavedAgeSec = max(0, Date().timeIntervalSince(mt))
            }
        } else {
            // Edge: cache fresh but every field is at default (e.g. project just
            // opened, AX poller wrote name="Untitled" only, file unreadable).
            source = "ax_live"
        }
        info.source = source
        info.lastSavedAgeSec = lastSavedAgeSec

        var extras: [String: Any] = ["source": source]
        if let age = lastSavedAgeSec { extras["last_saved_age_sec"] = age }

        let body = encodeJSON(info)
        let cacheReferenceDate = cacheContributionDates.max() ?? cachedProjectReferenceDate
        let envelope = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: (source == "ax_live" || source == "cache") ? cacheReferenceDate : nil,
            axOccluded: snapshot.axOccluded,
            extras: extras
        )
        return ReadResource.Result(
            contents: [.text(envelope, uri: uri, mimeType: "application/json")]
        )
    }

    private static func tracksAreInspectorContaminated(_ tracks: [TrackState]) -> Bool {
        tracks.count >= 3 && tracks.allSatisfy { $0.name.hasSuffix(":") }
    }

    private static func trustedLiveTrackCount(_ tracks: [TrackState], fetchedAt: Date) -> Int? {
        guard fetchedAt > .distantPast,
              !tracks.isEmpty,
              !tracksAreInspectorContaminated(tracks),
              tracks.allSatisfy({ $0.placeholder != true }) else {
            return nil
        }
        return tracks.count
    }

    private static func readMIDIPorts(router: ChannelRouter, uri: String) async throws -> ReadResource.Result {
        let result = await router.route(operation: "midi.list_ports")
        let payload: String
        if result.isSuccess,
           let data = result.message.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            payload = result.message
        } else if result.isSuccess {
            payload = encodeJSON(["message": result.message])
        } else {
            payload = encodeJSON(["error": result.message])
        }
        return ReadResource.Result(
            contents: [.text(payload, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readProjectAudit(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let report = await ProjectSessionAudit.buildAudit(cache: cache)
        // Honest Contract: never emit a success-shaped body that is missing the
        // schema/read_only contract fields. On encode failure, fail loud.
        do {
            let json = try encodeJSONStrict(report, compact: true)
            return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
        } catch {
            throw MCPError.internalError("audit encode failed: \(error.localizedDescription)")
        }
    }

    private static func readProjectCleanupPlan(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let report = await ProjectSessionAudit.buildCleanupPlan(cache: cache)
        do {
            let json = try encodeJSONStrict(report, compact: true)
            return ReadResource.Result(contents: [.text(json, uri: uri, mimeType: "application/json")])
        } catch {
            throw MCPError.internalError("cleanup_plan encode failed: \(error.localizedDescription)")
        }
    }

    private static func readTrackRegions(
        at index: Int,
        cache: StateCache,
        router: ChannelRouter,
        uri: String
    ) async throws -> ReadResource.Result {
        // The regions read returns an empty array for an index with no regions —
        // already a classifiable empty-state — and its live-route "no JSON-RPC
        // response" hang is bounded by the resource-read deadline (#199), NOT by a
        // track-count short-circuit: the cache can hold regions for a track whose
        // header isn't in the track array, so track_count is not a reliable
        // existence proxy here.
        if case .success(let payload) = await router.route(operation: "region.get_regions"),
           let liveRegions = try? RegionInfo.decodeToolPayload(payload) {
            await cache.updateRegions(liveRegions.map { $0.asRegionState() })
        }
        let regions = await cache.getRegions().filter { $0.trackIndex == index }
        let json = encodeJSON(regions)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readMixerStrip(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        guard let strip = await cache.getChannelStrip(at: index) else {
            // Mixer strips are keyed by `trackIndex` (not array position), so the
            // valid set is the actual trackIndex values — possibly non-contiguous.
            return indexOutOfRangeResult(
                uri: uri,
                requestedIndex: index,
                availableIndices: await cache.getChannelStrips().map(\.trackIndex).sorted(),
                collection: "channel strip"
            )
        }
        // B2 (#11): give the single-strip read the same envelope + provenance as
        // logic://mixer, so a harness reading an individual strip gets the same
        // freshness signal instead of a bare, undated object.
        let fetchedAt = await cache.getMixerFetchedAt()
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart = (age as? Double).map { "\($0)" } ?? "null"
        let isoPart = (iso as? String).map { "\"\($0)\"" } ?? "null"
        let dataSource = mixerDataSource(fetchedAt: fetchedAt)
        let stripJSON = encodeJSON(strip)
        let json = """
            {"cache_age_sec":\(agePart),"data_source":"\(dataSource)","fetched_at":\(isoPart),"strip":\(stripJSON)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// v3.1.8 (Issue #7) — markers wrapped in cache envelope with source attribution.
    /// Markers come from cache (populated by StatePoller's hardened AX walker).
    /// Source: "ax_live" if cache populated, "default" if empty/unread.
    /// `ax_occluded` flag in the envelope flags untrusted-empty (Logic UI focus
    /// stole AX away from the arrange area mid-poll).
    /// v3.2 — wire 형식 DTO. 도메인 `MarkerState` 의 `positionSource` (camelCase) →
    /// JSON `position_source` (snake_case) 변환 + derived `is_canonical` 추가.
    /// SRP — 도메인 model 과 wire schema 책임 분리.
    private struct MarkerWireDTO: Encodable {
        let id: Int
        let name: String
        let position: String
        let positionSource: PositionSource
        let isCanonical: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, position
            case positionSource = "position_source"
            case isCanonical = "is_canonical"
        }
    }

    /// Marker 배열을 wire JSON (snake_case `position_source` + derived
    /// `is_canonical`) 으로 직렬화한다.
    static func encodeMarkersWire(_ markers: [MarkerState]) -> String {
        let dtos = markers.map { m in
            MarkerWireDTO(
                id: m.id,
                name: m.name,
                position: m.position,
                positionSource: m.positionSource,
                isCanonical: m.positionSource.isCanonical
            )
        }
        return encodeJSON(dtos)
    }

    private static func readMarkers(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let markers = await cache.getMarkers()
        let fetchedAt = await cache.getMarkersFetchedAt()
        let axOccluded = await cache.getAXOccluded()
        let body = encodeMarkersWire(markers)
        let source: String
        if !markers.isEmpty {
            source = "ax_live"
        } else if fetchedAt > .distantPast {
            // Poller has run, came up empty — could be no markers OR occluded.
            source = axOccluded ? "cache" : "ax_live"
        } else {
            source = "default"
        }
        let envelope = wrapWithCacheEnvelope(
            bodyJSON: body,
            fetchedAt: fetchedAt,
            axOccluded: axOccluded,
            extras: ["source": source]
        )
        return ReadResource.Result(
            contents: [.text(envelope, uri: uri, mimeType: "application/json")]
        )
    }

    /// Wire-format DTO for `logic://mcu/state`. MCU LCD bytes can carry raw
    /// control characters straight from hardware SysEx decode; routing the
    /// payload through `JSONEncoder` guarantees RFC 8259-valid escaping for
    /// `\n`, `\r`, `\t`, and U+0000-U+001F — which the previous hand-rolled
    /// emitter missed and which could have produced unparseable JSON.
    private struct MCUStateDTO: Encodable {
        struct Connection: Encodable {
            let isConnected: Bool
            let registeredAsDevice: Bool
            let portName: String
            let lastFeedbackAt: Date?
        }
        struct Display: Encodable {
            let upperRow: String
            let lowerRow: String
        }
        let connection: Connection
        let display: Display
    }

    private static func readMCUState(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let conn = await cache.getMCUConnection()
        let display = await cache.getMCUDisplay()
        let dto = MCUStateDTO(
            connection: .init(
                isConnected: conn.isConnected,
                registeredAsDevice: conn.registeredAsDevice,
                portName: conn.portName,
                lastFeedbackAt: conn.lastFeedbackAt
            ),
            display: .init(upperRow: display.upperRow, lowerRow: display.lowerRow)
        )
        let json = encodeJSON(dto, compact: true)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    /// Max bytes we will read from the library-inventory cache file. A real
    /// scan is typically <1 MiB; this cap exists so a maliciously-large file
    /// (e.g. via a hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` symlink target)
    /// can't OOM the server.
    static let libraryInventoryMaxBytes: Int = 64 * 1024 * 1024  // 64 MiB

    /// Resolve the library-inventory cache file. Checks (in order):
    /// 1. `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env override (absolute path; symlinks resolved + validated)
    /// 2. `<CWD>/Resources/library-inventory.json` — dev/CLI launches from repo root
    /// 3. `~/Library/Application Support/LogicProMCP/library-inventory.json` — daemon/launchd launches where CWD=/
    private static func libraryInventoryCandidatePaths() -> [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_LIBRARY_INVENTORY"],
           !override.isEmpty {
            paths.append(override)
        }
        paths.append("Resources/library-inventory.json")
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            paths.append(
                appSupport.appendingPathComponent("LogicProMCP/library-inventory.json").path
            )
        }
        return paths
    }

    /// Default directory prefixes the library-inventory cache file is allowed
    /// to live under. Computed at call time (not a static let) because tests
    /// rely on `HOME` being mutable and because `<CWD>/Resources/` is itself
    /// a moving target across the test runner / dev shell / launchd contexts.
    ///
    /// All prefixes are normalised via `URL(...).resolvingSymlinksInPath()`
    /// and are guaranteed to end in `/` so a path comparison of the form
    /// `resolved.hasPrefix(prefix)` cannot be tricked by a sibling like
    /// `/Users/example/Music/Logic-evil/x.json` matching `/Users/example/Music/Logic`.
    static func defaultLibraryInventoryAllowedPrefixes() -> [String] {
        var prefixes: [String] = []

        // (1) ~/Library/Application Support/LogicProMCP/  — production location
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            prefixes.append(
                appSupport.appendingPathComponent("LogicProMCP", isDirectory: true).path
            )
        }

        // (2) <CWD>/Resources/  — repo-root dev/CLI launches
        let cwd = FileManager.default.currentDirectoryPath
        prefixes.append(URL(fileURLWithPath: cwd).appendingPathComponent("Resources", isDirectory: true).path)

        // (3) ~/Music/Logic/  — Logic Pro's own user library directory; users
        //     reasonably stash a hand-built inventory beside their patches.
        let home = NSHomeDirectory()
        prefixes.append(URL(fileURLWithPath: home).appendingPathComponent("Music/Logic", isDirectory: true).path)

        // (4) Operator-extended allowlist via env. ADDITIVE (not replacement)
        //     so the safe defaults can never be removed by a misconfigured
        //     daemon. Colon-separated, matching `PATH` conventions.
        if let extra = ProcessInfo.processInfo.environment["LOGIC_PRO_MCP_INVENTORY_ALLOWLIST"],
           !extra.isEmpty {
            for raw in extra.split(separator: ":") {
                let s = String(raw)
                guard !s.isEmpty else { continue }
                prefixes.append(s)
            }
        }

        // Normalise: resolve symlinks (so a prefix can't escape via its own
        // symlink), expand `~`, and force a trailing `/` for safe prefix
        // comparison. Empties / duplicates filtered out.
        var seen = Set<String>()
        var out: [String] = []
        for p in prefixes {
            let expanded = (p as NSString).expandingTildeInPath
            var resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            if !resolved.hasSuffix("/") { resolved += "/" }
            if seen.insert(resolved).inserted {
                out.append(resolved)
            }
        }
        return out
    }

    /// Validate that the candidate path is safe to read as the library cache.
    /// Returns the resolved absolute path on success, or nil on rejection.
    /// Mitigations against a hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` symlink
    /// target (e.g. an attacker with daemon env-var access pointing us at a
    /// sensitive file):
    /// - Must end in `.json` after symlink resolution (so `/etc/passwd` and
    ///   binary secrets won't be served raw)
    /// - Must be a regular file (not a directory)
    /// - Must be smaller than `libraryInventoryMaxBytes`
    /// - Resolved path must sit under one of `allowedPrefixes` (post-symlink),
    ///   so an env-var pointing at `/etc/passwd.json` or a symlink chain
    ///   escaping a sandboxed dir is rejected before any bytes are read.
    /// Always logs the resolved path on reject so operators can audit.
    /// Internal (not private) so the test target can exercise it directly
    /// with synthesised allowlists; production callers always use the default
    /// allowlist computed by `defaultLibraryInventoryAllowedPrefixes()`.
    static func validateLibraryInventoryPath(
        _ rawPath: String,
        allowedPrefixes: [String]? = nil
    ) -> String? {
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
        guard resolved.hasSuffix(".json") else {
            Log.warn(
                "library-inventory path rejected (must end in .json): raw=\(rawPath), resolved=\(resolved)",
                subsystem: Log.Subsystem.library
            )
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
           let size = attrs[.size] as? Int, size > libraryInventoryMaxBytes {
            Log.warn(
                "library-inventory file exceeds \(libraryInventoryMaxBytes) bytes — refusing to load (raw=\(rawPath), resolved=\(resolved), size=\(size))",
                subsystem: Log.Subsystem.library
            )
            return nil
        }
        // Path-prefix allowlist. The previous validation only enforced the
        // `.json` suffix, which left any user-readable JSON file (Keychain
        // export, app config, third-party token caches) reachable through a
        // hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` env var. We now require
        // the post-symlink-resolution path to live inside an allowlisted
        // directory tree, defaulting to the inventory's natural homes
        // (~/Library/Application Support/LogicProMCP/, <CWD>/Resources/,
        // ~/Music/Logic/) plus an optional additive `LOGIC_PRO_MCP_INVENTORY_ALLOWLIST`.
        let prefixes = allowedPrefixes ?? defaultLibraryInventoryAllowedPrefixes()
        // Prefixes are normalized with a trailing "/", so comparing the full
        // resolved file path accepts files under the prefix while rejecting
        // sibling-prefix paths such as `/foo-evil/x.json` for prefix `/foo/`.
        let inAllowlist = prefixes.contains { resolved.hasPrefix($0) }
        guard inAllowlist else {
            Log.warn(
                "library-inventory path rejected (outside allowlist): raw=\(rawPath), resolved=\(resolved), allowlist=\(prefixes.joined(separator: ", "))",
                subsystem: Log.Subsystem.library
            )
            return nil
        }
        return resolved
    }

    private static func readLibraryInventory(uri: String) async throws -> ReadResource.Result {
        let candidates = libraryInventoryCandidatePaths()
        let allowlist = defaultLibraryInventoryAllowedPrefixes()
        for path in candidates {
            guard let resolved = validateLibraryInventoryPath(path, allowedPrefixes: allowlist) else { continue }
            guard let data = FileManager.default.contents(atPath: resolved) else { continue }
            // Parse before serving: we advertise this resource as
            // `application/json`, so corrupt or attacker-shaped bytes must
            // not reach the MCP client under that mimetype. On parse
            // failure we fall through to the next candidate and log.
            guard (try? JSONSerialization.jsonObject(with: data, options: [])) != nil,
                  let s = String(data: data, encoding: .utf8) else {
                Log.warn(
                    "library-inventory file is not valid JSON, skipping: \(resolved)",
                    subsystem: Log.Subsystem.library
                )
                continue
            }
            // v3.1.0 (T7) — wrap with cache envelope based on file mtime.
            // Clients can now detect stale inventories (e.g. before the first
            // `scan_library` of a new Logic install) without parsing the
            // inventory payload itself.
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
            let mtime = attrs?[.modificationDate] as? Date
            let json = wrapWithCacheEnvelope(bodyJSON: s, fetchedAt: mtime)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        // No cache found at any candidate — warn loudly so daemon deployments
        // where CWD=/ don't silently return an empty placeholder forever.
        Log.warn(
            "library-inventory cache missing at candidate paths: \(candidates.joined(separator: ", ")). Run logic_library scan, or set LOGIC_PRO_MCP_LIBRARY_INVENTORY to an absolute path under the allowlist (extend via LOGIC_PRO_MCP_INVENTORY_ALLOWLIST if needed).",
            subsystem: Log.Subsystem.library
        )
        let json = #"{"cached":false,"note":"Run logic_library scan to populate (or set LOGIC_PRO_MCP_LIBRARY_INVENTORY env var)"}"#
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readSystemHealth(
        cache: StateCache,
        router: ChannelRouter,
        uri: String
    ) async throws -> ReadResource.Result {
        // Delegate to SystemDispatcher for canonical source (PRD §4.3.2, T8 fix)
        let toolResult = await SystemDispatcher.handle(
            command: "health", params: [:], router: router, cache: cache
        )
        // Extract text from tool result
        let json: String
        if case .text(let text, _, _) = toolResult.content.first {
            json = text
        } else {
            json = "{}"
        }
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }
}
