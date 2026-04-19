import Foundation
import MCP

/// Registers MCP resources for zero-cost state reads.
/// Resources are URI-addressable data pulled on demand — they don't appear
/// in the tool list. Clients can watch/poll them to keep a local mirror in
/// sync without consuming tool-call budget.
///
/// Dynamic surface: the full `resources` list is advertised for capability
/// announcement, but at `resources/list` request time we filter out MCU-only
/// resources when the control surface isn't connected so the LLM doesn't
/// discover probes that would just return empty payloads.
struct ResourceProvider {

    /// Full static resource set. Used for capability announcement and
    /// back-compat with callers that read `.resources` synchronously.
    static let resources: [Resource] = baseResources

    /// Full static template set.
    static let templates: [Resource.Template] = baseTemplates

    /// Dynamic resource list used at `resources/list` request time.
    /// When `mcuConnected == false`, hides MCU-only resources so the LLM
    /// doesn't waste tokens probing offline hardware.
    static func resources(mcuConnected: Bool) -> [Resource] {
        mcuConnected ? baseResources : baseResources.filter { !isMCUOnly($0.uri) }
    }

    /// Dynamic template list. Currently none of the templates are MCU-specific,
    /// but the factory is exposed for symmetry + future growth.
    static func templates(mcuConnected _: Bool) -> [Resource.Template] {
        baseTemplates
    }

    // MARK: - Declarations

    private static func annotations(priority: Double) -> Resource.Annotations {
        Resource.Annotations(
            audience: [.assistant],
            priority: priority,
            lastModified: versionReleaseTimestamp
        )
    }

    /// Stable release timestamp stamped into every resource's `lastModified`.
    /// Lets caching clients invalidate their local mirror on server upgrade.
    private static let versionReleaseTimestamp: String = "2026-04-19T00:00:00Z"

    private static let baseResources: [Resource] = [
        Resource(
            name: "System Health",
            uri: "logic://system/health",
            description: "Channel status, cache freshness, permission state",
            mimeType: "application/json",
            annotations: annotations(priority: 1.0)
        ),
        Resource(
            name: "Transport State",
            uri: "logic://transport/state",
            description: "Current transport state: playing, recording, tempo, position, cycle, metronome",
            mimeType: "application/json",
            annotations: annotations(priority: 0.9)
        ),
        Resource(
            name: "Tracks",
            uri: "logic://tracks",
            description: "All tracks: name, type, index, mute/solo/arm states",
            mimeType: "application/json",
            annotations: annotations(priority: 0.85)
        ),
        Resource(
            name: "Mixer",
            uri: "logic://mixer",
            description: "All channel strips: volume, pan, plugins, sends",
            mimeType: "application/json",
            annotations: annotations(priority: 0.8)
        ),
        Resource(
            name: "Markers",
            uri: "logic://markers",
            description: "All project markers with bar positions and names",
            mimeType: "application/json",
            annotations: annotations(priority: 0.75)
        ),
        Resource(
            name: "Project Info",
            uri: "logic://project/info",
            description: "Project name, sample rate, time signature, track count",
            mimeType: "application/json",
            annotations: annotations(priority: 0.7)
        ),
        Resource(
            name: "MIDI Ports",
            uri: "logic://midi/ports",
            description: "Available MIDI ports (system + virtual)",
            mimeType: "application/json",
            annotations: annotations(priority: 0.5)
        ),
        Resource(
            name: "MCU Control Surface State",
            uri: "logic://mcu/state",
            description: "Mackie Control Universal connection, registration, and LCD display state",
            mimeType: "application/json",
            annotations: annotations(priority: 0.6)
        ),
        Resource(
            name: "Library Inventory",
            uri: "logic://library/inventory",
            description: "Cached Logic Pro Library tree (instruments, categories, presets) from the last scan",
            mimeType: "application/json",
            annotations: annotations(priority: 0.4)
        ),
    ]

    private static let baseTemplates: [Resource.Template] = [
        Resource.Template(
            uriTemplate: "logic://tracks/{index}",
            name: "Track Detail",
            description: "Single track detail by index (including automation mode)",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://tracks/{index}/regions",
            name: "Track Regions",
            description: "Regions on a single track by track index",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://mixer/{strip}",
            name: "Channel Strip Detail",
            description: "Single channel strip by index (volume, pan, plugin chain)",
            mimeType: "application/json"
        ),
    ]

    // MARK: - Filtering

    private static func isMCUOnly(_ uri: String) -> Bool {
        uri == "logic://mcu/state"
    }
}
