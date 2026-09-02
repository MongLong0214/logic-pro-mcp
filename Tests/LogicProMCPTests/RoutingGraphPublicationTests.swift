import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// Runtime ADR-008 coverage. These go through `logic://tracks` first because
/// the graph is allowed to *resolve* only references that ADR-002 has already
/// issued; the mixer read itself must never bind a display string as an id.
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

    @Test("a mixer read does not mint trk_ identities from output labels")
    func outputLabelCannotIssueAnIdentity() async throws {
        let fixture = try await fixture(
            tracks: [
                track(index: 0, name: "Source"),
                track(index: 1, name: "Destination"),
            ],
            strips: [ChannelStripState(trackIndex: 0, output: "Destination")],
            issueTrackReferences: false
        )

        let graph = try fixture.graph
        let edges = try #require(graph["edges"] as? [[String: Any]])
        let partialReason = try #require(graph["partialReason"] as? String)

        #expect(edges.isEmpty)
        #expect(partialReason.contains("unresolved source endpoint for mixer strip track_index=0"))
        #expect(partialReason.contains("unresolved output destination endpoint \"Destination\""))
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
                targetRegistry: registry
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
