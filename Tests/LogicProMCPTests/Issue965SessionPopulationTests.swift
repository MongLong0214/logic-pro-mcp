import Foundation
import Testing
@testable import LogicProMCP

// #965 O1, cache-only increment. The cases drive `build` on a hand-built Capture, except the last
// suite, which drives `capture` against a real cache; all assert on the encoded JSON, because the
// wire document is what a consumer reads.
//
// The #965 required cases (its tests section) that do not apply to a cache-only report and are therefore not tested here:
// - a missing middle page: the cache is read in one actor hop, there is no paging;
// - cancellation mid-scan: there is no scan to cancel;
// - a restoration conflict: nothing is navigated, so nothing is restored;
// - a concurrent rename between two pages: there is one snapshot, and a write that lands during
//   the capture surfaces as `cache_moved_during_capture` rather than as a torn page pair.

private typealias Observation = SessionPopulationObservation

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let freshRead = fixedNow.addingTimeInterval(-1)
private let staleRead = fixedNow.addingTimeInterval(-60)

private let baselineVersions: [CacheSectionID: StateCache.SectionVersion] = [
    .tracks: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 7),
    .mixer: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 2),
    .project: StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 1),
]

private func liveTrack(
    _ index: Int,
    name: String? = nil,
    isSelected: Bool = false,
    isStackHeader: Bool? = false,
    stackCollapsed: Bool? = nil
) -> TrackState {
    TrackState(
        id: index,
        name: name ?? "Track \(index + 1)",
        type: .audio,
        isSelected: isSelected,
        isStackHeader: isStackHeader,
        stackCollapsed: stackCollapsed
    )
}

private func liveTracks(_ count: Int) -> [TrackState] {
    (0..<count).map { liveTrack($0) }
}

private func makeCapture(
    hasDocument: Bool = true,
    axOccluded: Bool = false,
    tracks: [TrackState],
    tracksFetchedAt: Date = freshRead,
    strips: [ChannelStripState] = [],
    mixerFetchedAt: Date = .distantPast,
    versionsBefore: [CacheSectionID: StateCache.SectionVersion] = baselineVersions,
    versionsAfter: [CacheSectionID: StateCache.SectionVersion] = baselineVersions,
    fileTrackCount: Int? = nil,
    projectFileNotBound: Bool = false,
    referencesEnabled: Bool = false,
    issued: IssuedTrackReferences? = nil,
    projectIssuance: ProjectIssuance? = nil
) -> Observation.Capture {
    Observation.Capture(
        before: StateCache.CaptureBoundary(
            versions: versionsBefore,
            occlusionRevision: 0,
            hasDocument: hasDocument,
            axOccluded: axOccluded
        ),
        after: StateCache.CaptureBoundary(
            versions: versionsAfter,
            occlusionRevision: 0,
            hasDocument: hasDocument,
            axOccluded: axOccluded
        ),
        projectEpoch: 3,
        project: ProjectInfo(name: "Song", filePath: "/Users/x/Song.logicx"),
        tracks: tracks,
        tracksFetchedAt: tracksFetchedAt,
        channelStrips: strips,
        mixerFetchedAt: mixerFetchedAt,
        fileTrackCount: fileTrackCount,
        projectFileNotBound: projectFileNotBound,
        requestedProjectMatches: nil,
        referencesEnabled: referencesEnabled,
        targetSnapshot: referencesEnabled ? TargetRegistrySnapshot(projectEpoch: 3, topologyGeneration: 0) : nil,
        issued: issued,
        projectIssuance: projectIssuance,
        beganAt: fixedNow.addingTimeInterval(-0.01),
        endedAt: fixedNow,
        // Constructed fixture identity shared with its matching graph fixtures.
        captureID: "fixture_population_capture"
    )
}

