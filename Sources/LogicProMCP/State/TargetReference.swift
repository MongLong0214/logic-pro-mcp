import Foundation

struct TargetReference: Codable, Hashable, Sendable {
    let rawValue: String
}

enum TargetKind: String, Codable, Sendable {
    case project
    case track
    case mixerStrip
    case pluginInsert

    fileprivate var referencePrefix: String {
        switch self {
        case .project: "prj"
        case .track: "trk"
        case .mixerStrip: "mix"
        case .pluginInsert: "ins"
        }
    }
}

struct TargetDescriptor: Hashable, Sendable {
    let trackIndex: Int
    let trackName: String

    var fingerprint: String {
        "\(trackIndex):\(trackName.utf8.count):\(trackName)"
    }
}

struct TargetBinding: Sendable {
    let reference: TargetReference
    let kind: TargetKind
    let serverSessionID: UUID
    let projectEpoch: UInt64
    let topologyGeneration: UInt64
    let descriptor: TargetDescriptor
    let observedFingerprint: String
    let createdAt: ContinuousClock.Instant
}

actor TargetRegistry {
    private let serverSessionID: UUID
    private var projectEpoch: UInt64 = 0
    private var topologyGeneration: UInt64 = 0
    private var bindings: [TargetReference: TargetBinding] = [:]

    init(serverSessionID: UUID = UUID()) {
        self.serverSessionID = serverSessionID
    }

    var currentProjectEpoch: UInt64 { projectEpoch }
    var currentTopologyGeneration: UInt64 { topologyGeneration }

    func bind(
        kind: TargetKind,
        descriptor: TargetDescriptor,
        fingerprint: String
    ) -> TargetReference {
        if let binding = bindings.values.first(where: {
            $0.kind == kind
                && $0.serverSessionID == serverSessionID
                && $0.projectEpoch == projectEpoch
                && $0.topologyGeneration == topologyGeneration
                && $0.descriptor == descriptor
                && $0.observedFingerprint == fingerprint
        }) {
            return binding.reference
        }

        let reference = TargetReference(
            rawValue: "\(kind.referencePrefix)_\(UUID().uuidString)"
        )
        bindings[reference] = TargetBinding(
            reference: reference,
            kind: kind,
            serverSessionID: serverSessionID,
            projectEpoch: projectEpoch,
            topologyGeneration: topologyGeneration,
            descriptor: descriptor,
            observedFingerprint: fingerprint,
            createdAt: ContinuousClock().now
        )
        return reference
    }

    func resolve(_ reference: TargetReference) -> TargetBinding? {
        guard hasValidFormat(reference),
              let binding = bindings[reference],
              reference.rawValue.hasPrefix("\(binding.kind.referencePrefix)_"),
              binding.serverSessionID == serverSessionID,
              binding.projectEpoch == projectEpoch,
              binding.topologyGeneration == topologyGeneration
        else {
            return nil
        }
        return binding
    }

    /// Rebind an existing `target_ref` to a new descriptor after the SERVER
    /// ITSELF verifiably changed the referenced track's identity fingerprint —
    /// currently a `logic_tracks rename` performed through this very ref and
    /// confirmed by read-back (State A). The causal chain (this server issued
    /// the verified mutation via this reference) proves the binding still names
    /// the same track, so we update it in place instead of letting the
    /// name-fingerprint drift check invalidate a track that was renamed via its
    /// own ref.
    ///
    /// Validity gates match `resolve` (session / project-epoch /
    /// topology-generation): an unknown or already-stale reference is a no-op —
    /// a stale binding is NEVER resurrected. The rebound binding preserves
    /// `reference`, `kind`, `serverSessionID`, `projectEpoch`,
    /// `topologyGeneration`, and `createdAt`, adopting only the new `descriptor`
    /// with `observedFingerprint = descriptor.fingerprint`.
    ///
    /// Deliberately server-only: user-initiated (non-server) renames, and any
    /// topology change made directly in Logic's UI, are NOT rebound — the server
    /// cannot prove it caused those, so the drift check MUST keep invalidating
    /// them (fail-closed). Dropping the track name from the fingerprint instead
    /// would forfeit that external-change protection; hence rebind-on-proof, not
    /// a thinner fingerprint.
    func rebind(_ reference: TargetReference, to descriptor: TargetDescriptor) {
        guard let existing = resolve(reference) else { return }
        bindings[reference] = TargetBinding(
            reference: existing.reference,
            kind: existing.kind,
            serverSessionID: existing.serverSessionID,
            projectEpoch: existing.projectEpoch,
            topologyGeneration: existing.topologyGeneration,
            descriptor: descriptor,
            observedFingerprint: descriptor.fingerprint,
            createdAt: existing.createdAt
        )
    }

    func bumpProjectEpoch() {
        projectEpoch += 1
        bindings.removeAll(keepingCapacity: true)
    }

    func bumpTopologyGeneration() {
        topologyGeneration += 1
        bindings.removeAll(keepingCapacity: true)
    }

    private func hasValidFormat(_ reference: TargetReference) -> Bool {
        guard let separator = reference.rawValue.firstIndex(of: "_") else { return false }
        let uuidString = String(reference.rawValue[reference.rawValue.index(after: separator)...])
        guard uuidString.count == 36, let uuid = UUID(uuidString: uuidString) else {
            return false
        }
        return uuid.uuidString.caseInsensitiveCompare(uuidString) == .orderedSame
    }
}
