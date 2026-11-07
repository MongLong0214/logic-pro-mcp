import Foundation
import MCP
import Testing
@testable import LogicProMCP

// v3.1.8 (Issue #7) — readProjectInfo tier merge:
// Tier 1: cache (live AX, source "ax_live" or "cache")
// Tier 2: trusted live track cache for trackCount when ProjectInfo is name-only
// Tier 3: LogicProjectFileReader (source "project_file" + last_saved_age_sec)
// Tier 4: defaults (source "default")
// Critical: live cache values win when present; project file values only fill
// fields the live cache has not observed.

private func makeFileReaderRuntime(
    tempo: Double? = 80,
    sampleRate: Int? = nil,
    numerator: Int? = 4,
    denominator: Int? = 4,
    trackCount: Int? = 31,
    mtime: Date = Date(timeIntervalSince1970: 1_700_000_000),
    bundlePath: URL = URL(fileURLWithPath: "/tmp/Lofi-Dreamscape-80.logicx"),
    pathReturnsNil: Bool = false
) -> LogicProjectFileReader.Runtime {
    .init(
        currentDocumentPath: { pathReturnsNil ? nil : bundlePath.path },
        now: { Date(timeIntervalSince1970: 1_700_000_500) },
        readPlistData: { _ in
            var dict: [String: Any] = [:]
            if let t = tempo { dict["BeatsPerMinute"] = t }
            if let sampleRate { dict["SampleRate"] = sampleRate }
            if let n = numerator, n > 0 { dict["SongSignatureNumerator"] = n }
            if let d = denominator, d > 0 { dict["SongSignatureDenominator"] = d }
            if let tc = trackCount { dict["NumberOfTracks"] = tc }
            return try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        },
        mtime: { _ in mtime },
        sleep: { _ in }
    )
}

/// Build a synthetic .logicx bundle so the path validation passes (the runtime
/// closures don't read the actual file, but `validatePath` checks
/// `FileManager.default.fileExists(... isDirectory:)`).
private func ensureFixtureBundle(at url: URL) -> URL {
    let altDir = url
        .appendingPathComponent("Alternatives", isDirectory: true)
        .appendingPathComponent("000", isDirectory: true)
    try? FileManager.default.createDirectory(at: altDir, withIntermediateDirectories: true)
    let leaf = altDir.appendingPathComponent("MetaData.plist")
    if !FileManager.default.fileExists(atPath: leaf.path) {
        try? Data().write(to: leaf)  // empty marker — readPlistData closure overrides
    }
    return url
}

private func parseEnvelope(_ contents: ReadResource.Result) throws -> [String: Any] {
    guard !contents.contents.isEmpty, let text = contents.contents[0].text else {
        throw NSError(domain: "test", code: 0)
    }
    let data = Data(text.utf8)
    return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test(arguments: [false, true])
func projectInfoRefusesConflictingLiveDocumentBeforeIssuingReference(references: Bool) async throws {
    try await FeatureFlags.withAdr002TargetRefForTests(references) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-info-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ensureFixtureBundle(at: directory.appendingPathComponent("old/Same.logicx", isDirectory: true))
        let current = ensureFixtureBundle(at: directory.appendingPathComponent("current/Same.logicx", isDirectory: true))
        #expect(FileManager.default.contentsEqual(atPath: old.path, andPath: current.path))
        let cache = StateCache(), registry = TargetRegistry()
        let original = ProjectInfo(name: "Same", tempo: 95, filePath: old.path, lastUpdated: Date())
        await cache.updateProject(original)
        await #expect(throws: MCPError.internalError("project target snapshot became stale during resource emission")) {
            _ = try await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: ChannelRouter(),
                targetRegistry: registry, fileReader: makeFileReaderRuntime(bundlePath: current))
        }
        #expect(await registry.currentProjectIdentity == nil)
        let after = await cache.getProject()
        #expect(after.name == original.name && after.filePath == original.filePath && after.lastUpdated == original.lastUpdated)
    }
}

