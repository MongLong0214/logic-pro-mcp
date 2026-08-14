@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

private final class Issue523ActionLog: @unchecked Sendable {
    private var actions: [(elementID: Int, action: String)] = []

    func recordAction(elementID: Int, action: String) {
        actions.append((elementID, action))
    }

    func actionCount(elementID: Int, action: String) -> Int {
        actions.filter { $0.elementID == elementID && $0.action == action }.count
    }

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
    var postWriteRowsReadFailureWasObserved = false
    var postWriteAXRowsReadFailuresRemaining = 0
    var postWriteAXRowsReadFailureStatus = AXError.cannotComplete.rawValue
    var postWriteAXRowsReadFailurePersists = false
    var postWriteAXRowsReadFailureCount = 0
    var postWriteAXRowsReadFailureWasObserved = false
    var postWriteAXRowsReadRecoveredAfterFailure = false
    var postWriteAXRowsRecoveredReadCount = 0
    var postWriteRowsReadEmpty = false
    var postWriteRowsDropIndex: Int?
    var postWriteRowsSubstituteIndex: Int?
    var postWriteRowsEmptyReadWasObserved = false
    var postWriteStructuralCorroborationWasObserved = false
    var postWriteStructuralChildrenReadFailuresRemaining = 0
    var postWriteStructuralChildrenReadFailureStatus = AXError.cannotComplete.rawValue
    var postWriteStructuralChildrenReadFailurePersists = false
    var postWriteStructuralChildrenReadFailureCount = 0
    var postWriteStructuralChildrenReadFailureWasObserved = false
    var postWriteStructuralChildrenReadRecoveredAfterFailure = false
    var postWriteStructuralChildrenRecoveredReadCount = 0
    var postWriteRowsDropReadWasObserved = false
    var postWriteRowsSubstituteReadWasObserved = false
    var postWriteRowRolesBecomeNonRows = false
    var postWriteRowRoleChangeWasObserved = false
    var postWriteRowCellsReadNoValue = false
    var postWriteRowCellsFailureWasObserved = false
    var postWriteRowCellsNoValueReadCount = 0
    var postWriteRowCellsInvalidReadFailuresRemaining = 0
    var postWriteRowCellsInvalidReadFailureCount = 0
    var postWriteRowCellsInvalidReadWasObserved = false
    var postWriteRowCellsReadRecoveredAfterInvalid = false
    var postWriteRowCellsRecoveredReadCount = 0
    var postWriteRowCellsInvalidReadPersists = false
    var postWriteRowsNeverSettle = false
    var postWriteRowsNeverSettleReadCount = 0
    var postWriteRowsNeverSettleWasObserved = false
    var rowSelectionWasWritten = false
    var selectedRowsReadFailsAfterSelection = false
    var selectionChangesAfterSelectWrite = false
    var selectionChangesAfterFinalSelectionCheckBeforePick = false
    var selectionChangeBetweenConfirmationAndPickWasObserved = false
    var selectionUnreadableBeforePick = false
    var selectedRowsReadFailsAfterShowMenu = false
    var selectedRowID: Int?
    var showMenuWasRequested = false
    var menuWasDismissed = false
    var menuCancelWasIssued = false
    var toolbarMenuReadCount = 0
    var toolbarAbsenceObservationCount = 0
    var closesAfterFirstSighting = false
    var menuChildrenReadFailsBetweenAbsences = false
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
    let readMarkerCount: () -> Int
    let readMarkerNames: () -> [String]
    let readSelectedMarkerName: () -> String?

