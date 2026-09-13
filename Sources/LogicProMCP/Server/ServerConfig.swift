import Foundation

/// Central configuration for the Logic Pro MCP server.
/// All tunables live here — ports, timeouts, poll intervals.
struct ServerConfig: Sendable {
    // MARK: - Server Identity
    static let serverName = "logic-pro-mcp"
    static let serverVersion = "3.16.0"
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
    // 60, raised from 30 on 2026-09-13. On a freshly launched Logic the import panel itself did
    // not appear until roughly twelve seconds in — measured by polling the German panel from
    // outside the run — so the button-enable wait had to grow, and the script's own bound has to
    // outlast it or the raise converts one failure into another. It did exactly that once: the
    // button wait went to 30s under a 30s script bound and the envelope changed from "the Import
    // button stayed disabled" to "AppleScript error: timedOut". `record_sequence` carries a 300s
    // server deadline, so this sits well inside it.
    static let midiImportAppleScriptTimeout: TimeInterval = 90.0

    // The script's stages, each a WALL-CLOCK budget rather than a count of polling turns. A turn's
    // cost is Logic's, not ours — every one of these loops walks a window list — so a fixed count
    // buys a different amount of waiting on a busy machine than on an idle one, which is the
    // property that made all three of these too short on a freshly launched Logic.
    //
    // Each was measured on 2026-09-13 against a cold German Logic, one stage at a time, because
    // every raise revealed the next stage behind it: the button wait first, then the file-open
    // sheet. The panel itself did not appear until roughly twelve seconds after the menu click.
    //
    // Their SUM has to stay inside `midiImportAppleScriptTimeout` with room for the script's fixed
    // delays, or a stage that stalls is killed with the script and the caller is told "the script
    // timed out" instead of WHICH stage stalled. `midiImportStageBudgetsFitInsideTheScriptBound`
    // pins that, and it is the check the first attempt at this raise would have failed.

    /// Waiting for the File → Import → MIDI File open sheet to exist.
    static let midiImportFileOpenSheetBudget: TimeInterval = 20.0
    /// Waiting for the go-to-folder field to read our path back.
    static let midiImportPathAcceptBudget: TimeInterval = 15.0
    /// Waiting for the Import button to become enabled.
    static let midiImportButtonEnableBudget: TimeInterval = 25.0
    /// Probing for the post-import tempo alert. Short ON PURPOSE and unlike the others: this one
    /// asks whether a dialog is there, so its budget is paid by every successful import that has
    /// no tempo alert to dismiss, not only by a stalled one.
    static let midiImportTempoProbeBudget: TimeInterval = 3.0

    /// The script's fixed `delay` statements outside the polling loops, summed. Stated so the
    /// budget check below is about the whole script rather than only its loops.
    static let midiImportFixedDelayAllowance: TimeInterval = 5.0

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
