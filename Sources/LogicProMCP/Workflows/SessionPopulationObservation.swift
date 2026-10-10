@preconcurrency import ApplicationServices
import Foundation

/// #965 session-population report shared by fresh request acquisition and the existing audit.
///
/// The registered inspection acquires AX values under the existing poll-cycle exclusion.
/// The audit and explicit cache-only callers keep their previous readings. Every domain carries
/// a `coverage` and the reasons it is not
/// `complete`, so a consumer can tell a rail that was read from one that was not, an empty read
/// from a failed read, and a count that happens to match from a row set that is actually known.
/// The cache cannot see hidden tracks, stack children behind a collapsed header, strip names, or
/// which strip belongs to which track, and the report says so instead of leaving those absent.
enum SessionPopulationObservation {
    static let schema = "logic_pro_mcp_session_population.v1"

    /// Native values from this request, never a fallback to an earlier poll's rows.
    struct FreshPopulation: Sendable {
        let project: ProjectInfo?
        let tracks: [TrackState]?
        let strips: [ChannelStripState]?
        let fileTrackCount: Int?
        let beganAt: Date
        let endedAt: Date
        var stable: Bool
        var uiEffects: UIEffects = .init()
        var mixerPresentation: MixerPresentation? = nil
        var presentationObservation: PresentationObservation? = nil
        var presentationBinding: PresentationBinding? = nil
        /// Temporary rows remain immutable request facts. Only an independent
        /// post-restoration reading may become the ordinary current cache.
        var hasCapturedTrackExposure = false
        var restoredTracks: [TrackState]? = nil
        /// The live held view control, not a claim about saved/live population equivalence.
        var hiddenTracksShown: Bool? = nil
        /// Request-local physical witnesses from explicit selection and verified restoration.
        /// Never decoded or reconstructed from a wire reference, name or ordinal.
        var selectionAssociations: [AccessibilityChannel.HeldSelectionAssociation.Pair] = []
        /// A new full reading after verified selection restoration. This is not
        /// permission to accept changes during that reading or across projects.
        var associationReadbackBoundary: StateCache.CaptureBoundary? = nil
        /// Actual closed-to-open disclosure deltas, retained only after verified restoration.
        /// These are historical membership observations, not current target authority,
        /// immediate-parent links or absolute depths.
        var disclosureExposures: [HeldDisclosureExposure] = []
    }

    struct HeldDisclosureExposure: Sendable {
        let stack: AXTrackBinding.Binding
        let exposed: [AXTrackBinding.Binding]
    }

    struct PresentationObservation: Encodable, Equatable, Sendable {
        let mixerVisible: Bool?
        let isPlaying: Bool?
        let isRecording: Bool?
        let uiLocale: String?
        init(mixerVisible: Bool?, isPlaying: Bool?, isRecording: Bool?, uiLocale: String? = nil) {
            self.mixerVisible = mixerVisible; self.isPlaying = isPlaying
            self.isRecording = isRecording; self.uiLocale = uiLocale
        }
        func matchesViewTransport(_ other: Self) -> Bool {
            mixerVisible == other.mixerVisible && isPlaying == other.isPlaying && isRecording == other.isRecording
        }
        enum CodingKeys: String, CodingKey {
            case mixerVisible = "mixer_visible", isPlaying = "is_playing", isRecording = "is_recording", uiLocale = "ui_locale"
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(mixerVisible, forKey: .mixerVisible)
            try values.encode(isPlaying, forKey: .isPlaying)
            try values.encode(isRecording, forKey: .isRecording)
            try values.encode(uiLocale, forKey: .uiLocale)
        }
    }

    /// Process-local custody from the actual request reader; JSON cannot recreate it.
    final class PresentationBinding: @unchecked Sendable {
        let window: AXUIElement
        let title: String
        let document: String
        let mixer: AXUIElement?
        let transport: AXLogicProElements.ObservedTransportActivity?
        let runtime: AXLogicProElements.Runtime
        let pid: pid_t?
        let app: AXUIElement?
        let focus: AXUIElement?
        let navigationBaseline: AccessibilityChannel.OwnedMixerObservationNavigation?
        let uiLocale: String?
        init(window: AXUIElement, title: String, document: String, mixer: AXUIElement?,
             transport: AXLogicProElements.ObservedTransportActivity?, runtime: AXLogicProElements.Runtime,
             uiLocale: String? = nil) {
            self.window = window; self.title = title; self.document = document
            self.mixer = mixer; self.transport = transport; self.runtime = runtime
            self.uiLocale = uiLocale
            pid = runtime.logicProPID()
            app = AXLogicProElements.appRoot(runtime: runtime)
            focus = app.flatMap { AXHelpers.getAttribute($0, kAXFocusedUIElementAttribute as String, runtime: runtime.ax) }
            navigationBaseline = .init(window: window, runtime: runtime, expectedProject: nil,
                requiresProjectReference: false, referenceIsCurrent: { true })
        }

        func matches(_ other: PresentationBinding) -> Bool {
            func same(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
                switch (lhs, rhs) {
                case (nil, nil): return true
                case (.some(let a), .some(let b)): return CFEqual(a, b)
                default: return false
                }
            }
            guard CFEqual(window, other.window), title.utf8.elementsEqual(other.title.utf8),
                  document.utf8.elementsEqual(other.document.utf8), pid == other.pid,
                  same(app, other.app), same(focus, other.focus), same(mixer, other.mixer) else { return false }
            switch (transport, other.transport) {
            case (nil, nil): return true
            case (.some(let a), .some(let b)):
                return CFEqual(a.controlBar, b.controlBar) && CFEqual(a.play, b.play) && CFEqual(a.record, b.record)
                    && a.isPlaying == b.isPlaying && a.isRecording == b.isRecording
            default: return false
            }
        }
    }

