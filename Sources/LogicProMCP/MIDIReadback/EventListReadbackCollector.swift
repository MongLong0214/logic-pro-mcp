import ApplicationServices
import Foundation

/// Release-side Accessibility collector for the live Event List.
///
/// This collector deliberately gathers observations only. The proofs needed by
/// `assessReadback` remain unproven in a release build, so collecting a live
/// table cannot make the default-off readback path complete or public.
enum EventListReadbackCollector {
    static func collect(
        requestedRegion: MIDIRegionReference,
        resolvedIdentity: RegistryResolvedIdentityProof,
        projectEpochBefore: UInt64,
        projectEpochAfter: UInt64,
        ppq: Int,
        runtime: AXLogicProElements.Runtime = .production
    ) throws -> EventListReadbackEvidence {
        guard let mainWindow = AXLogicProElements.mainWindow(runtime: runtime) else {
            throw EventListReadbackCollectorError.mainWindowUnavailable
        }

        let eventTab = try findEventTab(in: mainWindow, runtime: runtime.ax)
        let eventTabWasSelected = try checkedState(of: eventTab, runtime: runtime.ax)
        defer { restoreEventTab(eventTab, wasSelected: eventTabWasSelected, runtime: runtime.ax) }

        let paneAndTable = try findEventPaneAndTable(
            for: eventTab,
            in: mainWindow,
            runtime: runtime.ax
        )
        let originalRows: [AXUIElement] = AXHelpers.getAttribute(
            paneAndTable.table,
            kAXSelectedRowsAttribute,
            runtime: runtime.ax
        ) ?? []
        defer {
            _ = AXHelpers.setAttribute(
                paneAndTable.table,
                kAXSelectedRowsAttribute,
                originalRows as CFArray,
                runtime: runtime.ax
            )
        }

        try selectEventTabIfNeeded(eventTab, wasSelected: eventTabWasSelected, runtime: runtime.ax)

        let headers = try readHeaders(of: paneAndTable.table, runtime: runtime.ax)
        let filter = try readFilters(in: paneAndTable.pane, runtime: runtime.ax)
        let itemCount = try readStaticText(
            help: "Number of Items",
            in: paneAndTable.pane,
            runtime: runtime.ax
        )
        // `ObservedRegionIdentityProof` intentionally exposes no release
        // constructible observed value. Still require the independent AX value
        // to be present, rather than silently treating a missing Region Path as
        // an observation.
        let regionPath = try readStaticText(
            help: "Region Path",
            in: paneAndTable.pane,
            runtime: runtime.ax
        )
        guard !regionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EventListReadbackCollectorError.regionPathMissing
        }

        let harvest = try harvestRows(
            from: paneAndTable.table,
            headers: headers,
            runtime: runtime.ax
        )
        try refuseTimeDisplayIfNeeded(runtime: runtime, rows: harvest.passA, positionColumn: headers.positionID)

