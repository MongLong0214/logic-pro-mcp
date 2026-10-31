import Foundation

extension SetupDoctor {
    static func claudeRegistrationCheck(registration: ClaudeRegistration, clientProfile: ClientProfile) -> Check {
        guard clientProfile == .claudeCode else {
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .skipped,
                summary: "Claude Code registration is not required for client profile \(clientProfile.rawValue).",
                evidence: ["client_profile": clientProfile.rawValue],
                remediationType: .none,
                optional: true,
                skipReason: .clientNotSelected
            )
        }
        // Read-only registration detection: inspect the Claude Code config file
        // directly instead of shelling out to `claude mcp list`. `claude mcp list`
        // health-checks every registered MCP server, which spawns the registered
        // LogicProMCP binary over stdio (creating CoreMIDI virtual ports + AX
        // pollers) — a real side effect that violates the doctor's documented
        // "read-only / run-before-startup" contract, and one the old 1.5s SIGKILL
        // could orphan. Reading the config is fast, non-mutating, and spawns nothing.
        switch registration {
        case let .registered(command, _):
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .pass,
                summary: "Claude Code MCP registration found.",
                evidence: [
                    "registered": "true",
                    "command": command,
                    "match_kind": ClaudeRegistrationMatchKind.nameAndCommand.rawValue,
                ],
                remediationType: .none
            )
        case let .nameOnly(name, command):
            return partialClaudeRegistrationCheck(
                name: name,
                command: command,
                matchKind: .nameOnly,
                summary: "Claude Code MCP registration name matches, but its command does not target LogicProMCP."
            )
        case let .commandOnly(name, command):
            return partialClaudeRegistrationCheck(
                name: name,
                command: command,
                matchKind: .commandOnly,
                summary: "A Claude Code MCP entry targets LogicProMCP, but its server name does not match logic-pro."
            )
        case .notRegistered:
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .fail,
                summary: "Claude Code MCP registration was not found.",
                evidence: terminalRegistrationEvidence([
                    "registered": "false",
                    "match_kind": ClaudeRegistrationMatchKind.none.rawValue,
                ]),
                remediationType: .none
            )
        case let .configUnavailable(reason):
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .fail,
                summary: "Claude Code registration could not be checked because the Claude config could not be read.",
                evidence: terminalRegistrationEvidence(["reason": reason]),
                remediationType: .none
            )
        }
    }

    static func partialClaudeRegistrationCheck(
        name: String,
        command: String,
        matchKind: ClaudeRegistrationMatchKind,
        summary: String
    ) -> Check {
        check(
            id: "mcp.claude_code_registration",
            domain: "mcp",
            status: .fail,
            summary: summary,
            evidence: terminalRegistrationEvidence([
                "registered": "false",
                "match_kind": matchKind.rawValue,
                "server_name": name,
                "command": command,
            ]),
            remediationType: .none
        )
    }


    static func mcpRegistrationTargetCheck(
        registration: ClaudeRegistration,
        runtime: Runtime,
        checks: [Check],
        staticVersionForPath: (String) -> StaticVersionResult
        ,
        clientProfile: ClientProfile
    ) -> Check {
        guard clientProfile == .claudeCode else {
            return check(
                id: "mcp.registration_target",
                domain: "mcp",
                status: .skipped,
                summary: "Claude Code registration target is not required for client profile \(clientProfile.rawValue).",
                evidence: ["client_profile": clientProfile.rawValue],
                remediationType: .none,
                optional: true,
                skipReason: .clientNotSelected
            )
        }
        if let cause = blockingCause(for: "mcp.registration_target", checks: checks) {
            return check(
                id: "mcp.registration_target",
                domain: "mcp",
                status: .skipped,
                summary: "Registered MCP target cannot be checked until Claude Code registration is present.",
                evidence: [:],
                remediationType: .none,
                blockedBy: cause
            )
        }
        guard case let .registered(command, environment) = registration else {
            return check(
                id: "mcp.registration_target",
                domain: "mcp",
                status: .skipped,
                summary: "Registered MCP target cannot be checked.",
                evidence: ["reason": "registration_unavailable"],
                remediationType: .none,
                blockedBy: "mcp.claude_code_registration"
            )
        }
        let resolution = resolveRegisteredCommand(command, runtime: runtime)
        guard let resolvedCommand = resolution.path else {
            return check(
                id: "mcp.registration_target",
                domain: "mcp",
                status: .fail,
                summary: "Claude Code registration uses an unresolved PATH-dependent command; the MCP client's launch PATH may differ.",
                evidence: terminalRegistrationEvidence([
                    "command_path": command,
                    "reason": "path_dependent_unresolved",
                ]),
                remediationType: .none
            )
        }
        let exists = runtime.fileExistsAtPath(resolvedCommand)
        let regular = exists && runtime.isRegularFile(resolvedCommand)
        let executable = regular && runtime.isExecutableFile(resolvedCommand)
        var evidence = [
            "command_path": command,
            "resolved_path": resolvedCommand,
            "resolution_basis": resolution.basis,
            "regular_file": String(regular),
            "executable": String(executable),
            "running_version": ServerConfig.serverVersion,
        ]
        var shareDirMissing = false
        if let shareDir = environment["LOGIC_PRO_MCP_SHARE_DIR"], !shareDir.isEmpty {
            let valid = runtime.isDirectory(shareDir)
            evidence["share_dir"] = valid ? "present" : "missing"
            shareDirMissing = !valid
        }
        var versionMismatch = false
        if executable, case let .version(version) = staticVersionForPath(resolvedCommand) {
            evidence["registered_version"] = version
            evidence["version_match"] = String(version == ServerConfig.serverVersion)
            versionMismatch = version != ServerConfig.serverVersion
        } else {
            evidence["registered_version"] = "indeterminate"
        }
        let warn = !exists || !regular || !executable || shareDirMissing || versionMismatch
        return check(
            id: "mcp.registration_target",
            domain: "mcp",
            status: warn ? .fail : .pass,
            summary: warn
                ? "Claude Code registration target is missing, not a regular executable, has a missing share dir, or is stale."
                : "Claude Code registration target is present and executable. If it was resolved from PATH, this report used the doctor's environment; the MCP client's spawn PATH may differ.",
            evidence: warn ? terminalRegistrationEvidence(evidence) : evidence,
            remediationType: .none
        )
    }


    static func claudeDesktopRegistrationCheck(runtime: Runtime, clientProfile: ClientProfile) -> Check {
        guard clientProfile == .claudeDesktop else {
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .skipped,
                summary: "Claude Desktop registration is not required for client profile \(clientProfile.rawValue).",
                evidence: ["client_profile": clientProfile.rawValue],
                remediationType: .none,
                optional: true,
                skipReason: .clientNotSelected
            )
        }
        switch runtime.readClaudeDesktopRegistration() {
        case .registered:
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .pass,
                summary: "Claude Desktop MCP registration found.",
                evidence: [
                    "config_present": "true",
                    "registered": "true",
                    "match_kind": ClaudeRegistrationMatchKind.nameAndCommand.rawValue,
                ],
                remediationType: .none
            )
        case let .nameOnly(name, command):
            return partialClaudeDesktopRegistrationCheck(
                name: name,
                command: command,
                matchKind: .nameOnly,
                summary: "Claude Desktop registration name matches, but its command does not target LogicProMCP."
            )
        case let .commandOnly(name, command):
            return partialClaudeDesktopRegistrationCheck(
                name: name,
                command: command,
                matchKind: .commandOnly,
                summary: "A Claude Desktop entry targets LogicProMCP, but its server name does not match logic-pro."
            )
        case .notRegistered:
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .fail,
                summary: "Claude Desktop config exists but LogicProMCP is not registered.",
                evidence: terminalRegistrationEvidence([
                    "config_present": "true",
                    "registered": "false",
                    "match_kind": ClaudeRegistrationMatchKind.none.rawValue,
                ]),
                remediationType: .none
            )
        case let .configUnavailable(reason):
            let absent = reason == "config_absent"
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .fail,
                summary: absent
                    ? "Claude Desktop config is absent."
                    : "Claude Desktop config could not be read.",
                evidence: terminalRegistrationEvidence([
                    "config_present": absent ? "false" : "true",
                    "reason": reason,
                ]),
                remediationType: .none
            )
        }
    }

    static func partialClaudeDesktopRegistrationCheck(
        name: String,
        command: String,
        matchKind: ClaudeRegistrationMatchKind,
        summary: String
    ) -> Check {
        check(
            id: "mcp.claude_desktop_registration",
            domain: "mcp",
            status: .fail,
            summary: summary,
            evidence: terminalRegistrationEvidence([
                "config_present": "true",
                "registered": "false",
                "match_kind": matchKind.rawValue,
                "server_name": name,
                "command": command,
            ]),
            remediationType: .none
        )
    }

    private static func terminalRegistrationEvidence(
        _ evidence: [String: String]
    ) -> [String: String] {
        var result = evidence
        result["terminal"] = "true"
        result["human_intervention_required"] = "false"
        result["human_intervention_requests"] = "0"
        return result
    }

    struct RegisteredCommandResolution: Equatable, Sendable {
        let path: String?
        let basis: String
    }

    static func resolveRegisteredCommand(_ command: String, runtime: Runtime) -> RegisteredCommandResolution {
        if command.hasPrefix("/") {
            return RegisteredCommandResolution(path: command, basis: "absolute")
        }
        guard !command.contains("/") else {
            return RegisteredCommandResolution(path: nil, basis: "relative_path_unresolved")
        }
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = "\(prefix)/\(command)"
            if runtime.fileExistsAtPath(candidate), runtime.isRegularFile(candidate) {
                return RegisteredCommandResolution(path: candidate, basis: "canonical_path")
            }
        }
        guard let output = runtime.runCommand("/usr/bin/which", [command]).output,
              output.exitCode == 0 else {
            return RegisteredCommandResolution(path: nil, basis: "doctor_path")
        }
        let resolved = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.hasPrefix("/") else {
            return RegisteredCommandResolution(path: nil, basis: "doctor_path")
        }
        return RegisteredCommandResolution(path: resolved, basis: "doctor_path")
    }


}