    /// Presentation is independent of population coverage: All plus enabled type filters
    /// does not establish hidden/stacked membership or a traversal end.
    struct MixerPresentation: Encodable, Equatable, Sendable {
        var mode: String? = nil
        var typeFilters: [String: Bool?] = Dictionary(uniqueKeysWithValues:
            ["audio", "instrument", "aux", "bus", "input", "output", "master_vca", "midi"].map { ($0, nil) })

        enum CodingKeys: String, CodingKey { case mode; case typeFilters = "type_filters" }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            if let mode { try values.encode(mode, forKey: .mode) }
            else { try values.encodeNil(forKey: .mode) }
            try values.encode(typeFilters, forKey: .typeFilters)
        }
    }

    struct AcceptedPopulation: Sendable {
        let reading: Reading
        let boundary: StateCache.CaptureBoundary
        let population: FreshPopulation
    }

    enum AcquisitionError: Error {
        case cancelled, deadline, ownershipLost, pollerStopped, textEditing
    }

    struct NavigationAcquisitionError: Error {
        let cause: Error
        let effects: UIEffects
    }

    static func requireOwnedAcquisition() throws {
        let context = OperationTraceContext.current
        if (Task.isCancelled || context?.cancellationRequested() == true)
            && !AccessibilityChannel.OwnedTrackStackObservationNavigation.restoringInterruptedAcquisition {
            throw AcquisitionError.cancelled
        }
        guard let context,
              context.mutationGateAcquired, context.ownsGate() else {
            throw AcquisitionError.ownershipLost
        }
        if let deadline = context.deadline, ContinuousClock.now >= deadline {
            throw AcquisitionError.deadline
        }
    }

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
        case countIsTheOnlyEndWitness = "count_is_the_only_end_witness"
        case projectFileNotBound = "project_file_not_bound"
        case trackCacheStale = "track_cache_stale"
        case selectionStateUnverified = "selection_state_unverified"
        case mixerNotVisible = "mixer_not_visible"
        case mixerCacheStale = "mixer_cache_stale"
        case mixerFiltersUnread = "mixer_filters_unread"
        case mixerPresentationFiltered = "mixer_presentation_filtered"
        case noObservedAssociationEvidence = "no_observed_association_evidence"
        case associationPopulationNotObserved = "association_population_not_observed"
        case parentDepthNotObserved = "parent_depth_not_observed"
        case routingGraphPartial = "routing_graph_partial"
        case routingGraphUnavailable = "routing_graph_unavailable"
        case colorDeferredToIssue970 = "color_deferred_to_issue_970"
        case livePopulationMoved = "live_population_moved"
        case freshTrackReadUnavailable = "fresh_track_read_unavailable"
        case freshStripReadUnavailable = "fresh_strip_read_unavailable"
        case domainNotRequested = "domain_not_requested"
    }

    struct Request: Sendable {
        static let defaultDomains: [Domain] = [.tracks, .strips, .associations, .hierarchy]

        var scope: Scope
        var domains: [Domain]
        var allowUINavigation: Bool
        var projectRef: String?

        var needsTracks: Bool { domains.contains { [.tracks, .hierarchy, .associations].contains($0) } }
        var needsStrips: Bool { domains.contains { [.strips, .routing, .associations].contains($0) } }

        /// An MCU Mixer echo cannot invalidate an acquisition that reads no strips.
        /// Retained captures and repair baselines still watch all sections after acceptance.
        var acquisitionSections: [CacheSectionID] {
            needsTracks && !needsStrips ? [.tracks, .project] : SessionPopulationObservation.watchedSections
        }

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
    /// `before` and `after` bracket the reading: if anything in them differs — a watched section's
    /// version or a flag no version covers — the cache moved while the capture was in flight, and
    /// the report then refuses to call any domain better than `unstable`. `hasDocument` and
    /// `axOccluded` are read from `before`.
    struct Capture: Sendable {
        let before: StateCache.CaptureBoundary
        let after: StateCache.CaptureBoundary
        let projectEpoch: UInt64
        let project: ProjectInfo
        let tracks: [TrackState]
        let tracksFetchedAt: Date
        let channelStrips: [ChannelStripState]
        let mixerFetchedAt: Date
        /// `NumberOfTracks` from the project bundle's MetaData.plist, or nil when the bundle could
        /// not be read or is not the captured project's bundle. It is the one count the rail did
        /// not produce, which is what makes it an expected count rather than a restatement of the
        /// rows.
        let fileTrackCount: Int?
        /// A bundle was read, but its path is not the captured project's path (or the cache holds
        /// no path), so its count describes some other document or none that can be named.
        let projectFileNotBound: Bool
        /// Nil when the caller named no `project_ref`; false when the reference does not name the
        /// captured project, in which case nothing was issued and the report must not be returned.
        let requestedProjectMatches: Bool?
        let referencesEnabled: Bool
        /// The snapshot used by track, project and physical-strip issuance; nil exactly when
        /// `referencesEnabled` is false. Resources and the graph consume this capture's refs.
        let targetSnapshot: TargetRegistrySnapshot?
        /// Nil while `referencesEnabled` means the registry moved on during issuance.
        let issued: IssuedTrackReferences?
        /// Row-aligned references issued for retained physical strips in this very capture.
        /// Alignment is not identity: the registry deduplicates on CF ownership and document,
        /// never on Mixer ordinal or name. Nil means issuance was interrupted or stale.
        let mixerReferences: [TargetReference?]?
        let projectIssuance: ProjectIssuance?
        let beganAt: Date
        let endedAt: Date
        /// An opaque capture identity, independent of revision counters and session state.
        let captureID: String
        let freshPopulation: FreshPopulation?

        init(
            before: StateCache.CaptureBoundary,
            after: StateCache.CaptureBoundary,
            projectEpoch: UInt64,
            project: ProjectInfo,
            tracks: [TrackState],
            tracksFetchedAt: Date,
            channelStrips: [ChannelStripState],
            mixerFetchedAt: Date,
            fileTrackCount: Int?,
            projectFileNotBound: Bool,
            requestedProjectMatches: Bool?,
            referencesEnabled: Bool,
            targetSnapshot: TargetRegistrySnapshot?,
            issued: IssuedTrackReferences?,
            projectIssuance: ProjectIssuance?,
            beganAt: Date,
            endedAt: Date,
            captureID: String = "snap_" + UUID().uuidString,
            freshPopulation: FreshPopulation? = nil,
            mixerReferences: [TargetReference?]? = nil
        ) {
            self.before = before
            self.after = after
            self.projectEpoch = projectEpoch
            self.project = project
            self.tracks = tracks
            self.tracksFetchedAt = tracksFetchedAt
            self.channelStrips = channelStrips
            self.mixerFetchedAt = mixerFetchedAt
            self.fileTrackCount = fileTrackCount
            self.projectFileNotBound = projectFileNotBound
            self.requestedProjectMatches = requestedProjectMatches
            self.referencesEnabled = referencesEnabled
            self.targetSnapshot = targetSnapshot
            self.issued = issued
            self.mixerReferences = mixerReferences
            self.projectIssuance = projectIssuance
            self.beganAt = beganAt
            self.endedAt = endedAt
            self.captureID = captureID
            self.freshPopulation = freshPopulation
        }

        func mixerReference(at row: Int) -> TargetReference? {
            guard before == after, freshPopulation?.stable != false,
                  let mixerReferences, mixerReferences.indices.contains(row) else { return nil }
            return mixerReferences[row]
        }

        var referencesStale: Bool {
            referencesEnabled && (issued == nil ||
                (channelStrips.contains { $0.physicalBinding != nil } && mixerReferences == nil))
        }

    }

    /// The sections whose movement during capture makes the report unstable.
    static let watchedSections: [CacheSectionID] = [.tracks, .mixer, .project]

    /// One reading of the cache and of the bundle Logic names as its front document. The reader asks
    /// Logic for that document on its own, so the bundle need not be the project the cache holds;
    /// its track count is kept only when the two paths name the same bundle.
    ///
    /// The inspection (`capture`) and the session audit (`ProjectSessionAudit.buildAudit(cache:)`)
    /// both read through this, so they observe the session the same way (#965 O3).
    struct Reading: Sendable {
        let state: StateCache.AuditState
        /// `NumberOfTracks` of the cached project's bundle; nil when no bundle was read or the one
        /// read is not the cached project's.
        let fileTrackCount: Int?
        /// A bundle was read, but its path is not the cached project's path (or the cache holds no
        /// path).
        let projectFileNotBound: Bool
    }

    static func observe(cache: StateCache, fileReader: LogicProjectFileReader.Runtime) async -> Reading {
        // The file first, then the cache, as the audit read them before #965 O3. The reader awaits
        // Logic, so a cache read taken before that await can be older than the bundle it is compared
        // with: a rail that grew during the read was compared at its old count, a false
        // track_readback_gap (#1096 review round 1, R965-1). Read after, the cache is the newer of the
        // two, and a project that changed in between fails the bundle-path binding instead of lending
        // its count to another rail. `capture`'s boundaries still bracket both reads.
        let metadata = await LogicProjectFileReader.read(runtime: fileReader)
        let state = await cache.auditSnapshot()
        let fileBound = metadata.map { sameBundle($0.bundlePath, cachedPath: state.project.filePath) }
        return Reading(
            state: state,
            fileTrackCount: fileBound == true ? metadata?.trackCount : nil,
            projectFileNotBound: fileBound == false
        )
    }

    /// Reads the cache once. No AX call, no navigation, no cache write.
    ///
    /// References are issued through the same two issuers `logic://tracks` and `logic://mixer` use,
    /// under the same gate (`FeatureFlags.adr002TargetRef` and a registry), so a `track_ref` here
    /// is the reference those resources return for the same observed row.
    ///
    /// `requestedProjectRef` is the caller's `project_ref`, already accepted by the registry. It is
    /// compared with the project the cache actually holds before anything is issued: see
    /// `Capture.requestedProjectMatches`.
    static func capture(
        cache: StateCache,
        targetRegistry: TargetRegistry?,
        fileReader: LogicProjectFileReader.Runtime,
        requestedProjectRef: String? = nil,
        now: @Sendable () -> Date = Date.init,
        accepted: AcceptedPopulation? = nil,
        stoppingWhen stop: @Sendable () -> Bool = { false }
    ) async -> Capture {
        let beganAt = accepted?.population.beganAt ?? now()
        let before: StateCache.CaptureBoundary
        let observed: Reading
        if let accepted {
            before = accepted.boundary
            observed = accepted.reading
        } else {
            before = await cache.captureBoundary(watching: watchedSections)
            observed = await observe(cache: cache, fileReader: fileReader)
        }
        let snapshot = observed.state

        let targetSnapshot: TargetRegistrySnapshot?
        if !stop(), FeatureFlags.adr002TargetRef, let targetRegistry {
            let current = await targetRegistry.currentSnapshot
            if accepted != nil, accepted?.population.stable == true {
                targetSnapshot = await targetRegistry.snapshotForObservedProject(
                    snapshot.project, ifCurrent: current, stoppingWhen: stop
                )
            } else {
                targetSnapshot = current
            }
        } else {
            targetSnapshot = nil
        }

        // The registry accepted the reference because it names the registry's current project,
        // but an external switch moves the cache without touching the registry until some reader
        // binds the new project. Compare before issuing, so a mismatch neither reports nor binds
        // the project the caller did not name.
        var requestedProjectMatches: Bool?
        if let requestedProjectRef {
            var matches = false
            if FeatureFlags.adr002TargetRef, let targetRegistry, let targetSnapshot,
               let binding = await targetRegistry.resolveCurrentProject(TargetReference(rawValue: requestedProjectRef)),
               let captured = ProjectReferenceIssuance.descriptor(
                   name: snapshot.project.name,
                   filePath: snapshot.project.filePath,
                   epoch: targetSnapshot.projectEpoch
               ) {
                matches = binding.descriptor == captured
            }
            requestedProjectMatches = matches
        }

        var issued: IssuedTrackReferences?
        var mixerReferences: [TargetReference?]?
        var projectIssuance: ProjectIssuance?
        if !stop(), accepted?.population.stable != false,
           FeatureFlags.adr002TargetRef, let targetRegistry, let targetSnapshot, requestedProjectMatches != false {
            issued = await TrackReferenceIssuance.issue(
                for: accepted != nil && !StateCache.sessionReportHasBoundPath(snapshot.project.filePath)
                    ? [] : TrackReferenceIssuance.liveInventory(snapshot.tracks),
                registry: targetRegistry,
                snapshot: targetSnapshot,
                stoppingWhen: stop
            )
            if !stop() {
                projectIssuance = await ProjectReferenceIssuance.issue(
                    cached: snapshot.project,
                    registry: targetRegistry,
                    snapshot: targetSnapshot,
                    stoppingWhen: stop
                )
            }
            // The registry can move between the comparison and the bind; the bind must hand back
            // the very reference the caller named.
            if let requestedProjectRef {
                var reissued = false
                if case .issued(let reference)? = projectIssuance {
                    reissued = reference.rawValue == requestedProjectRef
                }
                if !reissued { requestedProjectMatches = false }
            }
            if !stop(), requestedProjectMatches != false, issued != nil {
                switch projectIssuance {
                case .issued?:
                    mixerReferences = await issueMixerReferences(
                        snapshot.channelStrips, registry: targetRegistry, snapshot: targetSnapshot,
                        stoppingWhen: stop
                    )
                case .unobserved?:
                    // Readable strips without a bound project remain observations, not a moved
                    // capture. They have no physical reference authority to publish.
                    mixerReferences = Array(repeating: nil, count: snapshot.channelStrips.count)
                default:
                    break
                }
            }
            // Binding awaits the registry. A movement after the final bind is still a moved
            // capture, not permission to publish references from the previous epoch/topology.
            let current = await targetRegistry.currentSnapshot
            if Task.isCancelled || stop() || current != targetSnapshot {
                issued = nil
                mixerReferences = nil
                projectIssuance = .stale
            }
        }

        let after = await cache.captureBoundary(watching: watchedSections)
        let endedAt = now()

        return Capture(
            before: before,
            after: after,
            projectEpoch: snapshot.projectEpoch,
            project: snapshot.project,
            tracks: snapshot.tracks,
            tracksFetchedAt: snapshot.tracksFetchedAt,
            channelStrips: snapshot.channelStrips,
            mixerFetchedAt: snapshot.mixerFetchedAt,
            fileTrackCount: observed.fileTrackCount,
            projectFileNotBound: observed.projectFileNotBound,
            requestedProjectMatches: requestedProjectMatches,
            referencesEnabled: targetSnapshot != nil,
            targetSnapshot: targetSnapshot,
            issued: issued,
            projectIssuance: projectIssuance,
            beganAt: beganAt,
            endedAt: endedAt,
            freshPopulation: accepted?.population,
            mixerReferences: mixerReferences
        )
    }

    private static func issueMixerReferences(
        _ strips: [ChannelStripState], registry: TargetRegistry,
        snapshot: TargetRegistrySnapshot, stoppingWhen stop: @Sendable () -> Bool
    ) async -> [TargetReference?]? {
        var references: [TargetReference?] = []
        for strip in strips {
            guard !Task.isCancelled, !stop() else { return nil }
            guard let physical = strip.physicalBinding else {
                references.append(nil)
                continue
            }
            // Repeated observations of the same physical element do not prove unique membership.
            guard strips.filter({ $0.physicalBinding?.matches(physical) == true }).count == 1 else {
                references.append(nil)
                continue
            }
            let descriptor = TargetDescriptor(trackIndex: strip.trackIndex, trackName: strip.name ?? "")
            guard let reference = await registry.bind(
                kind: .mixerStrip, descriptor: descriptor, fingerprint: descriptor.fingerprint,
                snapshot: snapshot, physicalMixerStrip: physical, stoppingWhen: stop
            ) else { return nil }
            references.append(reference)
        }
        return references
    }

    // MARK: - Report

    struct SnapshotRetention: Encodable, Sendable {
        let retained: Bool
        let reason: String?
        let ttlSeconds = StateCache.sessionCaptureLifetimeSeconds
        let capacity = StateCache.sessionCaptureLimit
        let maxBytes = StateCache.sessionCaptureByteLimit

        enum CodingKeys: String, CodingKey {
            case retained, reason, capacity
            case ttlSeconds = "ttl_seconds"
            case maxBytes = "max_bytes"
        }
    }

    struct Report: Encodable, Sendable {
        let schema: String
        let readOnly: Bool
        /// Opaque identity of this immutable capture; inspect_session retains the original
        /// report for bounded lookup within this cache, never regenerating it by revision.
        let snapshotId: String
        /// Set by the dispatcher after deciding whether this report can be retained.
        var snapshotRetention: SnapshotRetention? = nil
        let scope: Scope
        let requestedDomains: [Domain]
        let project: ProjectSection
        let capture: CaptureWindow
        let sources: Sources
        let tracks: TracksSection
        let strips: StripsSection
        let associations: DomainSection
        let hierarchy: DomainSection
        let routing: RoutingSection?
        let color: DomainSection?
        let overall: Overall
        let uiEffects: UIEffects
        var presentationObservation: PresentationObservation? = nil

        enum CodingKeys: String, CodingKey {
            case schema
            case readOnly = "read_only"
            case snapshotId = "snapshot_id"
            case snapshotRetention = "snapshot_retention"
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
            case presentationObservation = "presentation_observation"
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
        var hidden: Bool? = nil
        let parent = "unknown"
        let depth = "unknown"
        let isSelected: Bool?
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

        // Unread selection/stack/placeholder fields are explicit nulls: unavailable metadata
        // differs from an observed negative, and an omitted key could hide that distinction.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(row, forKey: .row)
            try container.encode(trackIndex, forKey: .trackIndex)
            try container.encode(name, forKey: .name)
            try container.encode(type, forKey: .type)
            try container.encode(typeSource, forKey: .typeSource)
            try container.encode(isStackHeader, forKey: .isStackHeader)
            try container.encode(stackCollapsed, forKey: .stackCollapsed)
            if let hidden { try container.encode(hidden, forKey: .hidden) }
            else { try container.encode("unknown", forKey: .hidden) }
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
        /// Whether `expected_count` equals the whole rail's row count (not the scoped `count`).
        /// Present only beside `expected_count`. A match is evidence, not completeness.
        let expectedCountMatchesRail: Bool?
        let hiddenTracksShown: Bool?

        enum CodingKeys: String, CodingKey {
            case firstRow = "first_row"
            case lastRow = "last_row"
            case count
            case expectedCount = "expected_count"
            case expectedCountSource = "expected_count_source"
            case expectedCountMatchesRail = "expected_count_matches_rail"
            case hiddenTracksShown = "hidden_tracks_shown"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(firstRow, forKey: .firstRow)
            try container.encode(lastRow, forKey: .lastRow)
            try container.encode(count, forKey: .count)
            try container.encodeIfPresent(expectedCount, forKey: .expectedCount)
            try container.encodeIfPresent(expectedCountSource, forKey: .expectedCountSource)
            try container.encodeIfPresent(expectedCountMatchesRail, forKey: .expectedCountMatchesRail)
            try container.encodeIfPresent(hiddenTracksShown, forKey: .hiddenTracksShown)
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
        let name: String?
        let nameReadError: String?
        var nameStatus: String { name != nil ? "observed" : (nameReadError != nil ? "unknown" : "not_read") }
        let output: String?
        let input: String?
        let inputObservation: InputSlotObservation?
        var inputStatus: String { inputObservation?.state.rawValue ?? "not_read" }
        let pluginCount: Int
        let pluginsSource: String?
        var mixerStripRef: String? = nil
        var sendSlots: [SendSlotObservation]? = nil

        enum CodingKeys: String, CodingKey {
            case stripIndex = "strip_index"
            case name
            case nameStatus = "name_status"
            case nameReadError = "name_read_error"
            case output
            case input
            case inputObservation = "input_observation"
            case inputStatus = "input_status"
            case pluginCount = "plugin_count"
            case pluginsSource = "plugins_source"
            case mixerStripRef = "mixer_strip_ref"
            case sendSlots = "send_slots"
        }

        // Unknown and legacy not-read names remain explicit nulls, never empty names.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stripIndex, forKey: .stripIndex)
            if let name {
                try container.encode(name, forKey: .name)
            } else {
                try container.encodeNil(forKey: .name)
            }
            try container.encode(nameStatus, forKey: .nameStatus)
            try container.encodeIfPresent(nameReadError, forKey: .nameReadError)
            try container.encodeIfPresent(output, forKey: .output)
            try container.encodeIfPresent(input, forKey: .input)
            try container.encodeIfPresent(inputObservation, forKey: .inputObservation)
            try container.encode(inputStatus, forKey: .inputStatus)
            try container.encode(pluginCount, forKey: .pluginCount)
            try container.encodeIfPresent(pluginsSource, forKey: .pluginsSource)
            try container.encodeIfPresent(mixerStripRef, forKey: .mixerStripRef)
            try container.encodeIfPresent(sendSlots, forKey: .sendSlots)
        }
    }

    struct StripWitnesses: Encodable, Sendable {
        let count: Int
        var presentation: MixerPresentation? = nil
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
        var rows: [AssociationRow]? = nil
        var disclosureExposures: [DisclosureExposureRow]? = nil
        enum CodingKeys: String, CodingKey {
            case coverage, reasons, rows
            case disclosureExposures = "disclosure_exposures"
        }
    }

    struct DisclosureExposureRow: Encodable, Sendable {
        let stackRef: String
        let exposedTrackRefs: [String]
        let source = "owned_disclosure_exposure"
        enum CodingKeys: String, CodingKey {
            case stackRef = "stack_ref", exposedTrackRefs = "exposed_track_refs", source
        }
    }

    struct AssociationRow: Encodable, Sendable {
        let trackIndex: Int
        let trackRef: String
        let mixerStripRef: String
        let source = "held_exclusive_selection_focus"
        enum CodingKeys: String, CodingKey {
            case trackIndex = "track_index", trackRef = "track_ref", mixerStripRef = "mixer_strip_ref", source
        }
    }

    /// The routing domain (#291): existing coverage under `graph` stays wire-compatible;
    /// additive `nodes` carries the same publication's actual source endpoints.
    struct RoutingSection: Encodable, Sendable {
        let coverage: Coverage
        let reasons: [Reason]
        let graph: RoutingCoverage
        let nodes: [RoutingNode]
        let snapshotId: String

        enum CodingKeys: String, CodingKey {
            case coverage
            case reasons
            case graph
            case nodes
            case snapshotId = "snapshot_id"
        }
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
        var navigationPerformed = false
        var restoration = "not_applicable"
        var changed: [String] = []
        var attempted: [String] = []
        var reason: String?

        enum CodingKeys: String, CodingKey {
            case navigationPerformed = "navigation_performed"
            case restoration
            case changed
            case attempted
            case reason
        }
    }

    /// Live instability and cache movement are different witnesses of an unusable baseline.
    static func captureMovementReason(capture: Capture) -> Reason? {
        if capture.freshPopulation?.stable == false { return .livePopulationMoved }
        return capture.before != capture.after ? .cacheMovedDuringCapture : nil
    }

    /// Why the rows in `capture` cannot stand for a track's CURRENT name, however complete the
    /// rail is. Each is a tracks-domain reason `build` gives about the rows that WERE read when it
    /// is the capture's only failure. Every one that holds is returned, where `build` reports only
    /// the first of moved, no document, no live read, contamination and a stale reference, so over
    /// a capture with several this can name reasons the report does not. The completeness reasons
    /// (hidden tracks, a count as the only end witness, collapsed stacks) are about rows that were
    /// not read, so they are left out: an identical name over a fresh but partial rail is still an
    /// observation of that name (#966).
    static func trackRowReadbackReasons(capture: Capture) -> [Reason] {
        var reasons: [Reason] = []
        if let movement = captureMovementReason(capture: capture) { reasons.append(movement) }
        if !capture.before.hasDocument { reasons.append(.noDocument) }
        if capture.tracksFetchedAt == .distantPast {
            reasons.append(.noLiveTrackReadYet)
        } else if capture.endedAt.timeIntervalSince(capture.tracksFetchedAt) > ProjectSessionAudit.staleThresholdSeconds {
            reasons.append(.trackCacheStale)
        }
        if TrackReferenceIssuance.liveInventory(capture.tracks).isEmpty && !capture.tracks.isEmpty {
            reasons.append(.inspectorSubtreeContamination)
        }
        if capture.referencesEnabled && capture.issued == nil { reasons.append(.targetSnapshotStale) }
        if capture.before.axOccluded { reasons.append(.axOccluded) }
        return reasons
    }

    // MARK: - Build

    /// Pure: the same capture and request always produce the same report.
    static func build(request: Request, capture: Capture) -> Report {
        let movementReason = captureMovementReason(capture: capture)
        let moved = movementReason != nil

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
                hidden: !moved && capture.freshPopulation?.stable == true ? track.hideButtonReadback : nil,
                isSelected: track.selectionReadback,
                placeholder: track.placeholder,
                trackRef: reference
            )
        }
        let collapsedStackRows = live.enumerated().compactMap { index, track in
            track.stackCollapsed == true ? index : nil
        }
        let ambiguousTrackIndices = issued?.ambiguousTrackIndices ?? duplicateTrackIndices(in: live)

        // Coverage describes the rail that was read; the scope narrows which rows are shown and,
        // for a selection, adds the one reason the rail cannot answer.
        let tracksCoverage: Coverage
        var tracksReasons: [Reason] = []
        if capture.freshPopulation != nil && !request.needsTracks {
            tracksCoverage = .unavailable
            tracksReasons = [.domainNotRequested]
        } else if let movementReason {
            tracksCoverage = .unstable
            tracksReasons = [movementReason]
        } else if let population = capture.freshPopulation, population.tracks == nil {
            tracksCoverage = .unavailable
            tracksReasons = [.freshTrackReadUnavailable]
        } else if !capture.before.hasDocument {
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
            if capture.before.axOccluded {
                tracksReasons.append(.axOccluded)
            }
            if live.isEmpty {
                // The cache cannot tell a failed rail read from an empty rail.
                tracksReasons.append(.unverifiedEmpty)
            }
            // The poller keeps the last rows when a read fails, so rows can outlive the rail they
            // describe. The audit's threshold, so both reports call the same rows stale.
            if capture.endedAt.timeIntervalSince(capture.tracksFetchedAt) > ProjectSessionAudit.staleThresholdSeconds {
                tracksReasons.append(.trackCacheStale)
            }
            if !collapsedStackRows.isEmpty {
                tracksReasons.append(.collapsedTrackStack)
            }
            if capture.freshPopulation?.hiddenTracksShown == false {
                tracksReasons.append(.hiddenTracksUnobserved)
            }
            if live.contains(where: { $0.isStackHeader == nil }) {
                tracksReasons.append(.stackStateUnreadable)
            }
            if let expected = capture.fileTrackCount {
                // A matching count says the rail has as many rows as the file has tracks, not
                // that these rows are those tracks: nothing in the cache witnesses where the rail
                // ends, so a count alone never makes the population complete (#965).
                tracksReasons.append(expected == live.count ? .countIsTheOnlyEndWitness : .trackReadbackGap)
            } else {
                if capture.projectFileNotBound {
                    tracksReasons.append(.projectFileNotBound)
                }
                // Without an independent expected count nothing rules out rows the rail does not show.
                if !tracksReasons.contains(.hiddenTracksUnobserved) { tracksReasons.append(.hiddenTracksUnobserved) }
            }
            if request.scope == .selection && (live.isEmpty || live.contains(where: { $0.selectionReadback == nil })) {
                // Unknown is not unselected. Even agreeing rows cannot certify the selected
                // set when one strict AXSelected read was unavailable.
                tracksReasons.append(.selectionStateUnverified)
            }
            tracksCoverage = tracksReasons.isEmpty ? .complete : .partial
        }

        let rows: [TrackRow]
        switch request.scope {
        case .wholeProject:
            rows = allRows
        case .selection:
            rows = allRows.filter { $0.isSelected == true }
        }
        let tracks = TracksSection(
            coverage: tracksCoverage,
            reasons: tracksReasons,
            witnesses: TrackWitnesses(
                firstRow: rows.first?.row,
                lastRow: rows.last?.row,
                count: rows.count,
                expectedCount: capture.fileTrackCount,
                expectedCountSource: capture.fileTrackCount == nil ? nil : "project_file",
                expectedCountMatchesRail: capture.fileTrackCount.map { $0 == live.count },
                hiddenTracksShown: capture.freshPopulation?.stable == true ? capture.freshPopulation?.hiddenTracksShown : nil
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
        if capture.freshPopulation != nil && !request.needsStrips {
            stripsCoverage = .unavailable
            stripsReasons = [.domainNotRequested]
        } else if let movementReason {
            stripsCoverage = .unstable
            stripsReasons = [movementReason]
        } else if let population = capture.freshPopulation, population.strips == nil {
            stripsCoverage = .unavailable
            stripsReasons = [.freshStripReadUnavailable]
        } else if stripSource == "mixer_not_visible" {
            stripsCoverage = .unavailable
            stripsReasons = [.mixerNotVisible]
        } else if capture.referencesStale {
            stripsCoverage = .unstable
            stripsReasons = [.targetSnapshotStale]
        } else if stripSource == "cache_stale" {
            stripsCoverage = .partial
            stripsReasons = [.mixerCacheStale]
        } else {
            // Known presentation removes an unread-filter claim, not missing independent
            // population/end evidence. Restricted views remain explicit.
            stripsCoverage = .partial
            if let presentation = capture.freshPopulation?.mixerPresentation,
               let mode = presentation.mode, presentation.typeFilters.count == 8,
               presentation.typeFilters.values.allSatisfy({ $0 != nil }) {
                stripsReasons = mode == "all" && presentation.typeFilters.values.allSatisfy({ $0 == true })
                    ? [.countIsTheOnlyEndWitness] : [.mixerPresentationFiltered, .countIsTheOnlyEndWitness]
            } else { stripsReasons = [.mixerFiltersUnread] }
        }
        let strips = StripsSection(
            coverage: stripsCoverage,
            reasons: stripsReasons,
            witnesses: StripWitnesses(count: capture.channelStrips.count,
                                     presentation: capture.freshPopulation?.mixerPresentation),
            rows: capture.channelStrips.enumerated().map { row, strip in
                StripRow(
                    stripIndex: strip.trackIndex,
                    name: strip.name,
                    nameReadError: strip.nameReadError,
                    output: strip.output,
                    input: strip.input,
                    inputObservation: strip.inputObservation,
                    pluginCount: strip.plugins.count,
                    pluginsSource: strip.pluginsSource,
                    mixerStripRef: capture.mixerReference(at: row)?.rawValue,
                    sendSlots: strip.sendSlots
                )
            }
        )

        func deferred(_ reason: Reason) -> DomainSection {
            if let movementReason {
                return DomainSection(coverage: .unstable, reasons: [movementReason])
            }
            return DomainSection(coverage: .unavailable, reasons: [reason])
        }
        // An ordinal or name join between a strip and a track is not evidence of association.
        var associations = deferred(.noObservedAssociationEvidence)
        if movementReason == nil, request.allowUINavigation, request.domains.contains(.associations),
           let pairs = capture.freshPopulation?.selectionAssociations, !pairs.isEmpty {
            var rows: [AssociationRow] = []
            var heldTracks: [AXTrackBinding.Binding] = []
            var heldStrips: [AXMixerStripBinding.Binding] = []
            var qualified = true
            for pair in pairs {
                let trackMatches = live.indices.filter { live[$0].physicalBinding?.matches(pair.track) == true }
                let stripMatches = capture.channelStrips.indices.filter { capture.channelStrips[$0].physicalBinding?.matches(pair.strip) == true }
                guard trackMatches.count == 1, stripMatches.count == 1,
                      let trackRow = trackMatches.first, let stripRow = stripMatches.first,
                      !heldTracks.contains(where: { $0.matches(pair.track) }),
                      !heldStrips.contains(where: { $0.matches(pair.strip) }),
                      let trackRef = allRows[trackRow].trackRef,
                      let stripRef = capture.mixerReference(at: stripRow)?.rawValue else { qualified = false; break }
                heldTracks.append(pair.track); heldStrips.append(pair.strip)
                if request.scope == .wholeProject || live[trackRow].selectionReadback == true {
                    rows.append(.init(trackIndex: live[trackRow].id, trackRef: trackRef, mixerStripRef: stripRef))
                }
            }
            if qualified, !rows.isEmpty {
                associations = .init(coverage: .partial, reasons: [.associationPopulationNotObserved], rows: rows)
            }
        }
        var hierarchy = deferred(.parentDepthNotObserved)
        if movementReason == nil, request.allowUINavigation, request.domains.contains(.hierarchy),
           tracksCoverage == .partial || tracksCoverage == .complete,
           let observations = capture.freshPopulation?.disclosureExposures, !observations.isEmpty {
            func reference(for physical: AXTrackBinding.Binding) -> (Int, String)? {
                let matches = live.indices.filter { live[$0].physicalBinding?.matches(physical) == true }
                guard matches.count == 1, let row = matches.first, let ref = allRows[row].trackRef else { return nil }
                return (row, ref)
            }
            var exposures: [DisclosureExposureRow] = []
            var qualified = true
            for observation in observations {
                guard let (_, stackRef) = reference(for: observation.stack) else { qualified = false; break }
                let members = observation.exposed.compactMap { reference(for: $0) }
                guard members.count == observation.exposed.count,
                      Set(members.map(\.1)).count == members.count,
                      !members.contains(where: { $0.1 == stackRef }) else { qualified = false; break }
                let refs = members.filter { request.scope == .wholeProject || live[$0.0].selectionReadback == true }.map(\.1)
                if !refs.isEmpty { exposures.append(.init(stackRef: stackRef, exposedTrackRefs: refs)) }
            }
            if qualified, !exposures.isEmpty {
                hierarchy = .init(coverage: .partial, reasons: [.parentDepthNotObserved], disclosureExposures: exposures)
            }
        }
        let routing = request.domains.contains(.routing) ? routingSection(capture: capture, moved: moved) : nil
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
            sources: Sources(
                tracks: capture.freshPopulation == nil ? "ax_poll_cache"
                    : !request.needsTracks ? "not_requested"
                    : capture.freshPopulation?.tracks == nil ? "ax_request_unavailable" : "ax_request_read",
                strips: capture.freshPopulation == nil ? stripSource
                    : !request.needsStrips ? "not_requested"
                    : capture.freshPopulation?.strips == nil ? "ax_request_unavailable" : "ax_request_read",
                expectedCount: "project_file"
            ),
            tracks: tracks,
            strips: strips,
            associations: associations,
            hierarchy: hierarchy,
            routing: routing,
            color: color,
            overall: Overall(complete: incompleteDomains.isEmpty, incompleteDomains: incompleteDomains),
            uiEffects: capture.freshPopulation?.uiEffects ?? UIEffects(),
            presentationObservation: capture.freshPopulation?.presentationObservation
        )
    }

    /// The graph of this capture, by the same `RoutingGraphPublication.publish` `logic://mixer`
    /// calls. A project reference that went stale during issuance is a moved capture here: a
    /// reader that cannot throw the way the resource does publishes it as every domain `unstable`.
    static func routingGraph(capture: Capture) -> RoutingGraph {
        let project: RoutingProjectBinding
        switch capture.projectIssuance {
        case .issued(let reference)?:
            project = .issued(reference)
        case .unobserved(let reason)?:
            project = .unavailable(reason: reason)
        case .stale?:
            project = .moved
        case nil:
            // With references off nothing was issued, which is not a movement.
            project = capture.referencesEnabled ? .moved : .referencesUnavailable
        }
        return RoutingGraphPublication.publish(capture: capture, project: project)
    }

    /// The routing section `build` reports, over `routingGraph(capture:)`.
    static func routingSection(capture: Capture, moved: Bool) -> RoutingSection {
        let graph = routingGraph(capture: capture)

        let coverage: Coverage
        let reasons: [Reason]
        if moved {
            coverage = .unstable
            reasons = [captureMovementReason(capture: capture) ?? .cacheMovedDuringCapture]
        } else if graph.coverage.domains.contains(where: { $0.state == .unstable }) {
            coverage = .unstable
            reasons = [.targetSnapshotStale]
        } else if capture.mixerFetchedAt == .distantPast {
            coverage = .unavailable
            reasons = [.routingGraphUnavailable]
        } else if graph.complete {
            coverage = .complete
            reasons = []
        } else {
            coverage = .partial
            reasons = [.routingGraphPartial]
        }
        return RoutingSection(
            coverage: coverage,
            reasons: reasons,
            graph: graph.coverage,
            nodes: graph.nodes,
            snapshotId: graph.snapshotId
        )
    }

    static func snapshotID(for capture: Capture) -> String {
        capture.captureID
    }

    /// Whether the bundle the file reader read is the cached project's bundle. Both sides are
    /// resolved and standardized, because the reader resolves symlinks (`/var` is `/private/var`)
    /// and the cached path need not. A cache with no absolute path names no bundle.
    static func sameBundle(_ bundle: URL, cachedPath: String?) -> Bool {
        guard let cached = cachedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              cached.hasPrefix("/") else {
            return false
        }
        let cachedBundle = URL(fileURLWithPath: cached).resolvingSymlinksInPath().standardizedFileURL.path
        return cachedBundle == bundle.resolvingSymlinksInPath().standardizedFileURL.path
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
