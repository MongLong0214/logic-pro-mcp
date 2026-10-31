import Foundation

/// Remediation vocabulary shared by `SetupDoctor` and `SetupLifecycle`.
///
/// Both surfaces previously declared their own copy of this enum (the lifecycle
/// one carried a `// Mirrors SetupDoctor.RemediationType` note kept in sync by
/// hand). They are unified here so the taxonomy and its `remediation` wire shape
/// (`{"type": <rawValue>, "value": <String>}`) can never drift.
///
/// `.systemSettings` is retained as legacy wire vocabulary, but neither the
/// doctor nor lifecycle planner emits it: unavailable permissions now terminate
/// without asking a person to change settings. Sharing a superset does NOT
/// change either JSON shape; cases a surface never emits do not appear.
enum SetupRemediationType: String, Codable, Sendable {
    case command
    case docs
    case systemSettings = "system_settings"
    case manual
    case none
}

/// Shared remediation payload (`{type, value}`) for SetupDoctor + SetupLifecycle.
struct SetupRemediation: Codable, Equatable, Sendable {
    let type: SetupRemediationType
    let value: String
}
