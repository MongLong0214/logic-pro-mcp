import Foundation

/// The waits between consecutive readings of a bounded readback poll.
///
/// A fixed `sleep(window)` followed by one read costs the whole window on every call, however fast
/// Logic answered. The same window spent as a poll costs only as long as Logic takes, and the last
/// reading still lands no earlier than `windowNanoseconds` after the write, so a slow Logic is
/// judged on the same evidence a fixed settle would have produced.
struct SettleSchedule: Sendable, Equatable {
    let waitsNanoseconds: [UInt64]

    var windowNanoseconds: UInt64 { waitsNanoseconds.reduce(0, +) }
    var readings: Int { waitsNanoseconds.count + 1 }

    /// Time after the write at which each reading after the first is taken.
    var checkpointsNanoseconds: [UInt64] {
        var total: UInt64 = 0
        return waitsNanoseconds.map { total += $0; return total }
    }

    /// The readings at `checkpoints` (ascending, positive), plus the immediate one.
    init(checkpointsNanoseconds checkpoints: [UInt64]) {
        var previous: UInt64 = 0
        var waits: [UInt64] = []
        for checkpoint in checkpoints {
            precondition(checkpoint > previous, "checkpoints must ascend from above zero")
            waits.append(checkpoint - previous)
            previous = checkpoint
        }
        self.waitsNanoseconds = waits
    }

    init(waitsNanoseconds: [UInt64]) { self.waitsNanoseconds = waitsNanoseconds }

    /// Every multiple of `step` up to `window`, plus the `early` checkpoints below the first step.
    /// A fixed poll that read every `step` is therefore a SUBSET of this schedule: whatever
    /// latency it caught, this catches no later, and the last reading is still at `window`.
    static func onGrid(
        stepNanoseconds step: UInt64,
        windowNanoseconds window: UInt64,
        earlyNanoseconds early: [UInt64]
    ) -> SettleSchedule {
        precondition(step > 0 && window >= step && window % step == 0, "the window must be whole steps")
        let grid = stride(from: step, through: window, by: Int(step)).map { $0 }
        let leading = early.filter { $0 < step }.sorted()
        return SettleSchedule(checkpointsNanoseconds: leading + grid)
    }

    /// Doubling waits from `first`, held at `cap`, the last one trimmed so the waits sum to exactly
    /// `window`.
    static func bounded(
        windowNanoseconds window: UInt64,
        firstNanoseconds first: UInt64 = 10_000_000,
        capNanoseconds cap: UInt64 = 100_000_000
    ) -> SettleSchedule {
        precondition(first > 0 && cap >= first, "a settle schedule needs a positive first wait")
        var waits: [UInt64] = []
        var remaining = window
        var next = first
        while remaining > 0 {
            let wait = min(next, remaining)
            waits.append(wait)
            remaining -= wait
            next = min(next * 2, cap)
        }
        return SettleSchedule(waitsNanoseconds: waits)
    }

    /// `edit.move_to_playhead` used to sleep 350 ms before its single post-read.
    static let regionMove = SettleSchedule.bounded(windowNanoseconds: 350_000_000)

    /// Control Bar checkbox readback (play, record, cycle, metronome, count-in, autopunch). It
    /// used to sleep 50 ms BEFORE the first read and then every 50 ms for 12 reads (600 ms).
    static let controlBarCheckbox = SettleSchedule.onGrid(
        stepNanoseconds: 50_000_000, windowNanoseconds: 600_000_000, earlyNanoseconds: [10_000_000, 30_000_000]
    )
}

struct SettleOutcome<Reading> {
    /// The reading the caller must judge: the first one `isSettled` accepted, else the one taken
    /// after the full window.
    let reading: Reading
    let readings: Int
    let settled: Bool
    let waitedNanoseconds: UInt64
}

enum SettlePoll {
    /// Read, and while `isSettled` refuses the reading wait the next slice and read again. Only a
    /// reading that `isSettled` accepts ends the poll early, so `isSettled` must be the caller's
    /// own success condition: an early exit then returns exactly what the final reading would have
    /// returned once Logic caught up, and a reading that never satisfies it is taken after the
    /// whole window, as the fixed sleep it replaces did.
    static func untilSettled<Reading>(
        schedule: SettleSchedule,
        wait: (UInt64) async -> Void,
        read: () -> Reading,
        isSettled: (Reading) -> Bool
    ) async -> SettleOutcome<Reading> {
        var reading = read()
        var readings = 1
        var waited: UInt64 = 0
        if isSettled(reading) {
            return SettleOutcome(reading: reading, readings: readings, settled: true, waitedNanoseconds: waited)
        }
        for slice in schedule.waitsNanoseconds {
            await wait(slice)
            waited += slice
            reading = read()
            readings += 1
            if isSettled(reading) {
                return SettleOutcome(reading: reading, readings: readings, settled: true, waitedNanoseconds: waited)
            }
        }
        return SettleOutcome(reading: reading, readings: readings, settled: false, waitedNanoseconds: waited)
    }
}

extension SettlePoll {
    /// The wait synchronous AX code uses.
    static let blockingWait: @Sendable (UInt64) -> Void = { nanoseconds in usleep(useconds_t(nanoseconds / 1_000)) }

    /// `untilSettled` for the synchronous AX paths that already block their thread with `usleep`.
    static func untilSettledSync<Reading>(
        schedule: SettleSchedule,
        wait: (UInt64) -> Void,
        read: () -> Reading,
        isSettled: (Reading) -> Bool
    ) -> SettleOutcome<Reading> {
        var reading = read()
        var readings = 1
        var waited: UInt64 = 0
        if isSettled(reading) {
            return SettleOutcome(reading: reading, readings: readings, settled: true, waitedNanoseconds: waited)
        }
        for slice in schedule.waitsNanoseconds {
            wait(slice)
            waited += slice
            reading = read()
            readings += 1
            if isSettled(reading) {
                return SettleOutcome(reading: reading, readings: readings, settled: true, waitedNanoseconds: waited)
            }
        }
        return SettleOutcome(reading: reading, readings: readings, settled: false, waitedNanoseconds: waited)
    }
}
