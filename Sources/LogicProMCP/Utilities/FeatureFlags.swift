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

    /// PRD (ADR-005 #288 R2): promoted from opt-in to DEFAULT ON, so the
    /// variable is now a kill-switch — read with `!= "0"` because an absent
    /// variable must mean ON. Only the exact string "0" rolls back; deployments
    /// already passing the pre-promotion "1" see no change. R2 debate ratified
    /// the flip: measured overhead is 45.7µs/op (see OperationTraceOverheadBench)
    /// — 3-4 orders of magnitude under AX round-trip latency; the store is
    /// bounded (128 traces / 8MiB FIFO); the write-time privacy allowlist is
    /// live-verified; so the support value — a `trace_id` on every result — is
    /// worth carrying by default.
    static var adr005OperationTrace: Bool {
        #if DEBUG
        if let adr005OperationTraceOverride { return adr005OperationTraceOverride }
        #endif
        return ProcessInfo.processInfo.environment["LOGIC_MCP_ADR005_OPERATION_TRACE"] != "0"
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

    static var adr009PluginCapabilities: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR009_PLUGIN_CAPABILITIES"] == "1"
    }

    static var adr010MidiReadback: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR010_MIDI_READBACK"] == "1"
    }

    static var adr011CompressorControl: Bool {
        ProcessInfo.processInfo.environment["LOGIC_MCP_ADR011_COMPRESSOR_CONTROL"] == "1"
    }

    // `adr012SpectralEQ` was here until 2026-08-28. The spectral commands are promoted, and the
    // flag is REMOVED rather than defaulted on: one nothing reads still looks like a control, and
    // the next person to set `LOGIC_MCP_ADR012_SPECTRAL_EQ=0` would have every reason to expect it
    // to do something.

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
