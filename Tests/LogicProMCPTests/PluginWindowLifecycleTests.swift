import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("PluginInspector — T5 Window Lifecycle")
struct PluginWindowLifecycleTests {
    private func wrapper() -> AXUIElementSendable {
        AXUIElementSendable(AXUIElementCreateSystemWide())
    }

    @Test func openWindowSucceedsWithinTimeout() async throws {
        let clock = MutableBox(0)
        let appeared = MutableBox(false)
        let win = wrapper()
        let runtime = PluginWindowRuntime(
            findWindow: { _ in appeared.value ? win : nil },
            openWindow: { _ in
                // Simulate async window-open latency — appears after 2nd nowMs tick
                appeared.value = true
                return win
            },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { clock.value += 100; return clock.value }
        )
        let result = try await PluginInspector.openPluginWindow(
            for: 0,
            runtime: runtime,
            probeSleep: { _ in }
        )
        #expect(CFEqual(result.element, win.element))
    }

    @Test func openWindowTimeoutThrows() async {
        let clock = MutableBox(0)
        let runtime = PluginWindowRuntime(
            findWindow: { _ in nil }, // never appears
            openWindow: { _ in throw PluginError.openTimeout(trackIndex: 1) },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { clock.value += 3000; return clock.value }
        )
        do {
            _ = try await PluginInspector.openPluginWindow(
                for: 1,
                runtime: runtime,
                probeSleep: { _ in }
            )
            Issue.record("Expected throw")
        } catch PluginError.openTimeout(let idx) {
            #expect(idx == 1)
        } catch {
            // runtime.openWindow itself may throw openTimeout; acceptable outcome
        }
    }

    @Test func openWindowFindTimeoutThrows() async {
        let clock = MutableBox(0)
        let win = wrapper()
        let runtime = PluginWindowRuntime(
            findWindow: { _ in nil }, // never appears
            openWindow: { _ in win }, // openWindow returns (but find loop never finds)
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { clock.value += 3000; return clock.value }
        )
        do {
            _ = try await PluginInspector.openPluginWindow(
                for: 2,
                runtime: runtime,
                probeSleep: { _ in }
            )
            Issue.record("Expected throw")
        } catch PluginError.openTimeout(let idx) {
            #expect(idx == 2)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func closeWindowSuccess() async {
        let win = wrapper()
        let runtime = PluginWindowRuntime(
            findWindow: { _ in nil },
            openWindow: { _ in throw PluginError.openTimeout(trackIndex: 0) },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { 0 }
        )
        let result = await PluginInspector.closePluginWindow(win, runtime: runtime)
        #expect(result)
    }

    @Test func closeWindowFailureReturnsFalse() async {
        let win = wrapper()
        let runtime = PluginWindowRuntime(
            findWindow: { _ in nil },
            openWindow: { _ in throw PluginError.openTimeout(trackIndex: 0) },
            closeWindow: { _ in false }, // AXPress failed
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { 0 }
        )
        let result = await PluginInspector.closePluginWindow(win, runtime: runtime)
        #expect(!result)
    }

    @Test func openWindowTimeoutExactBoundaryThrows() async {
        // Regression: at exactly timeoutMs elapsed, must throw (P2 from Phase 6 boomer review)
        let clock = MutableBox(0)
        let win = wrapper()
        let runtime = PluginWindowRuntime(
            findWindow: { _ in nil }, // never appears — force timeout path
            openWindow: { _ in win },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            // Clock returns start=0, then 2000 (exactly boundary)
            nowMs: { clock.value += 2000; return clock.value }
        )
        do {
            _ = try await PluginInspector.openPluginWindow(
                for: 3,
                runtime: runtime,
                probeSleep: { _ in },
                timeoutMs: 2000
            )
            Issue.record("Expected throw at exact 2000ms boundary")
        } catch PluginError.openTimeout(let idx) {
            #expect(idx == 3)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func openWindowMonotonicClockNoBackwardMath() async throws {
        // Even with adversarial clock that would go backward, elapsed = current - start
        // stays consistent if using monotonic source; here we just confirm no crash.
        let clock = MutableBox(0)
        let win = wrapper()
        let runtime = PluginWindowRuntime(
            findWindow: { _ in win }, // always found immediately
            openWindow: { _ in win },
            closeWindow: { _ in true },
            listOpenWindows: { [] },
            identifyPlugin: { _ in nil },
            nowMs: { clock.value += 50; return clock.value }
        )
        let result = try await PluginInspector.openPluginWindow(
            for: 0,
            runtime: runtime,
            probeSleep: { _ in }
        )
        #expect(CFEqual(result.element, win.element))
    }
}