private func encodedReport(
    _ capture: Observation.Capture,
    request: Observation.Request = Observation.Request()
) throws -> [String: Any] {
    let json = try encodeJSONStrict(Observation.build(request: request, capture: capture), compact: true)
    return try #require(sharedJSONObject(json))
}

private func section(_ report: [String: Any], _ key: String) throws -> [String: Any] {
    try #require(report[key] as? [String: Any], "missing section \(key)")
}

private func coverage(_ domain: [String: Any]) throws -> String {
    try #require(domain["coverage"] as? String)
}

private func reasons(_ domain: [String: Any]) throws -> [String] {
    try #require(domain["reasons"] as? [String])
}

private func rows(_ domain: [String: Any]) throws -> [[String: Any]] {
    try #require(domain["rows"] as? [[String: Any]])
}

private func overallComplete(_ report: [String: Any]) throws -> Bool {
    let overall = try section(report, "overall")
    return try #require(overall["complete"] as? Bool)
}

@Suite("#965 session population: tracks coverage")
struct Issue965TracksCoverageTests {
    @Test func coldCacheIsUnavailableNotEmpty() throws {
        let report = try encodedReport(makeCapture(tracks: [], tracksFetchedAt: .distantPast))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "unavailable")
        #expect(try reasons(tracks) == ["no_live_track_read_yet"])
        #expect(try rows(tracks).isEmpty)
        let complete = try overallComplete(report)
        #expect(!complete)
        #expect(try #require(report["read_only"] as? Bool))
        #expect(report["schema"] as? String == "logic_pro_mcp_session_population.v1")
    }

    @Test func observedEmptyRailIsPartialUnverifiedEmpty() throws {
        let report = try encodedReport(makeCapture(tracks: []))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        let observed = try reasons(tracks)
        #expect(observed.contains("unverified_empty"))
        #expect(observed.contains("hidden_tracks_unobserved"))
        let witnesses = try section(tracks, "witnesses")
        #expect(witnesses["count"] as? Int == 0)
        #expect(witnesses["first_row"] is NSNull)
        #expect(witnesses["last_row"] is NSNull)
    }

    @Test func noDocumentIsUnavailable() throws {
        let report = try encodedReport(makeCapture(hasDocument: false, tracks: []))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "unavailable")
        #expect(try reasons(tracks) == ["no_document"])
    }

    @Test func inspectorContaminationDropsTheWalkAndSaysSo() throws {
        let contaminated = [
            liveTrack(0, name: "Region:"),
            liveTrack(1, name: "Track:"),
            liveTrack(2, name: "MIDI Thru:"),
        ]
        let report = try encodedReport(makeCapture(tracks: contaminated, fileTrackCount: 3))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "unavailable")
        #expect(try reasons(tracks) == ["inspector_subtree_contamination"])
        #expect(try rows(tracks).isEmpty)
        #expect(try section(tracks, "witnesses")["count"] as? Int == 0)
    }

    @Test func duplicateNamesAndIdsArePreservedAndAmbiguityNamed() throws {
        let duplicates = [
            liveTrack(0, name: "Vocal"),
            liveTrack(1, name: "Vocal"),
            TrackState(id: 1, name: "Bass", type: .audio, isStackHeader: false),
        ]
        let report = try encodedReport(makeCapture(tracks: duplicates, fileTrackCount: 3))
        let tracks = try section(report, "tracks")
        let observed = try rows(tracks)
        #expect(observed.map { $0["name"] as? String } == ["Vocal", "Vocal", "Bass"])
        #expect(observed.map { $0["track_index"] as? Int } == [0, 1, 1])
        #expect(observed.map { $0["row"] as? Int } == [0, 1, 2])
        #expect(tracks["ambiguous_track_indices"] as? [Int] == [1])
    }

    @Test func ambiguityIsCopiedFromIssuanceWhenReferencesAreOn() throws {
        let issued = IssuedTrackReferences(
            byRow: [TargetReference(rawValue: "trk_a"), nil],
            byTrackIndex: [0: TargetReference(rawValue: "trk_a")],
            ambiguousTrackIndices: [4]
        )
        let report = try encodedReport(makeCapture(
            tracks: liveTracks(2),
            fileTrackCount: 2,
            referencesEnabled: true,
            issued: issued
        ))
        let tracks = try section(report, "tracks")
        #expect(tracks["ambiguous_track_indices"] as? [Int] == [4])
        let observed = try rows(tracks)
        #expect(observed[0]["track_ref"] as? String == "trk_a")
        #expect(observed[1]["track_ref"] == nil)
    }

    @Test func collapsedStackIsPartialWithItsRowsWitnessed() throws {
        var tracks = liveTracks(19)
        tracks[4] = liveTrack(4, isStackHeader: true, stackCollapsed: true)
        let report = try encodedReport(makeCapture(tracks: tracks, fileTrackCount: 19))
        let tracksSection = try section(report, "tracks")
        #expect(try coverage(tracksSection) == "partial")
        #expect(try reasons(tracksSection) == ["collapsed_track_stack", "count_is_the_only_end_witness"])
        #expect(tracksSection["collapsed_stack_rows"] as? [Int] == [4])
        let row = try rows(tracksSection)[4]
        #expect(try #require(row["is_stack_header"] as? Bool))
        #expect(try #require(row["stack_collapsed"] as? Bool))
    }

    @Test func unreadableStackStateIsPartialAndWrittenAsNull() throws {
        var tracks = liveTracks(19)
        tracks[7] = liveTrack(7, isStackHeader: nil)
        let report = try encodedReport(makeCapture(tracks: tracks, fileTrackCount: 19))
        let tracksSection = try section(report, "tracks")
        #expect(try coverage(tracksSection) == "partial")
        #expect(try reasons(tracksSection) == ["stack_state_unreadable", "count_is_the_only_end_witness"])
        let row = try rows(tracksSection)[7]
        #expect(row["is_stack_header"] is NSNull)
        #expect(row["stack_collapsed"] is NSNull)
        #expect(row["hidden"] as? String == "unknown")
        #expect(row["parent"] as? String == "unknown")
        #expect(row["depth"] as? String == "unknown")
        #expect(row["type_source"] as? String == "header_aggregate")
    }

    @Test func fileCountMismatchIsAReadbackGap() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(19), fileTrackCount: 20))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["track_readback_gap"])
        let witnesses = try section(tracks, "witnesses")
        #expect(witnesses["count"] as? Int == 19)
        #expect(witnesses["expected_count"] as? Int == 20)
        #expect(witnesses["expected_count_source"] as? String == "project_file")
        let matched = try #require(witnesses["expected_count_matches_rail"] as? Bool)
        #expect(!matched)
        #expect(try section(report, "sources")["expected_count"] as? String == "project_file")
    }

    // Counts alone do not establish completion (#965): a clean rail whose count matches the file
    // keeps the count as evidence and stays partial, because nothing witnesses where it ends.
    @Test func matchingFileCountOnACleanRailIsEvidenceNotCompleteness() throws {
        let report = try encodedReport(
            makeCapture(tracks: liveTracks(19), fileTrackCount: 19),
            request: Observation.Request(domains: [.tracks])
        )
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["count_is_the_only_end_witness"])
        let witnesses = try section(tracks, "witnesses")
        #expect(witnesses["first_row"] as? Int == 0)
        #expect(witnesses["last_row"] as? Int == 18)
        #expect(witnesses["count"] as? Int == 19)
        #expect(witnesses["expected_count"] as? Int == 19)
        let matched = try #require(witnesses["expected_count_matches_rail"] as? Bool)
        #expect(matched)
        let complete = try overallComplete(report)
        #expect(!complete)
        #expect(try section(report, "overall")["incomplete_domains"] as? [String] == ["tracks"])
    }

    // SP-01: rows the poller kept after failed reads, with a count that happens to match.
    @Test func staleRowsWithAMatchingCountAreNotComplete() throws {
        let report = try encodedReport(
            makeCapture(tracks: liveTracks(19), tracksFetchedAt: staleRead, fileTrackCount: 19),
            request: Observation.Request(domains: [.tracks])
        )
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["track_cache_stale", "count_is_the_only_end_witness"])
        let complete = try overallComplete(report)
        #expect(!complete)
    }

    @Test func matchingFileCountNeverUpgradesACollapsedStack() throws {
        var tracks = liveTracks(19)
        tracks[0] = liveTrack(0, isStackHeader: true, stackCollapsed: true)
        let report = try encodedReport(
            makeCapture(tracks: tracks, fileTrackCount: 19),
            request: Observation.Request(domains: [.tracks])
        )
        let tracksSection = try section(report, "tracks")
        #expect(try coverage(tracksSection) == "partial")
        #expect(try reasons(tracksSection) == ["collapsed_track_stack", "count_is_the_only_end_witness"])
        let complete = try overallComplete(report)
        #expect(!complete)
    }

    @Test func missingFileCountLeavesHiddenTracksUnobserved() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(19), fileTrackCount: nil))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["hidden_tracks_unobserved"])
        let witnesses = try section(tracks, "witnesses")
        #expect(witnesses["expected_count"] == nil)
        #expect(witnesses["expected_count_source"] == nil)
        #expect(witnesses["expected_count_matches_rail"] == nil)
    }

    @Test func occludedAXIsPartialEvenWhenTheCountMatches() throws {
        let report = try encodedReport(makeCapture(axOccluded: true, tracks: liveTracks(19), fileTrackCount: 19))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["ax_occluded", "count_is_the_only_end_witness"])
    }
}

