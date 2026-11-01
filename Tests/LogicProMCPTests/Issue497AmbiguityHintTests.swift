import MCP
import Testing

@testable import LogicProMCP

@Test("Issue497: ambiguous target reference terminates without a human route")
func Issue497AmbiguousTargetReferenceTerminatesWithoutHumanRoute() async throws {
    let name = "Studio Grand"
    let liveNames: [Int: String] = [
        1: name,
        5: name,
        6: name,
    ]

    let registry = TargetRegistry()
    let descriptor = TargetDescriptor(trackIndex: 6, trackName: name)
    let reference = await registry.bind(
        kind: .track,
        descriptor: descriptor,
        fingerprint: descriptor.fingerprint
    )
    let cache = StateCache()
    await cache.updateTracks(liveNames.map { TrackState(id: $0.key, name: $0.value, type: .audio) })

    try await FeatureFlags.withAdr002TargetRefForTests(true) {
        let result = await TrackDispatcher.handle(
            command: "rename",
            params: [
                "name": .string("Renamed Studio Grand"),
                "target_ref": .string(reference.rawValue),
            ],
            router: ChannelRouter(),
            cache: cache,
            targetRegistry: registry,
            liveTrackNames: { liveNames }
        )

        let body = try #require(sharedJSONObject(sharedToolText(result)))
        let isError = try #require(result.isError as Bool?)
        #expect(isError)
        #expect(body["error"] as? String == "ambiguous_target_name")
        guard let writeAttempted = body["write_attempted"] as? Bool,
              let safeToRetry = body["safe_to_retry"] as? Bool,
              let terminal = body["terminal"] as? Bool,
              let humanInterventionRequired = body["human_intervention_required"] as? Bool else {
            Issue.record("ambiguous target reference omitted a required terminal Boolean field")
            return
        }
        #expect(!writeAttempted)
        #expect(!safeToRetry)
        #expect(terminal)
        #expect(body["terminal_scope"] as? String == "mcp_request_only")
        #expect(!humanInterventionRequired)
        #expect(body["human_intervention_requests"] as? Int == 0)
        #expect(body["human_dependent_transitions"] as? Int == 0)
        #expect(body["ambiguous_track_indices"] as? [Int] == [1, 5, 6])
        let hint = try #require(body["hint"] as? String)
        #expect(!hint.localizedCaseInsensitiveContains("rename {name, index}"))
        #expect(!hint.localizedCaseInsensitiveContains("unambiguous name"))
        #expect(!hint.localizedCaseInsensitiveContains("select by index"))
    }
}
