import Testing
@testable import LogicProMCP

/// The debug fault seam's contract.
///
/// This file used to also drive the release and debug executables through `QualificationTransport`
/// to prove the seam is absent from a release binary end to end. That transport was part of the
/// release-certification system removed on 2026-09-12, and the tests that drove it went with it.
/// What survives is the seam's own rule, which is what the saga compensation tests depend on:
/// `FaultInjectionSeam` answers for the two documented modes and for nothing else.
///
/// The release-exclusion property itself is now a build fact rather than a test: `Package.swift`
/// defines `FAULT_TEST_SEAM` only for debug, so the type does not exist in a release build. A test
/// cannot assert that from inside a debug build, and asserting it from a release build requires the
/// subprocess driver that was deleted.
@Suite("Fault injection seam")
struct FaultInjectionSeamTests {
    #if FAULT_TEST_SEAM
    @Test func injectionResolvesOnlyDocumentedModes() throws {
        #expect(FaultInjectionSeam(environment: [:]) == nil)
        #expect(FaultInjectionSeam(environment: [
            FaultInjectionSeam.environmentKey: "unknown",
        ]) == nil)
        let timeout = try #require(FaultInjectionSeam(environment: [
            FaultInjectionSeam.environmentKey: "timeout",
        ]))
        #expect(timeout.mode == .timeout)
        let partial = try #require(FaultInjectionSeam(environment: [
            FaultInjectionSeam.environmentKey: "partial_state",
        ]))
        #expect(partial.mode == .partialState)
    }
    #endif
}
