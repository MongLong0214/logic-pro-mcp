import Foundation

extension SetupDoctor {
    static func macOSVersionCheck(runtime: Runtime) -> Check {
        let minimumMajor = 14 // Package.swift: platforms: [.macOS(.v14)]
        guard let version = runtime.macOSVersion() else {
            return check(
                id: "system.macos_version",
                domain: "system",
                status: .skipped,
                summary: "macOS version could not be determined.",
                evidence: ["reason": "version_unreadable"],
                remediationType: .docs,
                skipReason: .versionUnreadable
            )
        }
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        if version.majorVersion >= minimumMajor {
            return check(
                id: "system.macos_version",
                domain: "system",
                status: .pass,
                summary: "macOS \(versionString) meets the minimum (\(minimumMajor)+).",
                evidence: ["version": versionString, "minimum_major": String(minimumMajor)],
                remediationType: .none
            )
        }
        return check(
            id: "system.macos_version",
            domain: "system",
            status: .fail,
            summary: "macOS \(versionString) is below the required minimum (\(minimumMajor)+).",
            evidence: ["version": versionString, "minimum_major": String(minimumMajor)],
            remediationType: .docs
        )
    }


    static func logicInstallationCheck(logicApps apps: [LogicAppInfo]) -> Check {
        let supported = supportedLogicApps(apps)
        guard !supported.isEmpty else {
            return check(
                id: "logic.installation",
                domain: "logic",
                status: .fail,
                summary: "Logic Pro.app was not found in /Applications or ~/Applications (desktop or Creator Studio).",
                evidence: ["path": "not_found"],
                remediationType: .docs
            )
        }
        if Self.unshippedVariantOnly(supported) {
            // Not "unreadable": the bundle read fine and is a Logic this release does not ship for.
            // Reporting it as unreadable sent the reader looking for a permissions problem.
            return check(
                id: "logic.installation",
                domain: "logic",
                status: .fail,
                summary: "Only Logic Pro Creator Studio was found. This release ships for desktop "
                    + "Logic Pro only; Creator Studio is recognised so it is not driven by mistake.",
                evidence: ["reason": "unshipped_variant_only",
                           "path": supported.map(\.path).joined(separator: ",")],
                remediationType: .docs
            )
        }
        guard let primary = preferredReadableLogicApp(supported), let version = primary.version else {
            return check(
                id: "logic.installation",
                domain: "logic",
                status: .skipped,
                summary: "Logic Pro.app exists but its version could not be read.",
                evidence: ["reason": "bundle_unreadable", "path": supported.map(\.path).joined(separator: ",")],
                remediationType: .docs,
                skipReason: .bundleUnreadable
            )
        }
        var evidence = [
            "version": version,
            "bundle_id": primary.bundleID ?? "",
            "path": primary.path,
        ]
        if let variant = logicVariantLabel(for: primary.bundleID) {
            evidence["variant"] = variant
        }
        let additional = supported.filter { $0.path != primary.path || $0.bundleID != primary.bundleID }
        if !additional.isEmpty {
            evidence["second_copy"] = "present"
            evidence["additional_variants"] = additional.compactMap(\.bundleID).joined(separator: ",")
        }
        return check(
            id: "logic.installation",
            domain: "logic",
            status: .pass,
            summary: "Logic Pro \(version) is installed.",
            evidence: evidence,
            remediationType: .none
        )
    }


    static func logicVersionSupportCheck(logicApps: [LogicAppInfo], checks: [Check]) -> Check {
        if let cause = blockingCause(for: "logic.version_support", checks: checks) {
            return check(
                id: "logic.version_support",
                domain: "logic",
                status: .skipped,
                summary: "Logic Pro version support cannot be checked until Logic Pro installation is readable.",
                evidence: [:],
                remediationType: .docs,
                blockedBy: cause
            )
        }
        let version = Self.preferredReadableLogicApp(logicApps)?.version ?? ""
        let minimum = LogicProSupport.minimumSupportedLogicVersion
        let latest = LogicProSupport.latestValidatedLogicVersion
        let status: CheckStatus
        let summary: String
        if Self.compareVersions(version, minimum) < 0 {
            status = .fail
            summary = "Logic Pro \(version) is below the supported floor \(minimum)."
        } else if Self.compareVersions(version, latest) == 0 {
            status = .pass
            summary = "Logic Pro \(version) matches the latest validated version."
        } else {
            status = .warn
            summary = "Logic Pro \(version) is outside the latest validated version \(latest)."
        }
        return check(
            id: "logic.version_support",
            domain: "logic",
            status: status,
            summary: summary,
            evidence: [
                "detected_version": version,
                "minimum_supported": minimum,
                "latest_validated": latest,
            ],
            remediationType: status == .pass ? .none : .docs
        )
    }


    static func logicApplicationStateCheck(runtime: Runtime) -> Check {
        let running = runtime.logicProRunning()
        let visible = running && runtime.logicProHasVisibleWindow()
        let status: CheckStatus = running ? (visible ? .pass : .warn) : .manual
        return check(
            id: "logic.application_state",
            domain: "logic",
            status: status,
            summary: logicApplicationSummary(running: running, visible: visible),
            evidence: ["running": String(running), "visible_window": String(visible)],
            remediationType: running ? (visible ? .none : .manual) : .manual
        )
    }


    static func logicBlockingDialogCheck(runtime: Runtime, checks: [Check]) -> Check {
        if let cause = blockingCause(for: "logic.blocking_dialog", checks: checks) {
            return check(
                id: "logic.blocking_dialog",
                domain: "logic",
                status: .skipped,
                summary: "Blocking-dialog scan skipped because a prerequisite is not passing.",
                evidence: [:],
                remediationType: .manual,
                blockedBy: cause
            )
        }
        guard let info = runtime.blockingDialogInfo() else {
            return check(
                id: "logic.blocking_dialog",
                domain: "logic",
                status: .pass,
                summary: "No blocking Logic Pro modal dialog was detected.",
                evidence: ["dialog_present": "false"],
                remediationType: .none
            )
        }
        return check(
            id: "logic.blocking_dialog",
            domain: "logic",
            status: .warn,
            summary: "Logic Pro has a blocking modal dialog.",
            evidence: [
                "dialog_present": "true",
                "dialog_title": info.title,
                "role": info.role,
                "buttons": info.buttonTitles.joined(separator: ","),
                "recovery_action": info.recoveryAction,
            ],
            remediationType: .manual
        )
    }


    static func logicApplicationSummary(running: Bool, visible: Bool) -> String {
        if visible {
            return "Logic Pro is running with a visible window."
        }
        if running {
            return "Logic Pro is running, but no visible project window was detected."
        }
        return "Logic Pro is not running; live setup checks need manual validation."
    }


}
