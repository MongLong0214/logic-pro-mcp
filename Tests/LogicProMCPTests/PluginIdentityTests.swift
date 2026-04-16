import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("PluginInspector — T4 Identity")
struct PluginIdentityTests {
    private func wrapper() -> AXUIElementSendable {
        AXUIElementSendable(AXUIElementCreateSystemWide())
    }

    private func runtime(
        findWindow: @escaping @Sendable (Int) async -> AXUIElementSendable? = { _ in nil },
        identifyPlugin: @escaping @Sendable (AXUIElementSendable) async -> (name: String, bundleID: String, version: String?)? = { _ in nil }
    ) -> PluginWindowRuntime {
        PluginWindowRuntime(
            findWindow: findWindow,
            openWindow: { _ in throw PluginError.openTimeout(trackIndex: 0) },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: identifyPlugin,
            nowMs: { 0 }
        )
    }

    @Test func decodeAUVersionTypical() {
        // 1.3.2 packed as 0x01030002
        #expect(PluginInspector.decodeAUVersion(0x0001_0302) == "1.3.2")
    }

    @Test func decodeAUVersionZeroReturnsNil() {
        #expect(PluginInspector.decodeAUVersion(0) == nil)
    }

    @Test func decodeAUVersionHighMajor() {
        // 256.0.0
        #expect(PluginInspector.decodeAUVersion(0x0100_0000) == "256.0.0")
    }

    @Test func identifyPluginByBundleID() async {
        let win = wrapper()
        let rt = runtime(identifyPlugin: { _ in
            (name: "ES2", bundleID: "com.apple.audio.units.ES2", version: "1.3.2")
        })
        let result = await PluginInspector.identifyPlugin(in: win, runtime: rt)
        #expect(result?.bundleID == "com.apple.audio.units.ES2")
        #expect(result?.name == "ES2")
        #expect(result?.version == "1.3.2")
    }

    @Test func identifyPluginVersionNilTolerated() async {
        let win = wrapper()
        let rt = runtime(identifyPlugin: { _ in
            (name: "ThirdParty", bundleID: "com.example.plugin", version: nil)
        })
        let result = await PluginInspector.identifyPlugin(in: win, runtime: rt)
        #expect(result?.version == nil)
        #expect(result?.bundleID == "com.example.plugin")
    }

    @Test func identifyPluginRegistryFailNilReturn() async {
        let win = wrapper()
        let rt = runtime(identifyPlugin: { _ in nil })
        let result = await PluginInspector.identifyPlugin(in: win, runtime: rt)
        #expect(result == nil)
    }

    @Test func identifyPluginLocaleInvariantByBundleID() async {
        // AXDescription localizes ("알케미" in Korean) but bundle ID is stable
        let win = wrapper()
        let rt = runtime(identifyPlugin: { _ in
            (name: "Alchemy", bundleID: "com.apple.audio.units.Alchemy", version: "1.5.0")
        })
        let result = await PluginInspector.identifyPlugin(in: win, runtime: rt)
        // bundle ID is what we use; name happens to be English here but runtime abstracts AX reads
        #expect(result?.bundleID == "com.apple.audio.units.Alchemy")
    }

    @Test func findPluginWindowFound() async {
        let expected = wrapper()
        let rt = runtime(findWindow: { idx in idx == 0 ? expected : nil })
        let found = await PluginInspector.findPluginWindow(for: 0, runtime: rt)
        #expect(found != nil)
    }

    @Test func findPluginWindowNotFoundReturnsNil() async {
        let rt = runtime(findWindow: { _ in nil })
        let found = await PluginInspector.findPluginWindow(for: 5, runtime: rt)
        #expect(found == nil)
    }
}
