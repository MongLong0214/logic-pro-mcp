@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class Issue523ActionLog: @unchecked Sendable {
    private var actions: [(elementID: Int, action: String)] = []
    private var keyEvents = 0
    private var pidKeyEvents: [(keyCode: CGKeyCode, pid: pid_t)] = []

    func recordAction(elementID: Int, action: String) {
        actions.append((elementID, action))
    }

    func recordKeyEvent(_: CGKeyCode) {
        keyEvents += 1
    }

    func recordKeyEventToLogic(_ keyCode: CGKeyCode, pid: pid_t) {
        pidKeyEvents.append((keyCode, pid))
    }

    func actionCount(elementID: Int, action: String) -> Int {
        actions.filter { $0.elementID == elementID && $0.action == action }.count
    }

    var keyEventCount: Int { keyEvents }
    var pidKeyEventCount: Int { pidKeyEvents.count }
    var pidKeyEventPIDs: [pid_t] { pidKeyEvents.map(\.pid) }
}

private final class Issue523MenuState: @unchecked Sendable {
    var isOpen = false
    var childrenReadFails = false
    var discoveryReadFailsOnce = false
    var discoveryReadAlwaysFails = false
    var controlDiscoveryReadFails = false
    var actionNamesReadFails = false
    var menuEntryChildrenReadFails = false
    var menuEntryEnabledReadFails = false
    var postWriteRowsReadFails = false
    var postWriteRowCellsReadNoValue = false
    var rowSelectionWasWritten = false
    var showMenuWasRequested = false
    var menuWasDismissed = false
    var toolbarMenuReadCount = 0
    var closesAfterFirstSighting = false
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
    let postKeyEventToLogic: @Sendable (CGKeyCode, pid_t) -> Bool
    let readMarkerCount: () -> Int