    var menuIsOpen: Bool { menuState.isOpen }
    var markerCount: Int { readMarkerCount() }
    var markerNames: [String] { readMarkerNames() }
    var selectedMarkerName: String? { readSelectedMarkerName() }
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
    menuChildrenReadFailsBetweenAbsences: Bool = false,
    editControlTitle: String = "編集",
    toolbarEditAdvertisesCancel: Bool = false,
    selectionConfirms: Bool = true,
    selectedRowsReadFailsAfterSelection: Bool = false,
    selectionChangesAfterSelectWrite: Bool = false,
    selectionChangesAfterFinalSelectionCheckBeforePick: Bool = false,
    selectionUnreadableBeforePick: Bool = false,
    pickDeletesSelectedRow: Bool = true,
    postWriteRowsReadFails: Bool = false,
    postWriteAXRowsReadFailures: Int = 0,
    postWriteAXRowsReadFailureStatus: Int32 = AXError.cannotComplete.rawValue,
    postWriteAXRowsReadFailurePersists: Bool = false,
    postWriteRowsReadEmpty: Bool = false,
    postWriteRowsDropIndex: Int? = nil,
    postWriteRowsSubstituteIndex: Int? = nil,
    postWriteRowRolesBecomeNonRows: Bool = false,
    postWriteStructuralChildrenReadFailures: Int = 0,
    postWriteStructuralChildrenReadFailureStatus: Int32 = AXError.cannotComplete.rawValue,
    postWriteStructuralChildrenReadFailurePersists: Bool = false,
    postWriteRowCellsReadNoValue: Bool = false,
    postWriteRowCellsInvalidReadFailures: Int = 0,
    postWriteRowCellsInvalidReadPersists: Bool = false,
    postWriteRowsNeverSettle: Bool = false,
    menuControlDiscoveryReadFails: Bool = false,
    menuActionNamesReadFails: Bool = false,
    bottomEditActionNamesReadFails: Bool = false,
    menuEntryChildrenReadFails: Bool = false,
    menuEntryEnabledReadFails: Bool = false,
    menuChildrenAbsenceStatusAfterCancel: Int32? = nil,
    menuUnrelatedEntryRoleReadFails: Bool = false,
    structuralRowOrder: [Int]? = nil,
    unrelatedEmptyTableBecomesFirstAfterPick: Bool = false,
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
    menuState.menuChildrenReadFailsBetweenAbsences = menuChildrenReadFailsBetweenAbsences
    menuState.selectedRowsReadFailsAfterSelection = selectedRowsReadFailsAfterSelection
    menuState.selectionChangesAfterSelectWrite = selectionChangesAfterSelectWrite
    menuState.selectionChangesAfterFinalSelectionCheckBeforePick = selectionChangesAfterFinalSelectionCheckBeforePick
    menuState.selectionUnreadableBeforePick = selectionUnreadableBeforePick
    let app = builder.element(52_300)
    let arrange = builder.element(52_301)
    let markerList = builder.element(52_302)
    let toolbarEdit = builder.element(52_303)
    let bottomEdit = builder.element(52_304)
    let menu = builder.element(52_305)
    let menuEntry = builder.element(52_306)
    let table = builder.element(52_307)
    let unrelatedTable = builder.element(52_308)
    let unreadableMenuSeparator = builder.element(52_309)

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
        builder.setChildren(menu, menuUnrelatedEntryRoleReadFails ? [unreadableMenuSeparator, menuEntry] : [menuEntry])
    }

    builder.setAttribute(table, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(table, kAXDescriptionAttribute as String, "Marker Table")
    builder.setAttribute(unrelatedTable, kAXRoleAttribute as String, kAXTableRole as String)
    builder.setAttribute(unrelatedTable, "AXRows", [AXUIElement]())
    builder.setChildren(unrelatedTable, [])

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
    // This is deliberately a distinct AX element whose cells can impersonate a real post-write
    // survivor. It lets the fixture model the dangerous same-count lie: AXRows supplies a
    // plausible row payload while the table's own AXChildren retain the real row element.
    let substituteRow = builder.element(98_765)
    let substituteLockCell = builder.element(98_766)
    let substitutePositionCell = builder.element(98_767)
    let substituteNameCell = builder.element(98_768)
    let substitutePosition = builder.element(98_769)
    let substituteName = builder.element(98_770)
    builder.setAttribute(substituteRow, kAXRoleAttribute as String, kAXRowRole as String)
    for cell in [substituteLockCell, substitutePositionCell, substituteNameCell] {
        builder.setAttribute(cell, kAXRoleAttribute as String, kAXCellRole as String)
    }
    builder.setChildren(substitutePositionCell, [substitutePosition])
    builder.setChildren(substituteNameCell, [substituteName])
    builder.setChildren(substituteRow, [substituteLockCell, substitutePositionCell, substituteNameCell])
    @Sendable func makeSubstituteRowReadLike(_ source: AXUIElement) {
        guard let index = rows.firstIndex(where: { CFEqual($0, source) }) else { return }
        builder.setAttribute(substitutePosition, kAXDescriptionAttribute as String, markers[index].position)
        builder.setAttribute(substituteName, kAXDescriptionAttribute as String, markers[index].name)
    }
    builder.setAttribute(table, "AXRows", rows)
    let structuralRows = structuralRowOrder.map { $0.map { rows[$0] } } ?? rows
    builder.setChildren(table, structuralRows)
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
                menuState.selectedRowID = builder.elementID(element)
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
                menuState.toolbarAbsenceObservationCount = 0
                if menuState.selectionUnreadableBeforePick {
                    // The pre-pick re-confirmation read fails from here on. A failed read is not a
                    // readable "something else is selected"; the receipt must keep them apart.
                    menuState.selectedRowsReadFailsAfterShowMenu = true
                }
                if menuState.selectionChangesAfterSelectWrite, rows.indices.contains(1) {
                    // Model an external selection change after this operation wrote AXSelected but
                    // before the menu's AXPick. The real command deletes this CURRENT selected row.
                    builder.setAttribute(table, "AXSelectedRows", [rows[1]])
                    menuState.selectedRowID = builder.elementID(rows[1])
                }
                if menuEntryTitle != nil, menuBoundToToolbar {
                    menuState.discoveryReadFailsOnce = menuDiscoveryReadFails
                    menuState.discoveryReadAlwaysFails = menuDiscoveryReadAlwaysFails
                    menuState.isOpen = true
                    builder.setChildren(toolbarEdit, menuState.isOpen ? [menu] : [])
                }
                return true
            }
            if action == (kAXCancelAction as String), elementID == menuID {
                menuState.menuCancelWasIssued = true
                if menuDismissesOnCancel {
                    menuState.isOpen = false
                    menuState.menuWasDismissed = true
                    builder.setChildren(toolbarEdit, [])
                }
                if menuChildrenReadFailsAfterCancel {
                    menuState.childrenReadFails = true
                }
                return true
            }
            if action == (kAXPickAction as String), elementID == entryID {
                // A menu that closed after observation has no live target for AXPick. Model the
                // stale action as a no-op instead of manufacturing a successful deletion.
                guard menuState.isOpen else {
                    menuState.postWriteRowsReadFails = postWriteRowsReadFails
                    menuState.postWriteAXRowsReadFailuresRemaining = postWriteAXRowsReadFailures
                    menuState.postWriteAXRowsReadFailureStatus = postWriteAXRowsReadFailureStatus
                    menuState.postWriteAXRowsReadFailurePersists = postWriteAXRowsReadFailurePersists
                    menuState.postWriteRowsReadEmpty = postWriteRowsReadEmpty
                    menuState.postWriteRowsDropIndex = postWriteRowsDropIndex
                    menuState.postWriteRowsSubstituteIndex = postWriteRowsSubstituteIndex
                    menuState.postWriteRowRolesBecomeNonRows = postWriteRowRolesBecomeNonRows
                    menuState.postWriteStructuralChildrenReadFailuresRemaining = postWriteStructuralChildrenReadFailures
                    menuState.postWriteStructuralChildrenReadFailureStatus = postWriteStructuralChildrenReadFailureStatus
                    menuState.postWriteStructuralChildrenReadFailurePersists = postWriteStructuralChildrenReadFailurePersists
                    menuState.postWriteRowCellsReadNoValue = postWriteRowCellsReadNoValue
                    menuState.postWriteRowCellsInvalidReadFailuresRemaining = postWriteRowCellsInvalidReadFailures
                    menuState.postWriteRowCellsInvalidReadPersists = postWriteRowCellsInvalidReadPersists
                    menuState.postWriteRowsNeverSettle = postWriteRowsNeverSettle
                    return false
                }
                if menuState.selectionChangesAfterFinalSelectionCheckBeforePick,
                   rows.indices.contains(1) {
                    // There is no AX primitive that atomically joins the final AXSelectedRows read
                    // to AXPick. Fire this seam at the start of the pick so it is strictly after
                    // the route's last successful confirmation and before Delete observes selection.
                    menuState.selectionChangeBetweenConfirmationAndPickWasObserved = true
                    builder.setAttribute(table, "AXSelectedRows", [rows[1]])
                    menuState.selectedRowID = builder.elementID(rows[1])
                }
                // AX reports failure despite delivering it. Delete exactly the AXSelected row so
                // fixtures can distinguish AXRows order from structural-descendant order.
                if pickDeletesSelectedRow,
                   let selectedRow = (AXHelpers.getAttribute(
                       table, "AXSelectedRows", runtime: builder.makeAXRuntime()
                   ) as [AXUIElement]?)?.first {
                    let currentRows: [AXUIElement] = AXHelpers.getAttribute(
                        table, "AXRows", runtime: builder.makeAXRuntime()
                    ) ?? []
                    let afterPick = currentRows.filter { !CFEqual($0, selectedRow) }
                    builder.setAttribute(table, "AXRows", afterPick)
                    builder.setChildren(table, afterPick)
                }
                if let substituteIndex = postWriteRowsSubstituteIndex,
                   let currentRows: [AXUIElement] = AXHelpers.getAttribute(
                       table, "AXRows", runtime: builder.makeAXRuntime()
                   ),
                   currentRows.indices.contains(substituteIndex) {
                    makeSubstituteRowReadLike(currentRows[substituteIndex])
                }
                if unrelatedEmptyTableBecomesFirstAfterPick {
                    builder.setChildren(markerList, [unrelatedTable, bottomEdit, toolbarEdit, table])
                }
                menuState.postWriteRowsReadFails = postWriteRowsReadFails
                menuState.postWriteAXRowsReadFailuresRemaining = postWriteAXRowsReadFailures
                menuState.postWriteAXRowsReadFailureStatus = postWriteAXRowsReadFailureStatus
                menuState.postWriteAXRowsReadFailurePersists = postWriteAXRowsReadFailurePersists
                menuState.postWriteRowsReadEmpty = postWriteRowsReadEmpty
                menuState.postWriteRowsDropIndex = postWriteRowsDropIndex
                menuState.postWriteRowsSubstituteIndex = postWriteRowsSubstituteIndex
                menuState.postWriteRowRolesBecomeNonRows = postWriteRowRolesBecomeNonRows
                menuState.postWriteStructuralChildrenReadFailuresRemaining = postWriteStructuralChildrenReadFailures
                menuState.postWriteStructuralChildrenReadFailureStatus = postWriteStructuralChildrenReadFailureStatus
                menuState.postWriteStructuralChildrenReadFailurePersists = postWriteStructuralChildrenReadFailurePersists
                menuState.postWriteRowCellsReadNoValue = postWriteRowCellsReadNoValue
                menuState.postWriteRowCellsInvalidReadFailuresRemaining = postWriteRowCellsInvalidReadFailures
                menuState.postWriteRowCellsInvalidReadPersists = postWriteRowCellsInvalidReadPersists
                menuState.postWriteRowsNeverSettle = postWriteRowsNeverSettle
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
                if (menuState.postWriteStructuralChildrenReadFailuresRemaining > 0
                    || menuState.postWriteStructuralChildrenReadFailurePersists),
                   builder.elementID(element) == builder.elementID(table) {
                    menuState.postWriteStructuralChildrenReadFailureWasObserved = true
                    menuState.postWriteStructuralChildrenReadFailureCount += 1
                    if menuState.postWriteStructuralChildrenReadFailuresRemaining > 0 {
                        menuState.postWriteStructuralChildrenReadFailuresRemaining -= 1
                    }
                    return .failure(AXHelpers.AXStatusError(
                        raw: menuState.postWriteStructuralChildrenReadFailureStatus
                    ))
                }
                if menuState.postWriteStructuralChildrenReadFailureCount > 0,
                   builder.elementID(element) == builder.elementID(table) {
                    menuState.postWriteStructuralChildrenReadRecoveredAfterFailure = true
                    menuState.postWriteStructuralChildrenRecoveredReadCount += 1
                }
                if menuState.postWriteRowsReadFails,
                   builder.elementID(element) == builder.elementID(table) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.postWriteRowCellsReadNoValue,
                   rows.contains(where: { CFEqual(element, $0) }) {
                    menuState.postWriteRowCellsFailureWasObserved = true
                    menuState.postWriteRowCellsNoValueReadCount += 1
                    return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
                }
                if (menuState.postWriteRowCellsInvalidReadFailuresRemaining > 0
                    || menuState.postWriteRowCellsInvalidReadPersists),
                   rows.contains(where: { CFEqual(element, $0) }) {
                    menuState.postWriteRowCellsInvalidReadWasObserved = true
                    menuState.postWriteRowCellsInvalidReadFailureCount += 1
                    if menuState.postWriteRowCellsInvalidReadFailuresRemaining > 0 {
                        menuState.postWriteRowCellsInvalidReadFailuresRemaining -= 1
                    }
                    return .failure(AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue))
                }
                if menuState.postWriteRowCellsInvalidReadFailureCount > 0,
                   rows.contains(where: { CFEqual(element, $0) }) {
                    menuState.postWriteRowCellsReadRecoveredAfterInvalid = true
                    menuState.postWriteRowCellsRecoveredReadCount += 1
                }
                if menuState.postWriteRowsReadEmpty,
                   builder.elementID(element) == builder.elementID(table) {
                    menuState.postWriteStructuralCorroborationWasObserved = true
                }
                if menuState.postWriteRowsNeverSettle,
                   builder.elementID(element) == builder.elementID(table) {
                    // Match the AXRows value from this loop turn, but alternate it on every
                    // turn. Both inventory sources answer successfully, so the production loop
                    // must report its real non-convergence instead of inventing an AX status.
                    let currentRows = (baseRuntime.ax.attributeValue(table, "AXRows")
                        as? [AXUIElement]) ?? []
                    let alternatingRows = menuState.postWriteRowsNeverSettleReadCount.isMultiple(of: 2)
                        ? Array(currentRows.dropLast())
                        : currentRows
                    return .success(alternatingRows)
                }
                if let menuChildrenAbsenceStatusAfterCancel,
                   menuState.menuCancelWasIssued,
                   builder.elementID(element) == toolbarEditID {
                    return .failure(AXHelpers.AXStatusError(raw: menuChildrenAbsenceStatusAfterCancel))
                }
                if builder.elementID(element) == toolbarEditID,
                   menuState.showMenuWasRequested,
                   let menuChildrenAbsenceStatus {
                    return .failure(AXHelpers.AXStatusError(raw: menuChildrenAbsenceStatus))
                }
                if menuState.menuChildrenReadFailsBetweenAbsences,
                   builder.elementID(element) == toolbarEditID,
                   menuState.showMenuWasRequested,
                   !menuState.isOpen {
                    menuState.toolbarAbsenceObservationCount += 1
                    if menuState.toolbarAbsenceObservationCount % 2 == 0 {
                        return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                    }
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
                if menuState.selectedRowsReadFailsAfterSelection,
                   menuState.rowSelectionWasWritten,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXSelectedRows" {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.selectedRowsReadFailsAfterShowMenu,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXSelectedRows" {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                if (menuState.postWriteAXRowsReadFailuresRemaining > 0
                    || menuState.postWriteAXRowsReadFailurePersists),
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    menuState.postWriteAXRowsReadFailureWasObserved = true
                    menuState.postWriteAXRowsReadFailureCount += 1
                    if menuState.postWriteAXRowsReadFailuresRemaining > 0 {
                        menuState.postWriteAXRowsReadFailuresRemaining -= 1
                    }
                    return .failure(AXHelpers.AXStatusError(
                        raw: menuState.postWriteAXRowsReadFailureStatus
                    ))
                }
                if menuState.postWriteAXRowsReadFailureCount > 0,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    menuState.postWriteAXRowsReadRecoveredAfterFailure = true
                    menuState.postWriteAXRowsRecoveredReadCount += 1
                }
                if menuState.postWriteRowsReadFails,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    menuState.postWriteRowsReadFailureWasObserved = true
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.postWriteRowsNeverSettle,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    menuState.postWriteRowsNeverSettleWasObserved = true
                    menuState.postWriteRowsNeverSettleReadCount += 1
                    let currentRows = (baseRuntime.ax.attributeValue(table, "AXRows")
                        as? [AXUIElement]) ?? []
                    let alternatingRows = menuState.postWriteRowsNeverSettleReadCount.isMultiple(of: 2)
                        ? Array(currentRows.dropLast())
                        : currentRows
                    return .success(alternatingRows as NSArray)
                }
                if menuState.postWriteRowsReadEmpty,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    // A SUCCESSFUL empty array while the table's children still hold the row.
                    menuState.postWriteRowsEmptyReadWasObserved = true
                    return .success([] as NSArray)
                }
                if let dropIndex = menuState.postWriteRowsDropIndex,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows",
                   dropIndex < rows.count {
                    // A SUCCESSFUL but TRUNCATED array: `AXRows` drops the row while the table's
                    // children still hold it. Same AX lie as the empty case, only not `[]`.
                    menuState.postWriteRowsDropReadWasObserved = true
                    var truncated = rows
                    truncated.remove(at: dropIndex)
                    return .success(truncated as NSArray)
                }
                if let substituteIndex = menuState.postWriteRowsSubstituteIndex,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows",
                   let currentRows: [AXUIElement] = AXHelpers.getAttribute(
                       table, "AXRows", runtime: builder.makeAXRuntime()
                   ),
                   currentRows.indices.contains(substituteIndex) {
                    // A matching post-write count is not evidence that AXRows contains the same
                    // row elements as the table's structural children. The foreign row is fully
                    // readable and carries the real survivor's position/name payload.
                    menuState.postWriteRowsSubstituteReadWasObserved = true
                    var substituted = currentRows
                    substituted[substituteIndex] = substituteRow
                    return .success(substituted as NSArray)
                }
                if menuState.postWriteRowRolesBecomeNonRows,
                   rows.contains(where: { CFEqual(element, $0) }),
                   attribute == kAXRoleAttribute as String {
                    // A rebuilding table can still expose child elements while none reports AXRow.
                    // This is not a readable empty structural list; the test asserts this seam fired.
                    menuState.postWriteRowRoleChangeWasObserved = true
                    return .success(kAXGroupRole as NSString)
                }
                if menuState.menuEntryEnabledReadFails,
                   builder.elementID(element) == entryID,
                   attribute == kAXEnabledAttribute as String {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuUnrelatedEntryRoleReadFails,
                   builder.elementID(element) == builder.elementID(unreadableMenuSeparator),
                   attribute == kAXRoleAttribute as String {
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
        postKeyEvent: { _ in false },
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
        readMarkerCount: {
            AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).count
        },
        readMarkerNames: {
            AXHelpers.getChildren(table, runtime: builder.makeAXRuntime()).compactMap { row in
                guard let index = rows.firstIndex(where: { CFEqual($0, row) }) else { return nil }
                return markers[index].name
            }
        },
        readSelectedMarkerName: {
            guard let selectedRowID = menuState.selectedRowID,
                  let selectedIndex = rows.firstIndex(where: {
                      builder.elementID($0) == selectedRowID
                  }) else { return nil }
            return markers[selectedIndex].name
        }
    )
}

