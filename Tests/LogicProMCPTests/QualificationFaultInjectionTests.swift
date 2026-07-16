import Foundation
import Testing
@testable import LogicProMCP

@Suite("Qualification M4 fault injection")
struct QualificationFaultInjectionTests {
    @Test func injectionIsOffUnlessDocumentedModeIsExplicit() {
        #expect(QualificationFaultInjection(environment: [:]) == nil)
        #expect(QualificationFaultInjection(environment: [
            QualificationFaultInjection.environmentKey: "unknown",
        ]) == nil)
        #expect(QualificationFaultInjection(environment: [
            QualificationFaultInjection.environmentKey: "timeout",
        ])?.mode == .timeout)
        #expect(QualificationFaultInjection(environment: [
            QualificationFaultInjection.environmentKey: "partial_state",
        ])?.mode == .partialState)
    }

    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before running the real-server fault probe."
    ))
    func timeoutIsObservedFromRealServerResponse() throws {
        try assertRealServerFault(mode: .timeout, expectedError: "operation_timeout")
    }

    @Test(.enabled(
        if: FileManager.default.isExecutableFile(atPath: Self.releaseExecutableURL.path),
        "Requires `swift build -c release` before running the real-server fault probe."
    ))
    func partialStateIsObservedFromRealServerResponse() throws {
        try assertRealServerFault(mode: .partialState, expectedError: "readback_unavailable")
    }

    private func assertRealServerFault(
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
            executableURL: Self.releaseExecutableURL,
            environment: childEnvironment,
            expectedOperationCount: OperationRegistry.specs.count,
            operations: [spec]
        ))
        let operation = try #require(result.operationResults[spec.id.rawValue])
        let frames = result.wireFrames.filter {
            $0.operationID == "operation_probe.\(spec.id.rawValue)"
        }

        #expect(frames.map(\.direction) == [.request, .response])
        #expect(operation.isError == true)
        #expect(operation.state == "C")
        #expect(operation.error == expectedError)
        #expect(operation.status == .failed)
        #expect(operation.responseData?.contains(Data("fault_injection".utf8)) == false)
    }

    private static let releaseExecutableURL = ProcessInfo.processInfo.environment[
        "LPMCP_TEST_SERVER_EXECUTABLE"
    ].map { URL(fileURLWithPath: $0) } ?? URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).appendingPathComponent(".build/release/LogicProMCP")
}