    var menuIsOpen: Bool { menuState.isOpen }
    var markerCount: Int { readMarkerCount() }
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
/// implementation consults that Boolean and treats the completed pick as a refusal, this fixture
/// changes from State A to State C and the test catches the false-negative report.
private func issue523MarkerDeleteFixture(
    menuEntryTitle: String?,
    menuEntryEnabled: Bool = true,
    menuBoundToToolbar: Bool = true,
    menuDismissesOnCancel: Bool = true,
    menuDiscoveryReadFails: Bool = false,
    menuDiscoveryReadAlwaysFails: Bool = false,
    menuChildrenReadFailsAfterCancel: Bool = false,
    menuClosesAfterFirstSighting: Bool = false,
    menuChildrenAbsenceStatus: Int32? = nil,
    editControlTitle: String = "編集",
    toolbarEditAdvertisesCancel: Bool = false,
    selectionConfirms: Bool = true,
    tableHasKeyboardFocus: Bool = false,
    pickDeletesSelectedRow: Bool = true,
    postWriteRowsReadFails: Bool = false,
    postWriteRowCellsReadNoValue: Bool = false,
    menuControlDiscoveryReadFails: Bool = false,
    menuActionNamesReadFails: Bool = false,
    bottomEditActionNamesReadFails: Bool = false,
    menuEntryChildrenReadFails: Bool = false,
    menuEntryEnabledReadFails: Bool = false,
    markers: [(position: String, name: String)] = [
        ("1 1 1 1", "Intro"),
        ("5 1 1 1", "Verse"),
        ("9 1 1 1", "Chorus"),
    ]
) -> Issue523MarkerDeleteFixture {
    let builder = FakeAXRuntimeBuilder()
    let actions = Issue523ActionLog()
    let menuState = Issue523MenuState()
    menuState.closesAfterFirstSighting = menuClosesAfterFirstSighting
    menuState.controlDiscoveryReadFails = menuControlDiscoveryReadFails
    menuState.actionNamesReadFails = menuActionNamesReadFails
    menuState.menuEntryChildrenReadFails = menuEntryChildrenReadFails
    menuState.menuEntryEnabledReadFails = menuEntryEnabledReadFails
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
    builder.setActionNames(
        toolbarEdit,
        toolbarEditAdvertisesCancel
            ? [kAXShowMenuAction as String, kAXCancelAction as String]
            : [kAXShowMenuAction as String]
    )
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

    let rows: [AXUIElement] = markers.enumerated().map { offset, marker in
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
    if tableHasKeyboardFocus {
        builder.setAttribute(app, kAXFocusedUIElementAttribute as String, table)
    }
    var markerListChildren = [bottomEdit, toolbarEdit, table]
    if menuEntryTitle != nil, !menuBoundToToolbar {
        // This menu is deliberately unrelated to the toolbar Edit control. It is the stale-window
        // decoy that the old "first AXMenu anywhere" fallback mistook for the requested menu.
        //
        // `menuState.isOpen` is NOT set: a leftover element in the window's child list is not the
        // exact toolbar Edit menu this operation asked to open.
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
                menuState.rowSelectionWasWritten = true
            }
            if selectionConfirms, attribute == kAXSelectedAttribute as String {
                builder.setAttribute(table, "AXSelectedRows", [element])
            }
            return true
        },
        performActionHandler: { element, action in
            let elementID = builder.elementID(element)
            actions.recordAction(elementID: elementID, action: action)
            if action == (kAXShowMenuAction as String), elementID == builder.elementID(toolbarEdit) {
                menuState.showMenuWasRequested = true
                menuState.menuWasDismissed = false
                menuState.toolbarMenuReadCount = 0
                if menuEntryTitle != nil, menuBoundToToolbar {
                    menuState.discoveryReadFailsOnce = menuDiscoveryReadFails
                    menuState.discoveryReadAlwaysFails = menuDiscoveryReadAlwaysFails
                    menuState.isOpen = true
                    builder.setChildren(toolbarEdit, menuState.isOpen ? [menu] : [])
                }
                return true
            }
            if action == (kAXCancelAction as String), elementID == menuID {
                if menuDismissesOnCancel {
                    menuState.isOpen = false
                    menuState.menuWasDismissed = true
                    builder.setChildren(toolbarEdit, [])
                } else if menuChildrenReadFailsAfterCancel {
                    menuState.childrenReadFails = true
                }
                return true
            }
            if action == (kAXPickAction as String), elementID == entryID {
                // A menu that closed after observation has no live target for AXPick. Model the
                // stale action as a no-op instead of manufacturing a successful deletion.
                guard menuState.isOpen else {
                    menuState.postWriteRowsReadFails = postWriteRowsReadFails
                    menuState.postWriteRowCellsReadNoValue = postWriteRowCellsReadNoValue
                    return false
                }
                // The first row is the selected target. AX reports failure despite delivering it.
                if pickDeletesSelectedRow {
                    let afterPick = Array(AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).dropFirst())
                    builder.setAttribute(table, "AXRows", afterPick)
                    builder.setChildren(table, afterPick)
                }
                menuState.postWriteRowsReadFails = postWriteRowsReadFails
                menuState.postWriteRowCellsReadNoValue = postWriteRowCellsReadNoValue
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
            actionNamesResult: { element in
                if menuState.actionNamesReadFails,
                   builder.elementID(element) == toolbarEditID {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if bottomEditActionNamesReadFails,
                   builder.elementID(element) == builder.elementID(bottomEdit) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                return baseRuntime.ax.actionNamesResult?(element)
                    ?? .success(baseRuntime.ax.actionNames(element))
            },
            childrenResult: { element in
                if menuState.controlDiscoveryReadFails,
                   menuState.rowSelectionWasWritten,
                   builder.elementID(element) == builder.elementID(markerList) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.menuEntryChildrenReadFails,
                   menuState.isOpen,
                   builder.elementID(element) == menuID {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.postWriteRowsReadFails,
                   builder.elementID(element) == builder.elementID(table) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.postWriteRowCellsReadNoValue,
                   rows.contains(where: { CFEqual(element, $0) }) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
                }
                if builder.elementID(element) == toolbarEditID,
                   menuState.showMenuWasRequested,
                   let menuChildrenAbsenceStatus {
                    return .failure(AXHelpers.AXStatusError(raw: menuChildrenAbsenceStatus))
                }
                if menuState.discoveryReadAlwaysFails, builder.elementID(element) == toolbarEditID {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.apiDisabled.rawValue))
                }
                if menuState.discoveryReadFailsOnce, builder.elementID(element) == toolbarEditID {
                    menuState.discoveryReadFailsOnce = false
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.childrenReadFails, builder.elementID(element) == toolbarEditID {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if builder.elementID(element) == toolbarEditID,
                   menuState.showMenuWasRequested,
                   !menuState.menuWasDismissed,
                   menuEntryTitle != nil,
                   menuBoundToToolbar {
                    menuState.toolbarMenuReadCount += 1
                }
                let children = baseRuntime.ax.children(element)
                if builder.elementID(element) == toolbarEditID,
                   menuState.closesAfterFirstSighting,
                   menuState.toolbarMenuReadCount == 1,
                   menuState.isOpen {
                    // Return the observed AXMenu, then close it before the caller reaches AXPick.
                    menuState.isOpen = false
                    builder.setChildren(toolbarEdit, [])
                }
                return .success(children)
            },
            attributeValueResult: { element, attribute in
                if menuState.postWriteRowsReadFails,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.menuEntryEnabledReadFails,
                   builder.elementID(element) == entryID,
                   attribute == kAXEnabledAttribute as String {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                return baseRuntime.ax.attributeValueResult?(element, attribute)
                    ?? .success(baseRuntime.ax.attributeValue(element, attribute))
            }
        ),
        executeAppleScript: baseRuntime.executeAppleScript
    )
    let mouse = AXMouseHelper.Runtime(
        postMouseEvent: { _, _, _ in false },
        postKeyEvent: { keyCode in
            actions.recordKeyEvent(keyCode)
            guard keyCode == 0x33 else { return false }
            let afterKey = Array(AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).dropFirst())
            builder.setAttribute(table, "AXRows", afterKey)
            builder.setChildren(table, afterKey)
            return false
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
        menuState: menuState,
        postKeyEventToLogic: { keyCode, pid in
            actions.recordKeyEventToLogic(keyCode, pid: pid)
            guard keyCode == 0x33 else { return false }
            let afterKey = Array(AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).dropFirst())
            builder.setAttribute(table, "AXRows", afterKey)
            builder.setChildren(table, afterKey)
            return false
        },
        readMarkerCount: {
            AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).count
        }
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
        // `.pickIssued`. This fake AXPick returns false after deleting once, so the mutation
        // misreports the completed menu delete as a route refusal and fails the State-A assertion.
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

@Test func testIssue523KeyFallbackIsAbsentForUsableMenusAndBoundedOtherwise() async {
    let cases: [(Int, Bool, () -> Issue523MarkerDeleteFixture)] = [
        (-1, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Delete") }),
        (3, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Delete") }),
        (0, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Delete", selectionConfirms: false) }),
        (0, true, { issue523MarkerDeleteFixture(menuEntryTitle: "Delete") }),
        (0, false, { issue523MarkerDeleteFixture(menuEntryTitle: nil) }),
        (0, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Copy") }),
        (0, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Delete", menuEntryEnabled: false) }),
        (0, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Copy", menuDiscoveryReadFails: true) }),
        (0, false, { issue523MarkerDeleteFixture(menuEntryTitle: "Copy", menuDismissesOnCancel: false) }),
    ]

    // Source mutation applied once: post `kVK_Delete` in the `.pickIssued` branch before its
    // survivor readback. The usable-menu case then records a key and fails the zero-key branch.
    // The restored source posts no key when the menu route was usable, and at most one otherwise.
    for (index, menuRouteWasUsable, makeFixture) in cases {
        let fixture = makeFixture()
        _ = await AccessibilityChannel.defaultDeleteMarker(
            index: index, runtime: fixture.runtime, mouse: fixture.mouse
        )
        if menuRouteWasUsable {
            #expect(fixture.actions.keyEventCount == 0)
        } else {
            #expect(fixture.actions.keyEventCount <= 1)
        }
    }
}

@Test func testIssue523AbsentEditMenuRefusesWithoutPostingAKey() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: nil)
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

    // Mutation: restore a global Delete after `.menuAbsent`. The mutation marks this path as a
    // write and calls the key seam, so the State-C/write/key assertions fail.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
    #expect(try #require(envelope["hint"] as? String).contains("not available"))
    #expect(!writeAttempted)
    #expect(safeToRetry)
    #expect(HonestContract.isFallbackUnsafeStateC(result.message))
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523FocusedKeyFallbackDeletesWhenLocalizedMenuRouteIsAbsent() async throws {
    // Source mutation applied once: replace the pid-bound `postKeyEventToLogic` call with
    // `mouse.postKeyEvent`. The fixture then records a global-tap key instead of a pid-bound one,
    // failing the direct-delivery assertions below.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Supprimer",
        editControlTitle: "Modifier",
        tableHasKeyboardFocus: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0,
        runtime: fixture.runtime,
        mouse: fixture.mouse,
        logicIsFrontmost: { true },
        postKeyEventToLogic: fixture.postKeyEventToLogic
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
    #expect(envelope["actuation_route"] as? String == "focused_delete_key")
    #expect(writeAttempted)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.actions.pidKeyEventCount == 1)
    #expect(fixture.actions.pidKeyEventPIDs == [4242])
    #expect(fixture.markerCount == 2)
}

@Test func testIssue523FocusedKeyFallbackRequiresLogicToBeFrontmost() async throws {
    // Source mutation applied once: replace `guard logicIsFrontmost()` with `guard true` before
    // the fallback post. This backgrounded-Logic fixture then records the key and fails the
    // no-post assertion.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: nil,
        tableHasKeyboardFocus: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0,
        runtime: fixture.runtime,
        mouse: fixture.mouse,
        logicIsFrontmost: { false },
        postKeyEventToLogic: fixture.postKeyEventToLogic
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.actions.pidKeyEventCount == 0)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)
    #expect(safeToRetry)
    #expect(fallbackUnsafe)
}

@Test func testIssue523UnreadableMenuReadsAreReportedAndMayUseTheFocusedFallback() async throws {
    // Source mutation applied once: drop the unreadable error while building either the menu-entry
    // or AXEnabled route outcome. Their `edit_menu_route_ax_status` assertions then fail rather
    // than leaving an advertised unreadable route without its raw AX diagnosis.
    let controlFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        tableHasKeyboardFocus: true,
        menuControlDiscoveryReadFails: true
    )
    let actionFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        tableHasKeyboardFocus: true,
        menuActionNamesReadFails: true
    )
    let entryFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        tableHasKeyboardFocus: true,
        menuEntryChildrenReadFails: true
    )
    let enabledFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        tableHasKeyboardFocus: true,
        menuEntryEnabledReadFails: true
    )

    let controlResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: controlFixture.runtime, mouse: controlFixture.mouse,
        logicIsFrontmost: { true }, postKeyEventToLogic: controlFixture.postKeyEventToLogic
    )
    let actionResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: actionFixture.runtime, mouse: actionFixture.mouse,
        logicIsFrontmost: { true }, postKeyEventToLogic: actionFixture.postKeyEventToLogic
    )
    let entryResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: entryFixture.runtime, mouse: entryFixture.mouse,
        logicIsFrontmost: { true }, postKeyEventToLogic: entryFixture.postKeyEventToLogic
    )
    let enabledResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: enabledFixture.runtime, mouse: enabledFixture.mouse,
        logicIsFrontmost: { true }, postKeyEventToLogic: enabledFixture.postKeyEventToLogic
    )
    let controlEnvelope = try issue523Envelope(controlResult)
    let actionEnvelope = try issue523Envelope(actionResult)
    let entryEnvelope = try issue523Envelope(entryResult)
    let enabledEnvelope = try issue523Envelope(enabledResult)

    #expect(controlResult.isSuccess)
    #expect(actionResult.isSuccess)
    #expect(entryResult.isSuccess)
    #expect(enabledResult.isSuccess)
    #expect(controlEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(actionEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(entryEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(enabledEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(controlEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(actionEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(entryEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(enabledEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(controlFixture.actions.keyEventCount == 0)
    #expect(actionFixture.actions.keyEventCount == 0)
    #expect(entryFixture.actions.keyEventCount == 0)
    #expect(enabledFixture.actions.keyEventCount == 0)
    #expect(controlFixture.actions.pidKeyEventCount == 1)
    #expect(actionFixture.actions.pidKeyEventCount == 1)
    #expect(entryFixture.actions.pidKeyEventCount == 1)
    #expect(enabledFixture.actions.pidKeyEventCount == 1)
}

