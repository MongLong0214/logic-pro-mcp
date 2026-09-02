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

    /// A complete Tempo List reading. `reportedEventCount` comes from the `Number of Items` /
    /// `항목 수` AXStaticText, while `events` comes from the table's AXRows. Construction is private
    /// to `read`, which refuses if those two independent counts disagree.
    struct Snapshot: Codable, Equatable, Sendable {
        let reportedEventCount: Int
        let events: [Event]
    }

    enum ReadRefusal: Error, Equatable, Sendable, CustomStringConvertible {
        case unmeasuredLocale(String)
        case tempoListWindowUnavailable
        case tempoListMenuUnavailable
        case tempoListMenuDisabled
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
            }
        }
    }

    enum WriteFailure: Equatable, Sendable, CustomStringConvertible {
        case invalidTarget(Double)
        case eventIndexOutOfRange(index: Int, count: Int)
        case positionChanged(expected: String, observed: String)
        case axWriteFailed
        case readFailed(ReadRefusal)
        case didNotMove(previous: Double, observed: Double, target: Double)
        case movedAway(previous: Double, observed: Double, target: Double)
        case attemptBudgetExhausted(observed: Double, target: Double, budget: Int)

        var description: String {
            switch self {
            case let .invalidTarget(target):
                return "Tempo target \(target) is not a finite positive number or a representable bounded walk."
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
            case let .attemptBudgetExhausted(observed, target, budget):
                return "Tempo write spent its distance-derived budget of \(budget) step(s) and stopped at \(observed), not \(target)."
            }
        }
    }

    enum RollbackOutcome: Equatable, Sendable {
        /// No forward value differed from the original tempo, so no restore write was needed.
        case notNeeded
        /// The same fresh-read, monotonic walk reached the original tempo.
        case restored(writes: Int)
        /// The restore stopped safely. No further writes are attempted: the receipt carries the
        /// restore failure so the caller knows the project may still hold a partial forward value.
        case failed(WriteFailure)
    }

    enum WriteOutcome: Equatable, Sendable {
        /// A successful no-op. This is deliberately different from `.converged(writes: 0)` so a
        /// caller can tell that no AX mutation was attempted because the event was already correct.
        case alreadyAtTarget(observed: Double)
        case converged(initial: Double, observed: Double, writes: Int)
        case refused(failure: WriteFailure, rollback: RollbackOutcome)
    }

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
        guard let window = findTempoListWindow(runtime: runtime) else {
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
        guard let window = findTempoListWindow(runtime: runtime) else {
            throw ReadRefusal.tempoListWindowUnavailable
        }
        return try inventory(in: window, runtime: runtime.ax).snapshot
    }

    /// Sets one existing event by row index and verifies the result.
    ///
    /// Logic 12.3's Tempo List accepts an AXValue write but advances exactly one BPM toward the
    /// requested number per write. Therefore `attemptBudget` is `ceil(abs(target - initial))`,
    /// derived from the measured distance rather than a fixed retry count. Every loop observation
    /// starts again from `window`; it never reads a cached row/group after Logic has re-rendered it.
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
            return .refused(failure: .readFailed(refusal), rollback: .notNeeded)
        } catch {
            return .refused(
                failure: .readFailed(.unmeasuredLocale(localeIdentifier ?? "unknown")),
                rollback: .notNeeded
            )
        }

        guard target.isFinite, target > 0 else {
            return .refused(failure: .invalidTarget(target), rollback: .notNeeded)
        }

        let initial: Event
        do {
            let snapshot = try read(in: window, localeIdentifier: localeIdentifier, runtime: runtime)
            guard snapshot.events.indices.contains(index) else {
                return .refused(
                    failure: .eventIndexOutOfRange(index: index, count: snapshot.events.count),
                    rollback: .notNeeded
                )
            }
            initial = snapshot.events[index]
        } catch let refusal as ReadRefusal {
            return .refused(failure: .readFailed(refusal), rollback: .notNeeded)
        } catch {
            return .refused(
                failure: .readFailed(.tempoListWindowUnavailable),
                rollback: .notNeeded
            )
        }

        guard initial.tempo != target else {
            return .alreadyAtTarget(observed: initial.tempo)
        }

        // A finite positive target can still be too far away to express a bounded loop on this
        // platform. Refuse it before `attemptBudget` would be unable to represent the distance.
        guard distance(initial.tempo, target) <= Double(Int.max) else {
            return .refused(failure: .invalidTarget(target), rollback: .notNeeded)
        }

        let forward = converge(
            at: index,
            from: initial,
            to: target,
            in: window,
            localeIdentifier: localeIdentifier,
            runtime: runtime
        )
        switch forward {
        case let .success(observed, writes):
            return .converged(initial: initial.tempo, observed: observed, writes: writes)
        case let .failure(failure, writes):
            let rollback: RollbackOutcome
            if writes == 0 {
                rollback = .notNeeded
            } else {
                rollback = rollbackToInitialTempo(
                    at: index,
                    initial: initial,
                    in: window,
                    localeIdentifier: localeIdentifier,
                    runtime: runtime
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
        let table = try tempoListTable(in: window, runtime: runtime)
        let rows = try tempoListRows(in: table, runtime: runtime)
        let count = try itemCount(in: window, runtime: runtime)

        var events: [Event] = []
        var tempoGroups: [AXUIElement] = []
        events.reserveCapacity(rows.count)
        tempoGroups.reserveCapacity(rows.count)

        for (rowIndex, row) in rows.enumerated() {
            let cells = AXHelpers.getChildren(row, runtime: runtime).filter {
                AXHelpers.getRole($0, runtime: runtime) == (kAXCellRole as String)
            }
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
                  tempo > 0 else {
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
        let census = AXHelpers.censusDescendant(
            of: window,
            role: kAXTableRole as String,
            maxDepth: 12,
            runtime: runtime
        )
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
        guard let rows: [AXUIElement] = AXHelpers.getAttribute(table, "AXRows", runtime: runtime) else {
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
        let groups = AXHelpers.getChildren(cell, runtime: runtime).filter {
            AXHelpers.getRole($0, runtime: runtime) == (kAXGroupRole as String)
        }
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
        guard let description: String = AXHelpers.getAttribute(
            group,
            kAXDescriptionAttribute,
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
        let census = AXLocalePolicy.censusDescendant(
            of: window,
            role: kAXStaticTextRole as String,
            matching: AXLocalePolicy.tempoListNumberOfItemsLabel,
            mode: .exactStrict,
            maxDepth: 12,
            runtime: runtime
        )
        guard census.candidates == 1,
              let text = census.element,
              AXLocalePolicy.tempoListNumberOfItemsLabel.matches(
                AXHelpers.getDescription(text, runtime: runtime),
                mode: .exactStrict
              ) else {
            throw ReadRefusal.itemCountMissing
        }
        guard let value: String = AXHelpers.getAttribute(text, kAXValueAttribute, runtime: runtime) else {
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

    // MARK: - Convergence and rollback

    private enum Convergence {
        case success(observed: Double, writes: Int)
        case failure(WriteFailure, writes: Int)
    }

    private static func converge(
        at index: Int,
        from initial: Event,
        to target: Double,
        in window: AXUIElement,
        localeIdentifier: String?,
        runtime: AXLogicProElements.Runtime
    ) -> Convergence {
        let budget = attemptBudget(from: initial.tempo, to: target)
        var current = initial
        var writes = 0

        for _ in 0..<budget {
            // Resolve the table, row, and value group anew immediately before every write. This is
            // not an optimization opportunity: the prior group's AXDescription can become nil when
            // Logic re-renders the row, and nil is not an observation that the value changed.
            let fresh: Inventory
            do {
                fresh = try inventory(in: window, runtime: runtime.ax)
            } catch let refusal as ReadRefusal {
                return .failure(.readFailed(refusal), writes: writes)
            } catch {
                return .failure(.readFailed(.tempoListWindowUnavailable), writes: writes)
            }
            guard fresh.snapshot.events.indices.contains(index) else {
                return .failure(
                    .eventIndexOutOfRange(index: index, count: fresh.snapshot.events.count),
                    writes: writes
                )
            }
            let freshEvent = fresh.snapshot.events[index]
            guard freshEvent.position == initial.position else {
                return .failure(
                    .positionChanged(expected: initial.position, observed: freshEvent.position),
                    writes: writes
                )
            }
            current = freshEvent

            guard AXHelpers.setAttribute(
                fresh.tempoGroups[index],
                kAXValueAttribute,
                NSNumber(value: target),
                runtime: runtime.ax
            ) else {
                return .failure(.axWriteFailed, writes: writes)
            }
            writes += 1

            // Re-enter through `read`, which resolves from `window` and deliberately retains no
            // reference from `fresh`. Reading `nil` off fresh.tempoGroups[index] here would be a
            // stale-element failure, not readback.
            let reread: Snapshot
            do {
                reread = try read(
                    in: window,
                    localeIdentifier: localeIdentifier,
                    runtime: runtime
                )
            } catch let refusal as ReadRefusal {
                return .failure(.readFailed(refusal), writes: writes)
            } catch {
                return .failure(.readFailed(.tempoListWindowUnavailable), writes: writes)
            }
            guard reread.events.indices.contains(index) else {
                return .failure(
                    .eventIndexOutOfRange(index: index, count: reread.events.count),
                    writes: writes
                )
            }
            let next = reread.events[index]
            guard next.position == initial.position else {
                return .failure(
                    .positionChanged(expected: initial.position, observed: next.position),
                    writes: writes
                )
            }
            if next.tempo == target {
                return .success(observed: next.tempo, writes: writes)
            }
            if next.tempo == current.tempo {
                return .failure(
                    .didNotMove(previous: current.tempo, observed: next.tempo, target: target),
                    writes: writes
                )
            }
            guard distance(next.tempo, target) < distance(current.tempo, target) else {
                return .failure(
                    .movedAway(previous: current.tempo, observed: next.tempo, target: target),
                    writes: writes
                )
            }
            current = next
        }

        return .failure(
            .attemptBudgetExhausted(observed: current.tempo, target: target, budget: budget),
            writes: writes
        )
    }

    private static func rollbackToInitialTempo(
        at index: Int,
        initial: Event,
        in window: AXUIElement,
        localeIdentifier: String?,
        runtime: AXLogicProElements.Runtime
    ) -> RollbackOutcome {
        let current: Event
        do {
            let snapshot = try read(
                in: window,
                localeIdentifier: localeIdentifier,
                runtime: runtime
            )
            guard snapshot.events.indices.contains(index) else {
                return .failed(.eventIndexOutOfRange(index: index, count: snapshot.events.count))
            }
            current = snapshot.events[index]
        } catch let refusal as ReadRefusal {
            return .failed(.readFailed(refusal))
        } catch {
            return .failed(.readFailed(.tempoListWindowUnavailable))
        }

        guard current.position == initial.position else {
            return .failed(.positionChanged(expected: initial.position, observed: current.position))
        }
        guard current.tempo != initial.tempo else { return .notNeeded }

        switch converge(
            at: index,
            from: current,
            to: initial.tempo,
            in: window,
            localeIdentifier: localeIdentifier,
            runtime: runtime
        ) {
        case let .success(_, writes):
            return .restored(writes: writes)
        case let .failure(failure, _):
            return .failed(failure)
        }
    }

    /// The measured AXValue setter moves exactly one BPM toward the target. `ceil(distance)` is
    /// therefore the finite upper bound for a well-behaved walk; it is never a magic retry count.
    private static func attemptBudget(from current: Double, to target: Double) -> Int {
        let distance = distance(current, target)
        precondition(distance.isFinite && distance > 0)
        precondition(distance <= Double(Int.max))
        return Int(distance.rounded(.up))
    }

    private static func distance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(lhs - rhs)
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
    ) -> AXUIElement? {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return nil }
        let windows: [AXUIElement] = AXHelpers.getAttribute(
            app,
            kAXWindowsAttribute,
            runtime: runtime.ax
        ) ?? []
        let candidates = windows.filter { window in
            let tables = AXHelpers.findAllDescendants(
                of: window,
                role: kAXTableRole as String,
                maxDepth: 12,
                runtime: runtime.ax
            )
            guard tables.count == 1 else { return false }
            let counts = AXHelpers.findAllDescendants(
                of: window,
                role: kAXStaticTextRole as String,
                maxDepth: 12,
                runtime: runtime.ax
            ).filter {
                AXLocalePolicy.tempoListNumberOfItemsLabel.matches(
                    AXHelpers.getDescription($0, runtime: runtime.ax),
                    mode: .exactStrict
                )
            }
            return counts.count == 1
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
