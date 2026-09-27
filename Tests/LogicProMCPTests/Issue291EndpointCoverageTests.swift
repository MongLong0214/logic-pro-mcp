import Foundation
import MCP
import Testing
@testable import LogicProMCP

// #291: typed endpoints and per-domain coverage.
//
// The pure cases drive `RoutingGraphPublication.publish(capture:project:)` and
// `SessionPopulationObservation.build` on a hand-built capture; the last suite reads
// `logic://mixer` from a real cache and registry and compares it with the same publish over a
// capture of that cache. Each case's comment names the mutation it exists to kill.

private typealias Observation = SessionPopulationObservation

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let freshRead = fixedNow.addingTimeInterval(-1)

private let baselineVersions: [CacheSectionID: StateCache.SectionVersion] = [
    .tracks: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 7),
    .mixer: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 2),
    .project: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 1),
]

private let projectReference = TargetReference(rawValue: "prj_song")

private func tracks(_ names: [String]) -> [TrackState] {
    names.enumerated().map { TrackState(id: $0.offset, name: $0.element, type: .audio) }
}

private func strip(_ index: Int, output: String?, sendSlots: [SendSlotObservation]? = []) -> ChannelStripState {
    var strip = ChannelStripState(trackIndex: index, output: output)
    strip.sendSlots = sendSlots
    return strip
}

/// A capture with references on and one `trk_<index>` per live row, as `capture` issues them.
private func makeCapture(
    tracks: [TrackState],
    strips: [ChannelStripState],
    mixerFetchedAt: Date = freshRead,
    versionsAfter: [CacheSectionID: StateCache.SectionVersion] = baselineVersions,
    issuedReferences: Bool = true,
    projectIssuance: ProjectIssuance? = .issued(projectReference)
) -> Observation.Capture {
    let references = tracks.map { TargetReference(rawValue: "trk_\($0.id)") }
    let issued = IssuedTrackReferences(
        byRow: references,
        byTrackIndex: Dictionary(uniqueKeysWithValues: zip(tracks.map(\.id), references)),
        ambiguousTrackIndices: []
    )
    return Observation.Capture(
        before: StateCache.CaptureBoundary(versions: baselineVersions, occlusionRevision: 0, hasDocument: true, axOccluded: false),
        after: StateCache.CaptureBoundary(versions: versionsAfter, occlusionRevision: 0, hasDocument: true, axOccluded: false),
        projectEpoch: 3,
        project: ProjectInfo(name: "Song", filePath: "/Users/x/Song.logicx"),
        tracks: tracks,
        tracksFetchedAt: freshRead,
        channelStrips: strips,
        mixerFetchedAt: mixerFetchedAt,
        fileTrackCount: nil,
        projectFileNotBound: false,
        requestedProjectMatches: nil,
        referencesEnabled: true,
        targetSnapshot: TargetRegistrySnapshot(projectEpoch: 3, topologyGeneration: 0),
        issued: issuedReferences ? issued : nil,
        projectIssuance: projectIssuance,
        beganAt: fixedNow.addingTimeInterval(-0.01),
        endedAt: fixedNow
    )
}

private func publish(_ capture: Observation.Capture) -> RoutingGraph {
    RoutingGraphPublication.publish(capture: capture, project: .issued(projectReference))
}

private func encodedReport(_ capture: Observation.Capture) throws -> [String: Any] {
    let report = Observation.build(request: Observation.Request(domains: [.routing]), capture: capture)
    return try #require(sharedJSONObject(try encodeJSONStrict(report, compact: true)))
}

