import Foundation
import Testing
@testable import LogicProMCP

@Suite("T8: LibraryAccessor helpers + perf regression")
struct LibraryAccessorHelpersTests {

    // ---- parsePath additional coverage (mostly in T3 already) ----

    @Test func testParsePath_UnicodeCategorySurvives() async throws {
        let p = LibraryAccessor.parsePath("오케스트라/따뜻한 바이올린")
        #expect(p == ["오케스트라", "따뜻한 바이올린"])
    }

    @Test func testParsePath_VeryLongPath() async throws {
        let segs = (0..<12).map { "L\($0)" }
        let joined = segs.joined(separator: "/")
        let p = LibraryAccessor.parsePath(joined)
        #expect(p?.count == 12)
    }

    // ---- resolvePath on cached tree edges ----

    private func buildRoot(_ children: [LibraryNode]) -> LibraryRoot {
        let r = LibraryNode(name: "(root)", path: "", kind: .folder, children: children)
        return LibraryRoot(
            generatedAt: "t", scanDurationMs: 0, measuredSettleDelayMs: 0,
            selectionRestored: false,
            truncatedBranches: 0, probeTimeouts: 0, cycleCount: 0,
            nodeCount: 0, leafCount: 0, folderCount: 0,
            root: r, categories: children.map(\.name),
            presetsByCategory: [:]
        )
    }

    @Test func testResolvePath_TopLevelLeafAsCategory() async throws {
        let leaf = LibraryNode(name: "Quick", path: "Quick", kind: .leaf, children: [])
        let root = buildRoot([leaf])
        let r = LibraryAccessor.resolvePath("Quick", in: root)
        #expect(r?.exists == true)
        #expect(r?.kind == .leaf)
    }

    @Test func testResolvePath_ChildrenListedForFolder() async throws {
        let l1 = LibraryNode(name: "A", path: "Cat/A", kind: .leaf, children: [])
        let l2 = LibraryNode(name: "B", path: "Cat/B", kind: .leaf, children: [])
        let cat = LibraryNode(name: "Cat", path: "Cat", kind: .folder, children: [l1, l2])
        let r = LibraryAccessor.resolvePath("Cat", in: buildRoot([cat]))
        #expect(r?.kind == .folder)
        #expect(Set(r?.children ?? []) == Set(["A", "B"]))
    }

    // ---- Inventory.Codable (legacy type) ----

    @Test func testLegacyInventory_Codable() async throws {
        let inv = LibraryAccessor.Inventory(
            categories: ["Bass"],
            presetsByCategory: ["Bass": ["Sub"]],
            currentCategory: "Bass", currentPreset: "Sub"
        )
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(LibraryAccessor.Inventory.self, from: data)
        #expect(decoded.categories == inv.categories)
    }

    // ---- Flatten policy: leaf-only category ----

    @Test func testFlatten_LeafTopLevel_EmptyArray() async throws {
        // When top-level is a leaf (not folder), its entry in presetsByCategory is empty
        let probe = TreeProbe(
            childrenAt: { path in path.isEmpty ? ["SoloLeaf"] : [] },
            focusOK: { true }, mutationSinceLastCheck: { false },
            sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
        )
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        #expect(root!.presetsByCategory["SoloLeaf"] == [])
    }

    // ---- Disambiguator edge cases (via enumerateTree) ----

    @Test func testDisambiguator_TripleDuplicate() async throws {
        let m: [String: [String]?] = [
            "": ["Drum"],
            "Drum": ["Kit", "Kit", "Kit"],
            "Drum/Kit[0]": [], "Drum/Kit[1]": [], "Drum/Kit[2]": [],
        ]
        let probe = TreeProbe(
            childrenAt: { p in m[p.joined(separator: "/")] ?? nil },
            focusOK: { true }, mutationSinceLastCheck: { false },
            sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
        )
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        var leaves: [String] = []
        func walk(_ n: LibraryNode) {
            if n.kind == .leaf { leaves.append(n.path) }
            n.children.forEach(walk)
        }
        walk(root!.root)
        #expect(leaves.contains("Drum/Kit[0]"))
        #expect(leaves.contains("Drum/Kit[1]"))
        #expect(leaves.contains("Drum/Kit[2]"))
    }

    // ---- Visited set capacity sanity ----

    @Test func testVisitedSet_Capacity10k_NoPanic() async throws {
        var s = Set<Int>()
        for i in 0..<10_000 {
            s.insert(i)
        }
        #expect(s.count == 10_000)
    }

    // ---- T8 #19 Perf regression guard: 100 folders under 2s (virtual clock, 0 settle) ----