@Test func testIssue523UnreadableEditCandidateDoesNotHideLaterUsableMenuControl() async throws {
    // Source mutation applied once: return `.menuUnreadable` from the bottom Edit action-list
    // failure. That stops before the toolbar candidate and fails this State-A/AXShowMenu proof.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        bottomEditActionNamesReadFails: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
    ) == 1)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.actions.pidKeyEventCount == 0)
}

@Test func testIssue523FailedPostWriteMarkerReadsCannotManufactureAnEmptyStateA() async throws {
    // Source mutation applied once: in the settled survivor loop, replace the post-write
    // `case .failure` State-B return with `reading = []`. This fixture's stale AXPick leaves the
    // only marker in place; the mutation settles the fabricated empty set and returns State A.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsReadFails: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(writeAttempted)
    let unreadable = try #require(envelope["readback_unreadable"] as? Bool)
    #expect(unreadable)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.markerCount == 1)
}

@Test func testIssue523PostWriteUnreadableRowCellsCannotManufactureAnEmptyStateA() async throws {
    // Source mutation applied once: change the incomplete-row `cells.count < 3` return to
    // `continue`. The surviving unreadable row is then silently skipped twice and manufactures a
    // vacuous State A; the restored reader returns this State B.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowCellsReadNoValue: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(try #require(envelope["write_attempted"] as? Bool))
    #expect(try #require(envelope["readback_unreadable"] as? Bool))
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.markerCount == 1)
}

