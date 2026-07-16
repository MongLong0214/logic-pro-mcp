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
    static let uploadArtifactCommitSHA = "65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08"
    static let downloadArtifactCommitSHA = "d3f86a106a0bac45b974a628896c90dbdf5c8093"

    private static func structuralIndices(in lines: [Substring]) -> [Int]? {
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
        return structuralIndices.contains(where: {
            hasAmbiguousYAMLKey(in: lines[$0])
        }) ? nil : structuralIndices
    }

    private static func workflowJob(named name: String, in workflow: String) -> String? {
        let lines = workflow.split(separator: "\n", omittingEmptySubsequences: false)
        guard let structuralIndices = structuralIndices(in: lines),
              let jobsIndex = structuralIndices.first(where: {
                  lines[$0].prefix { $0 == " " }.isEmpty
                      && lines[$0].trimmingCharacters(in: .whitespaces) == "jobs:"
              }) else { return nil }
        let jobsEndIndex = structuralIndices.first(where: {
            $0 > jobsIndex && lines[$0].prefix { $0 == " " }.isEmpty
        }) ?? lines.endIndex
        let jobIndices = structuralIndices.filter {
            $0 > jobsIndex && $0 < jobsEndIndex
                && lines[$0].prefix { $0 == " " }.count == 2
                && lines[$0].trimmingCharacters(in: .whitespaces) == "\(name):"
        }
        guard jobIndices.count == 1, let startIndex = jobIndices.first else { return nil }
        let endIndex = structuralIndices.first(where: {
            $0 > startIndex && $0 < jobsEndIndex
                && lines[$0].prefix { $0 == " " }.count <= 2
        }) ?? jobsEndIndex
        return lines[startIndex..<endIndex].joined(separator: "\n")
    }

    private static func blockingStep(
        named name: String,
        in job: String
    ) -> (body: String, index: Int, endIndex: Int, jobEndIndex: Int, firstStepIndex: Int)? {
        let lines = job.split(separator: "\n", omittingEmptySubsequences: false)
        guard let structuralIndices = structuralIndices(in: lines),
              let first = lines.first else { return nil }
        let jobIndentation = first.prefix { $0 == " " }.count
        guard let stepsStartIndex = structuralIndices.first(where: {
            lines[$0].prefix { $0 == " " }.count == jobIndentation + 2
                && yamlKeyValue(in: lines[$0])?.key == "steps"
                && yamlKeyValue(in: lines[$0])?.value.isEmpty == true
        }) else { return nil }
        let stepIndentation = jobIndentation + 4
        guard let firstStepIndex = structuralIndices.first(where: { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return index > stepsStartIndex
                && lines[index].prefix { $0 == " " }.count == stepIndentation
                && (line == "-" || line.hasPrefix("- "))
        }) else { return nil }
        let step = "- name: \(name)"
        let matches = structuralIndices.filter {
            $0 > stepsStartIndex
                && lines[$0].prefix { $0 == " " }.count == stepIndentation
                && lines[$0].trimmingCharacters(in: .whitespaces) == step
        }
        guard matches.count == 1, let startIndex = matches.first else { return nil }
        let endIndex = structuralIndices.first(where: { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return index > startIndex
                && lines[index].prefix { $0 == " " }.count == stepIndentation
                && (line == "-" || line.hasPrefix("- "))
        }) ?? lines.endIndex
        let body = lines[startIndex..<endIndex].joined(separator: "\n")
        guard stepScalar("continue-on-error", in: body) == nil,
              stepScalar("if", in: body) == nil,
              stepScalar("shell", in: body) == nil,
              !hasAmbiguousStepKey(in: body) else {
            return nil
        }
        return (body, startIndex, endIndex, lines.endIndex, firstStepIndex)
    }

    private static func pinnedTrustedVerifierStep(in workflow: String) -> String? {
        let lines = workflow.split(separator: "\n", omittingEmptySubsequences: false)
        guard let structuralIndices = structuralIndices(in: lines),
              let buildJob = workflowJob(named: "build", in: workflow),
              let publishJob = workflowJob(named: "publish", in: workflow),
              stepMapping("permissions", in: buildJob) == ["contents": "read"],
              stepMapping("permissions", in: publishJob) == ["contents": "write"],
              stepScalar("needs", in: publishJob) == "build",
              stepScalar("if", in: buildJob) == nil,
              stepScalar("if", in: publishJob) == nil,
              stepScalar("defaults", in: buildJob) == nil,
              stepScalar("defaults", in: publishJob) == nil,
              stepScalar("env", in: buildJob) == nil,
              stepScalar("env", in: publishJob) == nil else { return nil }
        let usesValues = structuralIndices.compactMap { index -> String? in
            guard let entry = yamlKeyValue(in: lines[index]), entry.key == "uses" else {
                return nil
            }
            return entry.value
        }
        guard usesValues.filter({
            normalizedScalar($0).contains("softprops/action-gh-release@")
        }).count == 1,
        !usesValues.contains(where: {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.contains("\\") || ["|", ">", "!", "&", "*"].contains { value.hasPrefix($0) }
        }),
        structuralIndices.filter({ index in
            guard let entry = yamlKeyValue(in: lines[index]) else { return false }
            return entry.key == "contents" && normalizedScalar(entry.value) == "write"
        }).count == 1,
        !structuralIndices.contains(where: { index in
            guard lines[index].prefix(while: { $0 == " " }).isEmpty,
                  let key = yamlKeyValue(in: lines[index])?.key else { return false }
            return ["defaults", "env", "permissions"].contains(key)
        }),
        !structuralIndices.contains(where: { index in
            guard let entry = yamlKeyValue(in: lines[index]) else { return false }
            return entry.key == "permissions" && !entry.value.isEmpty
        }) else { return nil }

        guard let checkout = blockingStep(named: "Checkout pinned trusted verifier", in: buildJob),
              let verifierBuild = blockingStep(named: "Build pinned trusted verifier", in: buildJob),
              let qualification = blockingStep(named: independentQualificationStepMarker, in: buildJob),
              let provenance = blockingStep(named: provenanceMarker, in: buildJob),
              let manifest = blockingStep(named: "Create release artifact SHA256 manifest", in: buildJob),
              let upload = blockingStep(named: "Upload verified release artifacts", in: buildJob),
              checkout.endIndex == verifierBuild.index,
              verifierBuild.endIndex == qualification.index,
              qualification.endIndex == provenance.index,
              provenance.endIndex == manifest.index,
              manifest.endIndex == upload.index,
              upload.endIndex == upload.jobEndIndex else {
            return nil
        }
        guard let download = blockingStep(named: "Download verified release artifacts", in: publishJob),
              let publishCheckout = blockingStep(named: "Checkout pinned trusted verifier for publish", in: publishJob),
              let publishBuild = blockingStep(named: "Build pinned trusted verifier for publish", in: publishJob),
              let reverify = blockingStep(named: "Reverify downloaded release artifact", in: publishJob),
              let publication = blockingStep(named: "Create GitHub Release", in: publishJob),
              download.index == download.firstStepIndex,
              download.endIndex == publishCheckout.index,
              publishCheckout.endIndex == publishBuild.index,
              publishBuild.endIndex == reverify.index,
              reverify.endIndex == publication.index,
              publication.endIndex == publication.jobEndIndex else {
            return nil
        }
        guard let qualificationScript = stepBlockScalar("run", in: qualification.body),
              let provenanceScript = stepBlockScalar("run", in: provenance.body),
              let manifestScript = stepBlockScalar("run", in: manifest.body),
              let reverifyScript = stepBlockScalar("run", in: reverify.body) else { return nil }
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
        let artifactFiles = [
            "LogicProMCP",
            "LogicProMCP-macOS-universal.tar.gz",
            "LogicProMCP-macOS-arm64.tar.gz",
            "RELEASE-METADATA.json",
            "SHA256SUMS.txt",
            "qualification-evidence/release-qualification-attestation.json",
            "qualification-evidence/evidence-manifest.json",
            "qualification-evidence/case-manifest.json",
            "qualification-evidence/public-transcript.json",
            "qualification-evidence/mutation-restore-compensation.json",
        ]
        let expectedManifestLines = ["shasum -a 256 \\"]
            + artifactFiles.map { "\($0) \\" }
            + ["> release-artifacts.sha256"]
        let expectedReverifyLines = [
            "test -f release-artifacts.sha256",
            "shasum -a 256 --check release-artifacts.sha256",
            "test -n \"$TRUSTED_QUALIFICATION_PUBLIC_KEY\"",
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
        let manifestLines = manifestScript.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let reverifyLines = reverifyScript.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard stepScalar("uses", in: checkout.body) == "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683",
              nestedStepScalar("ref", under: "with", in: checkout.body) == trustedVerifierCommitSHA,
              nestedStepScalar("path", under: "with", in: checkout.body) == "trusted-verifier-src",
              stepMapping("env", in: checkout.body) == nil,
              stepScalar("working-directory", in: verifierBuild.body) == "trusted-verifier-src",
              stepScalar("run", in: verifierBuild.body) == "swiftbuild-crelease--producttrusted-verifier",
              stepMapping("env", in: verifierBuild.body) == nil,
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
              manifestLines == expectedManifestLines,
              stepScalar("uses", in: upload.body) == "actions/upload-artifact@\(uploadArtifactCommitSHA)",
              stepMapping("with", in: upload.body) == [
                  "name": "verified-release-artifacts",
                  "if-no-files-found": "error",
                  "path": "|",
              ],
              nestedStepBlockScalarLines("path", under: "with", in: upload.body) == artifactFiles + ["release-artifacts.sha256"],
              stepScalar("uses", in: download.body) == "actions/download-artifact@\(downloadArtifactCommitSHA)",
              stepMapping("with", in: download.body) == ["name": "verified-release-artifacts"],
              stepScalar("uses", in: publishCheckout.body) == "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683",
              nestedStepScalar("ref", under: "with", in: publishCheckout.body) == trustedVerifierCommitSHA,
              nestedStepScalar("path", under: "with", in: publishCheckout.body) == "trusted-verifier-src",
              stepMapping("env", in: publishCheckout.body) == nil,
              stepScalar("working-directory", in: publishBuild.body) == "trusted-verifier-src",
              stepScalar("run", in: publishBuild.body) == "swiftbuild-crelease--producttrusted-verifier",
              stepMapping("env", in: publishBuild.body) == nil,
              stepMapping("env", in: reverify.body) == [
                  "TRUSTED_QUALIFICATION_PUBLIC_KEY": "${{secrets.trusted_qualification_public_key}}",
              ],
              reverifyLines == expectedReverifyLines,
              stepScalar("uses", in: publication.body) == "softprops/action-gh-release@c062e08bd532815e2082a85e87e3ef29c3e6d191",
              nestedStepBlockScalarLines("files", under: "with", in: publication.body) == artifactFiles,
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

    private static func nestedStepBlockScalarLines(
        _ key: String,
        under parent: String,
        in step: String
    ) -> [String]? {
        let lines = step.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let parentIndentation = first.prefix { $0 == " " }.count + 2
        guard let parentIndex = lines.dropFirst().firstIndex(where: {
            $0.prefix { $0 == " " }.count == parentIndentation
                && yamlKeyValue(in: $0)?.key == parent
                && yamlKeyValue(in: $0)?.value.isEmpty == true
        }) else { return nil }
        let keyIndentation = parentIndentation + 2
        guard let keyIndex = lines[lines.index(after: parentIndex)...].firstIndex(where: {
            $0.prefix { $0 == " " }.count == keyIndentation
                && yamlKeyValue(in: $0)?.key == key
                && yamlKeyValue(in: $0)?.value == "|"
        }) else { return nil }
        return lines[lines.index(after: keyIndex)...]
            .prefix { line in
                line.trimmingCharacters(in: .whitespaces).isEmpty
                    || line.prefix { $0 == " " }.count > keyIndentation
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
