import Foundation
import Testing
@testable import LogicProMCP

@Test func targetRefDefaultsToFalse() {
    let key = "LOGIC_MCP_ADR002_TARGET_REF"
    let previous = ProcessInfo.processInfo.environment[key]
    unsetenv(key)
    defer {
        if let previous {
            setenv(key, previous, 1)
        } else {
            unsetenv(key)
        }
    }

    #expect(FeatureFlags.adr002TargetRef == false)
}

@Test func operationTraceDefaultsToFalse() {
    let key = "LOGIC_MCP_ADR005_OPERATION_TRACE"
    let previous = ProcessInfo.processInfo.environment[key]
    unsetenv(key)
    defer {
        if let previous {
            setenv(key, previous, 1)
        } else {
            unsetenv(key)
        }
    }

    #expect(FeatureFlags.adr005OperationTrace == false)
}
