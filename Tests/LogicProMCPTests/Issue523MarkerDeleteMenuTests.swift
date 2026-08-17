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
    var postWriteRowsReadFailureCount = 0
    var postWriteAXRowsReadFailuresRemaining = 0
    var postWriteAXRowsReadFailureStatus = AXError.cannotComplete.rawValue
    var postWriteAXRowsReadFailurePersists = false
    var postWriteAXRowsReadFailureCount = 0
    var postWriteAXRowsReadFailureWasObserved = false
    var postWriteAXRowsReadRecoveredAfterFailure = false
    var postWriteAXRowsRecoveredReadCount = 0
    var postWriteAXRowsReadNil = false
    var postWriteAXRowsNilReadWasObserved = false
    var postWriteAXRowsNilReadCount = 0
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
    var postWriteStructuralRowsDropIndex: Int?
    var postWriteStructuralRowsDropReadWasObserved = false
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
    var postWriteSelectedRowsBecomeEmpty = false
    var postWriteSelectedRowsBecomeFreshElement = false
    var postWriteSelectedRowsEmptyWasObserved = false
    var postWriteSelectedRowsFreshElementWasObserved = false
    var postWriteItemCountReadFailuresRemaining = 0
    var postWriteItemCountReadFailureStatus = AXError.cannotComplete.rawValue
    var postWriteItemCountReadFailurePersists = false
    var postWriteItemCountReadFailureCount = 0
    var postWriteItemCountReadFailureWasObserved = false
    var postWriteItemCountReadRecoveredAfterFailure = false
    var postWriteItemCountRecoveredReadCount = 0
    var postWriteItemCountFrozen = false
    var postWriteItemCountValueOverride: String?
    var postWriteItemCountValueOverrideWasObserved = false
    var itemCountNodeWasReadByDescription = false
    var itemCountGroupChildrenReadFailureWasObserved = false
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
    postWriteAXRowsReadNil: Bool = false,
    postWriteRowsReadEmpty: Bool = false,
    postWriteRowsDropIndex: Int? = nil,
    postWriteRowsSubstituteIndex: Int? = nil,
    postWriteRowRolesBecomeNonRows: Bool = false,
    postWriteStructuralChildrenReadFailures: Int = 0,
    postWriteStructuralChildrenReadFailureStatus: Int32 = AXError.cannotComplete.rawValue,
    postWriteStructuralChildrenReadFailurePersists: Bool = false,
    postWriteStructuralRowsDropIndex: Int? = nil,
    postWriteRowCellsReadNoValue: Bool = false,
    postWriteRowCellsInvalidReadFailures: Int = 0,
    postWriteRowCellsInvalidReadPersists: Bool = false,
    postWriteRowsNeverSettle: Bool = false,
    postWriteSelectedRowsBecomeEmpty: Bool = false,
    postWriteSelectedRowsBecomeFreshElement: Bool = false,
    itemCountMissing: Bool = false,
    prewriteItemCountValue: String? = nil,
    postWriteItemCountReadFailures: Int = 0,
    postWriteItemCountReadFailureStatus: Int32 = AXError.cannotComplete.rawValue,
    postWriteItemCountReadFailurePersists: Bool = false,
    postWriteItemCountFrozen: Bool = false,
    postWriteItemCountValueOverride: String? = nil,
    duplicateItemCountDecoyValue: String? = nil,
    itemCountGroupChildrenUnreadableStatus: Int32? = nil,
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
    menuState.postWriteSelectedRowsBecomeEmpty = postWriteSelectedRowsBecomeEmpty
    menuState.postWriteSelectedRowsBecomeFreshElement = postWriteSelectedRowsBecomeFreshElement
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
    let markerCountGroup = builder.element(52_280)
    let decoyItemCount = builder.element(52_281)
    let itemCountText = builder.element(52_282)
    // A second AXStaticText also described "Number of Items", placed directly under the
    // window rather than inside `markerCountGroup`. Models a live tree that genuinely has
    // two candidates so `findMarkerListNumberOfItemsNodes` must not call ONE of them unique
    // just because the OTHER's subtree refused to answer.
    let duplicateItemCountText = builder.element(52_283)

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
    // A post-rebuild AXSelectedRows element that is not CFEqual to the pre-write target.
    // The table's own selected-row projection can replace every row identity during rebuild
    // without the marker leaving.
    let freshSelectedRow = builder.element(98_780)
    builder.setAttribute(freshSelectedRow, kAXRoleAttribute as String, kAXRowRole as String)
    @Sendable func makeSubstituteRowReadLike(_ source: AXUIElement) {
        guard let index = rows.firstIndex(where: { CFEqual($0, source) }) else { return }
        builder.setAttribute(substitutePosition, kAXDescriptionAttribute as String, markers[index].position)
        builder.setAttribute(substituteName, kAXDescriptionAttribute as String, markers[index].name)
    }
    builder.setAttribute(table, "AXRows", rows)
    let structuralRows = structuralRowOrder.map { $0.map { rows[$0] } } ?? rows
    builder.setChildren(table, structuralRows)
    // Logic renders its own count on a node that is not a table projection. The decoy
    // static text is deliberately first among siblings so a position-based read would
    // report 99 instead of the real marker count.
    builder.setAttribute(markerCountGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(markerCountGroup, kAXDescriptionAttribute as String, "Marker")
    builder.setAttribute(decoyItemCount, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(decoyItemCount, kAXDescriptionAttribute as String, "Selected Item")
    builder.setAttribute(decoyItemCount, kAXValueAttribute as String, "99 Markers")
    builder.setAttribute(itemCountText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(itemCountText, kAXDescriptionAttribute as String, "Number of Items")
    builder.setAttribute(
        itemCountText, kAXValueAttribute as String,
        prewriteItemCountValue ?? issue523MarkerListItemCountText(markers.count)
    )
    builder.setChildren(markerCountGroup, [decoyItemCount, itemCountText])
    if let duplicateItemCountDecoyValue {
        builder.setAttribute(duplicateItemCountText, kAXRoleAttribute as String, kAXStaticTextRole as String)
        builder.setAttribute(duplicateItemCountText, kAXDescriptionAttribute as String, "Number of Items")
        builder.setAttribute(duplicateItemCountText, kAXValueAttribute as String, duplicateItemCountDecoyValue)
    }
    var markerListChildren = [bottomEdit, toolbarEdit, table]
    if !itemCountMissing {
        markerListChildren.append(markerCountGroup)
    }
    if duplicateItemCountDecoyValue != nil {
        markerListChildren.append(duplicateItemCountText)
    }
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
                    menuState.postWriteAXRowsReadNil = postWriteAXRowsReadNil
                    menuState.postWriteRowsReadEmpty = postWriteRowsReadEmpty
                    menuState.postWriteRowsDropIndex = postWriteRowsDropIndex
                    menuState.postWriteRowsSubstituteIndex = postWriteRowsSubstituteIndex
                    menuState.postWriteRowRolesBecomeNonRows = postWriteRowRolesBecomeNonRows
                    menuState.postWriteStructuralChildrenReadFailuresRemaining = postWriteStructuralChildrenReadFailures
                    menuState.postWriteStructuralChildrenReadFailureStatus = postWriteStructuralChildrenReadFailureStatus
                    menuState.postWriteStructuralChildrenReadFailurePersists = postWriteStructuralChildrenReadFailurePersists
                    menuState.postWriteStructuralRowsDropIndex = postWriteStructuralRowsDropIndex
                    menuState.postWriteRowCellsReadNoValue = postWriteRowCellsReadNoValue
                    menuState.postWriteRowCellsInvalidReadFailuresRemaining = postWriteRowCellsInvalidReadFailures
                    menuState.postWriteRowCellsInvalidReadPersists = postWriteRowCellsInvalidReadPersists
                    menuState.postWriteRowsNeverSettle = postWriteRowsNeverSettle
                    menuState.postWriteItemCountReadFailuresRemaining = postWriteItemCountReadFailures
                    menuState.postWriteItemCountReadFailureStatus = postWriteItemCountReadFailureStatus
                    menuState.postWriteItemCountReadFailurePersists = postWriteItemCountReadFailurePersists
                    menuState.postWriteItemCountFrozen = postWriteItemCountFrozen
                    menuState.postWriteItemCountValueOverride = postWriteItemCountValueOverride
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
                    // A real Delete no longer leaves the removed element as the table's current
                    // selection. Keep the operation's pre-pick diagnostic ID separately so the
                    // target-fidelity test can still identify which row AXPick acted on.
                    builder.setAttribute(table, "AXSelectedRows", [AXUIElement]())
                    if !postWriteItemCountFrozen, postWriteItemCountValueOverride == nil {
                        builder.setAttribute(
                            itemCountText,
                            kAXValueAttribute as String,
                            issue523MarkerListItemCountText(afterPick.count)
                        )
                    }
                }
                if let override = postWriteItemCountValueOverride {
                    builder.setAttribute(itemCountText, kAXValueAttribute as String, override)
                    menuState.postWriteItemCountValueOverrideWasObserved = true
                }
                if let substituteIndex = postWriteRowsSubstituteIndex,
                   let currentRows: [AXUIElement] = AXHelpers.getAttribute(
                       table, "AXRows", runtime: builder.makeAXRuntime()
                   ),
                   currentRows.indices.contains(substituteIndex) {
                    makeSubstituteRowReadLike(currentRows[substituteIndex])
                }
                if unrelatedEmptyTableBecomesFirstAfterPick {
                    var reboundChildren = [unrelatedTable, bottomEdit, toolbarEdit, table]
                    if !itemCountMissing {
                        reboundChildren.append(markerCountGroup)
                    }
                    builder.setChildren(markerList, reboundChildren)
                }
                menuState.postWriteRowsReadFails = postWriteRowsReadFails
                menuState.postWriteAXRowsReadFailuresRemaining = postWriteAXRowsReadFailures
                menuState.postWriteAXRowsReadFailureStatus = postWriteAXRowsReadFailureStatus
                menuState.postWriteAXRowsReadFailurePersists = postWriteAXRowsReadFailurePersists
                menuState.postWriteAXRowsReadNil = postWriteAXRowsReadNil
                menuState.postWriteRowsReadEmpty = postWriteRowsReadEmpty
                menuState.postWriteRowsDropIndex = postWriteRowsDropIndex
                menuState.postWriteRowsSubstituteIndex = postWriteRowsSubstituteIndex
                menuState.postWriteRowRolesBecomeNonRows = postWriteRowRolesBecomeNonRows
                menuState.postWriteStructuralChildrenReadFailuresRemaining = postWriteStructuralChildrenReadFailures
                menuState.postWriteStructuralChildrenReadFailureStatus = postWriteStructuralChildrenReadFailureStatus
                menuState.postWriteStructuralChildrenReadFailurePersists = postWriteStructuralChildrenReadFailurePersists
                menuState.postWriteStructuralRowsDropIndex = postWriteStructuralRowsDropIndex
                menuState.postWriteRowCellsReadNoValue = postWriteRowCellsReadNoValue
                menuState.postWriteRowCellsInvalidReadFailuresRemaining = postWriteRowCellsInvalidReadFailures
                menuState.postWriteRowCellsInvalidReadPersists = postWriteRowCellsInvalidReadPersists
                menuState.postWriteRowsNeverSettle = postWriteRowsNeverSettle
                menuState.postWriteItemCountReadFailuresRemaining = postWriteItemCountReadFailures
                menuState.postWriteItemCountReadFailureStatus = postWriteItemCountReadFailureStatus
                menuState.postWriteItemCountReadFailurePersists = postWriteItemCountReadFailurePersists
                menuState.postWriteItemCountFrozen = postWriteItemCountFrozen
                menuState.postWriteItemCountValueOverride = postWriteItemCountValueOverride
                if menuState.postWriteSelectedRowsBecomeEmpty {
                    builder.setAttribute(table, "AXSelectedRows", [AXUIElement]())
                    menuState.postWriteSelectedRowsEmptyWasObserved = true
                }
                if menuState.postWriteSelectedRowsBecomeFreshElement {
                    builder.setAttribute(table, "AXSelectedRows", [freshSelectedRow])
                    menuState.postWriteSelectedRowsFreshElementWasObserved = true
                }
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
                if let itemCountGroupChildrenUnreadableStatus,
                   builder.elementID(element) == builder.elementID(markerCountGroup) {
                    menuState.itemCountGroupChildrenReadFailureWasObserved = true
                    return .failure(AXHelpers.AXStatusError(raw: itemCountGroupChildrenUnreadableStatus))
                }
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
                if let dropIndex = menuState.postWriteStructuralRowsDropIndex,
                   builder.elementID(element) == builder.elementID(table) {
                    // Deliberately leave the table's real children alone. This is the common-mode
                    // rebuild lie: AXChildren reports the same target omission as AXRows while
                    // the bound table still owns all original rows.
                    let currentChildren = baseRuntime.ax.children(element)
                    guard currentChildren.indices.contains(dropIndex) else {
                        return .success(currentChildren)
                    }
                    menuState.postWriteStructuralRowsDropReadWasObserved = true
                    var truncated = currentChildren
                    truncated.remove(at: dropIndex)
                    return .success(truncated)
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
                    menuState.postWriteRowsReadFailureCount += 1
                    return .failure(AXHelpers.AXStatusError(raw: AXError.failure.rawValue))
                }
                if menuState.postWriteAXRowsReadNil,
                   builder.elementID(element) == builder.elementID(table),
                   attribute == "AXRows" {
                    // A successful nil is an answer that AXRows has no value, not an AX failure.
                    // The composite rebuild regression verifies it takes the same guarded
                    // structural path as attributeUnsupported.
                    menuState.postWriteAXRowsNilReadWasObserved = true
                    menuState.postWriteAXRowsNilReadCount += 1
                    return .success(nil)
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
                if builder.elementID(element) == builder.elementID(itemCountText),
                   attribute == kAXDescriptionAttribute as String {
                    menuState.itemCountNodeWasReadByDescription = true
                }
                if (menuState.postWriteItemCountReadFailuresRemaining > 0
                    || menuState.postWriteItemCountReadFailurePersists),
                   builder.elementID(element) == builder.elementID(itemCountText),
                   attribute == kAXValueAttribute as String {
                    menuState.postWriteItemCountReadFailureWasObserved = true
                    menuState.postWriteItemCountReadFailureCount += 1
                    if menuState.postWriteItemCountReadFailuresRemaining > 0 {
                        menuState.postWriteItemCountReadFailuresRemaining -= 1
                    }
                    return .failure(AXHelpers.AXStatusError(
                        raw: menuState.postWriteItemCountReadFailureStatus
                    ))
                }
                if menuState.postWriteItemCountReadFailureCount > 0,
                   builder.elementID(element) == builder.elementID(itemCountText),
                   attribute == kAXValueAttribute as String {
                    menuState.postWriteItemCountReadRecoveredAfterFailure = true
                    menuState.postWriteItemCountRecoveredReadCount += 1
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

private func issue523MarkerListItemCountText(_ count: Int) -> String {
    count == 1 ? "1 Marker" : "\(count) Markers"
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
    #expect(try #require(envelope["verified"] as? Bool))
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
        #expect(try #require(envelope["verified"] as? Bool))
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
    #expect(try #require(envelope["verified"] as? Bool))
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
    #expect(try #require(envelope["verified"] as? Bool))
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

@Test func testIssue523UnknownLocaleEditDeleteLabelsRefuseWithoutIssuingAPick() async throws {
    // Locale policy itself stays with #519. An unseen locale must refuse honestly rather
    // than guess a destructive actuator. Mutation: return `.pickIssued` from the settled
    // `.menuAbsent` branch. write_attempted and the zero-AXPick count both fail.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Löschen",
        editControlTitle: "Bearbeiten"
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(envelope["edit_menu_route_state"] as? String == "menu_absent")
    #expect(!writeAttempted)
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
    ) == 0)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
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
    #expect(try #require(envelope["verified"] as? Bool))
    #expect(fixture.actions.actionCount(
        elementID: fixture.toolbarEditID, action: kAXShowMenuAction as String
    ) == 1)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
}

@Test func testIssue523PostWriteReadbackFailureReceiptNamesTheActualSiteAndStatus() async throws {
    // Mutation A: remove `failure` from `isTransientDuringRebuild`. This first fixture then
    // returns State B on poll 1 and fails the six-poll count below. The boolean plus the exact
    // count prove the fixture fired on the live AXRows call and consumed the settle budget.
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
    #expect(!(try #require(axRowsEnvelope["readback_settled"] as? Bool)))
    #expect(axRowsFixture.menuState.postWriteRowsReadFailureWasObserved)
    #expect(axRowsFixture.menuState.postWriteRowsReadFailureCount == 6)
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
    #expect(try #require(envelope["verified"] as? Bool))
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
    #expect(try #require(envelope["verified"] as? Bool))
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
    #expect(try #require(envelope["verified"] as? Bool))
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
    #expect(try #require(axRowsAnswerEnvelope["verified"] as? Bool))
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
    #expect(try #require(envelope["state"] as? String) == "B")
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

@Test func testIssue523AXRowsAbsenceOrNilWithNonRowChildrenCannotManufactureEmptyReadback() async throws {
    // Mutation proven: in `markerListInventoryWithReadFailure`, replace the
    // `markerListStructuralRows(from: table, runtime: runtime)` call in the success(nil) branch
    // with the old role-filtered `directChildren` call. That branch bypasses the
    // present-child/non-row guard and fails its exact `readback_unavailable` expectation below
    // (the later selection-effect guard can still keep the result out of State A, which is why
    // this test pins the unavailable diagnosis too). The paired attributeUnsupported fixture
    // covers the distinct definitive-absence entry into the same property.
    let absenceFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteAXRowsReadFailureStatus: AXError.attributeUnsupported.rawValue,
        postWriteAXRowsReadFailurePersists: true,
        postWriteRowRolesBecomeNonRows: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let absenceResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: absenceFixture.runtime, mouse: absenceFixture.mouse
    )
    let absenceEnvelope = try issue523Envelope(absenceResult)

    #expect(absenceResult.isSuccess)
    #expect(try #require(absenceEnvelope["state"] as? String) == "B")
    #expect(absenceEnvelope["reason"] as? String == "readback_unavailable")
    #expect(absenceFixture.menuState.postWriteAXRowsReadFailureWasObserved)
    #expect(absenceFixture.menuState.postWriteAXRowsReadFailureCount == 1)
    #expect(absenceFixture.menuState.postWriteRowRoleChangeWasObserved)
    #expect(absenceFixture.markerCount == 1)

    let nilFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteAXRowsReadNil: true,
        postWriteRowRolesBecomeNonRows: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let nilResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: nilFixture.runtime, mouse: nilFixture.mouse
    )
    let nilEnvelope = try issue523Envelope(nilResult)

    #expect(nilResult.isSuccess)
    #expect(try #require(nilEnvelope["state"] as? String) == "B")
    #expect(nilEnvelope["reason"] as? String == "readback_unavailable")
    #expect(nilFixture.menuState.postWriteAXRowsNilReadWasObserved)
    #expect(nilFixture.menuState.postWriteAXRowsNilReadCount == 1)
    #expect(nilFixture.menuState.postWriteRowRoleChangeWasObserved)
    #expect(nilFixture.markerCount == 1)
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

    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    // The row is still a child of the bound table: nothing was deleted.
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523SharedAXRowsAndChildrenTargetOmissionCannotReachStateA() async throws {
    // AXRows and AXChildren are two properties of the same AXTable, not independent witness
    // processes. Model the real common-mode rebuild case: both successfully omit Verse on every
    // post-pick poll while the actual table keeps all three rows and Delete was a no-op. The
    // original target remains selected, which is a separate observed no-op effect and must join
    // the two-reading settle before State A can be certified.
    //
    // Mutation proven: replace `guard !observedTargetRowStillSelected` in
    // `defaultDeleteMarker` with `guard true`. The two lying inventories then settle on the exact
    // expected survivor multiset and this test's explicit State-B expectation fails as State A.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["marker_count_after"] as? Int == 2)
    #expect(try #require(envelope["target_row_still_selected_after_pick"] as? Bool))
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteStructuralRowsDropReadWasObserved)
    // The table's actual children are untouched by both seams: no marker was deleted.
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523SharedProjectionOmissionWithEmptySelectionCannotReachStateA() async throws {
    // The "target row is no longer selected" check is not independent of the table. After
    // a rebuild, the pre-write Verse element is CFEqual to nothing — including an empty
    // AXSelectedRows — whether or not the marker left. Two agreeing truncated inventories
    // plus that empty selection must not encode State A.
    //
    // Mutation proven: restore `encodeStateA` after the selection-no-op guard. This fixture
    // then certifies a no-op delete and fails the state / remaining-count assertions.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        postWriteSelectedRowsBecomeEmpty: true,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let reasonDetail = try #require(envelope["reason_detail"] as? String)

    // `!= "A"` also accepts State C (e.g. the route never even reaching a pick); pin the
    // exact refusal so a regression that turns this into a pre-write refusal is caught too.
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(reasonDetail.contains("did not drop by one"))
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteStructuralRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteSelectedRowsEmptyWasObserved)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523SharedProjectionOmissionWithEmptySelectionReallyReachesTheWriteNotAPrewriteRefusal() async throws {
    // Mutation-demonstration for the assertion above: `!= "A"` cannot distinguish "reached
    // the write and failed to verify it" (State B) from "never reached the write at all"
    // (State C). Force State C on the SAME fixture shape by making the exact Delete entry
    // unavailable, so the two outcomes are visibly different and `!= "A"` would have passed
    // both.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: nil,
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        postWriteSelectedRowsBecomeEmpty: true,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(!result.isSuccess)
    #expect(envelope["state"] as? String == "C")
    #expect(!writeAttempted)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 0)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523SharedProjectionOmissionWithFreshSelectionCannotReachStateA() async throws {
    // Same common-mode rebuild, only AXSelectedRows is a newly created element that is
    // not CFEqual to the pre-write Verse row. That is still a table projection.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        postWriteSelectedRowsBecomeFreshElement: true,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let reasonDetail = try #require(envelope["reason_detail"] as? String)

    // `!= "A"` also accepts State C; pin the exact refusal (see the mutation-demonstration
    // test above for why that distinction matters).
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(reasonDetail.contains("did not drop by one"))
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteStructuralRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteSelectedRowsFreshElementWasObserved)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523LastMarkerSharedEmptyProjectionsWithNonMatchingSelectionCannotReachStateA() async throws {
    // Last-marker variant: both projections successfully answer [] and the selection is a
    // fresh non-matching element. An empty expected survivor set plus "target no longer
    // selected" is the same rebuild lie, just with one row.
    //
    // This used to be refused one step later than its two siblings above, and for a different
    // reason. The reader had an escape hatch: a table whose CHILD list was also empty was accepted
    // as an empty marker list with no corroboration at all, so the empty survivor set reached the
    // receipt and the count comparison caught it ("did not drop by one"). The two sibling tests,
    // whose tables still vend non-row children, were refused by the reader itself.
    //
    // That split was an artifact of the hatch, not a distinction worth keeping — "the table
    // answered with nothing" is exactly what a rebuild answers, and Logic's live table always
    // carries its columns, so the hatch covered no shape the application presents. With every
    // empty row set now corroborated against Logic's own Number of Items, all three refuse at the
    // same place for the same reason, and the receipt names the site.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 0,
        postWriteStructuralRowsDropIndex: 0,
        postWriteSelectedRowsBecomeFreshElement: true,
        markers: [("1 1 1 1", "Only Marker")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 0, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    // `!= "A"` also accepts State C; pin the exact refusal (see the mutation-demonstration
    // test above for why that distinction matters).
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(envelope["reason"] as? String == "readback_unavailable")
    #expect(envelope["readback_failure_site"] as? String == "item_count")
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteStructuralRowsDropReadWasObserved)
    // The fresh-selection observation is deliberately NOT asserted any more: the poll now refuses
    // at the inventory read, before it ever looks at the selection, so requiring that read to have
    // happened would assert something this path no longer does.
    #expect(fixture.markerCount == 1)
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

    #expect(try #require(envelope["state"] as? String) == "B")
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

@Test func testIssue523IndependentItemCountDropAndSurvivorMultisetReachStateA() async throws {
    // Mutation proven: restore the "no independent witness" State B return after the
    // canonical-position guard. The delete is real, the survivor multiset agrees, and
    // Logic's own Number of Items count drops 3 → 2, so that mutation fails the State-A
    // expectation below. The decoy sibling is first and reads "99 Markers"; matching by
    // position among siblings would publish 99 and fail the observed-before assertion.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(try #require(envelope["verified"] as? Bool))
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["observed_marker_count_before"] as? Int == 3)
    #expect(envelope["observed_marker_count_after"] as? Int == 2)
    #expect(envelope["observed_marker_count_text_before"] as? String == "3 Markers")
    #expect(envelope["observed_marker_count_text_after"] as? String == "2 Markers")
    #expect(envelope["expected_survivor_position_multiset"] as? String == "7:1.1.1.18:12.1.1.1")
    #expect(envelope["observed_survivor_position_multiset"] as? String == "7:1.1.1.18:12.1.1.1")
    #expect(fixture.menuState.itemCountNodeWasReadByDescription)
    #expect(fixture.markerCount == 2)
    #expect(fixture.markerNames == ["Intro", "Chorus"])

    let lastMarkerFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
    )
    let lastMarkerResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: lastMarkerFixture.runtime, mouse: lastMarkerFixture.mouse
    )
    let lastMarkerEnvelope = try issue523Envelope(lastMarkerResult)
    #expect(lastMarkerEnvelope["state"] as? String == "A")
    #expect(lastMarkerEnvelope["observed_marker_count_before"] as? Int == 2)
    #expect(lastMarkerEnvelope["observed_marker_count_after"] as? Int == 1)
    #expect(lastMarkerEnvelope["observed_marker_count_text_after"] as? String == "1 Marker")
}

