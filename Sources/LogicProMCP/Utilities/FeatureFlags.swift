import Foundation

enum FeatureFlags: Sendable {
    #if DEBUG
    @TaskLocal static var adr002TargetRefOverride: Bool?
    #endif

    static var adr002TargetRef: Bool {
        #if DEBUG
        if let adr002TargetRefOverride { return adr002TargetRefOverride }
        #endif
        return ProcessInfo.processInfo.environment["LOGIC_MCP_ADR002_TARGET_REF"] == "1"
    }

    #if DEBUG
    static func withAdr002TargetRefForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $adr002TargetRefOverride.withValue(value, operation: operation)
    }
    #endif

    static var adr003OperationRegistry: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR003_OPERATION_REGISTRY"] == "1"
    }

    static var adr004MutationSaga: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR004_MUTATION_SAGA"] == "1"
    }

    static var adr005OperationTrace: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] == "1"
    }

    static var adr006VersionedCache: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR006_VERSIONED_CACHE"] == "1"
    }

    static var adr007SelectorAtlas: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR007_SELECTOR_ATLAS"] == "1"
    }

    static var adr008RoutingGraph: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR008_ROUTING_GRAPH"] == "1"
    }

    static var adr009PluginCapabilities: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR009_PLUGIN_CAPABILITIES"] == "1"
    }
}