@Test(arguments: [false, true])
func projectInfoRetainsTheSamePhysicalBundleThroughAnAlias(references: Bool) async throws {
    try await FeatureFlags.withAdr002TargetRefForTests(references) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-info-alias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = ensureFixtureBundle(at: directory.appendingPathComponent("Current.logicx", isDirectory: true))
        let alias = directory.appendingPathComponent("Alias.logicx", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: current)
        #expect(alias.path != current.path)
        #expect(alias.resolvingSymlinksInPath().path == current.resolvingSymlinksInPath().path)
        let cache = StateCache(), registry = TargetRegistry()
        await cache.updateProject(ProjectInfo(name: "Current", tempo: 95, filePath: alias.path, lastUpdated: Date()))
        let result = try await ResourceHandlers.read(uri: "logic://project/info", cache: cache, router: ChannelRouter(),
            targetRegistry: registry, fileReader: makeFileReaderRuntime(bundlePath: current))
        let envelope = try parseEnvelope(result)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["filePath"] as? String == alias.path)
        #expect(data["name"] as? String == "Current")
        if references { #expect(data["project_ref"] != nil) }
        else { #expect(data["project_ref"] == nil) }
        #expect(await cache.getProject().filePath == alias.path)
    }
}

@Test
func cacheLive_filePresent_cachePreferred_sourceAxLive() async throws {
    let cache = StateCache()
    var live = ProjectInfo()
    live.tempo = 95
    live.timeSignature = "3/4"
    live.trackCount = 7
    live.lastUpdated = Date()  // very recent → "ax_live"
    await cache.updateProject(live)

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("CacheLiveBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 80, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["tempo"] as? Double == 95, "cache wins; got \(String(describing: data["tempo"]))")
    #expect(data["timeSignature"] as? String == "3/4")
    #expect(data["filePath"] as? String == bundle.path)
    #expect(envelope["source"] as? String == "ax_live")
    #expect(envelope["identity_source"] as? String == "current_document_project_file")
    #expect(envelope["identity_fetched_at"] as? String != nil)
}

@Test
func cacheProjectNameOnly_usesLiveTransportAndLiveTrackCacheForProjectTrackCount() async throws {
    let cache = StateCache()

    var liveProject = ProjectInfo()
    liveProject.name = "Untitled Live"
    liveProject.lastUpdated = Date()
    await cache.updateProject(liveProject)

    var transport = TransportState()
    transport.tempo = 127
    transport.sampleRate = 48_000
    transport.lastUpdated = Date()
    await cache.updateTransport(transport)

    await cache.updateTracks((0..<11).map {
        TrackState(id: $0, name: "Track \($0 + 1)", type: .softwareInstrument)
    })

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("LiveSiblingCacheBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 120, trackCount: 0, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["tempo"] as? Double == 127)
    #expect(data["sampleRate"] as? Int == 48_000)
    #expect(data["trackCount"] as? Int == 11)
    #expect(envelope["source"] as? String == "ax_live")
    #expect(envelope["last_saved_age_sec"] == nil)
}

@Test
func savedProjectSampleRateOverridesDisagreeingLiveTransport() async throws {
    let cache = StateCache()

    var liveProject = ProjectInfo()
    liveProject.name = "Saved Rate"
    liveProject.lastUpdated = Date()
    await cache.updateProject(liveProject)

    var transport = TransportState()
    transport.sampleRate = 44_100
    transport.lastUpdated = Date()
    await cache.updateTransport(transport)

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("SavedSampleRateBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(sampleRate: 48_000, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    let data = try #require(envelope["data"] as? [String: Any])

    #expect(data["sampleRate"] as? Int == 48_000)
}

@Test
func invalidSavedProjectSampleRateFallsBackToFreshTransport() async throws {
    let cache = StateCache()

    var transport = TransportState()
    transport.sampleRate = 44_100
    transport.lastUpdated = Date()
    await cache.updateTransport(transport)

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("InvalidSavedSampleRateBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(sampleRate: 0, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    let data = try #require(envelope["data"] as? [String: Any])

    #expect(data["sampleRate"] as? Int == 44_100)
}

@Test
func cacheProjectNameOnly_rejectsPlaceholderTrackCacheForProjectTrackCount() async throws {
    let cache = StateCache()

    var liveProject = ProjectInfo()
    liveProject.name = "Untitled Live"
    liveProject.lastUpdated = Date()
    await cache.updateProject(liveProject)

    await cache.updateTracks((0..<11).map {
        TrackState(id: $0, name: "Track \($0 + 1)", type: .unknown, placeholder: true)
    })

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaceholderSiblingCacheBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 120, trackCount: 0, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["trackCount"] as? Int == 0)
}

@Test
func cacheProjectNameOnly_rejectsInspectorContaminatedTrackCacheForProjectTrackCount() async throws {
    let cache = StateCache()

    var liveProject = ProjectInfo()
    liveProject.name = "Untitled Live"
    liveProject.lastUpdated = Date()
    await cache.updateProject(liveProject)

    await cache.updateTracks([
        TrackState(id: 0, name: "Region:", type: .unknown),
        TrackState(id: 1, name: "Track:", type: .unknown),
        TrackState(id: 2, name: "Channel Strip:", type: .unknown)
    ])

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("InspectorSiblingCacheBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 120, trackCount: 0, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["trackCount"] as? Int == 0)
}

@Test
func cacheStale_fileMetadata_useFile_sourceProjectFile() async throws {
    let cache = StateCache()
    // cache stays at struct defaults (lastUpdated == .distantPast)
    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("StaleBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 80, trackCount: 31, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["tempo"] as? Double == 80)
    #expect(data["trackCount"] as? Int == 31)
    #expect(envelope["source"] as? String == "project_file")
    #expect(envelope["last_saved_age_sec"] != nil)
    #expect(envelope["fetched_at"] as? String != nil)
    #expect(data["filePath"] as? String == bundle.path)
}

@Test
func cacheStale_fileUnreadable_useDefaults_sourceDefault() async throws {
    let cache = StateCache()
    let runtime = makeFileReaderRuntime(pathReturnsNil: true)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    #expect(envelope["source"] as? String == "default")
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["tempo"] as? Double == 120)
    #expect(envelope["last_saved_age_sec"] == nil)
}

@Test
func cacheLiveTempo95_fileTempo80_cacheWins_NEVERMixed() async throws {
    let cache = StateCache()
    var live = ProjectInfo()
    live.tempo = 95
    live.lastUpdated = Date()
    await cache.updateProject(live)

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("DivergeBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 80, bundlePath: bundle)

    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    guard let data = envelope["data"] as? [String: Any] else {
        Issue.record("data missing"); return
    }
    #expect(data["tempo"] as? Double == 95)
    let source = envelope["source"] as? String
    #expect(source != "project_file", "cache wins; file MUST NOT be source")
}

@Test
func envelope_includesSourceAlways() async throws {
    let cache = StateCache()
    let runtime = makeFileReaderRuntime(pathReturnsNil: true)
    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    #expect(envelope["source"] != nil)
}

@Test
func envelope_lastSavedAgeOnlyForProjectFileSource() async throws {
    let cache = StateCache()
    var live = ProjectInfo()
    live.tempo = 100
    live.lastUpdated = Date()
    await cache.updateProject(live)

    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("NoFileAgeBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(bundlePath: bundle)
    let result = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )
    let envelope = try parseEnvelope(result)
    #expect(envelope["last_saved_age_sec"] == nil, "cache source must omit last_saved_age_sec")
}

@Test
func cacheUnpoisoned_afterFileRead() async throws {
    let cache = StateCache()
    let bundle = ensureFixtureBundle(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("NoPoisonBundle.logicx", isDirectory: true))
    let runtime = makeFileReaderRuntime(tempo: 77, bundlePath: bundle)

    // Cache starts at distantPast (defaults). Resource read should fall to file.
    let before = await cache.getProject()
    #expect(before.lastUpdated == .distantPast)

    _ = try await ResourceHandlers.read(
        uri: "logic://project/info", cache: cache, router: ChannelRouter(), fileReader: runtime
    )

    // Cache MUST remain untouched.
    let after = await cache.getProject()
    #expect(after.lastUpdated == .distantPast, "cache must not be written by resource layer")
    #expect(after.tempo == 120.0, "cache tempo must remain default; got \(after.tempo)")
    _ = ()
}