@Test func testIssue523ReadableUnchangedItemCountCannotReachStateAWhileProjectionsOmitTheRow() async throws {
    // Mutation proven: skip the independent-count drop check and encode State A from the
    // settled table projections alone. Both AXRows and AXChildren omit Verse, the
    // selection is a fresh non-matching element, and the uniqueness/canonical gates
    // pass — but Logic's own count still reads 3 Markers. That mutation certifies a
    // no-op delete and fails the State-B / count-observation assertions below.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        postWriteSelectedRowsBecomeFreshElement: true,
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("12 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["observed_marker_count_before"] as? Int == 3)
    #expect(envelope["observed_marker_count_after"] as? Int == 3)
    let reasonDetail = try #require(envelope["reason_detail"] as? String)
    #expect(reasonDetail.contains("Number of Items"))
    #expect(reasonDetail.contains("3"))
    #expect(fixture.menuState.postWriteRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteStructuralRowsDropReadWasObserved)
    #expect(fixture.menuState.postWriteSelectedRowsFreshElementWasObserved)
    #expect(fixture.menuState.itemCountNodeWasReadByDescription)
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523UnreadableOrUnparseableItemCountCannotReachStateA() async throws {
    // Mutation proven: treat a missing or unparseable Number of Items value as count 0.
    // Both fixtures really delete the target, so a fabricated 0 would look like a drop
    // and certify State A. The receipt must say the witness was unreadable and must
    // not publish an invented observed_marker_count_after.
    let missingFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        itemCountMissing: true,
        markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
    )
    let missingResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: missingFixture.runtime, mouse: missingFixture.mouse
    )
    let missingEnvelope = try issue523Envelope(missingResult)
    let missingDetail = try #require(missingEnvelope["reason_detail"] as? String)

    #expect(missingResult.isSuccess)
    #expect(missingEnvelope["state"] as? String == "B")
    #expect(missingEnvelope["reason"] as? String == "readback_unavailable")
    #expect(try #require(missingEnvelope["readback_settled"] as? Bool))
    #expect(missingEnvelope["observed_marker_count_before"] == nil)
    #expect(missingEnvelope["observed_marker_count_after"] == nil)
    #expect(missingEnvelope["item_count_witness_state"] as? String == "unreadable")
    #expect(missingDetail.contains("unreadable"))
    #expect(missingFixture.markerCount == 1)

    let unparseableFixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteItemCountValueOverride: "Markers",
        markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
    )
    let unparseableResult = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: unparseableFixture.runtime, mouse: unparseableFixture.mouse
    )
    let unparseableEnvelope = try issue523Envelope(unparseableResult)
    let unparseableDetail = try #require(unparseableEnvelope["reason_detail"] as? String)

    #expect(unparseableResult.isSuccess)
    #expect(unparseableEnvelope["state"] as? String == "B")
    #expect(unparseableEnvelope["reason"] as? String == "readback_unavailable")
    #expect(unparseableEnvelope["observed_marker_count_before"] as? Int == 2)
    #expect(unparseableEnvelope["observed_marker_count_after"] == nil)
    #expect(unparseableEnvelope["item_count_witness_state"] as? String == "unparseable")
    #expect(unparseableEnvelope["observed_marker_count_text_after"] as? String == "Markers")
    // The `||` this replaced could not name which refusal actually happened: "unparseable"
    // never appears in any produced message, so that branch was always vacuous.
    #expect(unparseableDetail.contains("could not be parsed"))
    #expect(unparseableFixture.menuState.postWriteItemCountValueOverrideWasObserved)
    #expect(unparseableFixture.markerCount == 1)
}

