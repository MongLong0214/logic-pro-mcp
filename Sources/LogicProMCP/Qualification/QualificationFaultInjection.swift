import Foundation

struct QualificationFaultInjection: Equatable, Sendable {
    static let environmentKey = "LOGIC_PRO_MCP_FAULT_INJECT"

    enum Mode: String, Equatable, Sendable {
        case timeout
        case partialState = "partial_state"
    }

    struct Envelope: Codable, Equatable, Sendable {
        var success: Bool
        var state: String
        var error: String
        var writeAttempted: Bool
        var faultInjection: String

        enum CodingKeys: String, CodingKey {
            case success
            case state
            case error
            case writeAttempted = "write_attempted"
            case faultInjection = "fault_injection"
        }
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    init?(environment: [String: String]) {
        guard let raw = environment[Self.environmentKey],
              let mode = Mode(rawValue: raw) else {
            return nil
        }
        self.mode = mode
    }

    var failureReason: String {
        "qualification_fault_injected:\(mode.rawValue)"
    }

    private var errorCode: String {
        switch mode {
        case .timeout: return "qualification_timeout"
        case .partialState: return "qualification_partial_state"
        }
    }

    var responseData: Data {
        let envelope = Envelope(
            success: false,
            state: "C",
            error: errorCode,
            writeAttempted: false,
            faultInjection: mode.rawValue
        )
        return try! JSONEncoder().encode(envelope)
    }

    /// JSON text body for MCP tool isError content.
    var responseJSONText: String {
        String(decoding: responseData, as: UTF8.self)
    }
}
