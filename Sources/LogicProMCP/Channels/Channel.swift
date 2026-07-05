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
/// `KeyCmdTransportProtocol` and gate `runtime_ready` health behind an operator
/// approval. The channel-specific Log / health *strings* stay in the concrete
/// channels (RoutingAuditInvariantTests + the health tests pin them); only the
/// channel-agnostic skeleton lives here.
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

    /// Shared readiness-guard → approval-branch health skeleton. The concrete
    /// channel injects its pinned approved / unapproved detail strings and the
    /// approval identity, so the wire/health text stays byte-identical.
    func manualValidationHealth(
        approval channel: ManualValidationChannel,
        approvedDetail: @Sendable (KeyCmdTransportReadiness) -> String,
        unapprovedDetail: @Sendable (KeyCmdTransportReadiness) -> String
    ) async -> ChannelHealth {
        let readiness = await transport.readiness()
        guard readiness.available else {
            return .unavailable(readiness.detail)
        }
        if await approvalStore.isApproved(channel) {
            return .healthy(detail: approvedDetail(readiness), verificationStatus: .runtimeReady)
        }
        return .healthy(detail: unapprovedDetail(readiness), verificationStatus: .manualValidationRequired)
    }
}
