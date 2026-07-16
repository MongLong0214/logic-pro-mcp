import Foundation

/// LPMCP-PRD-001 production-readiness debt contracts for #367 residual remediation.
/// Each ID maps 1:1 to the cold-start RED catalog (R-REL … R-AUTH).
enum LPMCPPRD001DebtID: String, CaseIterable, Sendable, Comparable {
    case releaseWorkflowMissingIndependentQualification = "R-REL"
    case semanticCoverageIncomplete = "R-SEM"
    case managedFixtureMatrixUnbound = "R-MATRIX"
    case mutationRestoreCompensationMissing = "R-MUT"
    case independentProvenanceNotEnforced = "R-PROV"
    case publishedImmutableEvidenceMissing = "R-PUB"
    case authorityBaseSHAUnbound = "R-AUTH"

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProductionReadinessDebtFinding: Equatable, Sendable {
    let id: LPMCPPRD001DebtID
    let detail: String
}

struct ProductionReadinessContractReport: Equatable, Sendable {
    let findings: [ProductionReadinessDebtFinding]
    let registeredOperationCount: Int
    let semanticValidatorOperationCount: Int
    let requiredMatrixAxisCount: Int

    var openDebts: [LPMCPPRD001DebtID] {
        Array(Set(findings.map(\.id))).sorted()
    }

    var satisfied: Bool { findings.isEmpty }

    var allSevenDebtsOpen: Bool {
        Set(openDebts) == Set(LPMCPPRD001DebtID.allCases)
    }
}

/// Deterministic evaluator for repository-level production-readiness contracts.
/// Does not claim live Logic PASS; it encodes what must be true before promotion.
enum ProductionReadinessContractEvaluator {
    static let debtBoardRelativePath = "docs/tickets/lpmcp-prd-001/STATUS.md"
    static let releaseWorkflowRelativePath = ".github/workflows/release.yml"
    static let waiversRelativePath = ".github/qualification/waivers.json"
    static let publishedEvidenceMarker = "release-qualification-attestation"
    static let independentQualificationStepMarker = "Enforce independent exact-artifact qualification"
    static let mutationEvidenceMarker = "mutation-restore-compensation"
    static let provenanceMarker = "trusted-provenance-verify"
    static let promotionVerificationMarker = "--verify-promotion"

