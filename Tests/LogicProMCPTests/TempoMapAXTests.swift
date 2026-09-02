@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

@Suite("#304 measured Tempo List AX surface")
struct TempoMapAXTests {
    @Test("three AXCells publish position, numeric tempo, and SMPTE from their AXGroups")
    func tableWithThreeCellsParsesWholeGroupDescriptions() throws {
        let fixture = TempoListFixture(tempo: 120)

        let snapshot = try TempoMapAX.read(
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let event = try #require(snapshot.events.first)

        #expect(snapshot.reportedEventCount == 1)
        #expect(event.position == "1 1 1 1 ")
        #expect(event.tempo == 120)
        #expect(event.smpte == "01:00:00:00.00")
    }

    @Test("the item-count witness rejects a shorter Tempo List row collection")
    func eventCountDisagreementRefusesIncompleteRead() {
        let fixture = TempoListFixture(tempo: 120, reportedCountText: "2개의 이벤트")

        #expect(throws: TempoMapAX.ReadRefusal.incompleteRead(
            reportedEventCount: 2,
            observedRowCount: 1
        )) {
            _ = try TempoMapAX.read(
                in: fixture.window,
                localeIdentifier: "ko-KR",
                runtime: fixture.runtime()
            )
        }
    }

    @Test("one-BPM writes converge and report the actual number of writes")
    func writeConvergesInDistanceDerivedSteps() {
        let fixture = TempoListFixture(tempo: 118, steps: [.toward, .toward])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 120,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )

        #expect(outcome == .converged(initial: 118, observed: 120, writes: 2))
        #expect(fixture.currentTempo == 120)
        #expect(fixture.writeElementIDs.count == 2)
    }

    @Test("a write that does not move refuses and names the no-move observation")
    func writeThatDoesNotMoveRefuses() throws {
        let fixture = TempoListFixture(tempo: 118, steps: [.stuck])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 120,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .didNotMove(previous: 118, observed: 118, target: 120))
        #expect(refusedOutcome.failure.description.contains("did not move"))
        #expect(refusedOutcome.rollback == .notNeeded(writes: 0, finalObserved: 118))
    }

    @Test("a write that moves away from the target refuses")
    func writeThatMovesAwayRefuses() throws {
        let fixture = TempoListFixture(tempo: 118, steps: [.away, .toward])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 120,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .movedAway(previous: 118, observed: 117, target: 120))
        #expect(refusedOutcome.failure.description.contains("moved away"))
        #expect(refusedOutcome.rollback == .restored(writes: 1, finalObserved: 118))
        #expect(fixture.currentTempo == 118)
    }

    @Test("already-at-target is a distinguished zero-write success")
    func alreadyAtTargetDoesNotWrite() {
        let fixture = TempoListFixture(tempo: 120)

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 120,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )

        #expect(outcome == .alreadyAtTarget(observed: 120))
        #expect(fixture.writeElementIDs.isEmpty)
    }

    @Test("post-write readback re-finds a re-rendered group instead of reading stale nil")
    func staleElementReadIsNotTreatedAsChange() throws {
        let fixture = TempoListFixture(tempo: 118, steps: [.toward, .toward])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 120,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let firstWriteGroup = try #require(fixture.writeElementIDs.first)
        let lastWriteGroup = try #require(fixture.writeElementIDs.last)

        #expect(outcome == .converged(initial: 118, observed: 120, writes: 2))
        #expect(firstWriteGroup != lastWriteGroup)
        #expect(fixture.staleDescriptionReads == 0)
    }

    @Test("a locale outside the measured English/Korean pair refuses by its identifier")
    func unmeasuredLocaleRefuses() {
        let fixture = TempoListFixture(tempo: 120)

        #expect(throws: TempoMapAX.ReadRefusal.unmeasuredLocale("ja-JP")) {
            _ = try TempoMapAX.read(
                in: fixture.window,
                localeIdentifier: "ja-JP",
                runtime: fixture.runtime()
            )
        }
    }

    @Test("a partial forward walk restores through the same fresh convergence loop")
    func failedWriteRollsBackByConverging() throws {
        let fixture = TempoListFixture(tempo: 118, steps: [.toward, .stuck, .toward])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 121,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .didNotMove(previous: 119, observed: 119, target: 121))
        #expect(refusedOutcome.rollback == .restored(writes: 1, finalObserved: 118))
        #expect(fixture.currentTempo == 118)
        #expect(fixture.writeElementIDs.count == 3)
    }

    @Test("a competing unreadable table refuses instead of disappearing from write authority")
    func unreadableCompetingTableRefuses() {
        let fixture = TempoListFixture(tempo: 120, unreadableCompetingTable: true)
        let expected = TempoMapAX.ReadRefusal.axReadFailed(
            site: "Tempo List table census",
            status: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )

        #expect(throws: expected) {
            _ = try TempoMapAX.read(
                in: fixture.window,
                localeIdentifier: "ko-KR",
                runtime: fixture.runtime()
            )
        }
    }

    @Test("an unreadable competing window refuses instead of looking uniquely authorized")
    func unreadableCompetingWindowRefuses() {
        let fixture = TempoListFixture(tempo: 120, unreadableCompetingWindow: true)
        let expected = TempoMapAX.ReadRefusal.axReadFailed(
            site: "Tempo List window table census",
            status: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )

        #expect(throws: expected) {
            _ = try TempoMapAX.readOpenTempoList(
                runtime: fixture.runtime(),
                localeIdentifier: "ko-KR"
            )
        }
    }

    @Test("a non-absence AXRows status is named instead of becoming an empty row list")
    func unreadableRowsRefuseWithStatus() {
        let fixture = TempoListFixture(
            tempo: 120,
            axRowsReadFailures: [AXError.cannotComplete.rawValue]
        )
        let expected = TempoMapAX.ReadRefusal.axReadFailed(
            site: "Tempo List AXRows",
            status: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )

        #expect(throws: expected) {
            _ = try TempoMapAX.read(
                in: fixture.window,
                localeIdentifier: "ko-KR",
                runtime: fixture.runtime()
            )
        }
    }

    @Test("cell and count status failures stay visible to Tempo List write authority")
    func unreadableCellAndCountSitesRefuseWithStatus() {
        let checks: [(TempoListFixture.ReadFailureSite, String)] = [
            (.rowChildren, "row 0 AXCells"),
            (.tempoCellRole, "row 0 AXCells role"),
            (.tempoCellChildren, "row 0 cell 1 AXGroup"),
            (.tempoDescription, "row 0 cell 1 AXDescription"),
            (.itemCountValue, "Tempo List item-count AXValue"),
        ]

        for (failureSite, expectedSite) in checks {
            let fixture = TempoListFixture(tempo: 120, readFailureSite: failureSite)
            let expected = TempoMapAX.ReadRefusal.axReadFailed(
                site: expectedSite,
                status: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
            )

            #expect(throws: expected) {
                _ = try TempoMapAX.read(
                    in: fixture.window,
                    localeIdentifier: "ko-KR",
                    runtime: fixture.runtime()
                )
            }
        }
    }

    @Test("an unreadable competing count witness refuses even when one label matches")
    func unreadableCompetingCountWitnessRefuses() {
        let fixture = TempoListFixture(tempo: 120, unreadableCompetingCountWitness: true)
        let expected = TempoMapAX.ReadRefusal.axReadFailed(
            site: "Tempo List item-count census AXDescription",
            status: AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue)
        )

        #expect(throws: expected) {
            _ = try TempoMapAX.read(
                in: fixture.window,
                localeIdentifier: "ko-KR",
                runtime: fixture.runtime()
            )
        }
    }

    @Test("two agreeing but changing row/count witnesses refuse as unstable")
    func changingWitnessPairRefuses() {
        let fixture = TempoListFixture(
            tempo: 120,
            witnessPairs: [
                .init(rowVisible: false, reportedCountText: "0개의 이벤트"),
                .init(rowVisible: true, reportedCountText: "1개의 이벤트"),
            ]
        )
        let expected = TempoMapAX.ReadRefusal.inventoryUnstable(
            firstReportedEventCount: 0,
            firstObservedRowCount: 0,
            secondReportedEventCount: 1,
            secondObservedRowCount: 1
        )

        #expect(throws: expected) {
            _ = try TempoMapAX.read(
                in: fixture.window,
                localeIdentifier: "ko-KR",
                runtime: fixture.runtime()
            )
        }
    }

    @Test("integer Tempo List targets admit both documented domain endpoints")
    func documentedTempoEndpointsAreAccepted() {
        let lower = TempoListFixture(tempo: 6)
        let lowerOutcome = TempoMapAX.setExistingTempo(
            at: 0, to: 5, in: lower.window, localeIdentifier: "ko-KR", runtime: lower.runtime()
        )
        let upper = TempoListFixture(tempo: 998)
        let upperOutcome = TempoMapAX.setExistingTempo(
            at: 0, to: 999, in: upper.window, localeIdentifier: "ko-KR", runtime: upper.runtime()
        )

        #expect(lowerOutcome == .converged(initial: 6, observed: 5, writes: 1))
        #expect(upperOutcome == .converged(initial: 998, observed: 999, writes: 1))
    }

    @Test("out-of-range, fractional, and extreme targets refuse before any AX write")
    func unsupportedTargetsRefuse() throws {
        for target in [4.0, 1_000.0, 120.5, Double(Int.max)] {
            let fixture = TempoListFixture(tempo: 120)
            let outcome = TempoMapAX.setExistingTempo(
                at: 0,
                to: target,
                in: fixture.window,
                localeIdentifier: "ko-KR",
                runtime: fixture.runtime()
            )
            let refusedOutcome = try #require(refusal(from: outcome))

            #expect(refusedOutcome.failure == .invalidTarget(target))
            #expect(refusedOutcome.rollback == .notNeeded(writes: 0, finalObserved: nil))
            #expect(fixture.writeElementIDs.isEmpty)
        }
    }

    @Test("the practical write cap stops a long valid walk and reports the rollback receipt")
    func practicalWriteCapBoundsLongWalk() throws {
        let fixture = TempoListFixture(tempo: 5)
        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 999,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .attemptBudgetExhausted(observed: 69, target: 999, budget: 64))
        #expect(refusedOutcome.rollback == .restored(writes: 64, finalObserved: 5))
        #expect(fixture.currentTempo == 5)
    }

    @Test("a delayed Logic render settles before the write is judged")
    func delayedRenderSettlesBeforeJudgment() {
        let fixture = TempoListFixture(tempo: 118, postWriteRenderDelayAXRowsReads: 3)

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 119,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )

        #expect(outcome == .converged(initial: 118, observed: 119, writes: 1))
        #expect(fixture.currentTempo == 119)
    }

    @Test("an invalid element during post-write rebuild is re-read before judging")
    func rebuildingInvalidElementIsReread() {
        let fixture = TempoListFixture(
            tempo: 118,
            postWriteAXRowsReadFailures: [AXError.invalidUIElement.rawValue]
        )

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 119,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )

        #expect(outcome == .converged(initial: 118, observed: 119, writes: 1))
        #expect(fixture.currentTempo == 119)
    }

    @Test("an endlessly rebuilding row reaches the settle deadline instead of reading forever")
    func rebuildingRowDeadlineIsBounded() throws {
        let fixture = TempoListFixture(
            tempo: 118,
            postWriteAXRowsReadFailures: Array(repeating: AXError.invalidUIElement.rawValue, count: 100)
        )

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 119,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .deadlineExceeded(observed: 118, target: 119))
        #expect(refusedOutcome.rollback == .failed(
            failure: .readFailed(.axReadFailed(
                site: "Tempo List AXRows",
                status: AXHelpers.AXStatusError(raw: AXError.invalidUIElement.rawValue)
            )),
            writes: 0,
            finalObserved: 118
        ))
        #expect(fixture.writeElementIDs.count == 1)
    }

    @Test("a step that crosses the target refuses instead of becoming oscillating progress")
    func crossingTargetRefuses() throws {
        let fixture = TempoListFixture(tempo: 118, steps: [.crossing])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 120,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .crossedTarget(previous: 118, observed: 121, target: 120))
        #expect(refusedOutcome.rollback == .restored(writes: 3, finalObserved: 118))
        #expect(fixture.currentTempo == 118)
    }

    @Test("a rollback that drifts carries its write count and final observed tempo")
    func failedRollbackReportsPartialRestoreReceipt() throws {
        let fixture = TempoListFixture(tempo: 118, steps: [.toward, .stuck, .away])

        let outcome = TempoMapAX.setExistingTempo(
            at: 0,
            to: 121,
            in: fixture.window,
            localeIdentifier: "ko-KR",
            runtime: fixture.runtime()
        )
        let refusedOutcome = try #require(refusal(from: outcome))

        #expect(refusedOutcome.failure == .didNotMove(previous: 119, observed: 119, target: 121))
        #expect(refusedOutcome.rollback == .failed(
            failure: .movedAway(previous: 119, observed: 120, target: 118),
            writes: 1,
            finalObserved: 120
        ))
        #expect(fixture.currentTempo == 120)
    }

    private func refusal(
        from outcome: TempoMapAX.WriteOutcome
    ) -> (failure: TempoMapAX.WriteFailure, rollback: TempoMapAX.RollbackOutcome)? {
        guard case let .refused(failure, rollback) = outcome else { return nil }
        return (failure, rollback)
    }
}

