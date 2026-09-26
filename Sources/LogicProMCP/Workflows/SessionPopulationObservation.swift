import Foundation

/// #965 O1, first increment: what populates the open session, read from the poll cache alone.
///
/// The report answers "what is in this session?" without an AX call, without navigating and
/// without restoring anything. Every domain carries a `coverage` and the reasons it is not
/// `complete`, so a consumer can tell a rail that was read from one that was not, an empty read
/// from a failed read, and a count that happens to match from a row set that is actually known.
/// The cache cannot see hidden tracks, stack children behind a collapsed header, strip names, or
/// which strip belongs to which track, and the report says so instead of leaving those absent.
enum SessionPopulationObservation {
    static let schema = "logic_pro_mcp_session_population.v1"

    enum Domain: String, CaseIterable, Sendable, Encodable {
        case tracks
        case strips
        case associations
        case hierarchy
        case routing
        case color
    }

    enum Scope: String, CaseIterable, Sendable, Encodable {
        case wholeProject = "whole_project"
        case selection
    }

    enum Coverage: String, CaseIterable, Sendable, Encodable {
        case complete
        case partial
        case unavailable
        case unstable
    }

    enum ProjectStatus: String, Sendable, Encodable {
        case issued
        case unobserved
        case stale
        case referencesDisabled = "references_disabled"
    }

    /// The wire tokens carried under `reasons`. Tests assert the literal strings, not these names.
    enum Reason: String, Sendable, Encodable {
        case cacheMovedDuringCapture = "cache_moved_during_capture"
        case noDocument = "no_document"
        case noLiveTrackReadYet = "no_live_track_read_yet"
        case inspectorSubtreeContamination = "inspector_subtree_contamination"
        case targetSnapshotStale = "target_snapshot_stale"
        case axOccluded = "ax_occluded"
        case unverifiedEmpty = "unverified_empty"
        case collapsedTrackStack = "collapsed_track_stack"
        case stackStateUnreadable = "stack_state_unreadable"
        case hiddenTracksUnobserved = "hidden_tracks_unobserved"
        case trackReadbackGap = "track_readback_gap"
        case mixerNotVisible = "mixer_not_visible"
        case mixerCacheStale = "mixer_cache_stale"
        case mixerFiltersUnread = "mixer_filters_unread"
        case noObservedAssociationEvidence = "no_observed_association_evidence"
        case parentDepthNotObserved = "parent_depth_not_observed"
        case routingDeferredToIssue291R1 = "routing_deferred_to_issue_291_r1"
        case colorDeferredToIssue970 = "color_deferred_to_issue_970"
    }

    struct Request: Sendable {
        static let defaultDomains: [Domain] = [.tracks, .strips, .associations, .hierarchy]

        var scope: Scope
        var domains: [Domain]
        var allowUINavigation: Bool
        var projectRef: String?

        init(
            scope: Scope = .wholeProject,
            domains: [Domain] = Request.defaultDomains,
            allowUINavigation: Bool = false,
            projectRef: String? = nil
        ) {
            self.scope = scope
            self.domains = domains
            self.allowUINavigation = allowUINavigation
            self.projectRef = projectRef
        }
    }

    /// One reading of the cache and the registry, taken by `capture` and consumed by `build`.
    ///
    /// `versionsBefore` and `versionsAfter` bracket the reading: any section whose version differs
    /// between them moved while the capture was in flight, and the report then refuses to call any
    /// domain better than `unstable`.
    struct Capture: Sendable {
        let hasDocument: Bool
        let axOccluded: Bool
        let projectEpoch: UInt64
        let project: ProjectInfo
        let tracks: [TrackState]
        let tracksFetchedAt: Date
        let channelStrips: [ChannelStripState]
        let mixerFetchedAt: Date
        let versionsBefore: [CacheSectionID: StateCache.SectionVersion]
        let versionsAfter: [CacheSectionID: StateCache.SectionVersion]
        /// `NumberOfTracks` from the project bundle's MetaData.plist, or nil when the bundle could
        /// not be read. It is the one count the rail did not produce, which is what makes it an
        /// expected count rather than a restatement of the rows.
        let fileTrackCount: Int?
        let referencesEnabled: Bool
        /// Nil while `referencesEnabled` means the registry moved on during issuance.
        let issued: IssuedTrackReferences?
        let projectIssuance: ProjectIssuance?
        let beganAt: Date
        let endedAt: Date
    }

    /// The sections whose movement during capture makes the report unstable.
    static let watchedSections: [CacheSectionID] = [.tracks, .mixer, .project]

