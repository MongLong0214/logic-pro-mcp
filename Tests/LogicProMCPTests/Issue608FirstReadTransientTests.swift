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

    /// The hole a reviewer found: nothing covered the retry's SUCCESS path finding a dialog. Every
    /// other test either feeds a plain window on retry or never enters the retry at all, so a
    /// one-line `case .success(.elements): reason = .noBlockingWindow` on the re-read would have left
    /// them all green — and that mutation is precisely "the retry swallowed a modal".
    @Test("issue608_a_dialog_seen_only_on_the_re_read_still_blocks")
    func dialogSeenOnlyOnTheReReadStillBlocks() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(0)
        let dialog = b.element(1)
        b.setAttribute(dialog, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(dialog, kAXTitleAttribute as String, "Save")
        b.setChildren(dialog, [])
        // First read fails with the transient; the SECOND read is the one that sees the modal.
        let reader = WindowsReader(
            failures: 1, status: AXError.cannotComplete.rawValue, windows: [dialog]
        )
        let runtime = makeRuntime(reader: reader, builder: b, app: app)

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        #expect(reason == .blockingWindowFound)
        #expect(reason.isBlocked)
        #expect(reason.namesAnActualDialog)
        #expect(reader.reads == 2)
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

/// #608 follow-up: a window whose children will not read blocks — but nobody saw a dialog.
///
/// `windowHostsBlockingModal` returned a bare Bool, so the fail-closed default for an unreadable
/// child was indistinguishable from an actual modal, and the refusal reported
/// `refusal_names_an_actual_dialog: true` for a read that did not happen. That is this issue's own
/// defect wearing a different hat.
@Suite(.serialized)
struct Issue608UnreadableIsNotADialogTests {
    private final class Reader: @unchecked Sendable {
        private let windows: [AXUIElement]
        init(windows: [AXUIElement]) { self.windows = windows }
        func read() -> Result<AnyObject?, AXHelpers.AXStatusError> { .success(windows as AnyObject) }
    }

    @Test("issue608_a_window_whose_children_will_not_read_blocks_without_claiming_a_dialog")
    func unreadableChildrenBlockWithoutClaimingADialog() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(0)
        let window = b.element(1)
        b.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(window, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)

        let reader = Reader(windows: [window])
        let runtime = b.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { _, attribute in
                guard attribute == (kAXWindowsAttribute as String) else { return nil }
                return reader.read()
            },
            // The children read fails with a status that is NOT "unsupported" or "no value", which is
            // the fail-closed branch.
            childrenResultHandler: { _ in
                // Only one window exists in this fixture, so an unconditional failure IS that
                // window's children read.
                .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        // Fail-closed is preserved.
        #expect(reason.isBlocked)
        // But it does not claim anyone saw a dialog.
        #expect(!reason.namesAnActualDialog)
        #expect(reason == .windowChildrenUnreadable)
    }

    /// A real dialog alongside an unreadable window is still reported as a dialog — the observed
    /// thing is the more actionable one to name.
    @Test("issue608_a_real_dialog_wins_over_an_unreadable_window")
    func realDialogWinsOverUnreadable() {
        let b = FakeAXRuntimeBuilder()
        let app = b.element(0)
        let dialog = b.element(1)
        b.setAttribute(dialog, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(dialog, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(dialog, kAXTitleAttribute as String, "Save")
        b.setChildren(dialog, [])
        let broken = b.element(2)
        b.setAttribute(broken, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(broken, kAXSubroleAttribute as String, kAXStandardWindowSubrole as String)

        let reader = Reader(windows: [broken, dialog])
        let runtime = b.makeLogicRuntime(
            appElement: app,
            attributeValueResultHandler: { _, attribute in
                guard attribute == (kAXWindowsAttribute as String) else { return nil }
                return reader.read()
            },
            childrenResultHandler: { element in
                // The dialog is recognised by its SUBROLE before children are ever read, so failing
                // every children read still leaves the dialog observable and only breaks the other
                // window — which is the mix this test is about.
                _ = element
                return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let reason = AXLogicProElements.dialogPresenceReason(runtime: runtime)
        #expect(reason == .blockingWindowFound)
        #expect(reason.namesAnActualDialog)
    }
}
