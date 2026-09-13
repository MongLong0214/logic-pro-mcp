/// A readback-driven walk for sliders whose apparent value assignment is only
/// a one-step nudge toward the requested raw value.
///
/// This deliberately has no Accessibility import. The caller owns AX reads and
/// writes; the core only decides whether those observations justify another
/// nudge. Channel EQ needs this because assigning `AXValue` is not a set to a
/// destination: the reported Logic 12.x measurement is that each assignment
/// advances one step toward the requested raw value.
enum SliderIncrementWalk {
    struct Reading: Equatable, Sendable {
        /// The raw `AXValue`, never an inferred engineering value.
        let value: Double
        /// Logic's own `AXValueDescription` rendering.
        let display: String
    }

    enum Target: Equatable, Sendable {
        /// Converge on a raw `AXValue`. The tolerance is in raw slider units.
        case rawValue(Double, tolerance: Double)
        /// Converge only when Logic renders this exact `AXValueDescription`.
        /// This is the honest mode for values such as Hz and dB, whose raw
        /// mappings must not be invented by this core.
        case display(String)
    }

    enum WalkOutcome: Equatable, Sendable {
        case arrived(steps: Int, final: Reading)
        case noProgress(steps: Int, last: Reading)
        case budgetExhausted(steps: Int, last: Reading)
        case overshot(steps: Int, last: Reading)
        case readbackLost(steps: Int)
    }

    /// Walks by requesting a raw value on the desired side of the current
    /// reading. `nudge` is deliberately injected so this decision layer has no
    /// AX dependency; it returns whether the write itself was accepted, not
    /// whether the control moved.
    static func walk(
        to target: Target,
        read: () -> Reading?,
        nudge: (Double) -> Bool,
        budget: Int
    ) -> WalkOutcome {
        guard let initial = read() else {
            return .readbackLost(steps: 0)
        }

        if reached(target, reading: initial) {
            return .arrived(steps: 0, final: initial)
        }

        // A budget is a cap on accepted write steps. It never suppresses the
        // entry read: a missing entry read is still readback loss, not budget
        // exhaustion wearing a more convenient name.
        guard budget > 0 else {
            return .budgetExhausted(steps: 0, last: initial)
        }

        switch target {
        case .rawValue(let rawTarget, let tolerance):
            return walkRaw(
                to: rawTarget,
                tolerance: abs(tolerance),
                initial: initial,
                nudge: nudge,
                read: read,
                budget: budget
            )
        case .display(let targetDisplay):
            return walkDisplay(
                to: targetDisplay,
                initial: initial,
                nudge: nudge,
                read: read,
                budget: budget
            )
        }
    }

    private enum Direction: Double, Equatable {
        case down = -1
        case up = 1
    }

    private static func walkRaw(
        to target: Double,
        tolerance: Double,
        initial: Reading,
        nudge: (Double) -> Bool,
        read: () -> Reading?,
        budget: Int
    ) -> WalkOutcome {
        var current = initial
        var previous: Reading?
        var crossedTarget = false
        var steps = 0

        while steps < budget {
            // Passing the actual raw target lets AX decide its increment or
            // decrement. We never clamp it: an out-of-range request must run
            // into its real rail and report no progress.
            guard nudge(target) else {
                return .noProgress(steps: steps, last: current)
            }
            steps += 1

            guard let next = read() else {
                return .readbackLost(steps: steps)
            }
            if isWithinTolerance(next.value, of: target, tolerance: tolerance) {
                return .arrived(steps: steps, final: next)
            }

            if next.value == current.value {
                return .noProgress(steps: steps, last: next)
            }
            if previous?.value == next.value {
                return .noProgress(steps: steps, last: next)
            }

            // Do not call the first crossing an overshoot: a later nudge may
            // still return toward the target. It is an overshoot only after a
            // crossed walk moves farther away on the same wrong side.
            if crossedTarget,
               movesFurtherAwayOnSameSide(
                   from: current.value,
                   to: next.value,
                   target: target,
                   tolerance: tolerance
               ) {
                return .overshot(steps: steps, last: next)
            }

            if crossesTarget(
                from: current.value,
                to: next.value,
                target: target,
                tolerance: tolerance
            ) {
                crossedTarget = true
            }

            previous = current
            current = next
        }

        return .budgetExhausted(steps: steps, last: current)
    }

