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
    static func level(for command: String) -> Level {
        switch command {
        case "quit", "close":
            return .l3
        case "save_as", "bounce", "open", "export_run", "export_resume":
            // #27 Phase 2 — guarded export execution opens projects and fires
            // bounces, so it carries the same L2 destructive weight as the
            // individual open/bounce ops it composes. (The per-run `confirmed`
            // gate is enforced inside ProjectExportExecutor, not via the
            // dispatcher confirmation prompt, so a confirmed:false run returns a
            // State-C `confirmation_required` envelope rather than the L2 prompt.)
            return .l2
        case "save", "new", "launch", "cleanup_apply":
            // cleanup_apply mutates the project (executes a confirmed cleanup
            // step through track.rename). It carries its own confirmed:true
            // gate (#28), so it does NOT use the L2/L3 confirmation-prompt
            // flow — L1 here just turns on the SIEM audit trail.
            return .l1
        default:
            return .l0
        }
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
