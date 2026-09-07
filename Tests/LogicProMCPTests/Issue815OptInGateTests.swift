import Foundation
import Testing
@testable import LogicProMCP

/// #815 — why four LPMCP-PRD-001 debts are open, pinned so the answer cannot rot.
///
/// `productionReadinessContractsAreSatisfiedOnCurrentTree` records THAT they are open. It does not
/// record WHY, and the why took a measurement to find: every step name and job shape the checker
/// demands is already in `release.yml`, so the failure is a finer condition. It is this one —
/// `blockingStep` refuses a step carrying an `if`, and seven steps carry the same
/// `vars.ADR001_QUALIFICATION_ENFORCED` guard. An opt-in gate is not a gate.
///
/// These tests flip when the gate is made unconditional, which is the point: the diagnosis and the
/// fix cannot drift apart, and whoever removes the `if` is told here what else has to follow.
@Suite("#815 the ADR-001 gate is opt-in")
struct Issue815OptInGateTests {
    private var releaseWorkflow: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(
                contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
                encoding: .utf8
            )
        }
    }

    /// The condition, counted. Seven steps carry it, and they are exactly the chain the checker
    /// walks — so all four debts resolve together and would close together.
    @Test func everyGateStepIsSkippableBehindTheSameRepositoryVariable() throws {
        let yaml = try releaseWorkflow
        let guardClause = "if: ${{ vars.ADR001_QUALIFICATION_ENFORCED == 'true' }}"
        let guarded = yaml.components(separatedBy: guardClause).count - 1
        let gateSteps = [
            "Checkout pinned trusted verifier",
            "Build pinned trusted verifier",
            "Enforce independent exact-artifact qualification",
            "trusted-provenance-verify",
            "Checkout pinned trusted verifier for publish",
            "Build pinned trusted verifier for publish",
            "Reverify downloaded release artifact",
        ]
        let everyGateStepIsPresent = gateSteps.allSatisfy { yaml.contains("- name: \($0)") }
        let sevenStepsAreSkippable = guarded == gateSteps.count

        #expect(everyGateStepIsPresent)
        #expect(sevenStepsAreSkippable)
    }

    /// The step R-REL reports as ABSENT is present in the file. That gap between the report and
    /// the file is what sent the first reading of this down the wrong path.
    @Test func theStepTheDebtCallsMissingIsInTheFile() throws {
        let yaml = try releaseWorkflow
        let named = yaml.contains(
            "- name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)"
        )

        #expect(named)
    }

    /// And the checker's own reason for not seeing it. A step that can be skipped does not block,
    /// so it is not a blocking step — which is the correct reading, not a bug in the checker.
    @Test func aStepThatCanBeSkippedIsNotABlockingStep() throws {
        let job = """
              build:
                steps:
                  - name: Present but skippable
                    if: ${{ vars.SOMETHING == 'true' }}
                    run: echo hi
                  - name: Present and blocking
                    run: echo hi
            """
        let skippable = ProductionReadinessContractEvaluator.blockingStepIsRecognised(
            named: "Present but skippable", in: job
        )
        let blocking = ProductionReadinessContractEvaluator.blockingStepIsRecognised(
            named: "Present and blocking", in: job
        )

        #expect(!skippable)
        #expect(blocking)
    }
}
