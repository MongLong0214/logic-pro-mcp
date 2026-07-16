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
    static let trustedVerifierCommitSHA = "67fec5fccf817f9978022f0ca262b80a789e2dce"

    private static func blockingStep(
        named name: String,
        in workflow: String
    ) -> (body: String, index: Int, endIndex: Int, jobEndIndex: Int)? {
        let step = "- name: \(name)"
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
        guard !structuralIndices.contains(where: {
            hasAmbiguousYAMLKey(in: lines[$0])
        }) else { return nil }
        let releaseIndices = structuralIndices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == releaseStep
        }
        let usesValues = structuralIndices.compactMap { index -> String? in
            guard let entry = yamlKeyValue(in: lines[index]), entry.key == "uses" else {
                return nil
            }
            return entry.value
        }
        let ambiguousUsesValue = usesValues.contains { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.contains("\\")
                || trimmed.hasPrefix("|")
                || trimmed.hasPrefix(">")
                || trimmed.hasPrefix("!")
                || trimmed.hasPrefix("&")
                || trimmed.hasPrefix("*")
        }
        let publisherCount = usesValues.filter {
            $0.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .contains("softprops/action-gh-release@")
        }.count
        guard releaseIndices.count == 1,
              publisherCount == 1,
              !ambiguousUsesValue,
              let releaseIndex = releaseIndices.first else {
            return nil
        }
        let stepIndentation = lines[releaseIndex].prefix { $0 == " " }.count
        let stepsStartIndex = structuralIndices.last(where: {
            $0 < releaseIndex && lines[$0].prefix { $0 == " " }.count < stepIndentation
        }) ?? lines.startIndex
        let stepsIndentation = lines[stepsStartIndex].prefix { $0 == " " }.count
        let jobStartIndex = structuralIndices.last(where: {
            $0 < stepsStartIndex && lines[$0].prefix { $0 == " " }.count < stepsIndentation
        }) ?? lines.startIndex
        let jobIndentation = lines[jobStartIndex].prefix { $0 == " " }.count
        let jobEndIndex = structuralIndices.first(where: {
            $0 > jobStartIndex && lines[$0].prefix { $0 == " " }.count <= jobIndentation
        }) ?? lines.endIndex
        let inheritedOverride = structuralIndices.contains { index in
            let indentation = lines[index].prefix { $0 == " " }.count
            let isInheritedScope = indentation == 0
                || (index > jobStartIndex
                    && index < jobEndIndex
                    && indentation == jobIndentation + 2)
            guard isInheritedScope else { return false }
            if hasAmbiguousYAMLKey(in: lines[index]) { return true }
            guard let key = yamlKeyValue(in: lines[index])?.key else { return false }
            return key == "defaults"
                || key == "env"
                || (indentation == jobIndentation + 2 && key == "if")
        }
        guard !inheritedOverride else { return nil }
        let startIndex: Int
        if step == releaseStep {
            startIndex = releaseIndex
        } else {
            guard let gateIndex = structuralIndices.first(where: {
                $0 > stepsStartIndex && $0 < releaseIndex
                    && lines[$0].prefix { $0 == " " }.count == stepIndentation
                    && lines[$0].trimmingCharacters(in: .whitespaces) == step
            }) else { return nil }
            startIndex = gateIndex
        }
        let endIndex = structuralIndices.first(where: { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return index > startIndex && index < jobEndIndex
                && lines[index].prefix { $0 == " " }.count == stepIndentation
                && (line == "-" || line.hasPrefix("- "))
        }) ?? jobEndIndex
        let body = lines[startIndex..<endIndex].joined(separator: "\n")
        guard stepScalar("continue-on-error", in: body) == nil,
              stepScalar("if", in: body) == nil,
              stepScalar("shell", in: body) == nil,
              !hasAmbiguousStepKey(in: body) else {
            return nil
        }
        return (body, startIndex, endIndex, jobEndIndex)
    }

    private static func pinnedTrustedVerifierStep(in workflow: String) -> String? {
        guard let checkout = blockingStep(named: "Checkout pinned trusted verifier", in: workflow),
              let build = blockingStep(named: "Build pinned trusted verifier", in: workflow),
              let qualification = blockingStep(named: independentQualificationStepMarker, in: workflow),
              let provenance = blockingStep(named: provenanceMarker, in: workflow),
              let publication = blockingStep(named: "Create GitHub Release", in: workflow),
              checkout.endIndex == build.index,
              build.endIndex == qualification.index,
              qualification.endIndex == provenance.index,
              provenance.endIndex == publication.index,
              publication.endIndex == publication.jobEndIndex else {
            return nil
        }
        guard let qualificationScript = stepBlockScalar("run", in: qualification.body),
              let provenanceScript = stepBlockScalar("run", in: provenance.body) else {
            return nil
        }
        let qualificationLines = qualificationScript.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let expectedQualificationLines = [
            "echo \"managed-fixture-matrix\"",
            "echo \"required-matrix-axes:4\"",
            "test -n \"$QUALIFICATION_EVIDENCE_URL\"",
            "test -n \"$QUALIFICATION_EVIDENCE_SHA256\"",
            "test -n \"$TRUSTED_QUALIFICATION_PUBLIC_KEY\"",
            "curl --fail --location --silent --show-error \\",
            "\"$QUALIFICATION_EVIDENCE_URL\" --output qualification-evidence.zip",
            "echo \"$QUALIFICATION_EVIDENCE_SHA256  qualification-evidence.zip\" | shasum -a 256 --check",
            "mkdir qualification-evidence",
            "ditto -x -k qualification-evidence.zip qualification-evidence",
            "LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=\"$TRUSTED_QUALIFICATION_PUBLIC_KEY\" \\",
            "trusted-verifier-src/.build/release/trusted-verifier verify \\",
            "--candidate LogicProMCP \\",
            "--bundle qualification-evidence \\",
            "--release-version \"${GITHUB_REF_NAME#v}\" \\",
            "--expected-commit \"$GITHUB_SHA\"",
        ]
        let expectedQualificationEnvironment = [
            "QUALIFICATION_EVIDENCE_URL": "${{secrets.qualification_evidence_url}}",
            "QUALIFICATION_EVIDENCE_SHA256": "${{secrets.qualification_evidence_sha256}}",
            "TRUSTED_QUALIFICATION_PUBLIC_KEY": "${{secrets.trusted_qualification_public_key}}",
        ]
        let provenanceLines = provenanceScript.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard stepScalar("uses", in: checkout.body) == "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683",
              nestedStepScalar("ref", under: "with", in: checkout.body) == trustedVerifierCommitSHA,
              nestedStepScalar("path", under: "with", in: checkout.body) == "trusted-verifier-src",
              stepMapping("env", in: checkout.body) == nil,
              stepScalar("working-directory", in: build.body) == "trusted-verifier-src",
              stepScalar("run", in: build.body) == "swiftbuild-crelease--producttrusted-verifier",
              stepMapping("env", in: build.body) == nil,
              stepScalar("working-directory", in: qualification.body) == nil,
              stepMapping("env", in: qualification.body) == expectedQualificationEnvironment,
              qualificationLines == expectedQualificationLines,
              stepScalar("working-directory", in: provenance.body) == nil,
              stepMapping("env", in: provenance.body) == [
                  "TRUSTED_QUALIFICATION_PUBLIC_KEY": "${{secrets.trusted_qualification_public_key}}",
              ],
              provenanceLines == [
                  "test -f qualification-evidence/evidence-manifest.json",
                  "test -n \"$TRUSTED_QUALIFICATION_PUBLIC_KEY\"",
              ],
              stepScalar("uses", in: publication.body) == "softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191",
              stepScalar("working-directory", in: publication.body) == nil,
              stepMapping("env", in: publication.body) == nil else {
            return nil
        }
        return qualification.body
    }

    private static func nestedStepScalar(
        _ key: String,
        under parent: String,
        in step: String
    ) -> String? {
        stepMapping(parent, in: step)?[key]
    }

    private static func stepMapping(_ parent: String, in step: String) -> [String: String]? {
        let lines = step.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parentIndentation = first.prefix { $0 == " " }.count + 2
        guard let parentIndex = lines.dropFirst().firstIndex(where: {
            $0.prefix { $0 == " " }.count == parentIndentation
                && yamlKeyValue(in: $0)?.key == parent
        }), let parentEntry = yamlKeyValue(in: lines[parentIndex]) else {
            return nil
        }
        guard parentEntry.value.isEmpty else { return [:] }
        let body = lines[lines.index(after: parentIndex)...].prefix { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                || line.prefix { $0 == " " }.count > parentIndentation
        }
        var values: [String: String] = [:]
        for line in body {
            guard line.prefix(while: { $0 == " " }).count == parentIndentation + 2 else {
                continue
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard !hasAmbiguousYAMLKey(in: line),
                  let entry = yamlKeyValue(in: line),
                  values[entry.key] == nil else { return [:] }
            values[entry.key] = normalizedScalar(entry.value)
        }
        return values
    }

    private static func stepBlockScalar(_ key: String, in step: String) -> String? {
        let lines = step.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let indentation = first.prefix { $0 == " " }.count + 2
        let prefix = String(repeating: " ", count: indentation) + "\(key): |"
        guard let startIndex = lines.dropFirst().firstIndex(where: { String($0) == prefix }) else {
            return nil
        }
        let body = lines[lines.index(after: startIndex)...].prefix { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                || line.prefix { $0 == " " }.count > indentation
        }
        guard !body.isEmpty else { return nil }
        return body.joined(separator: "\n")
    }

    private static func stepScalar(_ key: String, in step: String) -> String? {
        let lines = step.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let indentation = first.prefix { $0 == " " }.count + 2
        return lines.dropFirst().first(where: {
            $0.prefix { $0 == " " }.count == indentation
                && yamlKeyValue(in: $0)?.key == key
        }).flatMap { line in
            yamlKeyValue(in: line).map { normalizedScalar($0.value) }
        }
    }

    private static func hasAmbiguousStepKey(in step: String) -> Bool {
        let lines = step.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return true }
        let indentation = first.prefix { $0 == " " }.count + 2
        return lines.dropFirst().contains { line in
            guard line.prefix(while: { $0 == " " }).count == indentation else { return false }
            return hasAmbiguousYAMLKey(in: line)
        }
    }

    private static func hasAmbiguousYAMLKey(in line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        if trimmed.hasPrefix("?") || trimmed.hasPrefix(":") { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let rawKey = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        return rawKey.contains("\\")
            || rawKey == "<<"
            || rawKey.hasPrefix("*")
            || rawKey.hasPrefix("&")
            || rawKey.hasPrefix("!")
    }

    private static func yamlKeyValue(in line: Substring) -> (key: String, value: String)? {
        let uncommented = line.trimmingCharacters(in: .whitespaces)
        guard !uncommented.isEmpty,
              !uncommented.hasPrefix("#"),
              let colon = uncommented.firstIndex(of: ":") else {
            return nil
        }
        var key = uncommented[..<colon].trimmingCharacters(in: .whitespaces)
        if key.count >= 2,
           (key.first == "\"" && key.last == "\"" || key.first == "'" && key.last == "'") {
            key.removeFirst()
            key.removeLast()
        }
        guard !key.isEmpty else { return nil }
        let value = uncommented[uncommented.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, value)
    }

    private static func normalizedScalar(_ value: String) -> String {
        var normalized = value.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized.count >= 2,
           (normalized.first == "\"" && normalized.last == "\""
            || normalized.first == "'" && normalized.last == "'") {
            normalized.removeFirst()
            normalized.removeLast()
        }
        return normalized
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
        let qualificationStep = pinnedTrustedVerifierStep(in: releaseWorkflowYAML)
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
            || qualificationStep?.contains("--bundle qualification-evidence") != true {
            findings.append(.init(
                id: .managedFixtureMatrixUnbound,
                detail: "release path does not bind managed-fixture matrix (\(QualificationAxis.requiredCombinations.count) axes)"
            ))
        }

        // R-MUT: mutation/readback/restore/compensation evidence must be required by release path.
        if !mutationRestoreCompensationEvidencePresent && qualificationStep == nil {
            findings.append(.init(
                id: .mutationRestoreCompensationMissing,
                detail: "no mutation/readback/restore/compensation evidence requirement in release path"
            ))
        }

        // R-PROV: independent provenance verification (not candidate self-sign only).
        if qualificationStep == nil
            || (!independentProvenanceEnforced
                && qualificationStep?.contains("LOGIC_PRO_MCP_QUALIFICATION_TRUSTED_PUBLIC_KEY=\"$TRUSTED_QUALIFICATION_PUBLIC_KEY\"") != true) {
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
