import Foundation
import Testing
@testable import LogicProMCP

@Test func testStateCacheTrackAndChannelStripAccessorsCoverSelectionAndExpansion() async {
    let cache = StateCache()

    await cache.updateTrack(at: 2) { track in
        track.name = "Lead Vox"
        track.type = .audio
        track.isSelected = true
        track.automationMode = .touch
    }
    await cache.updateFader(strip: 2, volume: 0.75)

    let tracks = await cache.getTracks()
    #expect(tracks.count == 3)
    #expect(tracks[0].name == "Track 1")

    let selectedTrack = await cache.getSelectedTrack()
    #expect(selectedTrack?.id == 2)
    #expect(selectedTrack?.automationMode == .touch)

    let strip = await cache.getChannelStrip(at: 2)
    #expect(strip?.trackIndex == 2)
    #expect(strip?.volume == 0.75)

    let missingTrack = await cache.getTrack(at: 9)
    let missingStrip = await cache.getChannelStrip(at: 9)
    #expect(missingTrack == nil)
    #expect(missingStrip == nil)
}

@Test func testStateCacheProjectRegionMarkerAndSnapshotModes() async {
    let cache = StateCache()
    let transport = TransportState(lastUpdated: Date(timeIntervalSinceNow: -2))
    let regions = [
        RegionState(
            id: "r1",
            name: "Verse",
            trackIndex: 1,
            startPosition: "1.1.1.1",
            endPosition: "9.1.1.1",
            length: "8 bars"
        )
    ]
    let markers = [MarkerState(id: 1, name: "Hook", position: "17.1.1.1")]
    let project = ProjectInfo(name: "Enterprise Mix", trackCount: 24)

    await cache.updateTransport(transport)
    await cache.updateRegions(regions)
    await cache.updateMarkers(markers)
    await cache.updateProject(project)

    let idleSnapshot = await cache.snapshot()
    #expect(idleSnapshot.pollMode == "idle")
    #expect(idleSnapshot.regionCount == 1)
    #expect(idleSnapshot.markerCount == 1)
    #expect(idleSnapshot.projectName == "Enterprise Mix")
    #expect(idleSnapshot.transportAge >= 0)

    await cache.recordToolAccess()
    let activeSnapshot = await cache.snapshot()
    #expect(activeSnapshot.pollMode == "active")

    let cachedRegions = await cache.getRegions()
    let cachedMarkers = await cache.getMarkers()
    let cachedProject = await cache.getProject()
    let cachedTransport = await cache.getTransport()
    #expect(cachedRegions.count == 1)
    #expect(cachedMarkers.count == 1)
    #expect(cachedProject.name == "Enterprise Mix")
    #expect(cachedTransport.position == transport.position)
}

@Test func testStateCacheDisplayUpdatesCoverLowerRowAndBulkReplacement() async {
    let cache = StateCache()
    let initialDisplay = MCUDisplayState(
        upperRow: String(repeating: "U", count: 56),
        lowerRow: String(repeating: " ", count: 56)
    )
    await cache.updateMCUDisplay(initialDisplay)
    await cache.updateMCUDisplayRow(upper: false, text: "Kick", offset: 0x38)

    let updatedDisplay = await cache.getMCUDisplay()
    #expect(updatedDisplay.upperRow == String(repeating: "U", count: 56))
    #expect(updatedDisplay.lowerRow.hasPrefix("Kick"))
}

@Test func testStateCacheNegativeIndicesDoNotMutateState() async {
    let cache = StateCache()

    await cache.updateTrack(at: -1) { track in
        track.name = "Should Not Exist"
    }
    await cache.updateFader(strip: -1, volume: 0.9)

    let tracks = await cache.getTracks()
    let strips = await cache.getChannelStrips()
    #expect(tracks.isEmpty)
    #expect(strips.isEmpty)
}

@Test func testStateCacheClearResetsTransport() async {
    let cache = StateCache()
    await cache.updateTransport(
        TransportState(
            isPlaying: true,
            isRecording: true,
            tempo: 128.5,
            position: "5.3.2.1"
        )
    )
    await cache.updateProject(ProjectInfo(name: "Stale Project", trackCount: 3))

    await cache.clearProjectState()

    let transport = await cache.getTransport()
    let project = await cache.getProject()
    #expect(transport.isPlaying == false)
    #expect(transport.isRecording == false)
    #expect(transport.position == "1.1.1.1")
    #expect(transport.tempo == 120.0)
    #expect(project.name == "")
}

@Test func testStateCacheSelectOnlyEnforcesSingleSelection() async {
    let cache = StateCache()
    await cache.updateTrack(at: 0) { $0.isSelected = true }
    await cache.updateTrack(at: 1) { $0.isSelected = true }
    await cache.updateTrack(at: 2) { $0.isSelected = true }

    await cache.selectOnly(trackAt: 1)

    let tracks = await cache.getTracks()
    #expect(tracks[0].isSelected == false)
    #expect(tracks[1].isSelected == true)
    #expect(tracks[2].isSelected == false)
    #expect(await cache.getSelectedTrack()?.id == 1)
}
