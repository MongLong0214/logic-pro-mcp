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
        /// Armed, but there is nothing to diff against. A refusal, not a pass — see `caseFor`.
        case noBaselines(reason: String)
        /// Diffed. `unmeasured` is the adopted set no pair covered.
        case diffed(verdict: QualificationReuse, drifts: [SelectorDrift], unmeasured: Set<SelectorID>)
    }

    /// A baseline and the live capture taken at the same scope.
    struct Pair: Sendable {
        let scope: String
        let baseline: AXSnapshot.Document
        let current: AXSnapshot.Document
    }

    /// The outcome for a set of pairs.
    ///
    /// `armed` is passed rather than read here so the decision has one home and the tests do not
    /// have to move an environment variable to exercise both sides.
    static func outcome(armed: Bool, pairs: [Pair]) -> Outcome {
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
        return .diffed(
            verdict: AtlasDiff.verdict(for: drifts, assumingCoverage: unmeasured),
            drifts: drifts,
            unmeasured: unmeasured)
    }

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
        case let .diffed(verdict, drifts, unmeasured):
            passed = verdict == .reuseFull
            reason = passed ? nil : describe(verdict: verdict, drifts: drifts, unmeasured: unmeasured)
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

    /// Why it failed, naming selectors rather than a count.
    ///
    /// A count tells a reader that something moved; the names tell them which operations are at
    /// risk, which is the whole reason `SelectorDrift` carries `affectedOperations`.
    static func describe(
        verdict: QualificationReuse,
        drifts: [SelectorDrift],
        unmeasured: Set<SelectorID>
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
        if moved.isEmpty, unmeasured.isEmpty, drifts.isEmpty {
            parts.append("nothing was compared")
        }
        return parts.joined(separator: " — ")
    }
}
