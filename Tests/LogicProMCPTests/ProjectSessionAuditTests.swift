import Foundation
import MCP
import Testing
@testable import LogicProMCP

// MARK: - Deterministic Snapshot fixture

/// Build a fully-formed audit Snapshot with a fixed `now` so `buildAudit(snapshot:)`
/// is fully deterministic and the file-vs-AX cross-check can be driven explicitly.
private func makeAuditSnapshot(
    now: Date = Date(timeIntervalSince1970: 1_730_000_000),
    hasDocument: Bool = true,
    project: ProjectInfo? = nil,
    transport: TransportState? = nil,
    tracks: [TrackState],
    regions: [RegionState] = [],
    regionsComplete: Bool = true,
    markers: [MarkerState] = [],
    channelStrips: [ChannelStripState] = [],
    fileTrackCount: Int? = nil,
    blockingDialogButtons: [String]? = nil
) -> ProjectSessionAudit.Snapshot {
    var proj = project ?? ProjectInfo()
    if project == nil {
        proj.name = "Fixture Session"
        proj.filePath = "/tmp/Fixture Session.logicx"
        proj.source = "ax_live"
        proj.trackCount = tracks.count
    }
    var tport = transport ?? TransportState()
    if transport == nil {
        tport.tempo = 126
        tport.lastUpdated = now
    }
    return ProjectSessionAudit.Snapshot(
        now: now,
        hasDocument: hasDocument,
        axOccluded: false,
        project: proj,
        projectFetchedAt: now,
        transport: tport,
        tracks: tracks,
        tracksFetchedAt: now,
        regions: regions,
        regionsFetchedAt: now,
        regionsComplete: regionsComplete,
        markers: markers,
        markersFetchedAt: now,
        channelStrips: channelStrips,
        mixerFetchedAt: now,
        fileTrackCount: fileTrackCount,
        blockingDialogButtons: blockingDialogButtons
    )
}

@Test func testProjectAuditMarksPartialRegionInventoryWithoutEmptyTrackClaims() throws {
    let tracks = [
        TrackState(id: 0, name: "Top Lane", type: .softwareInstrument),
        TrackState(id: 1, name: "Visible Lane", type: .softwareInstrument),
    ]
    let regions = [
        RegionState(
            id: "1:1:5:Visible",
            name: "Visible",
            trackIndex: 1,
            startPosition: "1 1 1 1",
            endPosition: "5 1 1 1",
            length: "4 0 0 0"
        ),
    ]
    let report = ProjectSessionAudit.buildAudit(snapshot: makeAuditSnapshot(
        tracks: tracks,
        regions: regions,
        regionsComplete: false
    ))

    let partial = try #require(report.findings.first { $0.id == "region_inventory_partial" })
    #expect(partial.severity == .warn)
    #expect(partial.provenance == "ax_visible_subset")
    #expect(report.evidence.exportReadiness.warnings.contains("region_inventory_partial"))
    #expect(!report.findings.contains { $0.id == "empty_tracks_detected" })
}

private func messySnapshot(
    now: Date = Date(timeIntervalSince1970: 1_730_000_000)
) -> ProjectSessionAudit.Snapshot {
    var kickA = TrackState(id: 0, name: "Kick", type: .audio)
    kickA.isSoloed = true
    var kickB = TrackState(id: 1, name: "Kick", type: .audio)
    kickB.isMuted = true
    kickB.isSoloed = true
    var unnamed = TrackState(id: 2, name: "", type: .softwareInstrument)
    unnamed.isArmed = true

    var strip = ChannelStripState(trackIndex: 0)
    strip.plugins = [PluginSlotState(index: 0, name: "Channel EQ", isBypassed: false)]
    strip.pluginsSource = "ax"

    return makeAuditSnapshot(
        now: now,
        tracks: [kickA, kickB, unnamed],
        regions: [
            RegionState(
                id: "0:1:5:Kick",
                name: "Kick",
                trackIndex: 0,
                startPosition: "1 1 1 1",
                endPosition: "5 1 1 1",
                length: "4 0 0 0"
            ),
        ],
        markers: [],
        channelStrips: [strip]
    )
}

