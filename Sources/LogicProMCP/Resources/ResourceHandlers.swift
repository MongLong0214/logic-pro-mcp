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
    /// T7 cache envelope. Returns `{"cache_age_sec":…,"fetched_at":…,"data":<body>}`.
    static func wrapWithCacheEnvelope(bodyJSON: String, fetchedAt: Date?) -> String {
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart: String = {
            if let a = age as? Double { return "\(a)" }
            return "null"
        }()
        let isoPart: String = {
            if let s = iso as? String { return "\"\(s)\"" }
            return "null"
        }()
        return "{\"cache_age_sec\":\(agePart),\"fetched_at\":\(isoPart),\"data\":\(bodyJSON)}"
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
    static func read(
        uri: String,
        cache: StateCache,
        router: ChannelRouter
    ) async throws -> ReadResource.Result {
        // Health must be side-effect free so the resource stays aligned with the tool contract.
        if uri == "logic://system/health" {
            return try await readSystemHealth(cache: cache, router: router, uri: uri)
        }

        await cache.recordToolAccess()

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
                    return try await readTrackRegions(at: index, cache: cache, uri: uri)
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
            return try await readTransportState(cache: cache, uri: uri)

        case "logic://tracks":
            return try await readTracks(cache: cache, uri: uri)

        case "logic://mixer":
            return try await readMixer(cache: cache, uri: uri)

        case "logic://markers":
            return try await readMarkers(cache: cache, uri: uri)

        case "logic://project/info":
            return try await readProjectInfo(cache: cache, uri: uri)

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

    private static func readTransportState(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let state = await cache.getTransport()
        let hasDocument = await cache.getHasDocument()
        let ageSeconds = Date().timeIntervalSince(state.lastUpdated)
        // Inline the struct's fields into a larger object so clients can
        // detect "no project open" / "stale snapshot" without having to
        // cross-reference logic://system/health. `transport_age_sec` grows
        // without bound after clearProjectState because lastUpdated
        // defaults to .distantPast.
        let inner = encodeJSON(state)
        let json = """
            {"state":\(inner),"has_document":\(hasDocument),"transport_age_sec":\(ageSeconds)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTracks(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let tracks = await cache.getTracks()
        let fetchedAt = await cache.getTracksFetchedAt()
        let body = encodeJSON(tracks)
        // v3.1.0 (T7) — cache envelope. Legacy consumers that decoded the
        // plain array must now read `.data`. The envelope is additive at the
        // resource URI level (not at the tool response level), so
        // mutating-op clients are unaffected.
        let json = wrapWithCacheEnvelope(bodyJSON: body, fetchedAt: fetchedAt)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTrack(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        if let track = await cache.getTrack(at: index) {
            let json = encodeJSON(track)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        throw MCPError.invalidParams("No track at index \(index)")
    }

    private static func readMixer(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let strips = await cache.getChannelStrips()
        let conn = await cache.getMCUConnection()
        let fetchedAt = await cache.getMixerFetchedAt()
        let stripsJSON = encodeJSON(strips)
        let (age, iso) = cacheEnvelope(fetchedAt: fetchedAt)
        let agePart = (age as? Double).map { "\($0)" } ?? "null"
        let isoPart = (iso as? String).map { "\"\($0)\"" } ?? "null"
        let json = """
            {"cache_age_sec":\(agePart),"fetched_at":\(isoPart),"mcu_connected":\(conn.isConnected),"registered":\(conn.registeredAsDevice),"strips":\(stripsJSON)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readProjectInfo(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        // hasDocument gate removed (post-hardening). Cache returns an empty
        // ProjectInfo when state is genuinely empty; clients distinguish.
        let info = await cache.getProject()
        let json = encodeJSON(info)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
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

    private static func readTrackRegions(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let regions = await cache.getRegions().filter { $0.trackIndex == index }
        let json = encodeJSON(regions)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readMixerStrip(at index: Int, cache: StateCache, uri: String) async throws -> ReadResource.Result {
        if let strip = await cache.getChannelStrip(at: index) {
            let json = encodeJSON(strip)
            return ReadResource.Result(
                contents: [.text(json, uri: uri, mimeType: "application/json")]
            )
        }
        throw MCPError.invalidParams("No channel strip at index \(index)")
    }

    private static func readMarkers(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let markers = await cache.getMarkers()
        let json = encodeJSON(markers)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
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
    private static let libraryInventoryMaxBytes: Int = 64 * 1024 * 1024  // 64 MiB

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

    /// Validate that the candidate path is safe to read as the library cache.
    /// Returns the resolved absolute path on success, or nil on rejection.
    /// Mitigations against a hostile `LOGIC_PRO_MCP_LIBRARY_INVENTORY` symlink
    /// target (e.g. an attacker with daemon env-var access pointing us at a
    /// sensitive file):
    /// - Must end in `.json` after symlink resolution (so `/etc/passwd` and
    ///   binary secrets won't be served raw)
    /// - Must be a regular file (not a directory)
    /// - Must be smaller than `libraryInventoryMaxBytes`
    /// Always logs the resolved path on reject so operators can audit.
    private static func validateLibraryInventoryPath(_ rawPath: String) -> String? {
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
        return resolved
    }

    private static func readLibraryInventory(uri: String) async throws -> ReadResource.Result {
        let candidates = libraryInventoryCandidatePaths()
        for path in candidates {
            guard let resolved = validateLibraryInventoryPath(path) else { continue }
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
            "library-inventory cache missing at candidate paths: \(candidates.joined(separator: ", ")). Run logic_library scan, or set LOGIC_PRO_MCP_LIBRARY_INVENTORY to an absolute path.",
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
