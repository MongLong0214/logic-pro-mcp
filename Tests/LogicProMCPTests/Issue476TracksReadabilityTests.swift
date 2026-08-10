import Foundation
import MCP
import Testing

@testable import LogicProMCP

/// #476 — `logic://tracks` answered `data: []` before its first live read, with no field saying so.
///
/// Measured against a project with two visible tracks: a cold read returned
/// `{"source":"default","fetched_at":null,"data":[]}` while `logic_tracks select {"track":0}` was
/// returning State A against those same tracks. The information that nothing had been read was
/// present only implicitly, in `source` and a null `fetched_at`. `logic://markers`, in the same
/// session, refused to be misread: `readable:false`, an explicit `reason`, and `verified_empty:false`.
@Suite("#476 logic://tracks says whether it observed anything")
struct Issue476TracksReadabilityTests {
    private func document(_ result: ReadResource.Result) throws -> [String: Any] {
        try #require(sharedJSONObject(sharedResourceText(result)))
    }

    /// No project file, so the file-count tier cannot fire and the two states under test are the
    /// ones that matter: nothing read yet, and a real live read.
    private let headlessFileReader = LogicProjectFileReader.Runtime(
        currentDocumentPath: { nil },
        now: Date.init,
        readPlistData: { _ in nil },
        mtime: { _ in nil },
        sleep: { _ in }
    )

    @Test("a cold read is marked unreadable and is not a verified empty project")
    func coldReadIsNotAnObservation() async throws {
        let cache = StateCache()
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let doc = try document(result)

        #expect(try #require(doc["source"] as? String) == "default")
        #expect(!(try #require(doc["readable"] as? Bool)))
        #expect(!(try #require(doc["verified_empty"] as? Bool)))
        #expect(try #require(doc["reason"] as? String) == "no_live_track_read_yet")
    }

    @Test("a live read of a real project is readable and not a verified empty")
    func liveReadIsAnObservation() async throws {
        let cache = StateCache()
        await cache.updateTracks([
            TrackState(id: 0, name: "Sum 1", type: .unknown),
            TrackState(id: 1, name: "Studio Grand", type: .unknown),
        ])
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let doc = try document(result)

        #expect(try #require(doc["source"] as? String) == "ax_live")
        #expect(try #require(doc["readable"] as? Bool))
        #expect(!(try #require(doc["verified_empty"] as? Bool)))
        #expect(doc["reason"] == nil)
    }

    // The third tier — placeholder names synthesised from a project-file track count — reports
    // `readable: false` with `track_names_synthesised_from_project_file` for the same reason, but it
    // needs a parsable .logicx on disk that this seam cannot fabricate, so it is covered by the live
    // check rather than here.
}
