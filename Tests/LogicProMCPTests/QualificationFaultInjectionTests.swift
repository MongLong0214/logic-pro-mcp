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

    @Test(arguments: [
        (QualificationFaultInjection.Mode.timeout, "qualification_timeout"),
        (QualificationFaultInjection.Mode.partialState, "qualification_partial_state"),
    ])
    func injectedMutationFailsClosedBeforeWrite(
        mode: QualificationFaultInjection.Mode,
        expectedError: String
    ) throws {
        let injection = QualificationFaultInjection(mode: mode)
        let envelope = try JSONDecoder().decode(
            QualificationFaultInjection.Envelope.self,
            from: injection.responseData
        )

        #expect(envelope.success == false)
        #expect(envelope.state == "C")
        #expect(envelope.error == expectedError)
        #expect(envelope.writeAttempted == false)
        #expect(envelope.faultInjection == mode.rawValue)
        #expect(injection.failureReason == "qualification_fault_injected:\(mode.rawValue)")
    }
}
