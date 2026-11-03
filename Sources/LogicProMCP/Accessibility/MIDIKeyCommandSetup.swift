import Foundation

/// Consent-gated orchestration for the first verified MIDI Key Command binding.
///
/// The runtime owns all UI interaction and must return only after its Key Commands
/// surface has been cleaned up. This type decides when an observed label is enough
/// to check, when Learn is permitted, and when functional background execution may
/// promote one operation to process-local readiness.
enum MIDIKeyCommandSetup {
    enum Mode: String, Equatable, Sendable {
        case check
        case apply
    }

    enum Inspection: Equatable, Sendable {
        case missing
        case matchingLabelUnverifiedSource
        case conflicting
        case provisional
        case unreadable
        case ambiguous
    }

    enum LearnResult: Equatable, Sendable {
        case learnedAndObserved
        case conflict(cleanupConfirmed: Bool, writeAttempted: Bool)
        case failed(stage: String, cleanupConfirmed: Bool, writeAttempted: Bool)
    }

    enum BackgroundVerification: Equatable, Sendable {
        case verifiedAndRestored
        case noObservedEffect
        case focusChangedDuringExecution
        case effectObservedRestoreFailed
        case transportFailure(writeAttempted: Bool, cleanupConfirmed: Bool)
    }

    enum Outcome: Equatable, Sendable {
        case consentRequired
        case checked(Inspection)
        case verified
        case failed(stage: String, cleanupConfirmed: Bool, writeAttempted: Bool)
    }

    struct Runtime: Sendable {
        let inspect: @Sendable (MIDIKeyCommandBindingCatalog.Entry) async -> Inspection
        let learn: @Sendable (MIDIKeyCommandBindingCatalog.Entry) async -> LearnResult
        let verifyBackgroundExecution: @Sendable (
            MIDIKeyCommandBindingCatalog.Entry
        ) async -> BackgroundVerification
        /// Atomically validates the caller's ownership and records readiness.
        /// Returns false when ownership or the destination channel changed.
        let recordVerifiedIfOwned: @Sendable (String) async -> Bool
        let permitsMutation: @Sendable () -> Bool

        init(
            inspect: @escaping @Sendable (MIDIKeyCommandBindingCatalog.Entry) async -> Inspection,
            learn: @escaping @Sendable (MIDIKeyCommandBindingCatalog.Entry) async -> LearnResult,
            verifyBackgroundExecution: @escaping @Sendable (
                MIDIKeyCommandBindingCatalog.Entry
            ) async -> BackgroundVerification,
            recordVerifiedIfOwned: @escaping @Sendable (String) async -> Bool,
            permitsMutation: @escaping @Sendable () -> Bool
        ) {
            self.inspect = inspect
            self.learn = learn
            self.verifyBackgroundExecution = verifyBackgroundExecution
            self.recordVerifiedIfOwned = recordVerifiedIfOwned
            self.permitsMutation = permitsMutation
        }
    }

    static func run(consent: Bool, mode: Mode, runtime: Runtime) async -> Outcome {
        guard consent else { return .consentRequired }
        guard runtime.permitsMutation() else {
            return .failed(
                stage: "ownership_lost",
                cleanupConfirmed: true,
                writeAttempted: false
            )
        }
        guard let entry = MIDIKeyCommandBindingCatalog.entries.first else {
            return .failed(stage: "catalog_empty", cleanupConfirmed: true, writeAttempted: false)
        }

        var writeAttempted = false
        var learnedBindingPersisted = false
        let inspection = await runtime.inspect(entry)
        if mode == .check {
            return .checked(inspection)
        }

        switch inspection {
        case .missing:
            guard runtime.permitsMutation() else {
                return .failed(
                    stage: "ownership_lost",
                    cleanupConfirmed: true,
                    writeAttempted: writeAttempted
                )
            }
            switch await runtime.learn(entry) {
            case .learnedAndObserved:
                writeAttempted = true
                learnedBindingPersisted = true
                break
            case .conflict(let cleanupConfirmed, let learnWriteAttempted):
                return .failed(
                    stage: "binding_conflict",
                    cleanupConfirmed: cleanupConfirmed,
                    writeAttempted: learnWriteAttempted
                )
            case .failed(let stage, let cleanupConfirmed, let learnWriteAttempted):
                return .failed(
                    stage: stage,
                    cleanupConfirmed: cleanupConfirmed,
                    writeAttempted: learnWriteAttempted
                )
            }

        case .matchingLabelUnverifiedSource:
            break

        case .conflicting:
            return .failed(stage: "binding_conflict", cleanupConfirmed: true, writeAttempted: false)
        case .provisional:
            return .failed(stage: "binding_provisional", cleanupConfirmed: true, writeAttempted: false)
        case .unreadable:
            return .failed(stage: "binding_unreadable", cleanupConfirmed: true, writeAttempted: false)
        case .ambiguous:
            return .failed(stage: "command_ambiguous", cleanupConfirmed: true, writeAttempted: false)
        }

        guard runtime.permitsMutation() else {
            return .failed(
                stage: "ownership_lost",
                cleanupConfirmed: !learnedBindingPersisted,
                writeAttempted: writeAttempted
            )
        }
        switch await runtime.verifyBackgroundExecution(entry) {
        case .verifiedAndRestored:
            writeAttempted = true
            guard runtime.permitsMutation() else {
                return .failed(
                    stage: "ownership_lost",
                    cleanupConfirmed: !learnedBindingPersisted,
                    writeAttempted: writeAttempted
                )
            }
            guard await runtime.recordVerifiedIfOwned(entry.operation) else {
                return .failed(
                    stage: "readiness_rejected",
                    cleanupConfirmed: !learnedBindingPersisted,
                    writeAttempted: writeAttempted
                )
            }
            return .verified
        case .noObservedEffect:
            return .failed(
                stage: "background_verify",
                cleanupConfirmed: !learnedBindingPersisted,
                writeAttempted: true
            )
        case .focusChangedDuringExecution:
            return .failed(stage: "background_focus", cleanupConfirmed: false, writeAttempted: true)
        case .effectObservedRestoreFailed:
            return .failed(stage: "background_restore", cleanupConfirmed: false, writeAttempted: true)
        case .transportFailure(let verificationWriteAttempted, let verificationCleanupConfirmed):
            return .failed(
                stage: "background_transport",
                cleanupConfirmed: verificationCleanupConfirmed && !learnedBindingPersisted,
                writeAttempted: writeAttempted || verificationWriteAttempted
            )
        }
    }
}
