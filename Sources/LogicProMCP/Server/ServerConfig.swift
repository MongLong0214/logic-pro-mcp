import Foundation

/// Central configuration for the Logic Pro MCP server.
/// All tunables live here — ports, timeouts, poll intervals.
struct ServerConfig: Sendable {
    // MARK: - Server Identity
    static let serverName = "logic-pro-mcp"
    static let serverVersion = "2.2.0"

    // MARK: - MIDI
    // NOTE: source name uses *-Internal suffix for consistency with KeyCmd/Scripter/MCU
    // ports — the unified naming pattern lets users approve all 4 ports the same way
    // in Logic Pro's MIDI Studio / Project Settings.
    static let virtualMIDISourceName = "LogicProMCP-MIDI-Internal"
    static let virtualMIDISinkName = "LogicProMCP-MIDI-In"
    /// MMC device ID (0x7F = all devices)
    static let mmcDeviceID: UInt8 = 0x7F

    // MARK: - Timeouts
    static let appleScriptTimeout: TimeInterval = 5.0

    // MARK: - Logic Pro
    static let logicProBundleID = "com.apple.logic10"
    static let logicProProcessName = "Logic Pro"

    // MARK: - Polling
    //
    // 2 s tradeoff: shorter intervals make post-mutation state reads fresh
    // (5 s required a manual refresh_cache call after every arm/mute/etc to
    // see the change — confusing for agents). 2 s keeps CPU overhead low
    // while giving users near-real-time state via resource reads. Agents
    // can still force-refresh via logic_system refresh_cache when they
    // need sub-2s freshness.
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
