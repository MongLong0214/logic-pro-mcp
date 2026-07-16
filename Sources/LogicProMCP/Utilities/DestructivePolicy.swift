import Foundation

/// Destructive operation safety policy (PRD §6.4).
/// Classifies commands by risk level and provides confirmation gates.
enum DestructivePolicy {
    enum Level: Int, Sendable, Comparable {
        case l0 = 0  // Safe — play, stop, set_volume
        case l1 = 1  // Normal — save, new, launch (audit log)
        case l2 = 2  // High — save_as, bounce, open (warning)
        case l3 = 3  // Critical — quit, close (confirmation required)

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Classify a command's destructive level.
    ///
    /// ADR-003: the operation registry's `ConfirmationPolicy` is the single
    /// authority — this is a projection, not an independent classification.
    /// Export-run/resume keep their per-run `confirmed` gate inside
    /// ProjectExportExecutor (a confirmed:false run returns a State-C
    /// `confirmation_required` envelope rather than the L2 prompt), and
    /// cleanup_apply carries its own confirmed:true gate (#28) — L1 there
    /// only turns on the SIEM audit trail.
    static func level(for command: String) -> Level {
        level(of: OperationRegistry.spec(
            tool: ToolID.logicProject.rawValue,
            command: command
        )?.confirmation ?? .none)
    }

    /// Projection used by every enforcement surface so no local map can drift.
    static func level(of confirmation: ConfirmationPolicy) -> Level {
        switch confirmation {
        case .none: return .l0
        case .l1: return .l1
        case .l2: return .l2
        case .l3: return .l3
        }
    }

    /// Wire label ("L2"/"L3") for a registry confirmation policy; nil below L2.
    static func promptLabel(of confirmation: ConfirmationPolicy) -> String? {
        let level = level(of: confirmation)
        guard level >= .l2 else { return nil }
        return level == .l3 ? "L3" : "L2"
    }

    /// Generate confirmation response JSON for high-risk commands.
    /// Returns nil for commands that don't need confirmation.
    ///
    /// Serialized through the shared `HonestContract.jsonString` layer (sorted
    /// keys + correct escaping) instead of hand-built string interpolation, so
    /// the `command` value can never break the envelope. Keys are emitted
    /// alphabetically; consumers/tests match on order-independent substrings.
    static func confirmationResponse(command: String) -> String? {
        let level = level(for: command)
        guard level >= .l2 else { return nil }
        let levelLabel = level == .l3 ? "L3" : "L2"
        return HonestContract.jsonString([
            "status": "confirmation_required",
            "command": command,
            "level": levelLabel,
            "message": "이 작업은 프로젝트 상태를 변경하거나 데이터 손실을 유발할 수 있습니다.",
            "confirm_command": "logic_project(\"\(command)\", {confirmed: true})",
        ])
    }

    /// Check if a command needs audit logging (L1+).
    static func needsAuditLog(for command: String) -> Bool {
        level(for: command) >= .l1
    }
}