@Test func testIssue523MenuClosingAfterFirstSightingMakesAXPickANoOp() async throws {
    // This models the narrower stale-element race: the first scoped AX read sees the menu, then it
    // closes before AXPick. The pick remains an attempted actuator, but cannot certify a deletion.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuClosesAfterFirstSighting: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    // Mutation: replace the survivor-set readback proof with `true`. The stale AXPick leaves all
    // three rows present, so that mutation manufactures State A and fails these State-B/count
    // assertions.
    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(writeAttempted)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523ExpectedMenuChildrenAbsenceStatusesSettleAsAbsent() async throws {
    for status in [Int32(-25205), Int32(-25212)] {
        let fixture = issue523MarkerDeleteFixture(
            menuEntryTitle: nil,
            menuChildrenAbsenceStatus: status
        )
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

        // Mutation: pass every non-success AXChildren status through as unreadable. These two
        // documented absence answers would be reported as `menu_unreadable`, so the route-state
        // assertion fails.
        #expect(!result.isSuccess)
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
        #expect(!writeAttempted)
        #expect(safeToRetry)
        #expect(fixture.actions.keyEventCount == 0)
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
        // (the Japanese move-and-delete label). That issues AXPick here, so the State-C/no-pick
        // assertions fail instead of merely checking a LabelSet in isolation.
        #expect(!result.isSuccess)
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
        #expect(fixture.actions.actionCount(
            elementID: fixture.menuEntryID, action: kAXPickAction as String
        ) == 0)
        #expect(fixture.actions.keyEventCount == 0)
    }
}