    /// Reads the cache once. No AX call, no navigation, no cache write.
    ///
    /// References are issued through the same two issuers `logic://tracks` and `logic://mixer` use,
    /// under the same gate (`FeatureFlags.adr002TargetRef` and a registry), so a `track_ref` here
    /// is the reference those resources return for the same observed row.
    static func capture(
        cache: StateCache,
        targetRegistry: TargetRegistry?,
        fileReader: LogicProjectFileReader.Runtime,
        now: @Sendable () -> Date = Date.init
    ) async -> Capture {
        let beganAt = now()
        var versionsBefore: [CacheSectionID: StateCache.SectionVersion] = [:]
        for section in watchedSections {
            versionsBefore[section] = await cache.currentVersion(for: section)
        }
        let snapshot = await cache.auditSnapshot()

        let targetSnapshot: TargetRegistrySnapshot?
        if FeatureFlags.adr002TargetRef, let targetRegistry {
            targetSnapshot = await targetRegistry.currentSnapshot
        } else {
            targetSnapshot = nil
        }

        let fileTrackCount = await LogicProjectFileReader.read(runtime: fileReader)?.trackCount

        var issued: IssuedTrackReferences?
        var projectIssuance: ProjectIssuance?
        if FeatureFlags.adr002TargetRef, let targetRegistry, let targetSnapshot {
            issued = await TrackReferenceIssuance.issue(
                for: TrackReferenceIssuance.liveInventory(snapshot.tracks),
                registry: targetRegistry,
                snapshot: targetSnapshot
            )
            projectIssuance = await ProjectReferenceIssuance.issue(
                name: snapshot.project.name,
                filePath: snapshot.project.filePath,
                registry: targetRegistry,
                snapshot: targetSnapshot
            )
        }

        var versionsAfter: [CacheSectionID: StateCache.SectionVersion] = [:]
        for section in watchedSections {
            versionsAfter[section] = await cache.currentVersion(for: section)
        }
        let endedAt = now()

        return Capture(
            hasDocument: snapshot.hasDocument,
            axOccluded: snapshot.axOccluded,
            projectEpoch: snapshot.projectEpoch,
            project: snapshot.project,
            tracks: snapshot.tracks,
            tracksFetchedAt: snapshot.tracksFetchedAt,
            channelStrips: snapshot.channelStrips,
            mixerFetchedAt: snapshot.mixerFetchedAt,
            versionsBefore: versionsBefore,
            versionsAfter: versionsAfter,
            fileTrackCount: fileTrackCount,
            referencesEnabled: targetSnapshot != nil,
            issued: issued,
            projectIssuance: projectIssuance,
            beganAt: beganAt,
            endedAt: endedAt
        )
    }

    // MARK: - Report

    struct Report: Encodable, Sendable {
        let schema: String
        let readOnly: Bool
        /// Names the cache revision the report was built from: `snap_<epoch>_t<tracks>_m<mixer>_p<project>`
        /// from the versions captured before the read. Emitted only; nothing consumes it in this
        /// increment. Retention rule: it names a cache revision, not a stored capture, so a later
        /// call can compare it against its own to see whether the cache moved, but nothing can be
        /// fetched by it.
        let snapshotId: String
        let scope: Scope
        let requestedDomains: [Domain]
        let project: ProjectSection
        let capture: CaptureWindow
        let sources: Sources
        let tracks: TracksSection
        let strips: StripsSection
        let associations: DomainSection
        let hierarchy: DomainSection
        let routing: DomainSection?
        let color: DomainSection?
        let overall: Overall
        let uiEffects: UIEffects

        enum CodingKeys: String, CodingKey {
            case schema
            case readOnly = "read_only"
            case snapshotId = "snapshot_id"
            case scope
            case requestedDomains = "requested_domains"
            case project
            case capture
            case sources
            case tracks
            case strips
            case associations
            case hierarchy
            case routing
            case color
            case overall
            case uiEffects = "ui_effects"
        }
    }

    struct ProjectSection: Encodable, Sendable {
        let status: ProjectStatus
        let projectRef: String?
        let name: String
        let filePath: String?
        let projectEpoch: UInt64

        enum CodingKeys: String, CodingKey {
            case status
            case projectRef = "project_ref"
            case name
            case filePath = "file_path"
            case projectEpoch = "project_epoch"
        }
    }

    struct CaptureWindow: Encodable, Sendable {
        let beganAt: String
        let endedAt: String

        enum CodingKeys: String, CodingKey {
            case beganAt = "began_at"
            case endedAt = "ended_at"
        }
    }

