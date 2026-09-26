import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Runtime ADR-008 coverage. The first group reads `logic://tracks` before
/// `logic://mixer`; the #291 R0 group below reads them in both orders, because
/// both readers issue `trk_` references through `TrackReferenceIssuance` and the
/// graph must not depend on which one ran first.
@Suite("#291 routing graph publication", .serialized)
struct RoutingGraphPublicationTests {
    @Test("an issued trk_ destination produces a reference-to-reference output edge")
    func issuedTrackDestinationEmitsEdgeAndKeepsTheLabelOnTheSource() async throws {
        let fixture = try await fixture(
            tracks: [
                track(index: 0, name: "Source"),
                track(index: 1, name: "Destination"),
            ],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )

        let graph = try fixture.graph
        let nodes = try #require(graph["nodes"] as? [[String: Any]])
        let edges = try #require(graph["edges"] as? [[String: Any]])
        let sourceReference = try #require(fixture.references["Source"])
        let destinationReference = try #require(fixture.references["Destination"])
        let edge = try #require(edges.first)
        let sourceNode = try #require(nodes.first { $0["id"] as? String == sourceReference })
        let observedOutputLabel = try #require(sourceNode["observed_output_label"] as? String)

        #expect(edge["kind"] as? String == "mainOutput")
        #expect(edge["source"] as? String == sourceReference)
        #expect(edge["destination"] as? String == destinationReference)
        #expect(observedOutputLabel == "Destination")
        #expect(!nodes.contains { $0["id"] as? String == "Destination" })
    }

    @Test("an unissued output destination emits no edge and identifies that endpoint")
    func unresolvedDestinationIsPartialNotANode() async throws {
        let fixture = try await fixture(
            tracks: [track(index: 0, name: "Source")],
            strips: [ChannelStripState(trackIndex: 0, output: "Stereo Output")]
        )

        let graph = try fixture.graph
        let edges = try #require(graph["edges"] as? [[String: Any]])
        let partialReason = try #require(graph["partialReason"] as? String)
        let complete = try #require(graph["complete"] as? Bool)

        #expect(edges.isEmpty)
        #expect(partialReason.contains("unresolved output destination endpoint \"Stereo Output\""))
        #expect(!complete)
    }

    @Test("an unreadable output is unknown, never a claim that the source is not routed")
    func unreadableOutputDoesNotBecomeNotRouted() async throws {
        let fixture = try await fixture(
            tracks: [track(index: 0, name: "Source")],
            strips: [ChannelStripState(trackIndex: 0, output: nil)]
        )

        let graph = try fixture.graph
        let edges = try #require(graph["edges"] as? [[String: Any]])
        let partialReason = try #require(graph["partialReason"] as? String)
        let complete = try #require(graph["complete"] as? Bool)

        #expect(edges.isEmpty)
        #expect(partialReason.contains("unreadable output destination endpoint for source track_index=0"))
        #expect(!partialReason.contains("not routed"))
        #expect(!complete)
    }

    @Test("the send list is omitted and its measured unreadability is declared")
    func sendsAreAbsentInsteadOfAnEmptyClaim() async throws {
        let fixture = try await fixture(
            tracks: [track(index: 0, name: "Source")],
            strips: [ChannelStripState(trackIndex: 0, output: nil)]
        )

        let graph = try fixture.graph
        let partialReason = try #require(graph["partialReason"] as? String)
        let sendList = graph["sends"] as? [Any]

        #expect(sendList == nil)
        #expect(partialReason.contains("sends are not covered"))
        #expect(partialReason.contains("no AXValue, AXValueDescription, or AXTitle"))
    }

    @Test("an empty output label is unreadable rather than a destination named empty string")
    func emptyOutputLabelIsUnknown() async throws {
        let fixture = try await fixture(
            tracks: [
                track(index: 0, name: "Source"),
                track(index: 1, name: ""),
            ],
            strips: [ChannelStripState(trackIndex: 0, output: "")]
        )

        let graph = try fixture.graph
        let nodes = try #require(graph["nodes"] as? [[String: Any]])
        let edges = try #require(graph["edges"] as? [[String: Any]])
        let partialReason = try #require(graph["partialReason"] as? String)
        let sourceReference = try #require(fixture.references["Source"])
        let sourceNode = try #require(nodes.first { $0["id"] as? String == sourceReference })

        #expect(edges.isEmpty)
        #expect(sourceNode["observed_output_label"] == nil)
        #expect(partialReason.contains("unreadable output destination endpoint for source track_index=0"))
        #expect(!partialReason.contains("endpoint \"\""))
    }

