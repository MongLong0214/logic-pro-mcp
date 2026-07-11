enum PromotionRejectionReason: Equatable, Sendable {
    case requiredCaseFailed(caseID: String)
    case requiredCombinationNotQualified(key: String)
    case missingArtifact(name: String)
    case binarySHAMismatch(expected: String, actual: String)
    case expiredWaiver(caseID: String)
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
        let expiredWaiverIDs = Set(attestation.waivers.compactMap { waiver in
            Self.isExpired(waiver.expiryVersion, at: releaseVersion) ? waiver.caseID : nil
        })
        for caseID in expiredWaiverIDs.sorted() {
            rejections.append(.expiredWaiver(caseID: caseID))
        }
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
            } else if Set(matchingCases.map(\.id)).count != matchingCases.count {
                rejections.append(.requiredCombinationNotQualified(key: axis.key))
            } else if !matchingCases.contains(where: {
                $0.status == .passed && $0.verified && !$0.evidenceFiles.isEmpty
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

private struct SemanticVersion: Comparable {
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
