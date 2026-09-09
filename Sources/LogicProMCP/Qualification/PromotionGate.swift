enum PromotionRejectionReason: Equatable, Sendable {
    case requiredCaseFailed(caseID: String)
    case requiredCombinationNotQualified(key: String)
    case missingArtifact(name: String)
    case requiredArtifactSchemaInvalid(name: String)
    case binarySHAMismatch(expected: String, actual: String)
    /// One or both values are not a SHA-256. Same reasoning as `releaseVersionUnparseable`.
    case binarySHAUnparseable(expected: String, actual: String)
    case releaseCommitMismatch(expected: String, actual: String)
    case expiredWaiver(caseID: String)
    case waiverForUnknownCase(caseID: String)
    case waiverForPassingCase(caseID: String)
    case waiverForNonWaivedCase(caseID: String, status: QualificationStatus)
    case waivedCaseMissingWaiver(caseID: String)
    case invalidWaiver(caseID: String, field: String)
    case duplicateWaiver(caseID: String)
    case duplicateCaseID(caseID: String)
    case releaseVersionMismatch(expected: String, actual: String)
    /// Distinct from a mismatch: one or both versions are not a semantic version at all, so there
    /// was nothing to compare. Folding this into `releaseVersionMismatch` printed
    /// `expected: "unknown", actual: "unknown"` -- two identical strings reported as disagreeing,
    /// which sends a reader looking for a difference that does not exist.
    case releaseVersionUnparseable(expected: String, actual: String)
    case evidenceBindingMismatch(detail: String)
    case requiredOperationNotSatisfied(operationID: String)
    /// The ADR-007 atlas diff ran and refused.
    ///
    /// A case of its own because this gate rejects a FAILED case only when its id equals a required
    /// axis key, and `atlas.drift_diff` is not one — so without this the step reported a failure
    /// that stopped nothing. Measured before merge, 2026-08-29: the case landed `.failed`,
    /// `attestation.failed` counted it, and the release stayed promotable. A verdict nobody acts on
    /// is the shape this whole step exists to remove.
    case atlasDriftRefused(detail: String)
    case provenanceSignatureMissing
    case provenanceSignatureInvalid
    case trustedProvenanceKeyUnavailable
}

struct PromotionDecision: Equatable, Sendable {
    let promotable: Bool
    let rejections: [PromotionRejectionReason]
}

struct PromotionGate {
    /// What it takes for a live qualification case to CREDIT its operation.
    ///
    /// #373. This was four inline conjuncts inside `evaluate`, which was fine while the release
    /// gate was the only reader. It is not the only reader any more:
    /// `ProductionReadinessContracts` reports R-SEM over the same question and had no way to ask
    /// it, so it counted every operation as uncovered no matter how much live evidence existed.
    /// Two evaluators answering "did this operation pass?" from two spellings is a second
    /// authority — the first divergence would let a release promote while the debt board said the
    /// coverage was missing, or the reverse. One function, both callers.
    ///
    /// Every conjunct is load-bearing and none is redundant:
    ///   * `status == .passed` — the case's own verdict.
    ///   * `verified` — the case asserts it verified something rather than merely not failing.
    ///   * `verificationKind == .semanticReadback` — a protocol smoke test also reaches `.passed`;
    ///     #373 asks for semantic evidence specifically, so the KIND is checked, not just the
    ///     verdict.
    ///   * `readback?.verified == true` — the readback is present AND says it verified. `?? false`
    ///     is deliberate here (an absent readback does not credit); written as `== true` so a nil
    ///     cannot read as a pass.
    static func operationIsLiveCredited(_ operationCase: QualificationCase) -> Bool {
        operationCase.status == .passed
            && operationCase.verified
            && operationCase.verificationKind == .semanticReadback
            && operationCase.readback?.verified == true
    }

    /// The operations a live attestation credits — the ONLY supported way to build the set
    /// `ProductionReadinessContracts.evaluate` reads.
    ///
    /// #373. The static evaluator must not be handed a list of operation IDs someone typed: that
    /// would let a stored artifact authorize itself, and R-SEM would close because a file said so.
    /// It is handed the output of this function instead, which reads real cases and applies the
    /// same predicate the release gate applies.
    ///
    /// The case id is checked as well as `operationID`, because the release gate identifies an
    /// operation case by BOTH (`in-process/<id>` with a matching `operationID`) and crediting on
    /// the weaker of the two would credit a case the release gate would not.
    ///
    /// A duplicated id credits NOTHING: `evaluate` rejects a duplicate case id outright, so an
    /// attestation carrying two cases for one operation is one the release gate refuses, and this
    /// function must not read a pass out of it.
    static func liveCreditedOperationIDs(
        in attestation: ReleaseQualificationAttestation
    ) -> Set<String> {
        var credited: Set<String> = []
        var seen: Set<String> = []
        var duplicated: Set<String> = []
        for operationCase in attestation.cases {
            let operationID = operationCase.operationID
            guard operationCase.id == "in-process/\(operationID)" else { continue }
            if !seen.insert(operationID).inserted { duplicated.insert(operationID) }
            if operationIsLiveCredited(operationCase) { credited.insert(operationID) }
        }
        return credited.subtracting(duplicated)
    }

