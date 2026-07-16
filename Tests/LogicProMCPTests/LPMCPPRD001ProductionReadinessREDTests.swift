import Foundation
import Testing
@testable import LogicProMCP

/// RED contracts for #367 / LPMCP-PRD-001 residual production readiness.
/// Exact base under remediation: main `cc5922e5c5c2786c401713fd80b1bd40d1e15f14`.
@Suite("LPMCP-PRD-001 production readiness RED")
struct LPMCPPRD001ProductionReadinessREDTests {
    private let expectedBaseSHA = "cc5922e5c5c2786c401713fd80b1bd40d1e15f14"

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tests/LogicProMCPTests/ThisFile.swift → repo root
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
    }

    // MARK: - Fixture-level contract purity (always pin detector behavior)

    @Test func r_rel_rejectsReleaseWorkflowWithoutIndependentQualificationStep() {
        let yaml = """
        jobs:
          build:
            steps:
              - name: Create GitHub Release
        """
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: yaml,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(report.openDebts.contains(.releaseWorkflowMissingIndependentQualification))
    }

    @Test func r_rel_rejectsIndependentQualificationStepThatCannotBlockRelease() {
        let fixture = """
        jobs:
          build:
            steps:
              - name: Enforce independent exact-artifact qualification
                <DIRECTIVE>
                run: ./LogicProMCP --verify-promotion
              - name: Create GitHub Release
                run: gh release create
        """
        for directive in ["continue-on-error: true", "if: false"] {
            let report = ProductionReadinessContractEvaluator.evaluate(
                releaseWorkflowYAML: fixture.replacingOccurrences(
                    of: "<DIRECTIVE>",
                    with: directive
                ),
                registeredOperationIDs: ["system.health"],
                semanticValidatorOperationIDs: ["system.health"],
                requiredMatrixAxisCount: 4,
                debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
                expectedAuthorityBaseSHA: expectedBaseSHA,
                publishedReleaseEvidencePresent: true,
                mutationRestoreCompensationEvidencePresent: true,
                independentProvenanceEnforced: true
            )

            #expect(
                report.openDebts.contains(.releaseWorkflowMissingIndependentQualification),
                "\(directive) must make the release gate non-blocking"
            )
        }
    }

    @Test func r_rel_ignoresGateNameSpoofedInsideRunBlock() {
        let fixture = """
        jobs:
          build:
            steps:
              - name: Decoy
                run: |
                  echo "- name: Enforce independent exact-artifact qualification"
              - name: Enforce independent exact-artifact qualification
                continue-on-error: true
                run: ./LogicProMCP --verify-promotion
              - name: Create GitHub Release
                run: gh release create
        """
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: fixture,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )

        #expect(report.openDebts.contains(.releaseWorkflowMissingIndependentQualification))
    }

    @Test func r_rel_ignoresGateAndReleaseAnchorsInsideRunBlock() {
        let fixture = """
        jobs:
          build:
            steps:
              - name: Decoy
                run: |
                  - name: Enforce independent exact-artifact qualification
                    run: ./LogicProMCP --verify-promotion
                  - name: Create GitHub Release
              - name: Enforce independent exact-artifact qualification
                if: false
                run: ./LogicProMCP --verify-promotion
              - name: Create GitHub Release
                run: gh release create
        """
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: fixture,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )

        #expect(report.openDebts.contains(.releaseWorkflowMissingIndependentQualification))
    }

    @Test func r_sem_rejectsWhenSemanticValidatorsCoverOnlyHealth() {
        let ops = (0..<10).map { "op.\($0)" } + ["system.health"]
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: """
            - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)
            managed-fixture-matrix
            \(ProductionReadinessContractEvaluator.mutationEvidenceMarker)
            \(ProductionReadinessContractEvaluator.provenanceMarker)
            \(ProductionReadinessContractEvaluator.publishedEvidenceMarker)
            """,
            registeredOperationIDs: ops,
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(report.openDebts.contains(.semanticCoverageIncomplete))
        #expect(report.registeredOperationCount == 11)
        #expect(report.semanticValidatorOperationCount == 1)
    }

    @Test func r_matrix_rejectsWhenManagedFixtureMatrixUnbound() {
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: """
            - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)
            \(ProductionReadinessContractEvaluator.mutationEvidenceMarker)
            \(ProductionReadinessContractEvaluator.provenanceMarker)
            \(ProductionReadinessContractEvaluator.publishedEvidenceMarker)
            """,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: QualificationAxis.requiredCombinations.count,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(report.openDebts.contains(.managedFixtureMatrixUnbound))
    }

    @Test func r_mut_r_prov_r_pub_rejectWhenMarkersAbsent() {
        let report = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: """
            - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)
            managed-fixture-matrix
            """,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: false,
            mutationRestoreCompensationEvidencePresent: false,
            independentProvenanceEnforced: false
        )
        #expect(report.openDebts.contains(.mutationRestoreCompensationMissing))
        #expect(report.openDebts.contains(.independentProvenanceNotEnforced))
        #expect(report.openDebts.contains(.publishedImmutableEvidenceMissing))
    }

    @Test func r_auth_rejectsMissingOrMismatchedDebtBoardSHA() {
        let missing = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: fullGreenWorkflowYAML(),
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: nil,
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(missing.openDebts.contains(.authorityBaseSHAUnbound))

        let mismatched = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: fullGreenWorkflowYAML(),
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: 4,
            debtBoardMarkdown: "Exact base: deadbeef",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(mismatched.openDebts.contains(.authorityBaseSHAUnbound))
    }

    // MARK: - Current remediation tree

    @Test func currentMainTreeOpensResidualLPMCPPRD001Debts() throws {
        let report = try ProductionReadinessContractEvaluator.evaluateRepositoryRoot(
            repositoryRoot,
            expectedAuthorityBaseSHA: expectedBaseSHA
        )
        #expect(report.registeredOperationCount == OperationRegistry.specs.count)
        if report.openDebts.isEmpty {
            #expect(report.satisfied)
        } else {
            // STATUS pin may close R-AUTH; residual production debts must still open.
            #expect(report.openDebts.contains(.semanticCoverageIncomplete)
                || report.openDebts.contains(.managedFixtureMatrixUnbound)
                || report.openDebts.contains(.releaseWorkflowMissingIndependentQualification)
                || report.openDebts.contains(.mutationRestoreCompensationMissing)
                || report.openDebts.contains(.independentProvenanceNotEnforced)
                || report.openDebts.contains(.publishedImmutableEvidenceMissing))
            #expect(!report.satisfied)
        }
    }

    /// Aggregate production-readiness bar for this remediation. RED until full GREEN.
    @Test func productionReadinessContractsAreSatisfiedOnCurrentTree() throws {
        let report = try ProductionReadinessContractEvaluator.evaluateRepositoryRoot(
            repositoryRoot,
            expectedAuthorityBaseSHA: expectedBaseSHA
        )
        #expect(
            report.satisfied,
            "LPMCP-PRD-001 open debts: \(report.openDebts.map(\.rawValue).joined(separator: ",")) — \(report.findings.map(\.detail).joined(separator: " | "))"
        )
    }

    // MARK: - Helpers

    private func fullGreenWorkflowYAML() -> String {
        """
        - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)
        managed-fixture-matrix
        \(ProductionReadinessContractEvaluator.mutationEvidenceMarker)
        \(ProductionReadinessContractEvaluator.provenanceMarker)
        \(ProductionReadinessContractEvaluator.publishedEvidenceMarker)
        """
    }
}
