struct MIDIProviderQualification: Codable, Equatable, Sendable {
    let provenance: MIDIReadbackProvenance
    let qualified: Bool
    let requiredProofs: [String]
}

struct QualifiedProviderRegistry: Sendable {
    private let candidates: [MIDIProviderQualification]

    init() {
        candidates = Self.unqualifiedCandidates
    }

    func publicProvider() -> MIDIReadbackProvenance? {
        candidates.first { $0.qualified }?.provenance
    }

    func candidateProvenances() -> [MIDIReadbackProvenance] {
        candidates.map(\.provenance)
    }

    func qualificationStatuses() -> [MIDIProviderQualification] {
        candidates
    }

    private static let unqualifiedCandidates = [
        MIDIProviderQualification(
            provenance: .eventListAX,
            qualified: false,
            requiredProofs: [
                "selected region identity",
                "first and last row plus count/end completeness",
                "Event List filter verification",
                "English and Korean locale coverage",
                "Desktop and Creator variant coverage",
                "Logic version drift detection",
            ]
        ),
        MIDIProviderQualification(
            provenance: .controlledSMFExport,
            qualified: false,
            requiredProofs: [
                "selected region identity",
                "random private temporary destination",
                "symlink and traversal rejection",
                "export UI mutation restoration",
                "complete SMF parse",
                "Logic version drift detection",
            ]
        ),
        MIDIProviderQualification(
            provenance: .projectPackageParser,
            qualified: false,
            requiredProofs: [
                "project format stability spike",
                "selected region identity",
                "complete note extraction",
                "cross-version drift detection",
            ]
        ),
        MIDIProviderQualification(
            provenance: .playbackCapture,
            qualified: false,
            requiredProofs: [
                "selected region playback identity",
                "capture completeness",
                "documented secondary-provenance limitation",
                "proof that rendered behavior is not claimed as original region data",
            ]
        ),
    ]
}
