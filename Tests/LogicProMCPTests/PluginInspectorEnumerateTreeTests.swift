import Foundation
import Testing
@testable import LogicProMCP

@Suite("PluginInspector — T2 enumerateMenuTree")
struct PluginInspectorEnumerateTreeTests {
    // Helper: build a probe with scripted tree lookup
    private func makeProbe(
        tree: [String: [PluginMenuItemInfo]],
        focus: Bool = true,
        mutate: Bool = false
    ) -> PluginPresetProbe {
        PluginPresetProbe(
            menuItemsAt: { segs in tree[segs.joined(separator: "/")] },
            pressMenuItem: { _ in true },
            focusOK: { focus },
            mutationSinceLastCheck: { mutate },
            sleep: { _ in },
            visitedHash: { $0.joined(separator: "/").hashValue }
        )
    }

    @Test func happyPath3LevelTree() async throws {
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [
                .init(name: "A", kind: .folder, hasSubmenu: true),
                .init(name: "B", kind: .folder, hasSubmenu: true),
            ],
            "A": [.init(name: "A1", kind: .leaf, hasSubmenu: false)],
            "B": [.init(name: "B1", kind: .leaf, hasSubmenu: false)],
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        #expect(root.children.count == 2)
        #expect(root.children[0].name == "A")
        #expect(root.children[0].children[0].name == "A1")
        #expect(root.children[0].children[0].kind == .leaf)
    }

    @Test func deepTreeMaxDepthEnforcement() async throws {
        // 5-level chain, maxDepth=2 → depth 3+ truncated
        var tree: [String: [PluginMenuItemInfo]] = [:]
        tree[""] = [.init(name: "L1", kind: .folder, hasSubmenu: true)]
        tree["L1"] = [.init(name: "L2", kind: .folder, hasSubmenu: true)]
        tree["L1/L2"] = [.init(name: "L3", kind: .folder, hasSubmenu: true)]
        tree["L1/L2/L3"] = [.init(name: "L4", kind: .leaf, hasSubmenu: false)]

        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree), maxDepth: 2)
        // Depth 0 (root) → depth 1 (L1) → depth 2 (L2) → truncated at depth 3 (L3 invocation exceeds)
        let l1 = root.children[0]
        let l2 = l1.children[0]
        // L3 branch should be truncated (depth 3 walk hits cap)
        let l3 = l2.children[0]
        #expect(l3.kind == .truncated)
    }

    @Test func duplicateSiblingsDisambiguated() async throws {
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [
                .init(name: "Pad", kind: .leaf, hasSubmenu: false),
                .init(name: "Pad", kind: .leaf, hasSubmenu: false),
            ]
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        #expect(root.children.count == 2)
        #expect(root.children[0].name == "Pad[0]")
        #expect(root.children[1].name == "Pad[1]")
    }

    @Test func emptySubmenu() async throws {
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [.init(name: "Empty", kind: .folder, hasSubmenu: true)],
            "Empty": [],
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        #expect(root.children[0].name == "Empty")
        #expect(root.children[0].kind == .folder)
        #expect(root.children[0].children.isEmpty)
    }

    @Test func whitespaceNameSkipped() async throws {
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [
                .init(name: "   ", kind: .leaf, hasSubmenu: false),
                .init(name: "Real", kind: .leaf, hasSubmenu: false),
            ]
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        #expect(root.children.count == 1)
        #expect(root.children[0].name == "Real")
    }

    @Test func submenuProbeTimeout() async throws {
        // Stub returns nil for the submenu path → probeTimeout
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [.init(name: "A", kind: .folder, hasSubmenu: true)]
            // "A" missing — probe returns nil
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        let a = root.children[0]
        #expect(a.kind == .probeTimeout)
    }

    @Test func cycleDetected() async throws {
        // Same visitedHash emitted at different depths
        let probe = PluginPresetProbe(
            menuItemsAt: { segs in
                if segs.isEmpty {
                    return [.init(name: "A", kind: .folder, hasSubmenu: true)]
                } else if segs == ["A"] {
                    return [.init(name: "A", kind: .folder, hasSubmenu: true)]
                } else {
                    return []
                }
            },
            pressMenuItem: { _ in true },
            focusOK: { true },
            mutationSinceLastCheck: { false },
            sleep: { _ in },
            visitedHash: { _ in 42 } // same hash everywhere → cycle on 2nd visit
        )
        let (_, cycleCount) = try await PluginInspector.enumerateMenuTree(probe: probe)
        #expect(cycleCount >= 1)
    }

    @Test func separatorPreserved() async throws {
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [
                .init(name: "---", kind: .separator, hasSubmenu: false),
                .init(name: "Factory Presets", kind: .folder, hasSubmenu: true),
            ],
            "Factory Presets": [.init(name: "X", kind: .leaf, hasSubmenu: false)],
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        // Separators with real names are preserved per PRD AC-1.1
        let separators = root.children.filter { $0.kind == .separator }
        #expect(separators.count == 1)
    }

    @Test func actionPreserved() async throws {
        let tree: [String: [PluginMenuItemInfo]] = [
            "": [
                .init(name: "Save As Default…", kind: .action, hasSubmenu: false),
                .init(name: "Factory Presets", kind: .folder, hasSubmenu: true),
            ],
            "Factory Presets": [],
        ]
        let (root, _) = try await PluginInspector.enumerateMenuTree(probe: makeProbe(tree: tree))
        let actions = root.children.filter { $0.kind == .action }
        #expect(actions.count == 1)
        #expect(actions[0].name == "Save As Default…")
    }

    @Test func mutationMidScanAborts() async throws {
        let callCount = MutableBox(0)
        let probe = PluginPresetProbe(
            menuItemsAt: { _ in [.init(name: "A", kind: .folder, hasSubmenu: true)] },
            pressMenuItem: { _ in true },
            focusOK: { true },
            mutationSinceLastCheck: { callCount.value += 1; return callCount.value >= 2 },
            sleep: { _ in },
            visitedHash: { $0.joined().hashValue }
        )
        do {
            _ = try await PluginInspector.enumerateMenuTree(probe: probe)
            Issue.record("Expected throw")
        } catch PluginError.menuMutated {
            // expected
        }
    }

    @Test func focusLossAborts() async throws {
        let probe = PluginPresetProbe(
            menuItemsAt: { _ in [] },
            pressMenuItem: { _ in true },
            focusOK: { false },
            mutationSinceLastCheck: { false },
            sleep: { _ in },
            visitedHash: { _ in 0 }
        )
        do {
            _ = try await PluginInspector.enumerateMenuTree(probe: probe)
            Issue.record("Expected throw")
        } catch PluginError.focusLost {
            // expected
        }
    }
}
