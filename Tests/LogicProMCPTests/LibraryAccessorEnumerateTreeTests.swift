import Foundation
import Testing
@testable import LogicProMCP

// MARK: - T2 TreeProbe mock infrastructure

private actor ProbeRecorder {
    var clicks: [[String]] = []
    var sleeps: [Int] = []
    var focusChecks: Int = 0
    var mutationChecks: Int = 0
    func recordClick(_ path: [String]) { clicks.append(path) }
    func recordSleep(_ ms: Int) { sleeps.append(ms) }
    func recordFocus() { focusChecks += 1 }
    func recordMutation() { mutationChecks += 1 }
}

private struct MockTree: Sendable {
    // [parentPath] → children names (nil = probeTimeout)
    let map: [String: [String]?]
    let leaves: Set<String>
    let visitedIdentity: [String: Int]  // path.joined("/") → identity; defaults to hash

    static func flat(categories: [String], presetsPerCategory: [String: [String]]) -> MockTree {
        var m: [String: [String]?] = [:]
        m[""] = categories
        var leaves = Set<String>()
        for (c, ps) in presetsPerCategory {
            m[c] = ps
            for p in ps {
                leaves.insert("\(c)/\(p)")
                m["\(c)/\(p)"] = []   // explicit leaf signal
            }
        }
        return MockTree(map: m, leaves: leaves, visitedIdentity: [:])
    }

    func children(at path: [String]) -> [String]?? {
        let key = path.joined(separator: "/")
        if let v = map[key] { return v }
        return .some(nil)  // unknown path → probe timeout
    }
}

private func makeProbe(
    tree: MockTree,
    focusOK: Bool = true,
    externalMutationAtClick: Int? = nil,
    recorder: ProbeRecorder
) -> TreeProbe {
    return TreeProbe(
        childrenAt: { path in
            await recorder.recordClick(path)
            let lookup = tree.children(at: path)
            switch lookup {
            case .some(.some(let arr)): return arr
            case .some(.none): return nil          // probeTimeout
            case .none: return nil
            }
        },
        focusOK: {
            await recorder.recordFocus()
            return focusOK
        },
        mutationSinceLastCheck: {
            await recorder.recordMutation()
            if let idx = externalMutationAtClick, await recorder.clicks.count >= idx {
                return true
            }
            return false
        },
        sleep: { ms in
            await recorder.recordSleep(ms)
            // no real sleep in tests
        },
        visitedHash: { path in
            if let id = tree.visitedIdentity[path.joined(separator: "/")] { return id }
            return path.joined(separator: "/").hashValue
        }
    )
}

// MARK: - T2 Tests

@Suite("T2: enumerateTree recursive walker")
struct LibraryAccessorEnumerateTreeTests {

