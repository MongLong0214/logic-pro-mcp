import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #608: the FIRST windows read in a fresh process answers `kAXErrorCannotComplete`, and every
/// mutating operation was refused as `blocking_dialog_present` on a screen holding one ordinary
/// window. Measured four trials out of four; the same read succeeds milliseconds later.
///
/// A failed read is not an observation, so re-reading it is not the same as retrying until the answer
/// is convenient — the tests below pin exactly that distinction: a read that SUCCEEDS is never
/// re-read, whatever it says.
@Suite(.serialized)
struct Issue608FirstReadTransientTests {
    /// A windows read that fails with `status` the first `failures` times, then reports `windows`.
    private final class WindowsReader: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingFailures: Int
        private let status: Int32
        private let windows: [AXUIElement]
        private(set) var reads = 0

        init(failures: Int, status: Int32, windows: [AXUIElement]) {
            self.remainingFailures = failures
            self.status = status
            self.windows = windows
        }

        func read() -> Result<AnyObject?, AXHelpers.AXStatusError> {
            lock.lock()
            defer { lock.unlock() }
            reads += 1
            if remainingFailures > 0 {
                remainingFailures -= 1
                return .failure(AXHelpers.AXStatusError(raw: status))
            }
            return .success(windows as AnyObject)
        }
    }

    private func makeRuntime(
        reader: WindowsReader,
        builder: FakeAXRuntimeBuilder,
        app: AXUIElement
    ) -> AXLogicProElements.Runtime {
        builder.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { _, attribute in
                // Only the windows attribute is served here; everything else falls through to the
                // builder's own store, which is what the window fixtures below rely on.
                guard attribute == (kAXWindowsAttribute as String) else { return nil }
                return reader.read()
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )
    }

    /// One plain standard window: nothing blocking.
    private func makeApp() -> (FakeAXRuntimeBuilder, AXUIElement, AXUIElement) {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(0)
        let window = b.element(1)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)
        b.setChildren(window, [])
        return (b, app, window)
    }

    @Test("issue608_a_cannot_complete_read_is_re_read_once_and_does_not_refuse")
    func cannotCompleteIsReReadOnce() {
        let (builder, app, window) = makeApp()
        let reader = WindowsReader(
            failures: 1, status: AXError.cannotComplete.rawValue, windows: [window]
        )
        let runtime = makeRuntime(reader: reader, builder: builder, app: app)

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        #expect(reason == .noBlockingWindow)
        #expect(!reason.isBlocked)
        // Exactly two: the failure and the one re-read. Not a loop.
        #expect(reader.reads == 2)
    }

    @Test("issue608_a_persistent_cannot_complete_still_fails_closed_but_is_named_apart")
    func persistentCannotCompleteFailsClosed() {
        let (builder, app, window) = makeApp()
        let reader = WindowsReader(
            failures: 99, status: AXError.cannotComplete.rawValue, windows: [window]
        )
        let runtime = makeRuntime(reader: reader, builder: builder, app: app)

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        // Fail-closed is preserved — the guard still blocks.
        #expect(reason.isBlocked)
        // But it does not claim a dialog, which is the whole point: an operator told
        // `blocking_dialog_present` goes looking for a modal that is not on screen.
        #expect(!reason.namesAnActualDialog)
        #expect(reason == .appNotYetAddressable)
        #expect(reader.reads == 2)
    }

    /// The guard must not re-read any other failure status — only the one measured to be transient.
    @Test("issue608_other_read_failures_are_not_re_read")
    func otherFailuresAreNotReRead() {
        let (builder, app, window) = makeApp()
        let reader = WindowsReader(
            failures: 1, status: AXError.apiDisabled.rawValue, windows: [window]
        )
        let runtime = makeRuntime(reader: reader, builder: builder, app: app)

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        #expect(reason == .windowsReadFailed)
        #expect(reason.isBlocked)
        #expect(reader.reads == 1)
    }

    /// The distinction that keeps this from being "retry until you like the answer": a read that
    /// SUCCEEDS and finds a dialog is never re-read, however inconvenient its answer.
    @Test("issue608_a_successful_read_that_finds_a_dialog_is_never_re_read")
    func successfulBlockingReadIsNeverReRead() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(0)
        let dialog = b.element(1)
        b.setAttribute(dialog, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(dialog, kAXTitleAttribute as String, "Save")
        b.setChildren(dialog, [])
        let reader = WindowsReader(failures: 0, status: 0, windows: [dialog])
        let runtime = makeRuntime(reader: reader, builder: b, app: app)

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        #expect(reason == .blockingWindowFound)
        #expect(reason.namesAnActualDialog)
        #expect(reader.reads == 1)
    }
}
