import Foundation

/// Central configuration for the Logic Pro MCP server.
/// All tunables live here — ports, timeouts, poll intervals.
struct ServerConfig: Sendable {
    // MARK: - Server Identity
    static let serverName = "logic-pro-mcp"
    static let serverVersion = "2.0.0"

    // MARK: - MIDI
    static let virtualMIDISourceName = "LogicProMCP-Out"
    static let virtualMIDISinkName = "LogicProMCP-In"
    /// MMC device ID (0x7F = all devices)
    static let mmcDeviceID: UInt8 = 0x7F

    // MARK: - Timeouts
    static let appleScriptTimeout: TimeInterval = 5.0
    static let channelHealthCheckTimeout: TimeInterval = 3.0

    // MARK: - Logic Pro
    static let logicProBundleID = "com.apple.logic10"
    static let logicProProcessName = "Logic Pro"

    // MARK: - Polling
    static let statePollingIntervalNs: UInt64 = 5_000_000_000 // 5 seconds

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
