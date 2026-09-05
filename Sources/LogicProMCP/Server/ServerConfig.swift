import Foundation

/// Central configuration for the Logic Pro MCP server.
/// All tunables live here — ports, timeouts, poll intervals.
struct ServerConfig: Sendable {
    // MARK: - Server Identity
    static let serverName = "logic-pro-mcp"
    static let serverVersion = "3.15.0"
    static let versionMarker = "LOGIC_PRO_MCP_VERSION=\(serverVersion)"

    // MARK: - MIDI
    // NOTE: source name uses *-Internal suffix for consistency with KeyCmd/Scripter/MCU
    // ports — the unified naming pattern lets users approve all 4 ports the same way
    // in Logic Pro's MIDI Studio / Project Settings.
    static let virtualMIDISourceName = "LogicProMCP-MIDI-Internal"
    /// MMC device ID (0x7F = all devices)
    static let mmcDeviceID: UInt8 = 0x7F

    // MARK: - Timeouts
    static let appleScriptTimeout: TimeInterval = 5.0

    // midi.import_file drives a File > Import > MIDI File sheet, a path-entry
    // dialog, an import button and a tempo prompt, each polled inside the
    // script itself. Summing one delay per iteration across those loops gives a
    // floor of 17.2 s, so the shared 5.0 s bound killed osascript while Logic
    // was still importing — the region landed but the caller saw a timeout
    // (#449). This bound must stay above that floor; the polling loops in
    // AccessibilityChannel+MIDIImport are the thing it has to outlast.
    static let midiImportAppleScriptTimeout: TimeInterval = 30.0

    // MARK: - Logic Pro
    /// Resolved bundle ID for the active Logic Pro variant (desktop or Creator Studio).
    static var logicProBundleID: String { LogicProTarget.current.bundleID }
    static var logicProProcessName: String { LogicProTarget.current.processName }

    // MARK: - Polling
    //
    // 3 s tradeoff: shorter intervals make post-mutation state reads fresh
    // (5 s required a manual refresh_cache call after every arm/mute/etc to
    // see the change — confusing for agents). 3 s keeps CPU overhead low
    // while giving users near-real-time state via resource reads. Agents
    // can still force-refresh via logic_system refresh_cache when they
    // need sub-3s freshness. (Comment was previously "2 s" — value/comment
    // drift fixed in v3.1.2 P2.)
    static let statePollingIntervalNs: UInt64 = 3_000_000_000 // 3 seconds

    // MARK: - Enterprise Safety
    /// Channels that report `manual_validation_required` are not considered
    /// execution-ready in enterprise mode and must not be used for routing.
    static let allowManualValidationChannels = false

    /// Channels that may fail to initialize without preventing the server from
    /// starting in degraded mode. Their unavailability must still surface in
    /// health/resource reporting.
    static let optionalStartupChannels: Set<ChannelID> = [
        .accessibility,
        .coreMIDI,
        .mcu,
        .midiKeyCommands,
        .scripter,
    ]
}

struct LogicProSupport: Sendable {
    static let minimumSupportedLogicVersion = "12.0.1"
    static let latestValidatedLogicVersion = "12.3"
}
