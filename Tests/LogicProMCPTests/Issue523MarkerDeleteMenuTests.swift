@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class Issue523ActionLog: @unchecked Sendable {
    private var actions: [(elementID: Int, action: String)] = []
    private var keyEvents = 0

    func recordAction(elementID: Int, action: String) {
        actions.append((elementID, action))
    }

    func recordKeyEvent() {
        keyEvents += 1
    }

    func actionCount(elementID: Int, action: String) -> Int {
        actions.filter { $0.elementID == elementID && $0.action == action }.count
    }

    var keyEventCount: Int { keyEvents }
}

private struct Issue523MarkerDeleteFixture {
    let runtime: AXLogicProElements.Runtime
    let mouse: AXMouseHelper.Runtime
    let actions: Issue523ActionLog
    let toolbarEditID: Int
    let bottomEditID: Int
    let menuEntryID: Int?
}

/// Builds the part of the live Marker List tree that matters to delete:
///
///     Marker List window
///       ├─ bottom `Edit` AXButton       actions: [AXPress]
///       ├─ toolbar `Edit` AXMenuButton  actions: [AXShowMenu]
///       │    └─ AXMenu → AXMenuItem
///       └─ AXTable → selected marker rows
///
/// An `AXPick` removes the selected row but returns `false`, matching the live AX anomaly. If the
/// implementation consults that Boolean and posts Delete too, this fixture removes another row;
/// readback changes from State A to State B and the test catches the destructive fallthrough.
private func issue523MarkerDeleteFixture(
    menuEntryTitle: String?,
    markerListHasFocus: Bool = true
) -> Issue523MarkerDeleteFixture {
    let builder = FakeAXRuntimeBuilder()
    let actions = Issue523ActionLog()
    let app = builder.element(52_300)
    let arrange = builder.element(52_301)
    let markerList = builder.element(52_302)
    let toolbarEdit = builder.element(52_303)
    let bottomEdit = builder.element(52_304)
    let menu = builder.element(52_305)
    let menuEntry = builder.element(52_306)
    let table = builder.element(52_307)

    builder.setAttribute(app, kAXMainWindowAttribute as String, arrange)
    builder.setAttribute(app, kAXWindowsAttribute as String, [arrange, markerList])
    builder.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(arrange, kAXTitleAttribute as String, "Issue523 - Tracks")
    builder.setAttribute(arrange, kAXDocumentAttribute as String, "/Issue523.logicx")
    builder.setAttribute(markerList, kAXRoleAttribute as String, kAXWindowRole as String)
    builder.setAttribute(markerList, kAXTitleAttribute as String, "Issue523 - Marker List")
    builder.setAttribute(markerList, kAXDocumentAttribute as String, "/Issue523.logicx")

    // Both controls have the Japanese live label. The action list, not role or tree position,
    // decides which one may be used to reveal a menu.
    builder.setAttribute(toolbarEdit, kAXRoleAttribute as String, kAXMenuButtonRole as String)
    builder.setAttribute(toolbarEdit, kAXDescriptionAttribute as String, "編集")
    builder.setActionNames(toolbarEdit, [kAXShowMenuAction as String])
    builder.setAttribute(bottomEdit, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(bottomEdit, kAXDescriptionAttribute as String, "編集")
    builder.setActionNames(bottomEdit, [kAXPressAction as String])

    if let menuEntryTitle {
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setAttribute(menuEntry, kAXRoleAttribute as String, kAXMenuItemRole as String)
        builder.setAttribute(menuEntry, kAXTitleAttribute as String, menuEntryTitle)
        builder.setAttribute(menuEntry, kAXEnabledAttribute as String, true as CFTypeRef)
        builder.setChildren(menu, [menuEntry])
        builder.setChildren(toolbarEdit, [menu])
    }

    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(table, kAXDescriptionAttribute as String, "Marker Table")
    if markerListHasFocus {
        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, table)
    } else {
        let arrangeFocus = builder.element(52_308)
        builder.setAttribute(arrangeFocus, kAXRoleAttribute as String, kAXGroupRole as String)
        builder.setAttribute(arrangeFocus, kAXDescriptionAttribute as String, "Arrange area")
        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, arrangeFocus)
    }

    let rows: [AXUIElement] = [
        ("1 1 1 1", "Intro"),
        ("5 1 1 1", "Verse"),
        ("9 1 1 1", "Chorus"),
    ].enumerated().map { offset, marker in
        let base = 52_310 + offset * 10
        let row = builder.element(base)
        let lockCell = builder.element(base + 1)
        let positionCell = builder.element(base + 2)
        let nameCell = builder.element(base + 3)
        let position = builder.element(base + 4)
        let name = builder.element(base + 5)
        builder.setAttribute(row, kAXRoleAttribute as String, kAXRowRole as String)
        for cell in [lockCell, positionCell, nameCell] {
            builder.setAttribute(cell, kAXRoleAttribute as String, kAXCellRole as String)
        }
        builder.setAttribute(position, kAXDescriptionAttribute as String, marker.0)
        builder.setAttribute(name, kAXDescriptionAttribute as String, marker.1)
        builder.setChildren(positionCell, [position])
        builder.setChildren(nameCell, [name])
        builder.setChildren(row, [lockCell, positionCell, nameCell])
        return row
    }
    builder.setAttribute(table, "AXRows", rows)
    builder.setChildren(table, rows)
    builder.setChildren(markerList, [bottomEdit, toolbarEdit, table])

    let entryID = builder.elementID(menuEntry)
    let runtime = builder.makeLogicRuntime(
        appElement: app,
        setAttributeHandler: { element, attribute, _ in
            if attribute == kAXSelectedAttribute as String {
                builder.setAttribute(table, "AXSelectedRows", [element])
            }
            return true
        },
        performActionHandler: { element, action in
            let elementID = builder.elementID(element)
            actions.recordAction(elementID: elementID, action: action)
            if action == (kAXPickAction as String), elementID == entryID {
                // The first row is the selected target. AX reports failure despite delivering it.
                let afterPick = Array(AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).dropFirst())
                builder.setAttribute(table, "AXRows", afterPick)
                builder.setChildren(table, afterPick)
                return false
            }
            return true
        }
    )
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { keyCode in
            guard keyCode == 0x33 else { return false }
            actions.recordKeyEvent()
            // Model the harm from treating the false AXPick result as permission to press Delete:
            // the selected target is already gone, so this removes another survivor.
            let afterKey = Array(AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).dropFirst())
            builder.setAttribute(table, "AXRows", afterKey)
            builder.setChildren(table, afterKey)
            return true
        },
        postUnicodeScalar: { _ in false },
        sleepMicros: { _ in }
    )
    return Issue523MarkerDeleteFixture(
        runtime: runtime,
        mouse: mouse,
        actions: actions,
        toolbarEditID: builder.elementID(toolbarEdit),
        bottomEditID: builder.elementID(bottomEdit),
        menuEntryID: menuEntryTitle == nil ? nil : entryID
    )
}

