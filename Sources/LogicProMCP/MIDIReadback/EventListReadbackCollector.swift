import ApplicationServices
import Foundation

/// Release-side Accessibility collector for the live Event List.
///
/// This collector deliberately gathers observations only. The proofs needed by
/// `assessReadback` remain unproven in a release build, so collecting a live
/// table cannot make the default-off readback path complete or public.
enum EventListReadbackCollector {
    /// What `readRow` sees on the live Event List, with no identity and no assessment (#616).
    ///
    /// `collect` requires a `RegistryResolvedIdentityProof`, and the only mint for one is compiled
    /// solely under `QUALIFICATION_FAULT_SEAM` — a debug condition. So the RELEASE binary contains
    /// this collector and cannot construct the argument it needs, which is why a live run driving the
    /// shipped artifact could never reach the code under test and every live check about it scored
    /// zero mutations.
    ///
    /// This entry exists to close exactly that gap and nothing else:
    ///
    ///   * it takes no identity, so it is constructible in release;
    ///   * it does NOT call `assessReadback`, so `EventListMIDINoteReadbackProvider` remains the sole
    ///     adapter the call-site lint permits and the dark provider stays dark;
    ///   * it mints no `CompleteProof` and completes no qualification;
    ///   * it goes through the SAME `readHeaders` / `readRows` / `readRow` the collector uses, which
    ///     is the point — the guard under test is on that path.
    ///
    /// It performs NO AX action. `collect` presses the Event tab when the pane is showing something
    /// else; this entry refuses instead, because "it only observes" is the whole reason a release
    /// binary is allowed to reach it. A press is small, but it is still actuation the shipped
    /// artifact could not previously perform on this path, and a claim of observation that quietly
    /// actuates is the defect this collector exists to make impossible. Selecting the Event tab is
    /// the driver's job, before the probe runs.
    /// What one probe run actually saw. `rows` alone was not enough to prove anything about the
    /// header: `RawEventRow` is keyed by `AXColumnID`s minted from `expectedHeaderTitles`, so a
    /// harness reading those keys compares the canonical English constants against themselves and
    /// gets a check that cannot fail. `liveHeaderTitles` is what Logic rendered. `firstRowCellChildren`
    /// is the count this collector's guard is ABOUT — the empty Lock/Mute cells — measured rather
    /// than inferred from a null slider.
    struct ProbeObservation: Sendable {
        let liveHeaderTitles: [String]
        let rows: [RawEventRow]
        let firstRowCellChildren: [String: Int]
    }

    static func observeNoteTable(
        runtime: AXLogicProElements.Runtime = .production
    ) throws -> ProbeObservation {
        guard let mainWindow = AXLogicProElements.mainWindow(runtime: runtime) else {
            throw EventListReadbackCollectorError.mainWindowUnavailable
        }
        let eventTab = try findEventTab(in: mainWindow, runtime: runtime.ax)
        guard try checkedState(of: eventTab, runtime: runtime.ax) else {
            throw EventListProbeRefusal.eventTabNotSelected
        }

        let paneAndTable = try findEventPaneAndTable(
            for: eventTab, in: mainWindow, runtime: runtime.ax
        )

        let headers = try readHeaders(of: paneAndTable.table, runtime: runtime.ax)
        let rowElements: [AXUIElement] = AXHelpers.getAttribute(
            paneAndTable.table, "AXRows", runtime: runtime.ax
        ) ?? []
        return ProbeObservation(
            liveHeaderTitles: sortButtonTitles(of: paneAndTable.table, runtime: runtime.ax),
            rows: try readRows(rowElements, headers: headers, runtime: runtime.ax),
            firstRowCellChildren: rowElements.first.map {
                cellChildCounts(of: $0, headers: headers, runtime: runtime.ax)
            } ?? [:]
        )
    }

