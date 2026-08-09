import AppKit
import Darwin
import Foundation

/// Utilities for finding and interacting with the Logic Pro process.
enum ProcessUtils {
    struct Runtime: Sendable {
        let logicProPID: @Sendable () -> pid_t?
        let fallbackLogicProPID: @Sendable () -> pid_t?
        let logicProRunning: @Sendable () -> Bool
        let activateLogicPro: @Sendable () -> Bool
        let logicIsFrontmost: @Sendable () -> Bool
        let logicProBundleURL: @Sendable () -> URL?

        static let production = Runtime(
            logicProPID: {
                ProcessUtils.logicProApp()?.processIdentifier
            },
            fallbackLogicProPID: {
                ProcessUtils.logicProPIDViaVisibleWindow()
                    ?? ProcessUtils.logicProPIDViaProcessList()
                    ?? ProcessUtils.logicProPIDViaSystemEvents()
            },
            logicProRunning: {
                ProcessUtils.logicProApp() != nil
                    || ProcessUtils.logicProPIDViaVisibleWindow() != nil
                    || ProcessUtils.logicProPIDViaProcessList() != nil
            },
            activateLogicPro: {
                guard let app = ProcessUtils.logicProApp() else {
                    return ProcessUtils.activateLogicProViaAppleScript()
                }
                return ProcessUtils.activateLogicProWithFallback(
                    appKitActivate: {
                        ProcessUtils.runAppKit {
                            app.activate()
                        }
                    },
                    appleScriptActivate: {
                        ProcessUtils.activateLogicProViaAppleScript()
                    }
                )
            },
            logicIsFrontmost: { ProcessUtils.logicOwnsTheKeyboard() },
            logicProBundleURL: {
                // RB-2 (v3.4.0): same rationale as `logicProApp()` — both
                // `NSRunningApplication.bundleURL` and
                // `NSWorkspace.urlForApplication(withBundleIdentifier:)` are
                // launch-services queries with no runloop dependency, so the
                // prior `runAppKit` guard forced a false-nil under stdio.
                LogicProTarget.installedBundleURL()
            }
        )
    }

    struct ProcessMetrics: Sendable {
        let memoryMB: Double
        let cpuPercent: Double
        let uptimeSec: Int
        let cpuPercentStatus: String
        let cpuPercentUnits: String
        let cpuSampleWindowSec: Double
    }

    private struct TimedPIDCache {
        let value: pid_t?
        let expiresAt: Date
    }

    private static let processStartDate = Date()
    private static let minimumCPUSampleUptimeSec: TimeInterval = 1.0
    private static let subprocessTimeout: TimeInterval = 1.0
    private static let pidCacheTTL: TimeInterval = 0.5
    private static let pidCacheLock = NSLock()
    nonisolated(unsafe) private static var pidProcessListCache: TimedPIDCache?

    static func runAppKit<T>(_ body: () -> T) -> T? {
        if Thread.isMainThread {
            return body()
        }
        // In a CLI process without an AppKit runloop, DispatchQueue.main.sync
        // would deadlock indefinitely. Guard against this by checking whether
        // the main runloop is actually servicing events.
        guard CFRunLoopIsWaiting(CFRunLoopGetMain()) || Thread.isMainThread else {
            return nil
        }
        return DispatchQueue.main.sync(execute: body)
    }

    static func activateLogicProWithFallback(
        appKitActivate: () -> Bool?,
        appleScriptActivate: () -> Bool
    ) -> Bool {
        let appKitActivated = appKitActivate() == true
        return appleScriptActivate() || appKitActivated
    }

    private static func activateLogicProViaAppleScript() -> Bool {
        let logicProAppleScript = LogicProTarget.current.appleScriptTarget()
        let script = """
        \(logicProAppleScript.activateByBundleID)
        try
            tell application "System Events"
                tell \(logicProAppleScript.systemEventsProcessTarget) to set frontmost to true
            end tell
        end try
        return "ok"
        """
        return runAppleScript(script) != nil
    }

    /// RB-2 (2026-05-08 enterprise review) closed in v3.4.0: pre-fix this
    /// wrapped the call in `runAppKit` "to be safe," which forced a nil
    /// return whenever the server ran as an MCP-client stdio subprocess
    /// (no AppKit runloop). The fallback chain (`/bin/ps` →
    /// `osascript System Events`) then took over, and in restricted
    /// launch contexts it sometimes failed too — producing the observed
    /// `logic_pro_running:false` while System Events on the same host
    /// could see Logic.
    ///
    /// `NSRunningApplication.runningApplications(withBundleIdentifier:)`
    /// is documented as thread-safe (it queries the launch services
    /// database; no runloop dependency). Calling it directly removes
    /// the false negative without losing safety.
    private static func logicProApp() -> NSRunningApplication? {
        LogicProTarget.runningApplication()
    }

