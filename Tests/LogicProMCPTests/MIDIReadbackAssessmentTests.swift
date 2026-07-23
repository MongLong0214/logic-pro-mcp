import Foundation
import Testing
@testable import LogicProMCP

// Assessment tests. The whole suite depends on the debug-only
// `QUALIFICATION_FAULT_SEAM` proven proofs + registry mint, because a release
// build has NO way to construct a proven proof (that is precisely the absolute
// guarantee: production cannot reach `complete:true`). Under the seam we can mint
// proven proofs to exercise the happy path and, by removing exactly one gate at
// a time, assert each fail-closed branch (RED-on-removal).
#if QUALIFICATION_FAULT_SEAM
@Suite struct MIDIReadbackAssessmentTests {
    // MARK: fixture

    static let region = MIDIRegionReference(
        targetRef: TargetReference(rawValue: "trk_assess"),
        regionIndex: 0
    )
    static let identity = ResolvedRegionIdentity(name: "R1", ordinal: 0, startTick: 0)
    static let posCol = AXColumnID(id: "c3")
    static let chCol = AXColumnID(id: "c5")
    static let pitchCol = AXColumnID(id: "c6")
    static let velCol = AXColumnID(id: "c7")
    static let lenCol = AXColumnID(id: "c8")

    static func noteRow(
        pitch: Double = 60,
        velocity: String = "100",
        channel: Double = 1,
        position: [Double] = [1, 1, 1, 1],
        length: [Double] = [0, 1, 0, 0]
    ) -> RawEventRow {
        [
            posCol: RawCell(groupSliderValues: position),
            chCol: RawCell(sliderValue: channel),
            pitchCol: RawCell(sliderValue: pitch, valueDescription: "C3"),
            velCol: RawCell(valueDescription: velocity),
            lenCol: RawCell(groupSliderValues: length),
        ]
    }

    static func roles() -> [ColumnRole: AXColumnID] {
        [.position: posCol, .channel: chCol, .pitch: pitchCol, .velocity: velCol, .length: lenCol]
    }

    /// The complete, well-formed filter control set (all note events visible, no
    /// scoping filter). Individual tests override one control to exercise a case.
    static func completeFilter(
        noteEvents: Bool = true, channel: Bool = false, scope: Bool = false, takeFolder: Bool = false
    ) -> FilterEvidence {
        FilterEvidence(checkboxes: [
            .init(id: "noteEvents", checked: noteEvents),
            .init(id: "channel", checked: channel),
            .init(id: "scope", checked: scope),
            .init(id: "takeFolder", checked: takeFolder),
        ])
    }

    /// Fully-proven single-note evidence; every argument overridable so a test
    /// can knock out exactly one gate.
    static func evidence(
        requestedRegion: MIDIRegionReference = region,
        resolved: RegistryResolvedIdentityProof? = nil,
        observed: ObservedRegionIdentityProof = .proven(identity),
        epochBefore: UInt64 = 1,
        epochAfter: UInt64 = 1,
        ppq: Int = 480,
        binding: ColumnBinding = .headerIdentity(.proven(roles())),
        filter: FilterEvidence = MIDIReadbackAssessmentTests.completeFilter(),
        countText: String = "1 Events",
        countProof: CountSemanticsProof = .provenAllEventsInRegion,
        keys: [RowKey] = [RowKey(index: 0)],
        passA: [RowKey: RawEventRow] = [RowKey(index: 0): noteRow()],
        passB: [RowKey: RawEventRow]? = nil,
        exhaustion: HarvestExhaustionProof = .proven,
        timing: TimingEvidence = .proven,
        calibration: CalibrationTriple? = CalibrationTriple(pitch: 60, velocity: 100, startTickValue: 1)
    ) -> EventListReadbackEvidence {
        EventListReadbackEvidence(
            requestedRegion: requestedRegion,
            resolvedIdentity: resolved ?? RegionIdentityRegistrySeam.mint(boundRegion: region, identity: identity),
            observedRegion: observed,
            projectEpochBefore: epochBefore,
            projectEpochAfter: epochAfter,
            ppq: ppq,
            columnBinding: binding,
            filter: filter,
            itemCount: ItemCountEvidence(rawCountText: countText, semanticsProof: countProof),
            harvest: RowHarvest(
                orderedRowKeys: keys,
                passA: passA,
                passB: passB ?? passA,
                exhaustion: exhaustion
            ),
            timing: timing,
            calibration: calibration
        )
    }

