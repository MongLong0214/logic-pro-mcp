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
    let projectName: String?
    let projectFilePath: String?
    let projectEpoch: UInt64?

    init(
        trackIndex: Int,
        trackName: String,
        projectName: String? = nil,
        projectFilePath: String? = nil,
        projectEpoch: UInt64? = nil
    ) {
        self.trackIndex = trackIndex
        self.trackName = trackName
        self.projectName = projectName
        self.projectFilePath = projectFilePath
        self.projectEpoch = projectEpoch
    }

    static func project(name: String, filePath: String, epoch: UInt64) -> TargetDescriptor {
        TargetDescriptor(
            trackIndex: -1,
            trackName: "",
            projectName: name,
            projectFilePath: filePath,
            projectEpoch: epoch
        )
    }

    var fingerprint: String {
        if let projectName, let projectFilePath, let projectEpoch {
            return "project:name=\(projectName.utf8.count):\(projectName)|path=\(projectFilePath.utf8.count):\(projectFilePath)|epoch=\(projectEpoch)"
        }
        return "\(trackIndex):\(trackName.utf8.count):\(trackName)"
    }

    static func pluginInsertIndex(from fingerprint: String) -> Int? {
        let bytes = Array(fingerprint.utf8)
        guard let firstSeparator = bytes.firstIndex(of: 58),
              let secondSeparator = bytes[(firstSeparator + 1)...].firstIndex(of: 58),
              firstSeparator > 0,
              secondSeparator > firstSeparator + 1,
              let nameLength = Int(String(decoding: bytes[(firstSeparator + 1)..<secondSeparator], as: UTF8.self))
        else {
            return nil
        }
        let nameStart = secondSeparator + 1
        guard nameStart <= bytes.count,
              nameLength >= 0,
              nameLength <= bytes.count - nameStart
        else {
            return nil
        }
        let suffixStart = nameStart + nameLength
        let marker = Array("|insert=".utf8)
        guard suffixStart <= bytes.count,
              bytes[suffixStart...].starts(with: marker)
        else {
            return nil
        }
        let tokenStart = suffixStart + marker.count
        let tokenEnd = bytes[tokenStart...].firstIndex(of: 124) ?? bytes.count
        guard tokenStart < tokenEnd else { return nil }
        return Int(String(decoding: bytes[tokenStart..<tokenEnd], as: UTF8.self))
    }

    var isProjectIdentity: Bool {
        projectName != nil && projectFilePath != nil && projectEpoch != nil
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
    let pluginInsertIndex: Int?
    var physicalMixerStrip: AXMixerStripBinding.Binding? = nil
    let createdAt: ContinuousClock.Instant
}

struct TargetRegistrySnapshot: Equatable, Sendable {
    let projectEpoch: UInt64
    let topologyGeneration: UInt64
}

