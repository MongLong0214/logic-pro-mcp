@preconcurrency import ApplicationServices
import Foundation
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

    @Test("Logic 13 transport evidence follows the toolbar, not the same-named view group")
    func logic13ToolbarTransportActivity() throws {
        let f = Fixture()
        f.builder.setRole(f.bar, kAXToolbarRole as String)
        let playWrapper = f.builder.element(965_708)
        let recordWrapper = f.builder.element(965_709)
        for (wrapper, control) in [(playWrapper, f.play), (recordWrapper, f.record)] {
            f.builder.setRole(wrapper, kAXGroupRole as String)
            f.builder.setChildren(wrapper, [control])
        }
        f.builder.setChildren(f.bar, [playWrapper, recordWrapper])

        let viewGroup = f.builder.element(965_710)
        let inspector = f.builder.element(965_711)
        f.builder.setRole(viewGroup, kAXGroupRole as String)
        f.builder.setAttribute(viewGroup, kAXDescriptionAttribute as String, "Control Bar")
        f.builder.setRole(inspector, kAXCheckBoxRole as String)
        f.builder.setAttribute(inspector, kAXDescriptionAttribute as String, "Inspector")
        f.builder.setChildren(inspector, [])
        f.builder.setChildren(viewGroup, [inspector])
        f.builder.setChildren(f.window, [viewGroup, f.bar])

        let observed = try #require(try AXLogicProElements.observedTransportActivity(
            in: f.window, runtime: f.runtime, checking: {}))
        #expect(CFEqual(observed.controlBar, f.bar))
        #expect(CFEqual(observed.play, f.play) && CFEqual(observed.record, f.record))
        #expect(!observed.isPlaying && !observed.isRecording)
    }

    @Test("a group that becomes a competing bar during the complete census is not an earlier absence")
    func descriptionChangedDuringCensusRefuses() throws {
        let f = Fixture()
        let competitor = f.builder.element(965_706)
        let later = f.builder.element(965_707)
        f.builder.setRole(competitor, kAXGroupRole as String)
        f.builder.setAttribute(competitor, kAXDescriptionAttribute as String, "Other group")
        f.builder.setChildren(competitor, [f.play, f.record])
        f.builder.setRole(later, kAXGroupRole as String)
        f.builder.setChildren(later, [])
        f.builder.setChildren(f.window, [f.bar, competitor, later])
        let base = f.runtime.ax
        let runtime = AXHelpers.Runtime(axApp: base.axApp, attributeValue: base.attributeValue,
            attributeIsSettable: base.attributeIsSettable, setAttributeValue: base.setAttributeValue,
            children: base.children, performAction: base.performAction, childCount: base.childCount,
            childrenResult: base.childrenResult,
            attributeValueResult: { element, attribute in
                if CFEqual(element, later), attribute == kAXRoleAttribute as String {
                    f.builder.setAttribute(competitor, kAXDescriptionAttribute as String, "Control Bar")
                }
                return base.attributeValueResult?(element, attribute) ?? .success(base.attributeValue(element, attribute))
            },
            attributeValuesResult: { node, attributes in
                if CFEqual(node, later) {
                    f.builder.setAttribute(competitor, kAXDescriptionAttribute as String, "Control Bar")
                }
                return .success(attributes.map { attribute in
                    if attribute == kAXChildrenAttribute as String { return base.children(node) as NSArray }
                    return base.attributeValue(node, attribute) ?? NSNull()
                })
            })
        #expect(AXLogicProElements.getControlBar(in: f.window, runtime: runtime) == nil,
            "The completed census must not authorize the earlier label of a now-competing bar")
        #expect(f.builder.actionCalls.isEmpty && f.builder.setCalls.isEmpty)
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
