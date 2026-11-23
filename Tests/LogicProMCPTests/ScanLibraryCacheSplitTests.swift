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
    let hint = try #require(obj["hint"] as? String)
    #expect(!hint.localizedCaseInsensitiveContains("scan_library"))
    #expect(!hint.localizedCaseInsensitiveContains("retry"))
    #expect(try #require(obj["terminal"] as? Bool))
    #expect(try #require(obj["terminal_scope"] as? String) == "mcp_request_only")
    #expect(!(try #require(obj["safe_to_retry"] as? Bool)))
    #expect(try #require(obj["automatic_precondition_attempts_exhausted"] as? Bool))
    #expect(!(try #require(obj["human_intervention_required"] as? Bool)))
    #expect(try #require(obj["human_intervention_requests"] as? Int) == 0)
    #expect(try #require(obj["human_dependent_transitions"] as? Int) == 0)
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

// resolve_path is an in-memory lookup over the cached scan. It must not queue
// behind a synchronous AX read that is holding the AccessibilityChannel actor.
@Test func testResolvePathDoesNotWaitForSynchronousAXReadOnChannel() async throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let channel = AccessibilityChannel(runtime: makeRuntime(trackStates: {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return []
    }))
    await channel.seedLastScanForTest(
        makeTestRoot(categories: ["Bass"], presets: ["Sub Bass"]), source: "disk"
    )
    let blockedRead = Task.detached { await channel.readTrackStates() }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            entered.wait()
            continuation.resume()
        }
    }

    let start = ContinuousClock.now
    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Bass/Sub Bass"]
    )
    let elapsed = ContinuousClock.now - start
    release.signal()
    _ = await blockedRead.value

    #expect(elapsed < .seconds(1), "resolve_path waited \(elapsed) for an unrelated AX read")
    let obj = try #require(JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as? [String: Any])
    let exists = try #require(obj["exists"] as? Bool)
    #expect(exists)
    #expect(obj["source"] as? String == "disk")
    let loadable = try #require(obj["loadable"] as? Bool)
    #expect(loadable)
}

@Test func testResolvePathConcurrentPublicationReturnsWholeSnapshot() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let leafRoot = makeTestRoot(categories: ["Category"], presets: ["Target"])
    let folderRoot = makeAtomicFolderRoot()
    await channel.seedLastScanForTest(leafRoot, source: "old")
    let initial = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Category/Target"]
    ).message

    var messages = [initial]
    messages += await withTaskGroup(of: [String].self, returning: [String].self) { group in
        group.addTask {
            for index in 0..<2_000 {
                if index.isMultiple(of: 2) {
                    await channel.seedLastScanForTest(folderRoot, source: "new")
                } else {
                    await channel.seedLastScanForTest(leafRoot, source: "old")
                }
                await Task.yield()
            }
            return []
        }
        for _ in 0..<4 {
            group.addTask {
                var batch: [String] = []
                batch.reserveCapacity(500)
                for _ in 0..<500 {
                    batch.append(await channel.execute(
                        operation: "library.resolve_path",
                        params: ["path": "Category/Target"]
                    ).message)
                    await Task.yield()
                }
                return batch
            }
        }

        var collected: [String] = []
        for await batch in group { collected.append(contentsOf: batch) }
        return collected
    }
    await channel.seedLastScanForTest(folderRoot, source: "new")
    messages.append(await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Category/Target"]
    ).message)

    var observedSources = Set<String>()
    for message in messages {
        let obj = try #require(JSONSerialization.jsonObject(
            with: Data(message.utf8)
        ) as? [String: Any])
        let source = try #require(obj["source"] as? String)
        observedSources.insert(source)
        switch source {
        case "old":
            #expect(obj["kind"] as? String == "leaf")
            #expect(obj["children"] == nil)
        case "new":
            #expect(obj["kind"] as? String == "folder")
            #expect(obj["children"] as? [String] == ["Child"])
        default:
            Issue.record("unexpected cache source \(source)")
        }
    }
    #expect(observedSources.contains("old"))
    #expect(observedSources.contains("new"))
    #expect(observedSources.count == 2)
}