private func issue523Envelope(_ result: ChannelResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
}

@Test func testIssue523AXRowsInventorySelectsTheMarkerNamedByRequestedIndex() async throws {
    // Source mutation applied once: replace the carried `inventory.rows[index]` target with the
    // reverse structural order. This fixture then selects Other instead of Target and fails the
    // target-selection and State-A proof below.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        structuralRowOrder: [1, 0],
        markers: [
            ("1 1 1 1", "Target"),
            ("9 1 1 1", "Other"),
        ]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(fixture.selectedMarkerName == "Target")
    #expect(fixture.markerCount == 1)
}

@Test func testIssue523SelectionChangedBeforeAXPickRefusesWithoutDeletingCurrentRow() async throws {
    // Source mutation applied once: remove the `markerListTargetRowIsSelected` switch immediately
    // before AXPick. This fixture then picks Delete after the selection changes from Intro to
    // Verse, removes Verse, and fails the State-C/no-pick/unchanged-marker-count proof below.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        selectionChangesAfterSelectWrite: true,
        pickDeletesSelectedRow: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "ax_write_failed")
    #expect(envelope["edit_menu_route_state"] as? String == "target_selection_changed_before_pick")
    #expect(envelope["target_selection_before_pick"] as? String == "changed")
    #expect(!writeAttempted)
    #expect(safeToRetry)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523SelectionCanChangeAfterFinalConfirmationAndReportsPossibleWrongDelete() async throws {
    // AX provides no atomic select-and-pick. This fixture changes the application selection at the
    // start of AXPick, after the route's final successful AXSelectedRows confirmation. Delete
    // therefore removes Other while the requested Target survives; the route cannot claim State A
    // and must say plainly that a different marker may have been deleted.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        selectionChangesAfterFinalSelectionCheckBeforePick: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Other")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(envelope["reason_detail"] as? String == "The settled survivor set differs from the requested target; a different marker may have been deleted.")
    #expect(fixture.menuState.selectionChangeBetweenConfirmationAndPickWasObserved)
    #expect(fixture.markerNames == ["Target"])
    #expect(envelope["expected_survivors"] as? [String] == ["5:Other7:5.1.1.1"])
    #expect(envelope["observed_survivors"] as? [String] == ["6:Target7:1.1.1.1"])
}