@Suite("#965 session population: strips, associations, hierarchy")
struct Issue965StripsAndDomainsTests {
    @Test func twentyOneStripsAgainstNineteenRowsClaimNoAssociation() throws {
        let strips = (0..<21).map { ChannelStripState(trackIndex: $0) }
        let report = try encodedReport(makeCapture(
            tracks: liveTracks(19),
            strips: strips,
            mixerFetchedAt: freshRead,
            fileTrackCount: 19
        ))
        let stripsSection = try section(report, "strips")
        #expect(try section(stripsSection, "witnesses")["count"] as? Int == 21)
        #expect(try section(try section(report, "tracks"), "witnesses")["count"] as? Int == 19)
        let stripRows = try rows(stripsSection)
        #expect(stripRows.count == 21)
        for row in stripRows {
            #expect(row["name"] is NSNull)
            #expect(row["name_status"] as? String == "not_read")
            #expect(row["strip_ref"] == nil)
            #expect(row["type"] == nil)
        }
        let stripsJSON = try String(decoding: JSONSerialization.data(withJSONObject: stripsSection), as: UTF8.self)
        #expect(!stripsJSON.contains("aux"))
        let associations = try section(report, "associations")
        #expect(try coverage(associations) == "unavailable")
        #expect(try reasons(associations) == ["no_observed_association_evidence"])
    }