@Test func testProjectSessionAuditFindingsAndCleanupPlanAreDeterministic() async throws {
    let now = Date(timeIntervalSince1970: 1_730_000_000)
    let snap = messySnapshot(now: now)

    // Real determinism: build twice from the identical snapshot and compare the
    // full ORDERED id arrays. A non-stable ordering or slug collision would
    // diverge here.
    let runA = ProjectSessionAudit.buildAudit(snapshot: snap)
    let runB = ProjectSessionAudit.buildAudit(snapshot: snap)
    #expect(runA.findings.map(\.id) == runB.findings.map(\.id))
    #expect(runA.cleanupPlan.map(\.id) == runB.cleanupPlan.map(\.id))

    // Uniqueness: cardinality of the id array equals cardinality of its Set.
    let findingIDsArray = runA.findings.map(\.id)
    #expect(findingIDsArray.count == Set(findingIDsArray).count)
    let stepIDsArray = runA.cleanupPlan.map(\.id)
    #expect(stepIDsArray.count == Set(stepIDsArray).count)

    // Documented sort invariant on findings.
    #expect(findingIDsArray == findingIDsArray.sorted())

    let report = runA
    #expect(report.schema == "logic_pro_mcp_project_audit.v1")
    #expect(report.readOnly)
    #expect(report.status == .degraded)
    #expect(report.evidence.tracks.total == 3)
    #expect(report.evidence.mixer.occupiedPluginSlots.count == 1)

    let findingIDs = Set(report.findings.map(\.id))
    #expect(findingIDs.contains("duplicate_track_names_kick_0_1"))
    #expect(findingIDs.contains("unnamed_or_placeholder_tracks"))
    #expect(findingIDs.contains("empty_tracks_detected"))
    #expect(findingIDs.contains("soloed_tracks_present"))
    #expect(findingIDs.contains("armed_tracks_present"))
    #expect(findingIDs.contains("muted_and_soloed_tracks"))
    #expect(findingIDs.contains("marker_structure_missing"))
    #expect(findingIDs.contains("occupied_plugin_slots_present"))

    let stepIDs = Set(report.cleanupPlan.map(\.id))
    #expect(stepIDs.contains("read_audit_snapshot"))
    #expect(stepIDs.contains("rename_duplicate_kick_0_1"))
    #expect(stepIDs.contains("rename_unnamed_or_placeholder_tracks"))
    #expect(stepIDs.contains("review_empty_tracks_no_delete"))
    #expect(stepIDs.contains("clear_solo_states"))
    #expect(stepIDs.contains("clear_arm_states"))

    // Empty-track step is a manual-review, non-mutating, non-executable step.
    let emptyTrackReview = try #require(report.cleanupPlan.first { $0.id == "review_empty_tracks_no_delete" })
    #expect(!emptyTrackReview.supportedByCurrentTools)
    #expect(!emptyTrackReview.mutatesProject)
    #expect(emptyTrackReview.command == nil)
    #expect(emptyTrackReview.tool == nil)

    // Plan-wide safety invariants (each allSatisfy is a non-optional Bool).
    // No step ever proposes a delete command by default.
    #expect(report.cleanupPlan.allSatisfy { ($0.command ?? "") != "delete" })
    // Any step that is not supported by current tools must be non-mutating.
    #expect(report.cleanupPlan.filter { !$0.supportedByCurrentTools }.allSatisfy { !$0.mutatesProject })
}

@Test func testProjectAuditFailsClosedWhenNoDocumentOpen() async throws {
    let cache = StateCache()
    await cache.updateDocumentState(false) // hasDocument defaults to TRUE; flip explicitly.
    let report = await ProjectSessionAudit.buildAudit(cache: cache)

    let blocker = try #require(report.findings.first { $0.id == "no_open_document" })
    #expect(blocker.severity == .blocker)
    #expect(report.status == .failed)
    #expect(report.evidence.exportReadiness.status == "blocked")
    #expect(report.evidence.exportReadiness.blockers.contains("no_open_document"))
    // Cleanup plan must stay read-only: no mutating step when the gate trips.
    #expect(report.cleanupPlan.allSatisfy { !$0.mutatesProject })
    #expect(report.cleanupPlan.contains { $0.id == "read_audit_snapshot" })
}

