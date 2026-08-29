@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #290 — the atlas diff as a qualification step, which is the criterion the measurement was built
/// for and the one this issue had left open.
///
/// It emits a `QualificationCase` rather than a new attestation field, so a consumer that never
/// heard of the atlas still counts its failure. That is the whole reason the shape was chosen, and
/// the first case below is the one that would notice if it changed.
@Suite("Issue290AtlasQualification")
struct AtlasQualificationTests {

    private func fixture(_ name: String) throws -> AXSnapshot.Document {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AX/\(name)")
        return try JSONDecoder().decode(AXSnapshot.Document.self, from: Data(contentsOf: url))
    }

    private func pairs() throws -> [AtlasQualification.Pair] {
        let rail = try fixture("logic-12.x-desktop-ko-track-headers.json")
        let bar = try fixture("logic-12.x-desktop-ko-control-bar.json")
        return [
            AtlasQualification.Pair(scope: rail.scope, baseline: rail, current: rail),
            AtlasQualification.Pair(scope: bar.scope, baseline: bar, current: bar),
        ]
    }

    private var axis: QualificationAxis {
        QualificationAxis(variant: .desktop, locale: .koKR, profile: .core, cache: .cold, fixture: .empty)
    }

    @Test("the flag decides whether the step exists at all")
    func theFlagGatesTheStep() throws {
        // Off is today's pipeline, unchanged: no case, so no count moves and no consumer sees a new
        // id. That matters more than it sounds — only `ko` has a control-bar baseline, so arming
        // this everywhere would refuse every qualification on a Logic speaking anything else, which
        // is a gate failing on its operator's language rather than on Logic.
        #expect(AtlasQualification.outcome(armed: false, pairs: try pairs()) == .notArmed)
        #expect(AtlasQualification.caseFor(
            .notArmed, axis: axis, binarySHA256: "abc", traceID: "t") == nil)

        // On, with the committed baselines against themselves: a passing case.
        let armed = AtlasQualification.outcome(armed: true, pairs: try pairs())
        let emitted = try #require(AtlasQualification.caseFor(
            armed, axis: axis, binarySHA256: "abc", traceID: "t"))
        #expect(emitted.status == .passed, "reason: \(emitted.reason ?? "nil")")
        #expect(emitted.verified)
        #expect(emitted.id == "atlas.drift_diff")
    }

    @Test("an armed run with nothing to diff refuses instead of reporting clean")
    func armedWithNoBaselinesFailsClosed() throws {
        let outcome = AtlasQualification.outcome(armed: true, pairs: [])
        guard case let .noBaselines(reason) = outcome else {
            Issue.record("expected .noBaselines, got \(outcome)")
            return
        }
        #expect(reason.contains("nothing to compare"))
        let emitted = try #require(AtlasQualification.caseFor(
            outcome, axis: axis, binarySHA256: "abc", traceID: "t"))
        #expect(emitted.status == .failed)
        #expect(!emitted.verified)
    }

    @Test("a selector that lost its control fails the case and names the operations at risk")
    func driftFailsAndNamesOperations() throws {
        // Driven by removing the label from the tree, not by editing an expected verdict. Every
        // alias, because `fader` is one of them and stripping only `volume` leaves the selector
        // resolving — a mutation that cannot be seen is not a control.
        let rail = try fixture("logic-12.x-desktop-ko-track-headers.json")
        var text = String(decoding: try JSONEncoder().encode(rail), as: UTF8.self)
        for alias in AXLocalePolicy.sliderVolumeHint.labels {
            text = text.replacingOccurrences(
                of: alias, with: String(repeating: "x", count: alias.count),
                options: .caseInsensitive)
        }
        let stripped = try JSONDecoder().decode(AXSnapshot.Document.self, from: Data(text.utf8))
        let bar = try fixture("logic-12.x-desktop-ko-control-bar.json")

        let outcome = AtlasQualification.outcome(armed: true, pairs: [
            AtlasQualification.Pair(scope: rail.scope, baseline: rail, current: stripped),
            AtlasQualification.Pair(scope: bar.scope, baseline: bar, current: bar),
        ])
        let emitted = try #require(AtlasQualification.caseFor(
            outcome, axis: axis, binarySHA256: "abc", traceID: "t"))

        #expect(emitted.status == .failed)
        let reason = try #require(emitted.reason)
        #expect(reason.contains("trackHeaderVolumeFader"),
                "the failure did not name the selector: \(reason)")
        #expect(reason.contains("mixer.set_volume"),
                "the failure did not name the operation at risk: \(reason)")
    }

    @Test("the case is filed under the axis the run measured")
    func theCaseCarriesTheRunsAxis() throws {
        // A result about a Korean Logic filed under `en` would read as a claim about a Logic nobody
        // looked at, and the axis is exactly what a promotion gate matches on.
        let other = QualificationAxis(
            variant: .desktop, locale: .enUS, profile: .core, cache: .cold, fixture: .empty)
        let armed = AtlasQualification.outcome(armed: true, pairs: try pairs())
        let ko = try #require(AtlasQualification.caseFor(
            armed, axis: axis, binarySHA256: "abc", traceID: "t"))
        let en = try #require(AtlasQualification.caseFor(
            armed, axis: other, binarySHA256: "abc", traceID: "t"))
        #expect(ko.axis.locale == .koKR)
        #expect(en.axis.locale == .enUS)
        #expect(ko.axis != en.axis)
    }

    @Test("a baseline that could not be read is named, and the run refuses")
    func aDroppedBaselineFailsClosed() throws {
        // Dropping an unreadable baseline is right — an empty current would diff as "every selector
        // vanished", true-looking and about nothing. Dropping it SILENTLY is not: with the
        // remaining pairs covering every selector, the case passed while a scope nobody could
        // resolve went unmentioned. Named by review before merge, 2026-08-29.
        let outcome = AtlasQualification.outcome(
            armed: true, pairs: try pairs(), dropped: ["logic-12.x-desktop-en-track-headers.json"])
        let emitted = try #require(AtlasQualification.caseFor(
            outcome, axis: axis, binarySHA256: "abc", traceID: "t"))
        #expect(emitted.status == .failed, "a dropped baseline was absorbed")
        let reason = try #require(emitted.reason)
        #expect(reason.contains("logic-12.x-desktop-en-track-headers.json"),
                "the dropped baseline is not named: \(reason)")

        // And the same pairs with nothing dropped still pass, or this case would be asserting that
        // the fixtures are broken rather than that dropping is caught.
        let clean = AtlasQualification.outcome(armed: true, pairs: try pairs())
        #expect(try #require(AtlasQualification.caseFor(
            clean, axis: axis, binarySHA256: "abc", traceID: "t")).status == .passed)
    }

    @Test("a refused atlas diff is not promotable")
    func aRefusedDiffBlocksPromotion() throws {
        // The defect this closes: `PromotionGate` rejects a FAILED case only when its id equals a
        // required axis key, and `atlas.drift_diff` is not one — so the step reported a failure
        // that stopped nothing, which is the "gate that does not gate" shape it exists to remove.
        let failed = try #require(AtlasQualification.caseFor(
            .diffed(verdict: .failClosedMutation,
                    drifts: [SelectorDrift(
                        selectorID: .trackHeaderVolumeFader, status: .missing,
                        previousConfidence: 1, currentConfidence: 0,
                        changedRoles: [], affectedOperations: [.mixerSetVolume])],
                    unmeasured: [], dropped: []),
            axis: axis, binarySHA256: "abc", traceID: "t"))
        #expect(failed.status == .failed)
        #expect(failed.id == "atlas.drift_diff")
        // The gate looks the case up by exactly this id; the rejection lives in PromotionGate and
        // is exercised there. What this pins is the contract between them — a rename on either
        // side leaves the gate watching a name nothing produces.
        let failedReason = try #require(failed.reason)
        #expect(failedReason.contains("failClosedMutation"))
    }

    @Test("the case id is the one the runner refuses to duplicate")
    func theCaseIdIsStable() throws {
        // The runner checks external-manifest ids for collisions BEFORE this step appends, so the
        // guard against a second `atlas.drift_diff` lives at the append site and keys on this exact
        // string. Pinning it here means renaming the id cannot silently make that guard watch a
        // name nothing produces. Found by review before merge, 2026-08-29.
        let armed = AtlasQualification.outcome(armed: true, pairs: try pairs())
        let emitted = try #require(AtlasQualification.caseFor(
            armed, axis: axis, binarySHA256: "abc", traceID: "t"))
        #expect(emitted.id == "atlas.drift_diff")
        #expect(emitted.operationID == "atlas.drift_diff")

        // And it must not look like the ids the promotion gate matches on. That gate finds a
        // required operation by `id == "in-process/<operationID>"`, so a case shaped like one would
        // be read as satisfying an operation this step never drove.
        #expect(!emitted.id.hasPrefix("in-process/"))
    }

    @Test("read-only reuse is not enough for a run asking about mutations")
    func readOnlyOnlyStillFails() throws {
        // `policy(for:)` grants `.readOnlyOnly` to a minor drift with high confidence. This step is
        // asking whether the release may be qualified for the mutating operations the atlas guards,
        // so anything short of full reuse is a no HERE — stated because the verdict's own
        // vocabulary makes `.readOnlyOnly` sound like a pass.
        let minor = SelectorDrift(
            selectorID: .trackHeaderPanControl, status: .minorDrift,
            previousConfidence: 0.95, currentConfidence: 0.85,
            changedRoles: [], affectedOperations: [.mixerSetPan])
        // The CASE, not just the sentence. An earlier version of this asserted only what
        // `describe` writes, so relaxing the decision to `verdict != .failClosedMutation` left it
        // green — the control could not see the mutation it was aimed at.
        let emitted = try #require(AtlasQualification.caseFor(
            .diffed(verdict: .readOnlyOnly, drifts: [minor], unmeasured: [], dropped: []),
            axis: axis, binarySHA256: "abc", traceID: "t"))
        #expect(emitted.status == .failed, "readOnlyOnly was accepted as a pass")
        #expect(!emitted.verified)

        let reason = try #require(emitted.reason)
        #expect(reason.contains("readOnlyOnly"))
        #expect(reason.contains("mixer.set_pan"))
    }
}