    @Test func hierarchyIsNeverObservedFromTheCache() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(3), fileTrackCount: 3))
        let hierarchy = try section(report, "hierarchy")
        #expect(try coverage(hierarchy) == "unavailable")
        #expect(try reasons(hierarchy) == ["parent_depth_not_observed"])
    }

    @Test func mixerColdIsUnavailable() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(3), mixerFetchedAt: .distantPast))
        let strips = try section(report, "strips")
        #expect(try coverage(strips) == "unavailable")
        #expect(try reasons(strips) == ["mixer_not_visible"])
        #expect(try section(report, "sources")["strips"] as? String == "mixer_not_visible")
    }

    @Test func mixerStaleIsPartial() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(3), mixerFetchedAt: staleRead))
        let strips = try section(report, "strips")
        #expect(try coverage(strips) == "partial")
        #expect(try reasons(strips) == ["mixer_cache_stale"])
        #expect(try section(report, "sources")["strips"] as? String == "cache_stale")
    }

    @Test func mixerFreshIsStillPartialBecauseFiltersAreUnread() throws {
        let strips = [ChannelStripState(trackIndex: 0, output: "Stereo Out", plugins: [], pluginsSource: "ax")]
        let report = try encodedReport(makeCapture(tracks: liveTracks(3), strips: strips, mixerFetchedAt: freshRead))
        let stripsSection = try section(report, "strips")
        #expect(try coverage(stripsSection) == "partial")
        #expect(try reasons(stripsSection) == ["mixer_filters_unread"])
        #expect(try section(report, "sources")["strips"] as? String == "ax_poll")
        let row = try rows(stripsSection)[0]
        #expect(row["strip_index"] as? Int == 0)
        #expect(row["output"] as? String == "Stereo Out")
        #expect(row["plugin_count"] as? Int == 0)
        #expect(row["plugins_source"] as? String == "ax")
    }

    @Test func routingAndColorAppearOnlyWhenRequested() throws {
        let capture = makeCapture(tracks: liveTracks(3), fileTrackCount: 3)
        let unrequested = try encodedReport(capture)
        #expect(unrequested["routing"] == nil)
        #expect(unrequested["color"] == nil)

        let requested = try encodedReport(
            capture,
            request: Observation.Request(domains: [.tracks, .routing, .color])
        )
        // The mixer was never polled in this capture, so the graph built for the section has
        // nothing to say about any strip (#291).
        let routing = try section(requested, "routing")
        #expect(try coverage(routing) == "unavailable")
        #expect(try reasons(routing) == ["routing_graph_unavailable"])
        #expect(routing["snapshot_id"] as? String == requested["snapshot_id"] as? String)
        let graph = try #require(routing["graph"] as? [String: Any])
        let population = try #require(graph["population"] as? [String: Any])
        #expect(population["state"] as? String == "unavailable")
        let color = try section(requested, "color")
        #expect(try coverage(color) == "unavailable")
        #expect(try reasons(color) == ["color_deferred_to_issue_970"])
        #expect(try section(requested, "overall")["incomplete_domains"] as? [String] == ["tracks", "routing", "color"])
        #expect(requested["requested_domains"] as? [String] == ["tracks", "routing", "color"])
    }
}