@Suite("#291 R1 endpoints: classification and edges")
struct Issue291EndpointClassificationTests {
    /// Kills: a bus-named track becoming a destination — restoring the track-name join sends
    /// strip 0's edge to `trk_1`, the track named `Bus 3`, instead of `bus_3`.
    @Test func aTrackNamedLikeABusIsNeverTheDestination() {
        let graph = publish(makeCapture(
            tracks: tracks(["Source", "Bus 3"]),
            strips: [strip(0, output: "Bus 3"), strip(1, output: "Stereo Output")]
        ))

        #expect(graph.edges == [
            RoutingEdge(kind: .mainOutput, source: "trk_0", destination: "bus_3", send: nil, provenance: .axMixerStrip),
        ])
        #expect(graph.nodes.map(\.id) == ["bus_3", "trk_0", "trk_1"])
        let bus = graph.nodes.first { $0.id == "bus_3" }
        #expect(bus == RoutingNode(id: "bus_3", kind: .bus, displayName: "Bus 3", busNumber: 3, targetRef: nil))
        #expect(graph.coverage.mainOutput.state == .partial)
        #expect(graph.coverage.mainOutput.reasons.contains("bus identity parsed from the source output slot description"))
        #expect(graph.coverage.mainOutput.reasons.contains("I/O label renames defeat the parse"))
        #expect(graph.isConsistent)
    }

    /// Kills: publishing the physical output as a node — `Stereo Output` or `Output 3-4` would
    /// then appear among the node ids, or an edge would lead to one.
    @Test func physicalNoOutputAndUnknownLabelsAreClassifiedWithoutNodes() {
        let labels = ["Stereo Output", "Output 3-4", "No Output", "Rumpelstiltskin"]
        let graph = publish(makeCapture(
            tracks: tracks(["A", "B", "C", "D"]),
            strips: labels.enumerated().map { strip($0.offset, output: $0.element) }
        ))

        #expect(graph.edges.isEmpty)
        #expect(graph.nodes.map(\.id) == ["trk_0", "trk_1", "trk_2", "trk_3"])
        #expect(graph.nodes.map(\.outputClassification) == [.physicalOutput, .physicalOutput, .noOutput, .unclassified])
        #expect(graph.nodes.map(\.observedOutputLabel) == labels)
        #expect(!graph.nodes.contains { labels.contains($0.id) || labels.contains($0.displayName) })
        let unclassified = graph.coverage.mainOutput.reasons.filter { $0.hasPrefix("unclassified output destination label") }
        #expect(unclassified == ["unclassified output destination label for source track_index=3"])
    }

    /// Kills: classifying an unknown label as a bus — `Busy 3`, a bare `Bus` or `Bus 3a` (an I/O
    /// label rename) would then become a `bus_<n>` node. The ten-script forms are Apple's own
    /// `Bus %d` / `Output %d-%d` compositions, with and without the space before the number.
    @Test func classifyOutputLabelReadsEachScriptAndRefusesAnythingElse() {
        let buses: [(String, Int)] = [
            ("Bus 3", 3), ("bus 12", 12), ("버스 2", 2), ("バス3", 3), ("总线 4", 4), ("匯流排 5", 5),
        ]
        for (label, number) in buses {
            let classified = RoutingGraphPublication.classifyOutputLabel(label)
            #expect(classified.0 == .bus, "\(label)")
            #expect(classified.busNumber == number, "\(label)")
        }
        for label in ["Stereo Output", "Uscita stereo", "立體聲輸出", "Output 3-4", "Output 3", "出力3-4", "Salida 5"] {
            let classified = RoutingGraphPublication.classifyOutputLabel(label)
            #expect(classified.0 == .physicalOutput, "\(label)")
            #expect(classified.busNumber == nil, "\(label)")
        }
        for label in ["No Output", "出力なし", "Kein Ausgang"] {
            #expect(RoutingGraphPublication.classifyOutputLabel(label).0 == .noOutput, "\(label)")
        }
        for label in ["Busy 3", "Bus", "Bus 3a", "Bus 0", "Output", "Output 3-", "Reverb", "Rumpelstiltskin"] {
            let classified = RoutingGraphPublication.classifyOutputLabel(label)
            #expect(classified.0 == .unclassified, "\(label)")
            #expect(classified.busNumber == nil, "\(label)")
        }
    }

    /// Kills: treating `send_slots: nil` as `[]` — the strip whose descendants were not read would
    /// then lose its `send slots unreadable` reason and read like the strip read with no slot.
    @Test func sendSlotsNilIsUnreadWhileEmptyAndOccupiedAreRead() {
        let graph = publish(makeCapture(
            tracks: tracks(["Unread", "Empty", "Occupied", "Unreadable slot"]),
            strips: [
                strip(0, output: "Bus 1", sendSlots: nil),
                strip(1, output: "Bus 1", sendSlots: []),
                strip(2, output: "Bus 1", sendSlots: [
                    SendSlotObservation(ordinal: 0, state: .occupiedUnknownDestination),
                    SendSlotObservation(ordinal: 1, state: .observedEmpty),
                ]),
                strip(3, output: "Bus 1", sendSlots: [SendSlotObservation(ordinal: 0, state: .unreadable)]),
            ]
        ))

        #expect(graph.coverage.sends == RoutingDomainCoverage(state: .partial, reasons: [
            "send destinations are not readable at the source slot: occupancy only",
            "send slots unreadable for track_index=0",
            "send slot ordinal=0 unreadable for track_index=3",
        ]))
        #expect(!graph.edges.contains { $0.kind == .send })
        #expect(graph.edges.count == 4)
    }

    /// Kills: a moved capture that is not `unstable` — dropping the before/after comparison
    /// publishes the nodes and partial domains of a cache that changed while it was read. The
    /// control is the same capture unmoved.
    @Test func aCaptureTheCacheMovedUnderIsUnstableInEveryDomain() {
        var after = baselineVersions
        after[.mixer] = StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 3)
        let rows = tracks(["Source"])
        let strips = [strip(0, output: "Bus 1")]

        let control = publish(makeCapture(tracks: rows, strips: strips))
        #expect(control.coverage.population.state == .partial)
        #expect(control.edges.count == 1)

        let moved = publish(makeCapture(tracks: rows, strips: strips, versionsAfter: after))
        let unstable = RoutingDomainCoverage(state: .unstable, reasons: ["cache moved during capture"])
        #expect(moved.coverage == .uniform(unstable))
        #expect(!moved.complete)
        #expect(moved.partialReason == "cache moved during capture")
        #expect(moved.nodes.isEmpty)
        #expect(moved.edges.isEmpty)
        #expect(moved.snapshotId == control.snapshotId)
        #expect(moved.isConsistent)
    }

    /// Kills: publishing `complete: true` — every strip here read cleanly, and the graph is still
    /// partial because its association is positional, its bus identity parsed, its filters unread
    /// and its bus-to-aux edges unobserved. Each domain's state is asserted so a domain promoted to
    /// `complete` is caught by name.
    @Test func aCleanReadIsStillPartialInThisIncrement() {
        let graph = publish(makeCapture(
            tracks: tracks(["Source"]),
            strips: [strip(0, output: "Bus 1")]
        ))

        #expect(!graph.complete)
        #expect(graph.coverage.population.state == .partial)
        #expect(graph.coverage.stripTrackAssociation == RoutingDomainCoverage(
            state: .partial,
            reasons: ["positional strip-to-track association unverified until #965 O2"]
        ))
        #expect(graph.coverage.mainOutput.state == .partial)
        #expect(graph.coverage.physicalOutput.state == .partial)
        #expect(graph.coverage.busToAuxInput == RoutingDomainCoverage(
            state: .notObserved,
            reasons: ["bus-to-aux input edges are not observed in this increment"]
        ))
        #expect(graph.coverage.sends.state == .partial)
        #expect(graph.isConsistent)
        let partialReason = graph.partialReason ?? ""
        for domain in graph.coverage.domains {
            for reason in domain.reasons {
                #expect(partialReason.contains(reason), "\(reason)")
            }
        }
        #expect(graph.snapshotId == "snap_3_t7_m2_p1")
        #expect(graph.projectReference == projectReference)
        #expect(graph.projectEpoch == 3)

        let decision = evaluate(
            RoutingWriteRequest(
                sourceTrackRef: TargetReference(rawValue: "trk_0"),
                physicalSlot: 0,
                destinationBusNumber: 1,
                destinationRef: nil,
                expectedProjectEpoch: 3
            ),
            against: graph
        )
        #expect(!decision.allowed)
        #expect(!decision.writeAttempted)
    }
}