    /// The header's sort-button titles, verbatim. A separate read from `readHeaders`, on purpose:
    /// that function CONSUMES the titles to decide whether they match and then reports canonical
    /// names either way, so it cannot witness what was rendered.
    private static func sortButtonTitles(
        of table: AXUIElement, runtime: AXHelpers.Runtime
    ) -> [String] {
        guard let header: AXUIElement = AXHelpers.getAttribute(
            table, kAXHeaderAttribute, runtime: runtime
        ) else { return [] }
        return AXHelpers.getChildren(header, runtime: runtime)
            .filter { (AXHelpers.getAttribute($0, kAXSubroleAttribute, runtime: runtime) as String?) == "AXSortButton" }
            .compactMap { AXHelpers.getTitle($0, runtime: runtime) }
    }

    /// How many children each cell of one row has. This is the observable the `readRow` guard is
    /// about: Logic gives an unset Lock or Mute flag a cell with ZERO children, and demanding one
    /// child everywhere is what made every real note row throw.
    private static func cellChildCounts(
        of row: AXUIElement, headers: HeaderBinding, runtime: AXHelpers.Runtime
    ) -> [String: Int] {
        let cells = AXHelpers.getChildren(row, runtime: runtime)
        var counts: [String: Int] = [:]
        for (index, id) in headers.orderedIDs.enumerated() where cells.indices.contains(index) {
            counts[id.id] = AXHelpers.getChildren(cells[index], runtime: runtime).count
        }
        return counts
    }

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
        try refuseTimeDisplayIfNeeded(
            pane: paneAndTable.pane,
            runtime: runtime,
            rows: harvest.passA,
            positionColumn: headers.positionID
        )

