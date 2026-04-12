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
                ProcessUtils.logicProPIDViaProcessList() ?? ProcessUtils.logicProPIDViaSystemEvents()
            },
            logicProRunning: {
                ProcessUtils.logicProApp() != nil || ProcessUtils.logicProPIDViaProcessList() != nil
            },
            activateLogicPro: {
                guard let app = ProcessUtils.logicProApp() else { return false }
                return ProcessUtils.runAppKit { app.activate(); return true } ?? false
            },
            logicProBundleURL: {
                ProcessUtils.runAppKit {
                    ProcessUtils.logicProApp()?.bundleURL
                        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ServerConfig.logicProBundleID)
                } ?? nil
            }
        )
    }

    struct ProcessMetrics: Sendable {
        let memoryMB: Double
        let cpuPercent: Double
        let uptimeSec: Int
    }

    private struct TimedPIDCache {
        let value: pid_t?
        let expiresAt: Date
    }

    private static let processStartDate = Date()
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

    private static func logicProApp() -> NSRunningApplication? {
        runAppKit {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: ServerConfig.logicProBundleID
            ).first
        } ?? nil
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
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
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

    private static func logicProPIDViaProcessList() -> pid_t? {
        let now = Date()
        pidCacheLock.lock()
        if let cached = pidProcessListCache, cached.expiresAt > now {
            let cachedValue = cached.value
            pidCacheLock.unlock()
            return cachedValue
        }
        pidCacheLock.unlock()

        let output = runProcessAndCaptureStdout(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,comm="],
            timeout: subprocessTimeout
        ) ?? ""
        let pid = parseLogicProPID(fromProcessList: output)

        pidCacheLock.lock()
        pidProcessListCache = TimedPIDCache(value: pid, expiresAt: now.addingTimeInterval(pidCacheTTL))
        pidCacheLock.unlock()
        return pid
    }

    private static func runAppleScript(_ source: String) -> String? {
        let inProcessResult: String?? = runAppKit {
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            let result = script?.executeAndReturnError(&errorInfo)
            guard errorInfo == nil else {
                return nil
            }
            return result?.stringValue
        }
        if let outer = inProcessResult, let result = outer {
            return result
        }

        return runProcessAndCaptureStdout(
            executablePath: "/bin/zsh",
            arguments: ["-lc", appleScriptShellCommand(for: source)],
            timeout: subprocessTimeout
        )
    }

    private static func appleScriptShellCommand(for source: String) -> String {
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let args = lines.map { "-e \(shellQuote($0))" }.joined(separator: " ")
        return "osascript \(args)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func runProcessAndCaptureStdout(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        stdin.fileHandleForWriting.closeFile()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if group.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 0.2)
            }
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Lightweight server-process metrics for diagnostics.
    static func currentProcessMetrics() -> ProcessMetrics {
        let uptime = max(Date().timeIntervalSince(processStartDate), 0.001)

        var usage = rusage()
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        let userTime = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let systemTime = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        let cpuPercent = usageResult == 0 ? ((userTime + systemTime) / uptime) * 100.0 : 0.0

        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let taskInfoResult = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        let memoryMB = taskInfoResult == KERN_SUCCESS ? Double(taskInfo.resident_size) / 1_048_576 : 0.0

        return ProcessMetrics(
            memoryMB: memoryMB,
            cpuPercent: cpuPercent,
            uptimeSec: Int(uptime.rounded())
        )
    }
}
