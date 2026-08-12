@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class Issue523ActionLog: @unchecked Sendable {
    private enum Event: Equatable {
        case action(elementID: Int, action: String)
        case key(CGKeyCode)
    }

    private var actions: [(elementID: Int, action: String)] = []
    private var deleteKeyEvents = 0
    private var escapeKeyEvents = 0
    private var events: [Event] = []

    func recordAction(elementID: Int, action: String) {
        actions.append((elementID, action))
        events.append(.action(elementID: elementID, action: action))
    }

    func recordKeyEvent(_ keyCode: CGKeyCode) {
        events.append(.key(keyCode))
        if keyCode == 0x33 { deleteKeyEvents += 1 }
        if keyCode == 0x35 { escapeKeyEvents += 1 }
    }

    func actionCount(elementID: Int, action: String) -> Int {
        actions.filter { $0.elementID == elementID && $0.action == action }.count
    }

    var keyEventCount: Int { deleteKeyEvents }

    var escapeKeyEventCount: Int { escapeKeyEvents }

    func actionOccursBeforeFirstKey(elementID: Int, action: String) -> Bool {
        guard let actionIndex = events.firstIndex(of: .action(elementID: elementID, action: action)),
              let keyIndex = events.firstIndex(where: { event in
                  if case .key(0x33) = event { return true }
                  return false
              }) else {
            return false
        }
        return actionIndex < keyIndex
    }
}

private final class Issue523MenuState: @unchecked Sendable {
    var isOpen = false
    var childrenReadFails = false
    var discoveryReadFailsOnce = false
}

private struct Issue523MarkerDeleteFixture {
    let runtime: AXLogicProElements.Runtime
    let mouse: AXMouseHelper.Runtime
    let actions: Issue523ActionLog
    let toolbarEditID: Int
    let bottomEditID: Int
    let menuID: Int
    let menuEntryID: Int
    let menuState: Issue523MenuState

