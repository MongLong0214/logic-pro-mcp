import Foundation

/// The atlas diff as a qualification step.
///
/// ADR-007 asks that a new Logic version's qualification include an atlas diff. `AtlasDiff` scores
/// baselines; this decides what a qualification run should DO with the answer, and it deliberately
/// adds no field to the attestation: the result is a `QualificationCase` like any other, so it
/// lands in `total`/`passed`/`failed` and in the case manifest without a schema change. A new field
/// would have needed a schema version, and a step whose whole claim is "this refuses" should not
/// arrive by changing what every consumer must parse.
///
/// HISTORY WORTH KEEPING, because this file has now said both things. The qualification subsystem
/// was removed on 2026-09-13 with ADR-001, and for a day this comment correctly said the run it
/// feeds did not exist — `caseFor` was deleted with it and `QualificationCase` survived nowhere but
/// in prose. The owner reversed that on 2026-09-14 and the subsystem is restored, so the paragraph
/// above is true again. The reason to record the round trip rather than quietly revert: a reader
/// who finds a comment describing a destination should be able to tell a stale claim from a
/// restored one, and this file was both within two days.
///
/// WHAT DECIDES WHETHER IT RUNS
/// ----------------------------
/// `FeatureFlags.adr007SelectorAtlas`, which until now gated nothing — measured 2026-08-29, its
/// only reference in the tree was a test asserting it is off, while the six adopted selectors
/// resolve unconditionally in every build. So the flag said "off" about something that was on.
/// It has a subject now, and it is this: the diff, not the selectors.
///
/// Off by default, and that is the point of putting it behind a flag rather than shipping it armed.
/// Only `ko` has a control-bar baseline today; arming this for every run would refuse every
/// qualification on a machine whose Logic speaks anything else — a gate failing on its operator's
/// language rather than on Logic.
enum AtlasQualification {

    /// What a run can conclude, before it is turned into a case.
    enum Outcome: Equatable, Sendable {
        /// The flag is off. No case is emitted at all; today's pipeline is unchanged.
        case notArmed
        /// Armed, but there is no usable validated baseline to diff against. A refusal, not a pass — see `caseFor`.
        case noBaselines(reason: String)
        /// Diffed. `unmeasured` is the adopted set no pair covered; `dropped` names baselines that
        /// could not be paired at all.
        case diffed(verdict: QualificationReuse, drifts: [SelectorDrift],
                    unmeasured: Set<SelectorID>, dropped: [String])
    }

    /// A baseline and the live capture taken at the same scope.
    struct Pair: Codable, Equatable, Sendable {
        let scope: String
        let baseline: AXSnapshot.Document
        let current: AXSnapshot.Document
    }

    /// The outcome for a set of pairs.
    ///
    /// `armed` is passed rather than read here so the decision has one home and the tests do not
    /// have to move an environment variable to exercise both sides.
    static func outcome(armed: Bool, pairs: [Pair], dropped: [String] = []) -> Outcome {
        guard armed else { return .notArmed }
        guard !pairs.isEmpty else {
            return .noBaselines(
                reason: "no atlas baseline was captured, so the diff had nothing to compare — "
                    + "an armed run with nothing to measure refuses rather than reporting clean")
        }
        let drifts = pairs.flatMap { AtlasDiff.between(baseline: $0.baseline, current: $0.current) }
        let unmeasured = pairs
            .map { AtlasDiff.uncovered(baseline: $0.baseline, current: $0.current) }
            .reduce(Set(AtlasDiff.adoptedSelectors.map(\.id))) { $0.intersection($1) }
        // A dropped baseline is a scope this run could not read. Even when the pairs that DID
        // resolve cover every selector, the run measured less than it was given — and calling that
        // full reuse is the silence this step exists to refuse.
        let verdict = dropped.isEmpty
            ? AtlasDiff.verdict(for: drifts, assumingCoverage: unmeasured)
            : .failClosedMutation
        return .diffed(
            verdict: verdict, drifts: drifts, unmeasured: unmeasured, dropped: dropped)
    }
    // `caseFor(_:axis:binarySHA256:traceID:)` turns an atlas outcome into a release-qualification
    // case. It was REMOVED on 2026-09-13 with the certification system it fed and RESTORED here on
    // 2026-09-19; the comment that said "only the adapter to the certificate went" stood directly
    // above the restored adapter for the life of the branch, which is a sentence describing a tree
    // that no longer existed.
    //
    // This decision-only projection carries no files. The runner uses `evidenceCaseFor` below
    // to retain the compared documents in the common manifest; no empty-evidence waiver is used.
    // Arming still needs the explicit qualification flag and baseline directory. Current captures
    // whose locale/version are merely `observed` cannot establish the required metadata binding.



