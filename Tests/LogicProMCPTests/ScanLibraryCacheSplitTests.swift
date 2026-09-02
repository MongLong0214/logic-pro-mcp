import Foundation
import Testing
@testable import LogicProMCP

// v3.1.0 (T6) — scan_library now writes three separate caches (panel / disk
// / both). resolve_path responses carry `source` and `loadable` fields so the
// client can distinguish disk-catalog candidates from panel-proven misses.

@Test func testResolvePathMissingCacheReturnsReason() async throws {
    // No scan has been run; resolve_path should hint at scan_library without
    // crashing.
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Bass/Sub"]
    )
    let isSuccess = result.isSuccess
    #expect(isSuccess)
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    let isMiss = !exists
    #expect(isMiss)
    let reason = try #require(obj["reason"] as? String)
    let hasExistingColdCacheReason = reason == "No cached library scan; call scan_library first"
    #expect(hasExistingColdCacheReason)
}

@Test func testResolvePathWarmCacheAbsentPathNamesMissingSegmentAndPrefix() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let root = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    await channel.seedLastScanForTest(root, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Bass/Absent"]
    )
    let isSuccess = result.isSuccess
    #expect(isSuccess)
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    let isMiss = !exists
    #expect(isMiss)
    let reason = try #require(obj["reason"] as? String)
    let namesMissingSegmentAndPrefix = reason == "Library path segment 'Absent' was not found under 'Bass' in the scanned library cache."
    #expect(namesMissingSegmentAndPrefix)
    let source = try #require(obj["source"] as? String)
    let consultedDiskCache = source == "disk"
    #expect(consultedDiskCache)
    let warningIsOmitted = obj["warning"] == nil
    #expect(warningIsOmitted)
}

@Test func testResolvePathWarmCacheRootMissNamesLibraryRoot() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let root = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    await channel.seedLastScanForTest(root, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Absent"]
    )
    let isSuccess = result.isSuccess
    #expect(isSuccess)
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    let isMiss = !exists
    #expect(isMiss)
    let reason = try #require(obj["reason"] as? String)
    let namesLibraryRoot = reason == "Library path segment 'Absent' was not found at the library root in the scanned library cache."
    #expect(namesLibraryRoot)
}

@Test func testResolvePathWarmCacheMalformedPathExplainsSyntaxAndOmitsWarning() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let root = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    await channel.seedLastScanForTest(root, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "A//C"]
    )
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    let isMiss = !exists
    #expect(isMiss)
    let reason = try #require(obj["reason"] as? String)
    let explainsMalformedSyntax = reason == "Malformed library path; after trimming surrounding spaces and tabs and removing one unescaped trailing '/', it must not be empty or contain an empty segment. Use non-empty slash-separated segments such as 'Bass/Sub Bass'; escape literal '/' in a segment as '\\/'."
    #expect(explainsMalformedSyntax)
    let source = try #require(obj["source"] as? String)
    let consultedDiskCache = source == "disk"
    #expect(consultedDiskCache)
    let warningIsOmitted = obj["warning"] == nil
    #expect(warningIsOmitted)
}

@Test func testResolvePathLeadingNewlineIsNotTrimmed() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let root = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    await channel.seedLastScanForTest(root, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "\nBass/Sub Bass"]
    )
    let isSuccess = result.isSuccess
    #expect(isSuccess)
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    let isMiss = !exists
    #expect(isMiss)
    let reason = try #require(obj["reason"] as? String)
    let keepsLeadingNewlineAsSegment = reason == "Library path segment '\nBass' was not found at the library root in the scanned library cache."
    #expect(keepsLeadingNewlineAsSegment)
}

@Test func testResolvePathInvariantViolationReturnsStateCWithoutExists() async throws {
    let root = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    let invalidMiss = LibraryAccessor.PathResolution(
        exists: false, kind: nil, matchedPath: nil, children: nil, miss: nil
    )

    let result = AccessibilityChannel.resolveLibraryPath(
        params: ["path": "Bass/Sub Bass"],
        lastPanelScan: nil,
        lastDiskScan: nil,
        lastScan: root,
        lastScanSource: "disk",
        resolveCachedPath: { _, _ in invalidMiss }
    )

    let isFailure = !result.isSuccess
    #expect(isFailure)
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let state = try #require(obj["state"] as? String)
    let isStateC = state == "C"
    #expect(isStateC)
    let error = try #require(obj["error"] as? String)
    let isInternalInconsistency = error == "internal_inconsistency"
    #expect(isInternalInconsistency)
    let existsIsOmitted = obj["exists"] == nil
    #expect(existsIsOmitted)
    let isTerminal = HonestContract.isTerminalStateC(result.message)
    #expect(isTerminal)
}