@Test func testProjectAuditSlugCollidingGroupsGetDistinctStableIds() throws {
    // Two distinct duplicate-name groups that slug() collapses to "kick-1":
    // "Kick #1" x2 (indices 0,1) and "Kick @1" x2 (indices 2,3).
    let tracks = [
        TrackState(id: 0, name: "Kick #1", type: .audio),
        TrackState(id: 1, name: "Kick #1", type: .audio),
        TrackState(id: 2, name: "Kick @1", type: .audio),
        TrackState(id: 3, name: "Kick @1", type: .audio),
    ]
    let report = ProjectSessionAudit.buildAudit(snapshot: makeAuditSnapshot(tracks: tracks))

    let dupFindingIDs = report.findings.map(\.id).filter { $0.hasPrefix("duplicate_track_names") }
    #expect(dupFindingIDs.count == 2)
    #expect(dupFindingIDs.count == Set(dupFindingIDs).count)

    let renameStepIDs = report.cleanupPlan.map(\.id).filter { $0.hasPrefix("rename_duplicate") }
    #expect(renameStepIDs.count == 2)
    #expect(renameStepIDs.count == Set(renameStepIDs).count)

    // Whole-report uniqueness still holds.
    let allFindingIDs = report.findings.map(\.id)
    #expect(allFindingIDs.count == Set(allFindingIDs).count)
    let allStepIDs = report.cleanupPlan.map(\.id)
    #expect(allStepIDs.count == Set(allStepIDs).count)
}

@Test func testProjectAuditEmojiOnlyDuplicateGroupsGetDistinctIds() throws {
    // slug() returns the literal "unnamed" for any name with no alphanumerics,
    // so two distinct emoji-only duplicate groups would collide without the
    // index disambiguator.
    let tracks = [
        TrackState(id: 0, name: "🔥", type: .audio),
        TrackState(id: 1, name: "🔥", type: .audio),
        TrackState(id: 2, name: "🎹", type: .audio),
        TrackState(id: 3, name: "🎹", type: .audio),
    ]
    let report = ProjectSessionAudit.buildAudit(snapshot: makeAuditSnapshot(tracks: tracks))

    let dupFindingIDs = report.findings.map(\.id).filter { $0.hasPrefix("duplicate_track_names") }
    #expect(dupFindingIDs.count == 2)
    let firstID = try #require(dupFindingIDs.first)
    let secondID = try #require(dupFindingIDs.dropFirst().first)
    #expect(firstID != secondID)
}

@Test func testProjectAuditReportsTrackReadbackGapWhenFileExceedsAX() throws {
    // AX surfaced 1 track but the project file says there are 4. The audit must
    // report this honestly (so it agrees with logic://tracks placeholder rows)
    // rather than claiming the inventory is empty.
    let snap = makeAuditSnapshot(
        tracks: [TrackState(id: 0, name: "Lead", type: .audio)],
        fileTrackCount: 4
    )
    let report = ProjectSessionAudit.buildAudit(snapshot: snap)

    let gap = try #require(report.findings.first { $0.id == "track_readback_gap" })
    #expect(gap.severity == .warn)
    #expect(gap.provenance == "project_file")
    #expect(gap.evidence.values.contains("file_track_count=4"))
    #expect(gap.evidence.values.contains("ax_track_count=1"))
    // The misleading "blank project" info must NOT be emitted alongside a gap.
    #expect(!report.findings.contains { $0.id == "track_inventory_empty" })
}

@Test func testProjectAuditEmptyAXAndNoFileCountEmitsInventoryEmpty() throws {
    // No AX tracks and no file count => honest "inventory empty" info, no gap.
    let snap = makeAuditSnapshot(tracks: [], fileTrackCount: nil)
    let report = ProjectSessionAudit.buildAudit(snapshot: snap)

    #expect(report.findings.contains { $0.id == "track_inventory_empty" })
    #expect(!report.findings.contains { $0.id == "track_readback_gap" })
}

