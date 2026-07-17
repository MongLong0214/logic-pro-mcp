import Foundation

enum FeatureFlags: Sendable {
    #if DEBUG
    @TaskLocal static var adr002TargetRefOverride: Bool?
    @TaskLocal static var adr003StrictParamsOverride: Bool?
    @TaskLocal static var adr004MutationSagaOverride: Bool?
    @TaskLocal static var adr005OperationTraceOverride: Bool?
    #endif

    /// PRD-007 Part 2 (ADR-002 #285): promoted from opt-in to DEFAULT ON, so the
    /// variable is now a kill-switch — read with `!= "0"` because an absent
    /// variable must mean ON. Only the exact string "0" rolls back; deployments
    /// already passing the pre-promotion "1" see no change.
    static var adr002TargetRef: Bool {
        #if DEBUG
        if let adr002TargetRefOverride { return adr002TargetRefOverride }
        #endif
        return ProcessInfo.processInfo.environment["LOGIC_MCP_ADR002_TARGET_REF"] != "0"
    }

    #if DEBUG
    static func withAdr002TargetRefForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $adr002TargetRefOverride.withValue(value, operation: operation)
    }
    #endif

    static var adr003StrictParams: Bool {
        #if DEBUG
        if let adr003StrictParamsOverride { return adr003StrictParamsOverride }
        #endif
        return ProcessInfo.processInfo.environment["LOGIC_MCP_ADR003_STRICT_PARAMS"] != "0"
    }

    #if DEBUG
    static func withAdr003StrictParamsForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $adr003StrictParamsOverride.withValue(value, operation: operation)
    }
    #endif

    static var adr004MutationSaga: Bool {
        #if DEBUG
        if let adr004MutationSagaOverride { return adr004MutationSagaOverride }
        #endif
        return ProcessInfo.processInfo.environment["LOGIC_MCP_ADR004_MUTATION_SAGA"] == "1"
    }

    static var adr005OperationTrace: Bool {
        #if DEBUG
        if let adr005OperationTraceOverride { return adr005OperationTraceOverride }
        #endif
        return ProcessInfo.processInfo.environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] == "1"
    }

    #if DEBUG
    static func withAdr004MutationSagaForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $adr004MutationSagaOverride.withValue(value, operation: operation)
    }

    static func withAdr005OperationTraceForTests<Result>(
        _ value: Bool,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $adr005OperationTraceOverride.withValue(value, operation: operation)
    }
    #endif

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

    static var adr010MidiReadback: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR010_MIDI_READBACK"] == "1"
    }

    static var adr011CompressorControl: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR011_COMPRESSOR_CONTROL"] == "1"
    }

    static var adr012SpectralEQ: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR012_SPECTRAL_EQ"] == "1"
    }

    static var adr013ChannelEQ: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR013_CHANNEL_EQ"] == "1"
    }

    static var adr015PianoRoll: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR015_PIANO_ROLL"] == "1"
    }

    static var adr016SmartTempo: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR016_SMART_TEMPO"] == "1"
    }

    static var adr017FlexPitch: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR017_FLEX_PITCH"] == "1"
    }

    static var adr018HostParams: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR018_HOST_PARAMS"] == "1"
    }
}
