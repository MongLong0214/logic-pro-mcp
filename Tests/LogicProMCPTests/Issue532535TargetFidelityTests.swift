@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class Issue532535537Counter: @unchecked Sendable {
    var value = 0
}

private func issue532535537Envelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

private func issue532535537MarkerList(
    builder: FakeAXRuntimeBuilder,
    window: AXUIElement,
    table: AXUIElement,
    firstID: Int,
    markers: [(position: String, name: String)]
) -> [AXUIElement] {
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    let rows: [AXUIElement] = markers.enumerated().map { offset, marker in
        let base = firstID + offset * 10
        let row = builder.element(base)
        let lock = builder.element(base + 1)
        let positionCell = builder.element(base + 2)
        let nameCell = builder.element(base + 3)
        let position = builder.element(base + 4)
        let name = builder.element(base + 5)
        builder.setAttribute(row, kAXRoleAttribute as String, kAXRowRole as String)
        for cell in [lock, positionCell, nameCell] {
            builder.setAttribute(cell, kAXRoleAttribute as String, kAXCellRole as String)
        }
        builder.setAttribute(position, kAXDescriptionAttribute as String, marker.position)
        builder.setAttribute(name, kAXDescriptionAttribute as String, marker.name)
        builder.setChildren(positionCell, [position])
        builder.setChildren(nameCell, [name])
        builder.setChildren(row, [lock, positionCell, nameCell])
        return row
    }
    builder.setAttribute(table, "AXRows", rows)
    builder.setChildren(table, rows)
    builder.setChildren(window, [table])
    return rows
}

/// `selection_changed` must report what the call ALTERED, not what is true afterwards. A row that
/// was already the sole selection is not a change, and claiming one would be the same over-claim
/// this refusal exists to remove.
@Test("#532: an already-selected row is not reported as a selection change")
func issue532AlreadySelectedRowIsNotAChange() async throws {
    // Mutation that must fail this test: set `selection_changed` unconditionally true again.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(53_900)
    let arrange = builder.element(53_901)
    let markerList = builder.element(53_902)
    let table = builder.element(53_903)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Preselected - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Preselected.logicx")
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Preselected - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Preselected.logicx")

    let rows = issue532535537MarkerList(
        builder: builder, window: markerList, table: table, firstID: 53_910,
        markers: [(position: "5 1 1 1", name: "Target")]
    )
    // The target row is ALREADY the sole selection before the operation runs.
    builder.setAttribute(table, "AXSelectedRows", [rows[0]])

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { _, _, _ in true },
        performActionHandler: nil
    )
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in false },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    )

    let result = await AccessibilityChannel.defaultDeleteMarker(index: 0, runtime: runtime, mouse: mouse)
    let envelope = try issue532535537Envelope(result)
    #expect(!result.isSuccess)
    let writeAttempted = try #require(envelope["selection_write_attempted"] as? Bool)
    #expect(writeAttempted)
    let changed = try #require(envelope["selection_changed"] as? Bool)
    #expect(!changed)
}

/// A failed pre-write selection observation says nothing about whether the selection changed.
/// This must remain distinct from an empty successful observation.
@Test("#532: an unreadable prior selection leaves selection change unknown")
func issue532UnreadablePriorSelectionLeavesChangeUnknown() async throws {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(54_000)
    let arrange = builder.element(54_001)
    let markerList = builder.element(54_002)
    let table = builder.element(54_003)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Unreadable - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Unreadable.logicx")
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Unreadable - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Unreadable.logicx")

    let rows = issue532535537MarkerList(
        builder: builder, window: markerList, table: table, firstID: 54_010,
        markers: [(position: "5 1 1 1", name: "Target")]
    )
    // The row was already selected. The first `AXSelectedRows` read then fails, so the result
    // cannot honestly say whether this operation changed the selection.
    builder.setAttribute(table, "AXSelectedRows", [rows[0]])
    let prewriteSelectedRowsRead = Issue532535537Counter()

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        attributeValueHandler: { element, attribute in
            guard CFEqual(element, table), attribute == "AXSelectedRows",
                  prewriteSelectedRowsRead.value == 0 else { return nil }
            // If `getAttributeResult` regresses to `getAttribute ?? []`, this is the failed
            // pre-write read it will flatten into an empty selection.
            prewriteSelectedRowsRead.value += 1
            return .some(nil)
        },
        attributeValueResultHandler: { element, attribute in
            guard CFEqual(element, table), attribute == "AXSelectedRows",
                  prewriteSelectedRowsRead.value == 0 else { return nil }
            // The injected mutation: AXSelectedRows fails before the selection write.
            prewriteSelectedRowsRead.value += 1
            return .failure(AXHelpers.AXStatusError(raw: 1))
        },
        setAttributeHandler: { element, attribute, _ in
            if attribute == kAXSelectedAttribute as String, CFEqual(element, rows[0]) {
                builder.setAttribute(table, "AXSelectedRows", [rows[0]])
            }
            return true
        },
        performActionHandler: nil
    )
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in false },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    )

    let result = await AccessibilityChannel.defaultDeleteMarker(index: 0, runtime: runtime, mouse: mouse)
    let envelope = try issue532535537Envelope(result)
    #expect(!result.isSuccess)
    let selectionWriteAttempted = try #require(envelope["selection_write_attempted"] as? Bool)
    #expect(selectionWriteAttempted)
    #expect(envelope["selection_changed"] == nil)
}