@Suite("#965 session population: stability, scope, references")
struct Issue965StabilityScopeReferenceTests {
    @Test func snapshotIdNamesTheImmutableCapture() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(2), fileTrackCount: 2))
        #expect(report["snapshot_id"] as? String == "fixture_population_capture")
    }

    @Test func aCacheThatMovedDuringCaptureMakesEveryRequestedDomainUnstable() throws {
        var after = baselineVersions
        after[.tracks] = StateCache.SectionVersion(projectEpoch: 3, sectionRevision: 8)
        let report = try encodedReport(
            makeCapture(
                tracks: liveTracks(19),
                strips: [ChannelStripState(trackIndex: 0)],
                mixerFetchedAt: freshRead,
                versionsAfter: after,
                fileTrackCount: 19
            ),
            request: Observation.Request(domains: Observation.Domain.allCases)
        )
        for key in ["tracks", "strips", "associations", "hierarchy", "routing", "color"] {
            let domain = try section(report, key)
            #expect(try coverage(domain) == "unstable", Comment(rawValue: key))
            #expect(try reasons(domain) == ["cache_moved_during_capture"], Comment(rawValue: key))
        }
        let complete = try overallComplete(report)
        #expect(!complete)
        #expect(report["snapshot_id"] as? String == "fixture_population_capture")
    }

    @Test func selectionScopeKeepsOriginalRowNumbers() throws {
        var tracks = liveTracks(5)
        tracks[1] = liveTrack(1, isSelected: true)
        tracks[3] = liveTrack(3, isSelected: true)
        let report = try encodedReport(
            makeCapture(tracks: tracks, fileTrackCount: 5),
            request: Observation.Request(scope: .selection, domains: [.tracks])
        )
        #expect(report["scope"] as? String == "selection")
        let tracksSection = try section(report, "tracks")
        let observed = try rows(tracksSection)
        #expect(observed.map { $0["row"] as? Int } == [1, 3])
        #expect(observed.map { $0["track_index"] as? Int } == [1, 3])
        let witnesses = try section(tracksSection, "witnesses")
        #expect(witnesses["first_row"] as? Int == 1)
        #expect(witnesses["last_row"] as? Int == 3)
        #expect(witnesses["count"] as? Int == 2)
        #expect(witnesses["expected_count"] as? Int == 5)
        #expect(try coverage(tracksSection) == "partial")
        #expect(try reasons(tracksSection) == ["count_is_the_only_end_witness", "selection_state_unverified"])
    }

    // SP-03: the selected header's AXSelected read failed, which the AX reader folds into `false`,
    // while its name and stack fields read. Every row therefore reads unselected.
    @Test func anUnreadableSelectionIsNotAnObservedEmptySelection() throws {
        let report = try encodedReport(
            makeCapture(tracks: liveTracks(19), fileTrackCount: 19),
            request: Observation.Request(scope: .selection, domains: [.tracks])
        )
        let tracksSection = try section(report, "tracks")
        #expect(try rows(tracksSection).isEmpty)
        #expect(try coverage(tracksSection) == "partial")
        #expect(try reasons(tracksSection) == ["count_is_the_only_end_witness", "selection_state_unverified"])
        let complete = try overallComplete(report)
        #expect(!complete)
    }

    @Test func referencesDisabledLeavesCoverageAloneAndIssuesNothing() throws {
        let report = try encodedReport(
            makeCapture(tracks: liveTracks(19), fileTrackCount: 19, referencesEnabled: false, issued: nil),
            request: Observation.Request(domains: [.tracks])
        )
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["count_is_the_only_end_witness"])
        for row in try rows(tracks) {
            #expect(row["track_ref"] == nil)
        }
        let project = try section(report, "project")
        #expect(project["status"] as? String == "references_disabled")
        #expect(project["project_ref"] == nil)
        #expect(project["name"] as? String == "Song")
        #expect(project["file_path"] as? String == "/Users/x/Song.logicx")
        #expect(project["project_epoch"] as? Int == 3)
    }

    @Test func staleIssuanceWhileReferencesAreOnIsUnstableWithoutReferences() throws {
        let report = try encodedReport(makeCapture(
            tracks: liveTracks(19),
            fileTrackCount: 19,
            referencesEnabled: true,
            issued: nil,
            projectIssuance: .stale
        ))
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "unstable")
        #expect(try reasons(tracks) == ["target_snapshot_stale"])
        for row in try rows(tracks) {
            #expect(row["track_ref"] == nil)
        }
        #expect(try section(report, "project")["status"] as? String == "stale")
    }

    @Test func issuedReferencesRideEachRowAndTheProject() throws {
        let references = (0..<3).map { TargetReference(rawValue: "trk_\($0)") }
        let issued = IssuedTrackReferences(
            byRow: references,
            byTrackIndex: Dictionary(uniqueKeysWithValues: references.enumerated().map { ($0.offset, $0.element) }),
            ambiguousTrackIndices: []
        )
        let report = try encodedReport(makeCapture(
            tracks: liveTracks(3),
            fileTrackCount: 3,
            referencesEnabled: true,
            issued: issued,
            projectIssuance: .issued(TargetReference(rawValue: "prj_song"))
        ))
        let tracks = try section(report, "tracks")
        #expect(try rows(tracks).map { $0["track_ref"] as? String } == ["trk_0", "trk_1", "trk_2"])
        let project = try section(report, "project")
        #expect(project["status"] as? String == "issued")
        #expect(project["project_ref"] as? String == "prj_song")
    }

    @Test func unobservedProjectIdentityIsNamed() throws {
        let issued = IssuedTrackReferences(byRow: [], byTrackIndex: [:], ambiguousTrackIndices: [])
        let report = try encodedReport(makeCapture(
            tracks: [],
            referencesEnabled: true,
            issued: issued,
            projectIssuance: .unobserved(reason: ProjectReferenceIssuance.unobservedReason)
        ))
        #expect(try section(report, "project")["status"] as? String == "unobserved")
    }

    @Test func reportPromisesNoUIEffectAndNamesItsSources() throws {
        let report = try encodedReport(makeCapture(tracks: liveTracks(1), fileTrackCount: 1))
        let effects = try section(report, "ui_effects")
        let navigated = try #require(effects["navigation_performed"] as? Bool)
        #expect(!navigated)
        #expect(effects["restoration"] as? String == "not_applicable")
        let sources = try section(report, "sources")
        #expect(sources["tracks"] as? String == "ax_poll_cache")
        let window = try section(report, "capture")
        #expect(window["began_at"] as? String == "2023-11-14T22:13:19.990Z")
        #expect(window["ended_at"] as? String == "2023-11-14T22:13:20.000Z")
    }
}

