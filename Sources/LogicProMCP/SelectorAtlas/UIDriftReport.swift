import Foundation

struct UIFingerprint: Codable, Equatable, Sendable {
    let logicVariant: String
    let logicVersion: String
    let locale: String
    let windowType: String
    let viewMode: String
    let sanitizedHierarchyHash: String
}

enum SelectorDriftStatus: String, Codable, Equatable, Sendable {
    case stable
    case minorDrift
    case changed
    case missing
}

struct SelectorDrift: Equatable, Sendable {
    let selectorID: SelectorID
    let status: SelectorDriftStatus
    let previousConfidence: Double
    let currentConfidence: Double
    let changedRoles: [String]
    let affectedOperations: [OperationID]
}

enum QualificationReuse: Equatable, Sendable {
    case reuseFull
    case readOnlyOnly
    case failClosedMutation
}

/// Which operations a selector's drift puts at risk.
///
/// EVERY `SelectorID` must appear, including with an empty list — `SelectorAtlasOperationMapTests`
/// fails otherwise. A missing key and a deliberate empty one are indistinguishable at the call
/// site (`operationsBySelector[id] ?? []`), so an ID added without a decision would silently report
/// that its drift affects nothing.
///
/// The operation IDs are checked against `OperationRegistry` by the same test. This is a
/// hand-maintained second copy of a relationship, and the only thing that keeps a second copy
/// honest is something that fails when it diverges.
private let operationsBySelector: [SelectorID: [OperationID]] = [
    .trackHeaderPanControl: [.mixerSetPan],
    .trackHeaderVolumeFader: [.mixerSetVolume],
    .trackHeaderMuteToggle: [.tracksMute],
    .trackHeaderSoloToggle: [.tracksSolo],
    .trackHeaderArmToggle: [.tracksArm, .tracksArmOnly],
    .controlBar: [.transportPlay, .transportStop],
    .transportPlayButton: [.transportPlay, .transportStop],
    .trackHeaderNameField: [.tracksSelect, .tracksRename],
    .mixerStripVolumeFader: [.mixerSetVolume],
    .mixerStripSendSlot: [],
    .pluginWindowTitle: [.pluginsGetInventory, .pluginsInsertVerified],
    .pluginParameterControl: [.pluginsSetParamVerified, .pluginsSetEQBandVerified, .mixerSetPluginParam],
    .projectSaveFilenameField: [.projectSaveAs],
]

func drift(
    previous: [SelectorID: Double],
    current: [SelectorID: Double],
    roleChanges: [SelectorID: [String]]
) -> [SelectorDrift] {
    SelectorID.allCases.compactMap { id in
        guard previous[id] != nil || current[id] != nil else { return nil }
        let old = previous[id] ?? 0
        let new = current[id] ?? 0
        let status: SelectorDriftStatus
        if current[id] == nil {
            status = .missing
        } else if previous[id] == nil {
            status = .changed
        } else {
            let delta = abs(old - new)
            status = delta < 0.05 ? .stable : delta < 0.20 ? .minorDrift : .changed
        }
        return SelectorDrift(
            selectorID: id,
            status: status,
            previousConfidence: old,
            currentConfidence: new,
            changedRoles: roleChanges[id] ?? [],
            affectedOperations: operationsBySelector[id] ?? []
        )
    }
}

func policy(for drift: SelectorDrift) -> QualificationReuse {
    switch drift.status {
    case .stable where drift.currentConfidence >= 0.80:
        .reuseFull
    case .minorDrift where drift.currentConfidence >= 0.80:
        .readOnlyOnly
    case .stable, .minorDrift, .changed, .missing:
        .failClosedMutation
    }
}
