@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// List-view export panel, modelled on the tree measured on Logic Pro 13.0
/// (7801): the browser is an `AXOutline` (id `ListView`) whose rows are
/// `AXRow > AXCell > AXTextField(AXURL)`. There is no `AXGroup` or `AXList`
/// ancestor. Selecting a row writes `AXSelectedRows` on the outline; a folder's
/// children appear only after its row is disclosed. The destination popup names
/// the directory being browsed, not the selected folder.
private final class ListViewPanelState: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let panel: AXUIElement
    let outline: AXUIElement
    private var nextID = 100
    private var rows: [AXUIElement] = []
    private var pathByRowID: [Int: String] = [:]
    private let childrenByPath: [String: [String]]
    private let echoesSelection: Bool
    private(set) var selectedRowsWrites: [String] = []
    private(set) var disclosedPaths: [String] = []
    private var now: UInt64 = 0

    init(
        initialRows: [String],
        childrenByPath: [String: [String]],
        echoesSelection: Bool = true
    ) {
        self.childrenByPath = childrenByPath
        self.echoesSelection = echoesSelection
        app = builder.element(1)
        panel = builder.element(2)
        outline = builder.element(3)
        let popup = builder.element(4)
        let export = builder.element(5)
        let cancel = builder.element(6)
        let perTrack = builder.element(7)
        builder.setRole(panel, kAXWindowRole as String)
        builder.setAttribute(panel, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        builder.setRole(popup, kAXPopUpButtonRole as String)
        builder.setAttribute(popup, kAXTitleAttribute as String, "Location:")
        builder.setAttribute(popup, kAXValueAttribute as String, "Browsed Directory")
        builder.setRole(perTrack, kAXPopUpButtonRole as String)
        builder.setAttribute(perTrack, kAXValueAttribute as String, "One File per Track")
        builder.setButton(export, title: "Export", x: 100, y: 100, width: 70, height: 24)
        builder.setButton(cancel, title: "Cancel", x: 180, y: 100, width: 70, height: 24)
        builder.setRole(outline, kAXOutlineRole as String)
        var children = [popup, perTrack]
        for (offset, value) in ["AIFF", "16-bit", "Normalize", "Include Audio Tail"].enumerated() {
            let option = builder.element(10 + offset)
            builder.setRole(option, kAXPopUpButtonRole as String)
            builder.setAttribute(option, kAXValueAttribute as String, value)
            children.append(option)
        }
        children += [export, cancel, outline]
        builder.setChildren(panel, children)
        builder.setAttribute(app, kAXWindowsAttribute as String, [panel])
        append(initialRows)
    }

    private func append(_ paths: [String]) {
        for path in paths {
            let row = builder.element(nextID)
            let cell = builder.element(nextID + 1)
            let field = builder.element(nextID + 2)
            nextID += 3
            builder.setRole(row, kAXRowRole as String)
            builder.setRole(cell, kAXCellRole as String)
            builder.setRole(field, kAXTextFieldRole as String)
            builder.setAttribute(field, kAXURLAttribute as String, URL(fileURLWithPath: path) as NSURL)
            builder.setChildren(cell, [field])
            builder.setChildren(row, [cell])
            rows.append(row)
            pathByRowID[builder.elementID(row)] = path
        }
        builder.setChildren(outline, rows)
    }

    func write(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        if attribute == (kAXDisclosingAttribute as String),
           let path = pathByRowID[builder.elementID(element)] {
            disclosedPaths.append(path)
            builder.setAttribute(element, attribute, value)
            append(childrenByPath[path] ?? [])
            return true
        }
        guard attribute == (kAXSelectedRowsAttribute as String),
              CFEqual(element, outline),
              let selected = value as? [AXUIElement],
              let row = selected.first,
              let path = pathByRowID[builder.elementID(row)] else {
            builder.setAttribute(element, attribute, value)
            return true
        }
        selectedRowsWrites.append(path)
        guard echoesSelection else { return false }
        builder.setAttribute(element, attribute, value)
        return true
    }

    func selectRow(at path: String) {
        guard let row = rows.first(where: { pathByRowID[builder.elementID($0)] == path }) else { return }
        builder.setAttribute(outline, kAXSelectedRowsAttribute as String, [row])
    }

    func directoryListing(at path: String) -> AXSurface.DirectoryListing {
        (childrenByPath[path] ?? []).isEmpty ? .empty : .hasEntries
    }

    func advance(_ nanos: UInt64) { now += nanos }
    func clock() -> UInt64 { now }

    func makeSurface() -> AXSurface {
        let runtime = builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { [self] element, attribute, value in
                write(element, attribute, value)
            },
            performActionHandler: nil
        )
        return AXSurface(
            runtime: runtime,
            directoryListing: { [self] path in directoryListing(at: path) },
            navigationNowNanos: { [self] in clock() },
            navigationSleep: { [self] duration in advance(duration) }
        )
    }
}