    static func bundleIDForPID(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Whether Logic currently owns the keyboard, asked of the window server rather than of
    /// `NSWorkspace`.
    ///
    /// `NSWorkspace.frontmostApplication` is served from a cache that a process only refreshes while
    /// it runs a run loop. The MCP server is long-lived and does not, so the value goes stale:
    /// measured here, after switching from Logic to Finder it kept answering "Logic Pro" for the
    /// rest of the process's life while the window server and System Events both said "Finder".
    /// A frontmost gate built on that reports `already_frontmost` for a backgrounded Logic — exactly
    /// the state it exists to refuse — so the question is put to the component that actually decides
    /// where keystrokes go.
    static func logicOwnsTheKeyboard() -> Bool {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        // The list is ordered front to back; the first normal-layer window belongs to the app that
        // owns the keyboard.
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return isKnownLogicPID(pid)
        }
        return false
    }

    static func isKnownLogicPID(_ pid: pid_t) -> Bool {
        guard let bundleID = bundleIDForPID(pid) else { return true }
        return LogicProTarget.isKnownBundleID(bundleID)
    }

    static func preferredLogicPID(from candidates: [pid_t]) -> pid_t? {
        guard !candidates.isEmpty else { return nil }
        let target = LogicProTarget.current
        if let match = candidates.first(where: { bundleIDForPID($0) == target.bundleID }) {
            return match
        }
        if let frontmostID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           candidates.contains(frontmostID),
           isKnownLogicPID(frontmostID) {
            return frontmostID
        }
        return candidates.first(where: isKnownLogicPID(_:))
    }

    /// Returns the PID of Logic Pro if running, nil otherwise.
    static func logicProPID() -> pid_t? {
        logicProPID(runtime: .production)
    }

    static func logicProPID(runtime: Runtime) -> pid_t? {
        runtime.logicProPID() ?? runtime.fallbackLogicProPID()
    }

    /// Whether Logic Pro is currently running.
    static var isLogicProRunning: Bool {
        isLogicProRunning(runtime: .production)
    }

    static func isLogicProRunning(runtime: Runtime) -> Bool {
        if runtime.logicProRunning() {
            return true
        }
        if runtime.logicProPID() != nil {
            return true
        }
        return runtime.fallbackLogicProPID() != nil
    }

    /// Check if Logic Pro has at least one visible on-screen window.
    /// Uses CGWindowListCopyWindowInfo (no extra permissions needed).
    static func hasVisibleWindow() -> Bool {
        guard let pid = logicProPID() else { return false }
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windowList.contains { info in
            guard let ownerPID = pidValue(from: info[kCGWindowOwnerPID as String]),
                  ownerPID == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else {
                return false
            }
            return true
        }
    }

    /// Bring Logic Pro to front (used sparingly — most operations don't need focus).
    static func activateLogicPro() -> Bool {
        activateLogicPro(runtime: .production)
    }

    static func activateLogicPro(runtime: Runtime) -> Bool {
        runtime.activateLogicPro()
    }

    static func logicProVersion() -> String? {
        logicProVersion(runtime: .production)
    }

    static func logicProVersion(runtime: Runtime) -> String? {
        let bundleURL = runtime.logicProBundleURL()
        guard let bundleURL, let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static func logicProPIDViaSystemEvents() -> pid_t? {
        let script = """
        tell application "System Events"
            try
                return unix id of first application process whose name is "\(AppleScriptSafety.escapeForScript(LogicProTarget.current.processName))"
            on error
                return ""
            end try
        end tell
        """
        guard let output = runAppleScript(script) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawPID = Int32(trimmed), rawPID > 0, isKnownLogicPID(rawPID) else {
            return nil
        }
        return rawPID
    }

    static func parseLogicProPID(fromProcessList output: String) -> pid_t? {
        var candidates: [pid_t] = []
        let installPathMarkers = LogicProVariantPolicy.macOSExecutablePathMarkers
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let rawPID = Int32(parts[0]), rawPID > 0 else {
                continue
            }

            let command = String(parts[1])
            if LogicProTarget.knownProcessNames.contains(where: { command.contains($0) })
                || installPathMarkers.contains(where: { command.contains($0) })
            {
                candidates.append(rawPID)
            }
        }

        return preferredLogicPID(from: candidates)
    }

    static func logicProPID(fromWindowList windowList: [[String: Any]]) -> pid_t? {
        var candidates: [pid_t] = []
        for info in windowList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  LogicProTarget.isLogicProcessName(ownerName),
                  let ownerPID = pidValue(from: info[kCGWindowOwnerPID as String]),
                  ownerPID > 0 else {
                continue
            }

            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let width = (bounds["Width"] as? NSNumber)?.doubleValue,
               let height = (bounds["Height"] as? NSNumber)?.doubleValue {
                if width > 0, height > 0 {
                    candidates.append(ownerPID)
                }
            } else {
                candidates.append(ownerPID)
            }
        }

