import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Drives one saga step to a chosen write-path state with a chosen live
/// readback, so classification can be asserted in isolation. The first read is
/// the before-state; every later read is the post-write readback.
private actor StubReadbackExecutor: SagaStepExecutor {
    private let before: Value
    private let readback: Value?
    private let result: StepResult
    private var reads = 0

    init(before: Value, readback: Value?, result: StepResult) {
        self.before = before
        self.readback = readback
        self.result = result
    }

    func run(_ step: SagaStep) async -> StepResult { result }

    func readState(_ step: SagaStep) async -> ObservedState? {
        reads += 1
        let value: Value? = reads == 1 ? before : readback
        guard let value else { return nil }
        return ObservedState(read: SagaReadEvidence(
            readSource: .axTrackHeaderFader,
            provenance: .liveIndependent,
            trackIndex: 0,
            field: "value",
            observed: value,
            sampledAt: "2026-07-17T00:00:00.000Z"
        ))
    }
}

@Suite("Saga value comparator", .serialized)
struct SagaValueComparatorTests {
    private func bind(_ registry: TargetRegistry, index: Int, name: String) async -> TargetReference {
        let descriptor = TargetDescriptor(trackIndex: index, trackName: name)
        return await registry.bind(
            kind: .track,
            descriptor: descriptor,
            fingerprint: descriptor.fingerprint
        )
    }

    private func step(
        _ operationID: OperationID,
        target: TargetReference,
        value: Value
    ) -> SagaStep {
        let valueParameter: String = switch operationID {
        case .tracksRename: "name"
        case .tracksMute, .tracksSolo, .tracksArm: "enabled"
        default: "value"
        }
        return SagaStep(
            operationID: operationID,
            targetRef: target,
            params: [valueParameter: value],
            expectedInverse: SagaExpectedInverse(
                operationID: operationID,
                valueParameter: valueParameter
            )
        )
    }

    /// Runs a single-step plan and returns its verification disposition.
    private func disposition(
        _ operationID: OperationID,
        desired: Value,
        before: Value,
        readback: Value?,
        state: StepResultState,
        key: String
    ) async -> VerificationDisposition? {
        let registry = TargetRegistry()
        let target = await bind(registry, index: 0, name: "Bass")
        let executor = StubReadbackExecutor(
            before: before,
            readback: readback,
            result: StepResult(
                state: state,
                writeBoundaryCrossed: true,
                detail: "stub \(state.rawValue)"
            )
        )
        let outcome = await MutationSaga(
            targetRegistry: registry,
            enabled: true,
            routeAvailable: { _ in true }
        ).execute(
            SagaPlan(
                steps: [step(operationID, target: target, value: desired)],
                idempotencyKey: key
            ),
            executor: executor
        )
        return outcome.journal.first?.verificationEvidence?.disposition
    }

    // MARK: - Unit: the comparator itself

