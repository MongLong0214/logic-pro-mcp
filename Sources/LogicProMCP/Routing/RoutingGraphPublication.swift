import Foundation

/// How the graph's project reference was obtained by the reader.
enum RoutingProjectBinding: Sendable {
    case issued(TargetReference)
    case unavailable(reason: String)
    /// The registry moved on while the project reference was being issued. `logic://mixer` throws
    /// instead of publishing this; `inspect_session`, which cannot throw, publishes it as every
    /// domain `unstable`.
    case moved

    /// What a reader with reference support off binds.
    static let referencesUnavailable = RoutingProjectBinding.unavailable(reason: "project reference is unavailable")
}

/// Builds the read-only ADR-008 projection from one #965 capture.
///
/// Identities come only from the shared capture: `issued` uses the existing track issuer, and
/// `mixerReferences` uses retained physical CF/document ownership in the existing registry.
/// Resources consume those very references; reading a resource first is not a prerequisite.
///
/// The AX reader contributes an output *label*, and the label is classified, never joined: a track
/// is never an output destination in Logic, so a track named like a bus is not one (#291). A
/// label that classifies as a bus becomes a `bus_<n>` node whose only identity is the number parsed
/// from the source's own slot description, and `main_output` coverage says so. A physical output
/// or no output is recorded on the source node and publishes no node and no edge. No send edge is
/// published: occupancy is read at the source strip, and the destination an assigned send's group
/// names is not read. Physical-strip nodes retain classification as display evidence only; no
/// track association, bus/port identity or edge is derived from their ordinal or labels.
///
/// This function is pure: it never sees the registry and never reads another resource. Every
/// domain it cannot answer carries its reasons in `coverage`, and `partialReason` is those reasons
/// joined, so `RoutingWriteGate`'s messages keep reading one string.
enum RoutingGraphPublication {
    static func publish(
        capture: SessionPopulationObservation.Capture,
        project: RoutingProjectBinding
    ) -> RoutingGraph {
        let snapshotId = SessionPopulationObservation.snapshotID(for: capture)
        let projectEpoch = capture.targetSnapshot?.projectEpoch ?? 0

        // A capture the cache or the registry moved under answers nothing domain by domain.
        var movedReason: String?
        if capture.before != capture.after {
            movedReason = cacheMovedReason
        } else if case .moved = project {
            movedReason = projectMovedReason
        } else if capture.referencesEnabled && capture.issued == nil {
            movedReason = trackReferencesMovedReason
        } else if capture.referencesEnabled && capture.channelStrips.contains(where: { $0.physicalBinding != nil })
                    && capture.mixerReferences == nil {
            movedReason = "physical strip references moved during capture"
        }
        if let movedReason {
            let unstable = RoutingDomainCoverage(state: .unstable, reasons: [movedReason])
            return RoutingGraph(
                projectReference: nil,
                projectEpoch: projectEpoch,
                complete: false,
                partialReason: movedReason,
                nodes: [],
                edges: [],
                provenance: [.axMixerStrip],
                snapshotId: snapshotId,
                coverage: .uniform(unstable)
            )
        }

        let tracks = TrackReferenceIssuance.liveInventory(capture.tracks)
        let issued = capture.referencesEnabled ? capture.issued : nil
        let mixerWasObserved = capture.mixerFetchedAt > .distantPast
        let tracksWereObserved = capture.tracksFetchedAt > .distantPast
        let strips = capture.channelStrips

        var population = DomainBuilder()
        var association = DomainBuilder()
        var mainOutput = DomainBuilder()
        var physicalOutput = DomainBuilder()
        var sends = DomainBuilder()

        if mixerWasObserved {
            population.partial(mixerFiltersUnreadReason)
        } else {
            population.unavailable(mixerUnavailableReason)
            association.unavailable(mixerUnavailableReason)
            mainOutput.unavailable(mixerUnavailableReason)
            physicalOutput.unavailable(mixerUnavailableReason)
            sends.unavailable(mixerUnavailableReason)
        }
        var projectReference: TargetReference?
        switch project {
        case .issued(let reference):
            projectReference = reference
        case .unavailable(let reason):
            population.partial(reason)
        case .moved:
            break
        }

        if issued == nil {
            association.unavailable(registryUnavailableReason)
            mainOutput.unavailable(registryUnavailableReason)
            physicalOutput.unavailable(registryUnavailableReason)
        } else if !tracksWereObserved {
            // Before the first live track read there is nothing to attribute a strip to. That is
            // unknown, not "this strip has no track", so it is one reason for the whole graph.
            association.unavailable(tracksUnavailableReason)
            mainOutput.unavailable(tracksUnavailableReason)
            physicalOutput.unavailable(tracksUnavailableReason)
        } else if mixerWasObserved {
            // What every read strip rests on even when each one read cleanly.
            association.partial(positionalAssociationReason)
            mainOutput.partial(busIdentityReason)
            mainOutput.partial(labelRenameReason)
            physicalOutput.partial(positionalAssociationReason)
            physicalOutput.partial(physicalOutputHasNoNodeReason)
        }
        if mixerWasObserved {
            sends.partial(sendDestinationReason)
        }

        let ambiguousTrackIndices = Set(issued?.ambiguousTrackIndices ?? [])
        var stripCounts: [Int: Int] = [:]
        for strip in strips {
            stripCounts[strip.trackIndex, default: 0] += 1
        }

        var nodesByID: [String: RoutingNode] = [:]
        var edges: [RoutingEdge] = []
        for (row, strip) in strips.enumerated() {
            let trackIndex = strip.trackIndex

            // nil is a strip whose descendants were not read; `[]` a strip read with no send slot.
            if let slots = strip.sendSlots {
                for slot in slots where slot.state == .unreadable {
                    sends.partial("send slot ordinal=\(slot.ordinal) unreadable for track_index=\(trackIndex)")
                }
            } else {
                sends.partial("send slots unreadable for track_index=\(trackIndex)")
            }

            guard let issued else { continue }

            // Physical ownership supplies a source endpoint independently of Arrange. Its
            // output is still display evidence, never a bus/port identity or an edge.
            if strip.physicalBinding != nil {
                if let reference = capture.mixerReference(at: row) {
                    let label = nonEmptyObservedLabel(strip.output)
                    let input: InputSlotObservation?
                    if let slot = strip.inputSlotBinding, let owner = strip.physicalBinding,
                       slot.owner.matches(owner),
                       let observed = strip.inputObservation, observed.state == .observedSource,
                       let source = observed.source, source.utf8.elementsEqual(slot.source.utf8) {
                        input = observed
                    } else { input = nil }
                    nodesByID[reference.rawValue] = RoutingNode(
                        id: reference.rawValue, kind: .physicalStrip,
                        displayName: strip.name ?? "", busNumber: nil, targetRef: reference,
                        observedOutputLabel: label,
                        outputClassification: label.map { classifyOutputLabel($0).0 },
                        observedInputSlot: input
                    )
                } else {
                    population.partial("physical strip membership or reference unavailable at observed row=\(row)")
                }
                association.partial(positionalAssociationReason)
                mainOutput.partial(positionalAssociationReason)
                physicalOutput.partial(positionalAssociationReason)
                continue
            }

            // Two strips claiming one track index cannot both be that track's source, and nothing
            // observed says which one is.
            if stripCounts[trackIndex, default: 0] > 1 {
                association.partial("duplicate mixer strip observations for track_index=\(trackIndex)")
                continue
            }

            let observedLabel = nonEmptyObservedLabel(strip.output)
            let classified = observedLabel.map(classifyOutputLabel)
            if observedLabel == nil {
                let reason = "unreadable output destination endpoint for source track_index=\(trackIndex)"
                mainOutput.partial(reason)
                physicalOutput.partial(reason)
            } else if classified?.0 == .unclassified {
                mainOutput.partial("unclassified output destination label for source track_index=\(trackIndex)")
            }

            guard tracksWereObserved else { continue }

            guard let sourceReference = issued.byTrackIndex[trackIndex],
                  let sourceTrack = tracks.first(where: { $0.id == trackIndex }) else {
                if ambiguousTrackIndices.contains(trackIndex) {
                    association.partial("ambiguous track observation: track_index=\(trackIndex) appears more than once")
                } else if tracks.contains(where: { $0.id == trackIndex }) {
                    association.partial("track_index=\(trackIndex) is not live-identity-backed: no reference can be issued")
                } else {
                    association.partial("no live track observation for mixer strip track_index=\(trackIndex)")
                }
                continue
            }
            nodesByID[sourceReference.rawValue] = RoutingNode(
                id: sourceReference.rawValue,
                kind: .track,
                displayName: sourceTrack.name,
                busNumber: nil,
                targetRef: sourceReference,
                observedOutputLabel: observedLabel,
                outputClassification: classified?.0
            )

            guard let observedLabel, classified?.0 == .bus, let busNumber = classified?.busNumber else {
                continue
            }
            let busID = "bus_\(busNumber)"
            if nodesByID[busID] == nil {
                nodesByID[busID] = RoutingNode(
                    id: busID,
                    kind: .bus,
                    displayName: observedLabel,
                    busNumber: busNumber,
                    targetRef: nil
                )
            }
            edges.append(RoutingEdge(
                kind: .mainOutput,
                source: sourceReference.rawValue,
                destination: busID,
                send: nil,
                provenance: .axMixerStrip
            ))
        }

        let coverage = RoutingCoverage(
            population: population.coverage,
            stripTrackAssociation: association.coverage,
            mainOutput: mainOutput.coverage,
            physicalOutput: physicalOutput.coverage,
            busToAuxInput: RoutingDomainCoverage(state: .notObserved, reasons: [busToAuxInputReason]),
            sends: sends.coverage
        )
        var partialReasons: [String] = []
        for domain in coverage.domains where domain.state != .complete {
            for reason in domain.reasons where !partialReasons.contains(reason) {
                partialReasons.append(reason)
            }
        }

        return RoutingGraph(
            projectReference: projectReference,
            projectEpoch: projectEpoch,
            complete: coverage.isComplete,
            partialReason: partialReasons.isEmpty ? nil : partialReasons.joined(separator: "; "),
            nodes: nodesByID.values.sorted { $0.id < $1.id },
            edges: edges,
            provenance: [.axMixerStrip],
            snapshotId: snapshotId,
            coverage: coverage
        )
    }

