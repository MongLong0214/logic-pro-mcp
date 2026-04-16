import Foundation
import Testing
@testable import LogicProMCP

@Suite("PluginInspector — T3 Path Parse/Resolve/Select")
struct PluginInspectorPathTests {
    @Test func parsePathSimple() throws {
        let segs = try PluginInspector.parsePath("A/B/C")
        #expect(segs == ["A", "B", "C"])
    }

    @Test func parsePathEscapedSlash() throws {
        let segs = try PluginInspector.parsePath(#"Bass\/Sub/Synth"#)
        #expect(segs == ["Bass/Sub", "Synth"])
    }

    @Test func parsePathEscapedBackslash() throws {
        let segs = try PluginInspector.parsePath(#"Path\\One/X"#)
        #expect(segs == [#"Path\One"#, "X"])
    }

    @Test func parsePathEmptySegmentThrows() {
        do {
            _ = try PluginInspector.parsePath("A//C")
            Issue.record("Expected invalidPath")
        } catch PluginError.invalidPath {
            // expected
        } catch { Issue.record("Wrong error: \(error)") }
    }

    @Test func parsePathTrailingSlashStripped() throws {
        let segs = try PluginInspector.parsePath("Bass/")
        #expect(segs == ["Bass"])
    }

    @Test func parsePathEmptyReturnsEmpty() throws {
        let segs = try PluginInspector.parsePath("")
        #expect(segs.isEmpty)
    }

    @Test func parsePathSingleSlashReturnsEmpty() throws {
        let segs = try PluginInspector.parsePath("/")
        #expect(segs.isEmpty)
    }

    @Test func encodePathSimple() {
        #expect(PluginInspector.encodePath(["A", "B"]) == "A/B")
    }

    @Test func encodePathEscapesSlashInSegment() {
        #expect(PluginInspector.encodePath(["Bass/Sub", "Synth"]) == #"Bass\/Sub/Synth"#)
    }

    @Test func encodePathEscapesBackslash() {
        #expect(PluginInspector.encodePath([#"Path\One"#, "X"]) == #"Path\\One/X"#)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let original = ["Bass/Sub", #"Weird\Name"#, "Normal"]
        let encoded = PluginInspector.encodePath(original)
        let decoded = try PluginInspector.parsePath(encoded)
        #expect(decoded == original)
    }

    // --- resolveMenuPath ---

    private func fixture() -> PluginPresetNode {
        PluginPresetNode(
            name: "(root)",
            path: "",
            kind: .folder,
            children: [
                PluginPresetNode(name: "A", path: "A", kind: .folder, children: [
                    PluginPresetNode(name: "A1", path: "A/A1", kind: .leaf, children: []),
                    PluginPresetNode(name: "A2", path: "A/A2", kind: .leaf, children: []),
                ]),
                PluginPresetNode(name: "B", path: "B", kind: .leaf, children: []),
                PluginPresetNode(name: "Synth", path: "Synth", kind: .folder, children: [
                    PluginPresetNode(name: "Pad[0]", path: "Synth/Pad[0]", kind: .leaf, children: []),
                    PluginPresetNode(name: "Pad[1]", path: "Synth/Pad[1]", kind: .leaf, children: []),
                ]),
            ]
        )
    }

    @Test func resolveLeafDepth1() throws {
        let hops = try PluginInspector.resolveMenuPath("B", in: fixture())
        #expect(hops?.count == 1)
        #expect(hops?[0].name == "B")
    }

    @Test func resolveLeafDepth2() throws {
        let hops = try PluginInspector.resolveMenuPath("A/A1", in: fixture())
        #expect(hops?.count == 2)
        #expect(hops?[0].name == "A")
        #expect(hops?[1].name == "A1")
    }

    @Test func resolveMissingReturnsNil() throws {
        let hops = try PluginInspector.resolveMenuPath("A/Nope", in: fixture())
        #expect(hops == nil)
    }

    @Test func resolveDisambiguatedDuplicate() throws {
        let hops = try PluginInspector.resolveMenuPath("Synth/Pad[1]", in: fixture())
        #expect(hops?.count == 2)
        #expect(hops?[1].name == "Pad[1]")
    }

    @Test func resolveEmptyReturnsNil() throws {
        let hops = try PluginInspector.resolveMenuPath("", in: fixture())
        #expect(hops == nil)
    }

    @Test func resolveNegativeDisambigIndexReturnsNil() throws {
        // Regression: negative index must not crash (P0 from Phase 6 boomer review)
        let hops = try PluginInspector.resolveMenuPath("Synth/Pad[-1]", in: fixture())
        #expect(hops == nil)
    }

    @Test func parsePathEscapedTrailingSlashPreserved() throws {
        // Regression: input `"Bass\/"` must preserve the literal `/` in the segment
        let segs = try PluginInspector.parsePath(#"Bass\/"#)
        #expect(segs == ["Bass/"])
    }

    // --- selectMenuPath ---

    @Test func selectCallsPressInOrder() async throws {
        let called = MutableBox<[[String]]>([])
        let probe = PluginPresetProbe(
            menuItemsAt: { _ in [] },
            pressMenuItem: { segs in called.value.append(segs); return true },
            focusOK: { true },
            mutationSinceLastCheck: { false },
            sleep: { _ in },
            visitedHash: { _ in 0 }
        )
        let hops = [
            MenuHop(indexInParent: 0, name: "A"),
            MenuHop(indexInParent: 1, name: "A2"),
        ]
        try await PluginInspector.selectMenuPath(hops, probe: probe)
        #expect(called.value.count == 2)
        #expect(called.value[0] == ["A"])
        #expect(called.value[1] == ["A", "A2"])
    }

    @Test func selectAbortsOnPressFailure() async {
        let callIdx = MutableBox(0)
        let probe = PluginPresetProbe(
            menuItemsAt: { _ in [] },
            pressMenuItem: { _ in
                callIdx.value += 1
                return callIdx.value < 2 // 2nd press fails
            },
            focusOK: { true },
            mutationSinceLastCheck: { false },
            sleep: { _ in },
            visitedHash: { _ in 0 }
        )
        let hops = [
            MenuHop(indexInParent: 0, name: "A"),
            MenuHop(indexInParent: 0, name: "B"),
        ]
        do {
            try await PluginInspector.selectMenuPath(hops, probe: probe)
            Issue.record("Expected throw")
        } catch PluginError.pressFailedAt(let path) {
            #expect(path == ["A", "B"])
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func selectSettleDelayApplied() async throws {
        let sleepCount = MutableBox(0)
        let probe = PluginPresetProbe(
            menuItemsAt: { _ in [] },
            pressMenuItem: { _ in true },
            focusOK: { true },
            mutationSinceLastCheck: { false },
            sleep: { _ in sleepCount.value += 1 },
            visitedHash: { _ in 0 }
        )
        let hops = [
            MenuHop(indexInParent: 0, name: "A"),
            MenuHop(indexInParent: 0, name: "B"),
            MenuHop(indexInParent: 0, name: "C"),
        ]
        try await PluginInspector.selectMenuPath(hops, probe: probe)
        // Sleep called between hops, not after final
        #expect(sleepCount.value == 2)
    }
}