/// A Tempo List AX fixture whose Tempo cell group is discarded after each write, exactly as Logic
/// re-renders it. A cached group both reads no AXDescription and refuses its next AXValue write;
/// a correct convergence loop must find the row/group anew from the window for every iteration.
private final class TempoListFixture: @unchecked Sendable {
    enum Step {
        case toward
        case stuck
        case away
        case crossing
    }

    enum ReadFailureSite {
        case rowChildren
        case tempoCellRole
        case tempoCellChildren
        case tempoDescription
        case itemCountValue
    }

    struct WitnessPair {
        let rowVisible: Bool
        let reportedCountText: String
    }

    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    private let table: AXUIElement
    private let countText: AXUIElement
    private let unreadableCompetingTable: AXUIElement?
    private let unreadableCompetingWindowTable: AXUIElement?
    private let unreadableCompetingCountWitness: AXUIElement?
    private var steps: [Step]
    private var stepIndex = 0
    private var generation = 0
    private var activeTempoGroup: AXUIElement?
    private var activeTempoCell: AXUIElement?
    private var activeRow: AXUIElement?
    private var staleTempoGroupIDs: Set<Int> = []
    private var axRowsReadFailures: [Int32]
    private let readFailureSite: ReadFailureSite?
    private var postWriteAXRowsReadFailures: [Int32]
    private let witnessPairs: [WitnessPair]
    private var witnessPairIndex = 0
    private let postWriteRenderDelayAXRowsReads: Int
    private var pendingRenderAXRowsReads = 0
    private var renderPending = false
    private(set) var currentTempo: Double
    private(set) var writeElementIDs: [Int] = []
    private(set) var staleDescriptionReads = 0

