import Foundation
import Testing
@testable import LogicProMCP

// v3.1.0 (T6) — scan_library now writes three separate caches (panel / disk
// / both) so a disk scan no longer poisons resolve_path lookups that should
// only return Panel-loadable entries. resolve_path responses carry `source`
// and `loadable` fields so the client can avoid set_instrument on disk-only
// paths that would deterministically fail.

@Test func testResolvePathMissingCacheReturnsReason() async {
    // No scan has been run; resolve_path should hint at scan_library without
    // crashing.
    let channel = AccessibilityChannel(runtime: makeRuntime())
    let result = await channel.execute(
        operation: "library.resolve_path",
        params: ["path": "Bass/Sub"]
    )
    #expect(result.isSuccess)
    let obj = try! JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as! [String: Any]
    #expect(obj["exists"] as? Bool == false)
    #expect(obj["reason"] as? String == "No cached library scan; call scan_library first")
}

@Test func testResolvePathReturnsPanelSourceAndLoadableTrueForMatch() async {
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
    let obj = try! JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as! [String: Any]
    #expect(obj["exists"] as? Bool == true)
    #expect(obj["source"] as? String == "panel")
    #expect(obj["loadable"] as? Bool == true)
    #expect(obj["warning"] == nil)
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
    #expect(obj["exists"] as? Bool == true)
    #expect(
        obj["source"] as? String == "panel",
        "mode:both must surface Panel cache so Panel-known entries get source:panel"
    )
    #expect(
        obj["loadable"] as? Bool == true,
        "Panel-known entries must report loadable:true even after mode:both"
    )
    #expect(obj["warning"] == nil, "No disk-only warning for Panel-known entry")
}

@Test func testResolvePathReturnsDiskOnlyWithLoadableFalse() async {
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
    let obj = try! JSONSerialization.jsonObject(
        with: Data(result.message.utf8)
    ) as! [String: Any]
    #expect(obj["exists"] as? Bool == true)
    #expect(obj["source"] as? String == "disk-only")
    #expect(obj["loadable"] as? Bool == false)
    #expect(obj["warning"] != nil)
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