    /// Why it failed, naming selectors rather than a count.
    ///
    /// A count tells a reader that something moved; the names tell them which operations are at
    /// risk, which is the whole reason `SelectorDrift` carries `affectedOperations`.
    /// The case an outcome produces, or nil when the run is not armed.
    ///
    /// `.readOnlyOnly` fails too. The verdict's own vocabulary distinguishes "reuse everything"
    /// from "reads only", and a qualification run is asking whether this release may be qualified
    /// for the mutating operations the atlas guards — so anything short of full reuse is a no for
    /// the question being asked here, whatever it may allow elsewhere.
    /// - Parameter axis: the run's own axis, passed in rather than invented. The atlas result is
    ///   about the variant and LOCALE this run measured — a case filed under a different axis would
    ///   read as a claim about a Logic nobody looked at.
    static func caseFor(
        _ outcome: Outcome,
        axis: QualificationAxis,
        binarySHA256: String,
        traceID: String
    ) -> QualificationCase? {
        let passed: Bool
        let reason: String?
        switch outcome {
        case .notArmed:
            return nil
        case let .noBaselines(why):
            passed = false
            reason = why
        case let .diffed(verdict, drifts, unmeasured, dropped):
            passed = verdict == .reuseFull
            reason = passed ? nil : describe(
                verdict: verdict, drifts: drifts, unmeasured: unmeasured, dropped: dropped)
        }
        return QualificationCase(
            id: "atlas.drift_diff",
            status: passed ? .passed : .failed,
            tool: "selector_atlas",
            command: "drift_diff",
            traceID: traceID,
            verified: passed,
            evidenceFiles: [],
            reason: reason,
            binarySHA256: binarySHA256,
            axis: axis,
            operationID: "atlas.drift_diff",
            operationRequestID: nil,
            verificationKind: .readResponse,
            deferral: nil,
            readback: nil,
            availabilityReason: nil
        )
    }

    /// The documents themselves, rather than a producer-supplied pass flag. This is retained
    /// inside the existing case evidence file and recomputed by the verifier.
    struct ComparisonEvidence: Codable, Equatable, Sendable {
        let schema: String
        let binarySHA256: String
        let axis: QualificationAxis
        let pairs: [Pair]
        let dropped: [String]

        enum CodingKeys: String, CodingKey {
            case schema, axis, pairs, dropped
            case binarySHA256 = "binary_sha256"
        }

        var outcome: Outcome {
            guard schema == "qualification-atlas-comparison/v1",
                  binarySHA256.count == 64,
                  binarySHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  axis.variant == .desktop else {
                return .noBaselines(reason: "invalid atlas evidence schema, candidate or variant")
            }
            guard Set(pairs.map(\.scope)).count == pairs.count else {
                return .noBaselines(reason: "duplicate atlas comparison scope")
            }
            // The two adopted qualification scopes are fixed by Desktop en/ko policy,
            // not inferred from surviving pairs or a favorable whole-window score.
            guard pairs.count == 2,
                  pairs.filter({ AXLocalePolicy.trackHeadersDescription.matches(
                      $0.scope, mode: .exactStrict) }).count == 1,
                  pairs.filter({ AXLocalePolicy.controlBarGroupLabel.matches(
                      $0.scope, mode: .exactStrict) }).count == 1 else {
                return .noBaselines(
                    reason: "required atlas scopes missing or ambiguous: trackHeaderRail, controlBar")
            }
            for pair in pairs {
                guard pair.scope == pair.baseline.scope,
                      pair.scope == pair.current.scope,
                      !AtlasDiff.selectors(for: pair.baseline).isEmpty else {
                    return .noBaselines(reason: "atlas capture scope does not match its pair")
                }
                guard pair.baseline.capturedFrom == "ax", pair.current.capturedFrom == "ax" else {
                    return .noBaselines(reason: "unsupported atlas capture source")
                }
                let locales: Set<String> = axis.locale == .koKR ? ["ko", "ko-KR"] : ["en", "en-US"]
                let unknownVersions: Set<String> = ["", "observed", "unknown", "unspecified"]
                guard locales.contains(pair.baseline.locale), locales.contains(pair.current.locale),
                      !unknownVersions.contains(pair.baseline.logicVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                      !unknownVersions.contains(pair.current.logicVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return .noBaselines(reason: "atlas capture locale/version is unknown or mismatches its axis")
                }
            }
            return AtlasQualification.outcome(armed: true, pairs: pairs, dropped: dropped)
        }
    }