    /// Classifies an output-slot description by the canon-derived sets in `AXLocalePolicy`.
    ///
    /// Whole-label matches come first: `Stereo Output` contains the physical prefix `Output` and
    /// must not be read as one of its pairs. A prefix classifies only when what follows it is a
    /// number (`Bus 3`, `バス3`, `Output 3-4`), so a label that merely starts with the word — an
    /// I/O-label rename such as `Busy`, a bare `Output` — stays `unclassified`.
    static func classifyOutputLabel(_ label: String) -> (RoutingOutputClassification, busNumber: Int?) {
        let candidate = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if AXLocalePolicy.noOutputLabel.matches(candidate, mode: .exact) {
            return (.noOutput, nil)
        }
        if AXLocalePolicy.stereoOutputLabel.matches(candidate, mode: .exact) {
            return (.physicalOutput, nil)
        }
        for remainder in remainders(of: candidate, after: AXLocalePolicy.busOutputLabelPrefix) {
            if let number = decimalNumber(remainder), number > 0 {
                return (.bus, number)
            }
        }
        for remainder in remainders(of: candidate, after: AXLocalePolicy.physicalOutputLabelPrefix) {
            let parts = remainder.split(separator: "-", omittingEmptySubsequences: false)
            if (1...2).contains(parts.count), parts.allSatisfy({ decimalNumber(String($0)) != nil }) {
                return (.physicalOutput, nil)
            }
        }
        return (.unclassified, nil)
    }