@Test func testResolvePathReturnsPanelSourceAndLoadableTrueForMatch() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    // Seed panel cache directly via a canned scan run. We can't easily run
    // runLiveScan here without a live AX tree, so we drive setLastScan via
    // its public surface (exposed for tests below). We use a small hand-
    // built LibraryRoot.
    let root = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    await channel.seedLastScanForTest(root, source: "panel")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Bass/Sub Bass"]
    )
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    #expect(exists)
    let source = try #require(obj["source"] as? String)
    let reportsPanelSource = source == "panel"
    #expect(reportsPanelSource)
    let loadable = try #require(obj["loadable"] as? Bool)
    #expect(loadable)
    let warningIsOmitted = obj["warning"] == nil
    #expect(warningIsOmitted)
}

@Test func testResolvePathReturnsPanelFolderAsNonLoadable() async {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let root = makeFolderRoot()
    await channel.seedLastScanForTest(root, source: "panel")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Synthesizer/Bass"]
    )
    let obj = try! JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as! [String: Any]
    #expect((obj["exists"] as? Bool)!)
    #expect(obj["kind"] as? String == "folder")
    #expect(obj["source"] as? String == "panel")
    #expect(!((obj["loadable"] as? Bool)!))
    #expect(obj["reason"] as? String == "folder_path")
    #expect(((obj["warning"] as? String)?.contains("leaf preset paths"))!)
}

@Test func testResolvePathReturnsDiskLeafAsLoadableCandidateWithoutPanelCache() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let disk = makeFolderRoot()
    await channel.seedLastScanForTest(disk, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Synthesizer/Bass/Acid Etched Bass"]
    )
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    #expect(exists)
    let kind = try #require(obj["kind"] as? String)
    let reportsLeaf = kind == "leaf"
    #expect(reportsLeaf)
    let source = try #require(obj["source"] as? String)
    let reportsDiskSource = source == "disk"
    #expect(reportsDiskSource)
    let loadable = try #require(obj["loadable"] as? Bool)
    #expect(loadable)
    let reasonIsOmitted = obj["reason"] == nil
    #expect(reasonIsOmitted)
    let warningIsOmitted = obj["warning"] == nil
    #expect(warningIsOmitted)
}

@Test func testResolvePathUsesDiskTreeToDisambiguateShallowPanelFolderRows() async {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let shallowPanel = makeTestRoot(categories: ["Synthesizer"], presets: ["Bass"])
    let diskTree = makeFolderRoot()
    await channel.seedLastScanForTest(shallowPanel, source: "panel")
    await channel.seedLastScanForTest(diskTree, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Synthesizer/Bass"]
    )
    let obj = try! JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as! [String: Any]
    #expect((obj["exists"] as? Bool)!)
    #expect(obj["kind"] as? String == "folder")
    #expect(obj["source"] as? String == "panel")
    #expect(!((obj["loadable"] as? Bool)!))
    #expect(obj["reason"] as? String == "folder_path")
}

// v3.1.0 (Ralph-2 / C3) — `mode:both` regression guard. Previously,
// `runBothScan` only seeded `lastBothScan` + `lastScan`; resolve_path
// walked `lastPanelScan` (miss) → `lastDiskScan` (miss) → `lastScan`
// (source="both") and hit the legacy fallback that force-sets
// `loadable:false` unless source=="panel". Even entries that the inline AX
// scan would have classified as Panel-loadable were misreported as
// `loadable:false, warning:"may not be loadable via Library Panel."`.
//
// The fix: `runBothScan` now seeds `lastPanelScan` from its inline AX scan
// when the Panel is open and enumerateTree succeeds. resolve_path's panel
// branch then matches and returns `source:"panel", loadable:true` for
// Panel-known paths.
//
// We emulate that post-`mode:both` state by calling `seedLastScanForTest`
// with source="panel" (as runBothScan's AX block now does) AND with
// source="both" (as the disk root). The resolve_path against a path that
// exists in the panel cache must return loadable:true.
@Test func testResolvePathAfterBothScanReturnsPanelLoadableForPanelPaths() async {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let panel = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    let disk = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    // Emulate what runBothScan now does: seed BOTH the panel cache (from the
    // inline AX scan) and the both cache (from the disk scan).
    await channel.seedLastScanForTest(panel, source: "panel")
    await channel.seedLastScanForTest(disk, source: "both")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Bass/Sub Bass"]
    )
    let obj = try! JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as! [String: Any]
    #expect((obj["exists"] as? Bool)!)
    #expect(
        obj["source"] as? String == "panel",
        "mode:both must surface Panel cache so Panel-known entries get source:panel"
    )
    #expect(
        (obj["loadable"] as? Bool)!,
        "Panel-known entries must report loadable:true even after mode:both"
    )
    #expect(obj["warning"] == nil, "No disk-only warning for Panel-known entry")
}

