import Foundation
import Testing
@testable import LogicProMCP

// MARK: - T1: LibraryNode / LibraryRoot Data Types

@Suite("T1: Library data types — Codable/Sendable/Equatable")
struct LibraryAccessorTypesTests {

    // 1 — enum rawValues
    @Test func testLibraryNodeKindRawValues() async throws {
        #expect(LibraryNodeKind.folder.rawValue == "folder")
        #expect(LibraryNodeKind.leaf.rawValue == "leaf")
        #expect(LibraryNodeKind.truncated.rawValue == "truncated")
        #expect(LibraryNodeKind.probeTimeout.rawValue == "probeTimeout")
        #expect(LibraryNodeKind.cycle.rawValue == "cycle")
    }

    // 2 — leaf encodes
    @Test func testLibraryNodeLeafEncodesCorrectly() async throws {
        let leaf = LibraryNode(name: "Warm Violins", path: "Orchestral/Strings/Warm Violins", kind: .leaf, children: [])
        let data = try JSONEncoder().encode(leaf)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"name\""))
        #expect(s.contains("\"path\""))
        #expect(s.contains("\"kind\""))
        #expect(s.contains("\"children\""))
        #expect(s.contains("\"Warm Violins\""))
    }

    // 3 — folder with children
    @Test func testLibraryNodeFolderWithChildren() async throws {
        let a = LibraryNode(name: "A", path: "Cat/A", kind: .leaf, children: [])
        let b = LibraryNode(name: "B", path: "Cat/B", kind: .leaf, children: [])
        let c = LibraryNode(name: "C", path: "Cat/C", kind: .leaf, children: [])
        let folder = LibraryNode(name: "Cat", path: "Cat", kind: .folder, children: [a, b, c])
        #expect(folder.children.count == 3)
        let data = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(LibraryNode.self, from: data)
        #expect(decoded == folder)
    }

    // 4 — no "position" field in JSON at any depth
    @Test func testLibraryNodeNoPositionField() async throws {
        let deep = LibraryNode(
            name: "Root", path: "", kind: .folder, children: [
                LibraryNode(name: "A", path: "A", kind: .folder, children: [
                    LibraryNode(name: "B", path: "A/B", kind: .leaf, children: [])
                ])
            ]
        )
        let data = try JSONEncoder().encode(deep)
        let s = String(data: data, encoding: .utf8)!
        #expect(!s.contains("\"position\""))
        #expect(!s.contains("\"CGPoint\""))
    }

    // 5 — LibraryRoot all fields
    @Test func testLibraryRoot_AllFields() async throws {
        let root = sampleRoot()
        let data = try JSONEncoder().encode(root)
        let s = String(data: data, encoding: .utf8)!
        for key in [
            "generatedAt", "scanDurationMs", "measuredSettleDelayMs",
            "selectionRestored", "truncatedBranches", "probeTimeouts", "cycleCount",
            "nodeCount", "leafCount", "folderCount",
            "root", "categories", "presetsByCategory",
        ] {
            #expect(s.contains("\"\(key)\""), "missing key \(key)")
        }
    }

    // 6 — 5-level round-trip
    @Test func testLibraryRoot_JSONRoundTrip5Levels() async throws {
        let deep = LibraryNode(
            name: "L0", path: "L0", kind: .folder, children: [
                LibraryNode(name: "L1", path: "L0/L1", kind: .folder, children: [
                    LibraryNode(name: "L2", path: "L0/L1/L2", kind: .folder, children: [
                        LibraryNode(name: "L3", path: "L0/L1/L2/L3", kind: .folder, children: [
                            LibraryNode(name: "L4", path: "L0/L1/L2/L3/L4", kind: .leaf, children: [])
                        ])
                    ])
                ])
            ]
        )
        let rootNode = LibraryNode(name: "(library-root)", path: "", kind: .folder, children: [deep])
        let lr = LibraryRoot(
            generatedAt: "2026-04-12T12:00:00Z",
            scanDurationMs: 123, measuredSettleDelayMs: 500,
            selectionRestored: false,
            truncatedBranches: 0, probeTimeouts: 0, cycleCount: 0,
            nodeCount: 6, leafCount: 1, folderCount: 5,
            root: rootNode,
            categories: ["L0"],
            presetsByCategory: ["L0": ["L4"]]
        )
        let data = try JSONEncoder().encode(lr)
        let decoded = try JSONDecoder().decode(LibraryRoot.self, from: data)
        #expect(decoded == lr)
    }

    // 7 — decode from minimal JSON
    @Test func testLibraryRoot_DecodesFromMinimalJSON() async throws {
        let json = """
        {
            "generatedAt": "2026-04-12T00:00:00Z",
            "scanDurationMs": 0,
            "measuredSettleDelayMs": 0,
            "selectionRestored": false,
            "truncatedBranches": 0,
            "probeTimeouts": 0,
            "cycleCount": 0,
            "nodeCount": 1,
            "leafCount": 0,
            "folderCount": 1,
            "root": { "name": "r", "path": "", "kind": "folder", "children": [] },
            "categories": [],
            "presetsByCategory": {}
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LibraryRoot.self, from: data)
        #expect(decoded.nodeCount == 1)
        #expect(decoded.root.kind == .folder)
    }

    // 8 — malformed rejects
    @Test func testLibraryRoot_DecodeRejectsMalformed() async throws {
        let badJSON = "{ \"root\": { \"name\": \"r\" } }" // missing required fields
        let data = badJSON.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LibraryRoot.self, from: data)
        }
    }

    // 9 — cycleCount round-trip
    @Test func testLibraryRoot_CycleCountSerializesCorrectly() async throws {
        var root = sampleRoot()
        root = LibraryRoot(
            generatedAt: root.generatedAt, scanDurationMs: root.scanDurationMs,
            measuredSettleDelayMs: root.measuredSettleDelayMs,
            selectionRestored: root.selectionRestored,
            truncatedBranches: root.truncatedBranches, probeTimeouts: root.probeTimeouts,
            cycleCount: 3, // ← the value under test
            nodeCount: root.nodeCount, leafCount: root.leafCount, folderCount: root.folderCount,
            root: root.root, categories: root.categories, presetsByCategory: root.presetsByCategory
        )
        let data = try JSONEncoder().encode(root)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"cycleCount\":3") || s.contains("\"cycleCount\" : 3"))
        let decoded = try JSONDecoder().decode(LibraryRoot.self, from: data)
        #expect(decoded.cycleCount == 3)
    }

    // MARK: - fixtures

    private func sampleRoot() -> LibraryRoot {
        let l = LibraryNode(name: "Sub", path: "Cat/Sub", kind: .leaf, children: [])
        let cat = LibraryNode(name: "Cat", path: "Cat", kind: .folder, children: [l])
        let r = LibraryNode(name: "(library-root)", path: "", kind: .folder, children: [cat])
        return LibraryRoot(
            generatedAt: "2026-04-12T12:00:00Z",
            scanDurationMs: 100, measuredSettleDelayMs: 500,
            selectionRestored: true,
            truncatedBranches: 0, probeTimeouts: 0, cycleCount: 0,
            nodeCount: 3, leafCount: 1, folderCount: 2,
            root: r,
            categories: ["Cat"],
            presetsByCategory: ["Cat": ["Sub"]]
        )
    }
}