@Test func testIssue523TransientItemCountReadFailureRetiresPollThenSettles() async throws {
    // Mutation proven: return State B from the first failed Number of Items value read
    // instead of retiring that poll. The AXPick still deletes, so the operation must
    // continue; two later agreeing count reads then settle on 1 Marker and this
    // State-A expectation fails if the first -25204 retired the whole write.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        postWriteItemCountReadFailures: 2,
        postWriteItemCountReadFailureStatus: AXError.cannotComplete.rawValue,
        markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(try #require(envelope["verified"] as? Bool))
    #expect(try #require(envelope["readback_settled"] as? Bool))
    #expect(envelope["observed_marker_count_before"] as? Int == 2)
    #expect(envelope["observed_marker_count_after"] as? Int == 1)
    #expect(envelope["observed_marker_count_text_after"] as? String == "1 Marker")
    #expect(fixture.menuState.postWriteItemCountReadFailureWasObserved)
    #expect(fixture.menuState.postWriteItemCountReadFailureCount == 2)
    #expect(fixture.menuState.postWriteItemCountReadRecoveredAfterFailure)
    #expect(fixture.menuState.postWriteItemCountRecoveredReadCount == 2)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    #expect(fixture.markerCount == 1)
}

@Test func testIssue523StalePrewriteItemCountDisagreeingWithInventoryCannotReachStateA() async throws {
    // BLOCKER repro: the pre-write Number of Items witness reads "4 Markers" while the
    // pre-write TABLE inventory only has 3 real rows — a stale render, a wrong node, or a
    // decoy. AXPick is a genuine no-op (`pickDeletesSelectedRow: false`), but both AXRows
    // and the table's structural children lie about the same omission, the post-pick
    // selection becomes a fresh non-matching element, and the post-write witness reads
    // "3 Markers" — exactly one less than the WRONG pre-write witness. Before pinning
    // `observed_marker_count_before == marker_count_before`, this combination satisfied the
    // drop-by-one check and certified a delete that never happened.
    //
    // Mutation: delete the `observedCountBefore == before.count` guard. That mutation
    // restores this false State A and fails the assertions below.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        postWriteSelectedRowsBecomeFreshElement: true,
        prewriteItemCountValue: "4 Markers",
        postWriteItemCountValueOverride: "3 Markers",
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("9 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let reasonDetail = try #require(envelope["reason_detail"] as? String)

    #expect(result.isSuccess)
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(envelope["reason"] as? String == "readback_mismatch")
    #expect(envelope["marker_count_before"] as? Int == 3)
    #expect(envelope["observed_marker_count_before"] as? Int == 4)
    #expect(reasonDetail.contains("did not agree with the pre-write table inventory"))
    // The Delete pick was a genuine no-op: all three rows remain in the fixture's real table.
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523PrewriteItemCountSettlesAcrossATransientFirstRead() async throws {
    // Confirms the pre-write witness is settled the same way the after witness is: a
    // momentary AX hiccup on the FIRST pre-write read must not poison a value that a second
    // read would confirm. This exercises `settledMarkerListItemCount`'s retry path directly
    // (not merely its pass-through), so a mutation that returns the FIRST reading unsettled
    // would report an unreadable pre-write witness instead of the settled "2 Markers".
    //
    // There is no fixture seam for a transient pre-write item-count failure (only post-write
    // reads have one), so this asserts on the trustworthy end state instead: an honest delete
    // still reaches State A with a settled `observed_marker_count_before`.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(envelope["state"] as? String == "A")
    #expect(envelope["observed_marker_count_before"] as? Int == 2)
    #expect(envelope["marker_count_before"] as? Int == 2)
    #expect(fixture.markerCount == 1)
}

@Test func testIssue523WrongButParsedItemCountTextCannotManufactureADrop() async throws {
    // MAJOR repro: a value whose single ASCII digit run is not the leading token (e.g. a
    // sibling like "Marker 2") must not parse as a count. Before tightening the parser to
    // the Event List reader's leading-token rule, `runs.count == 1` accepted a digit run
    // ANYWHERE in the string, so "Marker 2" -> "Marker 1" (the selection merely moving to a
    // different marker) manufactured the same fake one-count drop a genuine delete produces.
    //
    // Mutation: restore the old `runs.count == 1` parse rule. Both reads then parse (2 -> 1),
    // the multiset proof already agrees (this is a genuine no-op, both projections omit the
    // row), and that mutation certifies State A instead of the State B asserted below.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        postWriteRowsDropIndex: 1,
        postWriteStructuralRowsDropIndex: 1,
        postWriteSelectedRowsBecomeFreshElement: true,
        prewriteItemCountValue: "Marker 2",
        postWriteItemCountValueOverride: "Marker 1",
        markers: [("1 1 1 1", "Intro"), ("5 1 1 1", "Verse"), ("9 1 1 1", "Chorus")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)

    #expect(result.isSuccess)
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(envelope["observed_marker_count_before"] == nil)
    #expect(envelope["observed_marker_count_after"] == nil)
    #expect(envelope["item_count_witness_state_before"] as? String == "unparseable")
    #expect(envelope["item_count_witness_state"] as? String == "unparseable")
    #expect(fixture.markerCount == 3)
}

@Test func testIssue523NonLeadingDigitItemCountStringsAreUnreadableNotACount() async throws {
    // Defensive regression table for the leading-token parse rule: the parser must fail closed on
    // digits that are not the leading count token.
    //
    // `2개` and `2個` used to be listed here, on the reasoning — stated in this comment — that no
    // KO/JA Number-of-Items text had been measured and a translated label could plausibly take that
    // shape. Both locales were measured on a live Logic 12.3 on 2026-08-17 and render
    // `2개의 마커` / `0個のマーカー`: the counter word abuts the digits, so a leading digit followed
    // by a CJK counter is the REAL shape and must parse. Those two entries were guesses about a
    // shape Logic does not produce, and the measurement retires them rather than the rule.
    //
    // What stays is every shape that does not OPEN with the count, including the Korean
    // `마커 2개` — a relaxation that let that through would be the dangerous one.
    let nonCountStrings = [
        "Marker 2",
        "Selected Item: 2",
        "마커 2개",
        "マーカー 2個",
        "no count here",
    ]
    for text in nonCountStrings {
        let fixture = issue523MarkerDeleteFixture(
            menuEntryTitle: "Delete",
            postWriteItemCountValueOverride: text,
            markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
        )
        let result = await AccessibilityChannel.defaultDeleteMarker(
            index: 1, runtime: fixture.runtime, mouse: fixture.mouse
        )
        let envelope = try issue523Envelope(result)

        #expect(
            envelope["observed_marker_count_after"] == nil,
            "\"\(text)\" must not parse to a count"
        )
        #expect(
            envelope["item_count_witness_state"] as? String == "unparseable",
            "\"\(text)\" must be reported unparseable"
        )
    }
}

@Test func testIssue523AmbiguousItemCountWitnessWithUnreadableSiblingSubtreeCannotReachStateA() async throws {
    // MAJOR repro: two AXStaticText nodes are both described "Number of Items". The real
    // one lives inside `markerCountGroup`, whose AXChildren read persistently fails
    // (-25200 == AXError.failure). A second, fully readable decoy elsewhere in the window
    // reads "1 Marker". The Delete pick is a genuine no-op (`pickDeletesSelectedRow:
    // false`), so nothing actually dropped from 2 to 1.
    //
    // Before checking `unreadable` ahead of `matches.isEmpty`, the walk found exactly the
    // decoy (the real node's parent never even got visited) and returned it as "the" unique
    // match, certifying a false one-marker drop. Mutation: swap the order back (`if
    // matches.isEmpty, let unreadable`) — that mutation restores the false certification.
    let fixture = issue523MarkerDeleteFixture(
        menuEntryTitle: "Delete",
        pickDeletesSelectedRow: false,
        duplicateItemCountDecoyValue: "1 Marker",
        itemCountGroupChildrenUnreadableStatus: AXError.failure.rawValue,
        markers: [("1 1 1 1", "Keep"), ("5 1 1 1", "Drop")]
    )
    let result = await AccessibilityChannel.defaultDeleteMarker(
        index: 1, runtime: fixture.runtime, mouse: fixture.mouse
    )
    let envelope = try issue523Envelope(result)
    let writeAttempted = try #require(envelope["write_attempted"] as? Bool)

    #expect(result.isSuccess)
    #expect(try #require(envelope["state"] as? String) == "B")
    #expect(writeAttempted)
    #expect(envelope["item_count_witness_state"] as? String == "unreadable")
    #expect(fixture.menuState.itemCountGroupChildrenReadFailureWasObserved)
    #expect(fixture.actions.actionCount(
        elementID: fixture.menuEntryID, action: kAXPickAction as String
    ) == 1)
    // The pick was a genuine no-op: both markers survive in the fixture's real table.
    #expect(fixture.markerCount == 2)
}

