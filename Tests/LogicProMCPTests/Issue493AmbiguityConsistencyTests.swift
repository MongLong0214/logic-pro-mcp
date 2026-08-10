import MCP
import Testing

@testable import LogicProMCP

@Test("Issue #493: delete ambiguity has one code and one index-set meaning")
func deleteAmbiguityIsConsistentAcrossTargetRefAndIndexPaths() async throws {
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
        let targetRefResult = await TrackDispatcher.handle(
            command: "delete",
            params: ["target_ref": .string(reference.rawValue)],
            router: ChannelRouter(),
            cache: cache,
            targetRegistry: registry,
            liveTrackNames: { liveNames }
        )
        let indexResult = await TrackDispatcher.handle(
            command: "delete",
            params: [
                "index": .int(1),
                "expected_name": .string(name),
            ],
            router: ChannelRouter(),
            cache: cache,
            liveTrackNames: { liveNames }
        )

        let targetRefBody = try #require(sharedJSONObject(sharedToolText(targetRefResult)))
        let indexBody = try #require(sharedJSONObject(sharedToolText(indexResult)))
        #expect(targetRefBody["error"] as? String == indexBody["error"] as? String)
        #expect(targetRefBody["ambiguous_track_indices"] as? [Int] == indexBody["ambiguous_track_indices"] as? [Int])
    }
}
