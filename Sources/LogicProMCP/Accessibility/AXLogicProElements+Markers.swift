import ApplicationServices
import Foundation


extension AXLogicProElements {
    struct MarkerListBinding {
        let window: AXUIElement
        let projectDocument: String
    }

    /// A complete Marker List reading, retaining the exact AX elements that supplied its order.
    ///
    /// The marker ordinal is meaningful only relative to `rows`: a destructive caller must select
    /// `rows[ordinal]`, not rediscover an independently ordered structural descendant later.
    struct MarkerListInventory {
        let table: AXUIElement
        let rows: [AXUIElement]
        let markers: [MarkerState]
    }

    /// Stable source of an unreadable Marker List inventory result. The delete path reads the
    /// table bound before its write, so `tableLookup` is used by the window-based reader but is
    /// intentionally not reachable from its post-write readback.
    enum MarkerListReadFailureSite: String, Sendable {
        case tableLookup = "table_lookup"
        case axRows = "ax_rows"
        case structuralChildren = "structural_children"
        case cell = "cell"
        case settleLoop = "settle_loop"
    }

    /// Whether a marker-list failure came from an AX operation or from this reader's own
    /// corroboration guard. A synthetic `cannotComplete` for disagreeing row collections is not
    /// an AX failure and must not be mistaken for a rebuild-transient response.
    enum MarkerListReadFailureOrigin: Sendable, Equatable {
        case axRead
        case corroboration
    }

    /// Preserves both the exact AX status and the stage that consumed it. Corroboration counts are
    /// present only when both independently read row collections were actually available to
    /// compare; they never stand in for a failed AX read.
    struct MarkerListReadFailure: Error, Sendable, Equatable {
        let site: MarkerListReadFailureSite
        let status: AXHelpers.AXStatusError
        let origin: MarkerListReadFailureOrigin
        let axRowsCount: Int?
        let structuralChildrenCount: Int?

        init(
            site: MarkerListReadFailureSite,
            status: AXHelpers.AXStatusError,
            origin: MarkerListReadFailureOrigin = .axRead,
            axRowsCount: Int? = nil,
            structuralChildrenCount: Int? = nil
        ) {
            self.site = site
            self.status = status
            self.origin = origin
            self.axRowsCount = axRowsCount
            self.structuralChildrenCount = structuralChildrenCount
        }
    }

    static func markerListBinding(runtime: Runtime = .production) -> MarkerListBinding? {
        guard let app = appRoot(runtime: runtime),
              let mainWindow: AXUIElement = AXHelpers.getAttribute(
                  app,
                  kAXMainWindowAttribute,
                  runtime: runtime.ax
              ),
        let projectDocument: String = AXHelpers.getAttribute(
            mainWindow,
            kAXDocumentAttribute,
            runtime: runtime.ax
        ),
        !projectDocument.isEmpty else { return nil }

        let matches = titleScopedMarkerListWindows(runtime: runtime).filter { window in
            guard let document: String = AXHelpers.getAttribute(
                      window,
                      kAXDocumentAttribute,
                      runtime: runtime.ax
                  ) else { return false }
            return document == projectDocument
        }
        guard matches.count == 1 else { return nil }
        return MarkerListBinding(window: matches[0], projectDocument: projectDocument)
    }

    static func hasUnverifiedMarkerListWindow(runtime: Runtime = .production) -> Bool {
        !titleScopedMarkerListWindows(runtime: runtime).isEmpty
            && markerListBinding(runtime: runtime) == nil
    }

