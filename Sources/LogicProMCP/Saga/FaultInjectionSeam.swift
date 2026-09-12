#if FAULT_TEST_SEAM
/// Reads the one environment variable that arms a deliberate failure in a saga run.
///
/// It lived in `Qualification/` and was named for the release-certification system that used to
/// drive it. That system is gone; this is not. Saga compensation — a step that fails mid-plan, and
/// the reverse-order undo that follows — is product behaviour a caller depends on, and the only way
/// to test it is to make a step fail on purpose.
///
/// Compiled in debug only, so a release binary has no path to it and `LOGIC_PRO_MCP_FAULT_INJECT`
/// in the process environment engages nothing there. That is a TEST SEAM, not a security boundary:
/// it keeps the affordance out of what ships, and nothing more.
struct FaultInjectionSeam: Equatable, Sendable {
    static let environmentKey = "LOGIC_PRO_MCP_FAULT_INJECT"

    enum Mode: String, Equatable, Sendable {
        case timeout
        case partialState = "partial_state"
    }

    let mode: Mode

    init?(environment: [String: String]) {
        guard let raw = environment[Self.environmentKey],
              let mode = Mode(rawValue: raw) else {
            return nil
        }
        self.mode = mode
    }
}
#endif
