import Foundation
import MCP

/// Handles MCP resource read requests for logic:// URIs.
struct ResourceHandlers {

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

        // Check if Logic Pro has an open document — return error for stale reads
        let hasDocument = await cache.getHasDocument()

        // Handle parameterized URIs like logic://tracks/{index}
        if uri.hasPrefix("logic://tracks/") {
            guard hasDocument else {
                throw MCPError.invalidParams("No Logic Pro document is open")
            }
            let indexStr = String(uri.dropFirst("logic://tracks/".count))
            if let index = Int(indexStr) {
                return try await readTrack(at: index, cache: cache, uri: uri)
            }
        }

        switch uri {
        case "logic://transport/state":
            return try await readTransportState(cache: cache, uri: uri)

        case "logic://tracks":
            return try await readTracks(cache: cache, uri: uri)

        case "logic://mixer":
            return try await readMixer(cache: cache, uri: uri)

        case "logic://project/info":
            return try await readProjectInfo(cache: cache, uri: uri)

        case "logic://midi/ports":
            return try await readMIDIPorts(router: router, uri: uri)
        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    // MARK: - Individual resource handlers

    private static func readTransportState(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let state = await cache.getTransport()
        let json = encodeJSON(state)
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readTracks(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        let tracks = await cache.getTracks()
        let json = encodeJSON(tracks)
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
        let stripsJSON = encodeJSON(strips)
        let json = """
            {"mcu_connected":\(conn.isConnected),"registered":\(conn.registeredAsDevice),"strips":\(stripsJSON)}
            """
        return ReadResource.Result(
            contents: [.text(json, uri: uri, mimeType: "application/json")]
        )
    }

    private static func readProjectInfo(cache: StateCache, uri: String) async throws -> ReadResource.Result {
        guard await cache.getHasDocument() else {
            throw MCPError.invalidParams("No Logic Pro document is open")
        }
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