// Through `capture`, not a hand-built Capture: the cache is written from inside the asynchronous
// file read, the one await `capture` makes that a test can reach, and `fileReader` is the seam.
// No registry is passed, so nothing here depends on the reference flag.
@Suite("#965 session population: capture")
struct Issue965CaptureTests {
    private func populatedCache(projectPath: String = "/Users/x/Song.logicx") async -> StateCache {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Song", filePath: projectPath))
        await cache.updateTracks(liveTracks(3))
        return cache
    }

    /// A reader whose front-document query runs `duringRead`, then names no document.
    private func reader(duringRead: @escaping @Sendable () async -> Void) -> LogicProjectFileReader.Runtime {
        LogicProjectFileReader.Runtime(
            currentDocumentPath: {
                await duringRead()
                return nil
            },
            now: { fixedNow },
            readPlistData: { _ in nil },
            mtime: { _ in nil },
            sleep: { _ in }
        )
    }

    private func captureReport(
        _ cache: StateCache,
        reader: LogicProjectFileReader.Runtime,
        domains: [Observation.Domain]
    ) async throws -> [String: Any] {
        let capture = await Observation.capture(cache: cache, targetRegistry: nil, fileReader: reader, now: { fixedNow })
        return try encodedReport(capture, request: Observation.Request(domains: domains))
    }