    init(
        tempo: Double,
        reportedCountText: String = "1개의 이벤트",
        steps: [Step] = [],
        unreadableCompetingTable: Bool = false,
        unreadableCompetingWindow: Bool = false,
        unreadableCompetingCountWitness: Bool = false,
        axRowsReadFailures: [Int32] = [],
        readFailureSite: ReadFailureSite? = nil,
        postWriteAXRowsReadFailures: [Int32] = [],
        witnessPairs: [WitnessPair] = [],
        postWriteRenderDelayAXRowsReads: Int = 0
    ) {
        self.currentTempo = tempo
        self.steps = steps
        self.axRowsReadFailures = axRowsReadFailures
        self.readFailureSite = readFailureSite
        self.postWriteAXRowsReadFailures = postWriteAXRowsReadFailures
        self.witnessPairs = witnessPairs
        self.postWriteRenderDelayAXRowsReads = postWriteRenderDelayAXRowsReads
        app = builder.element(90_000)
        window = builder.element(90_001)
        table = builder.element(90_002)
        countText = builder.element(90_003)
        self.unreadableCompetingTable = unreadableCompetingTable ? builder.element(90_004) : nil
        let competingWindow = unreadableCompetingWindow ? builder.element(90_005) : nil
        self.unreadableCompetingWindowTable = unreadableCompetingWindow ? builder.element(90_006) : nil
        self.unreadableCompetingCountWitness = unreadableCompetingCountWitness ? builder.element(90_007) : nil

        var windows = [window]
        if let competingWindow { windows.append(competingWindow) }
        builder.setAttribute(app, kAXWindowsAttribute as String, windows)
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setRole(window, kAXWindowRole as String)
        if let competingWindow {
            builder.setRole(competingWindow, kAXWindowRole as String)
            if let unreadableCompetingWindowTable {
                builder.setChildren(competingWindow, [unreadableCompetingWindowTable])
            }
        }
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(countText, kAXStaticTextRole as String)
        if let competingCountWitness = self.unreadableCompetingCountWitness {
            builder.setRole(competingCountWitness, kAXStaticTextRole as String)
        }
        builder.setAttribute(countText, kAXDescriptionAttribute as String, "항목 수")
        builder.setAttribute(countText, kAXValueAttribute as String, reportedCountText)
        var windowChildren = [table, countText]
        if let competingTable = self.unreadableCompetingTable { windowChildren.append(competingTable) }
        if let competingCountWitness = self.unreadableCompetingCountWitness {
            windowChildren.append(competingCountWitness)
        }
        builder.setChildren(window, windowChildren)
        renderCurrentRow()
    }

