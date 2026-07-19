import Foundation
import Testing
@testable import LogicProMCP

/// #399 (CEO audit P0) — the qualification fault-injection seam is a debug-only
/// TEST affordance, never a shipped feature. A release binary must contain
/// neither the `LOGIC_PRO_MCP_FAULT_INJECT` string nor any code path that acts on
/// it, so its ordinary process environment cannot activate a fault. These tests
/// pin both the debug seam contract and the release exclusion.
///
/// The `swift test` build compiles the LogicProMCP module in debug (with
/// `QUALIFICATION_FAULT_SEAM`), so `QualificationFaultInjection` is present here;
/// the release-binary probes drive the separately built `-c release` executable,
/// which has it compiled out.
@Suite("Qualification fault seam — release exclusion (#399)")
struct QualificationFaultInjectionTests {
    /// TEST (C) — debug seam contract. `QualificationFaultInjection` returns
    /// non-nil ONLY for the exact documented modes; every other value is nil.
    @Test func injectionResolvesOnlyDocumentedModes() throws {
        #expect(QualificationFaultInjection(environment: [:]) == nil)
        #expect(QualificationFaultInjection(environment: [
            QualificationFaultInjection.environmentKey: "unknown",
        ]) == nil)
        let timeout = try #require(QualificationFaultInjection(environment: [
            QualificationFaultInjection.environmentKey: "timeout",
        ]))
        #expect(timeout.mode == .timeout)
        let partial = try #require(QualificationFaultInjection(environment: [
            QualificationFaultInjection.environmentKey: "partial_state",
        ]))
        #expect(partial.mode == .partialState)
    }

    /// TEST (A) — dead-string scan. The release binary must not contain the fault
    /// env-key bytes anywhere. RED before #399 (the string was present); GREEN
    /// after the compile-time exclusion. No shelling to `strings`.
    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before scanning the release binary."
    ))
    func releaseBinaryContainsNoFaultInjectionEnvString() throws {
        let data = try Data(contentsOf: Self.releaseExecutableURL, options: .mappedIfSafe)
        let needle = Data("LOGIC_PRO_MCP_FAULT_INJECT".utf8)
        #expect(data.range(of: needle) == nil)
    }

    /// TEST (B) — release behavior. Launching the release binary with the fault
    /// env set must yield behavior identical to the unset-env run: the
    /// transport.play no-write probe is the normal typed zero-write refusal, never
    /// the injected fault. RED before #399 (`partial_state` → readback_unavailable);
    /// GREEN after.
    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before the release fault-exclusion probe."
    ))
    func releaseBinaryIgnoresPartialStateFaultEnv() throws {
        let baseline = try driveTransportPlayProbe(faultEnv: [:])
        let withFault = try driveTransportPlayProbe(faultEnv: [
            "LOGIC_PRO_MCP_FAULT_INJECT": "partial_state",
            "LOGIC_PRO_MCP_FAULT_INJECT_STEP": "0",
        ])
        #expect(withFault.error != "readback_unavailable")
        try assertNormalZeroWriteRefusal(baseline)
        try assertNormalZeroWriteRefusal(withFault)
    }

    /// TEST (B), timeout mode. The `timeout` fault (a 60s sleep in debug) must be
    /// absent from release: the probe returns the normal refusal promptly, never
    /// `operation_timeout`. RED before #399; GREEN after.
    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before the release fault-exclusion probe."
    ))
    func releaseBinaryIgnoresTimeoutFaultEnv() throws {
        let baseline = try driveTransportPlayProbe(faultEnv: [:])
        let withFault = try driveTransportPlayProbe(faultEnv: [
            "LOGIC_PRO_MCP_FAULT_INJECT": "timeout",
        ])
        #expect(withFault.error != "operation_timeout")
        try assertNormalZeroWriteRefusal(baseline)
        try assertNormalZeroWriteRefusal(withFault)
    }

    /// The shipped behavior for a mutating no-write probe: a typed State-C
    /// zero-write refusal (`invalid_params`, `write_attempted=false`).
    private func assertNormalZeroWriteRefusal(
        _ probe: QualificationOperationResult
    ) throws {
        #expect(probe.state == "C")
        let error = try #require(probe.error)
        #expect(error == "invalid_params")
        let isError = try #require(probe.isError)
        #expect(isError)
        let writeAttempted = try #require(probe.writeAttempted)
        #expect(!writeAttempted)
    }

    private func driveTransportPlayProbe(
        faultEnv: [String: String]
    ) throws -> QualificationOperationResult {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        var childEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in faultEnv { childEnvironment[key] = value }
        let result = try QualificationTransport(
            requestTimeout: 30,
            shutdownGrace: 1
        ).drive(.init(
            executableURL: Self.releaseExecutableURL,
            environment: childEnvironment,
            expectedOperationCount: OperationRegistry.specs.count,
            operations: [spec]
        ))
        return try #require(result.operationResults[spec.id.rawValue])
    }

    private static let releaseExecutableURL = ProcessInfo.processInfo.environment[
        "LPMCP_TEST_SERVER_EXECUTABLE"
    ].map { URL(fileURLWithPath: $0) } ?? URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/release/LogicProMCP")
}
