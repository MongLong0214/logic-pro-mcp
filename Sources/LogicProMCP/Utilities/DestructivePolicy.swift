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
        case "save_as", "bounce", "open":
            return .l2
        case "save", "new", "launch":
            return .l1
        default:
            return .l0
        }
    }

    /// Generate confirmation response JSON for L3 commands.
    /// Returns nil for commands that don't need confirmation.
    static func confirmationResponse(command: String) -> String? {
        guard level(for: command) == .l3 else { return nil }
        return """
        {"status":"confirmation_required","command":"\(command)","level":"L3","message":"이 작업은 데이터 손실을 유발할 수 있습니다.","confirm_command":"logic_project(\\"\(command)\\", {confirmed: true})"}
        """
    }

    /// Check if a command needs audit logging (L1+).
    static func needsAuditLog(for command: String) -> Bool {
        level(for: command) >= .l1
    }
}
