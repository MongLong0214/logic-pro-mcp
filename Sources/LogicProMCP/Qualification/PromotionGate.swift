enum PromotionRejectionReason: Equatable, Sendable {
    case requiredCaseFailed(caseID: String)
    case requiredCombinationNotQualified(key: String)
    case missingArtifact(name: String)
    case binarySHAMismatch(expected: String, actual: String)
    case expiredWaiver(caseID: String)
    case waiverForUnknownCase(caseID: String)
    case waiverForPassingCase(caseID: String)
    case waiverForNonWaivedCase(caseID: String, status: QualificationStatus)
    case waivedCaseMissingWaiver(caseID: String)
    case invalidWaiver(caseID: String, field: String)
    case duplicateWaiver(caseID: String)
    case duplicateCaseID(caseID: String)
    case releaseVersionMismatch(expected: String, actual: String)
}

struct PromotionDecision: Equatable, Sendable {
    let promotable: Bool
    let rejections: [PromotionRejectionReason]
}

struct PromotionGate {
    func evaluate(
        attestation: ReleaseQualificationAttestation,
        releaseVersion: String,
        expectedBinarySHA256: String,
        presentArtifacts: Set<String>,
        requiredArtifacts: Set<String>
    ) -> PromotionDecision {
        var rejections: [PromotionRejectionReason] = []

        if SemanticVersion(attestation.serverVersion) == nil
            || SemanticVersion(releaseVersion) == nil
            || attestation.serverVersion != releaseVersion {
            rejections.append(.releaseVersionMismatch(
                expected: releaseVersion,
                actual: attestation.serverVersion
            ))
        }
        if !Self.isSHA256(attestation.binarySHA256)
            || !Self.isSHA256(expectedBinarySHA256)
            || attestation.binarySHA256 != expectedBinarySHA256 {
            rejections.append(.binarySHAMismatch(
                expected: expectedBinarySHA256,
                actual: attestation.binarySHA256
            ))
        }
        for artifact in requiredArtifacts.subtracting(presentArtifacts).sorted() {
            rejections.append(.missingArtifact(name: artifact))
        }
        let casesByID = Dictionary(grouping: attestation.cases, by: \.id)
        let duplicateCaseIDs = Set(casesByID.compactMap { caseID, cases in
            cases.count > 1 ? caseID : nil
        })
        for caseID in duplicateCaseIDs.sorted() {
            rejections.append(.duplicateCaseID(caseID: caseID))
        }
        let waiverIssues = QualificationWaiverValidator.issues(in: attestation.waivers)
        var invalidWaiverCaseIDs: Set<String> = []
        for issue in waiverIssues {
            switch issue {
            case .invalidField(let caseID, let field):
                invalidWaiverCaseIDs.insert(caseID)
                rejections.append(.invalidWaiver(caseID: caseID, field: field))
            case .duplicateCaseID(let caseID):
                invalidWaiverCaseIDs.insert(caseID)
                rejections.append(.duplicateWaiver(caseID: caseID))
            }
        }
        let waiverCaseIDs = Set(attestation.waivers.map(\.caseID))
        for caseID in Set(attestation.cases.compactMap {
            $0.status == .waived && !waiverCaseIDs.contains($0.id) ? $0.id : nil
        }).sorted() {
            rejections.append(.waivedCaseMissingWaiver(caseID: caseID))
        }
        for waiver in attestation.waivers {
            guard let matchingCases = casesByID[waiver.caseID] else {
                rejections.append(.waiverForUnknownCase(caseID: waiver.caseID))
                continue
            }
            if matchingCases.contains(where: { $0.status == .passed }) {
                rejections.append(.waiverForPassingCase(caseID: waiver.caseID))
            } else if let nonWaived = matchingCases.first(where: { $0.status != .waived }) {
                rejections.append(.waiverForNonWaivedCase(
                    caseID: waiver.caseID,
                    status: nonWaived.status
                ))
            }
        }
        let expiredWaiverIDs = Set(attestation.waivers.compactMap { waiver in
            Self.isExpired(waiver.expiryVersion, at: releaseVersion) ? waiver.caseID : nil
        })
        for caseID in expiredWaiverIDs.sorted() {
            rejections.append(.expiredWaiver(caseID: caseID))
        }
        let hasLiveQualifiedAxis = attestation.cases.contains { qualificationCase in
            qualificationCase.status == .passed
                && qualificationCase.verified
                && !qualificationCase.evidenceFiles.isEmpty
                && QualificationAxis.requiredCombinations.contains { axis in
                    Self.matchesRequiredAxis(caseID: qualificationCase.id, axis: axis)
                }
        }
        let qualifyingAxisWaiverCaseIDs = hasLiveQualifiedAxis
            ? Set(attestation.waivers.compactMap { waiver -> String? in
                guard waiver.governsHostAxisAvailability,
                      !invalidWaiverCaseIDs.contains(waiver.caseID),
                      !expiredWaiverIDs.contains(waiver.caseID) else {
                    return nil
                }
                return waiver.caseID
            })
            : []
        for axis in QualificationAxis.requiredCombinations {
            let matchingCases = attestation.cases.filter {
                Self.matchesRequiredAxis(caseID: $0.id, axis: axis)
            }
            let failedCaseID = matchingCases
                .filter { $0.status == .failed }
                .map(\.id)
                .sorted()
                .first
            if let failedCaseID {
                rejections.append(.requiredCaseFailed(caseID: failedCaseID))
            } else if matchingCases.contains(where: { duplicateCaseIDs.contains($0.id) }) {
                continue
            } else if !matchingCases.contains(where: { qualificationCase in
                (qualificationCase.status == .passed
                    && qualificationCase.verified
                    && !qualificationCase.evidenceFiles.isEmpty)
                    || (qualificationCase.status == .waived
                        && qualifyingAxisWaiverCaseIDs.contains(qualificationCase.id))
            }) {
                rejections.append(.requiredCombinationNotQualified(key: axis.key))
            }
        }

        return PromotionDecision(
            promotable: rejections.isEmpty,
            rejections: rejections
        )
    }

    private static func isExpired(_ expiryVersion: String, at releaseVersion: String) -> Bool {
        guard let expiry = SemanticVersion(expiryVersion),
              let release = SemanticVersion(releaseVersion) else {
            return true
        }
        return expiry <= release
    }

    private static func matchesRequiredAxis(
        caseID: String,
        axis: QualificationAxis
    ) -> Bool {
        caseID == axis.key || ProjectFixture.allCases.contains {
            caseID == "\(axis.key)/\($0.rawValue)"
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        var value = rawValue
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
