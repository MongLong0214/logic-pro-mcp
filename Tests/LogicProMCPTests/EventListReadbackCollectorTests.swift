@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

#if FAULT_TEST_SEAM
@Suite struct EventListReadbackCollectorTests {
    private static let headerTitles = [
        "L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info",
    ]

    private struct RowFields {
        let position: AXUIElement
        let number: AXUIElement
        let value: AXUIElement
    }

    private struct Fixture {
        let builder: FakeAXRuntimeBuilder
        let app: AXUIElement
        let eventTab: AXUIElement
        let table: AXUIElement
        let viewButton: AXUIElement
        let viewMenu: AXUIElement
        let rows: [AXUIElement]
        let rowFields: [RowFields]
    }

    private final class SelectionCounter: @unchecked Sendable {
        var writes = 0
        var selectedIndices: [Int] = []
    }

    private final class MenuActionCounter: @unchecked Sendable {
        var actions: [String] = []
        var viewButtonReadsAfterShow = 0
    }

    private static func fixture(
        headerTitles: [String] = Self.headerTitles,
        decoyHeaderTitles: [String]? = nil,
        rowCount: Int = 2,
        hollowRows: Set<Int> = [],
        omittedFilterTitle: String? = nil,
        timeMark: String = "",
        positionText: String = "1 1 1 1",
        viewMenuInitiallyOpen: Bool = true,
        includeDisplayMode: Bool = true
    ) -> Fixture {
        let builder = FakeAXRuntimeBuilder()
        var nextID = 1
        func element() -> AXUIElement {
            defer { nextID += 1 }
            return builder.element(nextID)
        }

        let app = element()
        let window = element()
        let pane = element()
        let eventTab = element()
        let table = element()
        let header = element()

        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setRole(window, kAXWindowRole as String)
        builder.setChildren(window, [pane])
        builder.setAttribute(pane, kAXParentAttribute as String, window)
        builder.setRole(pane, kAXGroupRole as String)
        builder.setChildren(pane, [eventTab, table])
        builder.setAttribute(eventTab, kAXParentAttribute as String, pane)
        builder.setRole(eventTab, kAXRadioButtonRole as String)
        builder.setAttribute(eventTab, kAXDescriptionAttribute as String, "Event")
        builder.setAttribute(eventTab, kAXTitleAttribute as String, "")
        builder.setAttribute(eventTab, kAXValueAttribute as String, 0)
        builder.setAttribute(table, kAXParentAttribute as String, pane)
        builder.setRole(table, kAXTableRole as String)
        builder.setAttribute(table, kAXHeaderAttribute as String, header)

        let headerButtons = headerTitles.map { title -> AXUIElement in
            let button = element()
            builder.setRole(button, kAXButtonRole as String)
            builder.setAttribute(button, kAXSubroleAttribute as String, "AXSortButton")
            builder.setAttribute(button, kAXTitleAttribute as String, title)
            return button
        }
        builder.setChildren(header, headerButtons)

        // A sibling list in the same pane. Live Logic really does have one — resolving the table by
        // "first ancestor containing a table" threw `eventTableAmbiguous(count: 2)` against real
        // Logic (see findEventPaneAndTable). Every fixture here modelled a lone table, so nothing
        // made the collector say WHICH table was the Event pane's.
        if let decoyHeaderTitles {
            let decoy = element()
            let decoyHeader = element()
            builder.setAttribute(decoy, kAXParentAttribute as String, pane)
            builder.setRole(decoy, kAXTableRole as String)
            builder.setAttribute(decoy, kAXHeaderAttribute as String, decoyHeader)
            builder.setChildren(decoyHeader, decoyHeaderTitles.map { title -> AXUIElement in
                let button = element()
                builder.setRole(button, kAXButtonRole as String)
                builder.setAttribute(button, kAXSubroleAttribute as String, "AXSortButton")
                builder.setAttribute(button, kAXTitleAttribute as String, title)
                return button
            })
            builder.setChildren(pane, [eventTab, table, decoy])
        }

        var rows: [AXUIElement] = []
        var rowFields: [RowFields] = []
        for rowIndex in 0..<rowCount {
            let row = element()
            let isHollow = hollowRows.contains(rowIndex)
            var fields: RowFields?
            var cells: [AXUIElement] = []
            for title in Self.headerTitles {
                let cell = element()
                // #293: L and M are the Lock and Mute FLAGS, and an unset flag is an EMPTY cell.
                // Measured live on a three-note region, every row reads cell child counts
                // [0, 0, 1, 1, 1, 1, 1, 1] — and those two cells expose no value-bearing attribute
                // either (19 attribute names, all structural). This fixture used to give them a child
                // like every other column, which is a shape Logic does not produce, and the collector
                // was written against the fixture: run against a real note it threw
                // `cellChildCountMismatch(row: 0, column: "L", actual: 0)` on the very first cell.
                if title == "L" || title == "M" {
                    builder.setChildren(cell, [])
                    cells.append(cell)
                    continue
                }
                let child = element()
                builder.setChildren(cell, [child])
                switch title {
                case "Position":
                    if !isHollow {
                        builder.setAttribute(child, kAXDescriptionAttribute as String, positionText)
                    }
                    let number = element()
                    let velocity = element()
                    fields = RowFields(position: child, number: number, value: velocity)
                    // The extra elements are used by their respective columns below.
                case "Status":
                    builder.setAttribute(child, kAXDescriptionAttribute as String, "Note")
                case "Ch":
                    builder.setAttribute(child, kAXValueAttribute as String, 1)
                case "Num":
                    guard let fields else { fatalError("Position must precede Num") }
                    builder.setChildren(cell, [fields.number])
                    if !isHollow {
                        builder.setAttribute(fields.number, kAXValueAttribute as String, 60)
                    }
                case "Val":
                    guard let fields else { fatalError("Position must precede Val") }
                    builder.setChildren(cell, [fields.value])
                    builder.setAttribute(fields.value, kAXValueAttribute as String, 17)
                    if !isHollow {
                        builder.setAttribute(fields.value, kAXValueDescriptionAttribute as String, "100")
                    }
                case "Length/Info":
                    builder.setAttribute(child, kAXDescriptionAttribute as String, "0 1 0 0")
                default:
                    builder.setAttribute(child, kAXDescriptionAttribute as String, "")
                }
                cells.append(cell)
            }
            guard let fields else { fatalError("missing Position cell") }
            builder.setChildren(row, cells)
            rows.append(row)
            rowFields.append(fields)
        }
        builder.setAttribute(table, "AXRows", rows)
        builder.setAttribute(table, kAXSelectedRowsAttribute as String, rows.prefix(1).map { $0 })

        for (filterTitle, _) in filterControls where filterTitle != omittedFilterTitle {
            let checkbox = element()
            builder.setRole(checkbox, kAXCheckBoxRole as String)
            builder.setAttribute(checkbox, kAXTitleAttribute as String, filterTitle)
            builder.setAttribute(checkbox, kAXValueAttribute as String, 1)
            builder.setAttribute(checkbox, kAXParentAttribute as String, pane)
            builder.setChildren(pane, AXHelpers.getChildren(pane, runtime: builder.makeAXRuntime()) + [checkbox])
        }

        for (help, value) in [("Number of Items", "\(rowCount) Events"), ("Region Path", "Region 1")] {
            let text = element()
            builder.setRole(text, kAXStaticTextRole as String)
            builder.setAttribute(text, kAXHelpAttribute as String, help)
            builder.setAttribute(text, kAXValueAttribute as String, value)
            builder.setAttribute(text, kAXParentAttribute as String, pane)
            builder.setChildren(pane, AXHelpers.getChildren(pane, runtime: builder.makeAXRuntime()) + [text])
        }

        // The display-mode setting hangs off the EVENT PANE's own View menu button, beside the
        // column toggles — not the application menu bar. This fixture used to place it on the menu
        // bar, which is why the collector could search there and pass here while failing on every
        // real Logic (#524). Measured on 12.3: the app View menu has sixteen entries and none is
        // this one.
        let viewButton = element()
        let viewMenu = element()
        let displayMode = element()
        builder.setRole(viewButton, kAXMenuButtonRole as String)
        builder.setAttribute(viewButton, kAXTitleAttribute as String, "View")
        builder.setAttribute(viewButton, kAXParentAttribute as String, pane)
        builder.setActionNames(viewButton, [kAXShowMenuAction as String])
        builder.setRole(viewMenu, kAXMenuRole as String)
        builder.setActionNames(viewMenu, [kAXCancelAction as String])
        builder.setRole(displayMode, kAXMenuItemRole as String)
        builder.setAttribute(displayMode, kAXTitleAttribute as String, "Event Position and Length as Time")
        builder.setAttribute(displayMode, kAXMenuItemMarkCharAttribute as String, timeMark)
        builder.setChildren(viewMenu, includeDisplayMode ? [displayMode] : [])
        builder.setChildren(viewButton, viewMenuInitiallyOpen ? [viewMenu] : [])
        builder.setChildren(pane, AXHelpers.getChildren(pane, runtime: builder.makeAXRuntime()) + [viewButton])

        return Fixture(
            builder: builder,
            app: app,
            eventTab: eventTab,
            table: table,
            viewButton: viewButton,
            viewMenu: viewMenu,
            rows: rows,
            rowFields: rowFields
        )
    }