@Test func testIssue523MissingDeleteEntryDismissesObservedMenuAndRefuses() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: "Copy")
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: remove the `dismissMarkerListEditMenu` call from the missing-entry branch. The
    // AXCancel and closed-menu assertions fail, proving this no-write refusal restores the menu
    // when AX can do so.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
    #expect(try #require(envelope["hint"] as? String).contains("missing or disabled"))
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(!fixture.menuIsOpen)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523DisabledDeleteEntryDismissesObservedMenuAndRefuses() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: "Delete", menuEntryEnabled: false)
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: remove the `dismissMarkerListEditMenu` call from the disabled-entry branch. The
    // AXCancel and closed-menu assertions fail, proving a disabled entry is never picked.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(!fixture.menuIsOpen)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523CancelFailureNeverEscalatesToAGlobalKey() async throws {
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
        let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

        // Mutation: restore the former Escape cleanup after AXCancel fails. The fixture records
        // that key post, so the no-key invariant fails.
        #expect(!result.isSuccess)
        #expect(envelope["state"] as? String == "C")
        #expect(!writeAttempted)
        #expect(safeToRetry)
        #expect(fixture.menuIsOpen)
        #expect(fixture.actions.keyEventCount == 0)
    }
}

@Test func testIssue523UnreadableMenuClosureStillRefusesWithoutAKey() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDismissesOnCancel: false,
        menuChildrenReadFailsAfterCancel: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

    // Mutation: restore the former Escape cleanup after the unreadable AXCancel observation. The
    // fixture records that post, so the no-key assertion fails.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(safeToRetry)
    #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523MenuThatIgnoresAXCancelStillRefusesWithoutDelete() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDismissesOnCancel: false
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

    // Mutation: restore the former Escape cleanup after AXCancel fails. The fixture records that
    // global key post, so the no-key assertion fails.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(safeToRetry)
    #expect(fallbackUnsafe)
    #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
}

