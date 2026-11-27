@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #1565: the poller's periodic transport read reuses its located control bar instead of walking
/// the whole window (Logic 13's Browser included) on every tick. A client read or write
/// verification keeps the complete census.
@Suite("Issue1565 periodic control bar read", .serialized)
struct Issue1565PeriodicControlBarTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        func reset() { lock.withLock { value = 0 } }
        var count: Int { lock.withLock { value } }
    }

    private struct Fixture {
        let builder = FakeAXRuntimeBuilder()
        let counter = Counter()
        let app: AXUIElement
        let window: AXUIElement
        let bar: AXUIElement

        init() {
            app = builder.element(156_500)
            window = builder.element(156_501)
            bar = builder.element(156_502)
            builder.setRole(window, kAXWindowRole as String)
            builder.setAttribute(app, kAXMainWindowAttribute as String, window)
            Self.makeBar(builder, bar, ids: 156_510)
            // An unrelated deep subtree standing in for the Browser.
            var browser: [AXUIElement] = []
            for index in 0..<20 {
                let row = builder.element(156_600 + index)
                builder.setRole(row, kAXGroupRole as String)
                builder.setChildren(row, [])
                browser.append(row)
            }
            let browserRoot = builder.element(156_599)
            builder.setRole(browserRoot, kAXGroupRole as String)
            builder.setChildren(browserRoot, browser)
            builder.setChildren(window, [bar, browserRoot])
        }

        static func makeBar(_ builder: FakeAXRuntimeBuilder, _ bar: AXUIElement, ids: Int) {
            builder.setRole(bar, kAXGroupRole as String)
            builder.setAttribute(bar, kAXDescriptionAttribute as String, "Control Bar")
            var controls: [AXUIElement] = []
            for (offset, label) in ["Play", "Record"].enumerated() {
                let control = builder.element(ids + offset)
                builder.setRole(control, kAXCheckBoxRole as String)
                builder.setAttribute(control, kAXDescriptionAttribute as String, label)
                builder.setAttribute(control, kAXValueAttribute as String, 0)
                builder.setChildren(control, [])
                controls.append(control)
            }
            builder.setChildren(bar, controls)
        }

        var runtime: AXLogicProElements.Runtime {
            let counter = counter
            return builder.makeLogicRuntime(
                appElement: app,
                childrenHandler: { _ in counter.bump(); return nil },
                childrenResultHandler: { _ in counter.bump(); return nil },
                setAttributeHandler: { _, _, _ in false },
                performActionHandler: { _, _ in false })
        }
    }

    @Test("a tick reads only the cached control bar and makes no AXChildren call")
    func tickUsesCachedBar() throws {
        let f = Fixture()
        let cache = AXLogicProElements.ControlBarCache()
        let first = try #require(AXLogicProElements.periodicControlBar(
            in: f.window, runtime: f.runtime.ax, cache: cache))
        #expect(CFEqual(first, f.bar))
        #expect(f.counter.count > 0)

        f.counter.reset()
        for _ in 0..<5 {
            let again = try #require(AXLogicProElements.periodicControlBar(
                in: f.window, runtime: f.runtime.ax, cache: cache))
            #expect(CFEqual(again, f.bar))
        }
        #expect(f.counter.count == 0)
    }

    @Test("an invalid cache triggers exactly one re-locate")
    func invalidCacheRelocatesOnce() throws {
        let f = Fixture()
        let cache = AXLogicProElements.ControlBarCache()
        _ = AXLogicProElements.periodicControlBar(in: f.window, runtime: f.runtime.ax, cache: cache)

        // Logic rebuilds the bar: the old element stops being the labelled bar.
        let replacement = f.builder.element(156_503)
        Fixture.makeBar(f.builder, replacement, ids: 156_520)
        f.builder.setAttribute(f.bar, kAXDescriptionAttribute as String, "Gone")
        f.builder.setChildren(f.window, [replacement])

        f.counter.reset()
        let relocated = try #require(AXLogicProElements.periodicControlBar(
            in: f.window, runtime: f.runtime.ax, cache: cache))
        #expect(CFEqual(relocated, replacement))
        let relocateCost = f.counter.count
        #expect(relocateCost > 0)

        f.counter.reset()
        let next = try #require(AXLogicProElements.periodicControlBar(
            in: f.window, runtime: f.runtime.ax, cache: cache))
        #expect(CFEqual(next, replacement))
        #expect(f.counter.count == 0)
    }

    @Test("a different window re-locates")
    func windowChangeRelocates() throws {
        let f = Fixture()
        let cache = AXLogicProElements.ControlBarCache()
        _ = AXLogicProElements.periodicControlBar(in: f.window, runtime: f.runtime.ax, cache: cache)

        let other = f.builder.element(156_530)
        let otherBar = f.builder.element(156_531)
        f.builder.setRole(other, kAXWindowRole as String)
        Fixture.makeBar(f.builder, otherBar, ids: 156_540)
        f.builder.setChildren(other, [otherBar])
        f.counter.reset()
        let found = try #require(AXLogicProElements.periodicControlBar(
            in: other, runtime: f.runtime.ax, cache: cache))
        #expect(CFEqual(found, otherBar))
        #expect(f.counter.count > 0)
    }

    @Test("the complete census still runs for a non-periodic read, and is skipped on a periodic tick")
    func writeVerificationKeepsCompleteCensus() throws {
        let f = Fixture()
        AXLogicProElements.sharedControlBarCache.clear()
        defer { AXLogicProElements.sharedControlBarCache.clear() }

        _ = try #require(AXLogicProElements.getControlBar(runtime: f.runtime))
        let censusCost = f.counter.count
        #expect(censusCost > 0)

        // Two non-periodic reads each pay the full census.
        f.counter.reset()
        _ = try #require(AXLogicProElements.getControlBar(runtime: f.runtime))
        #expect(f.counter.count >= censusCost)

        // A periodic tick locates once, then reads only the cached bar.
        AXLogicProElements.PeriodicRead.$active.withValue(true) {
            f.counter.reset()
            _ = AXLogicProElements.getControlBar(runtime: f.runtime)
            let firstTick = f.counter.count
            #expect(firstTick > 0)
            let windowReadCost = firstTick - censusCost
            f.counter.reset()
            _ = AXLogicProElements.getControlBar(runtime: f.runtime)
            #expect(f.counter.count <= max(windowReadCost, 0))
            #expect(f.counter.count < censusCost)
        }
    }
}

