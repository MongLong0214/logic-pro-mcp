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
    case evidenceBindingMismatch(detail: String)
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
        for issue in waiverIssues {
            switch issue {
            case .invalidField(let caseID, let field):
                rejections.append(.invalidWaiver(caseID: caseID, field: field))
            case .duplicateCaseID(let caseID):
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
        let attestedAxis = QualificationAxis(
            variant: attestation.logicVariant,
            locale: attestation.locale,
            profile: attestation.profile,
            cache: attestation.cache,
            fixture: attestation.fixture
        )
        let attestedLiveCase = attestation.cases.first {
            Self.isLiveQualifiedCase(
                $0,
                axis: attestedAxis,
                binarySHA256: attestation.binarySHA256
            )
        }
        let liveAvailability = attestedLiveCase?.availabilityObservation
        for axis in QualificationAxis.requiredAxes(
            profile: attestation.profile,
            cache: attestation.cache,
            fixture: attestation.fixture
        ) {
            let matchingCases = attestation.cases.filter {
                $0.id == axis.key
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
                Self.isLiveQualifiedCase(
                    qualificationCase,
                    axis: axis,
                    binarySHA256: attestation.binarySHA256
                ) || (liveAvailability != nil && Self.isGovernedUnavailableCase(
                    qualificationCase,
                    axis: axis,
                    observedAxis: attestedAxis,
                    binarySHA256: attestation.binarySHA256,
                    liveAvailability: liveAvailability
                ))
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

    private static func isLiveQualifiedCase(
        _ qualificationCase: QualificationCase,
        axis: QualificationAxis,
        binarySHA256: String
    ) -> Bool {
        qualificationCase.id == axis.key
            && qualificationCase.axis == axis
            && qualificationCase.binarySHA256 == binarySHA256
            && qualificationCase.status == .passed
            && qualificationCase.verified
            && qualificationCase.verificationKind == .independentReadback
            && qualificationCase.deferral == nil
            && qualificationCase.availabilityReason == nil
            && qualificationCase.readback?.verified == true
            && qualificationCase.readback?.source == "logic://system/health"
            && qualificationCase.readback.map { Self.isSHA256($0.sha256) } == true
            && Self.isValidLiveObservation(
                qualificationCase.availabilityObservation,
                axis: axis
            )
            && !qualificationCase.evidenceFiles.isEmpty
    }

    private static func isGovernedUnavailableCase(
        _ qualificationCase: QualificationCase,
        axis: QualificationAxis,
        observedAxis: QualificationAxis,
        binarySHA256: String,
        liveAvailability: QualificationAvailabilityObservation?
    ) -> Bool {
        guard axis != observedAxis,
              let liveAvailability,
              qualificationCase.availabilityObservation == liveAvailability,
              Self.isValidLiveObservation(liveAvailability, axis: observedAxis),
              Self.provesUnavailable(axis: axis, observation: liveAvailability) else {
            return false
        }
        return qualificationCase.id == axis.key
            && qualificationCase.axis == axis
            && qualificationCase.binarySHA256 == binarySHA256
            && qualificationCase.status == .notQualified
            && !qualificationCase.verified
            && qualificationCase.verificationKind == .typedDeferral
            && qualificationCase.deferral?.code == .operationUnavailable
            && qualificationCase.deferral?.detail.isEmpty == false
            && qualificationCase.deferral?.detail == qualificationCase.reason
            && qualificationCase.reason?.hasPrefix("required axis unavailable:") == true
            && qualificationCase.readback != nil
            && qualificationCase.readback?.verified == false
            && qualificationCase.readback?.source == "logic://system/health"
            && qualificationCase.readback.map { Self.isSHA256($0.sha256) } == true
            && qualificationCase.availabilityReason == availabilityReason(
                for: axis,
                observedAxis: observedAxis
            )
            && qualificationCase.reason?.isEmpty == false
            && !qualificationCase.evidenceFiles.isEmpty
    }

    private static func isValidLiveObservation(
        _ observation: QualificationAvailabilityObservation?,
        axis: QualificationAxis
    ) -> Bool {
        guard let observation,
              observation.activeVariant == axis.variant,
              observation.logicUILocale == axis.locale,
              observation.activeBundleID == expectedBundleID(for: axis.variant),
              observation.variants.count == LogicVariant.allCases.count,
              Set(observation.variants.map(\.variant)) == Set(LogicVariant.allCases),
              let active = observation.variants.first(where: { $0.variant == axis.variant }) else {
            return false
        }
        return active.bundleID == observation.activeBundleID
            && active.installed
            && active.running
            && observation.variants.allSatisfy {
                $0.bundleID == expectedBundleID(for: $0.variant)
            }
    }

    private static func provesUnavailable(
        axis: QualificationAxis,
        observation: QualificationAvailabilityObservation
    ) -> Bool {
        guard axis.variant != observation.activeVariant else {
            return axis.locale != observation.logicUILocale
        }
        guard let variant = observation.variants.first(where: { $0.variant == axis.variant }) else {
            return false
        }
        return !variant.installed && !variant.running
    }

    private static func expectedBundleID(for variant: LogicVariant) -> String {
        switch variant {
        case .desktop: LogicProVariant.desktop.bundleID
        case .creatorStudio: LogicProVariant.creatorStudio.bundleID
        }
    }

    private static func availabilityReason(
        for axis: QualificationAxis,
        observedAxis: QualificationAxis
    ) -> QualificationAvailabilityReason? {
        switch (axis.variant != observedAxis.variant, axis.locale != observedAxis.locale) {
        case (true, true): .differentLogicVariantAndUILocale
        case (true, false): .differentLogicVariant
        case (false, true): .differentLogicUILocale
        case (false, false): nil
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
