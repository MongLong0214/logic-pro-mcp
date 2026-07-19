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
    // #399 (CEO audit P0) — DEBUG-ONLY seam coverage. `QualificationFaultInjection`
    // and the transport fault modes are compiled solely under
    // `QUALIFICATION_FAULT_SEAM` (see Package.swift). This block references those
    // excluded symbols and/or drives the DEBUG executable (which HAS the seam), so
    // it compiles/runs only in the debug test build and is absent from a
    // `-c release` test build. It proves the qualification fault modes STILL WORK
    // in debug — the coverage the release-exclusion inversion would otherwise drop.
    #if QUALIFICATION_FAULT_SEAM
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

    /// FINDING 1 (#399) — debug transport-fault E2E, restored. The retired
    /// `timeoutIsObservedFromRealServerResponse` proved the transport `timeout`
    /// fault is observable end-to-end from a real server response. The seam is now
    /// compiled out of release, but it MUST still work in debug — that IS the
    /// qualification affordance. Driving the DEBUG executable (which has the seam)
    /// with `LOGIC_PRO_MCP_FAULT_INJECT=timeout` still yields `operation_timeout`,
    /// State C, and the FAILED classification, over a real request/response frame
    /// pair — matching what the old test proved.
    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.debugExecutableURL.path),
        "Requires `swift build` (debug) before driving the debug fault seam."
    ))
    func debugSeamTimeoutIsObservedFromRealServerResponse() throws {
        try assertDebugServerFault(mode: .timeout, expectedError: "operation_timeout")
    }

    /// FINDING 1 (#399) — debug transport-fault E2E, restored. Mirrors the retired
    /// `partialStateIsObservedFromRealServerResponse`: the DEBUG executable with
    /// `LOGIC_PRO_MCP_FAULT_INJECT=partial_state` still yields
    /// `readback_unavailable`, State C, and the FAILED classification.
    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.debugExecutableURL.path),
        "Requires `swift build` (debug) before driving the debug fault seam."
    ))
    func debugSeamPartialStateIsObservedFromRealServerResponse() throws {
        try assertDebugServerFault(mode: .partialState, expectedError: "readback_unavailable")
    }

    /// Drives the transport.play `__adr001b_no_write_probe` against the DEBUG
    /// server with the fault mode armed and asserts the fault is observed from the
    /// real wire response — the exact contract of the retired real-server tests.
    private func assertDebugServerFault(
        mode: QualificationFaultInjection.Mode,
        expectedError: String
    ) throws {
        let spec = try #require(OperationRegistry.specs.first { $0.id == .transportPlay })
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment[QualificationFaultInjection.environmentKey] = mode.rawValue
        let result = try QualificationTransport(
            requestTimeout: 30,
            shutdownGrace: 1
        ).drive(.init(
            executableURL: Self.debugExecutableURL,
            environment: childEnvironment,
            expectedOperationCount: OperationRegistry.specs.count,
            operations: [spec]
        ))
        let operation = try #require(result.operationResults[spec.id.rawValue])
        let frames = result.wireFrames.filter {
            $0.operationID == "operation_probe.\(spec.id.rawValue)"
        }
        #expect(frames.map(\.direction) == [.request, .response])
        let isError = try #require(operation.isError)
        #expect(isError)
        let state = try #require(operation.state)
        #expect(state == "C")
        let error = try #require(operation.error)
        #expect(error == expectedError)
        #expect(operation.status == .failed)
        let responseData = try #require(operation.responseData)
        #expect(!responseData.contains(Data("fault_injection".utf8)))
    }

    private static let debugExecutableURL = ProcessInfo.processInfo.environment[
        "LPMCP_TEST_DEBUG_SERVER_EXECUTABLE"
    ].map { URL(fileURLWithPath: $0) } ?? URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/debug/LogicProMCP")
    #endif

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
