import ApplicationServices
import Foundation

/// The measured Logic 12.3 Tempo List surface.
///
/// This is intentionally not a general Smart Tempo driver. It opens and reads the existing Tempo
/// List table, and can adjust the tempo of one existing row. The six disabled region-tempo menu
/// items and `Open Smart Tempo Editor` remain UNMEASURED: they require an audio-region selection
/// that was not available during the 2026-09-02 observation, so this type refuses by never
/// resolving or pressing those labels. Creating or deleting tempo events is likewise out of scope.
enum TempoMapAX {
    /// One measured AXRow. `position` and `smpte` preserve the AXDescription supplied by Logic;
    /// `tempo` is parsed directly from the whole Tempo cell group's AXDescription, not rebuilt from
    /// its seven digit sliders.
    struct Event: Codable, Equatable, Sendable {
        let position: String
        let tempo: Double
        let smpte: String
    }

    /// A stable Tempo List reading. `reportedEventCount` comes from the `Number of Items` /
    /// `항목 수` AXStaticText, while `events` comes from the table's AXRows. Construction is private
    /// to `read`: it requires those two witnesses to agree in each of two consecutive passes.
    /// That corroborates stable agreement at those instants; it does not prove a globally complete
    /// AX table while Logic is still rendering it.
    struct Snapshot: Codable, Equatable, Sendable {
        let reportedEventCount: Int
        let events: [Event]
    }

    enum ReadRefusal: Error, Equatable, Sendable, CustomStringConvertible {
        case unmeasuredLocale(String)
        case tempoListWindowUnavailable
        case tempoListMenuUnavailable
        case tempoListMenuDisabled
        case axReadFailed(site: String, status: AXHelpers.AXStatusError)
        case tableMissing
        case tableAmbiguous(count: Int)
        case rowsUnavailable
        case rowShapeMismatch(row: Int, expectedCells: Int, actualCells: Int)
        case cellGroupMissing(row: Int, cell: Int)
        case cellDescriptionMissing(row: Int, cell: Int)
        case invalidTempo(row: Int, description: String)
        case itemCountMissing
        case invalidItemCount(String)
        case incompleteRead(reportedEventCount: Int, observedRowCount: Int)
        case inventoryUnstable(
            firstReportedEventCount: Int,
            firstObservedRowCount: Int,
            secondReportedEventCount: Int,
            secondObservedRowCount: Int
        )

        var description: String {
            switch self {
            case let .unmeasuredLocale(locale):
                return "Tempo List is unmeasured for Logic UI locale '\(locale)'; only en-US and ko-KR are allowed."
            case .tempoListWindowUnavailable:
                return "Tempo List window is unavailable."
            case .tempoListMenuUnavailable:
                return "Edit > Tempo > Show Tempo List is unavailable."
            case .tempoListMenuDisabled:
                return "Edit > Tempo > Show Tempo List is disabled."
            case let .axReadFailed(site, status):
                let name = status.symbolicName ?? "AX status"
                return "Tempo List AX read at \(site) failed with \(name) (\(status.diagnosticLabel))."
            case .tableMissing:
                return "Tempo List table is unavailable."
            case let .tableAmbiguous(count):
                return "Tempo List table is ambiguous (\(count) candidates)."
            case .rowsUnavailable:
                return "Tempo List AXRows is unavailable."
            case let .rowShapeMismatch(row, expectedCells, actualCells):
                return "Tempo List row \(row) has \(actualCells) cells; expected \(expectedCells)."
            case let .cellGroupMissing(row, cell):
                return "Tempo List row \(row), cell \(cell) does not expose its AXGroup."
            case let .cellDescriptionMissing(row, cell):
                return "Tempo List row \(row), cell \(cell) has no AXGroup description."
            case let .invalidTempo(row, description):
                return "Tempo List row \(row) has an invalid tempo description '\(description)'."
            case .itemCountMissing:
                return "Tempo List Number of Items / 항목 수 text is unavailable."
            case let .invalidItemCount(value):
                return "Tempo List item-count value '\(value)' has no leading count."
            case let .incompleteRead(reportedEventCount, observedRowCount):
                return "Tempo List read is incomplete: item-count says \(reportedEventCount), table exposes \(observedRowCount) rows."
            case let .inventoryUnstable(firstCount, firstRows, secondCount, secondRows):
                return "Tempo List witnesses changed between passes: (\(firstCount), \(firstRows)) became (\(secondCount), \(secondRows))."
            }
        }