@Test func testIssue523UnreadableSelectionBeforePickIsNotAChangedSelection() async throws {
    // The re-confirmation immediately before AXPick has two distinct negative answers, and the
    // route reports them separately: the target is no longer the sole selection, or the selection
    // could not be read at all. Both refuse, so a test that only checks "it refused" cannot tell
    // them apart — and collapsing the unreadable case into "changed" is the substitution this
    // branch exists to stop.
    //
    // Mutation: return `.success(false)` from `markerListTargetRowIsSelected` on a failed read.
    // The refusal still happens, so only the route state and the AX status below can catch it.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        selectionUnreadableBeforePick: true,
        pickDeletesSelectedRow: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(!result.isSuccess)
    #expect(envelope["edit_menu_route_state"] as? String == "target_selection_unreadable_before_pick")
    #expect(envelope["target_selection_ax_status_before_pick"] as? Int == Int(AXError.cannotComplete.rawValue))
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523UnreadableSelectedRowsConfirmationIsNotAnEmptySelection() async throws {
    // Source mutation applied once: replace the post-write AXSelectedRows `.failure` result with
    // the successful empty array used for a genuinely empty selection. The refusal then loses its
    // readback-unavailable error, unreadable state, and raw AX status, failing this receipt proof.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        selectedRowsReadFailsAfterSelection: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["error"] as? String == "readback_unavailable")
    #expect(envelope["selection_state"] as? String == "unreadable")
    #expect(envelope["selection_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(!writeAttempted)
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
    ) == 0)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
}

@Test func testIssue523PostWriteReadbackStaysBoundToPrewriteTable() async throws {
    // Source mutation applied once: replace the table-bound post-write reader with
    // `enumerateMarkersFromListWindow(window, ...)`. The new first empty table then fabricates
    // this State A even though the original marker table still contains Target.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        unrelatedEmptyTableBecomesFirstAfterPick: true,
        markers: [("1 1 1 1", "Target")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(fixture.markerCount == 1)
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
        #expect(envelope["prewrite_marker_identities"] as? [String] == [
            "5:Intro7:1.1.1.1", "5:Verse7:5.1.1.1", "6:Chorus7:9.1.1.1",
        ])
        #expect(fixture.actions.actionCount(
            elementID: fixture.menuEntryID, action: kAXPickAction as String
        ) == 1)
        #expect(fixture.actions.actionCount(
            elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
        ) == 1)
        #expect(fixture.actions.actionCount(
            elementID: fixture.bottomEditID, action: kAXPressAction as String
        ) == 0)
        #expect(!fixture.menuIsOpen)
    }
}

