import Foundation
import MCP

/// Static catalog resource routing (stock plugins/instruments,
/// session players, workflow plans/skills) — URI parsing + detail/search/census.
extension ResourceHandlers {
    /// Stock plugin discovery routing. Parsed with `URLComponents` so path and
    /// query are matched exactly: unknown subpaths, nested segments, and stray
    /// query parameters fail closed instead of silently degrading to a search
    /// or a detail lookup.
    static func readStockPluginResource(uri: String) throws -> ReadResource.Result {
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
    static func readStockInstrumentResource(uri: String) throws -> ReadResource.Result {
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
    static func readSessionPlayerResource(uri: String) throws -> ReadResource.Result {
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
    static func readWorkflowPlanResource(uri: String) throws -> ReadResource.Result {
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
    static func readWorkflowSkillResource(uri: String) throws -> ReadResource.Result {
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

}