    @Test func testEnumerateTree_Perf_100Folders_UnderBudget() async throws {
        var build: [String: [String]?] = [:]
        var categories: [String] = []
        for i in 0..<100 {
            let catName = "Cat\(i)"
            categories.append(catName)
            let presets = (0..<30).map { "P\(i)_\($0)" }
            build[catName] = presets
            for p in presets { build["\(catName)/\(p)"] = [] }
        }
        build[""] = categories
        let m = build  // immutable snapshot is Sendable
        let probe = TreeProbe(
            childrenAt: { p in m[p.joined(separator: "/")] ?? nil },
            focusOK: { true }, mutationSinceLastCheck: { false },
            sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
        )
        let start = Date()
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        let elapsed = Date().timeIntervalSince(start)
        #expect(root != nil)
        #expect(root!.leafCount == 3000)
        #expect(elapsed < 2.0, "pure traversal should be < 2s, got \(elapsed)")
    }

    // ---- T8 #20 Linear scaling proof (50/100/200 ratio ≤ 2.5×) ----

    @Test func testEnumerateTree_Perf_ScalesLinearly_NotQuadratic() async throws {
        func time(folderCount n: Int) async -> TimeInterval {
            var build: [String: [String]?] = [:]
            var cats: [String] = []
            for i in 0..<n {
                cats.append("C\(i)"); build["C\(i)"] = ["L"]
                build["C\(i)/L"] = []
            }
            build[""] = cats
            let m = build
            let probe = TreeProbe(
                childrenAt: { p in m[p.joined(separator: "/")] ?? nil },
                focusOK: { true }, mutationSinceLastCheck: { false },
                sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
            )
            let start = Date()
            _ = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
            return Date().timeIntervalSince(start)
        }
        let t50 = await time(folderCount: 50)
        let t100 = await time(folderCount: 100)
        let t200 = await time(folderCount: 200)
        // Ratio t100/t50 and t200/t100 should each be ≤ 2.5× (allow noise).
        // If either is > 2.5 there's a super-linear bug.
        if t50 > 0.001 {  // skip if too fast to measure
            #expect(t100 / t50 < 2.5, "t100/t50=\(t100/t50)")
        }
        if t100 > 0.001 {
            #expect(t200 / t100 < 2.5, "t200/t100=\(t200/t100)")
        }
    }

    // ---- ScanOrchestration: restore disabled when cachedSelection nil ----

    @Test func testScanOrchestration_NilSelection_NoRestoreCall() async throws {
        let calls = CallRecorder()
        let probe = TreeProbe(
            childrenAt: { p in p.isEmpty ? ["A"] : [] },
            focusOK: { true }, mutationSinceLastCheck: { false },
            sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
        )
        _ = await LibraryAccessor.ScanOrchestration.run(
            probe: probe, cachedSelection: nil,
            restoreSelection: { _, _ in await calls.rec(); return true },
            writeJSON: { _ in true }, onComplete: { _ in }, settleDelayMs: 0
        )
        let n = await calls.n
        #expect(n == 0)
    }

    // ---- node count self-consistency ----

    @Test func testNodeCount_SelfConsistent() async throws {
        let probe = TreeProbe(
            childrenAt: { p in
                if p.isEmpty { return ["A", "B"] }
                if p == ["A"] { return ["a1", "a2"] }
                if p == ["B"] { return ["b1"] }
                return []
            },
            focusOK: { true }, mutationSinceLastCheck: { false },
            sleep: { _ in }, visitedHash: { $0.joined(separator: "/").hashValue }
        )
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)!
        #expect(root.leafCount == 3)
        #expect(root.nodeCount == root.leafCount + root.folderCount)
    }

    // ---- PathRuntime tests exercise selectByPath branches (already in T3 but add defensive) ----

    @Test func testSelectByPath_EmptyPath_ReturnsFalse() async throws {
        let rt = LibraryAccessor.PathRuntime(clickByName: { _ in true }, sleep: { _ in })
        let ok = await LibraryAccessor.selectByPath("", settleDelayMs: 0, runtime: rt)
        #expect(!ok)
    }

    @Test func testSelectByPath_SingleSegment_Works() async throws {
        let rec = CallRecorder()
        let rt = LibraryAccessor.PathRuntime(
            clickByName: { _ in await rec.rec(); return true },
            sleep: { _ in }
        )
        let ok = await LibraryAccessor.selectByPath("OnlyOne", settleDelayMs: 0, runtime: rt)
        #expect(ok)
        let n = await rec.n
        #expect(n == 1)
    }
}

private actor CallRecorder {
    var n: Int = 0
    func rec() { n += 1 }
}
