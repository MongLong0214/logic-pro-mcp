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
        let complete = try #require(doc["complete"] as? Bool)
        #expect(!complete)
        #expect(!(try #require(doc["verified_empty"] as? Bool)))
        #expect(try #require(doc["reason"] as? String) == "no_live_track_read_yet")
    }

    @Test("MCU feedback before an AX track read cannot claim AX row provenance",
          arguments: ["solo", "selection_on", "selection_off"])
    func coldFeedbackRowsAreNotAnAXObservation(_ kind: String) async throws {
        let cache = StateCache()
        let parser = MCUFeedbackParser(cache: cache)
        await parser.handle(.noteOn(
            channel: 0, note: kind == "solo" ? 0x0F : 0x1F,
            velocity: kind == "selection_off" ? 0 : 0x7F
        ))
        #expect(await cache.getTracksFetchedAt() == .distantPast)
        let registry = TargetRegistry()
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", targetRegistry: registry,
            fileReader: headlessFileReader
        )
        let doc = try document(result)
        let rows = try #require(doc["data"] as? [[String: Any]])
        // Keep the cached scalar data compatible; do not turn generated names into observations.
        #expect(rows.count == 8)
        #expect(rows[7]["name"] as? String == "Track 8")
        // A selection LED says nothing about solo; preserve the existing unknown value.
        if kind == "solo" {
            let soloed = try #require(rows[7]["isSoloed"] as? Bool)
            #expect(soloed)
        } else {
            #expect(rows[7]["isSoloed"] == nil)
        }
        let selected = try #require(rows[7]["isSelected"] as? Bool)
        if kind == "selection_on" {
            #expect(selected)
        } else {
            #expect(!selected)
        }
        #expect(rows.allSatisfy { $0["track_ref"] == nil })
        #expect(doc["source"] as? String == "cache")
        let readable = try #require(doc["readable"] as? Bool)
        #expect(!readable)
        #expect(doc["fetched_at"] is NSNull)
        let complete = try #require(doc["complete"] as? Bool)
        let verifiedEmpty = try #require(doc["verified_empty"] as? Bool)
        #expect(!complete)
        #expect(!verifiedEmpty)
        #expect(doc["reason"] as? String == "no_live_track_read_yet")
    }

    @Test("an AX read restores observation provenance, but project invalidation clears it")
    func feedbackDoesNotCarryObservationAcrossProjects() async throws {
        let cache = StateCache()
        let parser = MCUFeedbackParser(cache: cache)
        let registry = TargetRegistry()
        try await FeatureFlags.withAdr002TargetRefForTests(true) {
            await parser.handle(.noteOn(channel: 0, note: 0x0F, velocity: 0x7F))
            await cache.updateTracks([TrackState(id: 0, name: "Observed", type: .audio)])
            let observed = try document(await ResourceHandlers.readTracks(
                cache: cache, uri: "logic://tracks", targetRegistry: registry,
                fileReader: headlessFileReader
            ))
            let observedRows = try #require(observed["data"] as? [[String: Any]])
            #expect(observed["source"] as? String == "ax_live")
            let observedReadable = try #require(observed["readable"] as? Bool)
            #expect(observedReadable)
            #expect(observed["fetched_at"] as? String != nil)
            #expect(observedRows.count == 1)
            #expect(observedRows[0]["name"] as? String == "Observed")
            #expect(observedRows[0]["track_ref"] as? String != nil)

            await cache.clearProjectState()
            await parser.handle(.noteOn(channel: 0, note: 0x1F, velocity: 0x7F))
            let reset = try document(await ResourceHandlers.readTracks(
                cache: cache, uri: "logic://tracks", targetRegistry: registry,
                fileReader: headlessFileReader
            ))
            let resetRows = try #require(reset["data"] as? [[String: Any]])
            #expect(reset["source"] as? String == "cache")
            let resetReadable = try #require(reset["readable"] as? Bool)
            #expect(!resetReadable)
            #expect(reset["fetched_at"] is NSNull)
            #expect(reset["reason"] as? String == "no_live_track_read_yet")
            #expect(resetRows.count == 8)
            #expect(resetRows.allSatisfy { $0["track_ref"] == nil })
        }
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
        #expect(doc["reason"] as? String == "track_population_not_verified")
    }

    @Test("a collapsed stack makes a live list incomplete without making its rows unreadable")
    func collapsedStackMakesLiveListIncomplete() async throws {
        let cache = StateCache()
        await cache.updateTracks([
            TrackState(
                id: 0,
                name: "Absolute Zero",
                type: .softwareInstrument,
                isStackHeader: true,
                stackCollapsed: true
            ),
            TrackState(id: 1, name: "Audio 1", type: .audio),
            TrackState(
                id: 2,
                name: "Drum Bus",
                type: .bus,
                isStackHeader: true,
                stackCollapsed: true
            ),
        ])
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let doc = try document(result)

        let readable = try #require(doc["readable"] as? Bool)
        #expect(readable)
        let complete = try #require(doc["complete"] as? Bool)
        #expect(!complete)
        let reason = try #require(doc["reason"] as? String)
        #expect(reason == "collapsed_track_stack")
        let collapsedStacks = try #require(doc["collapsed_stacks"] as? [[String: Any]])
        #expect(collapsedStacks.count == 2)
        #expect(collapsedStacks[0]["index"] as? Int == 0)
        #expect(collapsedStacks[0]["name"] as? String == "Absolute Zero")
        #expect(collapsedStacks[1]["index"] as? Int == 2)
        #expect(collapsedStacks[1]["name"] as? String == "Drum Bus")
    }

    @Test("expanded stack rows alone do not verify the whole project population")
    func expandedStackDoesNotVerifyProjectPopulation() async throws {
        let cache = StateCache()
        await cache.updateTracks([
            TrackState(
                id: 0,
                name: "Absolute Zero",
                type: .softwareInstrument,
                isStackHeader: true,
                stackCollapsed: false
            ),
            TrackState(id: 1, name: "Audio 1", type: .audio),
        ])
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let doc = try document(result)

        let complete = try #require(doc["complete"] as? Bool)
        #expect(!complete)
        #expect(doc["reason"] as? String == "track_population_not_verified")
    }

    @Test("32 readable rows cannot rule out an unsaved hidden 33rd track")
    func visibleRowCountDoesNotVerifyHiddenMembership() async throws {
        let cache = StateCache()
        await cache.updateTracks((0..<32).map { index in
            TrackState(id: index, name: "Audio \(index + 1)", type: .audio)
        })
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let doc = try document(result)
        let rows = try #require(doc["data"] as? [[String: Any]])
        #expect(rows.count == 32)
        #expect(try #require(doc["readable"] as? Bool))
        let complete = try #require(doc["complete"] as? Bool)
        #expect(!complete)
        #expect(doc["reason"] as? String == "track_population_not_verified")
        #expect(!(try #require(doc["verified_empty"] as? Bool)))
    }

    @Test("an incomplete live list is never reported as verified empty")
    func incompleteLiveReadCannotVerifyEmptiness() async throws {
        let cache = StateCache()
        await cache.updateTracks([
            TrackState(
                id: 0,
                name: "Absolute Zero",
                type: .softwareInstrument,
                isStackHeader: true,
                stackCollapsed: true
            ),
        ])
        let result = try await ResourceHandlers.readTracks(
            cache: cache, uri: "logic://tracks", fileReader: headlessFileReader
        )
        let doc = try document(result)

        let complete = try #require(doc["complete"] as? Bool)
        #expect(!complete)
        let verifiedEmpty = try #require(doc["verified_empty"] as? Bool)
        #expect(!verifiedEmpty)
    }

    // The third tier — placeholder names synthesised from a project-file track count — reports
    // `readable: false` with `track_names_synthesised_from_project_file` for the same reason, but it
    // needs a parsable .logicx on disk that this seam cannot fabricate, so it is covered by the live
    // check rather than here.
}
