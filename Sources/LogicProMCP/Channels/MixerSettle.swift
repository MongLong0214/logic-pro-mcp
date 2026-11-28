import Foundation

enum MixerSettle {
    /// Read `read()` now; while it still equals `previous`, wait `step` and read again, for at most
    /// `bound` of waiting. A value that differs from `previous` is not believed on first sight: it
    /// is accepted only when the next read, one `step` later, returns the same value, because a
    /// slider can pass through the requested value on its way to another one. While it keeps
    /// changing the poll continues up to `bound`, then returns the last value read (at least one
    /// confirming read is always made). A nil read returns nil; an unchanged value is returned once
    /// the bound is spent, and the caller's own stagnation handling decides what that means.
    static func read(
        after previous: Double?,
        step: UInt32 = 2_000,
        bound: UInt32 = 25_000,
        sleep: (UInt32) -> Void = { usleep($0) },
        read: () -> Double?
    ) -> Double? {
        var waited: UInt32 = 0
        var latest = read()
        while let value = latest, value == previous, waited < bound {
            sleep(step)
            waited += step
            latest = read()
        }
        guard var candidate = latest, candidate != previous else { return latest }
        while true {
            sleep(step)
            waited += step
            guard let next = read() else { return candidate }
            if next == candidate { return next }
            candidate = next
            if waited >= bound { return candidate }
        }
    }
}