    struct Sources: Encodable, Sendable {
        let tracks: String
        let strips: String
        let expectedCount: String

        enum CodingKeys: String, CodingKey {
            case tracks
            case strips
            case expectedCount = "expected_count"
        }
    }

    struct TrackRow: Encodable, Sendable {
        let row: Int
        let trackIndex: Int
        let name: String
        let type: String
        let typeSource = "header_aggregate"
        let isStackHeader: Bool?
        let stackCollapsed: Bool?
        let hidden = "unknown"
        let parent = "unknown"
        let depth = "unknown"
        let isSelected: Bool
        let placeholder: Bool?
        let trackRef: String?

        enum CodingKeys: String, CodingKey {
            case row
            case trackIndex = "track_index"
            case name
            case type
            case typeSource = "type_source"
            case isStackHeader = "is_stack_header"
            case stackCollapsed = "stack_collapsed"
            case hidden
            case parent
            case depth
            case isSelected = "is_selected"
            case placeholder
            case trackRef = "track_ref"
        }

        // The three readback fields are written as explicit nulls: a header whose stack state
        // could not be examined is a different observation from one that is not a stack, and an
        // omitted key would let a consumer read the two the same way.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(row, forKey: .row)
            try container.encode(trackIndex, forKey: .trackIndex)
            try container.encode(name, forKey: .name)
            try container.encode(type, forKey: .type)
            try container.encode(typeSource, forKey: .typeSource)
            try container.encode(isStackHeader, forKey: .isStackHeader)
            try container.encode(stackCollapsed, forKey: .stackCollapsed)
            try container.encode(hidden, forKey: .hidden)
            try container.encode(parent, forKey: .parent)
            try container.encode(depth, forKey: .depth)
            try container.encode(isSelected, forKey: .isSelected)
            try container.encode(placeholder, forKey: .placeholder)
            try container.encodeIfPresent(trackRef, forKey: .trackRef)
        }
    }

    struct TrackWitnesses: Encodable, Sendable {
        let firstRow: Int?
        let lastRow: Int?
        let count: Int
        let expectedCount: Int?
        let expectedCountSource: String?

        enum CodingKeys: String, CodingKey {
            case firstRow = "first_row"
            case lastRow = "last_row"
            case count
            case expectedCount = "expected_count"
            case expectedCountSource = "expected_count_source"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(firstRow, forKey: .firstRow)
            try container.encode(lastRow, forKey: .lastRow)
            try container.encode(count, forKey: .count)
            try container.encodeIfPresent(expectedCount, forKey: .expectedCount)
            try container.encodeIfPresent(expectedCountSource, forKey: .expectedCountSource)
        }
    }

    struct TracksSection: Encodable, Sendable {
        let coverage: Coverage
        let reasons: [Reason]
        let witnesses: TrackWitnesses
        let rows: [TrackRow]
        let ambiguousTrackIndices: [Int]
        let collapsedStackRows: [Int]

        enum CodingKeys: String, CodingKey {
            case coverage
            case reasons
            case witnesses
            case rows
            case ambiguousTrackIndices = "ambiguous_track_indices"
            case collapsedStackRows = "collapsed_stack_rows"
        }
    }

    struct StripRow: Encodable, Sendable {
        let stripIndex: Int
        let nameStatus = "not_read"
        let output: String?
        let input: String?
        let pluginCount: Int
        let pluginsSource: String?

        enum CodingKeys: String, CodingKey {
            case stripIndex = "strip_index"
            case name
            case nameStatus = "name_status"
            case output
            case input
            case pluginCount = "plugin_count"
            case pluginsSource = "plugins_source"
        }

        // `name` is written as an explicit null beside `name_status`: the poller never reads a
        // strip's name, and a strip with no `name` key would read as one that has none.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stripIndex, forKey: .stripIndex)
            try container.encodeNil(forKey: .name)
            try container.encode(nameStatus, forKey: .nameStatus)
            try container.encodeIfPresent(output, forKey: .output)
            try container.encodeIfPresent(input, forKey: .input)
            try container.encode(pluginCount, forKey: .pluginCount)
            try container.encodeIfPresent(pluginsSource, forKey: .pluginsSource)
        }
    }

    struct StripWitnesses: Encodable, Sendable {
        let count: Int
    }

    struct StripsSection: Encodable, Sendable {
        let coverage: Coverage
        let reasons: [Reason]
        let witnesses: StripWitnesses
        let rows: [StripRow]
    }

    struct DomainSection: Encodable, Sendable {
        let coverage: Coverage
        let reasons: [Reason]
    }

    struct Overall: Encodable, Sendable {
        let complete: Bool
        let incompleteDomains: [Domain]

        enum CodingKeys: String, CodingKey {
            case complete
            case incompleteDomains = "incomplete_domains"
        }
    }

    struct UIEffects: Encodable, Sendable {
        let navigationPerformed = false
        let restoration = "not_applicable"

        enum CodingKeys: String, CodingKey {
            case navigationPerformed = "navigation_performed"
            case restoration
        }
    }

    // MARK: - Build

    /// Pure: the same capture and request always produce the same report.
    static func build(request: Request, capture: Capture) -> Report {
        let moved = watchedSections.contains { section in
            capture.versionsBefore[section] != capture.versionsAfter[section]
        }

        // The rail as `logic://tracks` sees it: an Inspector-contaminated walk is dropped whole.
        let live = TrackReferenceIssuance.liveInventory(capture.tracks)
        let contaminated = live.isEmpty && !capture.tracks.isEmpty
        let referencesStale = capture.referencesEnabled && capture.issued == nil
        let issued = capture.referencesEnabled ? capture.issued : nil

        let allRows: [TrackRow] = live.enumerated().map { index, track in
            var reference: String?
            if let issued, index < issued.byRow.count {
                reference = issued.byRow[index]?.rawValue
            }
            return TrackRow(
                row: index,
                trackIndex: track.id,
                name: track.name,
                type: track.type.rawValue,
                isStackHeader: track.isStackHeader,
                stackCollapsed: track.stackCollapsed,
                isSelected: track.isSelected,
                placeholder: track.placeholder,
                trackRef: reference
            )
        }
        let collapsedStackRows = live.enumerated().compactMap { index, track in
            track.stackCollapsed == true ? index : nil
        }
        let ambiguousTrackIndices = issued?.ambiguousTrackIndices ?? duplicateTrackIndices(in: live)

        // Coverage describes the rail that was read; the scope only narrows which rows are shown.
        let tracksCoverage: Coverage
        var tracksReasons: [Reason] = []
        if moved {
            tracksCoverage = .unstable
            tracksReasons = [.cacheMovedDuringCapture]
        } else if !capture.hasDocument {
            tracksCoverage = .unavailable
            tracksReasons = [.noDocument]
        } else if capture.tracksFetchedAt == .distantPast {
            tracksCoverage = .unavailable
            tracksReasons = [.noLiveTrackReadYet]
        } else if contaminated {
            tracksCoverage = .unavailable
            tracksReasons = [.inspectorSubtreeContamination]
        } else if referencesStale {
            tracksCoverage = .unstable
            tracksReasons = [.targetSnapshotStale]
        } else {
            if capture.axOccluded {
                tracksReasons.append(.axOccluded)
            }
            if live.isEmpty {
                // The cache cannot tell a failed rail read from an empty rail.
                tracksReasons.append(.unverifiedEmpty)
            }
            if !collapsedStackRows.isEmpty {
                tracksReasons.append(.collapsedTrackStack)
            }
            if live.contains(where: { $0.isStackHeader == nil }) {
                tracksReasons.append(.stackStateUnreadable)
            }
            if let expected = capture.fileTrackCount {
                if expected == live.count {
                    // The count agrees; it cannot upgrade a row set that carries another reason.
                } else {
                    tracksReasons.append(.trackReadbackGap)
                }
            } else {
                // Without an independent expected count nothing rules out rows the rail does not show.
                tracksReasons.append(.hiddenTracksUnobserved)
            }
            tracksCoverage = tracksReasons.isEmpty ? .complete : .partial
        }

        let rows: [TrackRow]
        switch request.scope {
        case .wholeProject:
            rows = allRows
        case .selection:
            rows = allRows.filter(\.isSelected)
        }
        let tracks = TracksSection(
            coverage: tracksCoverage,
            reasons: tracksReasons,
            witnesses: TrackWitnesses(
                firstRow: rows.first?.row,
                lastRow: rows.last?.row,
                count: rows.count,
                expectedCount: capture.fileTrackCount,
                expectedCountSource: capture.fileTrackCount == nil ? nil : "project_file"
            ),
            rows: rows,
            ambiguousTrackIndices: ambiguousTrackIndices,
            collapsedStackRows: collapsedStackRows
        )

        // `mixerDataSource` is the sole producer of these three labels, and `logic://mixer`
        // publishes the same one, so the two documents agree about the strip freshness.
        let stripSource = ResourceHandlers.mixerDataSource(fetchedAt: capture.mixerFetchedAt, now: capture.endedAt)
        let stripsCoverage: Coverage
        let stripsReasons: [Reason]
        if moved {
            stripsCoverage = .unstable
            stripsReasons = [.cacheMovedDuringCapture]
        } else if stripSource == "mixer_not_visible" {
            stripsCoverage = .unavailable
            stripsReasons = [.mixerNotVisible]
        } else if stripSource == "cache_stale" {
            stripsCoverage = .partial
            stripsReasons = [.mixerCacheStale]
        } else {
            // A fresh poll still has not read the strip names or the mixer's filter state.
            stripsCoverage = .partial
            stripsReasons = [.mixerFiltersUnread]
        }
        let strips = StripsSection(
            coverage: stripsCoverage,
            reasons: stripsReasons,
            witnesses: StripWitnesses(count: capture.channelStrips.count),
            rows: capture.channelStrips.map { strip in
                StripRow(
                    stripIndex: strip.trackIndex,
                    output: strip.output,
                    input: strip.input,
                    pluginCount: strip.plugins.count,
                    pluginsSource: strip.pluginsSource
                )
            }
        )

        func deferred(_ reason: Reason) -> DomainSection {
            moved
                ? DomainSection(coverage: .unstable, reasons: [.cacheMovedDuringCapture])
                : DomainSection(coverage: .unavailable, reasons: [reason])
        }
        // An ordinal or name join between a strip and a track is not evidence of association.
        let associations = deferred(.noObservedAssociationEvidence)
        let hierarchy = deferred(.parentDepthNotObserved)
        let routing = request.domains.contains(.routing) ? deferred(.routingDeferredToIssue291R1) : nil
        let color = request.domains.contains(.color) ? deferred(.colorDeferredToIssue970) : nil

        func coverage(of domain: Domain) -> Coverage {
            switch domain {
            case .tracks: return tracks.coverage
            case .strips: return strips.coverage
            case .associations: return associations.coverage
            case .hierarchy: return hierarchy.coverage
            case .routing: return routing?.coverage ?? .unavailable
            case .color: return color?.coverage ?? .unavailable
            }
        }
        let incompleteDomains = request.domains.filter { coverage(of: $0) != .complete }

        let projectStatus: ProjectStatus
        var projectRef: String?
        if !capture.referencesEnabled {
            projectStatus = .referencesDisabled
        } else {
            switch capture.projectIssuance {
            case .issued(let reference)?:
                projectStatus = .issued
                projectRef = reference.rawValue
            case .unobserved?, nil:
                projectStatus = .unobserved
            case .stale?:
                projectStatus = .stale
            }
        }

        return Report(
            schema: schema,
            readOnly: true,
            snapshotId: snapshotID(for: capture),
            scope: request.scope,
            requestedDomains: request.domains,
            project: ProjectSection(
                status: projectStatus,
                projectRef: projectRef,
                name: capture.project.name,
                filePath: capture.project.filePath,
                projectEpoch: capture.projectEpoch
            ),
            capture: CaptureWindow(
                beganAt: ISO8601DateFormatter.cacheFormatter.string(from: capture.beganAt),
                endedAt: ISO8601DateFormatter.cacheFormatter.string(from: capture.endedAt)
            ),
            sources: Sources(tracks: "ax_poll_cache", strips: stripSource, expectedCount: "project_file"),
            tracks: tracks,
            strips: strips,
            associations: associations,
            hierarchy: hierarchy,
            routing: routing,
            color: color,
            overall: Overall(complete: incompleteDomains.isEmpty, incompleteDomains: incompleteDomains),
            uiEffects: UIEffects()
        )
    }

    static func snapshotID(for capture: Capture) -> String {
        let epoch = capture.versionsBefore[.project]?.projectEpoch
            ?? capture.versionsBefore[.tracks]?.projectEpoch
            ?? capture.projectEpoch
        func revision(_ section: CacheSectionID) -> UInt64 {
            capture.versionsBefore[section]?.sectionRevision ?? 0
        }
        return "snap_\(epoch)_t\(revision(.tracks))_m\(revision(.mixer))_p\(revision(.project))"
    }

    /// The same rule `TrackReferenceIssuance.issue` applies, for a capture that issued nothing:
    /// an id two rows share cannot say which of them a strip belongs to.
    private static func duplicateTrackIndices(in tracks: [TrackState]) -> [Int] {
        var occurrences: [Int: Int] = [:]
        for track in tracks {
            occurrences[track.id, default: 0] += 1
        }
        return occurrences.filter { $0.value > 1 }.map(\.key).sorted()
    }
}
