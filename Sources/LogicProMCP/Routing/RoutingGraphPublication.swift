import Foundation

/// Builds the read-only ADR-008 projection from cached mixer observations.
///
/// The AX reader contributes only an output *label*. The registry is the sole
/// source of identities: a label may select one already-issued `trk_` reference
/// only when the current live-track inventory has exactly one matching name.
/// It is never itself a node id.
enum RoutingGraphPublication {
    static func publish(
        strips: [ChannelStripState],
        tracks: [TrackState],
        targetRegistry: TargetRegistry?,
        snapshot: TargetRegistrySnapshot?,
        mixerWasObserved: Bool
    ) async -> RoutingGraph {
        var partialReasons: [String] = []
        func recordPartial(_ reason: String) {
            if !partialReasons.contains(reason) {
                partialReasons.append(reason)
            }
        }

        guard let targetRegistry, let snapshot else {
            recordPartial("routing endpoints could not resolve: the ADR-002 reference registry is unavailable")
            recordPartial(sendCoverageReason)
            if !mixerWasObserved {
                recordPartial("mixer strip observations are unavailable")
            }
            return RoutingGraph(
                projectReference: nil,
                projectEpoch: 0,
                complete: false,
                partialReason: partialReasons.joined(separator: "; "),
                nodes: [],
                edges: [],
                provenance: [.axMixerStrip]
            )
        }

        let tracksByIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var referencesByTrackIndex: [Int: TargetReference] = [:]
        for track in tracks {
            if let reference = await TargetRefResolver.issuedTrackReference(
                for: track,
                targetRegistry: targetRegistry,
                snapshot: snapshot
            ) {
                referencesByTrackIndex[track.id] = reference
            }
        }

        var nodesByID: [String: RoutingNode] = [:]
        var edges: [RoutingEdge] = []
        for strip in strips {
            let observedLabel = nonEmptyObservedLabel(strip.output)
            let sourceTrack = tracksByIndex[strip.trackIndex]
            let sourceReference = referencesByTrackIndex[strip.trackIndex]

            if let sourceTrack, let sourceReference {
                addNode(
                    reference: sourceReference,
                    track: sourceTrack,
                    observedOutputLabel: observedLabel,
                    to: &nodesByID
                )
            } else {
                recordPartial("unresolved source endpoint for mixer strip track_index=\(strip.trackIndex): no issued trk_ reference")
            }

            guard let observedLabel else {
                recordPartial("unreadable output destination endpoint for source track_index=\(strip.trackIndex)")
                continue
            }

            let matchingDestinations = tracks.filter { $0.name == observedLabel }
            let destinationsWithIssuedReferences = matchingDestinations.compactMap { track in
                referencesByTrackIndex[track.id].map { (track, $0) }
            }
            guard destinationsWithIssuedReferences.count == 1,
                  matchingDestinations.count == 1 else {
                recordPartial(
                    "unresolved output destination endpoint \"\(observedLabel)\" for source track_index=\(strip.trackIndex): no unique issued trk_ reference"
                )
                continue
            }

            let (destinationTrack, destinationReference) = destinationsWithIssuedReferences[0]
            addNode(
                reference: destinationReference,
                track: destinationTrack,
                observedOutputLabel: nil,
                to: &nodesByID
            )
            if let sourceReference {
                edges.append(RoutingEdge(
                    kind: .mainOutput,
                    source: sourceReference.rawValue,
                    destination: destinationReference.rawValue,
                    send: nil,
                    provenance: .axMixerStrip
                ))
            }
        }

        if !mixerWasObserved {
            recordPartial("mixer strip observations are unavailable")
        }
        // Empty send slots expose no destination attribute, so an empty list
        // would collapse “no send” and “could not read a send”. Sends are absent
        // from this graph until a real observation can distinguish those states.
        recordPartial(sendCoverageReason)

        let projectReference = await targetRegistry.issuedCurrentProjectReference(snapshot: snapshot)
        if projectReference == nil {
            recordPartial("project reference is unavailable")
        }

        return RoutingGraph(
            projectReference: projectReference,
            projectEpoch: snapshot.projectEpoch,
            complete: false,
            partialReason: partialReasons.joined(separator: "; "),
            nodes: nodesByID.values.sorted { $0.id < $1.id },
            edges: edges,
            provenance: [.axMixerStrip]
        )
    }

    private static let sendCoverageReason = "sends are not covered: an empty send slot exposes no AXValue, AXValueDescription, or AXTitle"

    private static func nonEmptyObservedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func addNode(
        reference: TargetReference,
        track: TrackState,
        observedOutputLabel: String?,
        to nodesByID: inout [String: RoutingNode]
    ) {
        let id = reference.rawValue
        if let existing = nodesByID[id] {
            guard existing.observedOutputLabel == nil, let observedOutputLabel else { return }
            nodesByID[id] = RoutingNode(
                id: existing.id,
                kind: existing.kind,
                displayName: existing.displayName,
                busNumber: existing.busNumber,
                targetRef: existing.targetRef,
                observedOutputLabel: observedOutputLabel
            )
            return
        }
        nodesByID[id] = RoutingNode(
            id: id,
            kind: .track,
            displayName: track.name,
            busNumber: nil,
            targetRef: reference,
            observedOutputLabel: observedOutputLabel
        )
    }
}
