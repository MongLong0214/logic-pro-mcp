@preconcurrency import ApplicationServices
import Foundation

/// #1606: the track-header Volume fader of the last `mixer.set_volume` target, kept so the next call
/// can skip the whole-window header walk (about 75 ms of a ~500 ms write on Logic 13).
///
/// This is a hint, not an answer. Every use is revalidated against the live tree first, and any
/// doubt returns nil so the caller does the full locate it always did. What it checks, in order:
/// the header rail is still readable, row `index` of the rail is still the cached header, the
/// cached slider is still an `AXSlider` under that header, and it still resolves as the Volume fader.
final class MixerHeaderFaderCache: @unchecked Sendable {
    static let shared = MixerHeaderFaderCache()

    private struct Entry {
        let index: Int
        let rail: AXUIElement
        let header: AXUIElement
        let slider: AXUIElement
    }

    private let lock = NSLock()
    private var entry: Entry?

    func invalidate() {
        lock.lock(); entry = nil; lock.unlock()
    }

    /// Remember `slider` as the Volume fader of row `index` of the rail that holds `header`. Nothing
    /// is kept unless that rail, enumerated alone, yields `header` at `index`.
    func store(index: Int, header: AXUIElement, slider: AXUIElement, runtime: AXHelpers.Runtime) {
        guard let rail: AXUIElement = AXHelpers.getAttribute(header, kAXParentAttribute as String, runtime: runtime),
              case .read(let rows) = AXLogicProElements.enumerateTrackHeaderRows(in: rail, runtime: runtime),
              index >= 0, index < rows.count, CFEqual(rows[index], header) else {
            invalidate()
            return
        }
        lock.lock()
        entry = Entry(index: index, rail: rail, header: header, slider: slider)
        lock.unlock()
    }

    /// The cached slider when it is still provably row `index`'s Volume fader, otherwise nil.
    func revalidated(index: Int, runtime: AXHelpers.Runtime) -> AXUIElement? {
        lock.lock(); let held = entry; lock.unlock()
        guard let held, held.index == index else { return nil }
        guard case .read(let rows) = AXLogicProElements.enumerateTrackHeaderRows(in: held.rail, runtime: runtime),
              index < rows.count, CFEqual(rows[index], held.header) else {
            invalidate()
            return nil
        }
        let role: String? = AXHelpers.getAttribute(held.slider, kAXRoleAttribute as String, runtime: runtime)
        guard role == (kAXSliderRole as String), Self.reaches(held.header, from: held.slider, runtime: runtime),
              AXLogicProElements.volumeFaderCandidates(among: [held.slider], runtime: runtime).count == 1 else {
            invalidate()
            return nil
        }
        return held.slider
    }

    /// `slider` sits under `header` within the four levels the full locate searches.
    private static func reaches(_ header: AXUIElement, from slider: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        var node = slider
        for _ in 0..<4 {
            guard let parent: AXUIElement = AXHelpers.getAttribute(node, kAXParentAttribute as String, runtime: runtime) else {
                return false
            }
            if CFEqual(parent, header) { return true }
            node = parent
        }
        return false
    }
}

enum MixerSettle {
    /// Read `read()` now; while it still equals `previous`, wait `step` and read again, for at most
    /// `bound` of waiting. Returns the first value that differs, or the unchanged value once the
    /// bound is spent (the caller's own stagnation handling then decides). A nil read returns nil.
    /// This replaces a fixed sleep before the read: a value that has already moved costs no wait.
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
        return latest
    }
}