        return EventListReadbackEvidence(
            // Resolved from the process actually being read, not from a build-time assumption. On an
            // unrecognised bundle identifier this is `.unknown`, which is the honest answer and keeps
            // the reading off a coverage axis it did not earn.
            variant: LogicProTarget.current.variant,
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

    /// Column identity is the CANONICAL English form; the locale variants only widen what the live
    /// header is allowed to say. Measured on a Korean Logic 12.3 the same columns read
    /// `["L","M","위치","상태","채널","번호","값","길이/정보"]`, and comparing those against English
    /// literals threw `headerMismatch` — the readback could not run at all outside English.
    private static let expectedHeaderColumns: [AXLocalePolicy.LabelSet] = [
        AXLocalePolicy.eventListColumnL, AXLocalePolicy.eventListColumnM,
        AXLocalePolicy.eventListColumnPosition, AXLocalePolicy.eventListColumnStatus,
        AXLocalePolicy.eventListColumnChannel, AXLocalePolicy.eventListColumnNumber,
        AXLocalePolicy.eventListColumnValue, AXLocalePolicy.eventListColumnLengthInfo,
    ]
    private static let expectedHeaderTitles = expectedHeaderColumns.map(\.canonical)
    /// The two columns whose cell may legitimately be EMPTY: an unset Lock or Mute flag.
    private static let flagColumnTitles: Set<String> = [
        AXLocalePolicy.eventListColumnL.canonical,
        AXLocalePolicy.eventListColumnM.canonical,
    ]
    /// Logic uses this distinct schema while the Event List is showing regions
    /// instead of the selected region's events. It is a recoverable navigation
    /// failure, not a column-layout drift.
    /// Measured in Korean as `["L","M","위치","이름","트랙","길이"]`.
    private static let regionLevelHeaderColumns: [AXLocalePolicy.LabelSet] = [
        AXLocalePolicy.eventListColumnL, AXLocalePolicy.eventListColumnM,
        AXLocalePolicy.eventListColumnPosition, AXLocalePolicy.eventListColumnName,
        AXLocalePolicy.eventListColumnTrack, AXLocalePolicy.eventListColumnLength,
    ]
    private static let regionLevelHeaderTitles = regionLevelHeaderColumns.map(\.canonical)
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
            // Through the policy, not against the literal `"Event"`. That comparison meant the
            // tab could only be found on an English Logic; everywhere else the collector threw
            // `eventTabNotFound` before reading anything. Measured 2026-08-29 on a Korean Logic:
            // the four list tabs describe themselves `이벤트`, `마커`, `템포`, `조표 및 박자표`.
            AXLocalePolicy.eventListTab.matches(
                AXHelpers.getDescription(tab, runtime: runtime) ?? "", mode: .exactStrict)
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

    /// Whether a table's header is one of the two schemas this pane shows.
    ///
    /// Identity, not position: the note level's eight columns or the region level's six. A table that
    /// carries neither is some other pane's, however close it sits in the tree.
    private static func headerBinds(_ table: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        guard let header: AXUIElement = AXHelpers.getAttribute(
            table, kAXHeaderAttribute, runtime: runtime
        ) else { return false }
        let titles = AXHelpers.getChildren(header, runtime: runtime)
            .filter { (AXHelpers.getAttribute($0, kAXSubroleAttribute, runtime: runtime) as String?) == "AXSortButton" }
            .compactMap { AXHelpers.getTitle($0, runtime: runtime) }
        guard !titles.isEmpty else { return false }
        return titlesMatch(titles, expectedHeaderColumns)
            || titlesMatch(titles, regionLevelHeaderColumns)
    }

    /// Positional locale-aware comparison against a column schema, shared by `headerBinds` (which
    /// decides WHICH table is the Event pane's) and `readHeaders` (which decides whether that
    /// table is at region level). They had separate definitions of the same question and drifted
    /// apart — one counted, the other compared — which is exactly the defect below.
    ///
    /// Counting the columns was the
    /// earlier form and it was arity-only matching under a comment that claimed identity — the very
    /// thing `HeaderIdentityProof` refuses to represent. Any other pane whose header happens to carry
    /// six or eight sort buttons satisfied a count; it does not satisfy these labels.
    // [String?] rather than [String]: readHeaders keeps the nil for a title AX would not give,
    // and `matches` refuses nil. Compacting them away here would silently shorten the list and let
    // a header with a missing title match a shorter schema.
    private static func titlesMatch(_ titles: [String?], _ columns: [AXLocalePolicy.LabelSet]) -> Bool {
        guard titles.count == columns.count else { return false }
        return zip(titles, columns).allSatisfy { title, column in column.matches(title) }
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

        // #616: pick the table by WHAT IT IS, and fall back to "the only one here" rather than
        // leading with it.
        //
        // This used to take the first ancestor containing any table and demand there be exactly one.
        // Run for the first time against live Logic — from the release binary, through the probe
        // added for this — it threw `eventTableAmbiguous(count: 2)` before reaching any of the code
        // it exists to run, because a sibling pane in that ancestor also has a table. The Event
        // pane's table was right there; the rule just could not say which one it was.
        //
        // A table that carries this pane's header is identifiable. Ambiguity is now reserved for the
        // case where TWO tables both look like the Event pane, which is a real ambiguity rather than
        // an accident of which panes happen to be open.
        for parent in ancestors {
            let tables = AXHelpers.findAllDescendants(
                of: parent,
                role: kAXTableRole as String,
                maxDepth: 12,
                runtime: runtime
            )
            guard !tables.isEmpty else { continue }

            let identifiable = tables.filter { headerBinds($0, runtime: runtime) }
            if identifiable.count == 1, let table = identifiable.first {
                return (parent, table)
            }
            if identifiable.count > 1 {
                throw EventListReadbackCollectorError.eventTableAmbiguous(count: identifiable.count)
            }
            // No table here carries an Event-pane header. Keep the historical behaviour for the
            // single-table case so existing fixtures — which model a bare table with no header —
            // still resolve.
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

        if titlesMatch(titles, regionLevelHeaderColumns) {
            throw EventListReadbackCollectorError.paneAtRegionLevel
        }

        for index in expectedHeaderColumns.indices {
            let column = expectedHeaderColumns[index]
            let actual = titles.indices.contains(index) ? titles[index] : nil
            guard column.matches(actual) else {
                // The reported `expected` stays canonical so the error names one thing across
                // locales, while `actual` carries whatever Logic really rendered.
                throw EventListReadbackCollectorError.headerMismatch(
                    expected: column.canonical, actual: actual
                )
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
            let title = expectedHeaderTitles[columnIndex]
            let children = AXHelpers.getChildren(cell, runtime: runtime)
            // #293: L and M are the Lock and Mute FLAGS, and an unset flag is an EMPTY cell — measured
            // live on a three-note region, every row reads cell child counts [0, 0, 1, 1, 1, 1, 1, 1].
            // Requiring exactly one child everywhere therefore threw
            // `cellChildCountMismatch(row: 0, column: "L", actual: 0)` on the first cell of the first
            // row of any ordinary note, so this collector could not read a single real row.
            //
            // The absence is not ambiguous: those two cells expose no value-bearing attribute at all
            // (19 attribute names, all structural, `AXDescription` nil, no `AXValue`), so there is
            // nowhere else for a set flag to live and an empty cell means "off".
            //
            // Deliberately narrow: only the two flag columns may be empty. A missing child in a DATA
            // column is still a mismatch, because there the absence would be a datum that failed to
            // read rather than a state.
            if flagColumnTitles.contains(title), children.isEmpty {
                result[headers.orderedIDs[columnIndex]] = RawCell()
                continue
            }
            guard children.count == 1, let child = children.first else {
                throw EventListReadbackCollectorError.cellChildCountMismatch(
                    row: index,
                    column: title,
                    actual: children.count
                )
            }
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

    /// The Event pane's own View menu, opened so its items are readable.
    ///
    /// The menu has to be shown before its entries materialise; the mark character that says whether
    /// the Time display is active is only meaningful once they have. The menu is cancelled again by
    /// the caller's `defer` so the pane is left as it was found.
    private static func paneViewMenu(
        in pane: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(
            of: pane, role: kAXMenuButtonRole as String, maxDepth: 8, runtime: runtime
        ).filter {
            AXLocalePolicy.elementMatches($0, AXLocalePolicy.viewMenuBar, runtime: runtime)
        }
        guard buttons.count == 1, let button = buttons.first else { return nil }
        if let existing = AXHelpers.getChildren(button, runtime: runtime).first(where: {
            AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
        }) {
            return existing
        }
        _ = AXHelpers.performAction(button, "AXShowMenu", runtime: runtime)
        return AXHelpers.getChildren(button, runtime: runtime).first {
            AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
        }
    }

    private static func refuseTimeDisplayIfNeeded(
        pane: AXUIElement,
        runtime: AXLogicProElements.Runtime,
        rows: [RowKey: RawEventRow],
        positionColumn: AXColumnID
    ) throws {
        // The setting lives in the EVENT PANE's own View menu, together with the column toggles —
        // not in the application menu bar. Measured on Logic 12.3: the app View menu holds sixteen
        // entries (Library, Inspector, Mixer, … Enter Full Screen) and none of them is this one, so
        // searching there found zero matches and every collect() threw displayModeUnavailable before
        // it could return evidence. Nothing caught it because the collector is reachable from no
        // dispatcher, and the unit tests supply the mode through a seam rather than a live menu.
        guard let viewMenu = paneViewMenu(in: pane, runtime: runtime.ax) else {
            throw EventListReadbackCollectorError.displayModeUnavailable
        }
        let menuItems = AXHelpers.findAllDescendants(
            of: viewMenu,
            role: kAXMenuItemRole as String,
            maxDepth: 8,
            runtime: runtime.ax
        ).filter {
            AXLocalePolicy.elementMatches(
                $0, AXLocalePolicy.eventPositionAsTimeMenuItem, runtime: runtime.ax
            )
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

/// The probe's own refusal, deliberately NOT a case of `EventListReadbackCollectorError`. That
/// enum is mirrored case-for-case by the provider's public error, and `collect` can never fail
/// this way — a case there would be an absence dressed as a possibility.
enum EventListProbeRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case eventTabNotSelected

    var description: String {
        switch self {
        case .eventTabNotSelected:
            return "Event List tab is not selected. This entry observes and will not select it; "
                + "open the Event List and choose the Event tab first."
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