    func evaluate(
        attestation: ReleaseQualificationAttestation,
        releaseVersion: String,
        expectedBinarySHA256: String,
        presentArtifacts: Set<String>,
        requiredArtifacts: Set<String>,
        requiredOperationIDs: Set<String>
    ) -> PromotionDecision {
        var rejections: [PromotionRejectionReason] = []

        // Three conditions used to share one reason name. A run whose attestation carried
        // `serverVersion: "unknown"` reported `releaseVersionMismatch` with
        // `expected: "unknown", actual: "unknown"` -- nothing mismatched; both values were simply
        // not versions. Naming several causes with one word makes the message point at the wrong
        // one, and the reader goes looking for a disagreement that is not there.
        if SemanticVersion(attestation.serverVersion) == nil
            || SemanticVersion(releaseVersion) == nil {
            rejections.append(.releaseVersionUnparseable(
                expected: releaseVersion,
                actual: attestation.serverVersion
            ))
        } else if attestation.serverVersion != releaseVersion {
            rejections.append(.releaseVersionMismatch(
                expected: releaseVersion,
                actual: attestation.serverVersion
            ))
        }
        if !Self.isSHA256(attestation.binarySHA256) || !Self.isSHA256(expectedBinarySHA256) {
            rejections.append(.binarySHAUnparseable(
                expected: expectedBinarySHA256,
                actual: attestation.binarySHA256
            ))
        } else if attestation.binarySHA256 != expectedBinarySHA256 {
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
        // The atlas step, if it ran at all. Absent means the flag was off, which is today's
        // pipeline and not a rejection; present-and-failed is one.
        if let atlas = attestation.cases.first(where: { $0.id == "atlas.drift_diff" }),
           atlas.status == .failed {
            rejections.append(.atlasDriftRefused(
                detail: atlas.reason ?? "the atlas diff refused without a stated reason"))
        }

        for operationID in requiredOperationIDs.sorted() {
            let operationCases = attestation.cases.filter {
                $0.id == "in-process/\(operationID)" && $0.operationID == operationID
            }
            guard operationCases.count == 1, let operationCase = operationCases.first else {
                rejections.append(.requiredOperationNotSatisfied(operationID: operationID))
                continue
            }
            let operationPassed = PromotionGate.operationIsLiveCredited(operationCase)
            let operationWaived = operationCase.status == .waived
                && !operationCase.verified
                && operationCase.verificationKind == .typedDeferral
                && operationCase.deferral != nil
                && attestation.waivers.contains { waiver in
                    waiver.governsOperation(
                        caseID: operationCase.id,
                        operationID: operationCase.operationID
                    ) && waiver.affectsDefaultProfile
                        && waiver.releaseNoteVisible
                        && !expiredWaiverIDs.contains(waiver.caseID)
                }
            if !operationPassed && !operationWaived {
                rejections.append(.requiredOperationNotSatisfied(
                    operationID: operationID
                ))
            }
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
                ) || (attestedLiveCase != nil && Self.isGovernedWaivedCase(
                    qualificationCase,
                    axis: axis,
                    observedAxis: attestedAxis,
                    binarySHA256: attestation.binarySHA256,
                    waivers: attestation.waivers,
                    expiredWaiverIDs: expiredWaiverIDs
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

    private static func isGovernedWaivedCase(
        _ qualificationCase: QualificationCase,
        axis: QualificationAxis,
        observedAxis: QualificationAxis,
        binarySHA256: String,
        waivers: [QualificationWaiver],
        expiredWaiverIDs: Set<String>
    ) -> Bool {
        guard axis != observedAxis,
              qualificationCase.id == axis.key,
              qualificationCase.axis == axis,
              qualificationCase.binarySHA256 == binarySHA256,
              qualificationCase.status == .waived,
              !qualificationCase.verified,
              qualificationCase.verificationKind == .typedDeferral,
              qualificationCase.deferral?.code == .operationUnavailable,
              qualificationCase.deferral?.detail == qualificationCase.reason,
              qualificationCase.readback?.verified == false,
              !qualificationCase.evidenceFiles.isEmpty else {
            return false
        }
        return waivers.contains {
            $0.caseID == axis.key
                && $0.governsHostAxisAvailability
                && $0.affectsDefaultProfile
                && $0.releaseNoteVisible
                && !expiredWaiverIDs.contains($0.caseID)
        }
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

    /// Internal, not private: `QualificationRunner` compares the PUBLISHED digest against the
    /// candidate at a second site and needs the same validity test. A copy there would be a second
    /// definition of "is this a SHA-256" free to drift from this one.
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Substring]

    init?(_ rawValue: String) {
        var value = rawValue
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard withoutBuild.count <= 2,
              withoutBuild.allSatisfy({ !$0.isEmpty }),
              withoutBuild.dropFirst().allSatisfy({
                  Self.validIdentifiers($0, rejectNumericLeadingZero: false)
              }) else {
            return nil
        }
        let releaseParts = withoutBuild[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard releaseParts.count <= 2,
              releaseParts.allSatisfy({ !$0.isEmpty }),
              releaseParts.dropFirst().allSatisfy({
                  Self.validIdentifiers($0, rejectNumericLeadingZero: true)
              }) else {
            return nil
        }
        let parts = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy(Self.validCoreNumber),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = releaseParts.count == 2
            ? releaseParts[1].split(separator: ".", omittingEmptySubsequences: false)
            : []
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = Self.isASCIINumeric(left)
            let rightNumeric = Self.isASCIINumeric(right)
            switch (leftNumeric, rightNumeric) {
            case (true, true):
                return left.count == right.count
                    ? left.lexicographicallyPrecedes(right)
                    : left.count < right.count
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left.lexicographicallyPrecedes(right)
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func validIdentifiers(
        _ value: Substring,
        rejectNumericLeadingZero: Bool
    ) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier in
            !identifier.isEmpty
                && identifier.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || $0 == 45
                }
                && (!rejectNumericLeadingZero || !isASCIINumeric(identifier)
                    || identifier == "0" || identifier.first != "0")
        }
    }

    private static func validCoreNumber(_ value: Substring) -> Bool {
        isASCIINumeric(value) && (value == "0" || value.first != "0")
    }

    private static func isASCIINumeric(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
