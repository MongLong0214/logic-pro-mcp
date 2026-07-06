import Foundation

extension SetupDoctor {
    static func installSourceCheck(installSource: InstallSource, executablePath: String?) -> Check {
        let status: CheckStatus = installSource == .unknown ? .warn : .pass
        return check(
            id: "install.source",
            domain: "install",
            status: status,
            summary: installSource == .unknown ? "Install source is unknown or manual." : "Install source detected as \(installSource.rawValue).",
            evidence: ["install_source": installSource.rawValue, "path": executablePath ?? "<nil>"],
            remediationType: installSource == .unknown ? .docs : .none
        )
    }


    static func installBinaryInventoryCheck(
        executablePath: String?,
        runtime: Runtime,
        claudeRegistration: ClaudeRegistration,
        staticVersionForPath: (String) -> StaticVersionResult
    ) -> Check {
        let runningVersion = ServerConfig.serverVersion
        let candidates = binaryInventoryCandidates(
            executablePath: executablePath,
            runtime: runtime,
            claudeRegistration: claudeRegistration
        )
        var rendered: [String] = []
        var stale = false
        var indeterminateStaleRisk = false
        var indeterminate: [String] = []
        for path in candidates {
            let arch = runtime.runCommand("/usr/bin/lipo", ["-archs", path])?.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isRunningExecutable = standardized(path) == standardized(executablePath ?? "")
            switch staticVersionForPath(path) {
            case let .version(version):
                rendered.append("\(path):\(arch?.isEmpty == false ? arch! : "unknown"):\(version)")
                if !isRunningExecutable, version != runningVersion {
                    stale = true
                }
            case let .indeterminate(versions):
                rendered.append("\(path):\(arch?.isEmpty == false ? arch! : "unknown"):indeterminate")
                indeterminate.append(versions.isEmpty ? path : "\(path)(\(versions.joined(separator: ",")))")
                if !isRunningExecutable {
                    indeterminateStaleRisk = true
                }
            }
        }
        let warn = stale || indeterminateStaleRisk
        var evidence = [
            "running_version": runningVersion,
            "candidates": rendered.isEmpty ? "none" : rendered.joined(separator: " | "),
        ]
        if stale { evidence["stale"] = "true" }
        if !indeterminate.isEmpty { evidence["indeterminate"] = indeterminate.joined(separator: ",") }
        return check(
            id: "install.binary_inventory",
            domain: "install",
            status: warn ? .warn : .pass,
            summary: binaryInventorySummary(stale: stale, indeterminateStaleRisk: indeterminateStaleRisk),
            evidence: evidence,
            remediationType: warn ? .command : .none,
            remediationValueOverride: warn ? "brew upgrade logic-pro-mcp" : nil
        )
    }


    static func binaryInventorySummary(stale: Bool, indeterminateStaleRisk: Bool) -> String {
        if stale {
            return "A canonical LogicProMCP binary has a different static version than the running doctor."
        }
        if indeterminateStaleRisk {
            return "A canonical LogicProMCP binary's static version could not be determined; staleness cannot be ruled out."
        }
        return "Canonical LogicProMCP binary inventory found no stale installed binary."
    }


    static func installShareDirCheck(runtime: Runtime) -> Check {
        switch runtime.shareDirProbe() {
        case let .complete(path, source):
            return check(
                id: "install.share_dir",
                domain: "install",
                status: .pass,
                summary: "Installed share directory contains the expected helper assets.",
                evidence: shareDirEvidence(path: path, source: source),
                remediationType: .none
            )
        case let .missing(path, source, files):
            return check(
                id: "install.share_dir",
                domain: "install",
                status: .warn,
                summary: "Installed share directory is missing helper assets.",
                evidence: shareDirEvidence(path: path, source: source, extra: ["missing_files": files.joined(separator: ",")]),
                remediationType: .command,
                remediationValueOverride: "brew reinstall logic-pro-mcp"
            )
        case .unresolved:
            return check(
                id: "install.share_dir",
                domain: "install",
                status: .skipped,
                summary: "Share directory could not be resolved; source builds may not have packaged helper assets.",
                evidence: ["reason": "share_dir_unresolved"],
                remediationType: .docs
            )
        case let .invalid(path, source):
            return check(
                id: "install.share_dir",
                domain: "install",
                status: .skipped,
                summary: "Resolved share directory is not a directory.",
                evidence: shareDirEvidence(path: path, source: source, extra: ["reason": "share_dir_invalid"]),
                remediationType: .docs
            )
        }
    }


    static func shareDirEvidence(
        path: String,
        source: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var evidence = ["resolved_dir": shareDirLabel(path: path, source: source), "source": source]
        for (key, value) in extra {
            evidence[key] = value
        }
        return evidence
    }


    static func shareDirLabel(path: String, source: String) -> String {
        if source == "registered_env" { return "registered_env" }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        return basename.isEmpty ? source : "\(source):\(basename)"
    }


    static func detectInstallSource(executablePath: String?, runtime: Runtime) -> InstallSource {
        // Match a real `.build` path component (SwiftPM's canonical build dir),
        // not a bare substring — a path like `/Users/x/my.build/release/LogicProMCP`
        // must NOT be misclassified as source_build.
        if let executablePath, URL(fileURLWithPath: executablePath).pathComponents.contains(".build") {
            return .sourceBuild
        }

        // Probe brew at canonical absolute paths instead of resolving via PATH.
        // A launchd/minimal-supervisor env often has a stripped PATH without
        // /opt/homebrew/bin, which would otherwise make a genuine Homebrew install
        // fall through to .releaseBinary based purely on ambient PATH.
        for brewPath in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if let brew = runtime.runCommand(brewPath, ["list", "--versions", "logic-pro-mcp"]),
               brew.exitCode == 0,
               brew.stdout.contains("logic-pro-mcp") {
                return .homebrew
            }
        }

        guard let executablePath else { return .unknown }
        if executablePath.hasPrefix("/usr/local/bin/") || executablePath.hasPrefix("/opt/homebrew/bin/") {
            return .releaseBinary
        }
        return .unknown
    }


    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }


    static func binaryInventoryCandidates(
        executablePath: String?,
        runtime: Runtime,
        claudeRegistration: ClaudeRegistration
    ) -> [String] {
        var paths = ["/opt/homebrew/bin/LogicProMCP", "/usr/local/bin/LogicProMCP"]
        if case let .registered(command, _) = claudeRegistration, command.hasPrefix("/") {
            paths.append(command)
        }
        var seen: Set<String> = []
        return paths.compactMap { path in
            let clean = standardized(path)
            guard seen.insert(clean).inserted, runtime.isRegularFile(clean) else { return nil }
            return clean
        }
    }


}
