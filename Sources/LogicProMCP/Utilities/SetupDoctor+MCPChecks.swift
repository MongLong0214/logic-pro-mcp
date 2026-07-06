import Foundation

extension SetupDoctor {
    static func claudeRegistrationCheck(registration: ClaudeRegistration) -> Check {
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
                evidence: ["registered": "true", "command": command],
                remediationType: .none
            )
        case .notRegistered:
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .warn,
                summary: "Claude Code MCP registration was not found.",
                evidence: ["registered": "false"],
                remediationType: .command,
                remediationValueOverride: "claude mcp add --scope user logic-pro -- LogicProMCP"
            )
        case let .configUnavailable(reason):
            return check(
                id: "mcp.claude_code_registration",
                domain: "mcp",
                status: .manual,
                summary: "Claude Code registration could not be checked because the Claude config could not be read.",
                evidence: ["reason": reason],
                remediationType: .manual
            )
        }
    }


    static func mcpRegistrationTargetCheck(
        registration: ClaudeRegistration,
        runtime: Runtime,
        checks: [Check],
        staticVersionForPath: (String) -> StaticVersionResult
    ) -> Check {
        if let cause = blockingCause(for: "mcp.registration_target", checks: checks) {
            return check(
                id: "mcp.registration_target",
                domain: "mcp",
                status: .skipped,
                summary: "Registered MCP target cannot be checked until Claude Code registration is present.",
                evidence: [:],
                remediationType: .command,
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
                remediationType: .command,
                blockedBy: "mcp.claude_code_registration"
            )
        }
        guard command.hasPrefix("/") else {
            return check(
                id: "mcp.registration_target",
                domain: "mcp",
                status: .skipped,
                summary: "Claude Code registration uses a relative or PATH-dependent command; install.binary_inventory covers canonical binary staleness.",
                evidence: ["command_path": command, "reason": "relative_command"],
                remediationType: .command,
                remediationValueOverride: "claude mcp add --scope user logic-pro -- LogicProMCP"
            )
        }
        let exists = runtime.fileExistsAtPath(command)
        let regular = exists && runtime.isRegularFile(command)
        let executable = regular && runtime.isExecutableFile(command)
        var evidence = [
            "command_path": command,
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
        if executable, case let .version(version) = staticVersionForPath(command) {
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
            status: warn ? .warn : .pass,
            summary: warn
                ? "Claude Code registration target is missing, not a regular executable, has a missing share dir, or is stale."
                : "Claude Code registration target is present and executable.",
            evidence: evidence,
            remediationType: warn ? .command : .none,
            remediationValueOverride: warn ? "claude mcp add --scope user logic-pro -- LogicProMCP" : nil
        )
    }


    static func claudeDesktopRegistrationCheck(runtime: Runtime) -> Check {
        switch runtime.readClaudeDesktopRegistration() {
        case .registered:
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .pass,
                summary: "Claude Desktop MCP registration found.",
                evidence: ["config_present": "true", "registered": "true"],
                remediationType: .none
            )
        case .notRegistered:
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .warn,
                summary: "Claude Desktop config exists but LogicProMCP is not registered.",
                evidence: ["config_present": "true", "registered": "false"],
                remediationType: .manual
            )
        case let .configUnavailable(reason):
            let absent = reason == "config_absent"
            return check(
                id: "mcp.claude_desktop_registration",
                domain: "mcp",
                status: .skipped,
                summary: absent
                    ? "Claude Desktop not configured (optional)."
                    : "Claude Desktop config could not be read.",
                evidence: ["config_present": absent ? "false" : "true", "reason": reason],
                remediationType: absent ? .none : .manual,
                optional: absent
            )
        }
    }


}
