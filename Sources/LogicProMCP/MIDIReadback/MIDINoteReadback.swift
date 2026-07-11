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
    let regionReference: MIDIRegionReference
    let projectEpoch: UInt64
    let complete: Bool
    let partialReason: String?
    let provenance: MIDIReadbackProvenance
    let ppq: Int
    let notes: [MIDINoteEvent]
    let tempoMap: [TempoEvent]
    let timeSignatures: [TimeSignatureEvent]

    init(
        regionReference: MIDIRegionReference,
        projectEpoch: UInt64,
        complete: Bool,
        partialReason: String?,
        provenance: MIDIReadbackProvenance,
        ppq: Int,
        notes: [MIDINoteEvent],
        tempoMap: [TempoEvent],
        timeSignatures: [TimeSignatureEvent]
    ) {
        self.regionReference = regionReference
        self.projectEpoch = projectEpoch
        self.complete = complete
        self.partialReason = complete ? nil : partialReason
        self.provenance = provenance
        self.ppq = ppq
        self.notes = notes
        self.tempoMap = tempoMap
        self.timeSignatures = timeSignatures
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            regionReference: try values.decode(MIDIRegionReference.self, forKey: .regionReference),
            projectEpoch: try values.decode(UInt64.self, forKey: .projectEpoch),
            complete: try values.decode(Bool.self, forKey: .complete),
            partialReason: try values.decodeIfPresent(String.self, forKey: .partialReason),
            provenance: try values.decode(MIDIReadbackProvenance.self, forKey: .provenance),
            ppq: try values.decode(Int.self, forKey: .ppq),
            notes: try values.decode([MIDINoteEvent].self, forKey: .notes),
            tempoMap: try values.decode([TempoEvent].self, forKey: .tempoMap),
            timeSignatures: try values.decode([TimeSignatureEvent].self, forKey: .timeSignatures)
        )
    }
}

protocol MIDINoteReadbackProvider: Sendable {
    var provenance: MIDIReadbackProvenance { get }

    func readNotes(
        target: MIDIRegionReference,
        context: ReadbackContext
    ) async throws -> MIDIRegionNoteSnapshot
}
