import Foundation

extension SetupDoctor {
    static func productionLaunchContext() -> LaunchContextInfo {
        let env = ProcessInfo.processInfo.environment
        let ancestors = productionAncestorProcessInfo()
        return classifyLaunchContext(
            ancestryBundleIDs: ancestors.bundleIDs,
            ancestryProcessNames: ancestors.processNames,
            cfBundleIdentifier: env["__CFBundleIdentifier"],
            termProgram: env["TERM_PROGRAM"]
        )
    }


    static func classifyLaunchContext(
        ancestryBundleIDs: [String],
        ancestryProcessNames: [String] = [],
        cfBundleIdentifier: String?,
        termProgram: String?
    ) -> LaunchContextInfo {
        for bundleID in ancestryBundleIDs {
            if let result = launchContextSignal(bundleID) { return result }
        }
        for name in ancestryProcessNames {
            if let result = launchContextSignal(name) { return result }
        }
        if let cfBundleIdentifier, let result = launchContextSignal(cfBundleIdentifier) {
            return result
        }
        if let termProgram, !termProgram.isEmpty {
            if termProgram.localizedCaseInsensitiveContains("Terminal")
                || termProgram.localizedCaseInsensitiveContains("iTerm") {
                return LaunchContextInfo(context: "terminal", responsibleHint: termProgram)
            }
        }
        return LaunchContextInfo(context: "unknown", responsibleHint: "unknown")
    }


    private static func launchContextSignal(_ raw: String) -> LaunchContextInfo? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.localizedCaseInsensitiveContains("Claude.app")
            || value.localizedCaseInsensitiveContains("claude_desktop")
            || value.localizedCaseInsensitiveContains("com.anthropic.claude") {
            return LaunchContextInfo(context: "claude_desktop", responsibleHint: pathBasenameOrValue(value))
        }
        if value.localizedCaseInsensitiveContains("claude") {
            return LaunchContextInfo(context: "claude_code", responsibleHint: pathBasenameOrValue(value))
        }
        if value.localizedCaseInsensitiveContains("Terminal")
            || value.localizedCaseInsensitiveContains("iTerm") {
            return LaunchContextInfo(context: "terminal", responsibleHint: pathBasenameOrValue(value))
        }
        return nil
    }


    private static func productionAncestorProcessInfo() -> (bundleIDs: [String], processNames: [String]) {
        var bundleIDs: [String] = []
        var processNames: [String] = []
        var pid = getppid()
        var seen: Set<pid_t> = []
        for _ in 0..<12 {
            guard pid > 1, seen.insert(pid).inserted else { break }
            if let path = processPath(pid) {
                processNames.append(URL(fileURLWithPath: path).lastPathComponent)
                if let bundleID = bundleIDForProcessPath(path) {
                    bundleIDs.append(bundleID)
                }
            }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return (bundleIDs, processNames)
    }


    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }


    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return pid_t(info.pbi_ppid)
    }


    private static func bundleIDForProcessPath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/", options: .caseInsensitive) else { return nil }
        let appPath = String(path[..<range.upperBound]).replacingOccurrences(of: "/Contents/", with: "")
        let infoURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }


    private static func pathBasenameOrValue(_ value: String) -> String {
        value.contains("/") ? URL(fileURLWithPath: value).lastPathComponent : value
    }


}
