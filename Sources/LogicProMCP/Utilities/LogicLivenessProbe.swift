import ApplicationServices
import Darwin
import Foundation

/// Two cheap, bounded facts about Logic that explain most "every live operation times out"
/// reports (#1565), so a timeout reply and `doctor` can name the likely cause and the fix
/// instead of only saying that 25 seconds passed.
struct LogicLiveness: Sendable, Equatable {
    /// Whether one of Logic's ordinary windows is on screen on the current Space. nil: not probed.
    var windowOnScreen: Bool?
    /// Logic's CPU over the sample window, in percent of one core. nil: not probed.
    var cpuPercent: Double?

    static let unavailable = LogicLiveness()

    var windowOffSpace: Bool { windowOnScreen == false }
    var mainThreadSaturated: Bool { (cpuPercent ?? 0) > LogicLivenessProbe.saturatedCPUPercent }

    /// The likely causes, each already phrased with its fix.
    var likelyCauses: [String] {
        var causes: [String] = []
        if windowOffSpace { causes.append(LogicLivenessProbe.windowOffSpaceMessage) }
        if mainThreadSaturated { causes.append(LogicLivenessProbe.saturatedMessage) }
        return causes
    }

    /// Wire fields for a reply: what was measured, and the causes if any.
    var fields: [String: Any] {
        var out: [String: Any] = [:]
        if let windowOnScreen { out["logic_window_on_screen"] = windowOnScreen }
        if let cpuPercent { out["logic_cpu_percent"] = (cpuPercent * 10).rounded() / 10 }
        let causes = likelyCauses
        if !causes.isEmpty { out["likely_causes"] = causes }
        return out
    }
}

enum LogicLivenessProbe {
    /// Process CPU above this share of one core is treated as a saturated main thread.
    static let saturatedCPUPercent = 85.0
    /// Two CPU samples this far apart; the whole probe stays under 300 ms.
    static let sampleIntervalSeconds = 0.2

    static let windowOffSpaceMessage =
        "Logic's window isn't on this desktop/Space — move Logic to the same desktop as the app running the server"
    static let saturatedMessage =
        "Logic's main thread is saturated (often the Logic 13 Browser panel is open) — close the Browser"

    /// Probe the running Logic. Never launches a subprocess and never touches Logic's AX tree.
    static func live() -> LogicLiveness {
        guard let pid = ProcessUtils.Runtime.production.logicProPID() else { return .unavailable }
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
        return LogicLiveness(
            windowOnScreen: windows.map { hasOnScreenWindow(pid: pid, in: $0) },
            cpuPercent: cpuPercent(pid: pid, interval: sampleIntervalSeconds)
        )
    }

    /// True when `pid` owns at least one non-empty, ordinary (layer 0) window in an on-screen list.
    static func hasOnScreenWindow(pid: pid_t, in windows: [[String: Any]]) -> Bool {
        windows.contains { info in
            guard ProcessUtils.pidValue(from: info[kCGWindowOwnerPID as String]) == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            return width > 0 && height > 0
        }
    }

    /// CPU time consumed over `elapsedSeconds`, as a percentage of one core.
    static func cpuPercent(cpuSecondsBefore: Double, cpuSecondsAfter: Double, elapsedSeconds: Double) -> Double? {
        guard elapsedSeconds > 0, cpuSecondsAfter >= cpuSecondsBefore else { return nil }
        return (cpuSecondsAfter - cpuSecondsBefore) / elapsedSeconds * 100
    }

    private static func cpuPercent(pid: pid_t, interval: TimeInterval) -> Double? {
        guard let before = totalCPUSeconds(pid: pid) else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: interval)
        guard let after = totalCPUSeconds(pid: pid) else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return cpuPercent(cpuSecondsBefore: before, cpuSecondsAfter: after, elapsedSeconds: elapsed)
    }

    /// User + system CPU time of `pid` from `proc_pidinfo`, converted from Mach time units.
    private static func totalCPUSeconds(pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
        let ticks = Double(info.pti_total_user &+ info.pti_total_system)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}
