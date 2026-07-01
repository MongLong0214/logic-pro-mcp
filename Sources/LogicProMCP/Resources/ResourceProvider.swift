import Foundation
import MCP

/// Registers MCP resources for zero-cost state reads.
/// Resources are URI-addressable data pulled on demand — they don't appear
/// in the tool list. Clients can watch/poll them to keep a local mirror in
/// sync without consuming tool-call budget.
///
/// Stable surface: `resources/list` always advertises the full static set,
/// matching the documented "18 static resources" catalog and the URIs that
/// are directly readable. `logic://mcu/state` is included even when the MCU
/// control surface is disconnected — a direct read returns a meaningful
/// `{ connected: false, … }` payload (not an empty probe), so hiding it from
/// discovery while it stayed readable made the list disagree with both the
/// docs and the readable surface (#215).
struct ResourceProvider {

    /// Full static resource set — the single source of truth for both
    /// capability announcement and `resources/list`.
    static let resources: [Resource] = baseResources

    /// Full static template set.
    static let templates: [Resource.Template] = baseTemplates

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
    private static let versionReleaseTimestamp: String = "2026-06-23T00:00:00Z"

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
            name: "Project Session Audit",
            uri: "logic://project/audit",
            description: "Read-only project/session audit with evidence-backed findings and cleanup plan",
            mimeType: "application/json",
            annotations: annotations(priority: 0.68)
        ),
        Resource(
            name: "Project Cleanup Plan",
            uri: "logic://project/cleanup-plan",
            description: "Read-only serializable cleanup plan derived from the current project/session audit",
            mimeType: "application/json",
            annotations: annotations(priority: 0.67)
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
        Resource(
            name: "Stock Plugin Intelligence",
            uri: "logic://stock-plugins",
            description: "Read-only Logic stock plugin catalog with truth labels, provenance, and limitations",
            mimeType: "application/json",
            annotations: annotations(priority: 0.45)
        ),
        Resource(
            name: "Stock Plugin Census",
            uri: "logic://stock-plugins/census",
            description: "Current-machine stock plugin catalog census metadata and validation state",
            mimeType: "application/json",
            annotations: annotations(priority: 0.35)
        ),
        Resource(
            name: "Stock Plugin Capabilities",
            uri: "logic://stock-plugins/capabilities",
            description: "Stock plugin catalog schema capabilities, truth labels, and read-only contract",
            mimeType: "application/json",
            annotations: annotations(priority: 0.35)
        ),
        Resource(
            name: "Stock Instrument Intelligence",
            uri: "logic://stock-instruments",
            description: "Read-only Logic stock instrument catalog with provenance, roles, and explicit limitations",
            mimeType: "application/json",
            annotations: annotations(priority: 0.42)
        ),
        Resource(
            name: "Session Player Intelligence",
            uri: "logic://session-players",
            description: "Read-only Logic Session Player and Drummer catalog with documented provenance and unsupported actions",
            mimeType: "application/json",
            annotations: annotations(priority: 0.41)
        ),
        Resource(
            name: "Workflow Skills",
            uri: "logic://workflow-skills",
            description: "Validated read-only Logic Pro MCP workflow skill pack",
            mimeType: "application/json",
            annotations: annotations(priority: 0.43)
        ),
        Resource(
            name: "Workflow Skills Schema",
            uri: "logic://workflow-skills/schema",
            description: "Workflow skill schema, evidence levels, and validation rules",
            mimeType: "application/json",
            annotations: annotations(priority: 0.34)
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
        Resource.Template(
            uriTemplate: "logic://stock-plugins/{id}",
            name: "Stock Plugin Detail",
            description: "Single stock plugin catalog entry by stable ID",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://stock-plugins/search?query={query}",
            name: "Stock Plugin Search",
            description: "Search stock plugin catalog entries by query",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://stock-instruments/{id}",
            name: "Stock Instrument Detail",
            description: "Single stock instrument catalog entry by stable ID",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://stock-instruments/search?query={query}",
            name: "Stock Instrument Search",
            description: "Search stock instrument catalog entries by query",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://session-players/{id}",
            name: "Session Player Detail",
            description: "Single Session Player or Drummer catalog entry by stable ID",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://workflow-plans/session?prompt={prompt}",
            name: "Session Plan Dry Run",
            description: "Planning-only composition/session workflow plan from a natural-language musical prompt",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://workflow-skills/{id}",
            name: "Workflow Skill Detail",
            description: "Single workflow skill by stable ID",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "logic://workflow-skills/search?query={query}",
            name: "Workflow Skill Search",
            description: "Search workflow skills by query",
            mimeType: "application/json"
        ),
    ]
}
