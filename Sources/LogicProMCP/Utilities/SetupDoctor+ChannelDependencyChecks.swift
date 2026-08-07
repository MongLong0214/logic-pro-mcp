import Foundation

extension SetupDoctor {
    static func manualValidationCheck(
        approvals: [ManualValidationChannel: ManualValidationApproval],
        profile: DoctorProfile,
        storeHealth: ManualValidationStoreHealth,
        checks: [Check] = []
    ) -> Check {
        if case let .corrupt(reason) = storeHealth {
            return check(
                id: "channels.manual_validation",
                domain: "channels",
                status: .warn,
                summary: "Manual-validation store could not be read; existing operator decisions were not trusted.",
                evidence: ["store_health": "corrupt", "reason": reason],
                remediationType: .manual
            )
        }

        let requiredChannels = manualValidationChannelsRequired(for: profile)
        guard !requiredChannels.isEmpty else {
            return check(
                id: "channels.manual_validation",
                domain: "channels",
                status: .skipped,
                summary: "Manual-validation channels are not required for profile \(profile.rawValue).",
                evidence: ["profile": profile.rawValue],
                remediationType: .none,
                optional: true,
                skipReason: .profileNotRequired
            )
        }

        // #457: hold the approval prompt until the setup it attests exists. The fix
        // plan drops blocked checks, so a user is never told to assert readiness for
        // a channel whose staging has not happened — the approval would be a durable
        // false attestation that no later file check can repair.
        if let cause = blockingCause(for: "channels.manual_validation", checks: checks) {
            return check(
                id: "channels.manual_validation",
                domain: "channels",
                status: .skipped,
                summary: "Operator approval is held until Key Commands staging completes; approving first would attest setup that has not happened.",
                evidence: ["blocked_by": cause],
                remediationType: .docs,
                blockedBy: cause
            )
        }

        let missing = requiredChannels
            .filter { approvals[$0]?.kind != .approved && approvals[$0]?.kind != .intentionallySkipped }
            .map(\.rawValue)
        let intentionallySkipped = requiredChannels
            .filter { approvals[$0]?.kind == .intentionallySkipped }
            .map(\.rawValue)
        var evidence = ["missing": missing.joined(separator: ","), "profile": profile.rawValue]
        if !intentionallySkipped.isEmpty {
            evidence["intentionally_skipped"] = intentionallySkipped.joined(separator: ",")
        }
        if missing.isEmpty && !intentionallySkipped.isEmpty {
            return check(
                id: "channels.manual_validation",
                domain: "channels",
                status: .skipped,
                summary: "Manual-validation channels were explicitly skipped by the operator; live readiness is not claimed for those channels.",
                evidence: evidence,
                remediationType: .none,
                skipReason: .intentionallySkipped
            )
        }
        return check(
            id: "channels.manual_validation",
            domain: "channels",
            status: missing.isEmpty ? .pass : .manual,
            summary: missing.isEmpty
                ? "Manual-validation channels have operator approvals or explicit skip decisions."
                : "Manual-validation channels need operator approval or an explicit decision to skip.",
            evidence: evidence,
            remediationType: missing.isEmpty ? .none : .command,
            remediationValueOverride: missing.isEmpty ? nil : "LogicProMCP --approve-channel MIDIKeyCommands && LogicProMCP --approve-channel Scripter"
        )
    }


    static func keycmdReferenceCheck(runtime: Runtime, profile: DoctorProfile) -> Check {
        guard isProfileRequired("channels.keycmd_reference", profile: profile) else {
            return check(
                id: "channels.keycmd_reference",
                domain: "channels",
                status: .skipped,
                summary: "Key Commands preset is not required for profile \(profile.rawValue).",
                evidence: ["profile": profile.rawValue],
                remediationType: .none,
                optional: true,
                skipReason: .profileNotRequired
            )
        }
        let staged = runtime.keyCommandsPresetStaged()
        return check(
            id: "channels.keycmd_reference",
            domain: "channels",
            status: staged ? .pass : .manual,
            summary: staged
                ? "Key Commands preset is staged."
                : "Key Commands preset is not staged; ignore this if MIDIKeyCommands-only ops are unused.",
            evidence: ["preset_staged": String(staged)],
            remediationType: staged ? .none : .command,
            remediationValueOverride: staged ? nil : keyCommandsRemediation(runtime: runtime)
        )
    }