@Test func testIssue523UnreadableMenuDiscoveryRefusesAfterObservedDismissal() async throws {
    // Every poll fails, not just the first. A single failed read is no longer final: measured on
    // Logic 12.3 a scoped child read can answer -25200 on one poll and answer normally on the next
    // while other reads in the same call succeed, so taking the first failure as the answer made
    // this route refuse intermittently while the menu was open. Persistent unreadability is still
    // unreadable, and must never be flattened into "the menu is absent".
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDiscoveryReadAlwaysFails: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

    // Source mutations applied once: send AXCancel to the control without first checking its action
    // names, and separately discard the persistent poll's raw AX status. This control advertises
    // only AXShowMenu, so the speculative cancel-call assertion fails; its status assertion also
    // fails when the poll's unreadable status is lost.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(fallbackUnsafe)
    #expect(envelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(envelope["edit_menu_route_ax_status"] as? Int == Int(AXError.apiDisabled.rawValue))
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(envelope["menu_cancel_action_state"] as? String == "not_advertised")
    #expect(try #require(envelope["hint"] as? String).contains("could not be read"))
    // The menu element was never observed, and the bound control does not advertise AXCancel, so
    // cleanup must not invent an unsupported control-specific action.
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXCancelAction as String
    ) == 0)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.actions.pidKeyEventCount == 0)
}

@Test func testIssue523UnknownMenuDiscoveryCancelsOnlyAnAdvertisingControl() async throws {
    // Source mutation applied once: make the AXCancel action-list membership condition false.
    // The advertised control then receives no cancel action and fails this one-action assertion.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDiscoveryReadAlwaysFails: true,
        toolbarEditAdvertisesCancel: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(envelope["menu_cancel_action_state"] as? String == "advertised_and_issued")
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXCancelAction as String
    ) == 1)
    #expect(fixture.actions.keyEventCount == 0)
    #expect(fixture.actions.pidKeyEventCount == 0)
}

@Test func testIssue523RejectsAWindowMenuThatIsNotBoundToToolbarEdit() async throws {
    let fixture = issue523MarkerDeleteFixture(menuEntryTitle: "Delete", menuBoundToToolbar: false)
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: restore the window-wide AXMenu fallback. It AXPick's this unrelated Delete entry,
    // so the route-refusal and exact-entry no-pick assertions both fail.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.actions.keyEventCount == 0)
}