actor TargetRegistry {
    private let serverSessionID: UUID
    private var projectEpoch: UInt64 = 0
    private var topologyGeneration: UInt64 = 0
    private var bindings: [TargetReference: TargetBinding] = [:]
    private var currentProjectDescriptor: TargetDescriptor?

    init(serverSessionID: UUID = UUID()) {
        self.serverSessionID = serverSessionID
    }

    var currentProjectEpoch: UInt64 { projectEpoch }
    var currentTopologyGeneration: UInt64 { topologyGeneration }
    var currentProjectIdentity: TargetDescriptor? { currentProjectDescriptor }
    var currentSnapshot: TargetRegistrySnapshot {
        TargetRegistrySnapshot(
            projectEpoch: projectEpoch,
            topologyGeneration: topologyGeneration
        )
    }

    /// A request-owned native project observation cannot inherit another document's bindings.
    /// Reuse the existing project descriptor and epoch, invalidating in-flight old snapshots too.
    func snapshotForObservedProject(
        _ project: ProjectInfo, ifCurrent snapshot: TargetRegistrySnapshot,
        stoppingWhen stop: @Sendable () -> Bool
    ) -> TargetRegistrySnapshot? {
        guard !stop(), snapshot.projectEpoch == projectEpoch,
              snapshot.topologyGeneration == topologyGeneration else { return nil }
        let observed = ProjectReferenceIssuance.descriptor(
            name: project.name, filePath: project.filePath, epoch: projectEpoch
        )
        if observed == nil || observed != currentProjectDescriptor {
            bumpProjectEpoch()
            currentProjectDescriptor = ProjectReferenceIssuance.descriptor(
                name: project.name, filePath: project.filePath, epoch: projectEpoch
            )
        }
        return currentSnapshot
    }

    func bind(
        kind: TargetKind,
        descriptor: TargetDescriptor,
        fingerprint: String,
        pluginInsertIndex: Int? = nil,
        physicalMixerStrip: AXMixerStripBinding.Binding? = nil
    ) -> TargetReference {
        if kind == .project, currentProjectDescriptor != descriptor {
            currentProjectDescriptor = descriptor
            bindings = bindings.filter { $0.value.kind != .project }
        }
        if let binding = bindings.values.first(where: { binding in
            binding.kind == kind
                && binding.serverSessionID == serverSessionID
                && binding.projectEpoch == projectEpoch
                && binding.topologyGeneration == topologyGeneration
                && (physicalMixerStrip.map { physical in binding.physicalMixerStrip?.matches(physical) == true }
                    ?? (binding.physicalMixerStrip == nil && binding.descriptor == descriptor))
                && (physicalMixerStrip != nil || binding.descriptor == descriptor)
                && (physicalMixerStrip != nil || kind == .project || binding.descriptor.trackName.utf8.elementsEqual(descriptor.trackName.utf8))
                && (physicalMixerStrip != nil || (kind == .project ? binding.observedFingerprint == fingerprint
                    : binding.observedFingerprint.utf8.elementsEqual(fingerprint.utf8)))
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
            pluginInsertIndex: kind == .pluginInsert
                ? pluginInsertIndex ?? TargetDescriptor.pluginInsertIndex(from: fingerprint)
                : nil,
            physicalMixerStrip: physicalMixerStrip,
            createdAt: ContinuousClock().now
        )
        return reference
    }

    func bind(
        kind: TargetKind,
        descriptor: TargetDescriptor,
        fingerprint: String,
        snapshot: TargetRegistrySnapshot,
        physicalMixerStrip: AXMixerStripBinding.Binding? = nil,
        stoppingWhen stop: @Sendable () -> Bool = { false }
    ) -> TargetReference? {
        guard !Task.isCancelled, !stop(), snapshot.projectEpoch == projectEpoch,
              snapshot.topologyGeneration == topologyGeneration else {
            return nil
        }
        if let physicalMixerStrip {
            guard kind == .mixerStrip, let path = physicalMixerStrip.projectPath,
                  let observedPath = currentProjectDescriptor?.projectFilePath,
                  path.utf8.elementsEqual(observedPath.utf8) else { return nil }
        }
        return bind(kind: kind, descriptor: descriptor, fingerprint: fingerprint, physicalMixerStrip: physicalMixerStrip)
    }

    /// Return a current reference that this registry has already issued for the
    /// exact descriptor. This is intentionally lookup-only: a display label
    /// resolving during a read must never cause a new identity to be minted.
    func issuedReference(
        kind: TargetKind,
        descriptor: TargetDescriptor,
        fingerprint: String,
        snapshot: TargetRegistrySnapshot
    ) -> TargetReference? {
        guard snapshot.projectEpoch == projectEpoch,
              snapshot.topologyGeneration == topologyGeneration else {
            return nil
        }
        return bindings.values.first(where: {
            $0.kind == kind
                && $0.serverSessionID == serverSessionID
                && $0.projectEpoch == projectEpoch
                && $0.topologyGeneration == topologyGeneration
                && $0.descriptor == descriptor
                && (kind == .project || $0.descriptor.trackName.utf8.elementsEqual(descriptor.trackName.utf8))
                && (kind == .project ? $0.observedFingerprint == fingerprint
                    : $0.observedFingerprint.utf8.elementsEqual(fingerprint.utf8))
        })?.reference
    }

    func resolveCurrentProject(_ reference: TargetReference) -> TargetBinding? {
        guard let binding = resolve(reference),
              binding.kind == .project,
              let currentProjectDescriptor,
              binding.descriptor == currentProjectDescriptor,
              binding.observedFingerprint == currentProjectDescriptor.fingerprint else {
            return nil
        }
        return binding
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
        if let physical = binding.physicalMixerStrip, let projectPath = currentProjectDescriptor?.projectFilePath,
           physical.projectPath?.utf8.elementsEqual(projectPath.utf8) != true { return nil }
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
            pluginInsertIndex: existing.pluginInsertIndex,
            physicalMixerStrip: existing.physicalMixerStrip,
            createdAt: existing.createdAt
        )
    }

    func bumpProjectEpoch() {
        projectEpoch += 1
        bindings.removeAll(keepingCapacity: true)
        currentProjectDescriptor = nil
    }

    func bumpTopologyGeneration() {
        topologyGeneration += 1
        bindings.removeAll(keepingCapacity: true)
        currentProjectDescriptor = nil
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
