@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #1606: mixer.set_volume spent most of its time in fixed sleeps and in a whole-window header walk.
// These tests pin the replacement: a settle that does not wait for a value that has already
// moved but still waits out a slow one. The header-fader cache that was part of this change is gone:
// every call locates the fader in the current window again.

@Suite("Issue1606 set_volume latency")
struct Issue1606SetVolumeLatencyTests {
    @Test("settle returns at once when the value already moved")
    func settleExitsEarly() {
        var sleeps: [UInt32] = []
        let value = MixerSettle.read(after: 10, sleep: { sleeps.append($0) }, read: { 20 })
        #expect(value == 20)
        // One confirming read a step later, nothing more.
        #expect(sleeps == [2_000])
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
        #expect(sleeps.count == 5)
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

    @Test("settle does not accept a value that passes through and moves on")
    func settleRejectsTransient() {
        var reads = [20.0, 30.0, 30.0]
        let value = MixerSettle.read(after: 10, sleep: { _ in }, read: { reads.count > 1 ? reads.removeFirst() : reads[0] })
        #expect(value == 30)
    }

    @Test("settle accepts a changed value only after a second agreeing read")
    func settleNeedsConfirmingRead() {
        var sleeps = 0
        let value = MixerSettle.read(after: 10, sleep: { _ in sleeps += 1 }, read: { 20 })
        #expect(value == 20)
        #expect(sleeps == 1)
    }

    @Test("settle keeps polling a changing value to the bound, then returns the last read")
    func settleChangingToBound() {
        var n = 0.0
        var slept: UInt32 = 0
        let value = MixerSettle.read(after: 10, step: 2_000, bound: 25_000, sleep: { slept += $0 }, read: { n += 1; return 100 + n })
        #expect(slept <= 27_000)
        #expect(value == 100 + n)
    }

    private final class Scripted: @unchecked Sendable {
        var script: [Double] = []
        var rest: Double
        init(rest: Double) { self.rest = rest }
        func next() -> Double { script.isEmpty ? rest : script.removeFirst() }
    }

    private func runVolume(transient: Bool) throws -> [String: Any] {
        let range = AXValueExtractors.SliderRange(min: 0, max: 200)
        let target = AXValueExtractors.logicMixerFaderContractToRaw(0.5, range: range)
        let start = target - 40
        let b = FakeAXRuntimeBuilder()
        let app = b.element(1_606_100), window = b.element(1_606_101)
        b.setAttribute(app, kAXMainWindowAttribute as String, window)
        let rail = b.element(1_606_110)
        b.setAttribute(rail, kAXRoleAttribute as String, kAXListRole as String)
        b.setAttribute(rail, kAXIdentifierAttribute as String, "Track Headers")
        let header = b.element(1_606_120), slider = b.element(1_606_121)
        b.setAttribute(header, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(slider, kAXRoleAttribute as String, kAXSliderRole as String)
        b.setAttribute(slider, kAXDescriptionAttribute as String, "Volume")
        b.setAttribute(slider, kAXMinValueAttribute as String, 0.0)
        b.setAttribute(slider, kAXMaxValueAttribute as String, 200.0)
        b.setChildren(header, [slider]); b.setChildren(rail, [header]); b.setChildren(window, [rail])
        // The slider reads `start`; after an increment it passes through the target once and, in the
        // transient case, settles ten raw units past it; otherwise it settles on the target.
        let state = Scripted(rest: start)
        let runtime = b.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { element, attribute in
                guard CFEqual(element, slider), attribute == kAXValueAttribute as String else { return nil }
                return .some(NSNumber(value: state.next()) as AnyObject)
            },
            setAttributeHandler: { _, _, _ in true },
            performActionHandler: { element, action in
                if CFEqual(element, slider), action == kAXIncrementAction as String {
                    state.rest = transient ? target + 10 : target
                    state.script = [target]
                }
                return true
            })
        let result = AccessibilityChannel.defaultSetMixerValue(
            params: ["index": "0", "value": "0.5"], target: .volume, runtime: runtime)
        return try #require(try JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
    }

    @Test("a value that settles on the target is State A")
    func settledOnTargetIsA() throws {
        let body = try runVolume(transient: false)
        #expect(body["state"] as? String == "A")
        #expect(body["verified"] as? Bool == true)
    }

    @Test("a value that passes through the target and settles elsewhere is not State A")
    func transientThroughTargetIsNotA() throws {
        let body = try runVolume(transient: true)
        #expect(body["state"] as? String != "A")
        #expect(body["verified"] as? Bool != true)
    }
}