@Test func testIssue523UnclosedMenuObservationDoesNotDiscardSettledBoundTableProof() async throws {
    // AXPick deletes the target and AXCancel closes the menu, but the scoped child reads fail
    // after that close. The run therefore cannot observe the closure even though no menu remains.
    // That uncertainty makes a retry unsafe; it does not make the separately bound
    // AXRows/AXChildren inventory unreadable. The two settled post-write readings still prove the
    // requested row disappeared.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuChildrenReadFailsAfterCancel: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Mutation: restore the old early State-B return from the
    // `menuCloseWasNotObserved` branch. The AXPick still deletes, but this precise State-A
    // proof becomes unreachable and the test fails.
    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(!(try #require(envelope["safe_to_retry"] as? Bool)))
    #expect(try #require(envelope["fallback_unsafe"] as? Bool))
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["marker_count_after"] as? Int == 2)
    #expect(fixture.markerCount == 2)
    #expect(fixture.markerNames == ["Verse", "Chorus"])
    #expect(!fixture.menuIsOpen)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
}

@Test func testIssue523ObservedMenuWithAbsentChildrenAfterCancelIsNotConfirmedClosed() async throws {
    // Source mutation applied once: in the `observedMenuClosure` branch, return `.success(nil)`
    // for attributeUnsupported/noValue. The ignored AXCancel then falsely reports this open menu
    // as closed and fails the unsafe-retry/menu-state assertions.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Copy",
        menuDismissesOnCancel: false,
        menuChildrenAbsenceStatusAfterCancel: AXError.attributeUnsupported.rawValue
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(fixture.menuIsOpen)
}

@Test func testIssue523UnreadableUnrelatedMenuEntryDoesNotHideDelete() async throws {
    // Source mutation applied once: return the separator role-read failure directly from
    // `markerListDeleteMenuItem`. That stops before the valid Delete item and fails this
    // State-A/AXPick proof.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuUnrelatedEntryRoleReadFails: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
}

@Test func testIssue523UnlocalizedEditMenuRefusesWithoutAnotherDestructiveActuator() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Supprimer",
        editControlTitle: "Modifier"
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)

    // Source mutation applied once: return `.pickIssued(menuCloseWasNotObserved: false)` from the
    // settled `.menuAbsent` branch. That falsely claims a destructive route was issued, so this
    // State-C/write/no-AXPick proof fails.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
    #expect(try #require(envelope["hint"] as? String).contains("not available"))
    #expect(!writeAttempted)
    #expect(safeToRetry)
    #expect(HonestContract.isFallbackUnsafeStateC(result.message))
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
    ) == 0)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.actions.actionCount(
        elementID: fixture.bottomEditID, action: kAXPressAction as String
    ) == 0)
}

@Test func testIssue523UnreadableMenuReadsAreReportedWithoutAnotherDestructiveActuator() async throws {
    // Source mutation applied once: drop the unreadable error while building either the menu-entry
    // or AXEnabled route outcome. Their `edit_menu_route_ax_status` assertions then fail rather
    // than leaving an advertised unreadable route without its raw AX diagnosis.
    let controlFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuControlDiscoveryReadFails: true
    )
    let actionFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuActionNamesReadFails: true
    )
    let entryFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuEntryChildrenReadFails: true
    )
    let enabledFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        menuEntryEnabledReadFails: true
    )

    let controlResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: controlFixture.runtime, mouse: controlFixture.mouse
    )
    let actionResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: actionFixture.runtime, mouse: actionFixture.mouse
    )
    let entryResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: entryFixture.runtime, mouse: entryFixture.mouse
    )
    let enabledResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: enabledFixture.runtime, mouse: enabledFixture.mouse
    )
    let controlEnvelope = try issue523Envelope(controlResult)
    let actionEnvelope = try issue523Envelope(actionResult)
    let entryEnvelope = try issue523Envelope(entryResult)
    let enabledEnvelope = try issue523Envelope(enabledResult)

    #expect(!controlResult.isSuccess)
    #expect(!actionResult.isSuccess)
    #expect(!entryResult.isSuccess)
    #expect(!enabledResult.isSuccess)
    #expect(controlEnvelope["state"] as? String == "C")
    #expect(actionEnvelope["state"] as? String == "C")
    #expect(entryEnvelope["state"] as? String == "C")
    #expect(enabledEnvelope["state"] as? String == "C")
    #expect(controlEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(actionEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(entryEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(enabledEnvelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(controlEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(actionEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(entryEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(enabledEnvelope["edit_menu_route_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(!(try #require(controlEnvelope["write_attempted"] as? Bool)))
    #expect(!(try #require(actionEnvelope["write_attempted"] as? Bool)))
    #expect(!(try #require(entryEnvelope["write_attempted"] as? Bool)))
    #expect(!(try #require(enabledEnvelope["write_attempted"] as? Bool)))
    #expect(controlFixture.actions.actionCount(
        elementID: controlFixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(actionFixture.actions.actionCount(
        elementID: actionFixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(entryFixture.actions.actionCount(
        elementID: entryFixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(enabledFixture.actions.actionCount(
        elementID: enabledFixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
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
}

@Test func testIssue523PostWriteReadbackFailureReceiptNamesTheActualSiteAndStatus() async throws {
    // Mutation A: replace the `ax_rows` receipt binding with `structural_children`. This first
    // fixture still returns State B, but it must fail the exact-site assertion below. The boolean
    // proves the fixture fired on the live AXRows call rather than a later structural read.
    let axRowsFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsReadFails: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let axRowsResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: axRowsFixture.runtime, mouse: axRowsFixture.mouse
    )
    let axRowsEnvelope = try issue523Envelope(axRowsResult)

    #expect(axRowsResult.isSuccess)
    #expect(axRowsEnvelope["state"] as? String == "B")
    #expect(axRowsEnvelope["reason"] as? String == "readback_unavailable")
    #expect(axRowsEnvelope["readback_failure_site"] as? String == "ax_rows")
    #expect(axRowsEnvelope["readback_ax_status"] as? Int == Int(AXError.failure.rawValue))
    #expect(axRowsEnvelope["readback_ax_status_name"] as? String == "failure")
    #expect(try #require(axRowsEnvelope["readback_unreadable"] as? Bool))
    #expect(axRowsFixture.menuState.postWriteRowsReadFailureWasObserved)
    #expect(axRowsFixture.actions.actionCount(
        elementID: axRowsFixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(axRowsFixture.markerCount == 1)

    // Mutation B: bind a successful AXRows-vs-structural mismatch to `ax_rows` instead. The
    // numeric AX status and the two counts remain plausible, so only their precise association
    // catches that wrong binding. The reader itself creates cannotComplete for this failed
    // corroboration; it is not substituted from any other AX call.
    let structuralFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsReadEmpty: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let structuralResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: structuralFixture.runtime, mouse: structuralFixture.mouse
    )
    let structuralEnvelope = try issue523Envelope(structuralResult)

    #expect(structuralResult.isSuccess)
    #expect(structuralEnvelope["state"] as? String == "B")
    #expect(structuralEnvelope["readback_failure_site"] as? String == "structural_children")
    #expect(structuralEnvelope["readback_ax_status"] as? Int == Int(AXError.cannotComplete.rawValue))
    #expect(structuralEnvelope["readback_ax_status_name"] as? String == "cannotComplete")
    #expect(structuralEnvelope["readback_ax_rows_count"] as? Int == 0)
    #expect(structuralEnvelope["readback_structural_children_count"] as? Int == 1)
    #expect(structuralFixture.menuState.postWriteRowsEmptyReadWasObserved)
    #expect(structuralFixture.menuState.postWriteStructuralCorroborationWasObserved)

    let cellFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowCellsReadNoValue: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let cellResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: cellFixture.runtime, mouse: cellFixture.mouse
    )
    let cellEnvelope = try issue523Envelope(cellResult)

    #expect(cellResult.isSuccess)
    #expect(cellEnvelope["state"] as? String == "B")
    #expect(cellEnvelope["readback_failure_site"] as? String == "cell")
    #expect(cellEnvelope["readback_ax_status"] as? Int == Int(AXError.noValue.rawValue))
    #expect(cellEnvelope["readback_ax_status_name"] as? String == "noValue")
    #expect(cellFixture.menuState.postWriteRowCellsFailureWasObserved)
    // `noValue` is an answer, not a rebuild failure. A terminal State B after the first cell
    // read proves it was not silently retried until the settle budget expired.
    #expect(cellFixture.menuState.postWriteRowCellsNoValueReadCount == 1)

    let settleFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsNeverSettle: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Other")]
    )
    let settleResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: settleFixture.runtime, mouse: settleFixture.mouse
    )
    let settleEnvelope = try issue523Envelope(settleResult)

    #expect(settleResult.isSuccess)
    #expect(settleEnvelope["state"] as? String == "B")
    #expect(settleEnvelope["readback_failure_site"] as? String == "settle_loop")
    // Every AXRows and structural-children read succeeded. An AX-status field here would be a
    // fabrication, so it must be absent rather than borrowed from any prior successful read.
    #expect(settleEnvelope["readback_ax_status"] == nil)
    #expect(settleEnvelope["readback_ax_status_name"] == nil)
    #expect(settleFixture.menuState.postWriteRowsNeverSettleWasObserved)
    #expect(settleFixture.menuState.postWriteRowsNeverSettleReadCount == 6)
}