    private static func walkDisplay(
        to targetDisplay: String,
        initial: Reading,
        nudge: (Double) -> Bool,
        read: () -> Reading?,
        budget: Int
    ) -> WalkOutcome {
        var current = initial
        // The first request is an upward probe. A measured 302 / "+6.2 dB"
        // walk took 179 upward steps to 480 / "+24.0 dB" for a "+2.2 dB"
        // target, so the probe's raw direction must not be frozen. Logic's
        // rendering is re-evaluated after every step to prove it is closer.
        var direction = Direction.up
        var isProbe = true
        var steps = 0

        // A REQUEST DISTANCE, not an assumed raw or display increment. Some Logic sliders snap
        // coarser than one raw unit: Channel EQ's Q spans 0...127 over peak bands and 0...52 over
        // shelves, and `nudge(current + 1)` lands back on the value it started from — measured
        // 2026-09-12, every `.display` request on Q stopped at `walk_steps: 1`. The SAME parameter
        // reached twelve verified writes through the `.rawValue` path, so the control was never
        // stuck; one raw unit is simply below its minimum step.
        //
        // A successful distance is RETAINED, so calibration is paid once per walk rather than at
        // every movement. See the budget note on `walk(to:read:nudge:budget:)`.
        var requestDistance = 1.0
        var unchangedWrites = 0
        // A retry policy, not a slider range: the tried distances are 1, 2, 4 … 128, which covers
        // the reported Q spans. A control needing more still returns `noProgress`, which is the
        // honest answer — this is bounded discovery, not a promise to find any threshold.
        let unchangedWriteLimit = 8

        while steps < budget {
            let requested = current.value + direction.rawValue * requestDistance
            guard requested.isFinite, requested != current.value else {
                return .noProgress(steps: steps, last: current)
            }
            guard nudge(requested) else {
                return .noProgress(steps: steps, last: current)
            }
            // Accepted no-ops and calibration writes consume the same budget, because `budget` is
            // a cap on ACCEPTED WRITE STEPS and the caller can see the number.
            steps += 1

            guard let next = read() else {
                return .readbackLost(steps: steps)
            }
            if namesTheSameReading(next.display, targetDisplay) {
                return .arrived(steps: steps, final: next)
            }

            if next.value == current.value, next.display == current.display {
                // NEITHER observation moved. That is either a rail or a request smaller than this
                // control's minimum step, and one unchanged readback cannot tell them apart — so
                // double the distance and ask again, up to the bounded retry window above. After
                // that the walk reports no progress, which is what a real rail deserves.
                unchangedWrites += 1
                guard unchangedWrites < unchangedWriteLimit else {
                    return .noProgress(steps: steps, last: next)
                }
                requestDistance *= 2
                current = next
                continue
            }

            unchangedWrites = 0
            if next.display == current.display {
                // An unchanged RENDERING over a CHANGED raw value is progress. Channel EQ's Q
                // renders two decimals over a range finer than that, so a real step reads back the
                // same string — treating that as terminal is why Q landed nothing on any band in
                // either direction (#292). A display plateau neither enlarges the request nor ends
                // calibration.
                current = next
                continue
            }

            guard let numbers = orderedDisplayNumbers(
                from: current.display,
                to: next.display,
                target: targetDisplay
            ) else {
                // An ordering we cannot establish is not a licence to pick a
                // direction. In particular, parsing raw values or a dB/Hz
                // mapping here would invent information Logic did not render.
                return .noProgress(steps: steps, last: next)
            }

            // A larger request can step OVER the target, and a crossing can still be numerically
            // closer — rendered 0 → 4 against a target of 3 is closer and has passed it. Check the
            // crossing BEFORE distance and before the probe reversal, so a coarse walk can never
            // sail past its target and call the overshoot progress.
            if crossesTarget(
                from: numbers.current,
                to: numbers.next,
                target: numbers.target,
                tolerance: 0
            ) {
                return .overshot(steps: steps, last: next)
            }

            let movedCloser = abs(numbers.next - numbers.target)
                < abs(numbers.current - numbers.target)
            if !movedCloser {
                if isProbe {
                    // The lone calibration probe moved away, so try its
                    // opposite once. Later non-closer displays are no
                    // progress, not a reason to walk into a control rail.
                    direction = direction == .up ? .down : .up
                    isProbe = false
                    current = next
                    continue
                }
                return .noProgress(steps: steps, last: next)
            }

            isProbe = false
            current = next
        }

        return .budgetExhausted(steps: steps, last: current)
    }

    private static func reached(_ target: Target, reading: Reading) -> Bool {
        switch target {
        case .rawValue(let value, let tolerance):
            isWithinTolerance(reading.value, of: value, tolerance: abs(tolerance))
        case .display(let display):
            namesTheSameReading(reading.display, display)
        }
    }

    private static func isWithinTolerance(
        _ value: Double,
        of target: Double,
        tolerance: Double
    ) -> Bool {
        abs(value - target) <= tolerance
    }