    var menuIsOpen: Bool { menuState.isOpen }
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
    menuEntryEnabled: Bool = true,
    menuBoundToToolbar: Bool = true,
    menuDismissesOnCancel: Bool = true,
    menuDismissesOnEscape: Bool = true,
    menuDiscoveryReadFails: Bool = false,
    menuChildrenReadFailsAfterCancel: Bool = false,
    editControlTitle: String = "編集",
    markerListHasFocus: Bool = true
) -> Issue523MarkerDeleteFixture {
    let builder = FakeAXRuntimeBuilder()
    let actions = Issue523ActionLog()
    let menuState = Issue523MenuState()
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

    // Both controls have the same live label. The action list, not role or tree position,
    // decides which one may be used to reveal a menu.
    builder.setAttribute(toolbarEdit, kAXRoleAttribute as String, kAXMenuButtonRole as String)
    builder.setAttribute(toolbarEdit, kAXDescriptionAttribute as String, editControlTitle)
    builder.setActionNames(toolbarEdit, [kAXShowMenuAction as String])
    builder.setAttribute(bottomEdit, kAXRoleAttribute as String, kAXButtonRole as String)
    builder.setAttribute(bottomEdit, kAXDescriptionAttribute as String, editControlTitle)
    builder.setActionNames(bottomEdit, [kAXPressAction as String])

    if let menuEntryTitle {
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        builder.setAttribute(menuEntry, kAXRoleAttribute as String, kAXMenuItemRole as String)
        builder.setAttribute(menuEntry, kAXTitleAttribute as String, menuEntryTitle)
        builder.setAttribute(menuEntry, kAXEnabledAttribute as String, menuEntryEnabled as CFTypeRef)
        builder.setChildren(menu, [menuEntry])
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
    var markerListChildren = [bottomEdit, toolbarEdit, table]
    if menuEntryTitle != nil, !menuBoundToToolbar {
        // This menu is deliberately unrelated to the toolbar Edit control. It is the stale-window
        // decoy that the old "first AXMenu anywhere" fallback mistook for the requested menu.
        menuState.isOpen = true
        markerListChildren.append(menu)
    }
    builder.setChildren(markerList, markerListChildren)

    let entryID = builder.elementID(menuEntry)
    let menuID = builder.elementID(menu)
    let toolbarEditID = builder.elementID(toolbarEdit)
    let baseRuntime = builder.makeLogicRuntime(
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
            if action == (kAXShowMenuAction as String), elementID == builder.elementID(toolbarEdit) {
                if menuEntryTitle != nil, menuBoundToToolbar {
                    menuState.isOpen = true
                    menuState.discoveryReadFailsOnce = menuDiscoveryReadFails
                    builder.setChildren(toolbarEdit, [menu])
                }
                return true
            }
            if action == (kAXCancelAction as String), elementID == menuID {
                if menuDismissesOnCancel {
                    menuState.isOpen = false
                    builder.setChildren(toolbarEdit, [])
                } else if menuChildrenReadFailsAfterCancel {
                    menuState.childrenReadFails = true
                }
                return true
            }
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
    let runtime = AXLogicProElements.Runtime(
        logicProPID: baseRuntime.logicProPID,
        ax: AXHelpers.Runtime(
            axApp: baseRuntime.ax.axApp,
            attributeValue: baseRuntime.ax.attributeValue,
            setAttributeValue: baseRuntime.ax.setAttributeValue,
            children: { element in
                if menuState.childrenReadFails, builder.elementID(element) == toolbarEditID {
                    // This is what legacy `getChildren` exposes for a failed AX read.
                    return []
                }
                return baseRuntime.ax.children(element)
            },
            performAction: baseRuntime.ax.performAction,
            childCount: baseRuntime.ax.childCount,
            actionNames: baseRuntime.ax.actionNames,
            childrenResult: { element in
                if menuState.discoveryReadFailsOnce, builder.elementID(element) == toolbarEditID {
                    menuState.discoveryReadFailsOnce = false
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.childrenReadFails, builder.elementID(element) == toolbarEditID {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                return .success(baseRuntime.ax.children(element))
            }
        ),
        executeAppleScript: baseRuntime.executeAppleScript
    )
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { keyCode in
            actions.recordKeyEvent(keyCode)
            if keyCode == 0x35 {
                if menuState.isOpen, menuDismissesOnEscape {
                    menuState.isOpen = false
                    builder.setChildren(toolbarEdit, [])
                }
                return true
            }
            guard keyCode == 0x33 else { return false }
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
        toolbarEditID: toolbarEditID,
        bottomEditID: builder.elementID(bottomEdit),
        menuID: menuID,
        menuEntryID: entryID,
        menuState: menuState
    )
}

private func issue523Envelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

@Test func testIssue523ExactDeleteMenuPickDoesNotFallThroughWhenAXPickReportsFailure() async throws {
    for (editTitle, deleteTitle) in [("Edit", "Delete"), ("編集", "削除"), ("편집", "삭제")] {
        let fixture = issue523MarkerDeleteFixture(
            menuEntryTitle: deleteTitle,
            editControlTitle: editTitle
        )
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

        // Mutation: return AXHelpers.performAction's Bool from the menu helper instead of
        // `.pickIssued`. This fake AXPick returns false after deleting once, so the old fallthrough
        // posts Delete, removes a second row, and these State-A/no-key assertions fail.
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "A")
        #expect(writeAttempted)
        #expect(fixture.actions.actionCount(
            elementID: fixture.menuEntryID, action: kAXPickAction as String
        ) == 1)
        #expect(fixture.actions.actionCount(
            elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
        ) == 1)
        #expect(fixture.actions.actionCount(
            elementID: fixture.bottomEditID, action: kAXPressAction as String
        ) == 0)
        #expect(fixture.actions.keyEventCount == 0)
        #expect(!fixture.menuIsOpen)
    }
}

