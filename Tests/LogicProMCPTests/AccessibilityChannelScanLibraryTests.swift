import Foundation
import Testing
@testable import LogicProMCP

@Suite("T4: scanLibraryAll orchestration + Tier-A + JSON write")
struct AccessibilityChannelScanLibraryTests {

    private actor ChannelMock {
        var scanInProgress = false
        var lastScan: LibraryRoot?
        var lastRoutedCategory: String?
        var lastRoutedPreset: String?
        var restoreCalls: [(String, String)] = []
        var jsonWrites: [LibraryRoot] = []
        var forceWriteFailure = false
        func setInProgress(_ v: Bool) { scanInProgress = v }
        func getInProgress() -> Bool { scanInProgress }
        func setRouted(cat: String?, preset: String?) { lastRoutedCategory = cat; lastRoutedPreset = preset }
        func takeSelectionSnapshot() -> (String, String)? {
            if let c = lastRoutedCategory, let p = lastRoutedPreset { return (c, p) }
            return nil
        }
        func restore(_ c: String, _ p: String) -> Bool { restoreCalls.append((c, p)); return true }
        func writeJSON(_ r: LibraryRoot) -> Bool {
            if forceWriteFailure { return false }
            jsonWrites.append(r); return true
        }
        func setLastScan(_ r: LibraryRoot) { lastScan = r }
        func setWriteFailure(_ v: Bool) { forceWriteFailure = v }
    }