    private static let filterControls = [
        ("Notes", FilterControlID.noteEvents),
        ("Progr. Change", FilterControlID.programChange),
        ("Pitch Bend", FilterControlID.pitchBend),
        ("Controller", FilterControlID.controller),
        ("Aftertouch", FilterControlID.aftertouch),
        ("Poly Aftertouch", FilterControlID.polyAftertouch),
        ("Syst. Exclusive", FilterControlID.systemExclusive),
        ("Additional Info", FilterControlID.additionalInfo),
    ]

    private static func collect(
        _ fixture: Fixture,
        runtime: AXLogicProElements.Runtime? = nil
    ) throws -> EventListReadbackEvidence {
        let region = MIDIRegionReference(
            targetRef: TargetReference(rawValue: "trk_event_list"),
            regionIndex: 0
        )
        let resolved = RegionIdentityRegistrySeam.mint(
            boundRegion: region,
            identity: ResolvedRegionIdentity(name: "Region 1", ordinal: 0, startTick: 0)
        )
        return try EventListReadbackCollector.collect(
            requestedRegion: region,
            resolvedIdentity: resolved,
            projectEpochBefore: 7,
            projectEpochAfter: 7,
            ppq: 480,
            runtime: runtime ?? fixture.builder.makeLogicRuntime(appElement: fixture.app)
        )
    }

