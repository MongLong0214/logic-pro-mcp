import MCP
import Testing

@testable import LogicProMCP

@Test("Issue497: ambiguity hint names the working index rename route")
func Issue497AmbiguityHintNamesIndexRenameRoute() async throws {
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
        let hint = try #require(body["hint"] as? String)
        #expect(hint.contains("rename {name, index}"))
        #expect(!hint.contains("or address the track by an unambiguous name"))
    }
}
