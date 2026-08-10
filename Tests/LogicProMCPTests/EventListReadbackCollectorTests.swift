@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

#if QUALIFICATION_FAULT_SEAM
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
        let rows: [AXUIElement]
        let rowFields: [RowFields]
    }

    private final class SelectionCounter: @unchecked Sendable {
        var writes = 0
        var selectedIndices: [Int] = []
    }

    private static func fixture(
        headerTitles: [String] = Self.headerTitles,
        rowCount: Int = 2,
        hollowRows: Set<Int> = [],
        omittedFilterTitle: String? = nil,
        timeMark: String = "",
        positionText: String = "1 1 1 1"
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

        var rows: [AXUIElement] = []
        var rowFields: [RowFields] = []
        for rowIndex in 0..<rowCount {
            let row = element()
            let isHollow = hollowRows.contains(rowIndex)
            var fields: RowFields?
            var cells: [AXUIElement] = []
            for title in Self.headerTitles {
                let cell = element()
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

        let menuBar = element()
        let viewMenu = element()
        let displayMode = element()
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
        builder.setAttribute(viewMenu, kAXTitleAttribute as String, "View")
        builder.setRole(displayMode, kAXMenuItemRole as String)
        builder.setAttribute(displayMode, kAXTitleAttribute as String, "Event Position and Length as Time")
        builder.setAttribute(displayMode, kAXMenuItemMarkCharAttribute as String, timeMark)
        builder.setChildren(menuBar, [viewMenu])
        builder.setChildren(viewMenu, [displayMode])

        return Fixture(
            builder: builder,
            app: app,
            eventTab: eventTab,
            table: table,
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
}
#endif