    private func expectEveryDomainUnstable(_ report: [String: Any]) throws {
        for key in ["tracks", "strips", "associations", "hierarchy", "routing", "color"] {
            let domain = try section(report, key)
            #expect(try coverage(domain) == "unstable", Comment(rawValue: key))
            #expect(try reasons(domain) == ["cache_moved_during_capture"], Comment(rawValue: key))
        }
        let complete = try overallComplete(report)
        #expect(!complete)
    }

    // SP-02: `updateAXOccluded` advances no section version, so versions alone cannot see it move.
    @Test func anOcclusionFlipDuringTheFileReadMakesEveryRequestedDomainUnstable() async throws {
        let quiet = await populatedCache()
        let control = try await captureReport(quiet, reader: reader(duringRead: {}), domains: Observation.Domain.allCases)
        #expect(try coverage(try section(control, "tracks")) == "partial")

        let cache = await populatedCache()
        let report = try await captureReport(
            cache,
            reader: reader(duringRead: { await cache.updateAXOccluded(true) }),
            domains: Observation.Domain.allCases
        )
        let occludedAfterCapture = await cache.getAXOccluded()
        #expect(occludedAfterCapture)
        try expectEveryDomainUnstable(report)
    }

    // SP-02: occlusion ends where it began, so comparing the flag value sees nothing; only the
    // occlusion revision can tell this capture from a quiet one.
    @Test func anOcclusionThatFlipsAndFlipsBackDuringTheFileReadMakesEveryRequestedDomainUnstable() async throws {
        let cache = await populatedCache()
        let report = try await captureReport(
            cache,
            reader: reader(duringRead: {
                await cache.updateAXOccluded(true)
                await cache.updateAXOccluded(false)
            }),
            domains: Observation.Domain.allCases
        )
        let occludedAfterCapture = await cache.getAXOccluded()
        #expect(!occludedAfterCapture)
        try expectEveryDomainUnstable(report)
    }

