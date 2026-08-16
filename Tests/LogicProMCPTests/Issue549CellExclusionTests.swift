@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// #549 (second fix): one `AXCell` inside Logic's Marker List table answers `AXChildren` with
/// `-25200` on EVERY read, live, whenever the Marker List window is open — independent of whether
/// a sheet exists anywhere. Because a single unreadable node anywhere made the whole sheet-scan
/// verdict `.unreadable` instead of `.absent`, `track.create` / `track.delete` could not reach
/// Honest Contract State A on any project that has a marker while that window is open, which is an
/// ordinary working state, not a rare failure.
///
/// The fix narrows `findSheetDescendantLookup`'s `.failure` branch: a children-read failure on a
/// node whose ALREADY-KNOWN role is `kAXCellRole` (a role that structurally cannot host an
/// `AXSheet`) now reports `.absent` for that node instead of poisoning the whole scan to
/// `.unreadable`. These tests prove: (1) the reproduction is actually fixed, (2) the narrowing is
/// exactly one role wide and does not casually swallow a role that COULD host a sheet, (3) a real
/// sheet elsewhere in the same tree is still found — the narrowing must never blind the scan, and
/// (4) a node whose OWN role read failed (so its role is unknown, not merely non-hosting) still
/// poisons, because it could have been the sheet.
@Suite("Issue #549 — an AXCell that cannot host a sheet does not poison the scan")
struct Issue549CellExclusionTests {

    @Test("a genuinely -25200-unreadable AXCell with no sheet anywhere reports absent, and the operation can certify")
    func cellChildrenFailureReportsAbsentAndCertifies() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9601)
        let window = builder.element(9602)
        let cellNode = builder.element(9603)
        let childrenReads = LockedCounter549Cell()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(cellNode, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setChildren(window, [cellNode])

        // The exact status measured live on the Marker List's AXCell.
        let markerListStatus = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, cellNode) else { return nil }
                _ = childrenReads.next()
                return .failure(markerListStatus)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(childrenReads.current() > 0, "the AXCell's AXChildren failure seam must fire, or this test proves nothing")
        #expect(read.unreadableReason == nil, "an AXCell that cannot host a sheet must not poison the scan verdict")
        #expect(read.sheetScanFailureDetail == nil)
        #expect(!read.signals.sheetPresent)
        #expect(read.modalObservationIsComplete)
        #expect(ModalReconciliation.classify(read.signals) == .none)

        // The property `track.create` / `track.delete` actually gate State A on: a complete,
        // unblocked observation from the public entry point, not only the lower-level signal read.
        let outcome = AccessibilityChannel.observeModalAfterMutation(isDeleteContext: false, runtime: runtime)
        #expect(outcome.kind == .none)
        #expect(outcome.unreadableReason == nil)
        #expect(outcome.modalObservationIsComplete, "the operation must be able to certify State A with the AXCell node still present")
    }

    @Test("the SAME failing shape on a role that CAN host content (AXGroup) still poisons the scan to unreadable")
    func groupChildrenFailureStillPoisons() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9611)
        let window = builder.element(9612)
        let groupNode = builder.element(9613)
        let childrenReads = LockedCounter549Cell()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(groupNode, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setChildren(window, [groupNode])

        let markerListStatus = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, groupNode) else { return nil }
                _ = childrenReads.next()
                return .failure(markerListStatus)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(childrenReads.current() > 0, "the AXGroup's AXChildren failure seam must fire, or this test proves nothing")
        #expect(read.unreadableReason == .windowSheetReadFailed(markerListStatus))
        let detail = try #require(
            read.sheetScanFailureDetail,
            "a role that CAN host content must still surface #549's failure-detail companion"
        )
        #expect(detail.attribute == .children)
        #expect(detail.subjectRole == (kAXGroupRole as String))
        #expect(!read.modalObservationIsComplete)
    }

    @Test("a real AXSheet elsewhere in the same tree is still found — the narrowing does not blind the scan")
    func realSheetElsewhereIsStillFound() throws {
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9621)
        let window = builder.element(9622)
        let cellNode = builder.element(9623)
        let containerGroup = builder.element(9624)
        let sheetNode = builder.element(9625)
        let childrenReads = LockedCounter549Cell()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setAttribute(cellNode, kAXRoleAttribute as String, kAXCellRole as String)
        builder.setAttribute(containerGroup, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(sheetNode, kAXRoleAttribute as String, kAXSheetRole as String)
        // The window's direct children are the failing AXCell AND a sibling group that (two
        // levels down) genuinely holds an AXSheet — the New Track shape.
        builder.setChildren(window, [cellNode, containerGroup])
        builder.setChildren(containerGroup, [sheetNode])

        let markerListStatus = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, cellNode) else { return nil }
                _ = childrenReads.next()
                return .failure(markerListStatus)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(
            childrenReads.current() > 0,
            "the failing AXCell subtree must actually be visited before the sheet is found, or this test proves nothing about narrowing safety"
        )
        #expect(read.signals.sheetPresent)
        #expect(read.unreadableReason == nil)
        let sheet = try #require(read.sheet)
        #expect(CFEqual(sheet, sheetNode))
    }

    @Test("a node whose OWN role read failed still poisons a subsequent children-read failure — identity unknown means it could have been the sheet")
    func unknownRoleChildrenFailureStillPoisons() throws {
        // The window root is the one node this scan ever descends into with `elementRole == nil`
        // for a reason OTHER than "role read failed": its role is never independently read at all
        // (see `findSheetDescendantLookup`'s `elementRole` doc comment). Failing the window's own
        // `AXChildren` read exercises exactly the `elementRole == nil` branch of the exclusion
        // guard and proves nil does NOT accidentally satisfy `rolesThatCannotHostASheet.contains`.
        let builder = FakeAXRuntimeBuilder()
        let app = builder.element(9631)
        let window = builder.element(9632)
        let childrenReads = LockedCounter549Cell()

        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        // Deliberately no children configured for `window` — the failure is the window's own
        // AXChildren read, not a descendant's.

        let markerListStatus = AXHelpers.AXStatusError(raw: AXError.failure.rawValue)
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            childrenResultHandler: { element in
                guard CFEqual(element, window) else { return nil }
                _ = childrenReads.next()
                return .failure(markerListStatus)
            },
            setAttributeHandler: nil,
            performActionHandler: nil
        )

        let read = AccessibilityChannel.readModalSignalsAndAlertTarget(runtime: runtime)

        #expect(childrenReads.current() > 0, "the window root's own AXChildren failure seam must fire, or this test proves nothing")
        #expect(read.unreadableReason == .windowSheetReadFailed(markerListStatus))
        let detail = try #require(read.sheetScanFailureDetail)
        #expect(detail.subjectRole == nil, "the window root's role is never read; nil must not be mistaken for a known non-hosting role")
        #expect(!read.modalObservationIsComplete)
    }
}

private final class LockedCounter549Cell: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