        return preferredLogicPID(from: candidates)
    }

    private static func pidValue(from value: Any?) -> pid_t? {
        if let pid = value as? pid_t {
            return pid
        }
        if let number = value as? NSNumber {
            return pid_t(number.int32Value)
        }
        if let int = value as? Int {
            return pid_t(int)
        }
        return nil
    }

    private static func logicProPIDViaVisibleWindow() -> pid_t? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return logicProPID(fromWindowList: windowList)
    }

    private static func logicProPIDViaProcessList() -> pid_t? {
        let now = Date()
        pidCacheLock.lock()
        if let cached = pidProcessListCache, cached.expiresAt > now {
            let cachedValue = cached.value
            pidCacheLock.unlock()
            return cachedValue
        }
        pidCacheLock.unlock()

        let psOutput = runProcessAndCaptureStdout(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,comm="],
            timeout: subprocessTimeout
        )
        var pgrepOutput: String?
        if psOutput.flatMap(parseLogicProPID(fromProcessList:)) == nil {
            for processName in LogicProTarget.knownProcessNames {
                pgrepOutput = runProcessAndCaptureStdout(
                    executablePath: "/usr/bin/pgrep",
                    arguments: ["-fl", processName],
                    timeout: subprocessTimeout
                )
                if pgrepOutput.flatMap(parseLogicProPID(fromProcessList:)) != nil {
                    break
                }
            }
        }
        let pid = psOutput.flatMap(parseLogicProPID(fromProcessList:))
            ?? pgrepOutput.flatMap(parseLogicProPID(fromProcessList:))

        pidCacheLock.lock()
        pidProcessListCache = TimedPIDCache(value: pid, expiresAt: now.addingTimeInterval(pidCacheTTL))
        pidCacheLock.unlock()
        return pid
    }

    private static func runAppleScript(_ source: String) -> String? {
        runProcessAndCaptureStdout(
            executablePath: "/usr/bin/osascript",
            arguments: appleScriptArguments(for: source),
            timeout: subprocessTimeout
        )
    }

    private static func appleScriptArguments(for source: String) -> [String] {
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.flatMap { ["-e", $0] }
    }

    private static func runProcessAndCaptureStdout(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLimitBytes: Int = 8_388_608
    ) -> String? {
        guard case let .completed(output) = BoundedProcessRunner.run(
            executable: executablePath,
            arguments: arguments,
            timeout: timeout,
            outputLimitBytes: outputLimitBytes
        ), output.exitCode == 0 else {
            return nil
        }
        if output.stdoutTruncated {
            Log.warn(
                "Process output truncated at \(outputLimitBytes) bytes for \(executablePath); downstream parsing (e.g. PID lookup) may be incomplete",
                subsystem: "process"
            )
        }
        return output.stdout
    }

    static func currentProcessMetrics() -> ProcessMetrics {
        let uptime = max(Date().timeIntervalSince(processStartDate), 0)

        var usage = rusage()
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        let userTime = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let systemTime = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let taskInfoResult = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        let residentMemoryBytes = taskInfoResult == KERN_SUCCESS ? UInt64(taskInfo.resident_size) : 0
        let cpuTimeSec = usageResult == 0 ? userTime + systemTime : 0

        return processMetricsForSample(
            cpuTimeSec: cpuTimeSec,
            uptimeSec: uptime,
            residentMemoryBytes: residentMemoryBytes
        )
    }

    static func processMetricsForSample(
        cpuTimeSec: Double,
        uptimeSec: TimeInterval,
        residentMemoryBytes: UInt64
    ) -> ProcessMetrics {
        let memoryMB = Double(residentMemoryBytes) / 1_048_576
        let uptime = max(uptimeSec, 0)
        guard uptime >= minimumCPUSampleUptimeSec,
              cpuTimeSec.isFinite,
              cpuTimeSec >= 0 else {
            return ProcessMetrics(
                memoryMB: memoryMB,
                cpuPercent: 0,
                uptimeSec: Int(uptime.rounded()),
                cpuPercentStatus: "warming_up",
                cpuPercentUnits: "single_core_lifetime_average",
                cpuSampleWindowSec: 0
            )
        }
        let cpuPercent = (cpuTimeSec / uptime) * 100.0
        return ProcessMetrics(
            memoryMB: memoryMB,
            cpuPercent: max(0, cpuPercent),
            uptimeSec: Int(uptime.rounded()),
            cpuPercentStatus: "sampled",
            cpuPercentUnits: "single_core_lifetime_average",
            cpuSampleWindowSec: uptime
        )
    }
}