@Test func testResolvePathReturnsDiskOnlyWithLoadableFalse() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    // Panel cache has category Bass / preset Sub Bass.
    let panel = makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"])
    await channel.seedLastScanForTest(panel, source: "panel")

    // Disk cache additionally has a disk-only preset under Drums.
    let disk = makeTestRoot(categories: ["Drums"], presets: ["Disk Only Kit"])
    await channel.seedLastScanForTest(disk, source: "disk")

    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Drums/Disk Only Kit"]
    )
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    #expect(exists)
    let source = try #require(obj["source"] as? String)
    let reportsDiskOnlySource = source == "disk-only"
    #expect(reportsDiskOnlySource)
    let loadable = try #require(obj["loadable"] as? Bool)
    let isNotLoadable = !loadable
    #expect(isNotLoadable)
    let warningIsPresent = obj["warning"] != nil
    #expect(warningIsPresent)
}

// MARK: - Helpers

private func makeRuntime() -> AccessibilityChannel.Runtime {
    AccessibilityChannel.Runtime(
        isTrusted: { true },
        isLogicProRunning: { true },
        appRoot: { nil },
        transportState: { .success("{}") },
        toggleTransportButton: { _ in .success("{}") },
        setTempo: { _ in .success("{}") },
        setCycleRange: { _ in .success("{}") },
        tracks: { .success("[]") },
        selectedTrack: { .success("{}") },
        selectTrack: { _ in .success("{}") },
        setTrackToggle: { _, _ in .success("{}") },
        renameTrack: { _ in .success("{}") },
        mixerState: { .success("{}") },
        channelStrip: { _ in .success("{}") },
        setMixerValue: { _, _ in .success("{}") },
        projectInfo: { .success("{}") }
    )
}

private func makeTestRoot(categories: [String], presets: [String]) -> LibraryRoot {
    var topChildren: [LibraryNode] = []
    for cat in categories {
        let leaves = presets.map {
            LibraryNode(name: $0, path: "\(cat)/\($0)", kind: .leaf, children: [])
        }
        topChildren.append(LibraryNode(name: cat, path: cat, kind: .folder, children: leaves))
    }
    let root = LibraryNode(name: "(library-root)", path: "", kind: .folder, children: topChildren)
    var byCat: [String: [String]] = [:]
    for cat in categories { byCat[cat] = presets }
    return LibraryRoot(
        generatedAt: "2026-04-24T00:00:00Z",
        scanDurationMs: 0, measuredSettleDelayMs: 0,
        selectionRestored: false, truncatedBranches: 0, probeTimeouts: 0,
        cycleCount: 0, nodeCount: 1 + categories.count + categories.count * presets.count,
        leafCount: categories.count * presets.count, folderCount: 1 + categories.count,
        root: root, categories: categories, presetsByCategory: byCat
    )
}

private func makeFolderRoot() -> LibraryRoot {
    let acid = LibraryNode(
        name: "Acid Etched Bass",
        path: "Synthesizer/Bass/Acid Etched Bass",
        kind: .leaf,
        children: []
    )
    let bass = LibraryNode(
        name: "Bass",
        path: "Synthesizer/Bass",
        kind: .folder,
        children: [acid]
    )
    let synth = LibraryNode(
        name: "Synthesizer",
        path: "Synthesizer",
        kind: .folder,
        children: [bass]
    )
    let root = LibraryNode(name: "(library-root)", path: "", kind: .folder, children: [synth])
    return LibraryRoot(
        generatedAt: "2026-07-02T00:00:00Z",
        scanDurationMs: 0, measuredSettleDelayMs: 0,
        selectionRestored: false, truncatedBranches: 0, probeTimeouts: 0,
        cycleCount: 0, nodeCount: 4, leafCount: 1, folderCount: 3,
        root: root,
        categories: ["Synthesizer"],
        presetsByCategory: ["Synthesizer": ["Acid Etched Bass"]]
    )
}