@Suite("#291 R1 endpoints: inspect_session routing section")
struct Issue291RoutingSectionTests {
    /// Kills: hard-coding the section — its `graph` must be the coverage `publish` gives for the
    /// same capture, and its `snapshot_id` the report's own.
    @Test func theRoutingSectionMirrorsTheGraphOfTheSameCapture() throws {
        let capture = makeCapture(
            tracks: tracks(["Source", "Other"]),
            strips: [strip(0, output: "Bus 2"), strip(1, output: nil, sendSlots: nil)]
        )
        let report = try encodedReport(capture)
        let routing = try #require(report["routing"] as? [String: Any])
        let graph = publish(capture)

        #expect(routing["coverage"] as? String == "partial")
        #expect(routing["reasons"] as? [String] == ["routing_graph_partial"])
        #expect(routing["snapshot_id"] as? String == report["snapshot_id"] as? String)
        #expect(routing["snapshot_id"] as? String == graph.snapshotId)
        let section = try #require(routing["graph"] as? [String: Any])
        let decoded = try JSONDecoder().decode(
            RoutingCoverage.self,
            from: JSONSerialization.data(withJSONObject: section)
        )
        #expect(decoded == graph.coverage)
        #expect(section["main_output"] != nil)
        #expect(section["strip_track_association"] != nil)
        #expect(section["bus_to_aux_input"] != nil)
    }

