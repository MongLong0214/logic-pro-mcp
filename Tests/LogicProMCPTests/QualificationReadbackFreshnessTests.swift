import Foundation
import Testing
@testable import LogicProMCP

/// #373 Phase B — a readback is only evidence if it can be shown to postdate the mutation.
///
/// The values here are the ones measured live on 2026-08-24 (`tracks.create_audio`, readback either
/// side), so the admissible case is a transcription of a real envelope rather than a shape invented
/// to make the rule pass.
@Suite("QualificationReadbackFreshness")
struct QualificationReadbackFreshnessTests {
    private static let mutationStart = ISO8601DateFormatter().date(from: "2026-08-24T01:19:03Z")!
    private static let postMutation = ISO8601DateFormatter().date(from: "2026-08-24T01:19:06Z")!
    private static let preMutation = ISO8601DateFormatter().date(from: "2026-08-24T01:19:00Z")!

    private static func envelope(
        source: String? = "ax_live",
        fetchedAt: Date? = postMutation,
        age: Double? = 0.28
    ) -> QualificationReadbackFreshness.Envelope {
        .init(source: source, fetchedAt: fetchedAt, cacheAgeSeconds: age)
    }

    @Test("the measured live envelope is admissible")
    func measuredEnvelopePasses() {
        #expect(QualificationReadbackFreshness
            .verdict(for: Self.envelope(), mutationStartedAt: Self.mutationStart) == .admissible)
    }

    @Test("a cache that never moved is refused, which is the defect Phase B was blocked on")
    func staleCacheIsRefused() {
        // The PRE envelope from the same live run: correct shape, correct source, simply older than
        // the mutation. A value-equality check cannot tell this from the POST envelope; this can.
        let verdict = QualificationReadbackFreshness.verdict(
            for: Self.envelope(fetchedAt: Self.preMutation, age: 0.80),
            mutationStartedAt: Self.mutationStart)
        #expect(verdict == .predatesMutation(fetchedAt: Self.preMutation,
                                             mutationStartedAt: Self.mutationStart))
    }

    @Test("an envelope stamped exactly at the mutation start cannot have witnessed it")
    func sameInstantIsRefused() {
        // Equality is what a coarse clock produces, so it is the case most likely to appear and be
        // waved through by a `>=`.
        #expect(!QualificationReadbackFreshness.verdict(
            for: Self.envelope(fetchedAt: Self.mutationStart),
            mutationStartedAt: Self.mutationStart).isAdmissible)
    }

    @Test("cache and default sources are refused by name, not merged into one failure")
    func nonLiveSourcesAreNamed() {
        for source in ["cache", "default", nil] as [String?] {
            let verdict = QualificationReadbackFreshness.verdict(
                for: Self.envelope(source: source), mutationStartedAt: Self.mutationStart)
            #expect(verdict == .notLive(source: source),
                    "source \(source ?? "nil") should be refused as not-live, got \(verdict)")
        }
    }

    @Test("an unplaceable or wrong-shaped envelope is refused rather than assumed fresh")
    func missingFieldsAreRefused() {
        // A check that reports agreement when it cannot see its subject is the failure this suite
        // exists to avoid: absence of a timestamp is not evidence of freshness.
        #expect(QualificationReadbackFreshness.verdict(
            for: Self.envelope(fetchedAt: nil),
            mutationStartedAt: Self.mutationStart) == .unplaceableInTime)
        #expect(QualificationReadbackFreshness.verdict(
            for: Self.envelope(age: nil),
            mutationStartedAt: Self.mutationStart) == .ageAbsent)
    }
}