@Test func testIssue523TransientInvalidMarkerRowCellReadRetiresPollThenSettles() async throws {
    // Mutation proven: make `isTransientMarkerReadbackFailure` return false for `.cell`. The
    // first -25202 then returns State B and fails the State-A expectation below. The cell seam
    // records every injected failure and every later successful row read, so a passing test
    // cannot be a fixture that never reached the live post-write reader.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteRowCellsInvalidReadFailures: 2,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["marker_count_after"] as? Int == 1)
    #expect(envelope["expected_survivor_position_multiset"] as? String == "7:5.1.1.1")
    #expect(envelope["observed_survivor_position_multiset"] as? String == "7:5.1.1.1")
    #expect(try #require(envelope["position_evidence_canonical"] as? Bool))
    #expect(fixture.menuState.postWriteRowCellsInvalidReadWasObserved)
    #expect(fixture.menuState.postWriteRowCellsInvalidReadFailureCount == 2)
    #expect(fixture.menuState.postWriteRowCellsReadRecoveredAfterInvalid)
    // The stale observations cannot combine with the later read: State A still needs two fresh,
    // agreeing successful survivor readings from the bound table.
    #expect(fixture.menuState.postWriteRowCellsRecoveredReadCount == 2)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.markerCount == 1)
    #expect(fixture.markerNames == ["Survivor"])
}

@Test func testIssue523TransientAXRowsReadFailureRetiresPollThenSettles() async throws {
    // Mutation proven: make `isTransientMarkerReadbackFailure` return false for `.axRows`.
    // The first genuine AXRows failure then exits as State B and fails the State-A expectation.
    // Counters prove this seam was armed only after the live AXPick and that two fresh survivor
    // observations, rather than the failed turns, performed the settle.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteAXRowsReadFailures: 2,
        postWriteAXRowsReadFailureStatus: AXError.cannotComplete.rawValue,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["marker_count_after"] as? Int == 1)
    #expect(envelope["expected_survivor_position_multiset"] as? String == "7:5.1.1.1")
    #expect(envelope["observed_survivor_position_multiset"] as? String == "7:5.1.1.1")
    #expect(fixture.menuState.postWriteAXRowsReadFailureWasObserved)
    #expect(fixture.menuState.postWriteAXRowsReadFailureCount == 2)
    #expect(fixture.menuState.postWriteAXRowsReadRecoveredAfterFailure)
    #expect(fixture.menuState.postWriteAXRowsRecoveredReadCount == 2)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.markerCount == 1)
    #expect(fixture.markerNames == ["Survivor"])
}

@Test func testIssue523TransientStructuralChildrenReadFailureRetiresPollThenSettles() async throws {
    // Mutation proven: make `isTransientMarkerReadbackFailure` return false for
    // `.structuralChildren`. The first genuine structural AX failure then exits as State B and
    // fails the State-A expectation. This seam is on the table's live AXChildren call, so it
    // cannot be satisfied by bypassing identity corroboration.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteStructuralChildrenReadFailures: 2,
        postWriteStructuralChildrenReadFailureStatus: AXError.invalidUIElement.rawValue,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["marker_count_after"] as? Int == 1)
    #expect(envelope["expected_survivor_position_multiset"] as? String == "7:5.1.1.1")
    #expect(envelope["observed_survivor_position_multiset"] as? String == "7:5.1.1.1")
    #expect(fixture.menuState.postWriteStructuralChildrenReadFailureWasObserved)
    #expect(fixture.menuState.postWriteStructuralChildrenReadFailureCount == 2)
    #expect(fixture.menuState.postWriteStructuralChildrenReadRecoveredAfterFailure)
    #expect(fixture.menuState.postWriteStructuralChildrenRecoveredReadCount == 2)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.markerCount == 1)
    #expect(fixture.markerNames == ["Survivor"])
}

