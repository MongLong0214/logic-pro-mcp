import Foundation

/// Result of a channel operation.
enum ChannelResult: Sendable {
    case success(String)
    case error(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let msg): return msg
        case .error(let msg): return msg
        }
    }
}

/// Health status of a channel.
enum ChannelVerificationStatus: String, Sendable {
    case runtimeReady = "runtime_ready"
    case manualValidationRequired = "manual_validation_required"
    case unattendedUnavailable = "unattended_unavailable"
    case unavailable = "unavailable"
}

struct ChannelHealth: Sendable {
    let available: Bool
    let latencyMs: Double?
    let detail: String
    let verificationStatus: ChannelVerificationStatus

    var ready: Bool {
        available && verificationStatus == .runtimeReady
    }

    static func healthy(
        latencyMs: Double? = nil,
        detail: String = "OK",
        verificationStatus: ChannelVerificationStatus = .runtimeReady
    ) -> ChannelHealth {
        ChannelHealth(
            available: true,
            latencyMs: latencyMs,
            detail: detail,
            verificationStatus: verificationStatus
        )
    }

    static func unavailable(
        _ reason: String,
        verificationStatus: ChannelVerificationStatus = .unavailable
    ) -> ChannelHealth {
        ChannelHealth(
            available: false,
            latencyMs: nil,
            detail: reason,
            verificationStatus: verificationStatus
        )
    }
}

/// Identifies the communication channels available to the server.
enum ChannelID: String, Sendable, CaseIterable {
    case coreMIDI = "CoreMIDI"
    case accessibility = "Accessibility"
    case cgEvent = "CGEvent"
    case appleScript = "AppleScript"
    case mcu = "MCU"
    case midiKeyCommands = "MIDIKeyCommands"
    case scripter = "Scripter"
}

/// Protocol that all communication channels conform to.
/// Each channel wraps a native macOS control mechanism.
protocol Channel: Actor {
    /// Which channel this is.
    nonisolated var id: ChannelID { get }

    /// Initialize the channel (create MIDI ports, AX refs, etc.)
    func start() async throws

    /// Tear down the channel.
    func stop() async

    /// Execute a named operation with parameters. Returns the result.
    func execute(operation: String, params: [String: String]) async -> ChannelResult

    /// Check if this channel is currently functional.
    func healthCheck() async -> ChannelHealth
}

/// Shared surface for the two send-only "MIDI CC on channel 16" channels
/// (`ScripterChannel` + `MIDIKeyCommandsChannel`). Both push bytes through a
/// `KeyCmdTransportProtocol`. Their mapped Logic operations have neither
/// programmatic setup nor outcome readback, so transport readiness alone never
/// becomes unattended execution readiness. The channel-specific Log / health
/// *strings* stay in the concrete channels; only the channel-agnostic skeleton
/// lives here.
protocol KeyCmdCCChannel: Channel {
    nonisolated var transport: any KeyCmdTransportProtocol { get }
    nonisolated var approvalStore: any ManualValidationStoring { get }
}

extension KeyCmdCCChannel {
    /// Zero-indexed MIDI channel 16 (wire nibble 0x0F) shared by both
    /// send-only CC channels.
    static var midiChannel: UInt8 { 15 }

    /// Shared `prepare()` → `readiness()` startup. The concrete channel folds
    /// the returned readiness into its own pinned start-log line.
    func prepareTransportForStart() async throws -> KeyCmdTransportReadiness {
        try await transport.prepare()
        return await transport.readiness()
    }

    /// A published virtual port remains available to the raw-MIDI bypass, but
    /// mapped Logic operations stay unroutable. A legacy approval file is not
    /// programmatic setup or readback and therefore cannot change this result.
    func unattendedSendOnlyHealth(
        detail: @Sendable (KeyCmdTransportReadiness) -> String
    ) async -> ChannelHealth {
        let readiness = await transport.readiness()
        guard readiness.available else {
            return .unavailable(readiness.detail)
        }
        return .healthy(
            detail: detail(readiness),
            verificationStatus: .unattendedUnavailable
        )
    }
}