        return EventListReadbackEvidence(
            requestedRegion: requestedRegion,
            resolvedIdentity: resolvedIdentity,
            observedRegion: .unproven,
            projectEpochBefore: projectEpochBefore,
            projectEpochAfter: projectEpochAfter,
            ppq: ppq,
            columnBinding: .headerIdentity(.unproven),
            filter: filter,
            itemCount: ItemCountEvidence(rawCountText: itemCount, semanticsProof: .unproven),
            harvest: harvest,
            timing: .unproven,
            calibration: nil
        )
    }

    // MARK: - Event pane identity

    private static let expectedHeaderTitles = [
        "L", "M", "Position", "Status", "Ch", "Num", "Val", "Length/Info",
    ]
    /// Logic uses this distinct schema while the Event List is showing regions
    /// instead of the selected region's events. It is a recoverable navigation
    /// failure, not a column-layout drift.
    private static let regionLevelHeaderTitles = [
        "L", "M", "Position", "Name", "Trk", "Length",
    ]
    private static let maximumMaterializationPasses = 64

    private struct HeaderBinding {
        let orderedIDs: [AXColumnID]
        let positionID: AXColumnID
        let numberID: AXColumnID
        let valueID: AXColumnID
    }

    private static func findEventTab(
        in mainWindow: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> AXUIElement {
        let tabs = AXHelpers.findAllDescendants(
            of: mainWindow,
            role: kAXRadioButtonRole as String,
            maxDepth: 20,
            runtime: runtime
        ).filter { tab in
            AXHelpers.getDescription(tab, runtime: runtime) == "Event"
                && (AXHelpers.getTitle(tab, runtime: runtime) ?? "").isEmpty
        }
        guard tabs.count == 1, let tab = tabs.first else {
            if tabs.isEmpty {
                throw EventListReadbackCollectorError.eventTabNotFound
            }
            throw EventListReadbackCollectorError.eventTabAmbiguous(count: tabs.count)
        }
        return tab
    }

    private static func findEventPaneAndTable(
        for eventTab: AXUIElement,
        in mainWindow: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> (pane: AXUIElement, table: AXUIElement) {
        var current = eventTab
        var ancestors: [AXUIElement] = []
        for _ in 0..<12 {
            guard let parent: AXUIElement = AXHelpers.getAttribute(
                current,
                kAXParentAttribute,
                runtime: runtime
            ), !ancestors.contains(where: { $0 == parent }) else {
                break
            }
            ancestors.append(parent)
            current = parent
        }

        // Fake AX runtimes commonly model the tree with AXChildren only. Build
        // the same ancestry structurally instead of falling back to an arbitrary
        // table elsewhere in the window.
        if ancestors.isEmpty,
           let path = path(from: mainWindow, to: eventTab, runtime: runtime) {
            ancestors = Array(path.dropLast().reversed())
        }

        for parent in ancestors {
            let tables = AXHelpers.findAllDescendants(
                of: parent,
                role: kAXTableRole as String,
                maxDepth: 12,
                runtime: runtime
            )
            guard !tables.isEmpty else { continue }
            guard tables.count == 1, let table = tables.first else {
                throw EventListReadbackCollectorError.eventTableAmbiguous(count: tables.count)
            }
            return (parent, table)
        }

        throw EventListReadbackCollectorError.eventTableNotFound
    }

    private static func path(
        from root: AXUIElement,
        to target: AXUIElement,
        runtime: AXHelpers.Runtime,
        depth: Int = 20
    ) -> [AXUIElement]? {
        guard depth >= 0 else { return nil }
        if root == target { return [root] }
        for child in AXHelpers.getChildren(root, runtime: runtime) {
            if let path = path(from: child, to: target, runtime: runtime, depth: depth - 1) {
                return [root] + path
            }
        }
        return nil
    }

    private static func checkedState(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> Bool {
        guard let value = AXValueExtractors.extractButtonState(element, runtime: runtime) else {
            throw EventListReadbackCollectorError.eventTabStateUnavailable
        }
        return value
    }

    private static func selectEventTabIfNeeded(
        _ tab: AXUIElement,
        wasSelected: Bool,
        runtime: AXHelpers.Runtime
    ) throws {
        guard !wasSelected else { return }
        guard AXHelpers.performAction(tab, kAXPressAction, runtime: runtime),
              try checkedState(of: tab, runtime: runtime)
        else {
            throw EventListReadbackCollectorError.eventTabActivationFailed
        }
    }

    private static func restoreEventTab(
        _ tab: AXUIElement,
        wasSelected: Bool,
        runtime: AXHelpers.Runtime
    ) {
        guard let selected = try? checkedState(of: tab, runtime: runtime), selected != wasSelected else {
            return
        }
        _ = AXHelpers.performAction(tab, kAXPressAction, runtime: runtime)
    }

    // MARK: - Header and metadata

    private static func readHeaders(
        of table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> HeaderBinding {
        guard let header: AXUIElement = AXHelpers.getAttribute(table, kAXHeaderAttribute, runtime: runtime) else {
            throw EventListReadbackCollectorError.headerUnavailable
        }
        let children = AXHelpers.getChildren(header, runtime: runtime)
        let sortButtons = children.filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXButtonRole as String)
                && (AXHelpers.getAttribute($0, kAXSubroleAttribute, runtime: runtime) as String?) == "AXSortButton"
        }
        guard sortButtons.count == children.count else {
            throw EventListReadbackCollectorError.headerSortButtonsUnavailable
        }
        let titles = sortButtons.map { AXHelpers.getTitle($0, runtime: runtime) }

        if titles == regionLevelHeaderTitles {
            throw EventListReadbackCollectorError.paneAtRegionLevel
        }

        for index in expectedHeaderTitles.indices {
            let expected = expectedHeaderTitles[index]
            let actual = titles.indices.contains(index) ? titles[index] : nil
            guard actual == expected else {
                throw EventListReadbackCollectorError.headerMismatch(expected: expected, actual: actual)
            }
        }
        guard titles.count == expectedHeaderTitles.count else {
            throw EventListReadbackCollectorError.headerMismatch(
                expected: "<end of header>",
                actual: titles[expectedHeaderTitles.count] ?? ""
            )
        }

        let ids = expectedHeaderTitles.map(AXColumnID.init(id:))
        return HeaderBinding(
            orderedIDs: ids,
            positionID: ids[2],
            numberID: ids[5],
            valueID: ids[6]
        )
    }

    private static let filterTitles: [(title: String, id: FilterControlID)] = [
        ("Notes", .noteEvents),
        ("Progr. Change", .programChange),
        ("Pitch Bend", .pitchBend),
        ("Controller", .controller),
        ("Aftertouch", .aftertouch),
        ("Poly Aftertouch", .polyAftertouch),
        ("Syst. Exclusive", .systemExclusive),
        ("Additional Info", .additionalInfo),
    ]

    private static func readFilters(
        in pane: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> FilterEvidence {
        let controls = AXHelpers.findAllDescendants(
            of: pane,
            role: kAXCheckBoxRole as String,
            maxDepth: 16,
            runtime: runtime
        )
        var evidence: [FilterEvidence.Checkbox] = []
        for filter in filterTitles {
            let matches = controls.filter { AXHelpers.getTitle($0, runtime: runtime) == filter.title }
            guard matches.count == 1, let control = matches.first,
                  let checked = AXValueExtractors.extractButtonState(control, runtime: runtime)
            else {
                throw EventListReadbackCollectorError.filterEvidenceIncomplete(title: filter.title)
            }
            evidence.append(.init(id: filter.id.rawValue, checked: checked))
        }
        return FilterEvidence(checkboxes: evidence)
    }

    private static func readStaticText(
        help: String,
        in pane: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> String {
        let matches = AXHelpers.findAllDescendants(
            of: pane,
            role: kAXStaticTextRole as String,
            maxDepth: 16,
            runtime: runtime
        ).filter { AXHelpers.getHelp($0, runtime: runtime) == help }
        guard matches.count == 1, let text = matches.first,
              let value = AXValueExtractors.extractTextValue(text, runtime: runtime)
        else {
            if help == "Region Path" {
                throw EventListReadbackCollectorError.regionPathMissing
            }
            throw EventListReadbackCollectorError.itemCountMissing
        }
        return value
    }

    // MARK: - Row harvesting

    private static func harvestRows(
        from table: AXUIElement,
        headers: HeaderBinding,
        runtime: AXHelpers.Runtime
    ) throws -> RowHarvest {
        guard let rows: [AXUIElement] = AXHelpers.getAttribute(table, "AXRows", runtime: runtime) else {
            throw EventListReadbackCollectorError.rowsUnavailable
        }
        let keys = rows.indices.map { RowKey(index: $0) }
        var observations = try readRows(rows, headers: headers, runtime: runtime)
        var passes = 0

        while let firstUnpopulated = observations.firstIndex(where: { !isPopulated($0, headers: headers) }),
              passes < maximumMaterializationPasses {
            guard AXHelpers.setAttribute(
                table,
                kAXSelectedRowsAttribute,
                [rows[firstUnpopulated]] as CFArray,
                runtime: runtime
            ) else {
                throw EventListReadbackCollectorError.rowSelectionFailed(index: firstUnpopulated)
            }
            observations = try readRows(rows, headers: headers, runtime: runtime)
            passes += 1
        }

        let populated = observations.filter { isPopulated($0, headers: headers) }.count
        guard populated == rows.count else {
            throw EventListReadbackCollectorError.harvestIncomplete(
                populated: populated,
                total: rows.count,
                passes: passes
            )
        }

        let passA = dictionary(rows: observations, keys: keys)
        let secondPass = try readRows(rows, headers: headers, runtime: runtime)
        let secondPopulated = secondPass.filter { isPopulated($0, headers: headers) }.count
        guard secondPopulated == rows.count else {
            throw EventListReadbackCollectorError.harvestIncomplete(
                populated: secondPopulated,
                total: rows.count,
                passes: passes
            )
        }
        return RowHarvest(
            orderedRowKeys: keys,
            passA: passA,
            passB: dictionary(rows: secondPass, keys: keys),
            exhaustion: .unproven
        )
    }

    private static func dictionary(rows: [RawEventRow], keys: [RowKey]) -> [RowKey: RawEventRow] {
        Dictionary(uniqueKeysWithValues: zip(keys, rows))
    }

    private static func readRows(
        _ rows: [AXUIElement],
        headers: HeaderBinding,
        runtime: AXHelpers.Runtime
    ) throws -> [RawEventRow] {
        try rows.enumerated().map { index, row in
            try readRow(row, index: index, headers: headers, runtime: runtime)
        }
    }

    private static func readRow(
        _ row: AXUIElement,
        index: Int,
        headers: HeaderBinding,
        runtime: AXHelpers.Runtime
    ) throws -> RawEventRow {
        let cells = AXHelpers.getChildren(row, runtime: runtime)
        guard cells.count == headers.orderedIDs.count else {
            throw EventListReadbackCollectorError.rowCellCountMismatch(
                row: index,
                expected: headers.orderedIDs.count,
                actual: cells.count
            )
        }

        var result: RawEventRow = [:]
        for (columnIndex, cell) in cells.enumerated() {
            let children = AXHelpers.getChildren(cell, runtime: runtime)
            guard children.count == 1, let child = children.first else {
                throw EventListReadbackCollectorError.cellChildCountMismatch(
                    row: index,
                    column: expectedHeaderTitles[columnIndex],
                    actual: children.count
                )
            }
            let title = expectedHeaderTitles[columnIndex]
            result[headers.orderedIDs[columnIndex]] = rawCell(
                title: title,
                child: child,
                runtime: runtime
            )
        }
        return result
    }

    private static func rawCell(
        title: String,
        child: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> RawCell {
        switch title {
        case "Position", "Length/Info":
            let description = AXHelpers.getDescription(child, runtime: runtime)
            return RawCell(
                valueDescription: description,
                groupSliderValues: bbtValues(description)
            )
        case "Ch", "Num":
            return RawCell(sliderValue: AXValueExtractors.extractSliderValue(child, runtime: runtime))
        case "Val":
            return RawCell(valueDescription: AXValueExtractors.extractValueDescription(child, runtime: runtime))
        default:
            return RawCell(
                valueDescription: AXHelpers.getDescription(child, runtime: runtime)
                    ?? AXValueExtractors.extractValueDescription(child, runtime: runtime)
            )
        }
    }

    private static func isPopulated(_ row: RawEventRow, headers: HeaderBinding) -> Bool {
        guard let position = row[headers.positionID]?.valueDescription,
              let number = row[headers.numberID]?.sliderValue,
              let value = row[headers.valueID]?.valueDescription,
              !position.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return number.isFinite
    }

    /// Event-list BBT cells are exactly four ASCII integer groups separated by
    /// single spaces. Time display (`01:00:00:00.00`) cannot satisfy this.
    private static func bbtValues(_ text: String?) -> [Double]? {
        guard let text else { return nil }
        let groups = text.split(separator: " ", omittingEmptySubsequences: false)
        guard groups.count == 4,
              groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else {
            return nil
        }
        let values = groups.compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
        return values
    }

    // MARK: - Display mode

    private static func refuseTimeDisplayIfNeeded(
        runtime: AXLogicProElements.Runtime,
        rows: [RowKey: RawEventRow],
        positionColumn: AXColumnID
    ) throws {
        guard let menuBar = AXLogicProElements.getMenuBar(runtime: runtime),
              let viewMenu = AXLocalePolicy.findMenuBarItem(
                in: menuBar,
                matching: AXLocalePolicy.viewMenuBar,
                runtime: runtime.ax
              )
        else {
            throw EventListReadbackCollectorError.displayModeUnavailable
        }
        let menuItems = AXHelpers.findAllDescendants(
            of: viewMenu,
            role: kAXMenuItemRole as String,
            maxDepth: 8,
            runtime: runtime.ax
        ).filter {
            AXHelpers.getTitle($0, runtime: runtime.ax) == "Event Position and Length as Time"
        }
        guard menuItems.count == 1, let menuItem = menuItems.first else {
            throw EventListReadbackCollectorError.displayModeUnavailable
        }
        let mark: String? = AXHelpers.getAttribute(menuItem, kAXMenuItemMarkCharAttribute, runtime: runtime.ax)
        let markedAsTime = !(mark?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let allPositionsAreBBT = rows.values.allSatisfy {
            $0[positionColumn]?.groupSliderValues?.count == 4
        }

        switch (markedAsTime, allPositionsAreBBT) {
        case (false, true):
            return
        case (true, false):
            throw EventListReadbackCollectorError.timeDisplayEnabled
        default:
            throw EventListReadbackCollectorError.displayModeDisagreement(
                markedAsTime: markedAsTime,
                positionsAreBBT: allPositionsAreBBT
            )
        }
    }
}

enum EventListReadbackCollectorError: Error, Equatable, Sendable, CustomStringConvertible {
    case mainWindowUnavailable
    case eventTabNotFound
    case eventTabAmbiguous(count: Int)
    case eventTabStateUnavailable
    case eventTabActivationFailed
    case eventTableNotFound
    case eventTableAmbiguous(count: Int)
    case headerUnavailable
    case headerSortButtonsUnavailable
    case paneAtRegionLevel
    case headerMismatch(expected: String, actual: String?)
    case filterEvidenceIncomplete(title: String)
    case itemCountMissing
    case regionPathMissing
    case rowsUnavailable
    case rowSelectionFailed(index: Int)
    case rowCellCountMismatch(row: Int, expected: Int, actual: Int)
    case cellChildCountMismatch(row: Int, column: String, actual: Int)
    case harvestIncomplete(populated: Int, total: Int, passes: Int)
    case displayModeUnavailable
    case timeDisplayEnabled
    case displayModeDisagreement(markedAsTime: Bool, positionsAreBBT: Bool)

    var description: String {
        switch self {
        case .mainWindowUnavailable: return "Logic Pro main window is unavailable."
        case .eventTabNotFound: return "Event List tab (AXDescription Event) was not found."
        case let .eventTabAmbiguous(count): return "Event List tab is ambiguous (\(count) matches)."
        case .eventTabStateUnavailable: return "Event List tab selection state is unavailable."
        case .eventTabActivationFailed: return "Could not activate the Event List tab."
        case .eventTableNotFound: return "Event List table was not found in the Event pane."
        case let .eventTableAmbiguous(count): return "Event List table is ambiguous (\(count) matches)."
        case .headerUnavailable: return "Event List table has no AXHeader."
        case .headerSortButtonsUnavailable: return "Event List header does not expose only sort-button columns."
        case .paneAtRegionLevel: return "Event List is at region level; event-level rows are unavailable."
        case let .headerMismatch(expected, actual):
            return "Event List column mismatch at \(expected): found \(actual ?? "<missing>")."
        case let .filterEvidenceIncomplete(title): return "Event List filter evidence is incomplete: \(title)."
        case .itemCountMissing: return "Event List Number of Items text is unavailable."
        case .regionPathMissing: return "Event List Region Path text is unavailable."
        case .rowsUnavailable: return "Event List AXRows is unavailable."
        case let .rowSelectionFailed(index): return "Could not select Event List row \(index) to materialize it."
        case let .rowCellCountMismatch(row, expected, actual):
            return "Event List row \(row) has \(actual) cells; expected \(expected)."
        case let .cellChildCountMismatch(row, column, actual):
            return "Event List row \(row), column \(column) has \(actual) cell children; expected 1."
        case let .harvestIncomplete(populated, total, passes):
            return "Event List materialization incomplete: \(populated)/\(total) rows after \(passes) passes."
        case .displayModeUnavailable: return "Event Position and Length as Time menu state is unavailable."
        case .timeDisplayEnabled: return "Event List is displaying position and length as time."
        case let .displayModeDisagreement(markedAsTime, positionsAreBBT):
            return "Event List display mode disagrees with Position format (mark=\(markedAsTime), BBT=\(positionsAreBBT))."
        }
    }
}
