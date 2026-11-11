@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// New explicit-window API contract tests: no original-head behavioral RED is claimed.
/// Apply/run only after the extraction/wiring repair; the old Atlas Control Bar route calls
/// production AX even when given this fake runtime, so it MUST NOT be executed as a BEFORE.
@Suite("Issue290AtlasControlBarScope")
struct Issue290AtlasControlBarScopeTests {
    private func group(_ builder: FakeAXRuntimeBuilder, id: Int,
                       controls: Bool, description: String = "Control Bar") -> AXUIElement {
        let bar = builder.element(id)
        builder.setAttribute(bar, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(bar, kAXDescriptionAttribute as String, description)
        if controls {
            let play = builder.element(id + 100)
            builder.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
            builder.setAttribute(play, kAXDescriptionAttribute as String, "Play")
            builder.setChildren(bar, [play])
        }
        return bar
    }

    @Test func atlasControlBarStaysInsideSuppliedWindowAndRuntime() throws {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(800)
        let supplied = b.element(801)
        let discoverable = b.element(802)
        let target = group(b, id: 803, controls: true)
        let decoy = group(b, id: 804, controls: true)
        b.setAttribute(app, kAXWindowsAttribute as String, [discoverable, supplied] as NSArray)
        b.setAttribute(app, kAXMainWindowAttribute as String, discoverable)
        b.setAttribute(supplied, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(discoverable, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setChildren(supplied, [target])
        b.setChildren(discoverable, [decoy])
        let elements = b.makeLogicRuntime(appElement: app)
        let global = try #require(AXLogicProElements.getControlBar(runtime: elements))
        #expect(CFEqual(global, decoy))
        let scoped = try #require(AtlasCapture.resolveScope("Control Bar", in: supplied, runtime: elements.ax))
        #expect(CFEqual(scoped, target))
        #expect(!CFEqual(scoped, decoy))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func explicitWindowRetainsCheckboxDiscriminationAndExactDescription() throws {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(850)
        let empty = group(b, id: 851, controls: false)
        let falseFriend = group(b, id: 852, controls: true, description: "Hide Control Bar")
        let target = group(b, id: 853, controls: true)
        b.setChildren(window, [empty, falseFriend, target])
        let scoped = try #require(AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()))
        #expect(CFEqual(scoped, target))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func logic13ToolbarOutranksTheSameNamedViewToggleGroup() throws {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(855)
        let toolbar = b.element(856)
        b.setAttribute(toolbar, kAXRoleAttribute as String, kAXToolbarRole as String)
        b.setAttribute(toolbar, kAXDescriptionAttribute as String, "Control Bar")
        let playWrapper = b.element(857)
        b.setAttribute(playWrapper, kAXRoleAttribute as String, kAXGroupRole as String)
        let play = b.element(858)
        b.setAttribute(play, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(play, kAXDescriptionAttribute as String, "Play")
        b.setChildren(playWrapper, [play])
        b.setChildren(toolbar, [playWrapper])

        let viewToggles = group(b, id: 859, controls: false)
        let inspector = b.element(959)
        b.setAttribute(inspector, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(inspector, kAXDescriptionAttribute as String, "Inspector")
        b.setChildren(viewToggles, [inspector])
        b.setChildren(window, [viewToggles, toolbar])

        let scoped = try #require(
            AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()))
        #expect(CFEqual(scoped, toolbar))
        #expect(!CFEqual(scoped, viewToggles))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func unrelatedButtonChildrenFailureDoesNotHideControlBar() throws {
        final class Reads: @unchecked Sendable { var batches = 0 }
        let b = FakeAXRuntimeBuilder()
        let reads = Reads()
        let window = b.element(860)
        let target = group(b, id: 861, controls: true)
        let harmless = b.element(862)
        b.setAttribute(harmless, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setChildren(harmless, [])
        b.setChildren(window, [target, harmless])
        let base = b.makeAXRuntime()
        let runtime = AXHelpers.Runtime(
            axApp: base.axApp,
            attributeValue: base.attributeValue,
            attributeIsSettable: base.attributeIsSettable,
            setAttributeValue: base.setAttributeValue,
            children: base.children,
            performAction: base.performAction,
            childCount: base.childCount,
            actionNames: base.actionNames,
            actionNamesResult: base.actionNamesResult,
            childrenResult: { element in
                if CFEqual(element, harmless) {
                    return .failure(.init(raw: AXError.failure.rawValue))
                }
                return base.childrenResult?(element) ?? .success(base.children(element))
            },
            attributeValueResult: base.attributeValueResult,
            performActionResult: base.performActionResult,
            elementAtPosition: base.elementAtPosition,
            attributeValuesResult: { _, _ in
                reads.batches += 1
                return .failure(.init(raw: AXError.failure.rawValue))
            }
        )

        let scoped = try #require(AXLogicProElements.getControlBar(in: window, runtime: runtime))
        #expect(CFEqual(scoped, target))
        #expect(reads.batches > 0)
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func explicitWindowStillRefusesIndistinguishableBars() {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(880)
        b.setChildren(window, [group(b, id: 881, controls: true), group(b, id: 882, controls: true)])
        #expect(AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()) == nil)
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func unreadContainerChildrenStillRefuseControlBarAuthority() {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(870)
        let target = group(b, id: 871, controls: true)
        let unreadContainer = b.element(872)
        b.setAttribute(unreadContainer, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setChildren(unreadContainer, [])
        b.setChildren(window, [target, unreadContainer])
        let base = b.makeAXRuntime()
        let runtime = AXHelpers.Runtime(
            axApp: base.axApp,
            attributeValue: base.attributeValue,
            attributeIsSettable: base.attributeIsSettable,
            setAttributeValue: base.setAttributeValue,
            children: base.children,
            performAction: base.performAction,
            childCount: base.childCount,
            actionNames: base.actionNames,
            actionNamesResult: base.actionNamesResult,
            childrenResult: { element in
                if CFEqual(element, unreadContainer) {
                    return .failure(.init(raw: AXError.failure.rawValue))
                }
                return base.childrenResult?(element) ?? .success(base.children(element))
            },
            attributeValueResult: base.attributeValueResult,
            performActionResult: base.performActionResult,
            elementAtPosition: base.elementAtPosition,
            attributeValuesResult: { _, _ in
                .failure(.init(raw: AXError.failure.rawValue))
            }
        )

        #expect(AXLogicProElements.getControlBar(in: window, runtime: runtime) == nil)
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }

    @Test func explicitWindowPreservesLoneLabelledWithoutControlsFallback() throws {
        let b = FakeAXRuntimeBuilder()
        let window = b.element(890)
        let lone = group(b, id: 891, controls: false, description: "컨트롤 막대")
        b.setChildren(window, [lone])
        let scoped = try #require(AXLogicProElements.getControlBar(in: window, runtime: b.makeAXRuntime()))
        #expect(CFEqual(scoped, lone))
        #expect(b.setCalls.isEmpty)
        #expect(b.actionCalls.isEmpty)
    }
}