    // The document flag ends where it began too; the project epoch that updateDocumentState(false)
    // advances through clearProjectState is what moves the watched versions.
    @Test func aDocumentThatGoesAndComesBackDuringTheFileReadMakesEveryRequestedDomainUnstable() async throws {
        let cache = await populatedCache()
        let report = try await captureReport(
            cache,
            reader: reader(duringRead: {
                await cache.updateDocumentState(false)
                await cache.updateDocumentState(true)
            }),
            domains: Observation.Domain.allCases
        )
        let documentAfterCapture = await cache.getHasDocument()
        #expect(documentAfterCapture)
        try expectEveryDomainUnstable(report)
    }

    @Test func aTrackWriteDuringTheFileReadMakesEveryRequestedDomainUnstable() async throws {
        let cache = await populatedCache()
        let report = try await captureReport(
            cache,
            reader: reader(duringRead: { await cache.updateTracks(liveTracks(4)) }),
            domains: Observation.Domain.allCases
        )
        let tracksAfterCapture = await cache.getTracks()
        #expect(tracksAfterCapture.count == 4)
        try expectEveryDomainUnstable(report)
    }

    // SP-01: the reader reads Logic's front document, Other.logicx, whose three tracks match the
    // three rows the cache holds for Song.logicx. The control in the same run points the cache at
    // the bundle the reader reads, through `/var` where the reader resolves to `/private/var`.
    @Test func aForeignProjectFileWhoseCountMatchesIsNotAnExpectedCount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue965-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreign = directory.appendingPathComponent("Other.logicx", isDirectory: true)
        let alternative = foreign.appendingPathComponent("Alternatives/000", isDirectory: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)
        try Data().write(to: alternative.appendingPathComponent("MetaData.plist"))
        let reader = LogicProjectFileReader.Runtime(
            currentDocumentPath: { foreign.path },
            now: { fixedNow },
            readPlistData: { _ in
                try? PropertyListSerialization.data(fromPropertyList: ["NumberOfTracks": 3], format: .binary, options: 0)
            },
            mtime: { _ in fixedNow },
            sleep: { _ in }
        )

        let boundCache = await populatedCache(projectPath: foreign.path)
        let bound = try await captureReport(boundCache, reader: reader, domains: [.tracks])
        let boundTracks = try section(bound, "tracks")
        #expect(try reasons(boundTracks) == ["count_is_the_only_end_witness"])
        #expect(try section(boundTracks, "witnesses")["expected_count"] as? Int == 3)

        let foreignCache = await populatedCache(projectPath: directory.appendingPathComponent("Song.logicx").path)
        let report = try await captureReport(foreignCache, reader: reader, domains: [.tracks])
        let tracks = try section(report, "tracks")
        #expect(try coverage(tracks) == "partial")
        #expect(try reasons(tracks) == ["project_file_not_bound", "hidden_tracks_unobserved"])
        let witnesses = try section(tracks, "witnesses")
        #expect(witnesses["count"] as? Int == 3)
        #expect(witnesses["expected_count"] == nil)
        #expect(witnesses["expected_count_matches_rail"] == nil)
        let complete = try overallComplete(report)
        #expect(!complete)
    }
}