/// The window check alone cannot catch this: both tables live in the SAME Marker List window, so
/// this fixture proves the exact-table CFEqual comparison remains an actuation precondition.
@Test("#535: a sibling table in the bound window cannot authorize the fallback key")
func issue535FocusRequiresTheExactSelectedTable() async throws {
    // Source mutation applied once: replace `CFEqual(focusedTable, table)` with `true` in the
    // focus guard. The sibling table then authorizes the Delete key and the zero-post assertion
    // below fails.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(54_100)
    let arrange = builder.element(54_101)
    let markerList = builder.element(54_102)
    let targetTable = builder.element(54_103)
    let siblingTable = builder.element(54_104)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "ExactTable - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/ExactTable.logicx")
    builder.setAttribute(markerList, kAXTitleAttribute as String, "ExactTable - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/ExactTable.logicx")
    let targetRows = issue532535537MarkerList(
        builder: builder, window: markerList, table: targetTable, firstID: 54_110,
        markers: [(position: "5 1 1 1", name: "Target")]
    )
    builder.setAttribute(siblingTable, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setChildren(markerList, [targetTable, siblingTable])
    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, siblingTable)

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, _ in
            if attribute == kAXSelectedAttribute as String, CFEqual(element, targetRows[0]) {
                builder.setAttribute(targetTable, "AXSelectedRows", [targetRows[0]])
            }
            return true
        },
        performActionHandler: nil
    )
    let deleteKeyPosts = Issue532535537Counter()
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in deleteKeyPosts.value += 1; return true },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    )

    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: runtime, mouse: mouse, logicIsFrontmost: { true }
    )
    let envelope = try issue532535537Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(deleteKeyPosts.value == 0)
}

/// This fixture preserves the selected table identity but changes its owning window after the row
/// selection. It independently proves the bound-window CFEqual comparison cannot be dropped.
@Test("#535: the selected table must remain in the bound Marker List window")
func issue535FocusRequiresTheBoundWindow() async throws {
    // Source mutation applied once: replace `CFEqual(element, window)` with `true` in the focus
    // guard. The reparented table then authorizes the Delete key and the zero-post assertion fails.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(54_200)
    let arrange = builder.element(54_201)
    let markerList = builder.element(54_202)
    let otherWindow = builder.element(54_203)
    let targetTable = builder.element(54_204)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList, otherWindow])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "BoundWindow - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/BoundWindow.logicx")
    builder.setAttribute(markerList, kAXTitleAttribute as String, "BoundWindow - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/BoundWindow.logicx")
    builder.setAttribute(otherWindow, kAXRoleAttribute as String, kAXWindowRole as String)
    let targetRows = issue532535537MarkerList(
        builder: builder, window: markerList, table: targetTable, firstID: 54_210,
        markers: [(position: "5 1 1 1", name: "Target")]
    )
    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, targetTable)

    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, _ in
            if attribute == kAXSelectedAttribute as String, CFEqual(element, targetRows[0]) {
                builder.setAttribute(targetTable, "AXSelectedRows", [targetRows[0]])
                builder.setChildren(otherWindow, [targetTable])
            }
            return true
        },
        performActionHandler: nil
    )
    let deleteKeyPosts = Issue532535537Counter()
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { _ in deleteKeyPosts.value += 1; return true },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    )

    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: runtime, mouse: mouse, logicIsFrontmost: { true }
    )
    let envelope = try issue532535537Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(deleteKeyPosts.value == 0)
}
