import Foundation

/// The atlas diff, and what a run should conclude from it.
///
/// ADR-007 asks that a new Logic version's qualification include an atlas diff. `AtlasDiff` scores
/// baselines; this decides what to DO with the answer.
///
/// THE QUALIFICATION RUN THIS WAS BUILT TO FEED NO LONGER EXISTS. It was written to emit a
/// `QualificationCase` that would land in an attestation's `total`/`passed`/`failed` and in a case
/// manifest, deliberately without adding a field so no schema version was needed. That whole
/// subsystem was removed on 2026-09-13 with ADR-001: `QualificationCase`,
/// `QualificationAttestation`, `PromotionGate` and `QualificationTransport` are gone from the tree
/// — measured, not assumed, by grepping `Sources/` for each (the only surviving mention of
/// `QualificationCase` anywhere was this comment).
///
/// What survives is the decision itself, which is the part worth keeping: `outcome(armed:pairs:
/// dropped:)` is pure, and `--probe-atlas-diff` in `MainEntrypoint` drives it against real captured
/// pairs. So the logic is reachable and testable; what it has no consumer for is a case to emit
/// into. When a qualification run exists again, that is the seam to wire, and the
/// no-new-schema-field reasoning above is still the right reasoning for it.
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
        /// Diffed. `unmeasured` is the adopted set no pair covered; `dropped` names baselines that
        /// could not be paired at all.
        case diffed(verdict: QualificationReuse, drifts: [SelectorDrift],
                    unmeasured: Set<SelectorID>, dropped: [String])
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
    // `caseFor(_:axis:binarySHA256:traceID:)` lived here and turned an atlas outcome into a
    // release-qualification case. The release-certification system it fed is gone; the atlas
    // itself is a DIAGNOSTIC — `--probe-atlas-diff` still runs `outcome(armed:pairs:dropped:)`
    // and prints what drifted. Only the adapter to the certificate went.


    /// Why it failed, naming selectors rather than a count.
    ///
    /// A count tells a reader that something moved; the names tell them which operations are at
    /// risk, which is the whole reason `SelectorDrift` carries `affectedOperations`.
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