/// #1565 (jasonwallis777, 3.19.0): the first two transport reads answered, then every later one
/// timed out. A read whose deadline fired kept walking Logic's window on the AX actor, so every
/// later read queued behind it. The abandoned walk must stop, and release the actor.
@Suite("Issue1565 abandoned read releases the AX actor", .serialized)
struct Issue1565AbandonedReadTests {
    private final class Slow: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set(_ value: Bool) { lock.withLock { on = value } }
        var isOn: Bool { lock.withLock { on } }
    }

    /// Stands in for AccessibilityChannel: one serial actor running a synchronous AX walk.
    private actor FakeAXActor {
        let runtime: AXHelpers.Runtime
        init(runtime: AXHelpers.Runtime) { self.runtime = runtime }
        func read(_ root: AXUIElement) -> Bool {
            if case .success = AXLogicProElements.completeControlBarCensus(
                of: root, matching: [kAXGroupRole as String], terminalRoles: [kAXButtonRole as String],
                maxDepth: 32, runtime: runtime, permittingRead: { !Task.isCancelled }) { return true }
            return false
        }
    }

    @Test("a third and a tenth read still succeed after two reads whose walk hangs past the deadline")
    func laterReadsSucceedAfterTwoHungReads() async throws {
        let builder = FakeAXRuntimeBuilder()
        // The hung window: 2000 nodes, each AX read of which takes 20 ms (about 40 s in all).
        let hungRoot = builder.element(156_700)
        var leaves: [AXUIElement] = []
        for index in 0..<2000 {
            let leaf = builder.element(156_800 + index)
            builder.setRole(leaf, kAXStaticTextRole as String)
            builder.setChildren(leaf, [])
            leaves.append(leaf)
        }
        builder.setRole(hungRoot, kAXGroupRole as String)
        builder.setChildren(hungRoot, leaves)
        // The healthy window the later reads walk.
        let goodRoot = builder.element(156_701)
        builder.setRole(goodRoot, kAXGroupRole as String)
        builder.setChildren(goodRoot, [])
        let isHung: @Sendable (AXUIElement) -> Bool = { builder.elementID($0) >= 156_800 || builder.elementID($0) == 156_700 }
        let runtime = builder.makeAXRuntime(
            attributeValueHandler: { element, _ in
                if isHung(element) { Thread.sleep(forTimeInterval: 0.02) }
                return nil
            },
            childrenHandler: { element in
                if isHung(element) { Thread.sleep(forTimeInterval: 0.02) }
                return nil
            },
            childrenResultHandler: { element in
                if isHung(element) { Thread.sleep(forTimeInterval: 0.02) }
                return nil
            },
            setAttributeHandler: { _, _, _ in false },
            performActionHandler: { _, _ in false })
        let ax = FakeAXActor(runtime: runtime)

        func read(_ root: AXUIElement) async throws -> [String: Any] {
            let result = try await LogicProServer.runResourceReadWithDeadline(
                uri: "logic://transport/state", deadlineOverride: 0.3
            ) {
                let ok = await ax.read(root)
                return ReadResource.Result(contents: [.text(
                    "{\"ok\":\(ok)}", uri: "logic://transport/state", mimeType: "application/json")])
            }
            let text = try #require(result.contents.first?.text)
            return try #require(sharedJSONObject(text))
        }

        for _ in 1...2 {
            let body = try await read(hungRoot)
            #expect(body["error"] as? String == "operation_timeout")
        }
        for _ in 3...10 {
            let body = try await read(goodRoot)
            #expect(body["error"] == nil)
            #expect(try #require(body["ok"] as? Bool))
        }
    }
}
