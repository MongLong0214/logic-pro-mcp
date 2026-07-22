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

    static func noteRow(pitch: Double = 60, velocity: String = "100", channel: Double = 1) -> RawEventRow {
        [
            posCol: RawCell(groupSliderValues: [1, 1, 1, 1]),
            chCol: RawCell(sliderValue: channel),
            pitchCol: RawCell(sliderValue: pitch, valueDescription: "C3"),
            velCol: RawCell(valueDescription: velocity),
            lenCol: RawCell(groupSliderValues: [0, 1, 0, 0]),
        ]
    }

    static func roles() -> [ColumnRole: AXColumnID] {
        [.position: posCol, .channel: chCol, .pitch: pitchCol, .velocity: velCol, .length: lenCol]
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
        filter: FilterEvidence = FilterEvidence(checkboxes: [.init(id: "notes", checked: true)]),
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
        let snap = assessReadback(Self.evidence(
            filter: FilterEvidence(checkboxes: [.init(id: "notes", checked: false)])
        ))
        #expect(snap.noteCompleteness.partialReason == .filterNotAllNotes)
    }

    @Test func scopeFilterActiveRejected() {
        let snap = assessReadback(Self.evidence(
            filter: FilterEvidence(checkboxes: [
                .init(id: "notes", checked: true),
                .init(id: "channelScope", checked: true),
            ])
        ))
        #expect(snap.noteCompleteness.partialReason == .filterNotAllNotes)
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