    // MARK: happy paths

    @Test func fullyProvenEvidenceIsComplete() {
        let snap = assessReadback(Self.evidence())
        #expect(snap.complete)
        #expect(snap.notes.count == 1)
        #expect(snap.notes.first?.pitch == 60)
        #expect(snap.notes.first?.velocity == 100)
        #expect(snap.notes.first?.channel == 1)
    }

    @Test func verifiedEmptyIsComplete() {
        let snap = assessReadback(Self.evidence(
            countText: "0 Events",
            keys: [],
            passA: [:]
        ))
        #expect(snap.complete)
        #expect(snap.notes.isEmpty)
    }

    // MARK: absolute guarantee — no proven proof ⇒ never complete

    @Test func unprovenObservedRegionCannotComplete() {
        let snap = assessReadback(Self.evidence(observed: .unproven))
        #expect(!snap.complete)
        #expect(snap.noteCompleteness.partialReason == .wrongRegion)
    }

    @Test func unprovenTimingCannotComplete() {
        let snap = assessReadback(Self.evidence(timing: .unproven))
        #expect(!snap.complete)
        #expect(snap.noteCompleteness.partialReason == .timingUnproven)
    }

    @Test func unprovenExhaustionCannotComplete() {
        let snap = assessReadback(Self.evidence(exhaustion: .unproven))
        #expect(!snap.complete)
        #expect(snap.noteCompleteness.partialReason == .harvestNotExhaustive)
    }

    @Test func unprovenCountSemanticsCannotComplete() {
        let snap = assessReadback(Self.evidence(countProof: .unproven))
        #expect(!snap.complete)
        #expect(snap.noteCompleteness.partialReason == .countIndependenceUnproven)
    }

    @Test func unresolvedColumnsCannotComplete() {
        let snap = assessReadback(Self.evidence(binding: .unresolved))
        #expect(!snap.complete)
        #expect(snap.noteCompleteness.partialReason == .columnUnresolved)
    }

    @Test func unprovenHeaderIdentityCannotComplete() {
        let snap = assessReadback(Self.evidence(binding: .headerIdentity(.unproven)))
        #expect(!snap.complete)
        #expect(snap.noteCompleteness.partialReason == .columnUnresolved)
    }

    // MARK: per-predicate RED-on-removal