@Test func testProjectAuditBlocksExternalMIDIRegionsBeforeExportClaim() throws {
    // #128 regression: a score opened from MIDI can look healthy in
    // logic://tracks + project.get_regions while every lane is a GM Device /
    // external-MIDI strip. That state is not audible-bounce verified, so audit
    // must flag it before a workflow treats track/region counts as export-ready.
    let tracks = [
        TrackState(id: 0, name: "GM Device 1", type: .externalMIDI),
        TrackState(id: 1, name: "Felt Keys", type: .softwareInstrument),
    ]
    let regions = [
        RegionState(
            id: "0:1:33:Imported",
            name: "Imported",
            trackIndex: 0,
            startPosition: "1 1 1 1",
            endPosition: "33 1 1 1",
            length: "32 0 0 0"
        ),
    ]
    let report = ProjectSessionAudit.buildAudit(snapshot: makeAuditSnapshot(tracks: tracks, regions: regions))

    let finding = try #require(report.findings.first { $0.id == "external_midi_regions_bounce_risk" })
    #expect(finding.severity == .blocker)
    #expect(finding.category == "export")
    #expect(finding.evidence.target == "0")
    #expect(finding.evidence.values.contains("track=0,name=GM Device 1,regions=1"))
    #expect(report.status == .failed)
    #expect(report.evidence.exportReadiness.status == "blocked")
    #expect(report.evidence.exportReadiness.blockers.contains("external_midi_regions_bounce_risk"))
}

@Test func testProjectAuditBlocksSoftwareInstrumentRegionsWithoutPluginEvidenceBeforeExportClaim() throws {
    // #174 regression: a MIDI-import demo can show software-instrument tracks
    // plus visible regions but still render a silent Logic Bounce when no
    // instrument/plugin evidence is readable. Track/region readback alone is
    // not export-ready audibility evidence.
    let tracks = [
        TrackState(id: 0, name: "Imported Keys", type: .softwareInstrument),
    ]
    let regions = [
        RegionState(
            id: "0:1:33:Imported Keys",
            name: "Imported Keys",
            trackIndex: 0,
            startPosition: "1 1 1 1",
            endPosition: "33 1 1 1",
            length: "32 0 0 0"
        ),
    ]
    var strip = ChannelStripState(trackIndex: 0)
    strip.plugins = []
    strip.pluginsSource = "ax"
    let report = ProjectSessionAudit.buildAudit(
        snapshot: makeAuditSnapshot(tracks: tracks, regions: regions, channelStrips: [strip])
    )

    let finding = try #require(report.findings.first {
        $0.id == "software_instrument_regions_without_audible_plugin"
    })
    #expect(finding.severity == .blocker)
    #expect(finding.category == "export")
    #expect(finding.evidence.target == "0")
    #expect(finding.evidence.values.contains("track=0,name=Imported Keys,regions=1,plugins=0"))
    #expect(report.status == .failed)
    #expect(report.evidence.exportReadiness.status == "blocked")
    #expect(report.evidence.exportReadiness.blockers.contains("software_instrument_regions_without_audible_plugin"))
}

@Test func testProjectAuditAllowsSoftwareInstrumentRegionsWithPluginEvidence() throws {
    let tracks = [
        TrackState(id: 0, name: "Imported Keys", type: .softwareInstrument),
    ]
    let regions = [
        RegionState(
            id: "0:1:9:Imported Keys",
            name: "Imported Keys",
            trackIndex: 0,
            startPosition: "1 1 1 1",
            endPosition: "9 1 1 1",
            length: "8 0 0 0"
        ),
    ]
    var strip = ChannelStripState(trackIndex: 0)
    strip.plugins = [PluginSlotState(index: 0, name: "Studio Grand", isBypassed: false)]
    strip.pluginsSource = "ax"
    let report = ProjectSessionAudit.buildAudit(
        snapshot: makeAuditSnapshot(tracks: tracks, regions: regions, channelStrips: [strip])
    )

    #expect(!report.findings.contains {
        $0.id == "software_instrument_regions_without_audible_plugin"
    })
    #expect(!report.evidence.exportReadiness.blockers.contains("software_instrument_regions_without_audible_plugin"))
}

