import Foundation
import Testing
@testable import LogicProMCP

private actor MIDISetupProbe {
    var inspections = 0
    var learns = 0
    var verifications = 0
    var recorded: [String] = []

    func inspected() { inspections += 1 }
    func learned() { learns += 1 }
    func verified() { verifications += 1 }
    func record(_ operation: String) { recorded.append(operation) }
}

private func midiSetupRuntime(
    probe: MIDISetupProbe,
    inspection: MIDIKeyCommandSetup.Inspection,
    learn: MIDIKeyCommandSetup.LearnResult = .learnedAndObserved,
    verification: MIDIKeyCommandSetup.BackgroundVerification = .verifiedAndRestored,
    recordAccepted: Bool = true,
    permitsMutation: @escaping @Sendable () -> Bool = { true }
) -> MIDIKeyCommandSetup.Runtime {
    MIDIKeyCommandSetup.Runtime(
        inspect: { _ in
            await probe.inspected()
            return inspection
        },
        learn: { _ in
            await probe.learned()
            return learn
        },
        verifyBackgroundExecution: { _ in
            await probe.verified()
            return verification
        },
        recordVerifiedIfOwned: { operation in
            guard recordAccepted else { return false }
            await probe.record(operation)
            return true
        },
        permitsMutation: permitsMutation
    )
}

@Test func midiSetupRefusesBeforeInspectionWithoutConsent() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(probe: probe, inspection: .missing)

    let outcome = await MIDIKeyCommandSetup.run(consent: false, mode: .apply, runtime: runtime)

    #expect(outcome == .consentRequired)
    #expect(await probe.inspections == 0)
    #expect(await probe.learns == 0)
    #expect(await probe.verifications == 0)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupCheckNeverLearnsVerifiesOrMarksReady() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(probe: probe, inspection: .matchingLabelUnverifiedSource)

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .check, runtime: runtime)

    #expect(outcome == .checked(.matchingLabelUnverifiedSource))
    #expect(await probe.inspections == 1)
    #expect(await probe.learns == 0)
    #expect(await probe.verifications == 0)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupApplyLearnsMissingBindingThenRequiresBackgroundVerificationAndRestore() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(probe: probe, inspection: .missing)

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .verified)
    #expect(await probe.inspections == 1)
    #expect(await probe.learns == 1)
    #expect(await probe.verifications == 1)
    #expect(await probe.recorded == ["transport.toggle_metronome"])
}

@Test func midiSetupMatchingLabelStillNeedsOwnedPortFunctionalVerification() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .matchingLabelUnverifiedSource,
        verification: .noObservedEffect
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_verify",
        cleanupConfirmed: true,
        writeAttempted: true
    ))
    #expect(await probe.learns == 0)
    #expect(await probe.verifications == 1)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupNeverMarksReadyWhenFocusChangedDuringExecutionInterval() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .matchingLabelUnverifiedSource,
        verification: .focusChangedDuringExecution
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_focus",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupNeverMarksReadyWhenRestorationIsUnconfirmed() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        verification: .effectObservedRestoreFailed
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_restore",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLostGateAfterInspectionPerformsNoLearnOrVerification() async {
    let probe = MIDISetupProbe()
    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func next() -> Bool {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return reads == 1
        }
    }
    let permit = Permit()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        permitsMutation: { permit.next() }
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "ownership_lost",
        cleanupConfirmed: true,
        writeAttempted: false
    ))
    #expect(await probe.inspections == 1)
    #expect(await probe.learns == 0)
    #expect(await probe.verifications == 0)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupTransportFailureAfterPossibleDeliveryRetainsUncertainWriteReceipt() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .matchingLabelUnverifiedSource,
        verification: .transportFailure(writeAttempted: true, cleanupConfirmed: false)
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_transport",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupRejectedReadinessPromotionDoesNotClaimVerification() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .matchingLabelUnverifiedSource,
        recordAccepted: false
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "readiness_rejected",
        cleanupConfirmed: true,
        writeAttempted: true
    ))
    #expect(await probe.verifications == 1)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnConflictPreservesNoWriteReceipt() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        learn: .conflict(cleanupConfirmed: true, writeAttempted: false)
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "binding_conflict",
        cleanupConfirmed: true,
        writeAttempted: false
    ))
    #expect(await probe.verifications == 0)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnFailurePreservesUncertainWriteReceipt() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        learn: .failed(
            stage: "learn_transport",
            cleanupConfirmed: false,
            writeAttempted: true
        )
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "learn_transport",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.verifications == 0)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnedBindingRemainsUncleanWhenBackgroundEffectIsAbsent() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        verification: .noObservedEffect
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_verify",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.learns == 1)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnWriteSurvivesPreDeliveryVerificationFailure() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        verification: .transportFailure(writeAttempted: false, cleanupConfirmed: true)
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_transport",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.learns == 1)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupTransportCleanupIsIndependentOfDeliveryReceipt() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .matchingLabelUnverifiedSource,
        verification: .transportFailure(writeAttempted: false, cleanupConfirmed: false)
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_transport",
        cleanupConfirmed: false,
        writeAttempted: false
    ))
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnedBindingRemainsUncleanWhenOwnershipExpiresBeforeVerification() async {
    let probe = MIDISetupProbe()
    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func next() -> Bool {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return reads < 3
        }
    }
    let permit = Permit()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        permitsMutation: { permit.next() }
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "ownership_lost",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.learns == 1)
    #expect(await probe.verifications == 0)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnedBindingRemainsUncleanWhenOwnershipExpiresAfterVerification() async {
    let probe = MIDISetupProbe()
    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func next() -> Bool {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return reads < 4
        }
    }
    let permit = Permit()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        permitsMutation: { permit.next() }
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "ownership_lost",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.verifications == 1)
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnedBindingRemainsUncleanWhenReadinessPromotionIsRejected() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .missing,
        recordAccepted: false
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "readiness_rejected",
        cleanupConfirmed: false,
        writeAttempted: true
    ))
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupPreexistingBindingRetainsConfirmedTransportCleanup() async {
    let probe = MIDISetupProbe()
    let runtime = midiSetupRuntime(
        probe: probe,
        inspection: .matchingLabelUnverifiedSource,
        verification: .transportFailure(writeAttempted: false, cleanupConfirmed: true)
    )

    let outcome = await MIDIKeyCommandSetup.run(consent: true, mode: .apply, runtime: runtime)

    #expect(outcome == .failed(
        stage: "background_transport",
        cleanupConfirmed: true,
        writeAttempted: false
    ))
    #expect(await probe.recorded.isEmpty)
}

@Test func midiSetupLearnNewAssignmentLabelIsExactAndDistinct() {
    let labels = AXLocalePolicy.learnNewAssignmentControl

    for title in [
        "Learn New Assignment", "새로운 할당 학습", "新規割り当てを登録",
        "Neue Zuweisung lernen", "Aprender nueva asignación",
        "Apprendre une nouvelle assignation", "Impara nuova assegnazione",
        "Aprender Nova Atribuição", "学习新的分配", "學習新指定"
    ] {
        #expect(labels.matches(title, mode: .exact))
    }

    #expect(!labels.matches("1", mode: .exact))
    #expect(!labels.matches("Learn by Key Label", mode: .exact))
    #expect(!labels.matches("키 레이블로 학습", mode: .exact))
}
