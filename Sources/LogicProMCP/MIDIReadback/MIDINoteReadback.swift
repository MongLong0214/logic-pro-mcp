import Foundation

enum MIDIReadbackProvenance: String, Codable, Equatable, Sendable {
    case eventListAX
    case controlledSMFExport
    case projectPackageParser
    case playbackCapture
    case none
}

struct MIDIRegionReference: Codable, Hashable, Sendable {
    let targetRef: TargetReference
    let regionIndex: Int?
}

struct ReadbackContext: Sendable {
    let localeIdentifier: String?
    let viewIdentifier: String?

    init(localeIdentifier: String? = nil, viewIdentifier: String? = nil) {
        self.localeIdentifier = localeIdentifier
        self.viewIdentifier = viewIdentifier
    }
}

struct MIDINoteEvent: Codable, Equatable, Sendable {
    let pitch: UInt8
    let startTicks: Int64
    let durationTicks: Int64
    let velocity: UInt8
    let channel: UInt8
}

struct TempoEvent: Codable, Equatable, Sendable {
    let tick: Int64
    let beatsPerMinute: Double
}

struct TimeSignatureEvent: Codable, Equatable, Sendable {
    let tick: Int64
    let numerator: Int
    let denominator: Int
}

/// Deterministic digest binding a note payload to its PPQ. Integer fields cannot
/// contain the `;`/`,`/`|` separators, so the encoding is unambiguous. Used to
/// seal a completeness or independence proof to the exact notes it certifies.
func midiRegionNoteDigest(_ notes: [MIDINoteEvent], ppq: Int) -> String {
    let body = notes
        .map { "\($0.pitch),\($0.startTicks),\($0.durationTicks),\($0.velocity),\($0.channel)" }
        .joined(separator: ";")
    return "ppq=\(ppq)|\(body)"
}

/// Deterministic digest binding a completeness proof to BOTH the note payload
/// (PPQ + notes) AND the snapshot identity it certifies: the region, project
/// epoch, provenance, and conversion pipeline. `MIDIRegionNoteSnapshot.complete`
/// recomputes this from the snapshot's OWN fields, so a proof minted for one
/// snapshot cannot be transplanted onto a foreign envelope (a different region,
/// epoch, provenance, or pipeline id — e.g. relabeling the pipeline to defeat the
/// verifier's independence check) and still read complete. The two free-text
/// fields (region raw value, pipeline id) are length-prefixed with their byte
/// count so a crafted value cannot inject a delimiter and forge a colliding
/// digest for a different identity tuple.
func midiSnapshotCompletenessBinding(
    regionReference: MIDIRegionReference,
    projectEpoch: UInt64,
    provenance: MIDIReadbackProvenance,
    conversionPipelineID: String,
    notes: [MIDINoteEvent],
    ppq: Int
) -> String {
    let region = regionReference.targetRef.rawValue
    let regionIndex = regionReference.regionIndex.map(String.init) ?? "nil"
    return "region=\(region.utf8.count):\(region)"
        + "|idx=\(regionIndex)"
        + "|epoch=\(projectEpoch)"
        + "|prov=\(provenance.rawValue)"
        + "|pipe=\(conversionPipelineID.utf8.count):\(conversionPipelineID)"
        + "|" + midiRegionNoteDigest(notes, ppq: ppq)
}

struct MIDIRegionNoteSnapshot: Codable, Equatable, Sendable {
    /// Identifies the conversion that produced `notes`, so a verifier can require
    /// the expected sequence to carry a DIFFERENT provenance — a re-derived
    /// expected sharing this conversion's bugs cannot yield a false match.
    static let eventListConversionID = "eventListAX.readback.v1"

    let regionReference: MIDIRegionReference
    let projectEpoch: UInt64
    /// Note-list completeness. A `.complete` verdict can be minted ONLY by
    /// `assessReadback` (see MIDIReadbackAssessment.swift); a completeness-gated
    /// `diffRegions` is its only consumer in this rollout.
    let noteCompleteness: CompletenessVerdict
    /// Tempo and time-signature completeness are SEPARATE dimensions. This core
    /// leaves both maps unpopulated and marks them incomplete, so an empty map is
    /// never mistaken for a proven-empty one; their own dimensions gate their
    /// (future) consumers.
    let tempoMapCompleteness: CompletenessVerdict
    let timeSignatureCompleteness: CompletenessVerdict
    let conversionPipelineID: String
    let provenance: MIDIReadbackProvenance
    let ppq: Int
    let notes: [MIDINoteEvent]
    let tempoMap: [TempoEvent]
    let timeSignatures: [TimeSignatureEvent]

    /// Complete ONLY if the completeness proof is bound to THIS snapshot's exact
    /// notes+PPQ AND its identity (region, epoch, provenance, pipeline) — so a
    /// proof can be re-paired with neither foreign notes nor a foreign envelope.
    var complete: Bool {
        guard case let .complete(proof) = noteCompleteness else { return false }
        return proof.contentBinding == midiSnapshotCompletenessBinding(
            regionReference: regionReference,
            projectEpoch: projectEpoch,
            provenance: provenance,
            conversionPipelineID: conversionPipelineID,
            notes: notes,
            ppq: ppq
        )
    }
    var partialReason: String? { noteCompleteness.partialReason.map { String(describing: $0) } }