@Test func testProjectAuditSurfacesBlockingModalAsExportBlocker() throws {
    // #427 follow-up: a blocking modal dialog owning the Logic window at audit
    // time must flow into export_readiness.blockers (a bounce cannot run while
    // it is up), matching the transport preflight's `preflight_blocking_dialog`
    // refusal — NOT be silently downgraded to the `ax_occluded` warning.
    let snap = makeAuditSnapshot(
        tracks: [TrackState(id: 0, name: "Lead", type: .audio)],
        blockingDialogButtons: ["Show Conflicts", "Ignore"]
    )
    let report = ProjectSessionAudit.buildAudit(snapshot: snap)

    let blocker = try #require(report.findings.first { $0.id == "export_blocked_by_modal_dialog" })
    #expect(blocker.severity == .blocker)
    #expect(blocker.category == "system")
    #expect(blocker.evidence.resource == "logic://system/health")
    #expect(blocker.evidence.values.contains("dialog_buttons=Show Conflicts,Ignore"))
    #expect(report.status == .failed)
    #expect(report.evidence.exportReadiness.status == "blocked")
    #expect(report.evidence.exportReadiness.blockers.contains("export_blocked_by_modal_dialog"))
}

@Test func testProjectAuditWithoutBlockingModalOmitsExportBlocker() throws {
    // Control: no blocking dialog ⇒ the modal blocker is absent and export
    // readiness is not blocked on account of it.
    let snap = makeAuditSnapshot(
        tracks: [TrackState(id: 0, name: "Lead", type: .audio)],
        blockingDialogButtons: nil
    )
    let report = ProjectSessionAudit.buildAudit(snapshot: snap)

    #expect(!report.findings.contains { $0.id == "export_blocked_by_modal_dialog" })
    #expect(!report.evidence.exportReadiness.blockers.contains("export_blocked_by_modal_dialog"))
}

@Test func testProjectAuditDispatcherSurfacesBlockingModalBlocker() async throws {
    // Mirrors the live repro: `logic_project audit` while a blocking modal
    // (AXDialog owned by the project window, buttons "Show Conflicts"/"Ignore")
    // is present must report the modal blocker in export_readiness instead of a
    // false green, using the SAME blockingDialogInfo() signal the transport
    // preflight fails closed on. A fixture is injected so the path is headless.
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Modal Repro"
    project.filePath = "/tmp/Modal Repro.logicx"
    project.source = "ax_live"
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Lead", type: .audio)])

    let result = await ProjectDispatcher.handle(
        command: "audit",
        params: [:],
        router: ChannelRouter(),
        cache: cache,
        blockingDialogInfo: {
            AXLogicProElements.BlockingDialogInfo(
                title: "",
                role: "AXDialog",
                owningWindow: "Modal Repro",
                buttonTitles: ["Show Conflicts", "Ignore"],
                recoveryAction: "Dismiss the blocking dialog (press Escape), then retry."
            )
        }
    )

    #expect(!result.isError!)
    let json = try #require(sharedJSONObject(sharedToolText(result)))
    #expect(json["status"] as? String == "failed")
    let evidence = try #require(json["evidence"] as? [String: Any])
    let exportReadiness = try #require(evidence["export_readiness"] as? [String: Any])
    #expect(exportReadiness["status"] as? String == "blocked")
    let blockers = try #require(exportReadiness["blockers"] as? [String])
    #expect(blockers.contains("export_blocked_by_modal_dialog"))
}

@Test func testProjectAuditResourceSurfacesBlockingModalBlockerFromCache() async throws {
    // #432 (load-bearing): the `logic://project/audit` RESOURCE is a cache-only
    // projection (it must not make live AX calls at read time). Before the fix it
    // built the audit without the blocking-dialog signal, so it reported
    // export_readiness.blockers:[] even while a blocking modal owned the Logic
    // window — the exact false-green class #431 removed on the tool path, still
    // live on the resource. With the poller-cached signal read at the resource
    // boundary, the resource must now surface the SAME
    // `export_blocked_by_modal_dialog` blocker the tool does.
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Modal Repro"
    project.filePath = "/tmp/Modal Repro.logicx"
    project.source = "ax_live"
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Lead", type: .audio)])
    // Stands in for the poller having observed a blocking modal via
    // AXLogicProElements.blockingDialogInfo() and cached its button titles.
    await cache.updateBlockingDialogButtons(["Show Conflicts", "Ignore"])

    let router = ChannelRouter()
    let auditResource = try await ResourceHandlers.read(uri: "logic://project/audit", cache: cache, router: router)
    let json = try #require(sharedJSONObject(sharedResourceText(auditResource)))

    #expect(json["status"] as? String == "failed")
    let evidence = try #require(json["evidence"] as? [String: Any])
    let exportReadiness = try #require(evidence["export_readiness"] as? [String: Any])
    #expect(exportReadiness["status"] as? String == "blocked")
    let blockers = try #require(exportReadiness["blockers"] as? [String])
    #expect(blockers.contains("export_blocked_by_modal_dialog"))
}