    /// What follows each member of `prefix` that `candidate` begins with, leading whitespace
    /// dropped: Japanese composes `バス%d` with no space and Traditional Chinese `匯流排 %d` with one.
    private static func remainders(of candidate: String, after prefix: AXLocalePolicy.LabelSet) -> [String] {
        prefix.labels.compactMap { member in
            guard let range = candidate.range(of: member, options: [.anchored, .caseInsensitive]) else {
                return nil
            }
            return String(candidate[range.upperBound...].drop { $0.isWhitespace })
        }
    }

    private static func decimalNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }

    private static func nonEmptyObservedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    static let cacheMovedReason = "cache moved during capture"
    static let projectMovedReason = "project reference snapshot moved during capture"
    static let trackReferencesMovedReason = "track reference snapshot moved during capture"
    static let mixerUnavailableReason = "mixer strip observations are unavailable"
    static let mixerFiltersUnreadReason = "mixer filters unread: hidden or filtered strips are not accounted for"
    static let registryUnavailableReason =
        "routing endpoints could not resolve: the ADR-002 reference registry is unavailable"
    static let tracksUnavailableReason = "track observations are unavailable: no live track read yet"
    static let positionalAssociationReason = "positional strip-to-track association unverified until #965 O2"
    static let busIdentityReason = "bus identity parsed from the source output slot description"
    static let labelRenameReason = "I/O label renames defeat the parse"
    static let physicalOutputHasNoNodeReason =
        "physical outputs are classified on the source node and publish no node or edge"
    static let busToAuxInputReason = "bus-to-aux input edges are not observed in this increment"
    static let sendDestinationReason = "send destinations are not readable at the source slot: occupancy only"
}

/// One domain's coverage while it is being built: it only ever moves away from `complete`.
private struct DomainBuilder {
    private var state: RoutingCoverageState = .complete
    private var reasons: [String] = []

    var coverage: RoutingDomainCoverage {
        RoutingDomainCoverage(state: state, reasons: reasons)
    }

    mutating func partial(_ reason: String) {
        if state == .complete { state = .partial }
        add(reason)
    }

    mutating func unavailable(_ reason: String) {
        state = .unavailable
        add(reason)
    }

    private mutating func add(_ reason: String) {
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
    }
}
