import Foundation

enum FeatureFlags: Sendable {
    static var adr002TargetRef: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR002_TARGET_REF"] == "1"
    }

    static var adr003OperationRegistry: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR003_OPERATION_REGISTRY"] == "1"
    }

    static var adr005OperationTrace: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] == "1"
    }
}