    private static func independentQualificationStep(in workflow: String) -> String? {
        let step = "- name: \(independentQualificationStepMarker)"
        let releaseStep = "- name: Create GitHub Release"
        let lines = workflow.split(separator: "\n", omittingEmptySubsequences: false)
        var structuralIndices: [Int] = []
        var blockScalarIndentation: Int?
        for index in lines.indices {
            let line = lines[index]
            let indentation = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let scalarIndentation = blockScalarIndentation {
                if indentation > scalarIndentation { continue }
                blockScalarIndentation = nil
            }
            structuralIndices.append(index)
            let uncommented = trimmed.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0].trimmingCharacters(in: .whitespaces)
            if let colon = uncommented.firstIndex(of: ":") {
                let value = uncommented[uncommented.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if value.first == "|" || value.first == ">" {
                    blockScalarIndentation = indentation
                }
            }
        }
        guard let releaseIndex = structuralIndices.first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == releaseStep
        }) else { return nil }
        let stepIndentation = lines[releaseIndex].prefix { $0 == " " }.count
        guard let startIndex = structuralIndices.first(where: {
            $0 < releaseIndex
                && lines[$0].prefix { $0 == " " }.count == stepIndentation
                && lines[$0].trimmingCharacters(in: .whitespaces) == step
        }) else { return nil }
        let endIndex = structuralIndices.first(where: {
            $0 > startIndex && $0 < releaseIndex
                && lines[$0].prefix { $0 == " " }.count == stepIndentation
                && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("- name:")
        }) ?? releaseIndex
        let body = lines[startIndex..<endIndex].joined(separator: "\n")
        guard stepScalar("continue-on-error", in: body).map(isTruthyConstant) != true,
              stepScalar("if", in: body).map(isFalseConstant) != true else {
            return nil
        }
        return body
    }

    private static func stepScalar(_ key: String, in step: String) -> String? {
        let lines = step.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let indentation = first.prefix { $0 == " " }.count + 2
        let prefix = String(repeating: " ", count: indentation) + "\(key):"
        return lines.dropFirst().first { $0.hasPrefix(prefix) }.map {
            $0.dropFirst(prefix.count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
        }
    }

    private static func isTruthyConstant(_ value: String) -> Bool {
        ["true", "yes", "on", "1", "${{true}}"].contains(value)
    }

    private static func isFalseConstant(_ value: String) -> Bool {
        ["false", "0", "${{false}}", "${{0}}"].contains(value)
    }

    /// Operations for which a semantic readback validator is implemented.
    static func operationsWithSemanticValidators(
        ids: [OperationID] = OperationID.allCases
    ) -> [OperationID] {
        ids.filter { id in
            // Probe validator availability without payloads: nil means unimplemented.
            QualificationSemanticReadbackValidator.validate(
                operationID: id.rawValue,
                responseData: Data("{}".utf8),
                readbackData: Data("{}".utf8)
            ) != nil
        }
    }

    static func evaluate(
        releaseWorkflowYAML: String,
        registeredOperationIDs: [String],
        semanticValidatorOperationIDs: [String],
        requiredMatrixAxisCount: Int,
        debtBoardMarkdown: String?,
        expectedAuthorityBaseSHA: String?,
        publishedReleaseEvidencePresent: Bool,
        mutationRestoreCompensationEvidencePresent: Bool,
        independentProvenanceEnforced: Bool,
        governedWaivers: [QualificationWaiver] = []
    ) -> ProductionReadinessContractReport {
        var findings: [ProductionReadinessDebtFinding] = []

        // R-REL: release workflow must block promotion on independent exact-artifact qualification.
        let qualificationStep = independentQualificationStep(in: releaseWorkflowYAML)
        if qualificationStep == nil {
            findings.append(.init(
                id: .releaseWorkflowMissingIndependentQualification,
                detail: "release.yml lacks step '\(independentQualificationStepMarker)' before publication"
            ))
        }

        let registered = Set(registeredOperationIDs)
        let semantic = Set(semanticValidatorOperationIDs)
        let waiverIssues = QualificationWaiverValidator.issues(in: governedWaivers)
        if !waiverIssues.isEmpty {
            findings.append(.init(
                id: .semanticCoverageIncomplete,
                detail: "governed waiver inventory has \(waiverIssues.count) validation issue(s)"
            ))
        }
        let missingSemantic = registered.filter { operationID in
            guard !semantic.contains(operationID) else { return false }
            return !governedWaivers.contains { waiver in
                waiver.governsOperation(
                    caseID: "in-process/\(operationID)",
                    operationID: operationID
                )
                    && waiver.affectsDefaultProfile
                    && waiver.releaseNoteVisible
                    && QualificationWaiverReasonCode(rawValue: waiver.reasonCode) != nil
            }
        }.sorted()
        if !missingSemantic.isEmpty {
            findings.append(.init(
                id: .semanticCoverageIncomplete,
                detail: "semantic validators or release-gated governed waivers missing for \(missingSemantic.count)/\(registered.count) operations (e.g. \(missingSemantic.prefix(5).joined(separator: ", ")))"
            ))
        }

        // R-MATRIX: required Desktop/Creator × en/ko axis count must be enforced in workflow + evidence path.
        let axisMarker = "required-matrix-axes:\(requiredMatrixAxisCount)"
        if requiredMatrixAxisCount < QualificationAxis.requiredCombinations.count
            || qualificationStep?.contains(axisMarker) != true
            || qualificationStep?.contains("--attestation qualification-evidence/release-qualification-attestation.json") != true {
            findings.append(.init(
                id: .managedFixtureMatrixUnbound,
                detail: "release path does not bind managed-fixture matrix (\(QualificationAxis.requiredCombinations.count) axes)"
            ))
        }

        // R-MUT: mutation/readback/restore/compensation evidence must be required by release path.
        if !mutationRestoreCompensationEvidencePresent
            && qualificationStep?.contains("--required-artifacts raw-transcript.json,public-transcript.json,mutation-restore-compensation.json") != true {
            findings.append(.init(
                id: .mutationRestoreCompensationMissing,
                detail: "no mutation/readback/restore/compensation evidence requirement in release path"
            ))
        }

        // R-PROV: independent provenance verification (not candidate self-sign only).
        if !independentProvenanceEnforced
            && (qualificationStep?.contains("LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=\"$TRUSTED_QUALIFICATION_PUBLIC_KEY\"") != true
                || qualificationStep?.contains("test -n \"$TRUSTED_QUALIFICATION_PUBLIC_KEY\"") != true) {
            findings.append(.init(
                id: .independentProvenanceNotEnforced,
                detail: "release path does not enforce trusted independent provenance verification"
            ))
        }

        // R-PUB: immutable published qualification evidence must be a release asset.
        let releaseStep = releaseWorkflowYAML.split(separator: "- name: Create GitHub Release", maxSplits: 1).last.map(String.init) ?? ""
        if !publishedReleaseEvidencePresent
            && (!releaseStep.contains("qualification-evidence/release-qualification-attestation.json")
                || !releaseStep.contains("qualification-evidence/evidence-manifest.json")
                || !releaseStep.contains("qualification-evidence/public-transcript.json")
                || releaseStep.contains("qualification-evidence/raw-transcript.json")
                || !releaseStep.contains("qualification-evidence/mutation-restore-compensation.json")) {
            findings.append(.init(
                id: .publishedImmutableEvidenceMissing,
                detail: "release path does not publish \(publishedEvidenceMarker) evidence assets"
            ))
        }

        // R-AUTH: debt board must pin exact authority base SHA for this remediation.
        if let expectedAuthorityBaseSHA {
            let board = debtBoardMarkdown ?? ""
            if board.isEmpty {
                findings.append(.init(
                    id: .authorityBaseSHAUnbound,
                    detail: "missing \(debtBoardRelativePath); cannot bind exact base SHA"
                ))
            } else if !board.contains(expectedAuthorityBaseSHA) {
                findings.append(.init(
                    id: .authorityBaseSHAUnbound,
                    detail: "debt board does not pin exact base SHA \(expectedAuthorityBaseSHA)"
                ))
            }
        }

        return ProductionReadinessContractReport(
            findings: findings,
            registeredOperationCount: registered.count,
            semanticValidatorOperationCount: semantic.count,
            requiredMatrixAxisCount: requiredMatrixAxisCount
        )
    }

    /// Evaluate the checked-in repository tree at `root`.
    static func evaluateRepositoryRoot(
        _ root: URL,
        expectedAuthorityBaseSHA: String
    ) throws -> ProductionReadinessContractReport {
        let releaseURL = root.appendingPathComponent(releaseWorkflowRelativePath)
        let releaseYAML = try String(contentsOf: releaseURL, encoding: .utf8)
        let boardURL = root.appendingPathComponent(debtBoardRelativePath)
        let board = try? String(contentsOf: boardURL, encoding: .utf8)
        let waiversURL = root.appendingPathComponent(waiversRelativePath)
        let waivers = try JSONDecoder().decode(
            [QualificationWaiver].self,
            from: Data(contentsOf: waiversURL)
        )
        let registered = OperationRegistry.specs.map(\.id.rawValue)
        let semanticIDs = operationsWithSemanticValidators().map(\.rawValue)
        return evaluate(
            releaseWorkflowYAML: releaseYAML,
            registeredOperationIDs: registered,
            semanticValidatorOperationIDs: semanticIDs,
            requiredMatrixAxisCount: QualificationAxis.requiredCombinations.count,
            debtBoardMarkdown: board,
            expectedAuthorityBaseSHA: expectedAuthorityBaseSHA,
            publishedReleaseEvidencePresent: false,
            mutationRestoreCompensationEvidencePresent: false,
            independentProvenanceEnforced: false,
            governedWaivers: waivers
        )
    }
}