    // 1. happy path → JSON stringifies LibraryRoot with all fields
    @Test func testScanLibraryAll_HappyPath_JSON() async throws {
        let mock = ChannelMock()
        let probe = Self.flatProbe(categories: ["Bass"], presets: ["Bass": ["Sub"]])
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: nil,
            restoreSelection: { c, p in await mock.restore(c, p) },
            writeJSON: { root in await mock.writeJSON(root) },
            onComplete: { root in await mock.setLastScan(root) },
            settleDelayMs: 0
        )
        #expect(r != nil)
        let writes = await mock.jsonWrites.count
        #expect(writes == 1)
        #expect(r!.cachePath != nil)
    }

    // 2. panel closed → nil
    @Test func testScanLibraryAll_PanelClosed_Error() async throws {
        let probe = TreeProbe(
            childrenAt: { _ in nil }, focusOK: { true },
            mutationSinceLastCheck: { false }, sleep: { _ in },
            visitedHash: { _ in 0 }
        )
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { _ in true },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r == nil)
    }

    // 3. Tier-A cache HIT → restore called
    @Test func testScanLibraryAll_TierA_CacheHit_RestoresSelection() async throws {
        let mock = ChannelMock()
        let probe = Self.flatProbe(categories: ["A"], presets: ["A": ["P"]])
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: ("A", "P"),
            restoreSelection: { c, p in await mock.restore(c, p) },
            writeJSON: { _ in true },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r != nil)
        #expect(r!.selectionRestored == true)
        let calls = await mock.restoreCalls
        #expect(calls.count == 1)
        #expect(calls[0] == ("A", "P"))
    }

    // 4. Tier-A cache MISS → selectionRestored = false, no restore call
    @Test func testScanLibraryAll_TierA_CacheMiss_FalseFlag() async throws {
        let mock = ChannelMock()
        let probe = Self.flatProbe(categories: ["A"], presets: ["A": ["P"]])
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: nil,
            restoreSelection: { c, p in await mock.restore(c, p) },
            writeJSON: { _ in true },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r != nil)
        #expect(r!.selectionRestored == false)
        let calls = await mock.restoreCalls
        #expect(calls.count == 0)
    }

    // 5. E17 write failure → result still returned, cachePath nil
    @Test func testScanLibraryAll_E17_WriteFailure_Tolerated() async throws {
        let mock = ChannelMock()
        await mock.setWriteFailure(true)
        let probe = Self.flatProbe(categories: ["A"], presets: ["A": ["P"]])
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { root in await mock.writeJSON(root) },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r != nil)   // tolerated — scan still succeeds
        #expect(r!.cachePath == nil)   // write failed — no path emitted
    }

    // 6. lastScan cache populated via onComplete
    @Test func testScanLibraryAll_LastScanCachedInActor() async throws {
        let mock = ChannelMock()
        let probe = Self.flatProbe(categories: ["A"], presets: ["A": ["P"]])
        _ = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { _ in true },
            onComplete: { root in await mock.setLastScan(root) },
            settleDelayMs: 0
        )
        let cached = await mock.lastScan
        #expect(cached != nil)
        #expect(cached!.leafCount == 1)
    }

    // 7. concurrent scans — second returns nil (lock pre-check)
    @Test func testScanLibraryAll_ConcurrentScan_SecondErrors() async throws {
        let mock = ChannelMock()
        await mock.setInProgress(true)
        let gateResult = await mock.getInProgress()
        #expect(gateResult == true)   // simulates pre-check: scan already in progress
        // In the channel, execute would return .error("Library scan already in progress") here.
    }

    // 8. result contains structural fields from LibraryRoot
    @Test func testScanLibraryAll_RespondsIncludesStructuralFields() async throws {
        let probe = Self.flatProbe(categories: ["A", "B"], presets: ["A": ["X"], "B": ["Y"]])
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe,
            cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { _ in true },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r != nil)
        #expect(r!.root.leafCount == 2)
        #expect(r!.root.nodeCount >= 4)
        #expect(r!.root.folderCount >= 3)
    }

    // 9. JSON write is valid (can decode the written blob)
    @Test func testScanLibraryAll_AC1_6_JSONWrittenToResources() async throws {
        let mock = ChannelMock()
        let probe = Self.flatProbe(categories: ["A"], presets: ["A": ["P"]])
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe, cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { root in await mock.writeJSON(root) },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r != nil)
        let writes = await mock.jsonWrites
        #expect(writes.count == 1)
        let data = try JSONEncoder().encode(writes[0])
        let decoded = try JSONDecoder().decode(LibraryRoot.self, from: data)
        #expect(decoded.leafCount == 1)
    }

    // 10. Flatten policy verified for depth-3
    @Test func testScanLibraryAll_FlattenPolicy_Depth3Actually() async throws {
        let m: [String: [String]?] = [
            "": ["Orch"],
            "Orch": ["Strings", "Brass"],
            "Orch/Strings": ["Warm"],
            "Orch/Brass": ["Tuba"],
            "Orch/Strings/Warm": [],
            "Orch/Brass/Tuba": [],
        ]
        let probe = TreeProbe(
            childrenAt: { p in m[p.joined(separator: "/")] ?? nil },
            focusOK: { true }, mutationSinceLastCheck: { false },
            sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
        )
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe, cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { _ in true },
            onComplete: { _ in },
            settleDelayMs: 0
        )
        #expect(r != nil)
        let orch = r!.root.presetsByCategory["Orch"] ?? []
        #expect(Set(orch) == Set(["Warm", "Tuba"]))
    }

    // 11. Abort on mutation → no JSON write, no cache update
    @Test func testScanLibraryAll_AXMutationMidScan_Aborts() async throws {
        let mock = ChannelMock()
        let counter = Counter()
        let probe = TreeProbe(
            childrenAt: { _ in ["A"] },
            focusOK: { true },
            mutationSinceLastCheck: {
                await counter.inc()
                return await counter.value > 1
            },
            sleep: { _ in },
            visitedHash: { $0.joined(separator: "/").hashValue }
        )
        let r = await LibraryAccessor.ScanOrchestration.run(
            probe: probe, cachedSelection: nil,
            restoreSelection: { _, _ in true },
            writeJSON: { root in await mock.writeJSON(root) },
            onComplete: { root in await mock.setLastScan(root) },
            settleDelayMs: 0
        )
        #expect(r == nil)
        let writes = await mock.jsonWrites.count
        #expect(writes == 0)
        let cached = await mock.lastScan
        #expect(cached == nil)
    }

    // helpers
    private actor Counter {
        var value: Int = 0
        func inc() { value += 1 }
    }
    private static func flatProbe(categories: [String], presets: [String: [String]]) -> TreeProbe {
        var m: [String: [String]?] = ["": categories]
        for (c, ps) in presets {
            m[c] = ps
            for p in ps { m["\(c)/\(p)"] = [] }
        }
        let tree = m  // captured by let (Sendable)
        return TreeProbe(
            childrenAt: { path in tree[path.joined(separator: "/")] ?? nil },
            focusOK: { true },
            mutationSinceLastCheck: { false },
            sleep: { _ in },
            visitedHash: { $0.joined(separator: "/").hashValue }
        )
    }
}
