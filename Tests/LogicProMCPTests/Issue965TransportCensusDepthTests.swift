@preconcurrency import ApplicationServices
import Testing
@testable import LogicProMCP

@Suite("#965 transport evidence beside deep Arrange/Mixer trees")
struct Issue965TransportCensusDepthTests {
    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let app: AXUIElement
        let window: AXUIElement
        let bar: AXUIElement
        let play: AXUIElement
        let record: AXUIElement

        init() {
            app = builder.element(965_700)
            window = builder.element(965_701)
            bar = builder.element(965_702)
            play = builder.element(965_703)
            record = builder.element(965_704)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            builder.setRole(bar, kAXGroupRole as String)
            builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
            for (control, label) in [(play, "Play"), (record, "Record")] {
                builder.setRole(control, kAXCheckBoxRole as String)
                builder.setAttribute(control, kAXDescriptionAttribute as String, label)
                builder.setAttribute(control, kAXValueAttribute as String, 0)
                builder.setChildren(control, [])
            }
            builder.setChildren(bar, [play, record])
            builder.setChildren(window, [bar])
        }

        func nested(_ depth: Int, children: [AXUIElement], offset: Int = 0) -> AXUIElement {
            var contents = children
            for index in 0..<depth {
                let group = builder.element(965_800 + offset + index)
                builder.setRole(group, kAXGroupRole as String)
                builder.setChildren(group, contents)
                contents = [group]
            }
            return contents[0]
        }

        var runtime: AXLogicProElements.Runtime {
            builder.makeLogicRuntime(appElement: app,
                setAttributeHandler: { _, _, _ in Issue.record("transport evidence must not write"); return false },
                performActionHandler: { _, _ in Issue.record("transport evidence must not act"); return false })
        }
    }

    @Test("an unrelated deep tree must not conceal an observed stopped transport")
    func stoppedTransportBesideDeepMixerTree() throws {
        let f = Fixture()
        let deepTree = f.nested(12, children: [])
        f.builder.setChildren(f.window, [f.bar, deepTree])
        let result = try AXLogicProElements.observedTransportActivity(
            in: f.window, runtime: f.runtime, checking: {})
        let observed = try #require(result)
        #expect(!observed.isPlaying && !observed.isRecording)
        #expect(CFEqual(observed.controlBar, f.bar))
        #expect(CFEqual(observed.play, f.play) && CFEqual(observed.record, f.record))
    }

    @Test("a competing control bar beyond the old depth still prevents authority")
    func deepCompetingBarIsAmbiguous() throws {
        let f = Fixture()
        let competitor = f.builder.element(965_705)
        f.builder.setRole(competitor, kAXGroupRole as String)
        f.builder.setAttribute(competitor, kAXDescriptionAttribute as String, "Control Bar")
        f.builder.setChildren(competitor, [f.play, f.record])
        f.builder.setChildren(f.window, [f.bar, f.nested(12, children: [competitor])])
        #expect(try AXLogicProElements.observedTransportActivity(
            in: f.window, runtime: f.runtime, checking: {}) == nil)
    }

    @Test("an unvisited subtree remains a refusal, not proof of absence")
    func truncatedWindowStillRefuses() throws {
        let f = Fixture()
        f.builder.setChildren(f.window, [f.bar, f.nested(34, children: [])])
        #expect(try AXLogicProElements.observedTransportActivity(
            in: f.window, runtime: f.runtime, checking: {}) == nil)
    }

    @Test("the narrower transport-control bound is not relaxed")
    func truncatedBarStillRefuses() throws {
        let f = Fixture()
        f.builder.setChildren(f.bar, [f.nested(5, children: [f.play, f.record])])
        #expect(try AXLogicProElements.observedTransportActivity(
            in: f.window, runtime: f.runtime, checking: {}) == nil)
    }
}