    private static func toggleEventTabRuntime(_ fixture: Fixture) -> AXLogicProElements.Runtime {
        let builder = fixture.builder
        let eventTab = fixture.eventTab
        return builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                guard element == eventTab, action == (kAXPressAction as String) else { return true }
                let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                return true
            }
        )
    }

    private static func ownedViewMenuRuntime(
        _ fixture: Fixture,
        cancelSucceeds: Bool = true,
        delayedAppearanceReads: Int = 0,
        closureReadFails: Bool = false
    ) -> (AXLogicProElements.Runtime, MenuActionCounter) {
        let builder = fixture.builder
        let eventTab = fixture.eventTab
        let viewButton = fixture.viewButton
        let viewMenu = fixture.viewMenu
        let counter = MenuActionCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: fixture.app,
            childrenHandler: { element in
                if counter.actions.contains(kAXCancelAction as String) { return nil }
                guard element == viewButton,
                      delayedAppearanceReads > 0,
                      counter.actions.contains(kAXShowMenuAction as String) else { return nil }
                counter.viewButtonReadsAfterShow += 1
                if counter.viewButtonReadsAfterShow <= delayedAppearanceReads { return [] }
                builder.setChildren(viewButton, [viewMenu])
                return [viewMenu]
            },
            childrenResultHandler: { element in
                if closureReadFails,
                   element == viewButton,
                   counter.actions.contains(kAXCancelAction as String) {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                if counter.actions.contains(kAXCancelAction as String) { return nil }
                guard element == viewButton,
                      delayedAppearanceReads > 0,
                      counter.actions.contains(kAXShowMenuAction as String) else { return nil }
                counter.viewButtonReadsAfterShow += 1
                if counter.viewButtonReadsAfterShow <= delayedAppearanceReads { return .success([]) }
                builder.setChildren(viewButton, [viewMenu])
                return .success([viewMenu])
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                if element == eventTab, action == (kAXPressAction as String) {
                    let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                    builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                    return true
                }
                if element == viewButton, action == (kAXShowMenuAction as String) {
                    counter.actions.append(action)
                    if delayedAppearanceReads == 0 { builder.setChildren(viewButton, [viewMenu]) }
                    return true
                }
                if element == viewMenu, action == (kAXCancelAction as String) {
                    counter.actions.append(action)
                    if cancelSucceeds { builder.setChildren(viewButton, []) }
                    return cancelSucceeds
                }
                return true
            }
        )
        return (runtime, counter)
    }

    /// A six-column list that is NOT the region level. Arity-only matching accepted it — the note
    /// schema has eight columns and the region schema six, so "8 or 6" bound this too and the
    /// resolve went ambiguous. The labels are what separate them.
    private static let decoyHeaderTitles = ["L", "M", "Position", "Marker", "Color", "Note"]

    @Test func aSiblingListWithSixColumnsIsNotTheEventTable() throws {
        let fixture = Self.fixture(decoyHeaderTitles: Self.decoyHeaderTitles)
        let runtime = fixture.builder.makeLogicRuntime(appElement: fixture.app)
        fixture.builder.setAttribute(fixture.eventTab, kAXValueAttribute as String, 1)

        // Binding by column COUNT throws `eventTableAmbiguous(count: 2)` here.
        let seen = try EventListReadbackCollector.observeNoteTable(runtime: runtime)
        #expect(seen.rows.count == 2)
        // The titles it REPORTS are the ones the header carried, not the canonical constants the
        // row keys are minted from — otherwise a harness reading them compares English to English.
        #expect(seen.liveHeaderTitles == Self.headerTitles)
        #expect(seen.rawItemCountText == "2 Events")
        #expect(seen.rawRegionPath == "Region 1")
    }

    @Test func theProbeRefusesRatherThanSelectingTheEventTab() throws {
        let fixture = Self.fixture()
        let runtime = fixture.builder.makeLogicRuntime(appElement: fixture.app)
        // AXValue 0: the pane is open on some other tab.
        #expect(throws: EventListProbeRefusal.eventTabNotSelected) {
            _ = try EventListReadbackCollector.observeNoteTable(runtime: runtime)
        }
        // ... and it did not press its way there.
        #expect((AXHelpers.getAttribute(fixture.eventTab, kAXValueAttribute as String, runtime: runtime.ax) as Int?) == 0)
        let refusal = EventListProbeRefusal.eventTabNotSelected.description
        #expect(refusal.contains("terminated without changing the Event List"))
        #expect(!refusal.contains("open the Event List"))
        #expect(!refusal.contains("choose the Event tab"))
    }

    @Test func headerMismatchIsRefused() throws {
        let fixture = Self.fixture(headerTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Velocity", "Length/Info"])
        #expect(throws: EventListReadbackCollectorError.headerMismatch(expected: "Val", actual: "Velocity")) {
            try Self.collect(fixture, runtime: Self.toggleEventTabRuntime(fixture))
        }
    }

    @Test func hiddenColumnIsRefusedByName() throws {
        let fixture = Self.fixture(headerTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Length/Info"])
        #expect(throws: EventListReadbackCollectorError.headerMismatch(expected: "Val", actual: "Length/Info")) {
            try Self.collect(fixture, runtime: Self.toggleEventTabRuntime(fixture))
        }
    }

    @Test func hollowRowsAreCompletedBySelectingFirstUnpopulatedRow() throws {
        let fixture = Self.fixture(rowCount: 3, hollowRows: [1, 2])
        let counter = SelectionCounter()
        let builder = fixture.builder
        let table = fixture.table
        let rows = fixture.rows
        let fields = fixture.rowFields
        let eventTab = fixture.eventTab
        let runtime = builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: { element, attribute, value in
                if element == table, attribute == (kAXSelectedRowsAttribute as String) {
                    counter.writes += 1
                    builder.setAttribute(element, attribute, value)
                    let selected: [AXUIElement]? = builder.attributeValue(
                        table,
                        kAXSelectedRowsAttribute as String
                    ) as? [AXUIElement]
                    if let selectedRow = selected?.first,
                       let index = rows.firstIndex(where: { $0 == selectedRow }) {
                        counter.selectedIndices.append(index)
                        if index == 1 {
                            for field in fields {
                                builder.setAttribute(field.position, kAXDescriptionAttribute as String, "1 1 1 1")
                                builder.setAttribute(field.number, kAXValueAttribute as String, 60)
                                builder.setAttribute(field.value, kAXValueDescriptionAttribute as String, "100")
                            }
                        }
                    }
                    return true
                }
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, action in
                guard element == eventTab, action == (kAXPressAction as String) else { return true }
                let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                return true
            }
        )

        let evidence = try Self.collect(fixture, runtime: runtime)
        #expect(evidence.harvest.orderedRowKeys.count == 3)
        #expect(evidence.harvest.passA.count == 3)
        #expect(counter.writes >= 2) // one materialization selection plus restoration
        #expect(counter.selectedIndices.first == 1)
    }

    @Test func virtualizedWindowsAreAccumulatedAcrossTwoIndependentPasses() throws {
        let fixture = Self.fixture(rowCount: 96, hollowRows: Set(32..<96))
        let counter = SelectionCounter()
        let builder = fixture.builder
        let table = fixture.table
        let rows = fixture.rows
        let fields = fixture.rowFields
        let eventTab = fixture.eventTab

        for rowIndex in 0..<32 {
            builder.setAttribute(fields[rowIndex].position, kAXDescriptionAttribute as String, "1 1 1 \(rowIndex + 1)")
            builder.setAttribute(fields[rowIndex].number, kAXValueAttribute as String, 60 + (rowIndex % 12))
            builder.setAttribute(fields[rowIndex].value, kAXValueDescriptionAttribute as String, "100")
        }

        let runtime = builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: { element, attribute, value in
                if element == table, attribute == (kAXSelectedRowsAttribute as String) {
                    counter.writes += 1
                    builder.setAttribute(element, attribute, value)
                    let selected: [AXUIElement]? = builder.attributeValue(
                        table,
                        kAXSelectedRowsAttribute as String
                    ) as? [AXUIElement]
                    if let selectedRow = selected?.first,
                       let index = rows.firstIndex(where: { $0 == selectedRow }) {
                        counter.selectedIndices.append(index)
                        let start = (index / 32) * 32
                        let visible = start..<min(start + 32, rows.count)
                        for rowIndex in rows.indices {
                            if visible.contains(rowIndex) {
                                builder.setAttribute(fields[rowIndex].position, kAXDescriptionAttribute as String, "1 1 1 \(rowIndex + 1)")
                                builder.setAttribute(fields[rowIndex].number, kAXValueAttribute as String, 60 + (rowIndex % 12))
                                builder.setAttribute(fields[rowIndex].value, kAXValueDescriptionAttribute as String, "100")
                            } else {
                                builder.removeAttribute(fields[rowIndex].position, kAXDescriptionAttribute as String)
                                builder.removeAttribute(fields[rowIndex].number, kAXValueAttribute as String)
                                builder.removeAttribute(fields[rowIndex].value, kAXValueDescriptionAttribute as String)
                            }
                        }
                    }
                    return true
                }
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, action in
                guard element == eventTab, action == (kAXPressAction as String) else { return true }
                let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                return true
            }
        )

        let evidence = try Self.collect(fixture, runtime: runtime)

        #expect(evidence.harvest.orderedRowKeys.map(\.index) == Array(0..<96))
        #expect(evidence.harvest.passA.count == 96)
        #expect(evidence.harvest.passB.count == 96)
        #expect(!evidence.harvest.exhaustion.isProven)
        // Pass A materializes 32 then 64. Pass B starts from the last visible window,
        // independently wraps to 0 then 32, and restoration finally selects the original row 0.
        // A collector that aliases pass B to pass A produces only [32, 64, 0].
        #expect(counter.writes == 5)
        #expect(counter.selectedIndices == [32, 64, 0, 32, 0])
    }

    @Test func unreadableOriginalRowSelectionRefusesBeforeAnyActuation() throws {
        let fixture = Self.fixture(rowCount: 3, hollowRows: [1, 2])
        let selectionCounter = SelectionCounter()
        let actionCounter = MenuActionCounter()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            attributeValueResultHandler: { element, attribute in
                if element == fixture.table,
                   attribute == (kAXSelectedRowsAttribute as String) {
                    return .failure(.init(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            setAttributeHandler: { _, _, _ in
                selectionCounter.writes += 1
                return true
            },
            performActionHandler: { _, action in
                actionCounter.actions.append(action)
                return true
            }
        )

        #expect(throws: EventListReadbackCollectorError.rowSelectionBaselineUnavailable(
            status: AXError.cannotComplete.rawValue
        )) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect(selectionCounter.writes == 0)
        #expect(actionCounter.actions.isEmpty)
    }

    @Test func malformedOriginalRowSelectionRefusesBeforeAnyActuation() throws {
        let fixture = Self.fixture(rowCount: 3, hollowRows: [1, 2])
        let selectionCounter = SelectionCounter()
        let actionCounter = MenuActionCounter()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            attributeValueResultHandler: { element, attribute in
                if element == fixture.table,
                   attribute == (kAXSelectedRowsAttribute as String) {
                    return .success("not rows" as NSString)
                }
                return nil
            },
            setAttributeHandler: { _, _, _ in
                selectionCounter.writes += 1
                return true
            },
            performActionHandler: { _, action in
                actionCounter.actions.append(action)
                return true
            }
        )

        #expect(throws: EventListReadbackCollectorError.rowSelectionBaselineMalformed) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect(selectionCounter.writes == 0)
        #expect(actionCounter.actions.isEmpty)
    }

    @Test func successfulHarvestRefusesWhenOriginalRowSelectionCannotBeRestored() throws {
        let fixture = Self.fixture(rowCount: 3, hollowRows: [1, 2])
        let builder = fixture.builder
        let table = fixture.table
        let rows = fixture.rows
        let fields = fixture.rowFields
        let eventTab = fixture.eventTab
        let counter = SelectionCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: { element, attribute, value in
                if element == table, attribute == (kAXSelectedRowsAttribute as String) {
                    counter.writes += 1
                    // The host can report a successful AX write without changing the selection.
                    // The collector must read back the exact original row instead of trusting it.
                    guard counter.writes == 1 else { return true }
                    builder.setAttribute(element, attribute, value)
                    for field in fields {
                        builder.setAttribute(field.position, kAXDescriptionAttribute as String, "1 1 1 1")
                        builder.setAttribute(field.number, kAXValueAttribute as String, 60)
                        builder.setAttribute(field.value, kAXValueDescriptionAttribute as String, "100")
                    }
                    return true
                }
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, action in
                guard element == eventTab, action == (kAXPressAction as String) else { return true }
                let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                return true
            }
        )

        #expect(throws: EventListReadbackCollectorError.rowSelectionRestorationFailed(primary: nil)) {
            try Self.collect(fixture, runtime: runtime)
        }
        let selected: [AXUIElement]? = builder.attributeValue(
            table,
            kAXSelectedRowsAttribute as String
        ) as? [AXUIElement]
        #expect(selected?.first == rows[1])
    }

    @Test func rowSelectionRestorationFailurePreservesThePrimaryRefusal() throws {
        let fixture = Self.fixture(
            rowCount: 3,
            hollowRows: [1, 2],
            timeMark: "✓",
            positionText: "01:00:00:00.00"
        )
        let builder = fixture.builder
        let table = fixture.table
        let fields = fixture.rowFields
        let eventTab = fixture.eventTab
        let counter = SelectionCounter()
        let runtime = builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: { element, attribute, value in
                if element == table, attribute == (kAXSelectedRowsAttribute as String) {
                    counter.writes += 1
                    guard counter.writes == 1 else { return false }
                    builder.setAttribute(element, attribute, value)
                    for field in fields {
                        builder.setAttribute(field.position, kAXDescriptionAttribute as String, "01:00:00:00.00")
                        builder.setAttribute(field.number, kAXValueAttribute as String, 60)
                        builder.setAttribute(field.value, kAXValueDescriptionAttribute as String, "100")
                    }
                    return true
                }
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, action in
                guard element == eventTab, action == (kAXPressAction as String) else { return true }
                let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                return true
            }
        )

        #expect(throws: EventListReadbackCollectorError.rowSelectionRestorationFailed(primary: .timeDisplayEnabled)) {
            try Self.collect(fixture, runtime: runtime)
        }
    }

    @Test func materializationExhaustionIsIncomplete() throws {
        let fixture = Self.fixture(rowCount: 65, hollowRows: Set(0..<65))
        let builder = fixture.builder
        let table = fixture.table
        let eventTab = fixture.eventTab
        let runtime = builder.makeLogicRuntime(
            appElement: fixture.app,
            setAttributeHandler: { element, attribute, value in
                builder.setAttribute(element, attribute, value)
                return true
            },
            performActionHandler: { element, action in
                guard element == eventTab, action == (kAXPressAction as String) else { return true }
                let old = (builder.attributeValue(eventTab, kAXValueAttribute as String) as? Int) ?? 0
                builder.setAttribute(eventTab, kAXValueAttribute as String, old == 0 ? 1 : 0)
                return true
            }
        )
        #expect(throws: EventListReadbackCollectorError.harvestIncomplete(populated: 0, total: 65, passes: 64)) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect(builder.attributeValue(table, kAXSelectedRowsAttribute as String) != nil)
    }

    @Test func timeDisplayIsRefused() throws {
        let fixture = Self.fixture(timeMark: "✓", positionText: "01:00:00:00.00")
        #expect(throws: EventListReadbackCollectorError.timeDisplayEnabled) {
            try Self.collect(fixture, runtime: Self.toggleEventTabRuntime(fixture))
        }
    }

    @Test func aViewMenuOpenedByTheCollectorIsCancelledAfterSuccess() throws {
        let fixture = Self.fixture(viewMenuInitiallyOpen: false)
        let (runtime, counter) = Self.ownedViewMenuRuntime(fixture)

        _ = try Self.collect(fixture, runtime: runtime)

        #expect(counter.actions == [kAXShowMenuAction as String, kAXCancelAction as String])
        #expect(AXHelpers.getChildren(fixture.viewButton, runtime: runtime.ax).isEmpty)
    }

    @Test func aViewMenuOpenedByTheCollectorIsCancelledAfterRefusal() throws {
        let fixture = Self.fixture(
            timeMark: "✓",
            positionText: "01:00:00:00.00",
            viewMenuInitiallyOpen: false
        )
        let (runtime, counter) = Self.ownedViewMenuRuntime(fixture)

        #expect(throws: EventListReadbackCollectorError.timeDisplayEnabled) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect(counter.actions == [kAXShowMenuAction as String, kAXCancelAction as String])
        #expect(AXHelpers.getChildren(fixture.viewButton, runtime: runtime.ax).isEmpty)
    }

    @Test func aMissingDisplayItemStillCancelsTheOwnedViewMenu() throws {
        let fixture = Self.fixture(viewMenuInitiallyOpen: false, includeDisplayMode: false)
        let (runtime, counter) = Self.ownedViewMenuRuntime(fixture)

        #expect(throws: EventListReadbackCollectorError.displayModeUnavailable) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect(counter.actions == [kAXShowMenuAction as String, kAXCancelAction as String])
    }

    @Test func aViewMenuThatWasAlreadyOpenIsNotCancelled() throws {
        let fixture = Self.fixture()
        let (runtime, counter) = Self.ownedViewMenuRuntime(fixture)

        _ = try Self.collect(fixture, runtime: runtime)

        #expect(counter.actions.isEmpty)
        #expect(AXHelpers.getChildren(fixture.viewButton, runtime: runtime.ax).count == 1)
    }

    @Test func anUnreadableBaselineDoesNotAcquireOrCancelTheUsersMenu() throws {
        let fixture = Self.fixture()
        let counter = MenuActionCounter()
        let runtime = fixture.builder.makeLogicRuntime(
            appElement: fixture.app,
            childrenHandler: { element in
                element == fixture.viewButton ? [] : nil
            },
            childrenResultHandler: { element in
                element == fixture.viewButton
                    ? .failure(.init(raw: AXError.cannotComplete.rawValue))
                    : nil
            },
            setAttributeHandler: nil,
            performActionHandler: { element, action in
                if element == fixture.eventTab, action == (kAXPressAction as String) {
                    let old = (fixture.builder.attributeValue(
                        fixture.eventTab,
                        kAXValueAttribute as String
                    ) as? Int) ?? 0
                    fixture.builder.setAttribute(
                        fixture.eventTab,
                        kAXValueAttribute as String,
                        old == 0 ? 1 : 0
                    )
                    return true
                }
                counter.actions.append(action)
                return true
            }
        )

        #expect(throws: EventListReadbackCollectorError.displayModeUnavailable) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect(counter.actions.isEmpty)
    }

    @Test func aDelayedOwnedViewMenuIsObservedAndCancelled() throws {
        let fixture = Self.fixture(viewMenuInitiallyOpen: false)
        let (runtime, counter) = Self.ownedViewMenuRuntime(
            fixture,
            delayedAppearanceReads: 1
        )

        _ = try Self.collect(fixture, runtime: runtime)

        #expect(counter.actions == [kAXShowMenuAction as String, kAXCancelAction as String])
        #expect(counter.viewButtonReadsAfterShow >= 2)
    }

    @Test func anUnreadablePostCancelStateIsNotAcceptedAsClosed() throws {
        let fixture = Self.fixture(viewMenuInitiallyOpen: false)
        let (runtime, counter) = Self.ownedViewMenuRuntime(
            fixture,
            closureReadFails: true
        )

        do {
            _ = try Self.collect(fixture, runtime: runtime)
            Issue.record("expected View-menu restoration failure")
        } catch let error as EventListReadbackCollectorError {
            #expect(error.description.contains("View menu"))
        }
        #expect(counter.actions == [kAXShowMenuAction as String, kAXCancelAction as String])
    }

    @Test func cancelFailurePreservesThePrimaryRefusalAndReportsRestorationFailure() throws {
        let fixture = Self.fixture(
            timeMark: "✓",
            positionText: "01:00:00:00.00",
            viewMenuInitiallyOpen: false
        )
        let (runtime, counter) = Self.ownedViewMenuRuntime(fixture, cancelSucceeds: false)

        do {
            _ = try Self.collect(fixture, runtime: runtime)
            Issue.record("expected display-mode refusal plus View-menu restoration failure")
        } catch let error as EventListReadbackCollectorError {
            #expect(error == .viewMenuDismissalFailed(primary: .timeDisplayEnabled))
        }
        #expect(counter.actions == [kAXShowMenuAction as String, kAXCancelAction as String])
        #expect(AXHelpers.getChildren(fixture.viewButton, runtime: runtime.ax).count == 1)
    }

    @Test func incompleteFilterSetIsRefused() throws {
        let fixture = Self.fixture(omittedFilterTitle: "Controller")
        #expect(throws: EventListReadbackCollectorError.filterEvidenceIncomplete(title: "Controller")) {
            try Self.collect(fixture, runtime: Self.toggleEventTabRuntime(fixture))
        }
    }

    @Test func paneAndRowsAreRestoredAfterAnError() throws {
        let fixture = Self.fixture(headerTitles: ["L", "M", "Position", "Status", "Ch", "Num", "Velocity", "Length/Info"])
        let runtime = Self.toggleEventTabRuntime(fixture)
        #expect(throws: EventListReadbackCollectorError.headerMismatch(expected: "Val", actual: "Velocity")) {
            try Self.collect(fixture, runtime: runtime)
        }
        #expect((fixture.builder.attributeValue(fixture.eventTab, kAXValueAttribute as String) as? Int) == 0)
        let restored: [AXUIElement]? = fixture.builder.attributeValue(fixture.table, kAXSelectedRowsAttribute as String) as? [AXUIElement]
        #expect(restored?.count == 1)
        #expect(restored?.first == fixture.rows.first)
    }

    private static func stitchRow(_ value: Int) -> RawEventRow {
        [AXColumnID(id: "value"): RawCell(sliderValue: Double(value))]
    }

    private static func stitchWindow(
        total: Int,
        keys: [Int],
        value: (Int) -> Int = { $0 }
    ) -> EventListReadbackCollector.VirtualWindowObservation {
        EventListReadbackCollector.VirtualWindowObservation(
            totalRows: total,
            rows: keys.map {
                EventListReadbackCollector.VirtualWindowRow(
                    key: RowKey(index: $0),
                    row: Self.stitchRow(value($0))
                )
            }
        )
    }

    @Test func twoIndependentCompleteWindowPassesStitchWithoutMintingExhaustion() throws {
        let pass = [
            Self.stitchWindow(total: 5, keys: [0, 1, 2]),
            Self.stitchWindow(total: 5, keys: [2, 3, 4]),
        ]

        let harvest = try EventListReadbackCollector.stitchVirtualWindows([pass, pass])

        #expect(harvest.orderedRowKeys.map(\.index) == [0, 1, 2, 3, 4])
        #expect(harvest.passA.count == 5)
        #expect(harvest.passB.count == 5)
        #expect(!harvest.exhaustion.isProven)
    }

    @Test func oneCompleteWindowPassIsStillInsufficient() {
        let pass = [Self.stitchWindow(total: 2, keys: [0, 1])]

        #expect(throws: EventListReadbackCollector.WindowStitchRefusal.passCount(expected: 2, actual: 1)) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([pass])
        }
    }

    @Test func oneVisibleWindowNeverClaimsACompleteFortyRowTable() {
        let visible = [Self.stitchWindow(total: 40, keys: Array(0..<32))]

        #expect(
            throws: EventListReadbackCollector.WindowStitchRefusal.incomplete(
                pass: 0,
                missing: Array(32..<40)
            )
        ) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([visible, visible])
        }
    }

    @Test func overlappingWindowsMustAgreeOnTheSharedRow() {
        let changedOverlap = [
            Self.stitchWindow(total: 4, keys: [0, 1, 2]),
            Self.stitchWindow(total: 4, keys: [2, 3], value: { $0 == 2 ? 99 : $0 }),
        ]

        #expect(throws: EventListReadbackCollector.WindowStitchRefusal.overlapChanged(pass: 0, key: 2)) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([changedOverlap, changedOverlap])
        }
    }

    @Test func duplicateRowKeyInsideOneWindowIsRefused() {
        let duplicate = EventListReadbackCollector.VirtualWindowObservation(
            totalRows: 2,
            rows: [
                .init(key: RowKey(index: 0), row: Self.stitchRow(0)),
                .init(key: RowKey(index: 0), row: Self.stitchRow(0)),
            ]
        )

        #expect(throws: EventListReadbackCollector.WindowStitchRefusal.duplicateKey(pass: 0, window: 0, key: 0)) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([[duplicate], [duplicate]])
        }
    }

    @Test func totalDriftAndDisplacedRowsAreRefused() {
        let totalDrift = [
            Self.stitchWindow(total: 2, keys: [0]),
            Self.stitchWindow(total: 3, keys: [1, 2]),
        ]
        #expect(
            throws: EventListReadbackCollector.WindowStitchRefusal.totalChanged(
                pass: 0,
                window: 1,
                expected: 2,
                actual: 3
            )
        ) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([totalDrift, totalDrift])
        }

        let displaced = [Self.stitchWindow(total: 2, keys: [0, 2])]
        #expect(
            throws: EventListReadbackCollector.WindowStitchRefusal.rowOutOfRange(
                pass: 0,
                window: 0,
                key: 2,
                total: 2
            )
        ) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([displaced, displaced])
        }
    }

    @Test func completePassesMustAgreeOnEveryRow() {
        let first = [Self.stitchWindow(total: 3, keys: [0, 1, 2])]
        let second = [Self.stitchWindow(total: 3, keys: [0, 1, 2], value: { $0 == 1 ? 9 : $0 })]

        #expect(throws: EventListReadbackCollector.WindowStitchRefusal.passDrift(key: 1)) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([first, second])
        }
    }

    @Test func thousandRowsStitchWithoutLossButWrongCardinalityRefuses() throws {
        let complete = stride(from: 0, to: 1_000, by: 125).map { start in
            Self.stitchWindow(total: 1_000, keys: Array(start..<min(start + 125, 1_000)))
        }
        let harvest = try EventListReadbackCollector.stitchVirtualWindows([complete, complete])
        #expect(harvest.orderedRowKeys.count == 1_000)
        #expect(harvest.orderedRowKeys.first?.index == 0)
        #expect(harvest.orderedRowKeys.last?.index == 999)

        let missingLast = [Self.stitchWindow(total: 1_000, keys: Array(0..<999))]
        #expect(throws: EventListReadbackCollector.WindowStitchRefusal.incomplete(pass: 0, missing: [999])) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([missingLast, missingLast])
        }

        let missingFirst = [Self.stitchWindow(total: 1_000, keys: Array(1..<1_000))]
        #expect(throws: EventListReadbackCollector.WindowStitchRefusal.incomplete(pass: 0, missing: [0])) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([missingFirst, missingFirst])
        }

        let extra = [Self.stitchWindow(total: 1_000, keys: Array(0...1_000))]
        #expect(
            throws: EventListReadbackCollector.WindowStitchRefusal.rowOutOfRange(
                pass: 0,
                window: 0,
                key: 1_000,
                total: 1_000
            )
        ) {
            _ = try EventListReadbackCollector.stitchVirtualWindows([extra, extra])
        }
    }

    @Test func identicalPayloadAtDifferentKeysRemainsTwoRows() throws {
        let pass = [Self.stitchWindow(total: 2, keys: [0, 1], value: { _ in 7 })]

        let harvest = try EventListReadbackCollector.stitchVirtualWindows([pass, pass])

        #expect(harvest.orderedRowKeys.map(\.index) == [0, 1])
        #expect(harvest.passA[RowKey(index: 0)] == harvest.passA[RowKey(index: 1)])
    }
}
#endif