@Test func testProjectAuditResourceOmitsBlockingModalBlockerWhenCacheClear() async throws {
    // #432 control: with no blocking dialog cached (the poller writes nil when
    // AXLogicProElements.blockingDialogInfo() returns nil), the resource must NOT
    // report the modal blocker — proving the finding is driven by the cached
    // signal, not emitted unconditionally.
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Clean Session"
    project.filePath = "/tmp/Clean Session.logicx"
    project.source = "ax_live"
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Lead", type: .audio)])

    let router = ChannelRouter()
    let auditResource = try await ResourceHandlers.read(uri: "logic://project/audit", cache: cache, router: router)
    let json = try #require(sharedJSONObject(sharedResourceText(auditResource)))
    let evidence = try #require(json["evidence"] as? [String: Any])
    let exportReadiness = try #require(evidence["export_readiness"] as? [String: Any])
    let blockers = try #require(exportReadiness["blockers"] as? [String])
    #expect(!blockers.contains("export_blocked_by_modal_dialog"))
}

@Test func testProjectAuditToolAndResourceAgreeOnCachedBlockingModal() async throws {
    // #432 core assertion: the tool (live signal) and the resource (cached
    // signal) must agree for the same blocking-modal state. Here the modal is
    // present through BOTH the poller-cached signal (drives the resource) and the
    // dispatcher's live blockingDialogInfo() seam (drives the tool); both read
    // surfaces must report the export blocker.
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Agreement"
    project.filePath = "/tmp/Agreement.logicx"
    project.source = "ax_live"
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Lead", type: .audio)])
    await cache.updateBlockingDialogButtons(["Show Conflicts", "Ignore"])

    let router = ChannelRouter()

    let resource = try await ResourceHandlers.read(uri: "logic://project/audit", cache: cache, router: router)
    let resourceJSON = try #require(sharedJSONObject(sharedResourceText(resource)))
    let resourceEvidence = try #require(resourceJSON["evidence"] as? [String: Any])
    let resourceReadiness = try #require(resourceEvidence["export_readiness"] as? [String: Any])
    let resourceBlockers = try #require(resourceReadiness["blockers"] as? [String])

    let tool = await ProjectDispatcher.handle(
        command: "audit",
        params: [:],
        router: router,
        cache: cache,
        blockingDialogInfo: {
            AXLogicProElements.BlockingDialogInfo(
                title: "",
                role: "AXDialog",
                owningWindow: "Agreement",
                buttonTitles: ["Show Conflicts", "Ignore"],
                recoveryAction: "Dismiss the blocking dialog (press Escape), then retry."
            )
        }
    )
    let toolJSON = try #require(sharedJSONObject(sharedToolText(tool)))
    let toolEvidence = try #require(toolJSON["evidence"] as? [String: Any])
    let toolReadiness = try #require(toolEvidence["export_readiness"] as? [String: Any])
    let toolBlockers = try #require(toolReadiness["blockers"] as? [String])

    #expect(resourceBlockers.contains("export_blocked_by_modal_dialog"))
    #expect(toolBlockers.contains("export_blocked_by_modal_dialog"))
}

