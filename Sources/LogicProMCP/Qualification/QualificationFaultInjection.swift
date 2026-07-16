struct QualificationFaultInjection: Equatable, Sendable {
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
