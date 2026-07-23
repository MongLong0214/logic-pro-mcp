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

    @Test func correlatedConversionRejected() {
        let snap = assessReadback(Self.evidence())
        // Spoof: expected sequence claiming the SAME conversion provenance as the
        // observed snapshot must fail-closed.
        let verdict = verifyRegion(
            observed: snap,
            expected: ExpectedSequence(
                notes: snap.notes, ppq: snap.ppq,
                provenance: .provenExternalArtifact(
                    sourceID: MIDIRegionNoteSnapshot.eventListConversionID,
                    contentBinding: expectedContentBinding(
                        sourceID: MIDIRegionNoteSnapshot.eventListConversionID,
                        notes: snap.notes, ppq: snap.ppq
                    )
                )
            )
        )
        guard case .incompleteCannotVerify = verdict else {
            Issue.record("Expected incompleteCannotVerify for correlated conversion provenance")
            return
        }
    }

    @Test func unprovenExpectedProvenanceRejected() {
        let snap = assessReadback(Self.evidence())
        // A free label cannot stand in for independence: without a proven
        // external artifact the expected sequence is unusable, not a pass.
        let verdict = verifyRegion(
            observed: snap,
            expected: ExpectedSequence(notes: snap.notes, ppq: snap.ppq, provenance: .unproven)
        )
        guard case .incompleteCannotVerify = verdict else {
            Issue.record("Expected incompleteCannotVerify for unproven expected provenance")
            return
        }
    }

    @Test func independentProvenanceMatchAccepted() {
        let snap = assessReadback(Self.evidence())
        // An independently-sourced expected sequence (different provenance) that
        // matches the observed notes verifies as an exact match.
        let verdict = verifyRegion(
            observed: snap,
            expected: ExpectedSequence(
                notes: snap.notes, ppq: snap.ppq,
                provenance: .provenExternalArtifact(
                    sourceID: "external.user-provided",
                    contentBinding: expectedContentBinding(
                        sourceID: "external.user-provided", notes: snap.notes, ppq: snap.ppq
                    )
                )
            )
        )
        #expect(verdict == .exactMatch)
    }

    @Test func transferredProofRejected() {
        let snap = assessReadback(Self.evidence())
        // A proof minted for a DIFFERENT payload (bound to an empty note set)
        // cannot be transferred to relabel the observed notes.
        let verdict = verifyRegion(
            observed: snap,
            expected: ExpectedSequence(
                notes: snap.notes, ppq: snap.ppq,
                provenance: .provenExternalArtifact(
                    sourceID: "external.user-provided",
                    contentBinding: expectedContentBinding(
                        sourceID: "external.user-provided", notes: [], ppq: snap.ppq
                    )
                )
            )
        )
        guard case .incompleteCannotVerify = verdict else {
            Issue.record("Expected incompleteCannotVerify for a transferred (mis-bound) proof")
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

    // MARK: gate-simulation follow-ups (payload binding, overflow, swap, span)

    @Test func ppqScaleOverflowRejected() {
        let snap = assessReadback(Self.evidence())
        let hugeNote = MIDINoteEvent(
            pitch: 60, startTicks: Int64.max, durationTicks: 1, velocity: 100, channel: 1
        )
        let sourceID = "external.user-provided"
        // Scaling from ppq 1 to 480 multiplies startTicks by 480 → Int64 overflow
        // → normalization must fail closed, never fall back to unscaled ticks.
        let expected = ExpectedSequence(
            notes: [hugeNote], ppq: 1,
            provenance: .provenExternalArtifact(
                sourceID: sourceID,
                contentBinding: expectedContentBinding(sourceID: sourceID, notes: [hugeNote], ppq: 1)
            )
        )
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