@Test func testProjectAuditAndCleanupPlanResourcesAndCommandsReturnJSON() async throws {
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Read Only"
    project.filePath = "/tmp/Read Only.logicx"
    project.source = "ax_live"
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Lead", type: .audio)])

    let router = ChannelRouter()
    let auditResource = try await ResourceHandlers.read(uri: "logic://project/audit", cache: cache, router: router)
    let auditJSON = try #require(sharedJSONObject(sharedResourceText(auditResource)))
    #expect(auditJSON["schema"] as? String == "logic_pro_mcp_project_audit.v1")
    #expect(try #require(auditJSON["read_only"] as? Bool))

    let planResource = try await ResourceHandlers.read(uri: "logic://project/cleanup-plan", cache: cache, router: router)
    let planJSON = try #require(sharedJSONObject(sharedResourceText(planResource)))
    #expect(planJSON["schema"] as? String == "logic_pro_mcp_project_cleanup_plan.v1")
    #expect(try #require(planJSON["requires_plan_confirmation"] as? Bool))
    #expect(try #require(planJSON["read_only"] as? Bool))

    let auditTool = await ProjectDispatcher.handle(command: "audit", params: [:], router: router, cache: cache)
    #expect(!auditTool.isError!)
    let auditToolJSON = try #require(sharedJSONObject(sharedToolText(auditTool)))
    #expect(auditToolJSON["schema"] as? String == "logic_pro_mcp_project_audit.v1")
    #expect(try #require(auditToolJSON["read_only"] as? Bool))

    let planTool = await ProjectDispatcher.handle(command: "cleanup_plan", params: [:], router: router, cache: cache)
    #expect(!planTool.isError!)
    let planToolJSON = try #require(sharedJSONObject(sharedToolText(planTool)))
    #expect(planToolJSON["schema"] as? String == "logic_pro_mcp_project_cleanup_plan.v1")
    #expect(try #require(planToolJSON["read_only"] as? Bool))
}

@Test func testProjectAuditSchemaV1KeySetsAreStable() async throws {
    // Lock the v1 wire schema key sets so a field add/remove forces a deliberate
    // test edit (and a schema version bump). Exact Set equality (not contains).
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Schema Probe"
    project.filePath = "/tmp/Schema Probe.logicx"
    project.source = "ax_live"
    await cache.updateProject(project)
    // Two duplicate tracks so a rename step (with tool+command set) is emitted.
    await cache.updateTracks([
        TrackState(id: 0, name: "Bass", type: .audio),
        TrackState(id: 1, name: "Bass", type: .audio),
    ])

    let router = ChannelRouter()
    let auditResource = try await ResourceHandlers.read(uri: "logic://project/audit", cache: cache, router: router)
    let auditJSON = try #require(sharedJSONObject(sharedResourceText(auditResource)))

    let topLevel = try #require(auditJSON["evidence"] as? [String: Any])
    #expect(Set(topLevel.keys) == [
        "has_document", "ax_occluded", "project", "transport",
        "tracks", "regions", "markers", "mixer", "export_readiness",
    ])

    let tracksKeys = try #require(topLevel["tracks"] as? [String: Any])
    #expect(Set(tracksKeys.keys) == [
        "total", "freshness", "selected_indices", "muted_indices",
        "soloed_indices", "armed_indices", "unnamed_track_indices", "duplicate_names",
    ])

    let mixerKeys = try #require(topLevel["mixer"] as? [String: Any])
    #expect(Set(mixerKeys.keys) == [
        "strip_count", "data_source", "freshness",
        "occupied_plugin_slots", "plugin_read_errors",
    ])

    let plan = try #require(auditJSON["cleanup_plan"] as? [[String: Any]])
    let renameStep = try #require(plan.first { ($0["id"] as? String)?.hasPrefix("rename_duplicate") ?? false })
    #expect(Set(renameStep.keys) == [
        "id", "target_identifier", "proposed_operation", "rationale",
        "risk_level", "required_confirmation", "expected_readback",
        "rollback_or_recovery", "stop_condition", "supported_by_current_tools",
        "mutates_project", "tool", "command",
    ])
}

@Test func testProjectAuditWorkflowCatalogEntryIsReadOnlyAndResolved() throws {
    let snapshot = WorkflowSkillCatalog.defaultSnapshot()
    let workflow = try #require(snapshot.workflows.first { $0.id == "logic.workflow.project.audit_cleanup_plan" })

    #expect(snapshot.validation.isValid)
    #expect(workflow.mutationKind == .readOnly)
    #expect(workflow.productionReady)
    #expect(try #require(workflow.dependenciesResolved as Bool?))
    #expect(workflow.allowedResources.contains("logic://project/audit"))
    #expect(workflow.allowedResources.contains("logic://project/cleanup-plan"))
}
