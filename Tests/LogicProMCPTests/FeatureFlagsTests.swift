import Foundation
import Testing
@testable import LogicProMCP

// PRD-007 Part 2 (ADR-002 #285): `LOGIC_MCP_ADR002_TARGET_REF` is DEFAULT ON.
// The variable is now a kill-switch, not an opt-in — it is read with `!= "0"`,
// so ONLY the exact string "0" disables the machinery.
//
// `.serialized` is load-bearing, not decoration. These tests assert on the ENV
// read path, so they cannot use the `@TaskLocal` override (which bypasses it) —
// they must mutate the real environment, and `setenv`/`unsetenv` are
// process-global. Run concurrently, one test's `setenv("1")` satisfies another
// test's unset-means-ON expectation and the suite goes GREEN without proving
// anything. That false pass is not hypothetical: it is what this file did when
// the default-ON assertion was first written against the old `== "1"` source.
//
// SPELLING IS LOAD-BEARING TOO: every assertion below is a BARE `#expect(x)` /
// `#expect(!x)`. Do NOT rewrite them as `#expect(x == true)` — under this
// toolchain `#expect(<Bool> == true/false)` is DEAD and passes unconditionally,
// even for a non-optional Bool. Verified empirically: an `#expect(true == false)`
// PASSES here. The `== true/false` form is how this file's assertions were first
// written, and it is why they went green against a source that still read `== "1"`.
@Suite("Feature flag environment contract", .serialized)
struct FeatureFlagEnvironmentTests {
    private func withTargetRefEnv<Result>(
        _ value: String?,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try Self.withEnv("LOGIC_MCP_ADR002_TARGET_REF", value, body)
    }

    fileprivate static func withEnv<Result>(
        _ key: String,
        _ value: String?,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let previous = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try body()
    }

    @Test("(a) no env and no override reads as ON — the shipped production default")
    func targetRefDefaultsToOn() {
        withTargetRefEnv(nil) {
            #expect(FeatureFlags.adr002TargetRef)
        }
    }

    @Test("(b) the =0 kill-switch disables it — the operator's rollback path")
    func targetRefKillSwitchZeroDisables() {
        withTargetRefEnv("0") {
            #expect(!FeatureFlags.adr002TargetRef)
        }
    }

    @Test("(c) the pre-promotion =1 opt-in spelling still reads as ON")
    func targetRefExplicitOneStaysOn() {
        // Deployments that already set =1 explicitly see no change.
        withTargetRefEnv("1") {
            #expect(FeatureFlags.adr002TargetRef)
        }
    }

    @Test("the kill-switch matches \"0\" exactly — =false does NOT disable")
    func targetRefKillSwitchMatchesZeroExactly() {
        // A footgun worth pinning: an operator who writes =false (or =off/=no)
        // has NOT disabled the feature. Pinned so the one documented rollback
        // spelling stays the only working one.
        for notDisabled in ["false", "off", "no", "", " 0", "00"] {
            withTargetRefEnv(notDisabled) {
                #expect(
                    FeatureFlags.adr002TargetRef,
                    "LOGIC_MCP_ADR002_TARGET_REF=\(notDisabled) must NOT read as disabled — only \"0\" is the kill-switch"
                )
            }
        }
    }

    @Test("ADR-005 operation trace stays default OFF")
    func operationTraceDefaultsToFalse() {
        Self.withEnv("LOGIC_MCP_ADR005_OPERATION_TRACE", nil) {
            #expect(!FeatureFlags.adr005OperationTrace)
        }
    }
}