    /// The two rendered numbers and the requested one, in a form that may be compared — or `nil`
    /// when they may not be.
    ///
    /// Only numbers LOGIC rendered are compared, and only with consistent rendered units. The
    /// requested unit is checked against them only when Logic rendered a unit at all: Logic renders
    /// Q as `0.88 ` with no unit while the caller's request is built as `0.88 Q`, and the old
    /// predicate rejected exactly that pair — so a Q walk could arrive (arrival already allowed it)
    /// but could never be steered. The asymmetry was the bug; this is the same rule arrival uses.
    private static func orderedDisplayNumbers(
        from current: String,
        to next: String,
        target: String
    ) -> (current: Double, next: Double, target: Double)? {
        guard let currentValue = leadingNumber(in: current),
              let nextValue = leadingNumber(in: next),
              let targetValue = leadingNumber(in: target),
              currentValue.number.isFinite,
              nextValue.number.isFinite,
              targetValue.number.isFinite else {
            return nil
        }

        let renderedUnit = trimmed(currentValue.suffix)
        guard renderedUnit == trimmed(nextValue.suffix),
              renderedUnit.isEmpty || renderedUnit == trimmed(targetValue.suffix) else {
            return nil
        }

        return (currentValue.number, nextValue.number, targetValue.number)
    }

    /// Splits only a leading signed decimal from Logic's rendering. Everything
    /// after it remains opaque unit text; this core must not create a dB or Hz
    /// parser just to choose a raw slider direction.
    private static func leadingNumber(in display: String) -> (number: Double, suffix: String)? {
        let bytes = Array(display.utf8)
        guard !bytes.isEmpty else { return nil }

        var end = 0
        if bytes[end] == 43 || bytes[end] == 45 { // + or -
            end += 1
        }

        var digits = 0
        while end < bytes.count, isASCIIDigit(bytes[end]) {
            end += 1
            digits += 1
        }
        if end < bytes.count, bytes[end] == 46 { // .
            end += 1
            while end < bytes.count, isASCIIDigit(bytes[end]) {
                end += 1
                digits += 1
            }
        }

        guard digits > 0,
              let number = Double(String(decoding: bytes[..<end], as: UTF8.self)) else {
            return nil
        }
        return (number, String(decoding: bytes[end...], as: UTF8.self))
    }

    /// Whether two renderings name the SAME reading.
    ///
    /// Exact string equality was the rule, and it made half of Channel EQ's dB space unreachable.
    /// The request renders -5.0 as `-5` — correct for `400 Hz`, wrong for dB, where Logic always
    /// shows the decimal — so the walk arrived at `-5.0 dB` and did not recognise it. Measured live
    /// 2026-09-12 (#292): every half-dB target landed and every WHOLE-dB target died
    /// `increment_walk_no_progress` a few steps from the value it had already reached, `-5.5`
    /// arriving in 82 steps while `-5.0` died in 6 from a start five steps away. Q lands nothing on
    /// any band for the mirror reason: a request of `1.5` against a control Logic renders `1.50`.
    ///
    /// This is NOT a unit conversion and invents no mapping. The number compared is the one LOGIC
    /// rendered, read by the same parser the ordering test uses, and the text after it must match
    /// exactly — `400 Hz` and `400 dB` stay different readings. A rendering carrying no number at
    /// all (`Off`, `Auto`) can only be compared as the string it is, and still is.
    private static func namesTheSameReading(_ rendered: String, _ requested: String) -> Bool {
        if rendered == requested { return true }
        guard let left = leadingNumber(in: rendered),
              let right = leadingNumber(in: requested) else { return false }
        guard left.number == right.number else { return false }
        // An EMPTY rendered suffix matches whatever unit the caller asked in. Measured 2026-09-13
        // (#292): Channel EQ renders Q as `0.88 ` — two decimals, a trailing space, and NO unit —
        // while a request for `unit: "Q"` builds `0.88 Q`. Comparing the suffixes as equals made Q
        // unreachable on every band in both directions, which is the failure this was written to
        // end and instead reproduced one layer down.
        //
        // Two NON-EMPTY suffixes must still agree, and that is the clause that matters: `400 Hz`
        // and `400 dB` stay different readings. When LOGIC renders no unit there is nothing to
        // disagree with — the control does not express one, and the caller's `Q` is their label for
        // the parameter rather than a rendering Logic ever produces.
        let renderedUnit = trimmed(left.suffix)
        if renderedUnit.isEmpty { return true }
        return renderedUnit == trimmed(right.suffix)
    }

    /// Stdlib-only, because this file deliberately imports nothing.
    private static func trimmed(_ text: String) -> String {
        String(text.drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private static func crossesTarget(
        from oldValue: Double,
        to newValue: Double,
        target: Double,
        tolerance: Double
    ) -> Bool {
        (oldValue < target - tolerance && newValue > target + tolerance)
            || (oldValue > target + tolerance && newValue < target - tolerance)
    }

    private static func movesFurtherAwayOnSameSide(
        from oldValue: Double,
        to newValue: Double,
        target: Double,
        tolerance: Double
    ) -> Bool {
        let bothAbove = oldValue > target + tolerance && newValue > target + tolerance
        let bothBelow = oldValue < target - tolerance && newValue < target - tolerance
        return (bothAbove || bothBelow) && abs(newValue - target) > abs(oldValue - target)
    }
}
