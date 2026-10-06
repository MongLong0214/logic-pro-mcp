import Foundation
import MCP
import Testing
@testable import LogicProMCP

// #904: keep the existing Output#mix and JA/IT spellings; the Mixer output
// reader also needs the own MAMixer Output row's German "Ausgang".
// These are synthetic cached observations, not fresh native qualification.
@Suite("#904 physical output labels reach the existing routing consumers", .serialized)
struct Issue904PhysicalOutputConsumerTests {
    @Test("German and English physical pairs agree across the existing readers",
          arguments: ["Ausgang 3-4", "Output 3-4"])
    func physicalPairLabelsAgreeAcrossExistingReaders(label: String) {
        let (classification, bus) = RoutingGraphPublication.classifyOutputLabel(label)
        #expect(classification == .physicalOutput)
        #expect(bus == nil)
        #expect(OutputAssignment.observed(slotLabel: label) == .physical(3, 4))
        #expect(AXLocalePolicy.physicalOutputLabelPrefix.matches(label, mode: .prefix))
    }

    @Test("the real mixer resource and population publication retain the physical classification",
          arguments: ["Ausgang 3-4", "Output 3-4"])
    func physicalPairLabelsReachResourceAndPopulationPublication(label: String) async throws {
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            let cache = StateCache()
            let registry = TargetRegistry()
            let router = ChannelRouter() // no channels registered or started
            await cache.updateTracks([TrackState(id: 0, name: "Source", type: .audio)])
            var strip = ChannelStripState(trackIndex: 0, output: label)
            strip.sendSlots = []
            await cache.updateChannelStrips([strip])

            let result = try await ResourceHandlers.read(
                uri: "logic://mixer", cache: cache, router: router,
                targetRegistry: registry, fileReader: .unavailable
            )
            let body = try #require(sharedJSONObject(sharedResourceText(result)))
            let strips = try #require(body["strips"] as? [[String: Any]])
            #expect(strips.count == 1)
            #expect(strips.first?["output"] as? String == label)
            let graphObject = try #require(body["routing_graph"] as? [String: Any])
            let resourceGraph = try JSONDecoder().decode(
                RoutingGraph.self, from: JSONSerialization.data(withJSONObject: graphObject)
            )
            let capture = await SessionPopulationObservation.capture(
                cache: cache, targetRegistry: registry, fileReader: .unavailable
            )
            #expect(capture.before == capture.after)
            #expect(capture.channelStrips.map(\.output) == [label])
            let populationGraph = SessionPopulationObservation.routingGraph(capture: capture)
            for graph in [resourceGraph, populationGraph] {
                #expect(graph.nodes.count == 1)
                let source = try #require(graph.nodes.first)
                #expect(source.kind == .track)
                #expect(source.displayName == "Source")
                #expect(source.observedOutputLabel == label)
                #expect(source.outputClassification == .physicalOutput)
                #expect(graph.edges.isEmpty)
                #expect(!graph.complete)
                let reason = try #require(graph.partialReason)
                #expect(!reason.contains("unclassified output destination label"))
                #expect(reason.contains(RoutingGraphPublication.positionalAssociationReason))
                #expect(graph.coverage.stripTrackAssociation.state == .partial)
            }
            let section = SessionPopulationObservation.routingSection(capture: capture, moved: false)
            #expect(section.coverage == .partial)
            #expect(!section.graph.mainOutput.reasons.contains {
                $0.contains("unclassified output destination label")
            })
        }
    }

    @Test("a physical prefix is anchored and requires a numeric endpoint, not a similar name")
    func physicalPrefixesStayAnchoredToNumericEndpoints() {
        for label in [
            "Ausgang", "Ausgangs 3-4", "prefix Ausgang 3-4", "Ausgang 3-4x",
            "Ausgang -3-4", "Ausgang 3--4", "Output", "Outputs 3-4",
            "prefix Output 3-4", "Output 3-4x",
        ] {
            #expect(RoutingGraphPublication.classifyOutputLabel(label).0 == .unclassified)
            #expect(OutputAssignment.observed(slotLabel: label) == nil)
        }
    }

    @Test("bus, fixed output kinds and legacy JA/IT physical spellings keep their meanings")
    func otherDestinationKindsAndLegacyPhysicalSpellingsStayUnchanged() {
        for label in ["Bus 3", "버스 3", "バス3"] {
            let (classification, number) = RoutingGraphPublication.classifyOutputLabel(label)
            #expect(classification == .bus)
            #expect(number == 3)
            #expect(OutputAssignment.observed(slotLabel: label) == .bus(3))
        }
        for label in ["Stereo Output", "Stereo-Ausgabe"] {
            #expect(RoutingGraphPublication.classifyOutputLabel(label).0 == .physicalOutput)
            #expect(OutputAssignment.observed(slotLabel: label) == .stereoOutput)
        }
        for label in ["No Output", "Kein Ausgang"] {
            #expect(RoutingGraphPublication.classifyOutputLabel(label).0 == .noOutput)
            #expect(OutputAssignment.observed(slotLabel: label) == .noOutput)
        }
        for label in ["出力3-4", "Uscita 3-4"] {
            #expect(RoutingGraphPublication.classifyOutputLabel(label).0 == .physicalOutput)
            #expect(OutputAssignment.observed(slotLabel: label) == .physical(3, 4))
        }
        // Keep the existing single-channel classification; it is not a pair assignment.
        #expect(RoutingGraphPublication.classifyOutputLabel("Output 3").0 == .physicalOutput)
        #expect(OutputAssignment.observed(slotLabel: "Output 3") == nil)
    }
}
