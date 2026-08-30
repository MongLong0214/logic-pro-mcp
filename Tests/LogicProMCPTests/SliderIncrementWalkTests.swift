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

    @Test func displayTargetUsesRawChangeToContinueInTheObservedDirection() {
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

        // Mutation caught: using a guessed Hz mapping instead of the observed
        // raw direction sends the second request somewhere other than 104.
        #expect(outcome == .arrived(
            steps: 2,
            final: Reading(value: 107, display: "248 Hz")
        ))
        #expect(requestedRawValues == [101, 104])
    }

    @Test func unchangedDisplayCannotEstablishADirection() {
        var reads: [Reading?] = [
            Reading(value: 100, display: "100 Hz"),
            Reading(value: 101, display: "100 Hz"),
        ]
        var nudgeCalls = 0

        let outcome = SliderIncrementWalk.walk(
            to: .display("101 Hz"),
            read: { reads.removeFirst() },
            nudge: { _ in nudgeCalls += 1; return true },
            budget: 8
        )

        // Mutation caught: continuing after an unchanged rendering invents a
        // display-to-raw mapping the core does not have.
        #expect(outcome == .noProgress(
            steps: 1,
            last: Reading(value: 101, display: "100 Hz")
        ))
        #expect(nudgeCalls == 1)
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
}
