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

    private enum Direction: Double {
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
        // The first request is a calibration nudge toward a higher raw value.
        // Once Logic's display changes, raw readback—not a made-up Hz/dB
        // mapping—tells us which raw direction produced that rendering.
        var direction: Direction?
        var rawWhenDisplayLastChanged = initial.value
        var previous: Reading?
        var steps = 0

        while steps < budget {
            let requestedRaw: Double
            if let direction {
                requestedRaw = current.value + direction.rawValue
            } else {
                requestedRaw = current.value + Direction.up.rawValue
            }

            guard nudge(requestedRaw) else {
                return .noProgress(steps: steps, last: current)
            }
            steps += 1

            guard let next = read() else {
                return .readbackLost(steps: steps)
            }
            if next.display == targetDisplay {
                return .arrived(steps: steps, final: next)
            }

            if next.value == current.value || previous?.value == next.value {
                return .noProgress(steps: steps, last: next)
            }

            if next.display != current.display {
                guard let observedDirection = rawDirection(
                    from: rawWhenDisplayLastChanged,
                    to: next.value
                ), direction == nil || direction == observedDirection else {
                    return .noProgress(steps: steps, last: next)
                }
                direction = observedDirection
                rawWhenDisplayLastChanged = next.value
            } else if direction == nil {
                // A raw change with no display change cannot establish that the
                // calibration nudge is moving toward the requested rendering.
                // Stop rather than guessing an engineering-value mapping.
                return .noProgress(steps: steps, last: next)
            }

            previous = current
            current = next
        }

        return .budgetExhausted(steps: steps, last: current)
    }

    private static func reached(_ target: Target, reading: Reading) -> Bool {
        switch target {
        case .rawValue(let value, let tolerance):
            isWithinTolerance(reading.value, of: value, tolerance: abs(tolerance))
        case .display(let display):
            reading.display == display
        }
    }

    private static func isWithinTolerance(
        _ value: Double,
        of target: Double,
        tolerance: Double
    ) -> Bool {
        abs(value - target) <= tolerance
    }

    private static func rawDirection(from oldValue: Double, to newValue: Double) -> Direction? {
        if newValue > oldValue { return .up }
        if newValue < oldValue { return .down }
        return nil
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