    struct EvidenceCase {
        let qualificationCase: QualificationCase
        let evidence: CaseEvidence
    }

    /// Production adapter. `caseFor` above is only the decision projection; it cannot provide
    /// release evidence without the documents from which the decision was computed.
    static func evidenceCaseFor(
        armed: Bool, pairs: [Pair], dropped: [String] = [],
        axis: QualificationAxis, binarySHA256: String, traceID: String
    ) -> EvidenceCase? {
        guard armed else { return nil }
        let comparison = ComparisonEvidence(schema: "qualification-atlas-comparison/v1",
            binarySHA256: binarySHA256, axis: axis, pairs: pairs, dropped: dropped)
        guard let decision = caseFor(comparison.outcome, axis: axis,
            binarySHA256: binarySHA256, traceID: traceID) else { return nil }
        let qualificationCase = QualificationCase(
            id: decision.id, status: decision.status, tool: decision.tool, command: decision.command,
            traceID: traceID, verified: decision.verified,
            evidenceFiles: ["evidence/atlas-drift-diff.json"], reason: decision.reason,
            binarySHA256: binarySHA256, axis: axis, operationID: decision.operationID,
            verificationKind: .atlasComparison)
        let evidence = CaseEvidence(schema: "qualification-case-evidence/v3",
            caseID: decision.id, operationID: decision.operationID,
            tool: decision.tool, command: decision.command,
            registrySpecFound: false, handlerBound: false, traceStarted: false, traceCompleted: false,
            observedVariant: axis.variant.rawValue, observedLocale: axis.locale.rawValue,
            failureReason: decision.reason, binarySHA256: binarySHA256, axis: axis,
            status: decision.status, verified: decision.verified,
            verificationKind: .atlasComparison, atlasComparison: comparison)
        return EvidenceCase(qualificationCase: qualificationCase, evidence: evidence)
    }

    static func comparisonBinds(_ evidence: CaseEvidence) -> Bool {
        guard let comparison = evidence.atlasComparison,
              comparison.binarySHA256 == evidence.binarySHA256, comparison.axis == evidence.axis,
              evidence.caseID == "atlas.drift_diff", evidence.operationID == evidence.caseID,
              evidence.tool == "selector_atlas", evidence.command == "drift_diff",
              evidence.operationResponseSHA256 == nil, evidence.operationRequestID == nil,
              evidence.operationIsError == nil, evidence.operationState == nil,
              evidence.operationError == nil, evidence.operationWriteAttempted == nil,
              evidence.readback == nil, evidence.deferral == nil,
              evidence.mutationRestoreRecordSHA256 == nil,
              evidence.availabilityReason == nil, evidence.availabilityObservation == nil,
              let expected = caseFor(comparison.outcome, axis: evidence.axis,
                binarySHA256: evidence.binarySHA256, traceID: "comparison-verification") else { return false }
        return expected.status == evidence.status && expected.verified == evidence.verified
            && expected.reason == evidence.failureReason
    }

    static func describe(
        verdict: QualificationReuse,
        drifts: [SelectorDrift],
        unmeasured: Set<SelectorID>,
        dropped: [String] = []
    ) -> String {
        var parts: [String] = ["atlas diff verdict \(verdict)"]
        let moved = drifts.filter { $0.status != .stable }
        if !moved.isEmpty {
            parts.append("drifted: " + moved
                .map { "\($0.selectorID)=\($0.status) (\($0.affectedOperations.map(\.rawValue).joined(separator: ",")))" }
                .sorted().joined(separator: "; "))
        }
        if !unmeasured.isEmpty {
            parts.append("unmeasured: " + unmeasured.map { "\($0)" }.sorted().joined(separator: ", "))
        }
        if !dropped.isEmpty {
            parts.append("baselines that could not be read or resolved: "
                + dropped.sorted().joined(separator: ", "))
        }
        if moved.isEmpty, unmeasured.isEmpty, dropped.isEmpty, drifts.isEmpty {
            parts.append("nothing was compared")
        }
        return parts.joined(separator: " — ")
    }
}