        /// A rebuilding tree invalidates this observation, not the operation. The settle poll
        /// obtains a fresh inventory instead of treating this as a permanent Tempo List failure.
        var isTransientDuringRebuild: Bool {
            guard case let .axReadFailed(_, status) = self else { return false }
            return status.isTransientDuringRebuild
        }
    }

    enum WriteFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidTarget(Double)
        case eventIndexOutOfRange(index: Int, count: Int)
        case positionChanged(expected: String, observed: String)
        case axWriteFailed
        case readFailed(ReadRefusal)
        case didNotMove(previous: Double, observed: Double, target: Double)
        case movedAway(previous: Double, observed: Double, target: Double)
        case crossedTarget(previous: Double, observed: Double, target: Double)
        case attemptBudgetExhausted(observed: Double, target: Double, budget: Int)
        case deadlineExceeded(observed: Double, target: Double)

        var description: String {
            switch self {
            case let .invalidTarget(target):
                return "Tempo target \(target) is not a whole BPM in Logic's supported 5...999 range."
            case let .eventIndexOutOfRange(index, count):
                return "Tempo event index \(index) is out of range for \(count) event(s)."
            case let .positionChanged(expected, observed):
                return "Tempo row changed position from '\(expected)' to '\(observed)'; refusing to write a different event."
            case .axWriteFailed:
                return "Tempo List AXValue write failed before a new value could be observed."
            case let .readFailed(refusal):
                return "Tempo List read failed after a write: \(refusal.description)"
            case let .didNotMove(previous, observed, target):
                return "Tempo write did not move toward \(target): it stayed at \(observed) (previous \(previous))."
            case let .movedAway(previous, observed, target):
                return "Tempo write moved away from \(target): \(previous) became \(observed)."
            case let .crossedTarget(previous, observed, target):
                return "Tempo write crossed \(target): \(previous) became \(observed), so the measured integer walk is no longer authorized."
            case let .attemptBudgetExhausted(observed, target, budget):
                return "Tempo write spent its bounded budget of \(budget) step(s) and stopped at \(observed), not \(target)."
            case let .deadlineExceeded(observed, target):
                return "Tempo write reached its wall-clock deadline at \(observed), not \(target)."
            }
        }
    }

    enum RollbackOutcome: Equatable, Sendable {
        /// No forward value differed from the original tempo, so no restore write was needed.
        case notNeeded(writes: Int, finalObserved: Double?)
        /// The same fresh-read, non-crossing walk reached the original tempo.
        case restored(writes: Int, finalObserved: Double)
        /// Restoration is attempted and reported, never guaranteed. No further writes are attempted
        /// after this failure; `writes` and `finalObserved` retain the restore receipt.
        case failed(failure: WriteFailure, writes: Int, finalObserved: Double?)
    }

    enum WriteOutcome: Equatable, Sendable {
        /// A successful no-op. This is deliberately different from `.converged(writes: 0)` so a
        /// caller can tell that no AX mutation was attempted because the event was already correct.
        case alreadyAtTarget(observed: Double)
        case converged(initial: Double, observed: Double, writes: Int)
        case refused(failure: WriteFailure, rollback: RollbackOutcome)
    }

    /// The measured writer has only observed whole-BPM steps. Fractional target values therefore
    /// refuse rather than guessing that an unmeasured stepping rule can land on them.
    private static let supportedTempoDecimalPlaces = 0
    /// A practical cap even inside Logic's bounded tempo range; this is a mutation safety limit,
    /// not evidence that all valid distances can be driven in one request.
    private static let maximumConvergenceWrites = 64
    private static let convergenceDeadline: TimeInterval = 3.0
    /// ASSUMED, not yet measured live: the first live Tempo List drive must replace these settle
    /// numbers with measured values. They bound two consecutive fresh observations after a write.
    private static let postWriteSettleDeadline: TimeInterval = 0.5
    private static let postWriteSettlePollMicros: useconds_t = 20_000

    /// Opens the only measured Tempo-menu view. The caller can then pass the returned window to
    /// `read(in:localeIdentifier:runtime:)` or `setExistingTempo(...)`.
    @discardableResult
    static func openTempoList(
        runtime: AXLogicProElements.Runtime = .production,
        localeIdentifier: String? = nil
    ) throws -> AXUIElement {
        try requireMeasuredLocale(runtime: runtime, localeIdentifier: localeIdentifier)
        guard let menuItem = AXLogicProElements.menuItem(
            labelPath: AXLocalePolicy.showTempoListMenuPath,
            runtime: runtime
        ) else {
            throw ReadRefusal.tempoListMenuUnavailable
        }
        guard menuItemIsEnabled(menuItem, runtime: runtime.ax) else {
            throw ReadRefusal.tempoListMenuDisabled
        }
        guard AXHelpers.performAction(menuItem, kAXPressAction as String, runtime: runtime.ax) else {
            throw ReadRefusal.tempoListMenuUnavailable
        }
        guard let window = try findTempoListWindow(runtime: runtime) else {
            throw ReadRefusal.tempoListWindowUnavailable
        }
        return window
    }

    /// Reads every existing Tempo List event from the passed window.
    ///
    /// The inventory is resolved from `window` for this call; no AXRow, AXCell, or AXGroup is
    /// retained in the public snapshot. This is essential because Logic re-renders a row after a
    /// value write and a cached AXUIElement can subsequently read nil.
    static func read(
        in window: AXUIElement,
        localeIdentifier: String? = nil,
        runtime: AXLogicProElements.Runtime = .production
    ) throws -> Snapshot {
        try requireMeasuredLocale(runtime: runtime, localeIdentifier: localeIdentifier)
        return try inventory(in: window, runtime: runtime.ax).snapshot
    }

    /// Reads an already-open Tempo List without relying on an unmeasured window title. A candidate
    /// must structurally contain the measured table and count witness; zero or multiple candidates
    /// refuse rather than choosing by window order.
    static func readOpenTempoList(
        runtime: AXLogicProElements.Runtime = .production,
        localeIdentifier: String? = nil
    ) throws -> Snapshot {
        try requireMeasuredLocale(runtime: runtime, localeIdentifier: localeIdentifier)
        guard let window = try findTempoListWindow(runtime: runtime) else {
            throw ReadRefusal.tempoListWindowUnavailable
        }
        return try inventory(in: window, runtime: runtime.ax).snapshot
    }

    /// Sets one existing event by row index and verifies the result.
    ///
    /// The only measured write sequence is integer BPM: `118 → set 120 → 119`, then `119 → set
    /// 120 → 120`. Fractional targets refuse. Every loop observation starts again from `window`; it
    /// never reads a cached row/group after Logic has re-rendered it, and every loop is bounded by
    /// both an iteration cap and a wall-clock deadline.
    static func setExistingTempo(
        at index: Int,
        to target: Double,
        in window: AXUIElement,
        localeIdentifier: String? = nil,
        runtime: AXLogicProElements.Runtime = .production
    ) -> WriteOutcome {
        do {
            try requireMeasuredLocale(runtime: runtime, localeIdentifier: localeIdentifier)
        } catch let refusal as ReadRefusal {
            return .refused(
                failure: .readFailed(refusal),
                rollback: .notNeeded(writes: 0, finalObserved: nil)
            )
        } catch {
            return .refused(
                failure: .readFailed(.unmeasuredLocale(localeIdentifier ?? "unknown")),
                rollback: .notNeeded(writes: 0, finalObserved: nil)
            )
        }

        guard isSupportedTempoTarget(target) else {
            return .refused(
                failure: .invalidTarget(target),
                rollback: .notNeeded(writes: 0, finalObserved: nil)
            )
        }

        let initial: Event
        do {
            let snapshot = try read(in: window, localeIdentifier: localeIdentifier, runtime: runtime)
            guard snapshot.events.indices.contains(index) else {
                return .refused(
                    failure: .eventIndexOutOfRange(index: index, count: snapshot.events.count),
                    rollback: .notNeeded(writes: 0, finalObserved: nil)
                )
            }
            initial = snapshot.events[index]
        } catch let refusal as ReadRefusal {
            return .refused(
                failure: .readFailed(refusal),
                rollback: .notNeeded(writes: 0, finalObserved: nil)
            )
        } catch {
            return .refused(
                failure: .readFailed(.tempoListWindowUnavailable),
                rollback: .notNeeded(writes: 0, finalObserved: nil)
            )
        }

        guard initial.tempo != target else {
            return .alreadyAtTarget(observed: initial.tempo)
        }

        let forward = converge(
            at: index,
            from: initial,
            to: target,
            in: window,
            localeIdentifier: localeIdentifier,
            runtime: runtime,
            deadline: Date().addingTimeInterval(convergenceDeadline)
        )
        switch forward {
        case let .success(observed, writes):
            return .converged(initial: initial.tempo, observed: observed, writes: writes)
        case let .failure(failure, writes, finalObserved):
            let rollback: RollbackOutcome
            if writes == 0 {
                rollback = .notNeeded(writes: 0, finalObserved: finalObserved)
            } else {
                rollback = rollbackToInitialTempo(
                    at: index,
                    initial: initial,
                    in: window,
                    localeIdentifier: localeIdentifier,
                    runtime: runtime,
                    fallbackObserved: finalObserved
                )
            }
            return .refused(failure: failure, rollback: rollback)
        }
    }

    // MARK: - Fresh inventory

    private struct Inventory {
        let snapshot: Snapshot
        /// This is intentionally private to one immediate AXValue set. The next observation
        /// must call `inventory(in:)` again because Logic invalidates the group on row re-render.
        let tempoGroups: [AXUIElement]
    }

    private static func inventory(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> Inventory {
        let first = try inventoryPass(in: window, runtime: runtime)
        let second = try inventoryPass(in: window, runtime: runtime)
        let firstWitness = InventoryWitness(
            reportedEventCount: first.snapshot.reportedEventCount,
            observedRowCount: first.snapshot.events.count
        )
        let secondWitness = InventoryWitness(
            reportedEventCount: second.snapshot.reportedEventCount,
            observedRowCount: second.snapshot.events.count
        )
        guard firstWitness == secondWitness else {
            throw ReadRefusal.inventoryUnstable(
                firstReportedEventCount: firstWitness.reportedEventCount,
                firstObservedRowCount: firstWitness.observedRowCount,
                secondReportedEventCount: secondWitness.reportedEventCount,
                secondObservedRowCount: secondWitness.observedRowCount
            )
        }
        return second
    }

    private struct InventoryWitness: Equatable {
        let reportedEventCount: Int
        let observedRowCount: Int
    }

    private static func inventoryPass(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> Inventory {
        let table = try tempoListTable(in: window, runtime: runtime)
        let rows = try tempoListRows(in: table, runtime: runtime)
        let count = try itemCount(in: window, runtime: runtime)

        var events: [Event] = []
        var tempoGroups: [AXUIElement] = []
        events.reserveCapacity(rows.count)
        tempoGroups.reserveCapacity(rows.count)

        for (rowIndex, row) in rows.enumerated() {
            let cells = try directChildren(
                of: row,
                withRole: kAXCellRole as String,
                site: "row \(rowIndex) AXCells",
                runtime: runtime
            )
            guard cells.count == 3 else {
                throw ReadRefusal.rowShapeMismatch(
                    row: rowIndex,
                    expectedCells: 3,
                    actualCells: cells.count
                )
            }

            let position = try groupDescription(
                in: cells[0], row: rowIndex, cellIndex: 0, runtime: runtime
            )
            let tempoGroup = try group(
                in: cells[1], row: rowIndex, cellIndex: 1, runtime: runtime
            )
            let tempoDescription = try description(of: tempoGroup, row: rowIndex, cell: 1, runtime: runtime)
            guard let tempo = Double(tempoDescription.trimmingCharacters(in: .whitespacesAndNewlines)),
                  tempo.isFinite,
                  TransportDispatcher.supportedTempoRange.contains(tempo) else {
                throw ReadRefusal.invalidTempo(row: rowIndex, description: tempoDescription)
            }
            let smpte = try groupDescription(
                in: cells[2], row: rowIndex, cellIndex: 2, runtime: runtime
            )

            events.append(Event(position: position, tempo: tempo, smpte: smpte))
            tempoGroups.append(tempoGroup)
        }

        guard count == events.count else {
            throw ReadRefusal.incompleteRead(
                reportedEventCount: count,
                observedRowCount: events.count
            )
        }
        return Inventory(
            snapshot: Snapshot(reportedEventCount: count, events: events),
            tempoGroups: tempoGroups
        )
    }

    private static func tempoListTable(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> AXUIElement {
        let census: AXHelpers.Census
        switch AXHelpers.censusDescendantResult(
            of: window,
            role: kAXTableRole as String,
            maxDepth: 12,
            runtime: runtime
        ) {
        case let .success(observed):
            census = observed
        case let .failure(error):
            throw axReadFailed(site: "Tempo List table census", status: error)
        }
        guard census.candidates > 0 else { throw ReadRefusal.tableMissing }
        guard census.candidates == 1, let table = census.element else {
            throw ReadRefusal.tableAmbiguous(count: census.candidates)
        }
        return table
    }

    private static func tempoListRows(
        in table: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> [AXUIElement] {
        guard let rows: [AXUIElement] = try attribute(
            table,
            "AXRows",
            site: "Tempo List AXRows",
            runtime: runtime
        ) else {
            throw ReadRefusal.rowsUnavailable
        }
        return rows
    }

    private static func group(
        in cell: AXUIElement,
        row: Int,
        cellIndex: Int,
        runtime: AXHelpers.Runtime
    ) throws -> AXUIElement {
        let groups = try directChildren(
            of: cell,
            withRole: kAXGroupRole as String,
            site: "row \(row) cell \(cellIndex) AXGroup",
            runtime: runtime
        )
        guard groups.count == 1, let group = groups.first else {
            throw ReadRefusal.cellGroupMissing(row: row, cell: cellIndex)
        }
        return group
    }

    private static func groupDescription(
        in cell: AXUIElement,
        row: Int,
        cellIndex: Int,
        runtime: AXHelpers.Runtime
    ) throws -> String {
        let valueGroup = try group(in: cell, row: row, cellIndex: cellIndex, runtime: runtime)
        return try description(of: valueGroup, row: row, cell: cellIndex, runtime: runtime)
    }

    private static func description(
        of group: AXUIElement,
        row: Int,
        cell: Int,
        runtime: AXHelpers.Runtime
    ) throws -> String {
        guard let description: String = try attribute(
            group,
            kAXDescriptionAttribute,
            site: "row \(row) cell \(cell) AXDescription",
            runtime: runtime
        ), !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadRefusal.cellDescriptionMissing(row: row, cell: cell)
        }
        return description
    }

    private static func itemCount(
        in window: AXUIElement,
        runtime: AXHelpers.Runtime
    ) throws -> Int {
        let census = try localizedCensus(
            of: window,
            labels: AXLocalePolicy.tempoListNumberOfItemsLabel,
            site: "Tempo List item-count census",
            runtime: runtime
        )
        guard census.candidates == 1,
              let text = census.element else {
            throw ReadRefusal.itemCountMissing
        }
        guard let value: String = try attribute(
            text,
            kAXValueAttribute,
            site: "Tempo List item-count AXValue",
            runtime: runtime
        ) else {
            throw ReadRefusal.itemCountMissing
        }
        guard let count = leadingASCIIInteger(in: value) else {
            throw ReadRefusal.invalidItemCount(value)
        }
        return count
    }

    private static func leadingASCIIInteger(in value: String) -> Int? {
        let digits = value.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// `noValue` and `attributeUnsupported` are an observed absence; every other AX status is a
    /// failed observation and must remain visible to the authority decision.
    private static func attribute<T>(
        _ element: AXUIElement,
        _ name: String,
        site: String,
        runtime: AXHelpers.Runtime
    ) throws -> T? {
        switch AXHelpers.getAttributeResult(element, name, runtime: runtime) as Result<T?, AXHelpers.AXStatusError> {
        case let .success(value):
            return value
        case let .failure(error) where error.isDefinitiveAbsence:
            return nil
        case let .failure(error):
            throw axReadFailed(site: site, status: error)
        }
    }

    private static func directChildren(
        of element: AXUIElement,
        withRole role: String,
        site: String,
        runtime: AXHelpers.Runtime
    ) throws -> [AXUIElement] {
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case let .success(observed):
            children = observed
        case let .failure(error) where error.isDefinitiveAbsence:
            children = []
        case let .failure(error):
            throw axReadFailed(site: site, status: error)
        }
        return try children.filter { child in
            let childRole: String? = try attribute(
                child,
                kAXRoleAttribute as String,
                site: "\(site) role",
                runtime: runtime
            )
            return childRole == role
        }
    }

    /// `AXLocalePolicy.censusDescendantResult` preserves a failed lookup when no label matches,
    /// but Tempo List write authority needs the stricter fact: every competing static-text label
    /// must be readable even when another one happens to match. Validate each title/description
    /// after the policy census so an unreadable competing count witness cannot disappear.
    private static func localizedCensus(
        of element: AXUIElement,
        labels: AXLocalePolicy.LabelSet,
        site: String,
        runtime: AXHelpers.Runtime
    ) throws -> AXLocalePolicy.Census {
        let policyCensus: AXLocalePolicy.Census
        switch AXLocalePolicy.censusDescendantResult(
            of: element,
            role: kAXStaticTextRole as String,
            matching: labels,
            mode: .exactStrict,
            maxDepth: 12,
            runtime: runtime
        ) {
        case let .success(observed):
            policyCensus = observed
        case let .failure(error):
            throw axReadFailed(site: site, status: error)
        }

        let staticTexts: AXHelpers.Census
        switch AXHelpers.censusDescendantResult(
            of: element,
            role: kAXStaticTextRole as String,
            maxDepth: 12,
            runtime: runtime
        ) {
        case let .success(observed):
            staticTexts = observed
        case let .failure(error):
            throw axReadFailed(site: site, status: error)
        }
        for staticText in staticTexts.matches {
            let _: String? = try attribute(
                staticText,
                kAXTitleAttribute as String,
                site: "\(site) AXTitle",
                runtime: runtime
            )
            let _: String? = try attribute(
                staticText,
                kAXDescriptionAttribute as String,
                site: "\(site) AXDescription",
                runtime: runtime
            )
        }
        return policyCensus
    }

    private static func axReadFailed(
        site: String,
        status: AXHelpers.AXStatusError
    ) -> ReadRefusal {
        .axReadFailed(site: site, status: status)
    }

    // MARK: - Convergence and rollback

    private enum Convergence {
        case success(observed: Double, writes: Int)
        case failure(WriteFailure, writes: Int, finalObserved: Double?)
    }

    private static func converge(
        at index: Int,
        from initial: Event,
        to target: Double,
        in window: AXUIElement,
        localeIdentifier: String?,
        runtime: AXLogicProElements.Runtime,
        deadline: Date
    ) -> Convergence {
        guard let budget = attemptBudget(from: initial.tempo, to: target) else {
            return .failure(.invalidTarget(target), writes: 0, finalObserved: initial.tempo)
        }
        var current = initial
        var writes = 0

        for _ in 0..<budget {
            guard Date() < deadline else {
                return .failure(
                    .deadlineExceeded(observed: current.tempo, target: target),
                    writes: writes,
                    finalObserved: current.tempo
                )
            }
            // Resolve the table, row, and value group anew immediately before every write. This is
            // not an optimization opportunity: the prior group's AXDescription can become nil when
            // Logic re-renders the row, and nil is not an observation that the value changed.
            let fresh: Inventory
            do {
                fresh = try inventory(in: window, runtime: runtime.ax)
            } catch let refusal as ReadRefusal {
                return .failure(.readFailed(refusal), writes: writes, finalObserved: current.tempo)
            } catch {
                return .failure(
                    .readFailed(.tempoListWindowUnavailable),
                    writes: writes,
                    finalObserved: current.tempo
                )
            }
            guard fresh.snapshot.events.indices.contains(index) else {
                return .failure(
                    .eventIndexOutOfRange(index: index, count: fresh.snapshot.events.count),
                    writes: writes,
                    finalObserved: current.tempo
                )
            }
            let freshEvent = fresh.snapshot.events[index]
            guard freshEvent.position == initial.position else {
                return .failure(
                    .positionChanged(expected: initial.position, observed: freshEvent.position),
                    writes: writes,
                    finalObserved: freshEvent.tempo
                )
            }
            current = freshEvent
            if current.tempo == target {
                return .success(observed: current.tempo, writes: writes)
            }

            guard AXHelpers.setAttribute(
                fresh.tempoGroups[index],
                kAXValueAttribute,
                NSNumber(value: target),
                runtime: runtime.ax
            ) else {
                return .failure(.axWriteFailed, writes: writes, finalObserved: current.tempo)
            }
            writes += 1

            // Re-enter through `read`, which resolves from `window` and deliberately retains no
            // reference from `fresh`. Two consecutive fresh observations must agree before this
            // write is judged. An invalid/rebuilding AX element is re-read within the deadline.
            let next: Event
            switch settleEvent(
                at: index,
                expectedPosition: initial.position,
                after: current,
                toward: target,
                in: window,
                localeIdentifier: localeIdentifier,
                runtime: runtime,
                deadline: min(deadline, Date().addingTimeInterval(postWriteSettleDeadline))
            ) {
            case let .success(observed):
                next = observed
            case let .failure(failure):
                return .failure(failure, writes: writes, finalObserved: current.tempo)
            }
            if next.tempo == target {
                return .success(observed: next.tempo, writes: writes)
            }
            if next.tempo == current.tempo {
                return .failure(
                    .didNotMove(previous: current.tempo, observed: next.tempo, target: target),
                    writes: writes,
                    finalObserved: next.tempo
                )
            }
            if crossedTarget(from: current.tempo, to: next.tempo, target: target) {
                return .failure(
                    .crossedTarget(previous: current.tempo, observed: next.tempo, target: target),
                    writes: writes,
                    finalObserved: next.tempo
                )
            }
            guard movesTowardTarget(from: current.tempo, to: next.tempo, target: target) else {
                return .failure(
                    .movedAway(previous: current.tempo, observed: next.tempo, target: target),
                    writes: writes,
                    finalObserved: next.tempo
                )
            }
            current = next
        }

        return .failure(
            .attemptBudgetExhausted(observed: current.tempo, target: target, budget: budget),
            writes: writes,
            finalObserved: current.tempo
        )
    }

    private static func settleEvent(
        at index: Int,
        expectedPosition: String,
        after current: Event,
        toward target: Double,
        in window: AXUIElement,
        localeIdentifier: String?,
        runtime: AXLogicProElements.Runtime,
        deadline: Date
    ) -> Result<Event, WriteFailure> {
        var previous: Event?
        while Date() < deadline {
            do {
                let reread = try read(
                    in: window,
                    localeIdentifier: localeIdentifier,
                    runtime: runtime
                )
                guard reread.events.indices.contains(index) else {
                    return .failure(.eventIndexOutOfRange(index: index, count: reread.events.count))
                }
                let observed = reread.events[index]
                guard observed.position == expectedPosition else {
                    return .failure(
                        .positionChanged(expected: expectedPosition, observed: observed.position)
                    )
                }
                if previous == observed {
                    return .success(observed)
                }
                previous = observed
            } catch let refusal as ReadRefusal where refusal.isTransientDuringRebuild {
                // A rebuild invalidates the pair; the next observation must be fresh again.
                previous = nil
            } catch let refusal as ReadRefusal {
                return .failure(.readFailed(refusal))
            } catch {
                return .failure(.readFailed(.tempoListWindowUnavailable))
            }
            if Date() < deadline { usleep(postWriteSettlePollMicros) }
        }
        return .failure(.deadlineExceeded(observed: previous?.tempo ?? current.tempo, target: target))
    }

    private static func rollbackToInitialTempo(
        at index: Int,
        initial: Event,
        in window: AXUIElement,
        localeIdentifier: String?,
        runtime: AXLogicProElements.Runtime,
        fallbackObserved: Double?
    ) -> RollbackOutcome {
        let current: Event
        do {
            let snapshot = try read(
                in: window,
                localeIdentifier: localeIdentifier,
                runtime: runtime
            )
            guard snapshot.events.indices.contains(index) else {
                return .failed(
                    failure: .eventIndexOutOfRange(index: index, count: snapshot.events.count),
                    writes: 0,
                    finalObserved: fallbackObserved
                )
            }
            current = snapshot.events[index]
        } catch let refusal as ReadRefusal {
            return .failed(failure: .readFailed(refusal), writes: 0, finalObserved: fallbackObserved)
        } catch {
            return .failed(
                failure: .readFailed(.tempoListWindowUnavailable),
                writes: 0,
                finalObserved: fallbackObserved
            )
        }

        guard current.position == initial.position else {
            return .failed(
                failure: .positionChanged(expected: initial.position, observed: current.position),
                writes: 0,
                finalObserved: current.tempo
            )
        }
        guard current.tempo != initial.tempo else {
            return .notNeeded(writes: 0, finalObserved: current.tempo)
        }

        switch converge(
            at: index,
            from: current,
            to: initial.tempo,
            in: window,
            localeIdentifier: localeIdentifier,
            runtime: runtime,
            deadline: Date().addingTimeInterval(convergenceDeadline)
        ) {
        case let .success(observed, writes):
            return .restored(writes: writes, finalObserved: observed)
        case let .failure(failure, writes, finalObserved):
            return .failed(failure: failure, writes: writes, finalObserved: finalObserved)
        }
    }

    /// The measured one-BPM walk informs this bound, but a separate practical cap prevents a valid
    /// target from authorizing arbitrary AX work. `Int(exactly:)` cannot trap on a rounded value.
    private static func attemptBudget(from current: Double, to target: Double) -> Int? {
        let requiredDistance = distance(current, target)
        guard requiredDistance.isFinite, requiredDistance > 0 else { return nil }
        let roundedDistance = requiredDistance.rounded(.up)
        guard let exactDistance = Int(exactly: roundedDistance) else { return nil }
        return min(exactDistance, maximumConvergenceWrites)
    }

    private static func distance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(lhs - rhs)
    }

    private static func isSupportedTempoTarget(_ target: Double) -> Bool {
        guard target.isFinite, TransportDispatcher.supportedTempoRange.contains(target) else { return false }
        let multiplier = pow(10, Double(supportedTempoDecimalPlaces))
        let scaled = target * multiplier
        return scaled.isFinite && scaled.rounded(.toNearestOrAwayFromZero) == scaled
    }

    private static func crossedTarget(from current: Double, to next: Double, target: Double) -> Bool {
        (current < target && next > target) || (current > target && next < target)
    }

    private static func movesTowardTarget(from current: Double, to next: Double, target: Double) -> Bool {
        (current < target && next > current) || (current > target && next < current)
    }

    // MARK: - Locale and window resolution

    private static func requireMeasuredLocale(
        runtime: AXLogicProElements.Runtime,
        localeIdentifier: String?
    ) throws {
        let observed = localeIdentifier ?? AXLogicProElements.logicUILocaleIdentifier(runtime: runtime) ?? "unknown"
        guard observed == QualificationLocale.enUS.rawValue || observed == QualificationLocale.koKR.rawValue else {
            throw ReadRefusal.unmeasuredLocale(observed)
        }
    }

    private static func menuItemIsEnabled(_ item: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        let enabled: Bool? = AXHelpers.getAttribute(item, kAXEnabledAttribute, runtime: runtime)
        return enabled ?? false
    }

    private static func findTempoListWindow(
        runtime: AXLogicProElements.Runtime
    ) throws -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        guard let windows: [AXUIElement] = try attribute(
            app,
            kAXWindowsAttribute as String,
            site: "Tempo List window discovery AXWindows",
            runtime: runtime.ax
        ) else {
            return nil
        }
        var candidates: [AXUIElement] = []
        for window in windows {
            let tables: AXHelpers.Census
            switch AXHelpers.censusDescendantResult(
                of: window,
                role: kAXTableRole as String,
                maxDepth: 12,
                runtime: runtime.ax
            ) {
            case let .success(observed):
                tables = observed
            case let .failure(error):
                throw axReadFailed(site: "Tempo List window table census", status: error)
            }
            guard tables.candidates == 1 else { continue }

            let counts = try localizedCensus(
                of: window,
                labels: AXLocalePolicy.tempoListNumberOfItemsLabel,
                site: "Tempo List window item-count census",
                runtime: runtime.ax
            )
            guard counts.candidates == 1 else { continue }
            candidates.append(window)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