    @Test func unboundIdentityRejected() {
        let otherRegion = MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_other"), regionIndex: 9
        )
        let forged = RegionIdentityRegistrySeam.mint(boundRegion: otherRegion, identity: Self.identity)
        let snap = assessReadback(Self.evidence(resolved: forged))
        #expect(snap.noteCompleteness.partialReason == .unboundIdentity)
    }

    @Test func mismatchedObservedIdentityRejected() {
        let snap = assessReadback(Self.evidence(
            observed: .proven(ResolvedRegionIdentity(name: "DIFFERENT", ordinal: 0, startTick: 0))
        ))
        #expect(snap.noteCompleteness.partialReason == .wrongRegion)
    }

    @Test func filterHidingNotesRejected() {
        let snap = assessReadback(Self.evidence(filter: Self.completeFilter(noteEvents: false)))
        #expect(snap.noteCompleteness.partialReason == .filterNotAllNotes)
    }

    @Test func scopeFilterActiveRejected() {
        let snap = assessReadback(Self.evidence(filter: Self.completeFilter(scope: true)))
        #expect(snap.noteCompleteness.partialReason == .filterNotAllNotes)
    }

    @Test func filterMissingControlRejected() {
        let snap = assessReadback(Self.evidence(filter: FilterEvidence(checkboxes: [
            .init(id: "noteEvents", checked: true),
            .init(id: "channel", checked: false),
            .init(id: "scope", checked: false),
            // takeFolder omitted → incomplete
        ])))
        #expect(snap.noteCompleteness.partialReason == .filterEvidenceIncomplete)
    }

    @Test func filterDuplicateControlRejected() {
        let snap = assessReadback(Self.evidence(filter: FilterEvidence(checkboxes: [
            .init(id: "noteEvents", checked: true),
            .init(id: "noteEvents", checked: true),
            .init(id: "channel", checked: false),
            .init(id: "scope", checked: false),
            .init(id: "takeFolder", checked: false),
        ])))
        #expect(snap.noteCompleteness.partialReason == .filterEvidenceIncomplete)
    }

    @Test func filterUnknownControlRejected() {
        let snap = assessReadback(Self.evidence(filter: FilterEvidence(checkboxes: [
            .init(id: "noteEvents", checked: true),
            .init(id: "channel", checked: false),
            .init(id: "scope", checked: false),
            .init(id: "takeFolder", checked: false),
            .init(id: "mysteryControl", checked: false),
        ])))
        #expect(snap.noteCompleteness.partialReason == .filterEvidenceIncomplete)
    }

    @Test func invalidPPQRejected() {
        let snap = assessReadback(Self.evidence(ppq: 0))
        #expect(snap.noteCompleteness.partialReason == .invalidPPQ)
    }

    @Test func calibrationNotDistinctRejected() {
        let snap = assessReadback(Self.evidence(
            calibration: CalibrationTriple(pitch: 60, velocity: 60, startTickValue: 1)
        ))
        #expect(snap.noteCompleteness.partialReason == .calibrationNotDistinct)
    }

    @Test func fractionalPitchRejected() {
        guard case .rowParseFailed = rowParseOutcome(bad: Self.noteRow(pitch: 60.5)) else {
            Issue.record("Expected rowParseFailed for fractional pitch")
            return
        }
    }

    @Test func nonFinitePitchRejected() {
        guard case .rowParseFailed = rowParseOutcome(bad: Self.noteRow(pitch: .infinity)) else {
            Issue.record("Expected rowParseFailed for non-finite pitch")
            return
        }
    }

    @Test func mapDimensionsAreUnpopulated() {
        let snap = assessReadback(Self.evidence())
        #expect(snap.complete)
        #expect(snap.tempoMapCompleteness == .incomplete(.mapsUnpopulated))
        #expect(snap.timeSignatureCompleteness == .incomplete(.mapsUnpopulated))
    }

    // MARK: independence contract (ingestion-minted opaque proof; match deferred)

    private static let sampleNote = MIDINoteEvent(
        pitch: 60, startTicks: 0, durationTicks: 120, velocity: 100, channel: 1
    )
    private func observedSnapshot() -> MIDIRegionNoteSnapshot { assessReadback(Self.evidence()) }

    @Test func samePipelineArtifactRejectedAtMint() {
        // An artifact claiming the observed conversion pipeline id is refused at
        // the MINT (fail-closed), not merely at verify.
        if ExternalArtifactIngestion.ingest(
            artifactID: MIDIRegionNoteSnapshot.eventListConversionID,
            rawArtifact: ExternalArtifactIngestion.encode([Self.sampleNote], ppq: 480)
        ) != nil {
            Issue.record("Ingesting under the observed pipeline id must be rejected at mint")
        }
    }

    @Test func ingestRejectsEmptyArtifactID() {
        if ExternalArtifactIngestion.ingest(
            artifactID: "",
            rawArtifact: ExternalArtifactIngestion.encode([Self.sampleNote], ppq: 480)
        ) != nil {
            Issue.record("Ingesting with an empty artifact id must be rejected at mint")
        }
    }

    @Test func unprovenExpectedProvenanceRejected() {
        let snap = observedSnapshot()
        // A caller-presented sequence with no proof is unusable, not a pass.
        guard case .incompleteCannotVerify = verifyRegion(
            observed: snap,
            expected: ExpectedSequence(notes: snap.notes, ppq: snap.ppq)
        ) else {
            Issue.record("Expected incompleteCannotVerify for unproven expected provenance")
            return
        }
    }

    @Test func publicInitCannotCarryProvenProvenance() {
        // The public initializer is unproven-only (no provenance parameter), so a
        // caller cannot pair a proof with foreign notes — no dual source of truth.
        guard case .unproven = ExpectedSequence(notes: [Self.sampleNote], ppq: 480).provenance else {
            Issue.record("Public ExpectedSequence init must yield .unproven")
            return
        }
    }

    @Test func observedNotesPlusArbitraryLabelNeverExactMatch() {
        // RED-on-removal guard: serialize the observed notes and ingest them under
        // ANY label (≠ pipeline) — still no `.exactMatch`. A would-be match is
        // DEFERRED; re-enabling the exactMatch path turns this red.
        let snap = observedSnapshot()
        let forged = ExternalArtifactIngestion.ingest(
            artifactID: "attacker.chosen.label",
            rawArtifact: ExternalArtifactIngestion.encode(snap.notes, ppq: snap.ppq)
        )!
        let verdict = verifyRegion(observed: snap, expected: forged)
        if verdict == .exactMatch {
            Issue.record("Observed-note laundering under an arbitrary label must never exactMatch")
        }
        guard case .incompleteCannotVerify = verdict else {
            Issue.record("A would-be match must be deferred (incompleteCannotVerify), got \(verdict)")
            return
        }
    }

    @Test func foreignArtifactNotesYieldMismatch() {
        // The proof carries its OWN artifact-decoded notes; verify compares the
        // observed notes against those. Foreign notes (≠ observed) → mismatch,
        // never a false positive.
        let snap = observedSnapshot()
        let foreign = ExternalArtifactIngestion.ingest(
            artifactID: "external.user-provided",
            rawArtifact: ExternalArtifactIngestion.encode(
                [MIDINoteEvent(pitch: 99, startTicks: 0, durationTicks: 120, velocity: 100, channel: 1)],
                ppq: snap.ppq
            )
        )!
        guard case .mismatch = verifyRegion(observed: snap, expected: foreign) else {
            Issue.record("Foreign artifact notes must yield a structured mismatch")
            return
        }
    }

    @Test func ingestRejectsMalformedArtifact() {
        if ExternalArtifactIngestion.ingest(artifactID: "a", rawArtifact: [0x01, 0x02]) != nil {
            Issue.record("Malformed artifact bytes must be rejected")
        }
    }

    @Test func ingestRejectsTrailingBytes() {
        var bytes = ExternalArtifactIngestion.encode([Self.sampleNote], ppq: 480)
        bytes.append(0x00)
        if ExternalArtifactIngestion.ingest(artifactID: "a", rawArtifact: bytes) != nil {
            Issue.record("Trailing bytes after the record body must be rejected")
        }
    }

    @Test func ingestRejectsTruncatedRecord() {
        var bytes = ExternalArtifactIngestion.encode([Self.sampleNote], ppq: 480)
        bytes.removeLast()
        if ExternalArtifactIngestion.ingest(artifactID: "a", rawArtifact: bytes) != nil {
            Issue.record("A truncated record must be rejected")
        }
    }

    @Test func ingestRejectsOverflowingCount() {
        // Header claims 0xFFFFFFFF records but the body is empty → length mismatch.
        var bytes = ExternalArtifactIngestion.encode([], ppq: 480)
        bytes[8] = 0xFF; bytes[9] = 0xFF; bytes[10] = 0xFF; bytes[11] = 0xFF
        if ExternalArtifactIngestion.ingest(artifactID: "a", rawArtifact: bytes) != nil {
            Issue.record("An overflowing/oversized record count must be rejected")
        }
    }

    @Test func artifactEmbeddedPPQFlowsThroughVerification() {
        // PPQ is decoded from the artifact bytes, not caller-supplied: an artifact
        // and observed snapshot both at ppq 960 with the same notes is a would-be
        // match (deferred), proving the embedded ppq is what drives verification.
        let notes = [MIDINoteEvent(pitch: 60, startTicks: 960, durationTicks: 480, velocity: 100, channel: 1)]
        let observed = MIDIRegionNoteSnapshot.makeCompleteForTesting(
            regionReference: Self.region, projectEpoch: 1, ppq: 960, notes: notes
        )
        let artifact = ExternalArtifactIngestion.ingest(
            artifactID: "external.user-provided",
            rawArtifact: ExternalArtifactIngestion.encode(notes, ppq: 960)
        )!
        guard case .incompleteCannotVerify = verifyRegion(observed: observed, expected: artifact) else {
            Issue.record("Artifact-embedded ppq should drive a would-be match (deferred)")
            return
        }
    }

    @Test func countMismatchRejected() {
        let snap = assessReadback(Self.evidence(countText: "2 Events"))
        #expect(snap.noteCompleteness.partialReason == .countMismatch)
    }

    @Test func epochChangeRejected() {
        let snap = assessReadback(Self.evidence(epochBefore: 1, epochAfter: 2))
        #expect(snap.noteCompleteness.partialReason == .epochChanged)
    }

    @Test func harvestGapRejected() {
        let rowA = Self.noteRow()
        let snap = assessReadback(Self.evidence(
            countText: "2 Events",
            keys: [RowKey(index: 0), RowKey(index: 2)],
            passA: [RowKey(index: 0): rowA, RowKey(index: 2): rowA]
        ))
        #expect(snap.noteCompleteness.partialReason == .harvestNotContiguous)
    }

    @Test func harvestContentInstabilityRejected() {
        let rowA = Self.noteRow(pitch: 60)
        let rowB = Self.noteRow(pitch: 61)
        let snap = assessReadback(Self.evidence(
            passA: [RowKey(index: 0): rowA],
            passB: [RowKey(index: 0): rowB]
        ))
        #expect(snap.noteCompleteness.partialReason == .harvestContentUnstable)
    }

    // Row-parse tests use a two-row fixture: row 0 is a valid note that anchors
    // the calibration column binding, and row 1 carries the bad field — so the
    // failure is isolated to row parsing (not column resolution).
    private func rowParseOutcome(bad: RawEventRow) -> PartialReason? {
        let snap = assessReadback(Self.evidence(
            countText: "2 Events",
            keys: [RowKey(index: 0), RowKey(index: 1)],
            passA: [RowKey(index: 0): Self.noteRow(), RowKey(index: 1): bad]
        ))
        return snap.noteCompleteness.partialReason
    }

    @Test func outOfRangePitchRejected() {
        guard case .rowParseFailed = rowParseOutcome(bad: Self.noteRow(pitch: 200)) else {
            Issue.record("Expected rowParseFailed for out-of-range pitch")
            return
        }
    }

    @Test func nonNumericVelocityRejected() {
        guard case .rowParseFailed = rowParseOutcome(bad: Self.noteRow(velocity: "loud")) else {
            Issue.record("Expected rowParseFailed for non-numeric velocity")
            return
        }
    }

    @Test func zeroVelocityRejected() {
        guard case .rowParseFailed = rowParseOutcome(bad: Self.noteRow(velocity: "0")) else {
            Issue.record("Expected rowParseFailed for zero velocity")
            return
        }
    }

    // MARK: fail-closed hardening (channel required, no column aliasing, robust count)

    @Test func missingChannelColumnRejected() {
        var r = Self.roles()
        r[.channel] = nil
        let snap = assessReadback(Self.evidence(binding: .headerIdentity(.proven(r))))
        #expect(snap.noteCompleteness.partialReason == .columnUnresolved)
    }

    @Test func aliasedLengthColumnRejected() {
        var r = Self.roles()
        r[.length] = Self.posCol
        let snap = assessReadback(Self.evidence(binding: .headerIdentity(.proven(r))))
        #expect(snap.noteCompleteness.partialReason == .columnUnresolved)
    }

    @Test func missingChannelValueRejected() {
        var row = Self.noteRow()
        row[Self.chCol] = RawCell(sliderValue: nil)
        let snap = assessReadback(Self.evidence(passA: [RowKey(index: 0): row]))
        guard case .rowParseFailed = snap.noteCompleteness.partialReason else {
            Issue.record("Expected rowParseFailed for missing channel value")
            return
        }
    }

    @Test func groupedThousandsCountRejected() {
        // "1,234 Events" must parse as 1234, not truncate to 1 → mismatch with 1 row.
        let snap = assessReadback(Self.evidence(countText: "1,234 Events"))
        #expect(snap.noteCompleteness.partialReason == .countMismatch)
    }

    @Test func malformedCountRejected() {
        let snap = assessReadback(Self.evidence(countText: "12abc"))
        #expect(snap.noteCompleteness.partialReason == .countMismatch)
    }

    @Test func leadingCommaCountRejected() {
        let snap = assessReadback(Self.evidence(countText: ",5 Events"))
        #expect(snap.noteCompleteness.partialReason == .countMismatch)
    }

    @Test func spaceGroupedCountRejected() {
        // "1 234 Events" must not be truncated to "1" and spuriously match a
        // single harvested row.
        let snap = assessReadback(Self.evidence(countText: "1 234 Events"))
        #expect(snap.noteCompleteness.partialReason == .countMismatch)
    }

    @Test func verifiedEmptyRejectsIncompleteColumns() {
        var r = Self.roles()
        r[.length] = nil
        let snap = assessReadback(Self.evidence(
            binding: .headerIdentity(.proven(r)), countText: "0 Events", keys: [], passA: [:]
        ))
        #expect(snap.noteCompleteness.partialReason == .emptyNotProven)
    }

    // MARK: cell-shape XOR (a cell carries exactly one numeric shape for its role)

    @Test func dualPopulatedChannelCellRejected() {
        // A channel cell that ALSO carries a group shape is structurally ambiguous.
        // The group first-value (9) differs from the calibrated start (1) so column
        // resolution is unaffected — the failure is isolated to the parse guard.
        var bad = Self.noteRow()
        bad[Self.chCol] = RawCell(sliderValue: 1, groupSliderValues: [9, 9, 9, 9])
        expectRowParseFail(bad, "dual-populated channel cell (scalar + group)")
    }

    @Test func dualPopulatedLengthCellRejected() {
        var bad = Self.noteRow()
        bad[Self.lenCol] = RawCell(sliderValue: 5, groupSliderValues: [0, 1, 0, 0])
        expectRowParseFail(bad, "dual-populated length cell (group + scalar)")
    }

    @Test func dualPopulatedRoleSwapRejected() {
        // The full attack: channel and length cells each expose BOTH shapes and
        // their roles are swapped, so each swapped role would find a wrong-kind
        // value. Pitch/velocity/position calibration is kept honest, so column
        // resolution passes; the XOR invariant rejects the dual cells at parse.
        let swapped: [ColumnRole: AXColumnID] = [
            .position: Self.posCol, .pitch: Self.pitchCol, .velocity: Self.velCol,
            .channel: Self.lenCol, .length: Self.chCol,
        ]
        var row = Self.noteRow()
        row[Self.chCol] = RawCell(sliderValue: 1, groupSliderValues: [0, 1, 0, 0])
        row[Self.lenCol] = RawCell(sliderValue: 1, groupSliderValues: [0, 1, 0, 0])
        let snap = assessReadback(Self.evidence(
            binding: .headerIdentity(.proven(swapped)),
            passA: [RowKey(index: 0): row]
        ))
        guard case .incomplete = snap.noteCompleteness else {
            Issue.record("Dual-populated swapped channel/length cells must not complete")
            return
        }
    }

    // The XOR guard applies to every role, not just channel/length. The injected
    // off-shape value uses a group first-value (9) that differs from the calibrated
    // start (1), so column resolution is unaffected and the parse guard is isolated.
    @Test func dualPopulatedPitchCellRejected() {
        var bad = Self.noteRow()
        bad[Self.pitchCol] = RawCell(sliderValue: 60, valueDescription: "C3", groupSliderValues: [9, 9, 9, 9])
        expectRowParseFail(bad, "dual-populated pitch cell (scalar + group)")
    }

    @Test func dualPopulatedVelocityCellRejected() {
        var bad = Self.noteRow()
        bad[Self.velCol] = RawCell(valueDescription: "100", groupSliderValues: [9, 9, 9, 9])
        expectRowParseFail(bad, "dual-populated velocity cell (description + group)")
    }

    @Test func dualPopulatedPositionCellRejected() {
        var bad = Self.noteRow()
        bad[Self.posCol] = RawCell(sliderValue: 5, groupSliderValues: [1, 1, 1, 1])
        expectRowParseFail(bad, "dual-populated position cell (group + scalar)")
    }

    // MARK: numeric / tick boundary matrix (one RED per claimed boundary)

    private func expectRowParseFail(_ bad: RawEventRow, _ label: String) {
        guard case .rowParseFailed = rowParseOutcome(bad: bad) else {
            Issue.record("Expected rowParseFailed for \(label)")
            return
        }
    }

    @Test func fractionalChannelRejected() { expectRowParseFail(Self.noteRow(channel: 1.5), "fractional channel") }
    @Test func nonFiniteChannelRejected() { expectRowParseFail(Self.noteRow(channel: .infinity), "non-finite channel") }
    @Test func extremeChannelRejected() { expectRowParseFail(Self.noteRow(channel: 1.0e20), "extreme channel") }
    @Test func nonFinitePositionRejected() {
        expectRowParseFail(Self.noteRow(position: [.infinity, 0, 0, 0]), "non-finite position")
    }
    @Test func extremePositionRejected() {
        expectRowParseFail(Self.noteRow(position: [1.0e20, 0, 0, 0]), "extreme position")
    }
    @Test func fractionalPositionRejected() {
        expectRowParseFail(Self.noteRow(position: [1.5, 1, 1, 1]), "fractional position segment")
    }
    @Test func nonFiniteLengthRejected() {
        expectRowParseFail(Self.noteRow(length: [.nan, 1, 0, 0]), "non-finite length")
    }
    @Test func extremeLengthRejected() {
        expectRowParseFail(Self.noteRow(length: [1.0e20, 0, 0, 0]), "extreme length")
    }

    @Test func fractionalLengthRejected() {
        expectRowParseFail(Self.noteRow(length: [0, 1.5, 0, 0]), "fractional length segment")
    }
    @Test func tickSumOverflowRejected() {
        expectRowParseFail(Self.noteRow(position: [9.0e18, 9.0e18, 0, 0]), "tick-sum overflow")
    }

    @Test func tickSubtractionOverflowRejected() {
        // Region start at Int64.min makes every row's region-relative subtraction
        // overflow; the row must fail rather than trap.
        let minStart = ResolvedRegionIdentity(name: "R1", ordinal: 0, startTick: Int64.min)
        let snap = assessReadback(Self.evidence(
            resolved: RegionIdentityRegistrySeam.mint(boundRegion: Self.region, identity: minStart),
            observed: .proven(minStart)
        ))
        guard case .rowParseFailed = snap.noteCompleteness.partialReason else {
            Issue.record("Expected rowParseFailed for tick subtraction overflow")
            return
        }
    }

    @Test func doubleCommaCountRejected() {
        #expect(assessReadback(Self.evidence(countText: "1,,0 Events")).noteCompleteness.partialReason == .countMismatch)
    }
    @Test func trailingCommaCountRejected() {
        #expect(assessReadback(Self.evidence(countText: "10, Events")).noteCompleteness.partialReason == .countMismatch)
    }
    @Test func interiorBadGroupingCountRejected() {
        #expect(assessReadback(Self.evidence(countText: "1,00 Events")).noteCompleteness.partialReason == .countMismatch)
    }
    @Test func nbspGroupedCountRejected() {
        #expect(assessReadback(Self.evidence(countText: "1\u{00A0}234 Events")).noteCompleteness.partialReason == .countMismatch)
    }

    // MARK: correctness-hardening (payload binding, overflow, swap, span)

    @Test func ppqScaleOverflowRejected() {
        let snap = assessReadback(Self.evidence())
        let hugeNote = MIDINoteEvent(
            pitch: 60, startTicks: Int64.max, durationTicks: 1, velocity: 100, channel: 1
        )
        // Scaling from ppq 1 to 480 multiplies startTicks by 480 → Int64 overflow
        // → normalization must fail closed, never fall back to unscaled ticks.
        let expected = ExternalArtifactIngestion.ingest(
            artifactID: "external.user-provided",
            rawArtifact: ExternalArtifactIngestion.encode([hugeNote], ppq: 1)
        )!
        guard case .incompleteCannotVerify = verifyRegion(observed: snap, expected: expected) else {
            Issue.record("Expected incompleteCannotVerify for PPQ scale overflow")
            return
        }
    }

    @Test func tickPrecisionPreservedNear2p53() {
        // Position group [2^53, 1, 0, 0] must sum to 2^53 + 1 (Int64), not lose the
        // +1 (which a Double accumulator would).
        let twoTo53 = 9_007_199_254_740_992.0
        let snap = assessReadback(Self.evidence(
            passA: [RowKey(index: 0): Self.noteRow(position: [twoTo53, 1, 0, 0])],
            calibration: CalibrationTriple(pitch: 60, velocity: 100, startTickValue: twoTo53)
        ))
        #expect(snap.complete)
        #expect(snap.notes.first?.startTicks == 9_007_199_254_740_993)  // 2^53 + 1
    }

    @Test func channelLengthRoleSwapRejected() {
        var r = Self.roles()
        let ch = r[.channel]
        r[.channel] = r[.length]
        r[.length] = ch
        // channel role now points to the length (group) column → no single slider
        // value → the row fails to parse (structural pin), never completes wrong.
        let snap = assessReadback(Self.evidence(binding: .headerIdentity(.proven(r))))
        guard case .rowParseFailed = snap.noteCompleteness.partialReason else {
            Issue.record("Expected rowParseFailed for channel/length role swap")
            return
        }
    }

    @Test func harvestMidWindowRejected() {
        // A contiguous window NOT anchored at row 0 is not proven to be the full table.
        let snap = assessReadback(Self.evidence(
            keys: [RowKey(index: 5)],
            passA: [RowKey(index: 5): Self.noteRow()]
        ))
        #expect(snap.noteCompleteness.partialReason == .harvestNotContiguous)
    }

    // MARK: Codable is display-only — decode forces incomplete

    @Test func decodedSnapshotIsUntrustedIncomplete() throws {
        let complete = assessReadback(Self.evidence())
        #expect(complete.complete)
        let data = try JSONEncoder().encode(complete)
        let decoded = try JSONDecoder().decode(MIDIRegionNoteSnapshot.self, from: data)
        #expect(!decoded.complete)
        #expect(decoded.noteCompleteness.partialReason == .decodedNotReassessed)
    }
}
#endif