    // 1 — happy path 2-level
    @Test func testEnumerateTree_HappyPath_2Level() async throws {
        let tree = MockTree.flat(
            categories: ["Bass", "Guitar", "Drums"],
            presetsPerCategory: [
                "Bass": ["Sub", "Funky"],
                "Guitar": ["Clean", "Dirty"],
                "Drums": ["Kit1", "Kit2"]
            ]
        )
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 500, probe: probe)
        #expect(root != nil)
        #expect(root!.leafCount == 6)
        #expect(root!.folderCount == 4) // synthetic root + 3 categories
        #expect(root!.categories.count == 3)
        #expect(root!.presetsByCategory["Bass"] == ["Sub", "Funky"])
    }

    // 2 — deep 6-level
    @Test func testEnumerateTree_Deep6Level() async throws {
        var map: [String: [String]?] = [:]
        map[""] = ["L1"]
        map["L1"] = ["L2"]
        map["L1/L2"] = ["L3"]
        map["L1/L2/L3"] = ["L4"]
        map["L1/L2/L3/L4"] = ["L5"]
        map["L1/L2/L3/L4/L5"] = ["Final"]
        map["L1/L2/L3/L4/L5/Final"] = []
        let tree = MockTree(map: map, leaves: ["L1/L2/L3/L4/L5/Final"], visitedIdentity: [:])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        #expect(root!.leafCount == 1)
    }

    // 3 — maxDepth truncation
    @Test func testEnumerateTree_MaxDepthTruncation() async throws {
        var map: [String: [String]?] = [:]
        map[""] = ["L1"]
        map["L1"] = ["L2"]
        map["L1/L2"] = ["L3"]
        map["L1/L2/L3"] = ["L4"]
        map["L1/L2/L3/L4"] = ["L5"]
        let tree = MockTree(map: map, leaves: [], visitedIdentity: [:])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 2, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        // Should have at least one truncated marker
        #expect(root!.truncatedBranches >= 1)
    }

    // 4 — duplicate siblings
    @Test func testEnumerateTree_DuplicateSiblings() async throws {
        let tree = MockTree(
            map: ["": ["Synth"], "Synth": ["Pad", "Pad"], "Synth/Pad[0]": [], "Synth/Pad[1]": []],
            leaves: ["Synth/Pad[0]", "Synth/Pad[1]"],
            visitedIdentity: [:]
        )
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        // Collect leaf paths
        var leafPaths: [String] = []
        func walk(_ n: LibraryNode) {
            if n.kind == .leaf { leafPaths.append(n.path) }
            n.children.forEach(walk)
        }
        walk(root!.root)
        #expect(leafPaths.contains("Synth/Pad[0]"))
        #expect(leafPaths.contains("Synth/Pad[1]"))
    }

    // 5 — empty category
    @Test func testEnumerateTree_EmptyCategory() async throws {
        let tree = MockTree(
            map: ["": ["EmptyCat"], "EmptyCat": []],
            leaves: [],
            visitedIdentity: [:]
        )
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        // EmptyCat is a leaf (no children) — expected
        #expect(root!.leafCount == 1)
    }

    // 6 — whitespace-only name skipped
    @Test func testEnumerateTree_WhitespaceOnlyName_Skipped() async throws {
        let tree = MockTree(
            map: ["": ["Good", "   ", "AnotherGood"], "Good": [], "AnotherGood": []],
            leaves: [],
            visitedIdentity: [:]
        )
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        #expect(root!.categories == ["Good", "AnotherGood"])
    }

    // 7 — probe timeout
    @Test func testEnumerateTree_ProbeTimeout() async throws {
        let tree = MockTree(
            map: ["": ["Stuck"]],  // "Stuck" not in map → nil (probe timeout)
            leaves: [],
            visitedIdentity: [:]
        )
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        #expect(root!.probeTimeouts >= 1)
    }

    // 8 — cycle safety
    @Test func testEnumerateTree_CycleSafety_VisitedSet() async throws {
        // Same identity for two different paths → cycle
        let tree = MockTree(
            map: ["": ["A"], "A": ["Back"], "A/Back": ["Deep"]],
            leaves: [],
            visitedIdentity: ["A/Back": 42, "A/Back/Deep": 42]  // ← colliding hash
        )
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        #expect(root!.cycleCount >= 1)
    }

    // 9 — Task.sleep usage
    @Test func testEnumerateTree_UsesTaskSleep() async throws {
        let tree = MockTree.flat(categories: ["A"], presetsPerCategory: ["A": ["P"]])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        _ = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 250, probe: probe)
        // Sleeps at least once with 250ms
        let sleeps = await rec.sleeps
        #expect(sleeps.contains(250))
    }

    // 10 — flatten policy, depth 3 tree
    @Test func testEnumerateTree_FlattenPolicy_Depth3Tree() async throws {
        var map: [String: [String]?] = [:]
        map[""] = ["Orch"]
        map["Orch"] = ["Strings", "Brass"]
        map["Orch/Strings"] = ["Warm", "Bright"]
        map["Orch/Brass"] = ["Tuba"]
        map["Orch/Strings/Warm"] = []
        map["Orch/Strings/Bright"] = []
        map["Orch/Brass/Tuba"] = []
        let tree = MockTree(map: map, leaves: [], visitedIdentity: [:])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        // presetsByCategory["Orch"] should flatten all leaves: Warm, Bright, Tuba
        let list = root!.presetsByCategory["Orch"] ?? []
        #expect(Set(list) == Set(["Warm", "Bright", "Tuba"]))
    }

    // 11 — panel closed returns nil
    @Test func testEnumerateTree_PanelClosed_ReturnsNil() async throws {
        let tree = MockTree(map: ["": nil], leaves: [], visitedIdentity: [:])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root == nil)
    }

    // 12 — stable ordering: two runs produce identical structure
    @Test func testEnumerateTree_StableOrdering() async throws {
        let tree = MockTree.flat(categories: ["A", "B"], presetsPerCategory: ["A": ["1", "2"], "B": ["3"]])
        let r1 = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: makeProbe(tree: tree, recorder: ProbeRecorder()))
        let r2 = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: makeProbe(tree: tree, recorder: ProbeRecorder()))
        #expect(r1 != nil && r2 != nil)
        #expect(r1!.root == r2!.root)
        #expect(r1!.categories == r2!.categories)
    }

    // 13 — E5b scanner self-click guard — no false abort from our own clicks
    @Test func testEnumerateTree_E5b_ScannerSelfClickGuard() async throws {
        let tree = MockTree.flat(categories: ["A"], presetsPerCategory: ["A": ["P"]])
        let rec = ProbeRecorder()
        // Indicate no external mutation — scanner's own clicks should not trigger abort
        let probe = makeProbe(tree: tree, externalMutationAtClick: nil, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil, "scanner's own click should not be mistaken for external mutation")
        #expect(root!.leafCount == 1)
    }

    // 14 — E5c focus loss abort
    @Test func testEnumerateTree_E5c_FocusLoss_Abort() async throws {
        let tree = MockTree.flat(categories: ["A"], presetsPerCategory: ["A": ["P"]])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, focusOK: false, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root == nil, "focus loss should abort scan (return nil)")
    }

    // 15 — E5 external mutation abort
    @Test func testEnumerateTree_E5_ExternalMutation_Abort() async throws {
        let tree = MockTree.flat(categories: ["A", "B"], presetsPerCategory: ["A": ["P"], "B": ["Q"]])
        let rec = ProbeRecorder()
        // Fire external mutation after the 2nd click (well into the scan)
        let probe = makeProbe(tree: tree, externalMutationAtClick: 2, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        // Abort → nil OR partial root; we require nil for clean abort semantics
        #expect(root == nil, "external mutation should abort scan")
    }

    // v3.0.4 — 3-level tree mirroring Isaac's Library Panel empirical findings:
    // Synthesizer holds subfolders (Bass, Lead), each holding real leaves.
    // Electronic Drums has leaves at depth 2. A correct enumerateTree must
    // return 4 actual leaves, not 2 subfolder markers as pre-3.0.4 did.
    @Test func testEnumerateTree_3Level_SynthBass_ElectronicDrums() async throws {
        var map: [String: [String]?] = [:]
        map[""] = ["Synthesizer", "Electronic Drums"]
        map["Synthesizer"] = ["Bass", "Lead"]
        map["Synthesizer/Bass"] = ["Acid Etched Bass", "Dark Drone Bass"]
        map["Synthesizer/Lead"] = ["Hard Metal Lead"]
        map["Synthesizer/Bass/Acid Etched Bass"] = []
        map["Synthesizer/Bass/Dark Drone Bass"] = []
        map["Synthesizer/Lead/Hard Metal Lead"] = []
        map["Electronic Drums"] = ["Roland TR-909"]
        map["Electronic Drums/Roland TR-909"] = []
        let tree = MockTree(map: map, leaves: [
            "Synthesizer/Bass/Acid Etched Bass",
            "Synthesizer/Bass/Dark Drone Bass",
            "Synthesizer/Lead/Hard Metal Lead",
            "Electronic Drums/Roland TR-909"
        ], visitedIdentity: [:])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root != nil)
        // 4 real leaves (not the 2 subfolders we'd see at depth 2 truncation)
        #expect(root!.leafCount == 4,
                "deep Library walk must surface every .patch leaf, not stop at folders")
        // Folders: synthetic root + Synthesizer + Bass + Lead + Electronic Drums = 5
        #expect(root!.folderCount == 5)
        // presetsByCategory flattens every leaf under its top-level category
        let synthLeaves = Set(root!.presetsByCategory["Synthesizer"] ?? [])
        #expect(synthLeaves == Set(["Acid Etched Bass", "Dark Drone Bass", "Hard Metal Lead"]))
        #expect(root!.presetsByCategory["Electronic Drums"] == ["Roland TR-909"])
    }

    // 16 — panel closed exact error text (via wrapper return)
    @Test func testEnumerateTree_PanelClosed_ExactErrorText() async throws {
        // The error text is surfaced by AccessibilityChannel T4, not enumerateTree itself.
        // Here we simply confirm enumerateTree returns nil; the T4 integration test asserts the text.
        let tree = MockTree(map: ["": nil], leaves: [], visitedIdentity: [:])
        let rec = ProbeRecorder()
        let probe = makeProbe(tree: tree, recorder: rec)
        let root = await LibraryAccessor.enumerateTree(maxDepth: 12, settleDelayMs: 0, probe: probe)
        #expect(root == nil)
    }
}
