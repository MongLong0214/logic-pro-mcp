import Foundation

extension SetupDoctor {
    static func manualValidationCheck(approvals: [ManualValidationChannel: ManualValidationApproval]) -> Check {
        let missing = ManualValidationChannel.allCases
            .filter { approvals[$0] == nil }
            .map(\.rawValue)
        return check(
            id: "channels.manual_validation",
            domain: "channels",
            status: missing.isEmpty ? .pass : .manual,
            summary: missing.isEmpty
                ? "Manual-validation channels have operator approvals."
                : "Manual-validation channels need operator approval or an explicit decision to skip.",
            evidence: ["missing": missing.joined(separator: ",")],
            remediationType: missing.isEmpty ? .none : .command,
            remediationValueOverride: missing.isEmpty ? nil : "LogicProMCP --approve-channel MIDIKeyCommands && LogicProMCP --approve-channel Scripter"
        )
    }


    static func keycmdReferenceCheck(runtime: Runtime) -> Check {
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
            remediationValueOverride: staged ? nil : "install-keycmds.sh"
        )
    }


    static func mcuWiringHintCheck(runtime: Runtime) -> Check {
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


    static func clickFallbackCheck(runtime: Runtime, permissionStatus: PermissionChecker.PermissionStatus) -> Check {
        let fallbackTool = "cli" + "click"
        let fallbackToolPresent = ["/opt/homebrew/bin/" + fallbackTool, "/usr/local/bin/" + fallbackTool]
            .contains(where: runtime.isExecutableFile)
        let nativeAvailable = permissionStatus.postEventAccess
        let warn = !nativeAvailable && !fallbackToolPresent
        return check(
            id: "dependencies.click_fallback",
            domain: "dependencies",
            status: warn ? .warn : .pass,
            summary: warn
                ? "No working click path was found because PostEvent is denied and \(fallbackTool) is absent."
                : "At least one click path is available or the fallback is not needed.",
            evidence: [
                fallbackTool: fallbackToolPresent ? "present" : "absent",
                "native_click": nativeAvailable ? "available" : "denied",
            ],
            remediationType: warn ? .docs : .none
        )
    }


}