    init(
        regionReference: MIDIRegionReference,
        projectEpoch: UInt64,
        noteCompleteness: CompletenessVerdict,
        provenance: MIDIReadbackProvenance,
        ppq: Int,
        notes: [MIDINoteEvent],
        tempoMap: [TempoEvent],
        timeSignatures: [TimeSignatureEvent],
        tempoMapCompleteness: CompletenessVerdict = .incomplete(.mapsUnpopulated),
        timeSignatureCompleteness: CompletenessVerdict = .incomplete(.mapsUnpopulated),
        conversionPipelineID: String = MIDIRegionNoteSnapshot.eventListConversionID
    ) {
        self.regionReference = regionReference
        self.projectEpoch = projectEpoch
        self.noteCompleteness = noteCompleteness
        self.tempoMapCompleteness = tempoMapCompleteness
        self.timeSignatureCompleteness = timeSignatureCompleteness
        self.conversionPipelineID = conversionPipelineID
        self.provenance = provenance
        self.ppq = ppq
        self.notes = notes
        self.tempoMap = tempoMap
        self.timeSignatures = timeSignatures
    }

    // Codable is display/wire only. A decoded snapshot is untrusted by
    // construction: all completeness dimensions are forced to `.incomplete` so a
    // rehydrated payload can never drive a State-A match. `CompletenessVerdict`
    // has no Codable conformance, so completeness cannot be re-hydrated.
    private enum CodingKeys: String, CodingKey {
        case regionReference, projectEpoch, complete, partialReason
        case conversionPipelineID, provenance, ppq, notes, tempoMap, timeSignatures
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(regionReference, forKey: .regionReference)
        try container.encode(projectEpoch, forKey: .projectEpoch)
        try container.encode(complete, forKey: .complete)
        try container.encodeIfPresent(partialReason, forKey: .partialReason)
        try container.encode(conversionPipelineID, forKey: .conversionPipelineID)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(ppq, forKey: .ppq)
        try container.encode(notes, forKey: .notes)
        try container.encode(tempoMap, forKey: .tempoMap)
        try container.encode(timeSignatures, forKey: .timeSignatures)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regionReference: try values.decode(MIDIRegionReference.self, forKey: .regionReference),
            projectEpoch: try values.decode(UInt64.self, forKey: .projectEpoch),
            noteCompleteness: .incomplete(.decodedNotReassessed),
            provenance: try values.decode(MIDIReadbackProvenance.self, forKey: .provenance),
            ppq: try values.decode(Int.self, forKey: .ppq),
            notes: try values.decode([MIDINoteEvent].self, forKey: .notes),
            tempoMap: try values.decode([TempoEvent].self, forKey: .tempoMap),
            timeSignatures: try values.decode([TimeSignatureEvent].self, forKey: .timeSignatures),
            tempoMapCompleteness: .incomplete(.decodedNotReassessed),
            timeSignatureCompleteness: .incomplete(.decodedNotReassessed),
            conversionPipelineID: (try? values.decode(String.self, forKey: .conversionPipelineID))
                ?? MIDIRegionNoteSnapshot.eventListConversionID
        )
    }

    #if QUALIFICATION_FAULT_SEAM
    /// Test-only note-complete snapshot. Compiled solely under
    /// `QUALIFICATION_FAULT_SEAM` (debug); a release binary has no path to a
    /// `.complete` verdict. A test seam, not a security boundary.
    static func makeCompleteForTesting(
        regionReference: MIDIRegionReference,
        projectEpoch: UInt64,
        ppq: Int,
        notes: [MIDINoteEvent],
        tempoMap: [TempoEvent] = [],
        timeSignatures: [TimeSignatureEvent] = [],
        provenance: MIDIReadbackProvenance = .eventListAX
    ) -> MIDIRegionNoteSnapshot {
        MIDIRegionNoteSnapshot(
            regionReference: regionReference,
            projectEpoch: projectEpoch,
            noteCompleteness: .complete(CompleteProof.makeForTesting(
                contentBinding: midiSnapshotCompletenessBinding(
                    regionReference: regionReference,
                    projectEpoch: projectEpoch,
                    provenance: provenance,
                    conversionPipelineID: MIDIRegionNoteSnapshot.eventListConversionID,
                    notes: notes,
                    ppq: ppq
                )
            )),
            provenance: provenance,
            ppq: ppq,
            notes: notes,
            tempoMap: tempoMap,
            timeSignatures: timeSignatures
        )
    }

    static func makeIncompleteForTesting(
        regionReference: MIDIRegionReference,
        projectEpoch: UInt64,
        ppq: Int,
        reason: PartialReason = .timingUnproven,
        provenance: MIDIReadbackProvenance = .eventListAX
    ) -> MIDIRegionNoteSnapshot {
        MIDIRegionNoteSnapshot(
            regionReference: regionReference,
            projectEpoch: projectEpoch,
            noteCompleteness: .incomplete(reason),
            provenance: provenance,
            ppq: ppq,
            notes: [],
            tempoMap: [],
            timeSignatures: []
        )
    }
    #endif
}

protocol MIDINoteReadbackProvider: Sendable {
    var provenance: MIDIReadbackProvenance { get }

    func readNotes(
        target: MIDIRegionReference,
        context: ReadbackContext
    ) async throws -> MIDIRegionNoteSnapshot
}