@Test func testIssue523AXAnswersAndAPIDisabledAreNotRetriedByPostWriteSettle() async throws {
    // Mutation proven: add either answer status or `apiDisabled` to
    // `AXStatusError.isTransientDuringRebuild`. Each corresponding exact-count expectation
    // below fails: answers must keep their semantics, while a disabled API is terminal rather
    // than a rebuild artefact.
    let axRowsAnswerFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteAXRowsReadFailureStatus: AXError.attributeUnsupported.rawValue,
        postWriteAXRowsReadFailurePersists: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let axRowsAnswerResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: axRowsAnswerFixture.runtime, mouse: axRowsAnswerFixture.mouse
    )
    let axRowsAnswerEnvelope = try issue523Envelope(axRowsAnswerResult)

    // `attributeUnsupported` is the table's true answer that AXRows is unavailable. The reader
    // uses its existing structural route for each of the two genuine settle observations.
    #expect(axRowsAnswerResult.isSuccess)
    #expect(axRowsAnswerEnvelope["state"] as? String == "A")
    #expect(try #require(axRowsAnswerEnvelope["readback_settled"] as? Bool))
    #expect(axRowsAnswerFixture.menuState.postWriteAXRowsReadFailureWasObserved)
    #expect(axRowsAnswerFixture.menuState.postWriteAXRowsReadFailureCount == 2)
    #expect(axRowsAnswerFixture.markerNames == ["Survivor"])

    let structuralAnswerFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteStructuralChildrenReadFailureStatus: AXError.noValue.rawValue,
        postWriteStructuralChildrenReadFailurePersists: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let structuralAnswerResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: structuralAnswerFixture.runtime, mouse: structuralAnswerFixture.mouse
    )
    let structuralAnswerEnvelope = try issue523Envelope(structuralAnswerResult)

    #expect(structuralAnswerResult.isSuccess)
    #expect(structuralAnswerEnvelope["state"] as? String == "B")
    #expect(structuralAnswerEnvelope["readback_failure_site"] as? String == "structural_children")
    #expect(structuralAnswerEnvelope["readback_ax_status"] as? Int == Int(AXError.noValue.rawValue))
    #expect(structuralAnswerFixture.menuState.postWriteStructuralChildrenReadFailureWasObserved)
    #expect(structuralAnswerFixture.menuState.postWriteStructuralChildrenReadFailureCount == 1)

    let cellAnswerFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteRowCellsReadNoValue: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let cellAnswerResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: cellAnswerFixture.runtime, mouse: cellAnswerFixture.mouse
    )
    let cellAnswerEnvelope = try issue523Envelope(cellAnswerResult)

    #expect(cellAnswerResult.isSuccess)
    #expect(cellAnswerEnvelope["state"] as? String == "B")
    #expect(cellAnswerEnvelope["readback_failure_site"] as? String == "cell")
    #expect(cellAnswerEnvelope["readback_ax_status"] as? Int == Int(AXError.noValue.rawValue))
    #expect(cellAnswerFixture.menuState.postWriteRowCellsFailureWasObserved)
    #expect(cellAnswerFixture.menuState.postWriteRowCellsNoValueReadCount == 1)

    let apiDisabledFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteAXRowsReadFailureStatus: AXError.apiDisabled.rawValue,
        postWriteAXRowsReadFailurePersists: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let apiDisabledResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: apiDisabledFixture.runtime, mouse: apiDisabledFixture.mouse
    )
    let apiDisabledEnvelope = try issue523Envelope(apiDisabledResult)

    #expect(apiDisabledResult.isSuccess)
    #expect(apiDisabledEnvelope["state"] as? String == "B")
    #expect(apiDisabledEnvelope["readback_failure_site"] as? String == "ax_rows")
    #expect(apiDisabledEnvelope["readback_ax_status"] as? Int == Int(AXError.apiDisabled.rawValue))
    #expect(apiDisabledFixture.menuState.postWriteAXRowsReadFailureWasObserved)
    #expect(apiDisabledFixture.menuState.postWriteAXRowsReadFailureCount == 1)
}

@Test func testIssue523PersistentInvalidMarkerRowCellReadKeepsCellDiagnosticAtBudgetExpiry() async throws {
    // Mutation proven: clear `finalTransientReadbackFailure` in the retry branch. The sixth
    // invalid cell read then reaches the settle-loop fallback and fails the exact-site
    // expectation below. The count proves this fixture consumed, but did not extend, the
    // existing six-poll settle budget.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteRowCellsInvalidReadPersists: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(!(try #require(envelope["readback_settled"] as? Bool)))
    #expect(envelope["readback_failure_site"] as? String == "cell")
    #expect(envelope["readback_ax_status"] as? Int == Int(AXError.invalidUIElement.rawValue))
    #expect(envelope["readback_ax_status_name"] as? String == "invalidUIElement")
    #expect(try #require(envelope["readback_unreadable"] as? Bool))
    #expect(fixture.menuState.postWriteRowCellsInvalidReadWasObserved)
    #expect(fixture.menuState.postWriteRowCellsInvalidReadFailureCount == 6)
    #expect(!fixture.menuState.postWriteRowCellsReadRecoveredAfterInvalid)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.markerCount == 1)
    #expect(fixture.markerNames == ["Survivor"])
}

@Test func testIssue523PersistentAXRowsAndStructuralFailuresKeepLastDiagnosticAtBudgetExpiry() async throws {
    // Mutation proven: clear `finalTransientReadbackFailure` in the retry branch. Both fixtures
    // would then publish `settle_loop` instead of the final genuine AX-failure site below. Six
    // exact injected failures prove the normal budget was consumed rather than extended.
    let axRowsFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteAXRowsReadFailureStatus: AXError.cannotComplete.rawValue,
        postWriteAXRowsReadFailurePersists: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let axRowsResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: axRowsFixture.runtime, mouse: axRowsFixture.mouse
    )
    let axRowsEnvelope = try issue523Envelope(axRowsResult)

    #expect(axRowsResult.isSuccess)
    #expect(axRowsEnvelope["state"] as? String == "B")
    #expect(!(try #require(axRowsEnvelope["readback_settled"] as? Bool)))
    #expect(axRowsEnvelope["readback_failure_site"] as? String == "ax_rows")
    #expect(axRowsEnvelope["readback_ax_status"] as? Int == Int(AXError.cannotComplete.rawValue))
    #expect(axRowsFixture.menuState.postWriteAXRowsReadFailureWasObserved)
    #expect(axRowsFixture.menuState.postWriteAXRowsReadFailureCount == 6)
    #expect(!axRowsFixture.menuState.postWriteAXRowsReadRecoveredAfterFailure)

    let structuralFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteStructuralChildrenReadFailureStatus: AXError.invalidUIElement.rawValue,
        postWriteStructuralChildrenReadFailurePersists: true,
        markers: [("1 1 1 1", "Target"), ("5 1 1 1", "Survivor")]
    )
    let structuralResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: structuralFixture.runtime, mouse: structuralFixture.mouse
    )
    let structuralEnvelope = try issue523Envelope(structuralResult)

    #expect(structuralResult.isSuccess)
    #expect(structuralEnvelope["state"] as? String == "B")
    #expect(!(try #require(structuralEnvelope["readback_settled"] as? Bool)))
    #expect(structuralEnvelope["readback_failure_site"] as? String == "structural_children")
    #expect(structuralEnvelope["readback_ax_status"] as? Int == Int(AXError.invalidUIElement.rawValue))
    #expect(structuralFixture.menuState.postWriteStructuralChildrenReadFailureWasObserved)
    #expect(structuralFixture.menuState.postWriteStructuralChildrenReadFailureCount == 6)
    #expect(!structuralFixture.menuState.postWriteStructuralChildrenReadRecoveredAfterFailure)
}

