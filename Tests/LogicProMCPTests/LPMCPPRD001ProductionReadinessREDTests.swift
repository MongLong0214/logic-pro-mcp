import Foundation
import Testing
@testable import LogicProMCP

/// RED contracts for #367 / LPMCP-PRD-001 residual production readiness.
/// Exact base under remediation: main `cc5922e5c5c2786c401713fd80b1bd40d1e15f14`.
@Suite("LPMCP-PRD-001 production readiness RED")
struct LPMCPPRD001ProductionReadinessREDTests {
    private let expectedBaseSHA = "cc5922e5c5c2786c401713fd80b1bd40d1e15f14"
    private let trustedVerifierCommitSHA = "67fec5fccf817f9978022f0ca262b80a789e2dce"

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

    @Test func r_rel_r_prov_rejectPinnedVerifierApprovalPathMutations() {
        let valid = fullGreenWorkflowYAML()
        let mutableRefWithDecoy = valid.replacingOccurrences(
            of: "        with:\n          ref: \(trustedVerifierCommitSHA)",
            with: "        env:\n          ref: \(trustedVerifierCommitSHA)\n        with:\n          ref: main"
        )
        let candidateWithInertVerifierDecoy = valid
            .replacingOccurrences(
                of: "          LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=\"$TRUSTED_QUALIFICATION_PUBLIC_KEY\" \\\n            trusted-verifier-src/.build/release/trusted-verifier verify \\\n              --candidate LogicProMCP \\\n              --bundle qualification-evidence \\\n              --release-version \"${GITHUB_REF_NAME#v}\" \\\n              --expected-commit \"$GITHUB_SHA\"",
                with: "          ./LogicProMCP \\\n            --verify-promotion \\\n              --attestation qualification-evidence/release-qualification-attestation.json \\\n              --release-version \"${GITHUB_REF_NAME#v}\" \\\n              --expected-commit \"$GITHUB_SHA\""
            )
            .replacingOccurrences(
                of: "          TRUSTED_QUALIFICATION_PUBLIC_KEY: ${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}",
                with: "          TRUSTED_QUALIFICATION_PUBLIC_KEY: ${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}\n          VERIFIER_DECOY: |\n            LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=\"$TRUSTED_QUALIFICATION_PUBLIC_KEY\" \\\n            trusted-verifier-src/.build/release/trusted-verifier verify \\\n              --candidate LogicProMCP \\\n              --bundle qualification-evidence \\\n              --release-version \"${GITHUB_REF_NAME#v}\" \\\n              --expected-commit \"$GITHUB_SHA\""
            )
        let verifierInUnrelatedJob = valid.replacingOccurrences(
            of: "      - name: Create GitHub Release\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191",
            with: "  publish:\n    steps:\n      - name: Create GitHub Release\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191"
        )
        let expressionContinueOnError = valid.replacingOccurrences(
            of: "      - name: Checkout pinned trusted verifier",
            with: "      - name: Checkout pinned trusted verifier\n        continue-on-error: ${{ 1 == 1 }}"
        )
        let expressionSkippedQualification = valid.replacingOccurrences(
            of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
            with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        if: ${{ 1 == 0 }}"
        )
        let uncalledVerifierWithObfuscatedCandidate = valid
            .replacingOccurrences(
                of: "          LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=",
                with: "          verify_decoy() {\n            LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY="
            )
            .replacingOccurrences(
                of: "              --expected-commit \"$GITHUB_SHA\"",
                with: "              --expected-commit \"$GITHUB_SHA\"\n          }\n          ./LogicProMCP \\\n            --verify-\"promotion\""
            )
        let mutations = [
            (
                "mutable verifier ref",
                valid.replacingOccurrences(
                    of: trustedVerifierCommitSHA,
                    with: "main"
                )
            ),
            (
                "trusted verifier invocation removed",
                valid.replacingOccurrences(
                    of: "trusted-verifier-src/.build/release/trusted-verifier verify",
                    with: "true"
                )
            ),
            (
                "candidate self-verification restored",
                valid.replacingOccurrences(
                    of: "trusted-verifier-src/.build/release/trusted-verifier verify",
                    with: "./LogicProMCP --verify-promotion"
                )
            ),
            ("mutable verifier ref with pinned env decoy", mutableRefWithDecoy),
            ("trusted verifier inert decoy with split candidate command", candidateWithInertVerifierDecoy),
            ("trusted verifier runs in unrelated job", verifierInUnrelatedJob),
            ("checkout continue-on-error expression evaluates true", expressionContinueOnError),
            ("qualification if expression evaluates false", expressionSkippedQualification),
            ("trusted verifier is uncalled while candidate command is obfuscated", uncalledVerifierWithObfuscatedCandidate),
        ]

        let validReport = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: valid,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: QualificationAxis.requiredCombinations.count,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(!validReport.openDebts.contains(.releaseWorkflowMissingIndependentQualification))
        #expect(!validReport.openDebts.contains(.independentProvenanceNotEnforced))
        #expect(mutations.allSatisfy { $0.1 != valid }, "every adversarial fixture must mutate the valid workflow")
        #expect(candidateWithInertVerifierDecoy.contains("VERIFIER_DECOY"))

        for (name, yaml) in mutations {
            let report = ProductionReadinessContractEvaluator.evaluate(
                releaseWorkflowYAML: yaml,
                registeredOperationIDs: ["system.health"],
                semanticValidatorOperationIDs: ["system.health"],
                requiredMatrixAxisCount: QualificationAxis.requiredCombinations.count,
                debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
                expectedAuthorityBaseSHA: expectedBaseSHA,
                publishedReleaseEvidencePresent: true,
                mutationRestoreCompensationEvidencePresent: true,
                independentProvenanceEnforced: true
            )

            #expect(
                report.openDebts.contains(.releaseWorkflowMissingIndependentQualification),
                "\(name) must fail R-REL closed"
            )
            #expect(
                report.openDebts.contains(.independentProvenanceNotEnforced),
                "\(name) must fail R-PROV closed"
            )
        }
    }

    @Test func r_rel_r_prov_rejectsExplicitGateExecutionOverrides() {
        let valid = fullGreenWorkflowYAML()
        let mutations = [
            (
                "qualification shell skips the gate script",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        shell: \"/usr/bin/true {0}\""
                )
            ),
            (
                "verifier build uses a forged shell",
                valid.replacingOccurrences(
                    of: "      - name: Build pinned trusted verifier",
                    with: "      - name: Build pinned trusted verifier\n        shell: \"sh -c 'exit 0' {0}\""
                )
            ),
            (
                "verifier build replaces PATH",
                valid.replacingOccurrences(
                    of: "      - name: Build pinned trusted verifier",
                    with: "      - name: Build pinned trusted verifier\n        env:\n          PATH: /tmp/forged-bin"
                )
            ),
            (
                "qualification redirects relative verifier resolution",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        working-directory: /tmp/forged-gate"
                )
            ),
            (
                "qualification shell key has YAML whitespace",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        shell : \"/usr/bin/true {0}\""
                )
            ),
            (
                "qualification shell key is quoted",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        \"shell\": \"/usr/bin/true {0}\""
                )
            ),
            (
                "verifier build uses flow-style PATH",
                valid.replacingOccurrences(
                    of: "      - name: Build pinned trusted verifier",
                    with: "      - name: Build pinned trusted verifier\n        env: { PATH: /tmp/forged-bin }"
                )
            ),
            (
                "qualification working-directory key is quoted",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        \"working-directory\": /tmp/forged-gate"
                )
            ),
            (
                "verifier build injects BASH_ENV",
                valid.replacingOccurrences(
                    of: "      - name: Build pinned trusted verifier",
                    with: "      - name: Build pinned trusted verifier\n        env:\n          BASH_ENV: /tmp/skip-gate"
                )
            ),
            (
                "qualification replaces evidence and trust bindings",
                valid
                    .replacingOccurrences(of: "${{ secrets.QUALIFICATION_EVIDENCE_URL }}", with: "https://attacker.invalid/evidence.zip")
                    .replacingOccurrences(of: "${{ secrets.QUALIFICATION_EVIDENCE_SHA256 }}", with: "attacker-digest")
                    .replacingOccurrences(of: "${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}", with: "attacker-key")
            ),
            (
                "job default shell skips run steps",
                valid.replacingOccurrences(
                    of: "  build:\n    steps:",
                    with: "  build:\n    defaults:\n      run:\n        shell: \"/usr/bin/true {0}\"\n    steps:"
                )
            ),
            (
                "workflow default shell skips run steps",
                valid.replacingOccurrences(
                    of: "jobs:\n  build:",
                    with: "defaults:\n  run:\n    shell: \"/usr/bin/true {0}\"\njobs:\n  build:"
                )
            ),
            (
                "job PATH replaces verifier tools",
                valid.replacingOccurrences(
                    of: "  build:\n    steps:",
                    with: "  build:\n    env:\n      PATH: /tmp/forged-bin\n    steps:"
                )
            ),
            (
                "publication provenance step uses custom shell",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.provenanceMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.provenanceMarker)\n        shell: \"/usr/bin/true {0}\""
                )
            ),
            (
                "step replaces trusted verifier after build",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: Replace trusted verifier\n        run: cp /usr/bin/true trusted-verifier-src/.build/release/trusted-verifier\n      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)"
                )
            ),
            (
                "nameless step replaces candidate after qualification",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.provenanceMarker)",
                    with: "      - run: cp /tmp/forged LogicProMCP\n      - name: \(ProductionReadinessContractEvaluator.provenanceMarker)"
                )
            ),
            (
                "step replaces evidence after provenance",
                valid.replacingOccurrences(
                    of: "      - name: Create GitHub Release",
                    with: "      - name: Replace verified evidence\n        run: cp /tmp/forged-attestation qualification-evidence/release-qualification-attestation.json\n      - name: Create GitHub Release"
                )
            ),
            (
                "publication runs even after gate failure",
                valid.replacingOccurrences(
                    of: "      - name: Create GitHub Release",
                    with: "      - name: Create GitHub Release\n        if: ${{ always() }}"
                )
            ),
            (
                "gate scripts use folded YAML scalars",
                valid.replacingOccurrences(of: "        run: |", with: "        run: >")
            ),
            (
                "qualification shell key uses a YAML escape",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)",
                    with: "      - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)\n        \"sh\\u0065ll\": \"/usr/bin/true {0}\""
                )
            ),
            (
                "job environment key uses a YAML escape",
                valid.replacingOccurrences(
                    of: "  build:\n    steps:",
                    with: "  build:\n    \"\\u0065nv\":\n      PATH: /tmp/forged-bin\n    steps:"
                )
            ),
            (
                "qualification environment uses an explicit PATH key",
                valid.replacingOccurrences(
                    of: "          TRUSTED_QUALIFICATION_PUBLIC_KEY: ${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}",
                    with: "          TRUSTED_QUALIFICATION_PUBLIC_KEY: ${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}\n          ? PATH\n          : /tmp/forged-bin"
                )
            ),
            (
                "standalone nameless step replaces candidate after qualification",
                valid.replacingOccurrences(
                    of: "      - name: \(ProductionReadinessContractEvaluator.provenanceMarker)",
                    with: "      -\n        run: cp /tmp/forged LogicProMCP\n      - name: \(ProductionReadinessContractEvaluator.provenanceMarker)"
                )
            ),
            (
                "publication marker is a decoy before a renamed publisher",
                valid.replacingOccurrences(
                    of: "      - name: Create GitHub Release\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191",
                    with: "      - name: Create GitHub Release\n        run: true\n      - name: Publish GitHub Release\n        if: ${{ always() }}\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191"
                )
            ),
            (
                "second publisher runs after a skipped publication marker",
                valid.replacingOccurrences(
                    of: "      - name: Create GitHub Release\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191",
                    with: "      - name: Create GitHub Release\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191\n      - name: Publish again after gate failure\n        if: ${{ always() }}\n        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191"
                )
            ),
            (
                "skipped decoy release job precedes an unguarded publisher job",
                valid.replacingOccurrences(
                    of: "  build:\n    steps:",
                    with: "  build:\n    if: ${{ false }}\n    steps:"
                ) + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish after skipped decoy
                        if: ${{ always() }}
                        uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191
                """
            ),
            (
                "alternate release action publishes from another job",
                valid + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish through alternate action ref
                        if: ${{ always() }}
                        uses: softprops/action-gh-release@v2
                """
            ),
            (
                "quoted alternate release action publishes from another job",
                valid + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish through quoted action ref
                        if: ${{ always() }}
                        uses: "softprops/action-gh-release@v2"
                """
            ),
            (
                "quoted commented release action publishes from another job",
                valid + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish through commented action ref
                        if: ${{ always() }}
                        uses: "softprops/action-gh-release@v2" # alternate publisher
                """
            ),
            (
                "escaped release action value publishes from another job",
                valid + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish through escaped action value
                        if: ${{ always() }}
                        uses: "softprops/action-gh-release@\\u0076\\u0032"
                """
            ),
            (
                "folded release action value publishes from another job",
                valid + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish through folded action value
                        if: ${{ always() }}
                        uses: >-
                          softprops/action-gh-release@v2
                """
            ),
            (
                "escaped uses key hides an alternate release action",
                valid + """

                  bypass-publish:
                    runs-on: macos-15
                    permissions:
                      contents: write
                    steps:
                      - name: Publish through escaped action key
                        if: ${{ always() }}
                        "\\u0075ses": softprops/action-gh-release@v2
                """
            ),
            (
                "verifier build command hides substitution after embedded hash",
                valid.replacingOccurrences(
                    of: "        run: swift build -c release --product trusted-verifier",
                    with: "        run: swift build -c release --product trusted-verifier# || true; mkdir -p .build/release; cp /usr/bin/true .build/release/trusted-verifier"
                )
            ),
        ]

        let validReport = ProductionReadinessContractEvaluator.evaluate(
            releaseWorkflowYAML: valid,
            registeredOperationIDs: ["system.health"],
            semanticValidatorOperationIDs: ["system.health"],
            requiredMatrixAxisCount: QualificationAxis.requiredCombinations.count,
            debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
            expectedAuthorityBaseSHA: expectedBaseSHA,
            publishedReleaseEvidencePresent: true,
            mutationRestoreCompensationEvidencePresent: true,
            independentProvenanceEnforced: true
        )
        #expect(!validReport.openDebts.contains(.releaseWorkflowMissingIndependentQualification))
        #expect(!validReport.openDebts.contains(.independentProvenanceNotEnforced))
        #expect(mutations.allSatisfy { $0.1 != valid }, "every execution override must mutate the valid workflow")

        for (name, yaml) in mutations {
            let report = ProductionReadinessContractEvaluator.evaluate(
                releaseWorkflowYAML: yaml,
                registeredOperationIDs: ["system.health"],
                semanticValidatorOperationIDs: ["system.health"],
                requiredMatrixAxisCount: QualificationAxis.requiredCombinations.count,
                debtBoardMarkdown: "Exact base: \(expectedBaseSHA)",
                expectedAuthorityBaseSHA: expectedBaseSHA,
                publishedReleaseEvidencePresent: true,
                mutationRestoreCompensationEvidencePresent: true,
                independentProvenanceEnforced: true
            )

            #expect(
                report.openDebts.contains(.releaseWorkflowMissingIndependentQualification),
                "\(name) must fail R-REL closed"
            )
            #expect(
                report.openDebts.contains(.independentProvenanceNotEnforced),
                "\(name) must fail R-PROV closed"
            )
        }
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
        jobs:
          build:
            steps:
              - name: Checkout pinned trusted verifier
                uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
                with:
                  ref: \(trustedVerifierCommitSHA)
                  path: trusted-verifier-src
              - name: Build pinned trusted verifier
                working-directory: trusted-verifier-src
                run: swift build -c release --product trusted-verifier
              - name: \(ProductionReadinessContractEvaluator.independentQualificationStepMarker)
                env:
                  QUALIFICATION_EVIDENCE_URL: ${{ secrets.QUALIFICATION_EVIDENCE_URL }}
                  QUALIFICATION_EVIDENCE_SHA256: ${{ secrets.QUALIFICATION_EVIDENCE_SHA256 }}
                  TRUSTED_QUALIFICATION_PUBLIC_KEY: ${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}
                run: |
                  echo "managed-fixture-matrix"
                  echo "required-matrix-axes:4"
                  test -n "$QUALIFICATION_EVIDENCE_URL"
                  test -n "$QUALIFICATION_EVIDENCE_SHA256"
                  test -n "$TRUSTED_QUALIFICATION_PUBLIC_KEY"
                  curl --fail --location --silent --show-error \\
                    "$QUALIFICATION_EVIDENCE_URL" --output qualification-evidence.zip
                  echo "$QUALIFICATION_EVIDENCE_SHA256  qualification-evidence.zip" | shasum -a 256 --check
                  mkdir qualification-evidence
                  ditto -x -k qualification-evidence.zip qualification-evidence
                  LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY="$TRUSTED_QUALIFICATION_PUBLIC_KEY" \\
                    trusted-verifier-src/.build/release/trusted-verifier verify \\
                      --candidate LogicProMCP \\
                      --bundle qualification-evidence \\
                      --release-version "${GITHUB_REF_NAME#v}" \\
                      --expected-commit "$GITHUB_SHA"
              - name: \(ProductionReadinessContractEvaluator.provenanceMarker)
                env:
                  TRUSTED_QUALIFICATION_PUBLIC_KEY: ${{ secrets.TRUSTED_QUALIFICATION_PUBLIC_KEY }}
                run: |
                  test -f qualification-evidence/evidence-manifest.json
                  test -n "$TRUSTED_QUALIFICATION_PUBLIC_KEY"
              - name: Create GitHub Release
                uses: softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191
        """
    }
}
