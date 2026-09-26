import Foundation

/// How the graph's project reference was obtained by the reader.
enum RoutingProjectBinding: Sendable {
    case issued(TargetReference)
    case unavailable(reason: String)
}

/// Builds the read-only ADR-008 projection from cached mixer observations.
///
/// Identities come only from `issued`, which the reader obtained through
/// `TrackReferenceIssuance` for the rows it observed — the same path
/// `logic://tracks` uses, so the graph does not depend on which resource was
/// read first (#291 R0). The AX reader contributes an output *label*; a label
/// selects a destination only when exactly one live track row carries that name
/// and that row has an issued reference. It is never itself a node id.
///
/// This function is pure: it never sees the registry and never reads another
/// resource. Every state it cannot answer is named in `partialReason`.
enum RoutingGraphPublication {
    /// `tracks` is the live inventory `issued` was issued for, row for row.
    /// `issued == nil` means reference support is off or has no registry.
    static func publish(
        strips: [ChannelStripState],
        tracks: [TrackState],
        issued: IssuedTrackReferences?,
        project: RoutingProjectBinding,
        projectEpoch: UInt64,
        mixerWasObserved: Bool,
        tracksWereObserved: Bool
    ) -> RoutingGraph {
        var partialReasons: [String] = []
        func recordPartial(_ reason: String) {
            if !partialReasons.contains(reason) {
                partialReasons.append(reason)
            }
        }

        guard let issued else {
            recordPartial("routing endpoints could not resolve: the ADR-002 reference registry is unavailable")
            recordPartial(sendCoverageReason)
            if !mixerWasObserved {
                recordPartial("mixer strip observations are unavailable")
            }
            return RoutingGraph(
                projectReference: nil,
                projectEpoch: projectEpoch,
                complete: false,
                partialReason: partialReasons.joined(separator: "; "),
                nodes: [],
                edges: [],
                provenance: [.axMixerStrip]
            )
        }

        // Before the first live track read there is nothing to join a strip to. That is unknown,
        // not "this strip has no track", so it is one reason for the whole graph.
        if !tracksWereObserved {
            recordPartial("track observations are unavailable: no live track read yet")
        }

        let ambiguousTrackIndices = Set(issued.ambiguousTrackIndices)
        var stripCounts: [Int: Int] = [:]
        for strip in strips {
            stripCounts[strip.trackIndex, default: 0] += 1
        }

        var nodesByID: [String: RoutingNode] = [:]
        var edges: [RoutingEdge] = []
        for strip in strips {
            let trackIndex = strip.trackIndex
            let observedLabel = nonEmptyObservedLabel(strip.output)

            // Two strips claiming one track index cannot both be that track's output, and nothing
            // observed says which one is.
            if stripCounts[trackIndex, default: 0] > 1 {
                recordPartial("duplicate mixer strip observations for track_index=\(trackIndex)")
                continue
            }

            var sourceReference: TargetReference?
            if tracksWereObserved {
                if let reference = issued.byTrackIndex[trackIndex],
                   let sourceTrack = tracks.first(where: { $0.id == trackIndex }) {
                    sourceReference = reference
                    addNode(
                        reference: reference,
                        track: sourceTrack,
                        observedOutputLabel: observedLabel,
                        to: &nodesByID
                    )
                } else if ambiguousTrackIndices.contains(trackIndex) {
                    recordPartial("ambiguous track observation: track_index=\(trackIndex) appears more than once")
                } else if tracks.contains(where: { $0.id == trackIndex }) {
                    recordPartial("track_index=\(trackIndex) is not live-identity-backed: no reference can be issued")
                } else {
                    recordPartial("no live track observation for mixer strip track_index=\(trackIndex)")
                }
            }

            guard let observedLabel else {
                recordPartial("unreadable output destination endpoint for source track_index=\(trackIndex)")
                continue
            }
            guard tracksWereObserved else { continue }

            let matchingDestinations = tracks.filter { $0.name == observedLabel }
            guard matchingDestinations.count == 1,
                  let destinationReference = issued.byTrackIndex[matchingDestinations[0].id] else {
                recordPartial(
                    "unresolved output destination endpoint \"\(observedLabel)\" for source track_index=\(trackIndex): no unique live track carries that name"
                )
                continue
            }

            addNode(
                reference: destinationReference,
                track: matchingDestinations[0],
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

        var projectReference: TargetReference?
        if case .issued(let reference) = project {
            projectReference = reference
        } else if case .unavailable(let reason) = project {
            recordPartial(reason)
        }

        return RoutingGraph(
            projectReference: projectReference,
            projectEpoch: projectEpoch,
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