@Test func testIssue523EmptyAXRowsWithSurvivingChildRowCannotReachStateA() async throws {
    // A SUCCESSFUL empty `AXRows` is not the same claim as an empty table. Concrete state: one
    // marker, the AXPick is a no-op, and the next reads return `success([])` for `AXRows` while the
    // table's children still hold the well-formed row. Two identical empty readings then settle,
    // the expected survivor set is also empty, the counts agree, and the uniqueness and canonical
    // gates pass — so the operation certifies a delete of a marker that is still there.
    //
    // Source mutation: take `case .success(let observedRows?)` as the complete row list without
    // corroborating an EMPTY one against the structural rows. That is the code as it stood, and it
    // returns State A here.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsReadEmpty: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // Measured: with the flag armed on the live-pick path this returned State A before the fix —
    // a verified delete of a marker still sitting in the table's children. An earlier version of
    // this fixture set the flag only on the stale-pick branch, so it never armed, and the State B
    // it produced came from an unrelated mismatch. That hole is why a first reading of this
    // scenario was reported as "does not reproduce".
    let observedState: String = envelope["state"] as? String ?? "nil"
    #expect(observedState != "A")
    #expect(fixture.menuState.postWriteRowsEmptyReadWasObserved)
    #expect(fixture.markerCount == 1)
}

@Test func testIssue523EmptyAXRowsWithChildrenThatNoLongerReportAXRowCannotReachStateA() async throws {
    // Last-marker variant: AXRows says success([]), the child remains present, but the rebuilding
    // table currently reports it as AXGroup rather than AXRow. A role-filtered `directChildren`
    // read used to turn those present children into [] and falsely corroborate the empty AXRows.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsReadEmpty: true,
        postWriteRowRolesBecomeNonRows: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(fixture.menuState.postWriteRowsEmptyReadWasObserved)
    #expect(fixture.menuState.postWriteRowRoleChangeWasObserved)
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
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523MenuChildrenAbsenceAfterShowDoesNotPromiseCleanRetry() async throws {
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
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

        // Source mutation applied once: return `.routeUnavailable(.menuAbsent)` without a menu
        // state from the settled-absence branch after AXShowMenu. These scoped absence statuses
        // would then advertise a clean retry even though a detached menu might still be open.
        #expect(!result.isSuccess)
        #expect(envelope["state"] as? String == "C")
        #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
        #expect(!writeAttempted)
        #expect(!safeToRetry)
        #expect(fallbackUnsafe)
        #expect(envelope["menu_state"] as? String == "could_not_be_closed")
        #expect(fixture.actions.actionCount(
            elementID: fixture.menuEntryID, action: kAXPickAction as String
        ) == 0)
    }
}

@Test func testIssue523UnreadablePollResetsTheConsecutiveAbsenceRequirement() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: nil,
        menuChildrenReadFailsBetweenAbsences: true
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
    let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

    // Mutation applied once: leave `absentReadings` unchanged in the failed-read branch. The
    // alternating absence → unreadable observations then falsely settle the route as absent,
    // rather than producing this unsafe-to-retry unreadable cleanup result.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "menu_unreadable")
    #expect(!safeToRetry)
    #expect(fallbackUnsafe)
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
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
}

@Test func testIssue523CleanupFailureMakesObservedMenuRefusalsUnsafeToRetry() async throws {
    let fixtures = [
        issue523MarkerDeleteFixture(menuEntryTitle: "Copy", menuDismissesOnCancel: false),
        issue523MarkerDeleteFixture(
            menuEntryTitle: "Delete", menuEntryEnabled: false, menuDismissesOnCancel: false
        ),
        issue523MarkerDeleteFixture(
            menuEntryTitle: "Delete",
            menuDismissesOnCancel: false,
            menuEntryChildrenReadFails: true
        ),
        issue523MarkerDeleteFixture(
            menuEntryTitle: "Delete",
            menuDismissesOnCancel: false,
            menuEntryEnabledReadFails: true
        ),
    ]
    for fixture in fixtures {
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 0, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)
        let writeAttempted = try #require(envelope["write_attempted"] as? Bool)
        let safeToRetry = try #require(envelope["safe_to_retry"] as? Bool)
        let fallbackUnsafe = try #require(envelope["fallback_unsafe"] as? Bool)

        // Mutation applied once: remove `menuState: menuWasClosed ? nil : "could_not_be_closed"`
        // from the four observed-menu refusal outcomes. Each fixture then misreports a retry into
        // its still-open menu as safe and omits the menu-state receipt.
        #expect(!result.isSuccess)
        #expect(envelope["state"] as? String == "C")
        #expect(!writeAttempted)
        #expect(!safeToRetry)
        #expect(fallbackUnsafe)
        #expect(envelope["menu_state"] as? String == "could_not_be_closed")
        #expect(fixture.menuIsOpen)
    }
}

@Test func testIssue523UnreadableMenuClosureStillRefusesWithoutAnotherDeleteActuation() async throws {
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

    // Mutation applied once: discard the observed-menu cleanup result in the unreadable-entry
    // branch. This closure proof failure would then be reported as safely retryable.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
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

    // Mutation applied once: discard the failed missing-entry cleanup result. The still-open menu
    // would then be misreported as safely retryable without its `menu_state` receipt.
    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(!safeToRetry)
    #expect(fallbackUnsafe)
    #expect(envelope["edit_menu_route_state"] as? String == "exact_delete_entry_missing_or_disabled")
    #expect(envelope["menu_state"] as? String == "could_not_be_closed")
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuID, action: kAXCancelAction as String
    ) == 1)
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
}

@Test func testIssue523TruncatedAXRowsWithSurvivingChildRowCannotReachStateA() async throws {
    // A non-empty `AXRows` is not evidence that it is the COMPLETE row list. The empty case was
    // corroborated against the table's children; a truncated non-empty one was still trusted whole.
    // Same measured AX lie — the table rebuilds and `AXRows` answers success — only the reading
    // drops exactly the target row instead of every row.
    //
    // Concrete state: three markers, the AXPick is a no-op, and every subsequent `AXRows` read
    // omits the target while `AXChildren` still holds all three rows. The expected survivor set is
    // the other two, the truncated reading matches it exactly, two identical readings settle, and
    // the uniqueness and canonical gates pass — so a delete that never happened certifies State A.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    let observedState: String = envelope["state"] as? String ?? "nil"
    #expect(observedState != "A")
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    // The row is still a child of the bound table: nothing was deleted.
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523SubstitutedAXRowsElementWithSameCountCannotReachStateA() async throws {
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsSubstituteIndex: 1,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    let observedState: String = envelope["state"] as? String ?? "nil"
    #expect(observedState != "A")
    #expect(fixture.markerCount == 3)
    #expect(fixture.menuState.postWriteRowsSubstituteReadWasObserved)
}

@Test func testIssue523PostDeleteSubstitutedAXRowsElementCannotReachStateA() async throws {
    // The real menu pick removes Verse. AXRows then reports the correct post-delete count and
    // two plausible survivor positions, but replaces Chorus's AX element with a foreign element;
    // AXChildren still holds the real Intro/Chorus rows. The survivor position/count proof alone
    // would certify State A, so the identity corroboration must reject the reading first.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteRowsSubstituteIndex: 1,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(fixture.menuState.postWriteRowsSubstituteReadWasObserved)
    // The table really did delete the target; the rejection is solely about trusting the
    // substituted AXRows element as a corroborated survivor observation.
    #expect(fixture.markerCount == 2)
    #expect(fixture.markerNames == ["Intro", "Chorus"])
}
