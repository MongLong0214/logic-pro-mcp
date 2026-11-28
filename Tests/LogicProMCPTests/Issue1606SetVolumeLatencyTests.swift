@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1606: mixer.set_volume spent most of its time in fixed sleeps and in a whole-window header walk.
// These tests pin the two replacements: a settle that does not wait for a value that has already
// moved but still waits out a slow one, and a header-fader cache that is only used after it has been
// revalidated against the live tree.

@Suite("Issue1606 set_volume latency")
struct Issue1606SetVolumeLatencyTests {
    @Test("settle returns at once when the value already moved")
    func settleExitsEarly() {
        var sleeps: [UInt32] = []
        let value = MixerSettle.read(after: 10, sleep: { sleeps.append($0) }, read: { 20 })
        #expect(value == 20)
        #expect(sleeps.isEmpty)
    }

    @Test("settle waits for a slow value and stops when it arrives")
    func settleWaitsForSlowValue() {
        var sleeps: [UInt32] = []
        var reads = 0
        let value = MixerSettle.read(after: 10, sleep: { sleeps.append($0) }, read: {
            reads += 1
            return reads < 5 ? 10 : 20
        })
        #expect(value == 20)
        #expect(sleeps.count == 4)
    }

    @Test("settle gives up at the bound and reports the unchanged value")
    func settleStopsAtBound() {
        var slept: UInt32 = 0
        let value = MixerSettle.read(after: 10, step: 2_000, bound: 25_000, sleep: { slept += $0 }, read: { 10 })
        #expect(value == 10)
        #expect(slept >= 25_000 && slept <= 26_000)
    }

    @Test("settle passes a failed read through")
    func settleNilRead() {
        #expect(MixerSettle.read(after: 10, sleep: { _ in }, read: { nil }) == nil)
    }

    private struct Tree {
        let b = FakeAXRuntimeBuilder()
        let window: AXUIElement
        let rail: AXUIElement
        let headers: [AXUIElement]
        let sliders: [AXUIElement]
        let runtime: AXLogicProElements.Runtime

        init(volumeRaw: Double) {
            let app = b.element(1_606_000)
            window = b.element(1_606_001)
            b.setAttribute(app, kAXMainWindowAttribute as String, window)
            rail = b.element(1_606_010)
            b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
            b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
            var hs: [AXUIElement] = [], ss: [AXUIElement] = []
            for i in 0..<2 {
                let header = b.element(1_606_020 + i * 10)
                b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
                let slider = b.element(1_606_021 + i * 10)
                b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
                b.setAttribute(slider, kAXDescriptionAttribute as String, "Volume")
                b.setAttribute(slider, kAXValueAttribute as String, volumeRaw)
                b.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
                b.setAttribute(slider, kAXMaxValueAttribute as String, 200.0)
                b.setChildren(header, [slider])
                hs.append(header); ss.append(slider)
            }
            b.setChildren(rail, hs)
            b.setChildren(window, [rail])
            headers = hs; sliders = ss
            runtime = b.makeLogicRuntime(appElement: app)
        }
    }

    @Test("a revalidated cached fader is returned; a reordered rail drops it")
    func cacheRevalidation() throws {
        let t = Tree(volumeRaw: 100)
        let cache = MixerHeaderFaderCache()
        cache.store(index: 1, header: t.headers[1], slider: t.sliders[1], runtime: t.runtime.ax)
        let hit = cache.revalidated(index: 1, runtime: t.runtime.ax)
        let found = try #require(hit)
        #expect(CFEqual(found, t.sliders[1]))
        #expect(cache.revalidated(index: 0, runtime: t.runtime.ax) == nil)

        t.b.setChildren(t.rail, [t.headers[1], t.headers[0]])
        #expect(cache.revalidated(index: 1, runtime: t.runtime.ax) == nil)
        // A failed revalidation forgets the entry rather than keeping it for the next call.
        t.b.setChildren(t.rail, t.headers)
        #expect(cache.revalidated(index: 1, runtime: t.runtime.ax) == nil)
    }

    @Test("a slider that left its header, or lost its volume identity, is refused")
    func cacheRefusesChangedSlider() {
        let t = Tree(volumeRaw: 100)
        let cache = MixerHeaderFaderCache()
        cache.store(index: 0, header: t.headers[0], slider: t.sliders[0], runtime: t.runtime.ax)
        t.b.setAttribute(t.sliders[0], kAXDescriptionAttribute as String, "Pan")
        #expect(cache.revalidated(index: 0, runtime: t.runtime.ax) == nil)

        cache.store(index: 0, header: t.headers[0], slider: t.sliders[0], runtime: t.runtime.ax)
        t.b.setAttribute(t.sliders[0], kAXDescriptionAttribute as String, "Volume")
        t.b.setAttribute(t.sliders[0], kAXParentAttribute as String, t.headers[1])
        #expect(cache.revalidated(index: 0, runtime: t.runtime.ax) == nil)
    }

    @Test("set_volume reuses a revalidated fader, and falls back to the full walk when the rail changed")
    func setVolumeUsesThenDropsCache() throws {
        let raw = AXValueExtractors.logicMixerFaderContractToRaw(
            0.5, range: AXValueExtractors.SliderRange(min: 0, max: 200))
        let t = Tree(volumeRaw: raw)
        let cache = MixerHeaderFaderCache()
        func call() throws -> String {
            let r = AccessibilityChannel.defaultSetMixerValue(
                params: ["index": "1", "value": "0.5"], target: .volume, runtime: t.runtime, headerCache: cache)
            #expect(r.isSuccess)
            let body = try #require(try JSONSerialization.jsonObject(with: Data(r.message.utf8)) as? [String: Any])
            return try #require(body["locate_path"] as? String)
        }
        #expect(try call() == "full_walk")
        #expect(try call() == "revalidated_cache")
        t.b.setChildren(t.rail, [t.headers[1], t.headers[0]])
        #expect(try call() == "full_walk")
    }
}