private func issue523Envelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

@Test func testIssue523ExactDeleteMenuPickDoesNotFallThroughWhenAXPickReportsFailure() async throws {
    for title in ["Delete", "削除"] {
        let fixture = issue523MarkerDeleteFixture(menuEntryTitle: title)
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let menuEntryID = try #require(fixture.menuEntryID)

        // Mutation: return AXHelpers.performAction's Bool from the menu helper instead of
        // `.pickIssued`. This fake AXPick returns false after deleting once, so the old fallthrough
        // posts Delete, removes a second row, and these State-A/no-key assertions fail.
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "A")
        #expect(writeAttempted)
        #expect(fixture.actions.actionCount(
            elementID: menuEntryID, action: kAXPickAction as String
        ) == 1)
        #expect(fixture.actions.actionCount(
            elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
        ) == 1)
        #expect(fixture.actions.actionCount(
            elementID: fixture.bottomEditID, action: kAXPressAction as String
        ) == 0)
        #expect(fixture.actions.keyEventCount == 0)
    }
}

@Test func testIssue523ExactDeleteMatchingRejectsUndoHistoryAndJapanesePrefixCollision() async throws {
    for title in ["Delete Undo History", "取り消し履歴を削除", "削除して移動"] {
        let fixture = issue523MarkerDeleteFixture(menuEntryTitle: title)
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)
        let menuEntryID = try #require(fixture.menuEntryID)

        // Mutation: replace `.exactStrict` with `.contains` (the undo-history labels) or `.prefix`
        // (the Japanese move-and-delete label). That issues AXPick here, so the no-pick assertion
        // fails instead of merely checking a LabelSet in isolation.
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "A")
        #expect(fixture.actions.actionCount(
            elementID: menuEntryID, action: kAXPickAction as String
        ) == 0)
        #expect(fixture.actions.keyEventCount == 1)
    }
}

@Test func testIssue523NoMenuOrNoExactEntryFallsThroughToFocusGuardedDeleteKey() async throws {
    for entryTitle: String? in [nil, "Copy"] {
        let fixture = issue523MarkerDeleteFixture(menuEntryTitle: entryTitle)
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)

        // Mutation: remove the non-pick cases from the switch or return after menu discovery.
        // Neither tree has an exact Delete actuator, so its existing focused-key fallback must run.
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "A")
        #expect(fixture.actions.keyEventCount == 1)
        if let menuEntryID = fixture.menuEntryID {
            #expect(fixture.actions.actionCount(
                elementID: menuEntryID, action: kAXPickAction as String
            ) == 0)
        }
    }
}

@Test func testIssue523FocusRefusalRemainsFallbackUnsafeButIsSafeToRetry() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: nil, markerListHasFocus: false)
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    // Mutation: omit safe_to_retry from the focus refusal. The refusal still prevents the key,
    // but callers can no longer distinguish a clean focus retry from an uncertain write.
    #expect(!result.isSuccess)
    #expect(safeToRetry)
    #expect(fallbackUnsafe)
    #expect(!writeAttempted)
    #expect(fixture.actions.keyEventCount == 0)
}