    @Test("the published graph remains partial while sends have no readable endpoint")
    func declaredSendCoverageKeepsOtherwiseResolvedGraphPartial() async throws {
        let fixture = try await fixture(
            tracks: [
                track(index: 0, name: "Source"),
                track(index: 1, name: "Destination"),
            ],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )

        let graph = try fixture.graph
        let edges = try #require(graph["edges"] as? [[String: Any]])
        let complete = try #require(graph["complete"] as? Bool)
        let partialReason = try #require(graph["partialReason"] as? String)

        #expect(edges.count == 1)
        #expect(!complete)
        #expect(partialReason.contains("sends are not covered"))
    }

    // MARK: - #291 R0: reader order

    @Test("mixer-first and tracks-first publish the same nodes and edges, and node ids are the tracks' track_ref")
    func mixerFirstAndTracksFirstPublishTheSameMembership() async throws {
        let tracks = [
            track(index: 0, name: "Source"),
            track(index: 1, name: "Destination"),
            track(index: 2, name: "Other"),
        ]
        let strips = [
            ChannelStripState(trackIndex: 0, output: "Destination"),
            ChannelStripState(trackIndex: 2, output: "Destination"),
        ]

        let mixerFirst = await Server(tracks: tracks, strips: strips)
        let mixerFirstGraph = try await mixerFirst.readGraph()
        let mixerFirstRows = try await mixerFirst.readTrackRows()

        let tracksFirst = await Server(tracks: tracks, strips: strips)
        let tracksFirstRows = try await tracksFirst.readTrackRows()
        let tracksFirstGraph = try await tracksFirst.readGraph()

        for (graph, rows) in [(mixerFirstGraph, mixerFirstRows), (tracksFirstGraph, tracksFirstRows)] {
            #expect(Set(graph.nodes.map(\.displayName)) == ["Source", "Destination", "Other"])
            #expect(edgeNames(graph) == [
                EdgeNames(kind: "mainOutput", source: "Source", destination: "Destination"),
                EdgeNames(kind: "mainOutput", source: "Other", destination: "Destination"),
            ])
            for node in graph.nodes {
                let row = try #require(rows.first { $0["name"] as? String == node.displayName })
                #expect(row["track_ref"] as? String == node.id)
            }
        }
        #expect(Set(mixerFirstGraph.nodes.map(\.displayName)) == Set(tracksFirstGraph.nodes.map(\.displayName)))
        #expect(edgeNames(mixerFirstGraph) == edgeNames(tracksFirstGraph))
    }

    @Test("a mixer read in a fresh server emits the output edge without a prior tracks read")
    func aMixerFirstReadEmitsTheOutputEdge() async throws {
        let server = await Server(
            tracks: [track(index: 0, name: "Source"), track(index: 1, name: "Destination")],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )

        let graph = try await server.readGraph()
        let rows = try await server.readTrackRows()
        let sourceReference = try #require(rows.first { $0["name"] as? String == "Source" }?["track_ref"] as? String)
        let destinationReference = try #require(
            rows.first { $0["name"] as? String == "Destination" }?["track_ref"] as? String
        )
        let edge = try #require(graph.edges.first)
        let partialReason = try #require(graph.partialReason)

        #expect(graph.edges.count == 1)
        #expect(edge.source == sourceReference)
        #expect(edge.destination == destinationReference)
        #expect(!partialReason.contains("no live track observation"))
        #expect(!partialReason.contains("track observations are unavailable"))
    }

    @Test("an output label never becomes a node id, whichever resource is read first")
    func anOutputLabelNeverBecomesANodeInEitherOrder() async throws {
        let tracks = [track(index: 0, name: "Source")]
        let strips = [ChannelStripState(trackIndex: 0, output: "Stereo Output")]
        for tracksFirst in [false, true] {
            let server = await Server(tracks: tracks, strips: strips)
            if tracksFirst {
                _ = try await server.readTrackRows()
            }
            let graph = try await server.readGraph()
            let partialReason = try #require(graph.partialReason)

            #expect(graph.nodes.count == 1)
            #expect(graph.edges.isEmpty)
            #expect(partialReason.contains(
                "unresolved output destination endpoint \"Stereo Output\" for source track_index=0: no unique live track carries that name"
            ))
            for node in graph.nodes {
                let binding = try #require(await server.registry.resolve(TargetReference(rawValue: node.id)))
                #expect(binding.kind == .track)
                #expect(binding.descriptor == TargetDescriptor(trackIndex: 0, trackName: "Source"))
            }
        }
    }

    @Test("before any live track read the graph says tracks are unknown, not that strips have none")
    func aColdTrackInventoryIsUnknownNotEmpty() async throws {
        let server = await Server(
            tracks: nil,
            strips: [ChannelStripState(trackIndex: 0, output: "Stereo Output")]
        )

        let graph = try await server.readGraph()
        let partialReason = try #require(graph.partialReason)

        #expect(graph.nodes.isEmpty)
        #expect(graph.edges.isEmpty)
        #expect(!graph.complete)
        #expect(partialReason.contains("track observations are unavailable: no live track read yet"))
        #expect(!partialReason.contains("no live track observation"))
        #expect(!partialReason.contains("unresolved output destination endpoint"))
    }

    @Test("a strip whose track index no live row carries is unknown and publishes no source node")
    func aStripWithNoTrackObservationIsUnknown() async throws {
        let server = await Server(
            tracks: [track(index: 1, name: "Destination")],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )

        let graph = try await server.readGraph()
        let partialReason = try #require(graph.partialReason)

        #expect(graph.nodes.map(\.displayName) == ["Destination"])
        #expect(graph.edges.isEmpty)
        #expect(partialReason.contains("no live track observation for mixer strip track_index=0"))
        for node in graph.nodes {
            let binding = try #require(await server.registry.resolve(TargetReference(rawValue: node.id)))
            #expect(binding.kind == .track)
        }
    }

    @Test("two strips observed for one track index publish no node and no edge for it")
    func duplicateStripObservationsPublishNoEdge() async throws {
        let server = await Server(
            tracks: [track(index: 0, name: "Source"), track(index: 1, name: "Destination")],
            strips: [
                ChannelStripState(trackIndex: 0, output: "Destination"),
                ChannelStripState(trackIndex: 0, output: "Destination"),
            ]
        )

        let graph = try await server.readGraph()
        let partialReason = try #require(graph.partialReason)

        #expect(graph.edges.isEmpty)
        #expect(!graph.nodes.contains { $0.displayName == "Source" })
        #expect(partialReason.contains("duplicate mixer strip observations for track_index=0"))
    }

    @Test("two track rows sharing an id are ambiguous: no trap, no node, no edge for that id")
    func duplicateTrackIdsAreAmbiguousNotTrapped() async throws {
        let server = await Server(
            tracks: [
                track(index: 0, name: "First"),
                track(index: 0, name: "Second"),
                track(index: 1, name: "Destination"),
            ],
            strips: [
                ChannelStripState(trackIndex: 0, output: "Destination"),
                ChannelStripState(trackIndex: 1, output: nil),
            ]
        )

        let graph = try await server.readGraph()
        let rows = try await server.readTrackRows()
        let partialReason = try #require(graph.partialReason)

        #expect(graph.edges.isEmpty)
        #expect(!graph.nodes.contains { $0.displayName == "First" || $0.displayName == "Second" })
        #expect(graph.nodes.map(\.displayName) == ["Destination"])
        #expect(partialReason.contains("ambiguous track observation: track_index=0 appears more than once"))
        #expect(rows.count == 3)
    }

    @Test("a row that is not live-identity-backed issues no reference from either reader")
    func anIneligibleTrackIssuesNoReference() async throws {
        let server = await Server(
            tracks: [
                TrackState(id: 0, name: "Source", type: .audio, liveIdentityBacked: false),
                track(index: 1, name: "Destination"),
            ],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )

        let graph = try await server.readGraph()
        let rows = try await server.readTrackRows()
        let partialReason = try #require(graph.partialReason)

        #expect(!graph.nodes.contains { $0.displayName == "Source" })
        #expect(graph.edges.isEmpty)
        #expect(partialReason.contains("track_index=0 is not live-identity-backed: no reference can be issued"))
        #expect(rows[0]["track_ref"] == nil)
        #expect(rows[1]["track_ref"] as? String != nil)
    }

    @Test("after a topology bump both readers issue the same fresh references, in either order")
    func aTopologyBumpReissuesFreshReferencesInBothReaders() async throws {
        let server = await Server(
            tracks: [track(index: 0, name: "Source"), track(index: 1, name: "Destination")],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )
        let before = try await server.readTrackRows().compactMap { $0["track_ref"] as? String }
        let graphBefore = try await server.readGraph()
        #expect(before.count == 2)
        #expect(Set(graphBefore.nodes.map(\.id)) == Set(before))

        await server.registry.bumpTopologyGeneration()
        let graphAfter = try await server.readGraph()
        let after = try await server.readTrackRows().compactMap { $0["track_ref"] as? String }

        #expect(after.count == 2)
        #expect(Set(graphAfter.nodes.map(\.id)) == Set(after))
        #expect(Set(after).isDisjoint(with: before))
        for reference in after {
            let binding = try #require(await server.registry.resolve(TargetReference(rawValue: reference)))
            #expect(binding.kind == .track)
        }
    }

    @Test("a project-epoch bump invalidates every published node and the graph reports the new epoch")
    func aProjectEpochBumpInvalidatesEveryPublishedNode() async throws {
        let server = await Server(
            tracks: [track(index: 0, name: "Source"), track(index: 1, name: "Destination")],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
        )
        let graphBefore = try await server.readGraph()
        #expect(graphBefore.projectEpoch == 0)
        #expect(graphBefore.nodes.count == 2)

        await server.registry.bumpProjectEpoch()
        let graphAfter = try await server.readGraph()

        #expect(graphAfter.projectEpoch == 1)
        #expect(graphAfter.nodes.count == 2)
        for node in graphBefore.nodes {
            #expect(await server.registry.resolve(TargetReference(rawValue: node.id)) == nil)
        }
        for node in graphAfter.nodes {
            let binding = try #require(await server.registry.resolve(TargetReference(rawValue: node.id)))
            #expect(binding.kind == .track)
            #expect(binding.projectEpoch == 1)
        }
    }

    @Test("with reference support off neither order publishes nodes or emits any reference")
    func disabledReferenceSupportPublishesNoNodesInEitherOrder() async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(false) {
            for tracksFirst in [false, true] {
                let server = await Server(
                    tracks: [track(index: 0, name: "Source"), track(index: 1, name: "Destination")],
                    strips: [ChannelStripState(trackIndex: 0, output: "Destination")]
                )
                var rows: [[String: Any]] = []
                if tracksFirst {
                    rows = try await server.readTrackRows()
                }
                let (graph, strips) = try await server.readMixer()
                if !tracksFirst {
                    rows = try await server.readTrackRows()
                }
                let partialReason = try #require(graph.partialReason)

                #expect(graph.nodes.isEmpty)
                #expect(graph.edges.isEmpty)
                #expect(partialReason.contains(
                    "routing endpoints could not resolve: the ADR-002 reference registry is unavailable"
                ))
                #expect(rows.count == 2)
                #expect(!rows.contains { $0["track_ref"] != nil })
                #expect(strips.count == 1)
                #expect(!strips.contains { $0["mixer_strip_ref"] != nil })
            }
        }
    }

    @Test("a mixer_strip_ref is emitted only for a strip whose track id is unique and eligible")
    func mixerStripRefRequiresAUniqueTrackObservation() async throws {
        let server = await Server(
            tracks: [
                track(index: 0, name: "First"),
                track(index: 0, name: "Second"),
                track(index: 1, name: "Unique"),
                TrackState(id: 2, name: "Unbacked", type: .audio, liveIdentityBacked: false),
            ],
            strips: [
                ChannelStripState(trackIndex: 0),
                ChannelStripState(trackIndex: 1),
                ChannelStripState(trackIndex: 2),
            ]
        )

        let (_, strips) = try await server.readMixer()
        let single = try await server.readStrip(at: 0)

        #expect(strips[0]["mixer_strip_ref"] == nil)
        #expect(strips[1]["mixer_strip_ref"] as? String != nil)
        #expect(strips[2]["mixer_strip_ref"] == nil)
        #expect(single["mixer_strip_ref"] == nil)
    }

    private struct EdgeNames: Hashable {
        let kind: String
        let source: String
        let destination: String
    }

    private func edgeNames(_ graph: RoutingGraph) -> Set<EdgeNames> {
        let names = Dictionary(graph.nodes.map { ($0.id, $0.displayName) }) { first, _ in first }
        return Set(graph.edges.map {
            EdgeNames(
                kind: $0.kind.rawValue,
                source: names[$0.source] ?? "?\($0.source)",
                destination: names[$0.destination] ?? "?\($0.destination)"
            )
        })
    }

    /// One fresh server: its own cache and registry. `tracks: nil` leaves the tracks section unread.
    private struct Server {
        let cache = StateCache()
        let registry = TargetRegistry()
        let router = ChannelRouter()

        init(tracks: [TrackState]?, strips: [ChannelStripState]) async {
            if let tracks {
                await cache.updateTracks(tracks)
            }
            await cache.updateChannelStrips(strips)
        }

        func readTrackRows() async throws -> [[String: Any]] {
            let result = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: router,
                targetRegistry: registry,
                fileReader: .unavailable
            )
            return try #require(sharedJSONObject(sharedResourceText(result))?["data"] as? [[String: Any]])
        }

        func readMixer() async throws -> (graph: RoutingGraph, strips: [[String: Any]]) {
            let result = try await ResourceHandlers.read(
                uri: "logic://mixer",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            let body = try #require(sharedJSONObject(sharedResourceText(result)))
            let graphObject = try #require(body["routing_graph"] as? [String: Any])
            let strips = try #require(body["strips"] as? [[String: Any]])
            let graph = try JSONDecoder().decode(
                RoutingGraph.self,
                from: JSONSerialization.data(withJSONObject: graphObject)
            )
            return (graph, strips)
        }

        func readGraph() async throws -> RoutingGraph {
            try await readMixer().graph
        }

        func readStrip(at index: Int) async throws -> [String: Any] {
            let result = try await ResourceHandlers.read(
                uri: "logic://mixer/\(index)",
                cache: cache,
                router: router,
                targetRegistry: registry
            )
            return try #require(sharedJSONObject(sharedResourceText(result))?["strip"] as? [String: Any])
        }
    }

    private func fixture(
        tracks: [TrackState],
        strips: [ChannelStripState],
        issueTrackReferences: Bool = true
    ) async throws -> (graph: [String: Any], references: [String: String]) {
        let cache = StateCache()
        await cache.updateTracks(tracks)
        await cache.updateChannelStrips(strips)
        let registry = TargetRegistry()
        let router = ChannelRouter()

        var references: [String: String] = [:]
        if issueTrackReferences {
            let trackResult = try await ResourceHandlers.read(
                uri: "logic://tracks",
                cache: cache,
                router: router,
                targetRegistry: registry,
                fileReader: .unavailable
            )
            let trackRows = try #require(
                (sharedJSONObject(sharedResourceText(trackResult))?["data"] as? [[String: Any]])
            )
            for row in trackRows {
                if let name = row["name"] as? String, let reference = row["track_ref"] as? String {
                    references[name] = reference
                }
            }
        }

        let mixerResult = try await ResourceHandlers.read(
            uri: "logic://mixer",
            cache: cache,
            router: router,
            targetRegistry: registry
        )
        let graph = try #require(
            sharedJSONObject(sharedResourceText(mixerResult))?["routing_graph"] as? [String: Any]
        )
        return (graph, references)
    }

    private func track(index: Int, name: String) -> TrackState {
        TrackState(id: index, name: name, type: .audio)
    }
}