@Suite("#1553 stem export destination in the file browser's List view")
struct Issue1553StemListViewTests {
    @Test("selects a listed destination row through the browser outline")
    func selectsDestinationRowInListView() {
        let destination = "/Users/fixture/Exports"
        let state = ListViewPanelState(
            initialRows: ["/Users/fixture/Exports", "/Users/fixture/Other"],
            childrenByPath: [destination: ["\(destination)/Rendered"]]
        )
        let surface = state.makeSurface()

        let result = surface.selectDestinationBrowserElement(at: destination)

        #expect(result == .selected)
        #expect(state.selectedRowsWrites == [destination])
        #expect(surface.listViewSelectionConfirms(destination))
    }

    @Test("discloses each folder on the way and selects only the last row")
    func descendsThroughDisclosedRows() {
        let first = "/Users/fixture/Exports"
        let destination = "\(first)/Mixes"
        let state = ListViewPanelState(
            initialRows: [first],
            childrenByPath: [first: [destination], destination: ["\(destination)/Rendered"]]
        )
        let surface = state.makeSurface()

        let result = surface.selectDestinationBrowserElement(at: destination)

        #expect(result == .selected)
        #expect(state.disclosedPaths == [first, destination])
        #expect(state.selectedRowsWrites == [first, destination])
        #expect(surface.listViewSelectionConfirms(destination))
        #expect(!surface.listViewSelectionConfirms(first))
    }

    @Test("an empty destination folder is selected without being disclosed")
    func emptyDestinationNeedsNoDisclosure() {
        let destination = "/Users/fixture/Exports"
        let state = ListViewPanelState(initialRows: [destination], childrenByPath: [:])
        let surface = state.makeSurface()

        #expect(surface.selectDestinationBrowserElement(at: destination) == .selected)
        #expect(state.disclosedPaths.isEmpty)
        #expect(surface.listViewSelectionConfirms(destination))
    }

    @Test("a selection the panel does not echo is refused")
    func unechoedSelectionIsRefused() {
        let destination = "/Users/fixture/Exports"
        let state = ListViewPanelState(
            initialRows: [destination], childrenByPath: [:], echoesSelection: false
        )
        let surface = state.makeSurface()

        let result = surface.selectDestinationBrowserElement(at: destination)

        #expect(result == .refused("stem_destination_component_not_confirmed:Exports"))
        #expect(!surface.listViewSelectionConfirms(destination))
    }

    @Test("a component that is not listed is refused by name")
    func unlistedComponentIsRefused() {
        let state = ListViewPanelState(
            initialRows: ["/Users/fixture/Exports"], childrenByPath: [:]
        )

        let result = state.makeSurface().selectDestinationBrowserElement(
            at: "/Users/fixture/Exports/Missing"
        )

        #expect(result == .refused("stem_destination_component_not_listed:Missing"))
    }

    @Test("the list-view witness requires the exact selected row, not a sibling")
    func witnessRejectsAnotherSelectedRow() {
        let destination = "/Users/fixture/Exports"
        let state = ListViewPanelState(
            initialRows: [destination, "/Users/fixture/Other"], childrenByPath: [:]
        )
        let surface = state.makeSurface()

        state.selectRow(at: "/Users/fixture/Other")

        #expect(!surface.listViewSelectionConfirms(destination))
        #expect(surface.listViewSelectionConfirms("/Users/fixture/Other"))
    }

    @Test("the list-view witness is false when no row is selected")
    func witnessRejectsNoSelection() {
        let destination = "/Users/fixture/Exports"
        let state = ListViewPanelState(initialRows: [destination], childrenByPath: [:])

        #expect(!state.makeSurface().listViewSelectionConfirms(destination))
    }
}
