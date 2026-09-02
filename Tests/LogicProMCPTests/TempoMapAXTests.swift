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
        #expect(refusedOutcome.rollback == .notNeeded)
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
        #expect(refusedOutcome.rollback == .restored(writes: 1))
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
        #expect(refusedOutcome.rollback == .restored(writes: 1))
        #expect(fixture.currentTempo == 118)
        #expect(fixture.writeElementIDs.count == 3)
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
    }

    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let window: AXUIElement
    private let table: AXUIElement
    private let countText: AXUIElement
    private var steps: [Step]
    private var stepIndex = 0
    private var generation = 0
    private var activeTempoGroup: AXUIElement?
    private var staleTempoGroupIDs: Set<Int> = []
    private(set) var currentTempo: Double
    private(set) var writeElementIDs: [Int] = []
    private(set) var staleDescriptionReads = 0

    init(
        tempo: Double,
        reportedCountText: String = "1개의 이벤트",
        steps: [Step] = []
    ) {
        self.currentTempo = tempo
        self.steps = steps
        app = builder.element(90_000)
        window = builder.element(90_001)
        table = builder.element(90_002)
        countText = builder.element(90_003)

        builder.setAttribute(app, kAXWindowsAttribute as String, [window])
        builder.setAttribute(app, kAXMainWindowAttribute as String, window)
        builder.setRole(window, kAXWindowRole as String)
        builder.setRole(table, kAXTableRole as String)
        builder.setRole(countText, kAXStaticTextRole as String)
        builder.setAttribute(countText, kAXDescriptionAttribute as String, "항목 수")
        builder.setAttribute(countText, kAXValueAttribute as String, reportedCountText)
        builder.setChildren(window, [table, countText])
        renderCurrentRow()
    }

    func runtime() -> AXLogicProElements.Runtime {
        builder.makeLogicRuntime(
            appElement: app,
            attributeValueHandler: { [self] element, attribute in
                guard attribute == (kAXDescriptionAttribute as String),
                      staleTempoGroupIDs.contains(builder.elementID(element)) else {
                    return nil
                }
                staleDescriptionReads += 1
                // Handled nil: this is what a stale AXUIElement looks like after Logic re-renders.
                return .some(nil)
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
                }
                renderCurrentRow()
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
        activeTempoGroup = tempoGroup
    }
}
