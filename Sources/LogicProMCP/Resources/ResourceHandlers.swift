import Foundation
import MCP

/// Handles MCP resource read requests for logic:// URIs.
struct ResourceHandlers {}

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

}