    /// The debt's core defect: EXACT `==` on a value the AX surface quantizes.
    /// Logic exposes the header fader in ~10-raw-unit detents, so a verified
    /// write of 0.7 reads back 0.699 — exact equality called that `notApplied`.
    ///
    /// NOTE ON THE BOUNDARY: the rule is the ratified `abs(a-b) <= 0.01`,
    /// applied literally. A value EXACTLY one epsilon away is deliberately not
    /// asserted here in either direction — in binary floating point
    /// `abs(0.71 - 0.7)` is `0.010000000000000009`, so the exact-boundary
    /// outcome is an artifact of decimal-literal representation rather than a
    /// decided contract. Asserting it would enshrine the artifact. Real
    /// readbacks (0.699…) sit well inside the tolerance; see the report note.
    @Test("volume tolerates the surface's quantization within 0.01")
    func volumeToleratesQuantization() {
        #expect(SagaValueComparator.equals(
            observed: .double(0.699), expected: .double(0.7), op: .mixerSetVolume
        ))
        #expect(SagaValueComparator.equals(
            observed: .double(0.705), expected: .double(0.7), op: .mixerSetVolume
        ))
        #expect(SagaValueComparator.equals(
            observed: .double(0.695), expected: .double(0.7), op: .mixerSetVolume
        ))
        // Clear of the boundary in both directions: a real mismatch.
        #expect(!SagaValueComparator.equals(
            observed: .double(0.68), expected: .double(0.7), op: .mixerSetVolume
        ))
        #expect(!SagaValueComparator.equals(
            observed: .double(0.72), expected: .double(0.7), op: .mixerSetVolume
        ))
    }

    @Test("pan tolerates 0.05 on its -1...1 range")
    func panToleratesItsWiderDetent() {
        #expect(SagaValueComparator.equals(
            observed: .double(0.46), expected: .double(0.5), op: .mixerSetPan
        ))
        #expect(!SagaValueComparator.equals(
            observed: .double(0.40), expected: .double(0.5), op: .mixerSetPan
        ))
    }

    /// A name is discrete: a trailing space is a different track name to the
    /// operator, and no epsilon may absorb it.
    @Test("rename compares exactly — a trailing space is not a match")
    func renameIsExact() {
        #expect(SagaValueComparator.equals(
            observed: .string("A"), expected: .string("A"), op: .tracksRename
        ))
        #expect(!SagaValueComparator.equals(
            observed: .string("A "), expected: .string("A"), op: .tracksRename
        ))
        #expect(SagaValueComparator.tolerance(for: .tracksRename).comparator == .exact)
        #expect(SagaValueComparator.tolerance(for: .tracksRename).epsilon == nil)
    }

    @Test("toggles compare exactly")
    func togglesAreExact() {
        for op in [OperationID.tracksMute, .tracksSolo, .tracksArm] {
            #expect(SagaValueComparator.tolerance(for: op).comparator == .exact)
            #expect(SagaValueComparator.equals(
                observed: .bool(true), expected: .bool(true), op: op
            ))
            #expect(!SagaValueComparator.equals(
                observed: .bool(false), expected: .bool(true), op: op
            ))
        }
    }

    /// Epsilon is absolute on a normalized range — a relative epsilon would
    /// collapse to zero at pan center, where a detent still spans 0.05.
    @Test("epsilon is absolute, not relative")
    func epsilonIsAbsolute() {
        #expect(SagaValueComparator.equals(
            observed: .double(0.04), expected: .double(0.0), op: .mixerSetPan
        ))
        #expect(SagaValueComparator.tolerance(for: .mixerSetVolume).epsilon == 0.01)
        #expect(SagaValueComparator.tolerance(for: .mixerSetPan).epsilon == 0.05)
    }

    /// A quantized field arriving as a non-numeric is a contract violation, not
    /// a near-miss — it must not be tolerated into a match.
    @Test("epsilon comparison fails closed on non-numeric or unknown operations")
    func epsilonFailsClosedOnNonNumeric() {
        #expect(!SagaValueComparator.equals(
            observed: .string("0.7"), expected: .double(0.7), op: .mixerSetVolume
        ))
        #expect(!SagaValueComparator.equals(
            observed: .bool(true), expected: .double(1.0), op: .mixerSetVolume
        ))
        // An operation with no declared tolerance falls back to exact.
        #expect(SagaValueComparator.tolerance(for: .transportPlay).comparator == .exact)
    }

    @Test("comparison evidence records comparator, epsilon, and delta")
    func comparisonEvidenceIsComplete() {
        let evidence = SagaValueComparator.evidence(
            observed: .double(0.699), desired: .double(0.7), op: .mixerSetVolume
        )
        #expect(evidence.comparator == .absoluteEpsilon)
        #expect(evidence.comparator.rawValue == "abs_eps")
        #expect(evidence.epsilon == 0.01)
        #expect(evidence.desired == .double(0.7))
        #expect(evidence.observed == .double(0.699))
        #expect(evidence.equal)
        let delta = try? #require(evidence.delta)
        #expect(abs((delta ?? 1) - 0.001) < 1e-9)

        // Exact comparators carry no epsilon, and string fields carry no delta.
        let exact = SagaValueComparator.evidence(
            observed: .string("A "), desired: .string("A"), op: .tracksRename
        )
        #expect(exact.comparator == .exact)
        #expect(exact.epsilon == nil)
        #expect(exact.delta == nil)
        #expect(!exact.equal)
    }

    // MARK: - Engine: classification through the comparator

    /// The headline regression: a State-B write whose live readback is one
    /// detent off the request is APPLIED, not `notApplied`. Pre-fix, exact `==`
    /// classified it `notApplied` and rolled back a write that had landed.
    @Test("volume 0.7 written, live readback 0.699 classifies applied")
    func quantizedVolumeReadbackClassifiesApplied() async {
        #expect(await disposition(
            .mixerSetVolume,
            desired: .double(0.7),
            before: .double(0.25),
            readback: .double(0.699),
            state: .stateB,
            key: "volume-quantized-applied"
        ) == .applied)
    }

    @Test("pan 0.5 readback 0.46 applies; 0.40 is beyond epsilon and did not apply")
    func panEpsilonDiscriminates() async {
        #expect(await disposition(
            .mixerSetPan,
            desired: .double(0.5),
            before: .double(0.40),
            readback: .double(0.46),
            state: .stateB,
            key: "pan-within-eps"
        ) == .applied)

        // Beyond epsilon AND equal to the before-state → the write did not land.
        #expect(await disposition(
            .mixerSetPan,
            desired: .double(0.5),
            before: .double(0.40),
            readback: .double(0.40),
            state: .stateB,
            key: "pan-beyond-eps"
        ) == .notApplied)
    }

    /// LPMCP-PRD-004: State A means the dispatcher ALREADY verified the write
    /// against the live surface. A later corroborating read that disagrees is
    /// drift we cannot explain — `unknown`. Demoting it to `notApplied` would
    /// roll back a verified write (the compensate-storm this closes).
    @Test("State A with a drifting corroborating read is unknown, never notApplied")
    func stateADriftIsUnknownNotNotApplied() async {
        let drifted = await disposition(
            .mixerSetVolume,
            desired: .double(0.7),
            before: .double(0.25),
            readback: .double(0.40),
            state: .stateA,
            key: "state-a-drift"
        )
        #expect(drifted == .unknown)
        #expect(drifted != .notApplied)

        // Drift all the way back to the before-state is STILL unknown under
        // State-A trust — the exact case the old `==` classified notApplied.
        let backToBefore = await disposition(
            .mixerSetVolume,
            desired: .double(0.7),
            before: .double(0.25),
            readback: .double(0.25),
            state: .stateA,
            key: "state-a-drift-to-before"
        )
        #expect(backToBefore == .unknown)
        #expect(backToBefore != .notApplied)
    }

    /// State-A trust does not depend on a corroborating read being available:
    /// the dispatcher's own live verification is sufficient.
    @Test("State A without a corroborating read stays applied")
    func stateAWithoutCorroborationStaysApplied() async {
        #expect(await disposition(
            .mixerSetVolume,
            desired: .double(0.7),
            before: .double(0.25),
            readback: nil,
            state: .stateA,
            key: "state-a-no-corroboration"
        ) == .applied)
    }

    /// State A + a corroborating read within epsilon is the ordinary path.
    @Test("State A with a quantized corroborating read stays applied")
    func stateAWithQuantizedCorroborationStaysApplied() async {
        #expect(await disposition(
            .mixerSetVolume,
            desired: .double(0.7),
            before: .double(0.25),
            readback: .double(0.699),
            state: .stateA,
            key: "state-a-quantized"
        ) == .applied)
    }

    /// A State-B rename whose readback differs only by a trailing space did NOT
    /// apply — no epsilon exists to absorb it.
    @Test("rename readback with a trailing space does not classify applied")
    func renameTrailingSpaceIsNotApplied() async {
        let result = await disposition(
            .tracksRename,
            desired: .string("A"),
            before: .string("Bass"),
            readback: .string("A "),
            state: .stateB,
            key: "rename-trailing-space"
        )
        #expect(result != .applied)
        #expect(result == .unknown)
    }

    @Test("verification evidence carries the comparator that decided it")
    func verificationEvidenceCarriesComparator() async throws {
        let registry = TargetRegistry()
        let target = await bind(registry, index: 0, name: "Bass")
        let executor = StubReadbackExecutor(
            before: .double(0.25),
            readback: .double(0.699),
            result: StepResult(state: .stateB, writeBoundaryCrossed: true, detail: "stub B")
        )
        let outcome = await MutationSaga(
            targetRegistry: registry,
            enabled: true,
            routeAvailable: { _ in true }
        ).execute(
            SagaPlan(
                steps: [step(.mixerSetVolume, target: target, value: .double(0.7))],
                idempotencyKey: "verification-comparator-evidence"
            ),
            executor: executor
        )
        let comparison = try #require(outcome.journal.first?.verificationEvidence?.comparison)
        #expect(comparison.comparator == .absoluteEpsilon)
        #expect(comparison.epsilon == 0.01)
        #expect(comparison.desired == .double(0.7))
        #expect(comparison.observed == .double(0.699))
        #expect(comparison.equal)
    }
}