    func runtime() -> AXLogicProElements.Runtime {
        builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { [self] element, attribute in
                if attribute == "AXRows", CFEqual(element, table) {
                    advancePendingRenderIfNeeded()
                    if !witnessPairs.isEmpty {
                        let pair = witnessPairs[min(witnessPairIndex, witnessPairs.count - 1)]
                        let rows = pair.rowVisible ? activeRow.map { [$0] } ?? [] : []
                        return .some(rows as NSArray)
                    }
                }
                if attribute == (kAXValueAttribute as String), CFEqual(element, countText), !witnessPairs.isEmpty {
                    let pair = witnessPairs[min(witnessPairIndex, witnessPairs.count - 1)]
                    witnessPairIndex += 1
                    return .some(pair.reportedCountText as NSString)
                }
                guard attribute == (kAXDescriptionAttribute as String),
                      staleTempoGroupIDs.contains(builder.elementID(element)) else {
                    return nil
                }
                staleDescriptionReads += 1
                // Handled nil: this is what a stale AXUIElement looks like after Logic re-renders.
                return .some(nil)
            },
            attributeValueResultHandler: { [self] element, attribute in
                guard attribute == "AXRows", CFEqual(element, table) else {
                    if let readFailureSite,
                       shouldFail(attribute: attribute, on: element, at: readFailureSite) {
                        return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                    }
                    if attribute == (kAXRoleAttribute as String),
                       let unreadableCompetingTable,
                       CFEqual(element, unreadableCompetingTable) {
                        return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                    }
                    if attribute == (kAXRoleAttribute as String),
                       let unreadableCompetingWindowTable,
                       CFEqual(element, unreadableCompetingWindowTable) {
                        return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                    }
                    if attribute == (kAXDescriptionAttribute as String),
                       let unreadableCompetingCountWitness,
                       CFEqual(element, unreadableCompetingCountWitness) {
                        return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                    }
                    return nil
                }
                if !axRowsReadFailures.isEmpty {
                    return .failure(AXHelpers.AXStatusError(raw: axRowsReadFailures.removeFirst()))
                }
                if renderPending, !postWriteAXRowsReadFailures.isEmpty {
                    return .failure(AXHelpers.AXStatusError(raw: postWriteAXRowsReadFailures.removeFirst()))
                }
                return nil
            },
            childrenResultHandler: { [self] element in
                guard let readFailureSite else { return nil }
                // The table census must see the table but need not descend into its row. That
                // lets the test target the later, row-authorizing children/role read rather than
                // having the recursive table census encounter the same synthetic fault first.
                if CFEqual(element, table) { return .success([]) }
                if shouldFailChildren(of: element, at: readFailureSite) {
                    return .failure(AXHelpers.AXStatusError(raw: AXError.cannotComplete.rawValue))
                }
                return nil
            },
            setAttributeHandler: { [self] element, attribute, value in
                guard attribute == (kAXValueAttribute as String),
                      let activeTempoGroup,
                      CFEqual(element, activeTempoGroup),
                      let requested = value as? NSNumber else {
                    return false
                }
                writeElementIDs.append(builder.elementID(element))
                let step = stepIndex < steps.count ? steps[stepIndex] : .toward
                stepIndex += 1
                switch step {
                case .toward:
                    currentTempo += requested.doubleValue > currentTempo ? 1 : -1
                case .stuck:
                    break
                case .away:
                    currentTempo += requested.doubleValue > currentTempo ? -1 : 1
                case .crossing:
                    currentTempo = requested.doubleValue > currentTempo
                        ? requested.doubleValue + 1
                        : requested.doubleValue - 1
                }
                scheduleCurrentRowRender()
                return true
            },
            performActionHandler: nil
        )
    }

    private func renderCurrentRow() {
        if let activeTempoGroup {
            staleTempoGroupIDs.insert(builder.elementID(activeTempoGroup))
        }
        let base = 91_000 + generation * 10
        generation += 1
        let row = builder.element(base)
        let positionCell = builder.element(base + 1)
        let tempoCell = builder.element(base + 2)
        let smpteCell = builder.element(base + 3)
        let positionGroup = builder.element(base + 4)
        let tempoGroup = builder.element(base + 5)
        let smpteGroup = builder.element(base + 6)

        builder.setRole(row, kAXRowRole as String)
        for cell in [positionCell, tempoCell, smpteCell] {
            builder.setRole(cell, kAXCellRole as String)
        }
        for group in [positionGroup, tempoGroup, smpteGroup] {
            builder.setRole(group, kAXGroupRole as String)
        }
        builder.setAttribute(positionGroup, kAXDescriptionAttribute as String, "1 1 1 1 ")
        builder.setAttribute(tempoGroup, kAXDescriptionAttribute as String, String(format: "%.4f", currentTempo))
        builder.setAttribute(smpteGroup, kAXDescriptionAttribute as String, "01:00:00:00.00")
        builder.setChildren(positionCell, [positionGroup])
        builder.setChildren(tempoCell, [tempoGroup])
        builder.setChildren(smpteCell, [smpteGroup])
        builder.setChildren(row, [positionCell, tempoCell, smpteCell])
        builder.setChildren(table, [row])
        builder.setAttribute(table, "AXRows", [row])
        activeRow = row
        activeTempoCell = tempoCell
        activeTempoGroup = tempoGroup
    }

    private func shouldFail(
        attribute: String,
        on element: AXUIElement,
        at site: ReadFailureSite
    ) -> Bool {
        switch site {
        case .rowChildren:
            return false
        case .tempoCellRole:
            return attribute == (kAXRoleAttribute as String) && activeTempoCell.map { CFEqual(element, $0) } == true
        case .tempoCellChildren:
            return false
        case .tempoDescription:
            return attribute == (kAXDescriptionAttribute as String) && activeTempoGroup.map { CFEqual(element, $0) } == true
        case .itemCountValue:
            return attribute == (kAXValueAttribute as String) && CFEqual(element, countText)
        }
    }

    private func shouldFailChildren(of element: AXUIElement, at site: ReadFailureSite) -> Bool {
        switch site {
        case .rowChildren:
            activeRow.map { CFEqual(element, $0) } == true
        case .tempoCellChildren:
            activeTempoCell.map { CFEqual(element, $0) } == true
        case .tempoCellRole, .tempoDescription, .itemCountValue:
            false
        }
    }

    private func scheduleCurrentRowRender() {
        pendingRenderAXRowsReads = postWriteRenderDelayAXRowsReads
        renderPending = true
    }

    private func advancePendingRenderIfNeeded() {
        guard renderPending else { return }
        guard pendingRenderAXRowsReads == 0 else {
            pendingRenderAXRowsReads -= 1
            return
        }
        renderPending = false
        renderCurrentRow()
    }
}