    private static func titleScopedMarkerListWindows(
        runtime: Runtime
    ) -> [AXUIElement] {
        guard let app = appRoot(runtime: runtime) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app, kAXWindowsAttribute, runtime: runtime.ax
        ) ?? []
        guard let mainWindow: AXUIElement = AXHelpers.getAttribute(
            app,
            kAXMainWindowAttribute,
            runtime: runtime.ax
        ),
        let mainTitle = AXHelpers.getTitle(mainWindow, runtime: runtime.ax),
        let activeProject = markerProjectName(from: mainTitle) else { return [] }
        return windows.filter { window in
            guard let title = AXHelpers.getTitle(window, runtime: runtime.ax),
                  let suffix = AXLocalePolicy.markerListWindowSuffixes.first(where: {
                      title.hasSuffix($0)
                  }) else { return false }
            return title.dropLast(suffix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines) == activeProject
        }
    }

    // MARK: - Markers

    /// Defensive upper bound on AX marker enumeration. Logic projects in the
    /// wild rarely exceed a few dozen markers; this cap keeps the AX traversal
    /// cost predictable even for pathological 10k-marker compositions.
    private static let markerLimit = 512

    /// Enumerate user markers from the project. Strategy order reflects
    /// Logic AX surface drift across major versions:
    ///
    /// **v3.1.9 (Issue #8) — Logic 12.2+ primary**: scrape the dedicated
    /// **Marker List** window's `AXTable`. Logic 12.2 removed user markers
    /// from the main arrange window's AX subtree entirely (the `AXRuler`
    /// strategy that v3.1.8 introduced returns empty on 12.2 because there
    /// are zero `AXRuler` elements in the arrange window). The dedicated
    /// Marker List window — opened via `탐색 → 마커 목록 열기` /
    /// `Navigate → Open Marker List` — exposes markers as
    /// `AXRow → AXCell` rows with name in cell column 2 and position in
    /// cell column 1.
    ///
    /// **v3.1.8 — Logic 11.x fallback**: `AXRuler` structural position
    /// inside the arrange area (the second `AXRuler` is the marker ruler;
    /// the first is the timeline). Preserved for older builds whose marker
    /// ruler is still in the arrange-window subtree.
    ///
    /// **legacy keyword fallback**: scan `AXGroup` descriptions for
    /// `marker` / `마커`. Preserved for very old Logic versions.
    ///
    /// Strategy 1's data quality requires the user to keep the Marker List
    /// window open. Callers that need first-class markers without a
    /// pre-opened window can set `LOGIC_PRO_MCP_AUTO_OPEN_MARKER_LIST=1`
    /// in the environment to trigger a one-time menu click on first
    /// successful project poll (see `defaultGetMarkers` in
    /// `AccessibilityChannel`).
    static func enumerateMarkers(
        in arrangementArea: AXUIElement,
        runtime: Runtime = .production
    ) -> [MarkerState] {
        // Strategy 1 — Logic 12.2+: scrape the Marker List window's AXTable.
        if let listWindow = findMarkerListWindow(runtime: runtime) {
            switch enumerateMarkersFromListWindow(listWindow, runtime: runtime.ax) {
            case .success(let listMarkers):
                return listMarkers
            case .failure:
                // An open Marker List is authoritative. Its failed read cannot be replaced with
                // stale marker-ruler data and then presented as an independent marker answer.
                // This list-returning legacy API cannot surface the AX error itself; callers that
                // need that distinction use enumerateMarkersFromListWindow directly.
                return []
            }
        }

        // Strategy 2 — Logic 11.x: AXRuler-based.
        var rulerElement: AXUIElement? = nil
        let rulers = AXHelpers.findAllDescendants(
            of: arrangementArea, role: "AXRuler", maxDepth: 6, runtime: runtime.ax
        )
        if rulers.count >= 2 {
            rulerElement = rulers[1]
        } else if let only = rulers.first {
            rulerElement = only
        }

        // Strategy 3 — keyword fallback (oldest path).
        if rulerElement == nil {
            // #60: centralized marker-container keyword bag (read-only classifier).
            let markerKeywords = AXLocalePolicy.markerContainerKeywords.labels
            let groups = AXHelpers.findAllDescendants(
                of: arrangementArea, role: kAXGroupRole, maxDepth: 6, runtime: runtime.ax
            )
            for group in groups {
                let id = AXHelpers.getIdentifier(group, runtime: runtime.ax)?.lowercased() ?? ""
                let desc = AXHelpers.getDescription(group, runtime: runtime.ax)?.lowercased() ?? ""
                let title = AXHelpers.getTitle(group, runtime: runtime.ax)?.lowercased() ?? ""
                let combined = "\(id) \(desc) \(title)"
                if markerKeywords.contains(where: { combined.contains($0.lowercased()) }) {
                    rulerElement = group
                    break
                }
            }
        }

        guard let ruler = rulerElement else { return [] }

        let texts = AXHelpers.findAllDescendants(
            of: ruler, role: kAXStaticTextRole, maxDepth: 4, runtime: runtime.ax
        )
        var markers: [MarkerState] = []
        markers.reserveCapacity(min(texts.count, markerLimit))
        for (index, text) in texts.prefix(markerLimit).enumerated() {
            let name = AXHelpers.getTitle(text, runtime: runtime.ax)
                ?? AXHelpers.getDescription(text, runtime: runtime.ax)
                ?? axValueAsName(text, runtime: runtime.ax)
                ?? ""
            guard !name.isEmpty else { continue }
            let parsed = extractMarkerPosition(text, runtime: runtime.ax)
            markers.append(.fromParsed(parsed, ordinal: index, name: name))
        }
        return markers
    }

    /// Locate the open Marker List window (Logic 12.2+ surface). Title
    /// suffix matches:
    ///   - `*- 마커 목록` (Korean localisation)
    ///   - `*- Marker List` (English)
    ///
    /// Returns nil if no such window is open. Window enumeration uses the
    /// `kAXWindowsAttribute` array on the application root; test doubles
    /// that don't implement that attribute correctly fall through to nil.
    /// Matches by suffix because the window title is
    /// `"<project name> - <localized 'Marker List'>"`; the localized suffix
    /// table lives in `AXLocalePolicy.markerListWindowSuffixes` (round-1 #7).
    static func findMarkerListWindow(runtime: Runtime = .production) -> AXUIElement? {
        markerListBinding(runtime: runtime)?.window
    }

    private static func markerProjectName(from windowTitle: String) -> String? {
        if let suffix = AXLocalePolicy.markerListWindowSuffixes.first(where: {
            windowTitle.hasSuffix($0)
        }) {
            let project = windowTitle.dropLast(suffix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return project.isEmpty ? nil : project
        }
        guard let separator = windowTitle.range(of: " - ", options: .backwards) else {
            return nil
        }
        let project = windowTitle[..<separator.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? nil : project
    }

    /// Read `MarkerState[]` from the Marker List window's `AXTable`.
    ///
    /// Observed structure on Logic Pro 12.2 (verified 2026-05-07 against
    /// `무제 15.logicx` with 3 user markers):
    /// ```
    /// AXTable
    ///   AXRow
    ///     AXCell  (Lock column — empty)
    ///     AXCell ─ AXGroup(desc="1 1 1 1 ")  ← position, space-separated B B D T
    ///     AXCell ─ AXCell(desc="마커 1")     ← marker name
    ///     AXCell ─ AXGroup(desc="∞")          ← length, ∞ for trailing marker
    /// ```
    /// We extract name from cell index 2's first child description, position
    /// from cell index 1's first child description (parsed via
    /// `parseMarkerListPosition` to the canonical `"bar.beat.div.tick"` form).
    static func enumerateMarkersFromListWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[MarkerState], AXHelpers.AXStatusError> {
        switch markerListInventoryFromListWindow(window, runtime: runtime) {
        case .success(let inventory):
            return .success(inventory.markers)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Resolves the Marker List table once and retains the rows whose order defines marker IDs.
    static func markerListInventoryFromListWindow(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<MarkerListInventory, AXHelpers.AXStatusError> {
        switch markerListInventoryFromListWindowWithReadFailure(window, runtime: runtime) {
        case .success(let inventory):
            return .success(inventory)
        case .failure(let failure):
            return .failure(failure.status)
        }
    }

    /// Window-based inventory variant that retains a table-discovery failure. The destructive
    /// delete flow uses the already-bound-table variant below after its write, but keeping this
    /// source explicit prevents the diagnostic vocabulary from silently conflating discovery
    /// with row enumeration elsewhere.
    static func markerListInventoryFromListWindowWithReadFailure(
        _ window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<MarkerListInventory, MarkerListReadFailure> {
        let table: AXUIElement
        switch markerListTable(in: window, runtime: runtime) {
        case .success(let foundTable?):
            table = foundTable
        case .success(nil):
            // An open Marker List without its table is not an empty Marker List. The caller
            // asked to enumerate the table's rows; with no table exposed it cannot establish that
            // every row was read (and a destructive caller must treat the readback as unavailable).
            return .failure(MarkerListReadFailure(
                site: .tableLookup,
                status: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
            ))
        case .failure(let error):
            return .failure(MarkerListReadFailure(site: .tableLookup, status: error))
        }

        return markerListInventoryWithReadFailure(from: table, runtime: runtime)
    }

    /// Re-reads the exact table element a caller already bound, without resolving another table
    /// from the window. This is the only valid post-write marker read for a destructive caller.
    static func enumerateMarkersFromListTable(
        _ table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[MarkerState], AXHelpers.AXStatusError> {
        switch markerListInventory(from: table, runtime: runtime) {
        case .success(let inventory):
            return .success(inventory.markers)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// As `enumerateMarkersFromListTable`, but retains the exact post-write read site for the
    /// destructive marker-delete receipt. The table is supplied by the pre-write inventory, so
    /// this method never re-discovers a table from the window.
    static func enumerateMarkersFromListTableWithReadFailure(
        _ table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[MarkerState], MarkerListReadFailure> {
        switch markerListInventoryWithReadFailure(from: table, runtime: runtime) {
        case .success(let inventory):
            return .success(inventory.markers)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private static func markerListInventory(
        from table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<MarkerListInventory, AXHelpers.AXStatusError> {
        switch markerListInventoryWithReadFailure(from: table, runtime: runtime) {
        case .success(let inventory):
            return .success(inventory)
        case .failure(let failure):
            return .failure(failure.status)
        }
    }

    /// Mirrors the inventory reader's existing read/guard flow exactly, retaining where its
    /// existing `AXStatusError` arose instead of flattening it before the delete receipt can
    /// expose the result.
    private static func markerListInventoryWithReadFailure(
        from table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<MarkerListInventory, MarkerListReadFailure> {
        enum RowSource {
            case axRows
            case structuralChildren

            var failureSite: MarkerListReadFailureSite {
                switch self {
                case .axRows: return .axRows
                case .structuralChildren: return .structuralChildren
                }
            }
        }

        let rows: [AXUIElement]
        let rowSource: RowSource
        switch AXHelpers.getAttributeResult(table, "AXRows", runtime: runtime) as Result<[AXUIElement]?, AXHelpers.AXStatusError> {
        case .success(let observedRows?):
            // `AXRows` is never evidence that it is the complete row list. Logic can answer
            // success while the table rebuild still leaves rows in its structural children, both
            // as an empty array and as a truncated non-empty array. Treat a disagreement as an
            // unreadable list, not as a survivor set. The direct-child order is deliberately not
            // compared: AXRows defines marker indices, while the structural traversal can reorder
            // otherwise identical row elements.
            switch markerListStructuralRows(from: table, runtime: runtime) {
            case .success(let structuralRows):
                guard sameElementMultiset(observedRows, structuralRows) else {
                    return .failure(MarkerListReadFailure(
                        site: .structuralChildren,
                        status: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue),
                        origin: .corroboration,
                        axRowsCount: observedRows.count,
                        structuralChildrenCount: structuralRows.count
                    ))
                }
                rows = observedRows
                rowSource = .axRows
            case .failure(let error):
                return .failure(MarkerListReadFailure(site: .structuralChildren, status: error))
            }
        case .failure(let error) where error.isDefinitiveAbsence:
            // `AXRows` unavailable is an answer about that attribute, not evidence that a
            // role-filtered structural `[]` is a complete Marker List. Use the same structural
            // reader as the AXRows-corrobation path: present children that temporarily cease to
            // report AXRow make this poll unreadable rather than a false empty survivor set.
            switch markerListStructuralRows(from: table, runtime: runtime) {
            case .success(let structuralRows):
                rows = structuralRows
                rowSource = .structuralChildren
            case .failure(let error):
                return .failure(MarkerListReadFailure(site: .structuralChildren, status: error))
            }
        case .success(nil):
            // A successful nil carries the same attribute-absence answer as a definitive
            // AXRows failure, so it must take the same guarded structural route.
            switch markerListStructuralRows(from: table, runtime: runtime) {
            case .success(let structuralRows):
                rows = structuralRows
                rowSource = .structuralChildren
            case .failure(let error):
                return .failure(MarkerListReadFailure(site: .structuralChildren, status: error))
            }
        case .failure(let error):
            return .failure(MarkerListReadFailure(site: .axRows, status: error))
        }

        // The cap prevents unbounded AX work, but it must not turn a partial traversal into a
        // complete marker list. A caller that needs a complete list has to receive an unavailable
        // result rather than an apparently valid prefix.
        guard rows.count <= markerLimit else {
            return .failure(MarkerListReadFailure(
                site: rowSource.failureSite,
                status: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
            ))
        }

        var markers: [MarkerState] = []
        markers.reserveCapacity(min(rows.count, markerLimit))
        for (index, row) in rows.enumerated() {
            let cells: [AXUIElement]
            switch directChildren(
                of: row, withRole: kAXCellRole as String,
                absenceIsEmpty: true, runtime: runtime
            ) {
            case .success(let children):
                cells = children
            case .failure(let error):
                return .failure(MarkerListReadFailure(site: .cell, status: error))
            }
            // Need at least 3 cells: [Lock, Position, Name, ...].
            // A present row whose required cells are absent is an incomplete row read, not proof
            // that the row does not represent a marker.
            guard cells.count >= 3 else {
                return .failure(MarkerListReadFailure(
                    site: .cell,
                    status: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
                ))
            }
            let positionRaw: String
            switch firstChildDescription(of: cells[1], runtime: runtime) {
            case .success(let value?):
                positionRaw = value
            case .success(nil):
                return .failure(MarkerListReadFailure(
                    site: .cell,
                    status: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
                ))
            case .failure(let error):
                return .failure(MarkerListReadFailure(site: .cell, status: error))
            }
            let nameRaw: String
            switch firstChildDescription(of: cells[2], runtime: runtime) {
            case .success(let value?):
                nameRaw = value
            case .success(nil):
                return .failure(MarkerListReadFailure(
                    site: .cell,
                    status: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
                ))
            case .failure(let error):
                return .failure(MarkerListReadFailure(site: .cell, status: error))
            }
            let name = nameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .failure(MarkerListReadFailure(
                    site: .cell,
                    status: AXHelpers.AXStatusError(raw: AXError.noValue.rawValue)
                ))
            }
            let parsed = parseMarkerListPosition(positionRaw)
            markers.append(.fromParsed(parsed, ordinal: index, name: name))
        }
        return .success(MarkerListInventory(table: table, rows: rows, markers: markers))
    }

    /// The table's direct structure corroborates an `AXRows` answer. A non-empty child list
    /// whose children no longer identify as rows is not evidence of an empty Marker List: the
    /// table is rebuilding and no complete row list is observable yet.
    private static func markerListStructuralRows(
        from table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(table, runtime: runtime) {
        case .success(let observedChildren):
            children = observedChildren
        case .failure(let error):
            return .failure(error)
        }
        var rows: [AXUIElement] = []
        for child in children {
            switch AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let role):
                if role == (kAXRowRole as String) { rows.append(child) }
            case .failure(let error):
                return .failure(error)
            }
        }
        guard children.isEmpty || !rows.isEmpty else {
            return .failure(AXHelpers.AXStatusError(raw: AXError.noValue.rawValue))
        }
        return .success(rows)
    }

    private static func sameElementMultiset(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var unmatched = rhs
        for element in lhs {
            guard let index = unmatched.firstIndex(where: { CFEqual($0, element) }) else {
                return false
            }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }

    /// Finds the first Marker List table without turning a failed `AXChildren` read into an
    /// empty tree. An empty successful traversal means no table was exposed; a failed traversal
    /// remains unreadable for callers deciding whether a destructive write is verified.
    private static func markerListTable(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<AXUIElement?, AXHelpers.AXStatusError> {
        var unreadable: AXHelpers.AXStatusError?
        var parents = [window]
        for _ in 0..<8 {
            var next: [AXUIElement] = []
            for parent in parents {
                let children: [AXUIElement]
                switch AXHelpers.childrenResult(parent, runtime: runtime) {
                case .success(let observedChildren):
                    children = observedChildren
                case .failure(let error) where error.isDefinitiveAbsence:
                    // A node that vends no children is an answer: nothing here, keep walking.
                    children = []
                case .failure(let error):
                    // A sibling group can refuse an AXChildren read while the real table remains
                    // reachable through another sibling. Skip it, remember the gap, and return the
                    // gap only if no table is found anywhere else in the bounded search.
                    unreadable = unreadable ?? error
                    children = []
                }
                for child in children {
                    switch AXHelpers.getAttributeResult(
                        child, kAXRoleAttribute as String, runtime: runtime
                    ) as Result<String?, AXHelpers.AXStatusError> {
                    case .success(let role):
                        if role == (kAXTableRole as String) { return .success(child) }
                    case .failure(let error) where error.isDefinitiveAbsence:
                        break
                    case .failure(let error):
                        // A node that will not answer is not a candidate. Measured on Logic 12.3,
                        // nodes answer -25200 mid-walk while enumeration in the same call succeeds,
                        // so aborting the SEARCH here refused every marker operation intermittently.
                        // Remember it instead, so "no table" stays distinct from "not found and part
                        // of the tree was unreadable".
                        unreadable = unreadable ?? error
                    }
                    next.append(child)
                }
            }
            parents = next
        }
        if let unreadable { return .failure(unreadable) }
        return .success(nil)
    }

    /// Reads direct children with a role match while preserving child-read failures. Role
    /// attributes are part of the structural reading too: treating an unreadable role as a
    /// non-match could manufacture an empty Marker List.
    /// `absenceIsEmpty` decides which QUESTION this read is answering, and the two are not
    /// interchangeable. Asking a cell whether it has child elements that might carry a label, an
    /// absent child list is an answer: the cell simply has none, and the caller falls back to the
    /// cell's own description. Asking a TABLE for its rows, it is not: a container that must hold
    /// the rows and will not vend them has not told us there are none, it has told us it cannot be
    /// seen. Laundering that into `[]` produced a settled empty survivor set and certified State A
    /// for a delete that may never have happened.
    private static func directChildren(
        of element: AXUIElement,
        withRole role: String,
        absenceIsEmpty: Bool,
        runtime: AXHelpers.Runtime
    ) -> Result<[AXUIElement], AXHelpers.AXStatusError> {
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .success(let observedChildren):
            children = observedChildren
        case .failure(let error) where absenceIsEmpty && error.isDefinitiveAbsence:
            children = []
        case .failure(let error):
            return .failure(error)
        }
        var matches: [AXUIElement] = []
        for child in children {
            switch AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let observedRole):
                if observedRole == role { matches.append(child) }
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(matches)
    }

    /// First non-empty `AXDescription` in `cell`'s direct children, skipping
    /// the localized placeholder ("셀" / "Cell" / "セル" / etc.) that
    /// `AXCell`s carry by default (table in `AXLocalePolicy.markerCellPlaceholders`,
    /// round-1 #7). Falls through to the cell's own description / value if no
    /// child carries a meaningful one.
    private static func firstChildDescription(
        of cell: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> Result<String?, AXHelpers.AXStatusError> {
        let placeholder = AXLocalePolicy.markerCellPlaceholders
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(cell, runtime: runtime) {
        case .success(let observedChildren):
            children = observedChildren
        case .failure(let error) where error.isDefinitiveAbsence:
            children = []
        case .failure(let error):
            return .failure(error)
        }
        for child in children {
            switch AXHelpers.getAttributeResult(
                child, kAXDescriptionAttribute as String, runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let description):
                if let description, !description.isEmpty, !placeholder.contains(description) {
                    return .success(description)
                }
            case .failure(let error) where error.isDefinitiveAbsence:
                // A child without AXDescription may still carry its label in AXValue.
                break
            case .failure(let error):
                return .failure(error)
            }
            switch AXHelpers.getAttributeResult(
                child, kAXValueAttribute as String, runtime: runtime
            ) as Result<AnyObject?, AXHelpers.AXStatusError> {
            case .success(let value):
                if let value = value as? String, !value.isEmpty {
                    return .success(value)
                }
            case .failure(let error) where error.isDefinitiveAbsence:
                // This child vends neither label attribute; keep looking.
                break
            case .failure(let error):
                return .failure(error)
            }
        }
        switch AXHelpers.getAttributeResult(
            cell, kAXDescriptionAttribute as String, runtime: runtime
        ) as Result<String?, AXHelpers.AXStatusError> {
        case .success(let description):
            if let description, !description.isEmpty, !placeholder.contains(description) {
                return .success(description)
            }
        case .failure(let error) where error.isDefinitiveAbsence:
            // The cell itself may still expose AXValue.
            break
        case .failure(let error):
            return .failure(error)
        }
        switch AXHelpers.getAttributeResult(
            cell, kAXValueAttribute as String, runtime: runtime
        ) as Result<AnyObject?, AXHelpers.AXStatusError> {
        case .success(let value):
            if let value = value as? String, !value.isEmpty {
                return .success(value)
            }
        case .failure(let error) where error.isDefinitiveAbsence:
            return .success(nil)
        case .failure(let error):
            return .failure(error)
        }
        return .success(nil)
    }

    /// Logic Marker List 셀의 위치 문자열을 표준 "bar.beat.div.tick" 형태로 변환한다.
    ///
    /// 관찰된 입력 변형:
    /// - 한글 12.2: `"1 1 1 1"` (공백 구분, whole-bar)
    /// - 영문 12.2: `"146 4 4 240."` (공백 구분 + UI 끝 마침표)
    ///
    /// 정확히 4 컴포넌트, 각 ASCII 정수 1 이상이어야 한다. Logic UI는 항상 4
    /// 컴포넌트를 노출하므로 1-3 컴포넌트는 비-position 셀(예: tempo)일 가능성으로
    /// nil 반환한다. 호출자는 `\(index+1).1.1.1` fallback을 사용한다.
    static func parseMarkerListPosition(_ raw: String) -> String? {
        // 끝의 마침표/콤마는 Logic UI rendering artifact — 반복 strip.
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, last == "." || last == "," {
            trimmed.removeLast()
        }
        // 공백/탭만 separator (Logic은 공백만 사용; 점은 끝에서만 의미).
        let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        // 정확히 4 컴포넌트 + ASCII 0-9만 (부호 prefix·Arabic-Indic 거부) + 1-based.
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  part.allSatisfy { $0.isASCII && $0.isNumber }
                      && (Int(part) ?? 0) >= 1
              }) else {
            return nil
        }
        return parts.joined(separator: ".")
    }

    private static func axValueAsName(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        guard let v = AXValueExtractors.extractTextValue(element, runtime: runtime),
              !v.isEmpty, !looksLikeBarPosition(v) else { return nil }
        return v
    }

    private static func extractMarkerPosition(
        _ element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> String? {
        let candidates = [
            AXValueExtractors.extractTextValue(element, runtime: runtime),
            AXHelpers.getHelp(element, runtime: runtime),
            AXHelpers.getDescription(element, runtime: runtime),
        ]
        for candidate in candidates {
            guard let raw = candidate, !raw.isEmpty else { continue }
            if looksLikeBarPosition(raw) { return raw }
        }
        return nil
    }

    private static func looksLikeBarPosition(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 1, parts.count <= 4 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

}