    /// Kills: publishing a stale project issuance as a merely unobserved project — `build` cannot
    /// throw the way `logic://mixer` does, so the section says the capture moved.
    @Test func aStaleIssuanceMakesTheSectionAndEveryGraphDomainUnstable() throws {
        let cases: [(String, Observation.Capture, String)] = [
            (
                "project",
                makeCapture(tracks: tracks(["Source"]), strips: [strip(0, output: "Bus 1")], projectIssuance: .stale),
                "project reference snapshot moved during capture"
            ),
            (
                "tracks",
                makeCapture(tracks: tracks(["Source"]), strips: [strip(0, output: "Bus 1")], issuedReferences: false),
                "track reference snapshot moved during capture"
            ),
        ]
        for (label, capture, reason) in cases {
            let routing = try #require(try encodedReport(capture)["routing"] as? [String: Any])
            #expect(routing["coverage"] as? String == "unstable", "\(label)")
            #expect(routing["reasons"] as? [String] == ["target_snapshot_stale"], "\(label)")
            let section = try #require(routing["graph"] as? [String: Any])
            let decoded = try JSONDecoder().decode(
                RoutingCoverage.self,
                from: JSONSerialization.data(withJSONObject: section)
            )
            #expect(decoded == .uniform(RoutingDomainCoverage(state: .unstable, reasons: [reason])), "\(label)")
        }
    }
}

@Suite("#291 R1 endpoints: logic://mixer parity", .serialized)
struct Issue291MixerParityTests {
    /// Kills: `logic://mixer` building its graph from a read other than its own capture — the
    /// published graph must equal `publish(capture:project:)` over a capture of the same cache and
    /// registry, and its `snapshot_id` must be `inspect_session`'s for that capture.
    @Test func logicMixerPublishesTheGraphOfItsCapture() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = StateCache()
            await cache.updateProject(ProjectInfo(name: "Song", filePath: "/Users/x/Song.logicx"))
            await cache.updateTracks(tracks(["Source", "Bus 3", "Other"]))
            await cache.updateChannelStrips([
                strip(0, output: "Bus 3"),
                strip(1, output: "Stereo Output", sendSlots: nil),
                strip(2, output: "Rumpelstiltskin"),
            ])
            let registry = TargetRegistry()

            let result = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: ChannelRouter(),
                targetRegistry: registry
            )
            let body = try #require(sharedJSONObject(sharedResourceText(result)))
            let graphObject = try #require(body["routing_graph"] as? [String: Any])
            let published = try JSONDecoder().decode(
                RoutingGraph.self,
                from: JSONSerialization.data(withJSONObject: graphObject)
            )

            let capture = await Observation.capture(
                cache: cache,
                targetRegistry: registry,
                fileReader: .unavailable,
                now: { fixedNow }
            )
            let issuance = try #require(capture.projectIssuance)
            let expected = RoutingGraphPublication.publish(
                capture: capture,
                project: try ResourceHandlers.routingProjectBinding(for: issuance)
            )
            #expect(published == expected)
            #expect(published.edges.map(\.destination) == ["bus_3"])
            #expect(published.projectReference != nil)

            let report = Observation.build(request: Observation.Request(domains: [.routing]), capture: capture)
            #expect(report.snapshotId == published.snapshotId)
            #expect(report.routing?.graph == published.coverage)
        }
    }
}
