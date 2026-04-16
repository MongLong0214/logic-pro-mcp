import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

@Suite("PluginInspector — T1 Types")
struct PluginInspectorTypesTests {
    @Test func pluginPresetNodeKindRoundTrip() throws {
        let all: [PluginPresetNodeKind] = [.folder, .leaf, .separator, .action, .truncated, .probeTimeout, .cycle]
        for kind in all {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(PluginPresetNodeKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    @Test func pluginPresetNodeCodable() throws {
        let root = PluginPresetNode(
            name: "(root)",
            path: "",
            kind: .folder,
            children: [
                PluginPresetNode(name: "A", path: "A", kind: .folder, children: [
                    PluginPresetNode(name: "A1", path: "A/A1", kind: .leaf, children: []),
                    PluginPresetNode(name: "A2", path: "A/A2", kind: .leaf, children: []),
                ]),
                PluginPresetNode(name: "B", path: "B", kind: .leaf, children: []),
            ]
        )
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(PluginPresetNode.self, from: data)
        #expect(decoded == root)
    }

    @Test func pluginPresetCacheCodable() throws {
        let cache = PluginPresetCache(
            pluginName: "ES2",
            pluginIdentifier: "com.apple.audio.units.ES2",
            pluginVersion: "1.3.2",
            contentHash: "abc123",
            generatedAt: "2026-04-13T00:00:00Z",
            scanDurationMs: 4200,
            measuredSubmenuOpenDelayMs: 300,
            truncatedBranches: 0,
            probeTimeouts: 0,
            cycleCount: 0,
            nodeCount: 10,
            leafCount: 8,
            folderCount: 2,
            root: PluginPresetNode(name: "(root)", path: "", kind: .folder, children: [])
        )
        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(PluginPresetCache.self, from: data)
        #expect(decoded == cache)
        #expect(decoded.schemaVersion == 1)
    }

    @Test func pluginPresetInventoryCodable() throws {
        let entry = PluginPresetCache(
            pluginName: "ES2",
            pluginIdentifier: "com.apple.audio.units.ES2",
            pluginVersion: nil,
            contentHash: "h",
            generatedAt: "t",
            scanDurationMs: 0,
            measuredSubmenuOpenDelayMs: 0,
            truncatedBranches: 0,
            probeTimeouts: 0,
            cycleCount: 0,
            nodeCount: 1,
            leafCount: 0,
            folderCount: 1,
            root: PluginPresetNode(name: "(root)", path: "", kind: .folder, children: [])
        )
        let inv = PluginPresetInventory(
            generatedAt: "2026-04-13T00:00:00Z",
            plugins: ["com.apple.audio.units.ES2": entry]
        )
        let data = try JSONEncoder().encode(inv)
        let decoded = try JSONDecoder().decode(PluginPresetInventory.self, from: data)
        #expect(decoded == inv)
    }

    @Test func schemaVersionFieldDefaults() {
        let inv = PluginPresetInventory(generatedAt: "t", plugins: [:])
        #expect(inv.schemaVersion == 1)
    }

    @Test func axUIElementSendableWraps() {
        let system = AXUIElementCreateSystemWide()
        let wrapper = AXUIElementSendable(system)
        #expect(CFEqual(wrapper.element, system))
    }

    @Test func scannerWindowRecordFields() {
        let system = AXUIElementCreateSystemWide()
        let rec = ScannerWindowRecord(
            cgWindowID: 42,
            bundleID: "com.apple.test",
            windowTitle: "Title",
            element: AXUIElementSendable(system)
        )
        #expect(rec.cgWindowID == 42)
        #expect(rec.bundleID == "com.apple.test")
        #expect(rec.windowTitle == "Title")
    }

    @Test func pluginPresetProbeClosuresInvoked() async {
        let menuCalled = MutableBox(false)
        let focusCalled = MutableBox(false)
        let probe = PluginPresetProbe(
            menuItemsAt: { _ in menuCalled.value = true; return [] },
            pressMenuItem: { _ in true },
            focusOK: { focusCalled.value = true; return true },
            mutationSinceLastCheck: { false },
            sleep: { _ in },
            visitedHash: { $0.joined().hashValue }
        )
        _ = await probe.menuItemsAt([])
        _ = await probe.focusOK()
        #expect(menuCalled.value)
        #expect(focusCalled.value)
    }

    @Test func pluginWindowRuntimeNowMsMonotonic() {
        let counter = MutableBox(0)
        let runtime = PluginWindowRuntime(
            findWindow: { _ in nil },
            openWindow: { _ in throw PluginError.openTimeout(trackIndex: 0) },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { counter.value += 1; return counter.value * 100 }
        )
        let t1 = runtime.nowMs()
        let t2 = runtime.nowMs()
        #expect(t2 > t1)
    }
}
