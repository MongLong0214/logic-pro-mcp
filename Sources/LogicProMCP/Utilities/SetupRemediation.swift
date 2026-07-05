import Foundation

/// Remediation vocabulary shared by `SetupDoctor` and `SetupLifecycle`.
///
/// Both surfaces previously declared their own copy of this enum (the lifecycle
/// one carried a `// Mirrors SetupDoctor.RemediationType` note kept in sync by
/// hand). They are unified here so the taxonomy and its `remediation` wire shape
/// (`{"type": <rawValue>, "value": <String>}`) can never drift.
///
/// The doctor uses the full set — `.systemSettings` is emitted for the
/// permission checks; the lifecycle planner only ever emits
/// command/docs/manual/none, but sharing the type keeps both surfaces reading
/// with the same vocabulary. Sharing a superset does NOT change either JSON
/// shape: the cases a surface never emits simply never appear in its output.
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
