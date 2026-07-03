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
                guard let app = ProcessUtils.logicProApp() else { return false }
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
            logicProBundleURL: {
                // RB-2 (v3.4.0): same rationale as `logicProApp()` — both
                // `NSRunningApplication.bundleURL` and
                // `NSWorkspace.urlForApplication(withBundleIdentifier:)` are
                // launch-services queries with no runloop dependency, so the
                // prior `runAppKit` guard forced a false-nil under stdio.
                ProcessUtils.logicProApp()?.bundleURL
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ServerConfig.logicProBundleID)
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
        let script = """
        tell application "Logic Pro" to activate
        try
            tell application "System Events"
                tell process "Logic Pro" to set frontmost to true
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
        NSRunningApplication.runningApplications(
            withBundleIdentifier: ServerConfig.logicProBundleID
        ).first
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

    /// Best-effort Logic Pro version lookup from the installed bundle.
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
        let escapedName = ServerConfig.logicProProcessName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            try
                return unix id of first application process whose name is "\(escapedName)"
            on error
                return ""
            end try
        end tell
        """
        guard let output = runAppleScript(script) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawPID = Int32(trimmed), rawPID > 0 else {
            return nil
        }
        return rawPID
    }

    static func parseLogicProPID(fromProcessList output: String) -> pid_t? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let rawPID = Int32(parts[0]), rawPID > 0 else {
                continue
            }

            let command = String(parts[1])
            if command.contains("/Logic Pro.app/Contents/MacOS/Logic Pro")
                || command == "Logic Pro"
                || command.hasSuffix("/Logic Pro")
            {
                return rawPID
            }
        }

        return nil
    }

    static func logicProPID(fromWindowList windowList: [[String: Any]]) -> pid_t? {
        for info in windowList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == ServerConfig.logicProProcessName,
                  let ownerPID = pidValue(from: info[kCGWindowOwnerPID as String]),
                  ownerPID > 0 else {
                continue
            }

            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let width = (bounds["Width"] as? NSNumber)?.doubleValue,
               let height = (bounds["Height"] as? NSNumber)?.doubleValue {
                if width > 0, height > 0 {
                    return ownerPID
                }
            } else {
                return ownerPID
            }
        }

        return nil
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
        let pgrepOutput = psOutput.flatMap(parseLogicProPID(fromProcessList:)) == nil
            ? runProcessAndCaptureStdout(
                executablePath: "/usr/bin/pgrep",
                arguments: ["-fl", ServerConfig.logicProProcessName],
                timeout: subprocessTimeout
            )
            : nil
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
        // Process-table probes (`ps -axo`, `pgrep`) can be large on busy hosts;
        // use a generous cap so a Logic line never lands past a truncation
        // boundary and makes PID parsing silently miss it.
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

    /// Lightweight server-process metrics for diagnostics.
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
