import Foundation

extension SetupDoctor {
    static func manualValidationCheck(
        approvals: [ManualValidationChannel: ManualValidationApproval],
        profile: DoctorProfile,
        storeHealth: ManualValidationStoreHealth,
        checks: [Check] = []
    ) -> Check {
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

        let legacyApprovals = requiredChannels
            .filter { approvals[$0]?.kind == .approved }
            .map(\.rawValue)
            .sorted()
        let legacySkips = requiredChannels
            .filter { approvals[$0]?.kind == .intentionallySkipped }
            .map(\.rawValue)
            .sorted()
        let storeEvidence: String
        switch storeHealth {
        case .ok:
            storeEvidence = "ok"
        case let .corrupt(reason):
            storeEvidence = "corrupt:\(reason)"
        }
        return check(
            id: "channels.manual_validation",
            domain: "channels",
            status: .fail,
            summary: "Required send-only channels are unavailable for unattended execution because setup and outcome readback are not programmatically verified.",
            evidence: [
                "profile": profile.rawValue,
                "required_channels": requiredChannels.map(\.rawValue).sorted().joined(separator: ","),
                "legacy_approvals_ignored": legacyApprovals.joined(separator: ","),
                "legacy_skips_ignored": legacySkips.joined(separator: ","),
                "store_health": storeEvidence,
                "terminal": "true",
                "human_intervention_required": "false",
                "human_intervention_requests": "0",
            ],
            remediationType: .none
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
            status: staged ? .pass : .warn,
            summary: staged
                ? "Key Commands mapping reference is staged; it does not qualify mapped Logic execution."
                : "Key Commands mapping reference is absent; staging cannot qualify mapped Logic execution.",
            evidence: [
                "preset_staged": String(staged),
                "unattended_qualification": "unaffected",
                "human_intervention_required": "false",
                "human_intervention_requests": "0",
            ],
            remediationType: .none
        )
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
        let observation = runtime.mcuPortReferenceProbe()
        let found = observation == .found
        let unavailable = !found
        let summary: String
        let probeOutcome: String
        let sourcePresent: String
        let referenceFound: String
        var evidence: [String: String] = [:]
        switch observation {
        case .found:
            summary = "Logic controller assignments reference the LogicProMCP MCU port."
            probeOutcome = "found"
            sourcePresent = "true"
            referenceFound = "true"
        case .confirmedAbsent:
            summary = "Logic controller assignments do not reference the LogicProMCP MCU port; MCU-only operations are unavailable for unattended execution."
            probeOutcome = "confirmed_absent"
            sourcePresent = "true"
            referenceFound = "false"
        case .sourceMissing:
            summary = "Logic controller assignments are absent; MCU-only operations are unavailable for unattended execution."
            probeOutcome = "source_missing"
            sourcePresent = "false"
            referenceFound = "unverified"
        case let .indeterminate(reason):
            summary = "Logic controller assignments could not be read; MCU-only operations are unavailable for unattended execution."
            probeOutcome = "indeterminate"
            sourcePresent = "true"
            referenceFound = "unverified"
            evidence = ["probe_failure_reason": reason]
        }
        evidence = evidence.merging([
            "assignment_probe": probeOutcome,
            "cs_file_present": sourcePresent,
            "mcu_port_reference_found": referenceFound,
            "terminal": String(unavailable),
            "human_intervention_required": "false",
            "human_intervention_requests": "0",
        ]) { current, _ in current }
        return check(
            id: "channels.mcu_wiring_hint",
            domain: "channels",
            status: unavailable ? .fail : .pass,
            summary: summary,
            evidence: evidence,
            remediationType: .none
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
            status: nativeAvailable ? .pass : .fail,
            summary: nativeAvailable
                ? "The native synthetic-click path is available (PostEvent granted); no fallback is used."
                : "No working click path: PostEvent is denied, and the external click-tool fallback "
                    + "was retired (a present tool is not a server click path).",
            evidence: [
                fallbackTool: (fallbackToolPresent ? "present" : "absent") + " (informational; retired as a server path)",
                "native_click": nativeAvailable ? "available" : "denied",
                "terminal": String(!nativeAvailable),
                "human_intervention_required": "false",
                "human_intervention_requests": "0",
            ],
            remediationType: .none
        )
    }


}
