@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// A plug-in window Logic has only just opened is not instantly readable. Its AXTable can be present
/// before the rows that make it Controls-shaped. `prepareView` used to refuse
/// `entry_view_not_confirmed` on the first such read, without waiting, although a view switch
/// already waits for its structure. These doubles model a non-instant window.
@Suite("Plug-in window entry view settling")
struct PluginWindowEntryViewSettlingTests {
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private struct Window {
        let element: AXUIElement
        let runtime: AXHelpers.Runtime
        let reads: Box<Int>
    }

    /// One window holding one AXTable. For the first `unsettledReads` reads of the window the table
    /// has no row (present, unconfirmed). `nil` means it never settles. `unreadableAfter` makes
    /// every window read fail from that read on.
    private func window(unsettledReads: Int?, unreadableAfter: Int? = nil) -> Window {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(1_000)
        let window = builder.element(1_001)
        let table = builder.element(1_002)
        let row = builder.element(1_003)
        let cell = builder.element(1_004)
        let label = builder.element(1_005)
        let checkbox = builder.element(1_006)
        let reads = Box(0)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(row, kAXRowRole as String)
        builder.setRole(cell, kAXCellRole as String)
        builder.setRole(label, kAXStaticTextRole as String)
        builder.setRole(checkbox, kAXCheckBoxRole as String)
        builder.setAttribute(label, kAXValueAttribute as String, "Limiter On")
        builder.setAttribute(checkbox, kAXValueAttribute as String, false)
        builder.setChildren(cell, [label, checkbox])
        builder.setChildren(row, [cell])
        builder.setChildren(window, [table])
        builder.setChildren(table, [])
        builder.setAttribute(table, kAXRowsAttribute as String, [AXUIElement]())
        let failure = AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        let runtime = builder.makeAXRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                reads.value += 1
                if let unreadableAfter, reads.value > unreadableAfter { return .failure(failure) }
                if let unsettledReads, reads.value > unsettledReads {
                    builder.setChildren(table, [row])
                    builder.setAttribute(table, kAXRowsAttribute as String, [row])
                }
                return nil
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
        return Window(element: window, runtime: runtime, reads: reads)
    }

    private func isReady(_ result: ControlsViewBooleanParameterWriter.ViewPreparationResult) -> Bool {
        if case .ready = result { return true }
        return false
    }

    @Test("a table that settles after a few reads is waited for, not refused")
    func settlingTableIsWaitedFor() {
        let w = window(unsettledReads: 3)
        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls, in: w.element, confirmationTimeout: 3.0, runtime: w.runtime)
        #expect(isReady(result))
        #expect(w.reads.value > 3)
    }

    @Test("a table that never settles is refused as entry_view_not_confirmed after the bound")
    func neverSettlingTableIsRefusedNamed() {
        let w = window(unsettledReads: nil)
        let started = Date()
        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls, in: w.element, confirmationTimeout: 0.3, runtime: w.runtime)
        var named = false
        if case .refused(.entryViewNotConfirmed, restoration: nil) = result { named = true }
        #expect(named)
        #expect(Date().timeIntervalSince(started) >= 0.25)
        #expect(w.reads.value > 2)
    }

    @Test("an unreadable window is refused, never read as confirmed")
    func unreadableWindowIsNeverConfirmed() {
        let w = window(unsettledReads: 0, unreadableAfter: 0)
        let result = ControlsViewBooleanParameterWriter.prepareView(
            .controls, in: w.element, confirmationTimeout: 0.3, runtime: w.runtime)
        #expect(!isReady(result))
        guard case let .refused(failure, restoration: nil) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.responseDiagnostics["plugin_view_switch_phase"] as? String != nil)
    }
}
