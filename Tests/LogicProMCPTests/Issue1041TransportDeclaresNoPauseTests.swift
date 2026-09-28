import Foundation
import MCP
import Testing
@testable import LogicProMCP

// MARK: - Issue #1041 — logic://transport does not declare a pause it never observed
//
// `TransportState.isPaused` was declared beside the four transport booleans, but nothing that
// reads Logic ever set it: every reader left the default, so the resource answered `false` for a
// paused transport. Measured live 2026-09-28 in ko: the 17 control-bar checkboxes read the same
// playing and paused, Play on in both, and a walk of 336 arrange-window elements found none whose
// title, description or help names a pause. The only thing that tells them apart is the playhead
// across two reads a beat apart -- a sequence, not a reading a state snapshot can carry. So the
// field is gone rather than filled; see `TransportState`.

@Suite("Issue #1041 — logic://transport declares no isPaused")
struct Issue1041TransportDeclaresNoPauseTests {
    /// Mutation this kills: declare `isPaused` on `TransportState` again (any default). The
    /// resource then carries the key, answering a question nothing observed.
    @Test("the transport resource carries the observed booleans and no isPaused")
    func transportResourceDeclaresNoPause() async throws {
        let cache = StateCache()
        var transport = TransportState()
        transport.isPlaying = true
        await cache.updateTransport(transport)
        await cache.updateDocumentState(true)

        let result = try await ResourceHandlers.read(
            uri: "logic://transport/state", cache: cache, router: ChannelRouter()
        )
        let text = try #require(result.contents.first?.text)
        let envelope = try #require(try sharedParseJSON(text) as? [String: Any])
        let data = try #require(envelope["data"] as? [String: Any])
        let state = try #require(data["state"] as? [String: Any])

        // The same read carries the siblings, so an absent key is not an unread state.
        #expect(state.keys.contains("isPlaying"))
        #expect(state.keys.contains("isRecording"))
        #expect(!state.keys.contains("isPaused"))
    }
}
