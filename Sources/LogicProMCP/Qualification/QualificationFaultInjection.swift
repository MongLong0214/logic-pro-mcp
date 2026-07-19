// #399 (CEO audit P0) — QUALIFICATION-ONLY. Compiled solely in debug via the
// `QUALIFICATION_FAULT_SEAM` define (see Package.swift). A release binary
// therefore holds no `LOGIC_PRO_MCP_FAULT_INJECT` string and no code that parses
// it, so the ordinary process environment can never activate a fault.
#if QUALIFICATION_FAULT_SEAM
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
#endif