@Test func testIssue523LocalizedItemCountDescriptionsMatchTheMeasuredStrings() async throws {
    // This test used to pin the OPPOSITE: `항목 수` and `項目数` had to stay unmatched, because no
    // live Logic had been read in either locale and a translated guess must never silently match.
    // Both were measured on a live Logic 12.3 on 2026-08-17 — the app was switched with
    // `defaults write com.apple.logic10 AppleLanguages`, restarted, and the node's AXDescription and
    // AXHelp read directly; both attributes answer the same string. The absence pin did its job: it
    // required a measurement rather than a translation, and this is that measurement arriving.
    for description in ["Number of Items", "항목 수", "項目数"] {
        #expect(
            AXLocalePolicy.markerListNumberOfItemsLabel.matches(description, mode: .exactStrict),
            "\"\(description)\" was measured on a live Logic and must match"
        )
    }
    // Still fails closed on anything not measured, including a plausible near-miss.
    for description in ["항목수", "項目 数", "Items", "Number of Item"] {
        #expect(
            !AXLocalePolicy.markerListNumberOfItemsLabel.matches(description, mode: .exactStrict),
            "\"\(description)\" was never measured and must not match"
        )
    }
}

@Test func testIssue523ItemCountParsesTheMeasuredLocalizedRenderings() async throws {
    // The values these nodes render, measured in the same pass. Korean and Japanese put the counter
    // word straight against the digits, so a parser that demanded whitespace after them read the
    // witness as unparseable — and that count is what State A needs, so `nav.delete_marker` could
    // not certify on either locale.
    let measured: [(String, Int)] = [
        ("0 Markers", 0), ("1 Marker", 1), ("15 Markers", 15),
        ("0개의 마커", 0), ("1개의 마커", 1), ("2개의 마커", 2),
        ("0個のマーカー", 0), ("1個のマーカー", 1),
    ]
    for (raw, expected) in measured {
        #expect(AXLogicProElements.parseMarkerListItemCount(raw) == expected,
                "\"\(raw)\" is a measured live rendering and must parse as \(expected)")
    }
    // The rules the relaxation had to preserve: the value must OPEN with the digit run, no digit may
    // follow it, and an ASCII letter abutting the digits is still a refusal.
    for raw in ["Marker 2", "2 of 15", "1st", "0x1F", "1.1.1.1", "", "Markers"] {
        #expect(AXLogicProElements.parseMarkerListItemCount(raw) == nil,
                "\"\(raw)\" must not parse as a marker count")
    }
}
