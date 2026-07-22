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

struct MIDIRegionNoteSnapshot: Codable, Equatable, Sendable {
    /// Identifies the conversion that produced `notes`, so a verifier can require
    /// the expected sequence to carry a DIFFERENT provenance — a re-derived
    /// expected sharing this conversion's bugs cannot yield a false match.
    static let eventListConversionID = "eventListAX.assessReadback.v1"

    let regionReference: MIDIRegionReference
    let projectEpoch: UInt64
    /// Note-list completeness — the only dimension `verifyRegion` consumes. A
    /// `.complete` verdict can be minted ONLY by `assessReadback` (see
    /// MIDIReadbackAssessment.swift).
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

    var complete: Bool { noteCompleteness.isComplete }
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
            noteCompleteness: .complete(CompleteProof.makeForTesting()),
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
