import Foundation

/// A bounded wait for a value to become readable after a write.
///
/// It replaces a fixed sleep placed in front of a readback: the check runs at once, and the wait
/// is spent only while the check still fails. The bound is the one the old sleep had, so a value
/// that never arrives costs what it cost before and is reported as not arrived (`false`), never as
/// arrived. The check, not this helper, decides what counts as the expected value, so a caller
/// keeps its independent readback.
enum ReadbackPoll {
    /// Runs `check` now. While it returns false and less than `bound` microseconds of wall time
    /// have passed, sleeps up to `step` and runs it again. Returns true when `check` passes, false
    /// once the bound is spent with the check still failing.
    ///
    /// A continuous value (a slider, a tempo) is not believed on first sight, because it can pass
    /// through the expected value on its way to another one: with `confirm` (the default) a
    /// passing check is accepted only when it passes again one `step` later, and a second failure
    /// resumes the poll. `confirm: false` is for a discrete state (a checkbox, a selection, a
    /// name), where there is no pass-through value and the read is an expensive tree walk that the
    /// confirmation would double; it accepts the first passing check.
    static func until(
        bound: UInt32,
        step: UInt32 = 5_000,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleep: (UInt32) -> Void = { usleep($0) },
        confirm: Bool = true,
        check: () -> Bool
    ) -> Bool {
        let start = now()
        let boundSeconds = Double(bound) / 1_000_000
        while true {
            if check() {
                if !confirm { return true }
                sleep(step)
                if check() { return true }
            }
            let remaining = boundSeconds - (now() - start)
            if remaining <= 0 { return false }
            sleep(min(step, UInt32((remaining * 1_000_000).rounded(.up))))
        }
    }
}