@Test func testResolvePathSixThousandLeafDiskInventory() async throws {
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let root = makeLargeDiskRoot(categories: 15, foldersPerCategory: 6, leavesPerFolder: 70)
    #expect(root.leafCount == 6_300)
    await channel.seedLastScanForTest(root, source: "disk")

    let start = ContinuousClock.now
    let leaf = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Category 14/Folder 5/Patch 69"]
    )
    let folder = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Category 14/Folder 5"]
    )
    let miss = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Category 14/Folder 5/Patch 70"]
    )
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .seconds(1), "three lookups over 6,300 leaves took \(elapsed)")

    let leafObj = try #require(JSONSerialization.jsonObject(
        with: Data(leaf.message.utf8)
    ) as? [String: Any])
    let leafExists = try #require(leafObj["exists"] as? Bool)
    #expect(leafExists)
    #expect(leafObj["kind"] as? String == "leaf")
    #expect(leafObj["matchedPath"] as? String == "Category 14/Folder 5/Patch 69")
    #expect(leafObj["source"] as? String == "disk")
    let leafLoadable = try #require(leafObj["loadable"] as? Bool)
    #expect(leafLoadable)
    #expect(leafObj["reason"] == nil)

    let folderObj = try #require(JSONSerialization.jsonObject(
        with: Data(folder.message.utf8)
    ) as? [String: Any])
    #expect(folderObj["kind"] as? String == "folder")
    let folderLoadable = try #require(folderObj["loadable"] as? Bool)
    #expect(!folderLoadable)
    #expect(folderObj["reason"] as? String == "folder_path")
    #expect((folderObj["children"] as? [String])?.count == 70)

    let missObj = try #require(JSONSerialization.jsonObject(
        with: Data(miss.message.utf8)
    ) as? [String: Any])
    let missExists = try #require(missObj["exists"] as? Bool)
    #expect(!missExists)
    #expect(
        missObj["reason"] as? String
            == "Library path segment 'Patch 70' was not found under 'Category 14/Folder 5' in the scanned library cache."
    )
}

// MARK: - Helpers

private func makeRuntime(
    trackStates: @escaping @Sendable () -> [TrackState]? = { nil }
) -> AccessibilityChannel.Runtime {
    AccessibilityChannel.Runtime(
        isTrusted: { true },
        isLogicProRunning: { true },
        appRoot: { nil },
        transportState: { .success("{}") },
        toggleTransportButton: { _ in .success("{}") },
        setTempo: { _ in .success("{}") },
        setCycleRange: { _ in .success("{}") },
        tracks: { .success("[]") },
        trackStates: trackStates,
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

private func makeAtomicFolderRoot() -> LibraryRoot {
    let child = LibraryNode(
        name: "Child", path: "Category/Target/Child", kind: .leaf, children: []
    )
    let target = LibraryNode(
        name: "Target", path: "Category/Target", kind: .folder, children: [child]
    )
    let category = LibraryNode(
        name: "Category", path: "Category", kind: .folder, children: [target]
    )
    let root = LibraryNode(
        name: "(library-root)", path: "", kind: .folder, children: [category]
    )
    return LibraryRoot(
        generatedAt: "2026-11-08T00:00:00Z",
        scanDurationMs: 0, measuredSettleDelayMs: 0,
        selectionRestored: false, truncatedBranches: 0, probeTimeouts: 0,
        cycleCount: 0, nodeCount: 4, leafCount: 1, folderCount: 3,
        root: root, categories: ["Category"], presetsByCategory: ["Category": ["Child"]]
    )
}

private func makeLargeDiskRoot(
    categories: Int, foldersPerCategory: Int, leavesPerFolder: Int
) -> LibraryRoot {
    var topChildren: [LibraryNode] = []
    var byCat: [String: [String]] = [:]
    for c in 0..<categories {
        let category = "Category \(c)"
        var folders: [LibraryNode] = []
        var categoryLeaves: [String] = []
        for f in 0..<foldersPerCategory {
            let folderPath = "\(category)/Folder \(f)"
            let leaves = (0..<leavesPerFolder).map { l in
                LibraryNode(
                    name: "Patch \(l)", path: "\(folderPath)/Patch \(l)",
                    kind: .leaf, children: []
                )
            }
            categoryLeaves += leaves.map(\.name)
            folders.append(LibraryNode(
                name: "Folder \(f)", path: folderPath, kind: .folder, children: leaves
            ))
        }
        byCat[category] = categoryLeaves
        topChildren.append(LibraryNode(
            name: category, path: category, kind: .folder, children: folders
        ))
    }
    let root = LibraryNode(
        name: "(library-root)", path: "", kind: .folder, children: topChildren
    )
    let counts = root.countNodes()
    return LibraryRoot(
        generatedAt: "2026-11-08T00:00:00Z",
        scanDurationMs: 0, measuredSettleDelayMs: 0,
        selectionRestored: false, truncatedBranches: 0, probeTimeouts: 0,
        cycleCount: 0, nodeCount: counts.total,
        leafCount: counts.leaves, folderCount: counts.folders,
        root: root, categories: topChildren.map(\.name), presetsByCategory: byCat
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
