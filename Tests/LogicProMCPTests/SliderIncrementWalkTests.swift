import Testing
@testable import LogicProMCP

@Suite("Channel EQ slider increment walk")
struct SliderIncrementWalkTests {
    typealias Reading = SliderIncrementWalk.Reading

    @Test func alreadyAtRawTargetDoesNotNudge() {
        var nudgeCalls = 0
        let reading = Reading(value: 262, display: "+2.2 dB")

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(262, tolerance: 0),
            read: { reading },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: moving before checking entry readback corrupts an
        // already-correct control.
        #expect(outcome == .arrived(steps: 0, final: reading))
        #expect(nudgeCalls == 0)
    }

    @Test func alreadyAtDisplayTargetDoesNotNudge() {
        var nudgeCalls = 0
        let reading = Reading(value: 374, display: "248 Hz")

        let outcome = SliderIncrementWalk.walk(
            to: .display("248 Hz"),
            read: { reading },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: treating a display request as an engineering-value
        // conversion changes a control whose own rendering already matches.
        #expect(outcome == .arrived(steps: 0, final: reading))
        #expect(nudgeCalls == 0)
    }

    @Test func saturationReportsNoProgress() {
        var reads: [Reading?] = [
            Reading(value: 0, display: "20 Hz"),
            Reading(value: 0, display: "20 Hz"),
        ]
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(100, tolerance: 0),
            read: { reads.removeFirst() },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: treating a rail as progress loops until the budget.
        #expect(outcome == .noProgress(
            steps: 1,
            last: Reading(value: 0, display: "20 Hz")
        ))
        #expect(nudgeCalls == 1)
    }

    @Test func outOfRangeRawTargetIsNotClampedBeforeSaturation() {
        let maximum = Reading(value: 1_050, display: "20000 Hz")
        var requestedRawValues: [Double] = []

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(2_000, tolerance: 0),
            read: { maximum },
            nudge: { requestedRawValues.append($0); return true },
            budget: 8
        )

        // Mutation caught: clamping 2,000 to a presumed maximum fabricates an
        // arrival instead of reporting the actual rail as no progress.
        #expect(outcome == .noProgress(steps: 1, last: maximum))
        #expect(requestedRawValues == [2_000])
    }

    @Test func rejectedNudgeStopsImmediately() {
        let initial = Reading(value: 100, display: "100 Hz")
        var nudgeCalls = 0
        var reads = 0

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(200, tolerance: 0),
            read: { reads += 1; return initial },
            nudge: { _ in nudgeCalls += 1; return false },
            budget: 8
        )

        // Mutation caught: ignoring a rejected write keeps issuing unaccepted
        // AX requests.
        #expect(outcome == .noProgress(steps: 0, last: initial))
        #expect(nudgeCalls == 1)
        #expect(reads == 1)
    }

    @Test func missingMidWalkReadbackIsReported() {
        var reads: [Reading?] = [Reading(value: 100, display: "100 Hz"), nil]
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(200, tolerance: 0),
            read: { reads.removeFirst() },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: reading nil as an unchanged value falsely calls an
        // accessibility outage a saturated control.
        #expect(outcome == .readbackLost(steps: 1))
        #expect(nudgeCalls == 1)
    }

    @Test func missingEntryReadbackIsReported() {
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(200, tolerance: 0),
            read: { nil },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: turning an absent initial readback into a default
        // value lets the core author a write without a control observation.
        #expect(outcome == .readbackLost(steps: 0))
        #expect(nudgeCalls == 0)
    }

    @Test func twoValueOscillationReportsNoProgress() {
        var reads: [Reading?] = [
            Reading(value: 0, display: "20 Hz"),
            Reading(value: 3, display: "23 Hz"),
            Reading(value: 0, display: "20 Hz"),
        ]

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(10, tolerance: 0),
            read: { reads.removeFirst() },
            nudge: { _ in true },
            budget: 8
        )

        // Mutation caught: forgetting the a→b→a detector makes a bouncing
        // control consume the whole write budget.
        #expect(outcome == .noProgress(
            steps: 2,
            last: Reading(value: 0, display: "20 Hz")
        ))
    }

    @Test func movementFartherAwayAfterCrossingReportsOvershot() {
        var reads: [Reading?] = [
            Reading(value: 4, display: "4"),
            Reading(value: 7, display: "7"),
            Reading(value: 8, display: "8"),
        ]

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(5, tolerance: 0),
            read: { reads.removeFirst() },
            nudge: { _ in true },
            budget: 8
        )

        // Mutation caught: accepting a second move away after crossing loses
        // the fact that the walk can no longer be trusted to return.
        #expect(outcome == .overshot(
            steps: 2,
            last: Reading(value: 8, display: "8")
        ))
    }

    @Test func budgetIsAnExactNudgeLimit() {
        var reads: [Reading?] = [
            Reading(value: 0, display: "0"),
            Reading(value: 4, display: "4"),
            Reading(value: 8, display: "8"),
        ]
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(20, tolerance: 0),
            read: { reads.removeFirst() },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 2
        )

        // Mutation caught: a <= loop condition performs one more write than
        // the caller authorized.
        #expect(outcome == .budgetExhausted(
            steps: 2,
            last: Reading(value: 8, display: "8")
        ))
        #expect(nudgeCalls == 2)
    }

    @Test func largeReadbackStepsStillArrive() {
        var reads: [Reading?] = [
            Reading(value: 0, display: "20 Hz"),
            Reading(value: 7, display: "28 Hz"),
            Reading(value: 10, display: "31 Hz"),
        ]

        let outcome = SliderIncrementWalk.walk(
            to: .rawValue(10, tolerance: 0),
            read: { reads.removeFirst() },
            nudge: { _ in true },
            budget: 3
        )

        // Mutation caught: assuming every accepted AX nudge moves exactly one
        // raw unit rejects a valid larger readback jump.
        #expect(outcome == .arrived(
            steps: 2,
            final: Reading(value: 10, display: "31 Hz")
        ))
    }

    @Test func displayTargetAboveStartArrivesAfterProbeMovesToward() {
        var reads: [Reading?] = [
            Reading(value: 100, display: "100 Hz"),
            Reading(value: 103, display: "200 Hz"),
            Reading(value: 107, display: "248 Hz"),
        ]
        var requestedRawValues: [Double] = []

        let outcome = SliderIncrementWalk.walk(
            to: .display("248 Hz"),
            read: { reads.removeFirst() },
            nudge: { requestedRawValues.append($0); return true },
            budget: 3
        )

        // Mutation caught: choosing a direction from an invented Hz mapping
        // instead of Logic's rendered ordering sends the second request
        // somewhere other than 104.
        #expect(outcome == .arrived(
            steps: 2,
            final: Reading(value: 107, display: "248 Hz")
        ))
        #expect(requestedRawValues == [101, 104])
    }

    @Test func aDisplayThatStopsChangingWhileTheValueMovesCostsTheBudget() {
        // THIS CASE'S RULE WAS DELIBERATELY NARROWED (#292) and the trade is stated rather than
        // hidden. It used to assert that an unchanged rendering is terminal, with the note
        // "continuing after an unchanged rendering turns a saturated or stalled display into a
        // budget-exhaustion walk" — which is exactly what now happens, and is the price.
        //
        // What it bought: Channel EQ's Q renders two decimals over increments finer than that, so a
        // REAL step reads back the same string. Under the old rule Q landed nothing on any band in
        // either direction, dying at step 1 every time. A control that moved is not a control that
        // did not.
        //
        // The failure is still a failure — `budgetExhausted` rolls back exactly as `noProgress`
        // does — and it costs the caller's own budget, which is the number they can change. The
        // case that still stops immediately is the rail, and `aRailIsStillARail` pins it.
        var current = 100.0
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .display("101 Hz"),
            read: { Reading(value: current, display: "100 Hz") },
            nudge: { requested in
                nudgeCalls += 1
                current += requested > current ? 1 : -1
                return true
            },
            budget: 8
        )

        // Mutation caught: making an unchanged rendering terminal again returns noProgress at step
        // 1 and Q becomes unreachable; making a rail non-terminal walks into the end stop forever.
        // 108, not 96: the target renders `101 Hz` against a current `100 Hz`, so the walk reads the
        // target as ABOVE and steps up. The raw value is what moves; the rendering never does.
        #expect(outcome == .budgetExhausted(steps: 8, last: Reading(value: 108, display: "100 Hz")))
        #expect(nudgeCalls == 8)
    }

    @Test func aStepTooSmallToSeeIsStillAStep() {
        // #292: Channel EQ's Q renders two decimals while one increment moves less than that, so a
        // real step reads back the same string. The walk used to call that terminal no-progress and
        // Q landed nothing on any band in either direction, dying at step 1 every time.
        //
        // The raw value is what says whether the control moved. Here one increment is a hundredth
        // of a display unit, so ten steps are needed before the rendering changes at all.
        var current = 100.0
        let read: () -> Reading? = {
            Reading(value: current, display: String(format: "%.2f", ((current / 1000) * 100).rounded() / 100))
        }
        let nudge: (Double) -> Bool = { requested in current += requested > current ? 1 : -1; return true }

        let outcome = SliderIncrementWalk.walk(
            to: .display("0.15"), read: read, nudge: nudge, budget: 128
        )

        // Mutation caught: restore `next.display == current.display` as terminal and this returns
        // noProgress at step 1 — exactly what Q does live.
        guard case let .arrived(_, final) = outcome else {
            Issue.record("expected to arrive, got \(outcome)")
            return
        }
        #expect(final.display == "0.15")
    }

    @Test func aRailIsStillARail() {
        // The clause above must keep doing the job it was written for. When neither the rendering
        // NOR the raw value moves, the control is against its end stop and continuing would be a
        // walk into a wall. This is the case that proves the fix narrowed the rule instead of
        // deleting it.
        let stuck = Reading(value: 480, display: "+24.0 dB")
        let outcome = SliderIncrementWalk.walk(
            to: .display("+30.0 dB"),
            read: { stuck },
            nudge: { _ in true },
            budget: 16
        )
        #expect(outcome == .noProgress(steps: 1, last: stuck))
    }

    @Test func displayTargetBelowStartReversesAndArrivesNearRawDistance() {
        var value = 302.0
        var nudgeCalls = 0

        func reading() -> Reading {
            Reading(value: value, display: "+\((value - 240) / 10) dB")
        }

        let outcome = SliderIncrementWalk.walk(
            to: .display("+2.2 dB"),
            read: { reading() },
            nudge: { requestedRaw in
                nudgeCalls += 1
                value += requestedRaw > value ? 1 : -1
                return true
            },
            budget: 64
        )

        // A +1 probe costs two extra accepted steps (up, then back down), but
        // must not repeat the measured 302 -> 480 wrong-way rail walk.
        #expect(outcome == .arrived(
            steps: 42,
            final: Reading(value: 262, display: "+2.2 dB")
        ))
        #expect(nudgeCalls == 42)
    }

    @Test func probeThatMovesAwayReversesAndArrives() {
        var reads: [Reading?] = [
            Reading(value: 100, display: "+4.0 dB"),
            Reading(value: 101, display: "+4.1 dB"),
            Reading(value: 100, display: "+4.0 dB"),
            Reading(value: 99, display: "+3.8 dB"),
        ]
        var requestedRawValues: [Double] = []

        let outcome = SliderIncrementWalk.walk(
            to: .display("+3.8 dB"),
            read: { reads.removeFirst() },
            nudge: { requestedRaw in requestedRawValues.append(requestedRaw); return true },
            budget: 4
        )

        // Mutation caught: retaining the upward probe direction never lets
        // the walk return toward a lower rendered target.
        #expect(outcome == .arrived(
            steps: 3,
            final: Reading(value: 99, display: "+3.8 dB")
        ))
        #expect(requestedRawValues == [101, 100, 99])
    }

    @Test func displayUnitTextMismatchReportsNoProgress() {
        var reads: [Reading?] = [
            Reading(value: 100, display: "+2.2 dB"),
            Reading(value: 101, display: "2.2"),
        ]

        let outcome = SliderIncrementWalk.walk(
            to: .display("+2.1 dB"),
            read: { reads.removeFirst() },
            nudge: { _ in true },
            budget: 8
        )

        // Mutation caught: matching only the number treats a unit-less
        // rendering as though it shared the target's dB ordering.
        #expect(outcome == .noProgress(
            steps: 1,
            last: Reading(value: 101, display: "2.2")
        ))
    }

    @Test func nonNumericDisplayReportsNoProgress() {
        var reads: [Reading?] = [
            Reading(value: 100, display: "Bypassed"),
            Reading(value: 101, display: "Active"),
        ]

        let outcome = SliderIncrementWalk.walk(
            to: .display("Enabled"),
            read: { reads.removeFirst() },
            nudge: { _ in true },
            budget: 8
        )

        // Mutation caught: an unordered rendering is not evidence that an
        // arbitrary raw direction can reach the requested text.
        #expect(outcome == .noProgress(
            steps: 1,
            last: Reading(value: 101, display: "Active")
        ))
    }

    @Test func displayRailReportsNoProgressInsteadOfBudgetExhaustion() {
        let rail = Reading(value: 480, display: "+24.0 dB")
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .display("+24.1 dB"),
            read: { rail },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: a probe blocked by a real control rail must not
        // consume the caller's entire budget.
        #expect(outcome == .noProgress(steps: 1, last: rail))
        #expect(nudgeCalls == 1)
    }

    @Test func displayBudgetIsAnExactNudgeLimit() {
        var reads: [Reading?] = [
            Reading(value: 100, display: "1.0"),
            Reading(value: 101, display: "1.1"),
            Reading(value: 102, display: "1.2"),
        ]
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .display("1.4"),
            read: { reads.removeFirst() },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 2
        )

        // Mutation caught: a display walk must honor the same accepted-write
        // budget boundary as a raw-value walk.
        #expect(outcome == .budgetExhausted(
            steps: 2,
            last: Reading(value: 102, display: "1.2")
        ))
        #expect(nudgeCalls == 2)
    }

    @Test func nonPositiveBudgetNeverNudges() {
        let initial = Reading(value: 100, display: "100 Hz")

        for budget in [0, -1] {
            var nudgeCalls = 0
            let outcome = SliderIncrementWalk.walk(
                to: .rawValue(200, tolerance: 0),
                read: { initial },
                nudge: { _ in nudgeCalls += 1; return true },
                budget: budget
            )

            // Mutation caught: entering the write loop before validating the
            // budget performs a mutation a zero-budget caller prohibited.
            #expect(outcome == .budgetExhausted(steps: 0, last: initial))
            #expect(nudgeCalls == 0)
        }
    }

    // MARK: - #292: the same reading, rendered two ways

    /// A Channel EQ gain slider as Logic actually renders it: ALWAYS one decimal, signed.
    /// One raw unit is 0.1 dB, measured (raw 302 = `+6.2 dB`, raw 480 = `+24.0 dB`).
    private func gainSlider(startingAt raw: Double) -> (read: () -> Reading?, nudge: (Double) -> Bool) {
        var current = raw
        let render: (Double) -> String = { value in
            let dB = (value / 10 * 10).rounded() / 10
            return dB >= 0 ? String(format: "+%.1f dB", dB) : String(format: "%.1f dB", dB)
        }
        return ({ Reading(value: current, display: render(current)) },
                { requested in current += requested > current ? 1 : -1; return true })
    }

    @Test func aWholeNumberDecibelTargetIsTheSameReadingLogicRendersWithADecimal() {
        // #292, measured live 2026-09-12: every half-dB request landed and every WHOLE-dB request
        // failed `increment_walk_no_progress` — `-5.5` arrived in 82 steps, `-5.0` died in 6 from a
        // start five steps away. The walk reaches the value and does not recognise it.
        //
        // `displayTargetValueText` renders -5.0 as `-5`, because dropping a trailing `.0` is right
        // for Hz (`400 Hz`) and wrong for dB, where Logic always shows the decimal. One formatting
        // rule for every unit is the defect; `-5 dB` and `-5.0 dB` are the same reading.
        let slider = gainSlider(startingAt: -45)   // -4.5 dB, five steps above the target
        let outcome = SliderIncrementWalk.walk(
            to: .display("-5 dB"),
            read: slider.read,
            nudge: slider.nudge,
            budget: 64
        )

        // Mutation caught: comparing renderings as strings instead of as the readings they name.
        // Restore the exact-string compare and this walk sails past -5.0 dB and reports no progress.
        guard case let .arrived(steps, final) = outcome else {
            Issue.record("expected to arrive, got \(outcome)")
            return
        }
        // Seven, not five: the walk opens with an UPWARD calibration probe, sees the rendering
        // move away from the target, and flips once — so a five-step descent costs two extra.
        // That probe is deliberate (`walkDisplay` says so) and is not what this case is about.
        #expect(steps == 7)
        #expect(final.display == "-5.0 dB")
    }

    @Test func aTargetRenderedWithMoreDecimalsThanTheRequestIsStillTheSameReading() {
        // The same defect, from the other direction, and the reason Q lands NOTHING on any band:
        // a request of `1.5` never matches a control Logic renders `1.50`.
        var current = 140.0
        let read: () -> Reading? = { Reading(value: current, display: String(format: "%.2f", current / 100)) }
        let nudge: (Double) -> Bool = { requested in current += requested > current ? 1 : -1; return true }

        let outcome = SliderIncrementWalk.walk(
            to: .display("1.5"), read: read, nudge: nudge, budget: 64
        )

        guard case let .arrived(_, final) = outcome else {
            Issue.record("expected to arrive, got \(outcome)")
            return
        }
        #expect(final.display == "1.50")
    }

    @Test func aDifferentUnitIsNotTheSameReadingHoweverEqualTheNumbers() {
        // The comparison must stay a comparison. `400 Hz` and `400 dB` share a number and name
        // different readings; a numeric compare that ignored the unit would accept either.
        let reading = Reading(value: 10, display: "400 Hz")
        let outcome = SliderIncrementWalk.walk(
            to: .display("400 dB"),
            read: { reading },
            nudge: { _ in true },
            budget: 0
        )

        #expect(outcome == .budgetExhausted(steps: 0, last: reading))
    }

    @Test func aRenderingWithNoNumberFallsBackToTheStringItIs() {
        // Not every display carries a number — `Off`, `Auto`, `-∞ dB`. Those can only be compared
        // as strings, and equal strings must still arrive.
        let reading = Reading(value: 0, display: "Off")
        let outcome = SliderIncrementWalk.walk(
            to: .display("Off"), read: { reading }, nudge: { _ in true }, budget: 4
        )
        #expect(outcome == .arrived(steps: 0, final: reading))
    }

    @Test func theExactLiveWalkThatFailedIsReproducedFromItsOwnNumbers() {
        // The failing live call, rebuilt from the envelope it returned: start raw 315 (`rollback_to`),
        // target `-5 dB`, and Logic's measured rendering — raw 190 reads `-5.0 dB`, 189 reads
        // `-5.1 dB`, 195 reads `-4.5 dB`, all four read back through the product on 2026-09-12.
        // If this arrives while the live call reports `noProgress` at 128 steps, the divergence is
        // not in this algorithm.
        var current = 315.0
        let render: (Double) -> String = { raw in
            let dB = ((raw / 10) - 24 + 0.0).rounded(.toNearestOrEven)
            _ = dB
            let exact = (raw / 10) - 24
            let scaled = (exact * 10).rounded() / 10
            return scaled >= 0 ? String(format: "+%.1f dB", scaled) : String(format: "%.1f dB", scaled)
        }
        let outcome = SliderIncrementWalk.walk(
            to: .display("-5 dB"),
            read: { Reading(value: current, display: render(current)) },
            nudge: { requested in current += requested > current ? 1 : -1; return true },
            budget: 256
        )
        guard case let .arrived(steps, final) = outcome else {
            Issue.record("expected to arrive, got \(outcome)")
            return
        }
        #expect(final.display == "-5.0 dB")
        #expect(steps == 127)
    }
}
