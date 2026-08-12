@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class Issue532535537Counter: @unchecked Sendable {
    var value = 0
}

private final class Issue532535537Ordinal: @unchecked Sendable {
    var value: Int?
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

private func issue532535537MarkerRuntime(
    markers: [(position: String, name: String)]
) -> AXLogicProElements.Runtime {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(53_700)
    let arrange = builder.element(53_701)
    let markerList = builder.element(53_702)
    let table = builder.element(53_703)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Issue537 - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Issue537.logicx")
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Issue537 - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Issue537.logicx")
    _ = issue532535537MarkerList(
        builder: builder,
        window: markerList,
        table: table,
        firstID: 53_710,
        markers: markers
    )
    return builder.makeLogicRuntime(appElement: app)
}

@Test("#535: a Marker List table in another project cannot authorize Delete")
func issue535FocusRequiresTheBoundTableAndWindowIdentity() async throws {
    // Mutation that must fail this test: replace either CFEqual comparison in the focus guard with
    // the former role/marker-label classifier.  The other project's Marker List then authorizes the
    // Delete key and `selection_changed` is no longer returned in this refusal.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(53_500)
    let arrangeA = builder.element(53_501)
    let markerListA = builder.element(53_502)
    let targetTable = builder.element(53_503)
    let arrangeB = builder.element(53_504)
    let markerListB = builder.element(53_505)
    let otherTable = builder.element(53_506)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrangeA)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrangeA, markerListA, arrangeB, markerListB])
    builder.setAttribute(arrangeA, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrangeA, kAXTitleAttribute as String, "Project A - Tracks")
    builder.setAttribute(arrangeA, kAXDocumentAttribute as String, "/Project-A.logicx")
    builder.setAttribute(markerListA, kAXTitleAttribute as String, "Project A - Marker List")
    builder.setAttribute(markerListA, kAXDocumentAttribute as String, "/Project-A.logicx")
    builder.setAttribute(arrangeB, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrangeB, kAXTitleAttribute as String, "Project B - Tracks")
    builder.setAttribute(arrangeB, kAXDocumentAttribute as String, "/Project-B.logicx")
    builder.setAttribute(markerListB, kAXTitleAttribute as String, "Project B - Marker List")
    builder.setAttribute(markerListB, kAXDocumentAttribute as String, "/Project-B.logicx")
    let targetRows = issue532535537MarkerList(
        builder: builder, window: markerListA, table: targetTable, firstID: 53_510,
        markers: [(position: "5 1 1 1", name: "Target")]
    )
    _ = issue532535537MarkerList(
        builder: builder, window: markerListB, table: otherTable, firstID: 53_550,
        markers: [(position: "9 1 1 1", name: "Other Project Target")]
    )
    builder.setAttribute(app, kAXFocusedUIElementAttribute as String, otherTable)

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

    let result = await AccessibilityChannel.defaultDeleteMarker(index: 0, runtime: runtime, mouse: mouse)
    let envelope = try issue532535537Envelope(result)
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    #expect(!writeAttempted)
    let selectionChanged = try #require(envelope["selection_changed"] as? Bool)
    #expect(selectionChanged)
    #expect(deleteKeyPosts.value == 0)
}

/// The window check alone cannot catch this: both tables live in the SAME Marker List window, so
/// only the table-identity comparison can reject the focused one. Written after discovering that
/// the two-project test passes with EITHER CFEqual removed — the two checks were covering for each
/// other, so neither was individually proven necessary.
@Test("#535: a second table in the same window cannot authorize Delete")
func issue535FocusRequiresTheBoundTableEvenWithinOneWindow() async throws {
    // Mutation that must fail this test: replace `CFEqual(focusedTable, table)` in the focus guard
    // with a nil check. The sibling table then authorizes the Delete key.
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(53_800)
    let arrange = builder.element(53_801)
    let markerList = builder.element(53_802)
    let targetTable = builder.element(53_803)
    let siblingTable = builder.element(53_804)
    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "OneWindow - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/OneWindow.logicx")
    builder.setAttribute(markerList, kAXTitleAttribute as String, "OneWindow - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/OneWindow.logicx")

    let targetRows = issue532535537MarkerList(
        builder: builder, window: markerList, table: targetTable, firstID: 53_810,
        markers: [(position: "5 1 1 1", name: "Target")]
    )
    // A second table inside the SAME window. `setChildren` on the window is rewritten by the
    // helper above, so wire both tables as its children explicitly.
    builder.setAttribute(siblingTable, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(siblingTable, kAXDescriptionAttribute as String, "Marker Table")
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

    let result = await AccessibilityChannel.defaultDeleteMarker(index: 0, runtime: runtime, mouse: mouse)
    let envelope = try issue532535537Envelope(result)
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(deleteKeyPosts.value == 0)
}