@Test func testIssue523ExactDeleteMatchingRejectsUndoHistoryAndJapanesePrefixCollision() async throws {
    for title in ["Delete Undo History", "取り消し履歴を削除", "削除して移動", "실행 취소 기록 삭제"] {
        let fixture = issue523MarkerDeleteFixture(menuEntryTitle: title)
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)

        // Mutation: replace `.exactStrict` with `.contains` (the undo-history labels) or `.prefix`
        // (the Japanese move-and-delete label). That issues AXPick here, so the no-pick assertion
        // fails instead of merely checking a LabelSet in isolation.
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "A")
        #expect(fixture.actions.actionCount(
            elementID: fixture.menuEntryID, action: kAXPickAction as String
        ) == 0)
        #expect(fixture.actions.keyEventCount == 1)
    }
}

@Test func testIssue523MissingDeleteEntryDismissesObservedMenuBeforeFocusGuardedDelete() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: "Copy")
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: remove the `dismissMarkerListEditMenu` call from the missing-entry branch. The
    // open-menu assertion and Cancel-before-key ordering both fail, catching the wedged fallback.
    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.actionOccursBeforeFirstKey(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ))
    #expect(!fixture.menuIsOpen)
    #expect(fixture.actions.keyEventCount == 1)
}

@Test func testIssue523DisabledDeleteEntryDismissesObservedMenuBeforeFocusGuardedDelete() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: "Delete", menuEntryEnabled: false)
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: remove the `dismissMarkerListEditMenu` call from the disabled-entry branch. The
    // open-menu assertion and Cancel-before-key ordering both fail, catching the wedged fallback.
    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.actionOccursBeforeFirstKey(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ))
    #expect(!fixture.menuIsOpen)
    #expect(fixture.actions.keyEventCount == 1)
}

@Test func testIssue523CancelFailureEscalatesToEscapeAndObservedClosure() async throws {
    for (title, enabled) in [("Copy", true), ("Delete", false)] {
        let fixture = issue523MarkerDeleteFixture(
            menuEntryTitle: title,
            menuEntryEnabled: enabled,
            menuDismissesOnCancel: false
        )
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

        // Mutation: return the wedged report immediately after a failed AXCancel. This fixture's
        // first Escape closes the menu, so the result stays State C and the open-menu assertion
        // fails instead of proving the escalation restored the UI before Delete was posted.
        #expect(result.isSuccess)
        #expect(envelope["state"] as? String == "A")
        #expect(writeAttempted)
        #expect(!fixture.menuIsOpen)
        #expect(fixture.actions.escapeKeyEventCount == 1)
        #expect(fixture.actions.keyEventCount == 1)
    }
}

@Test func testIssue523UnreadableMenuClosureForbidsFocusFallback() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDismissesOnCancel: false,
        menuDismissesOnEscape: false,
        menuChildrenReadFailsAfterCancel: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

    // Mutation: replace the closure observation with best-effort `getChildren`. After AXCancel,
    // this fixture gives that API `[]` but gives `childrenResult` an AX failure. The mutation then
    // treats the unreadable menu as closed and posts Delete; preserving the status keeps it wedged.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.escapeKeyEventCount == 3)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523MenuThatIgnoresEveryDismissalReportsWedgeWithoutDelete() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDismissesOnCancel: false,
        menuDismissesOnEscape: false
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

    // Mutation: make `dismissMarkerListEditMenu` claim success after its bounded dismissal tries.
    // The still-open fixture would then use the focus fallback and post Delete rather than return
    // the explicit wedged-menu refusal.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(fallbackUnsafe)
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.escapeKeyEventCount == 3)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523UnreadableMenuDiscoveryRefusesAfterObservedDismissal() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDiscoveryReadFails: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

    // Mutation: restore best-effort `getChildren` for discovery. This fixture returns a real menu
    // from that flattened API but a failed status from `childrenResult`, so the mutation closes
    // Copy's menu then posts Delete. Preserving the failure dismisses and refuses instead.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(safeToRetry)
    #expect(fallbackUnsafe)
    #expect(envelope["menu_state"] as? String == "closed_after_unreadable_discovery")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523RejectsAWindowMenuThatIsNotBoundToToolbarEdit() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: "Delete", menuBoundToToolbar: false)
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: restore the window-wide AXMenu fallback. It AXPick's this unrelated Delete entry,
    // so the exact-entry no-pick assertion and focus-guarded-key assertion both fail.
    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.actions.keyEventCount == 1)
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