    // #456: Homebrew installs install-keycmds.sh into the formula pkgshare, not on
    // PATH, so printing the bare script name hands the user a command they cannot
    // run — and fetching the script alone fails on its sibling keycmd-preset.plist.
    // The share dir is already resolved for the install checks, so the remediation
    // is derived from that same probe and stays runnable wherever the package put
    // it. Only an unresolved share dir falls back to the bare name, and it says so.
    static func keyCommandsRemediation(runtime: Runtime) -> String {
        switch runtime.shareDirProbe() {
        case let .complete(path, _), let .missing(path, _, _), let .invalid(path, _):
            return "\(path)/install-keycmds.sh"
        case .unresolved:
            return "install-keycmds.sh (share dir unresolved; set LOGIC_PRO_MCP_SHARE_DIR or reinstall)"
        }
    }


    static func mcuWiringHintCheck(runtime: Runtime, profile: DoctorProfile) -> Check {
        guard isProfileRequired("channels.mcu_wiring_hint", profile: profile) else {
            return check(
                id: "channels.mcu_wiring_hint",
                domain: "channels",
                status: .skipped,
                summary: "MCU wiring hint is not required for profile \(profile.rawValue).",
                evidence: ["profile": profile.rawValue],
                remediationType: .none,
                optional: true,
                skipReason: .profileNotRequired
            )
        }
        let found = runtime.mcuPortReferenceFound()
        return check(
            id: "channels.mcu_wiring_hint",
            domain: "channels",
            status: found == true ? .pass : .manual,
            summary: found == true
                ? "Logic controller assignments reference the LogicProMCP MCU port."
                : "Logic controller assignments do not confirm the LogicProMCP MCU port; ignore this if MCU-only ops are unused.",
            evidence: [
                "cs_file_present": found == nil ? "false" : "true",
                "mcu_port_reference_found": String(found == true),
            ],
            remediationType: found == true ? .none : .docs
        )
    }

    private static func manualValidationChannelsRequired(for profile: DoctorProfile) -> [ManualValidationChannel] {
        switch profile {
        case .core, .mixer, .auto:
            return []
        case .keycmd:
            return [.midiKeyCommands]
        case .legacyScripter:
            return [.scripter]
        case .full:
            return ManualValidationChannel.allCases
        }
    }


    static func clickFallbackCheck(runtime: Runtime, permissionStatus: PermissionChecker.PermissionStatus) -> Check {
        // The external click-tool fallback was RETIRED by the coordinate-free
        // campaign: the server's only synthetic-click path is the native CGEvent
        // post, which requires PostEvent access. The check id is kept for schema
        // stability, but a present external tool no longer counts as a server
        // click path (that would be a false-green about server capability); its
        // presence is still reported as informational evidence for operators.
        let fallbackTool = "cli" + "click"
        let fallbackToolPresent = ["/opt/homebrew/bin/" + fallbackTool, "/usr/local/bin/" + fallbackTool]
            .contains(where: runtime.isExecutableFile)
        let nativeAvailable = permissionStatus.postEventAccess
        return check(
            id: "dependencies.click_fallback",
            domain: "dependencies",
            status: nativeAvailable ? .pass : .warn,
            summary: nativeAvailable
                ? "The native synthetic-click path is available (PostEvent granted); no fallback is used."
                : "No working click path: PostEvent is denied, and the external click-tool fallback "
                    + "was retired (a present tool is not a server click path).",
            evidence: [
                fallbackTool: (fallbackToolPresent ? "present" : "absent") + " (informational; retired as a server path)",
                "native_click": nativeAvailable ? "available" : "denied",
            ],
            remediationType: nativeAvailable ? .none : .docs
        )
    }


}
