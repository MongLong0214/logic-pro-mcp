import Foundation
import Testing
@testable import LogicProMCP

private actor Issue494StateASelectChannel: Channel {
    nonisolated let id: ChannelID = .mcu
    var executedOps: [(String, [String: String])] = []

    func start() async throws {}
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        executedOps.append((operation, params))
        return .success(HonestContract.encodeStateA(extras: [
            "requested": Int(params["index"] ?? "0") ?? 0,
            "observed": Int(params["index"] ?? "0") ?? 0,
        ]))
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "Issue #494 State A select fixture")
    }
}

@Test("Issue494: track.select by ambiguous name fails closed")
func issue494SelectByAmbiguousNameFailsClosed() async throws {
    let router = ChannelRouter()
    let channel = Issue494StateASelectChannel()
    await router.register(channel)
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 1, name: "Studio Grand", type: .softwareInstrument),
        TrackState(id: 4, name: "Studio Grand", type: .softwareInstrument),
    ])

    let result = await TrackDispatcher.handle(
        command: "select",
        params: ["name": .string("Studio Grand")],
        router: router,
        cache: cache
    )

    let isError = try #require(result.isError as Bool?)
    #expect(isError, "ambiguous Studio Grand name must not return State A / verified true")
    guard isError else { return }

    let response = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(response["error"] as? String == "ambiguous_target_name")
    #expect(response["ambiguous_track_indices"] as? [Int] == [1, 4])
    #expect(await channel.executedOps.isEmpty, "ambiguous selection must not reach the router")
}

@Test("Issue494: track.select by unique name keeps State A")
func issue494SelectByUniqueNameKeepsStateA() async throws {
    let router = ChannelRouter()
    let channel = Issue494StateASelectChannel()
    await router.register(channel)
    let cache = StateCache()
    await cache.updateTracks([
        TrackState(id: 7, name: "Studio Grand", type: .softwareInstrument),
    ])

    let result = await TrackDispatcher.handle(
        command: "select",
        params: ["name": .string("Studio Grand")],
        router: router,
        cache: cache
    )

    let isError = try #require(result.isError as Bool?)
    #expect(!isError)
    let response = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(try #require(response["success"] as? Bool))
    #expect(try #require(response["verified"] as? Bool))
    #expect(response["state"] as? String == "A")
    let operations = await channel.executedOps
    #expect(operations.count == 1)
    let operation = try #require(operations.first)
    #expect(operation.0 == "track.select")
    #expect(operation.1 == ["index": "7"])
}
