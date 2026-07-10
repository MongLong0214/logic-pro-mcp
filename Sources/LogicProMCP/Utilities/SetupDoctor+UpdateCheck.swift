import Foundation

extension SetupDoctor {
    static func updateCheck(outcome: UpdateOutcome) -> Check {
        let installed = ServerConfig.serverVersion
        switch outcome {
        case let .found(rawLatest):
            let latest = Self.normalizeVersion(rawLatest)
            // An unparseable tag (e.g. "v", "-beta.1", "latest") normalizes to a value
            // with no numeric major. compareVersions would treat it as 0.0.0 and falsely
            // report "up to date" — so report skipped/parse_error instead of fabricating a pass.
            guard let major = latest.split(separator: ".").first, Int(major) != nil else {
                return check(
                    id: "updates.latest_release",
                    domain: "updates",
                    status: .skipped,
                    summary: "Could not parse the latest release version.",
                    evidence: ["reason": "parse_error"],
                    remediationType: .docs,
                    skipReason: .parseError
                )
            }
            let order = Self.compareVersions(installed, latest)
            if order >= 0 {
                return check(
                    id: "updates.latest_release",
                    domain: "updates",
                    status: .pass,
                    summary: "Installed version \(installed) is up to date.",
                    evidence: ["installed": installed, "latest": latest],
                    remediationType: .none
                )
            }
            return check(
                id: "updates.latest_release",
                domain: "updates",
                status: .warn,
                summary: "A newer release is available: \(latest) (installed \(installed)).",
                evidence: ["installed": installed, "latest": latest],
                remediationType: .command,
                remediationValueOverride: "brew upgrade logic-pro-mcp"
            )
        case .offline:
            return skippedUpdateCheck(reason: .offline)
        case .sourceUnavailable:
            return skippedUpdateCheck(reason: .sourceUnavailable)
        case .parseError:
            return skippedUpdateCheck(reason: .parseError)
        case .httpError:
            return skippedUpdateCheck(reason: .httpError)
        case .timeout:
            return skippedUpdateCheck(reason: .timeout)
        }
    }

    static func skippedUpdateCheck(reason: DoctorSkipReason) -> Check {
        check(
            id: "updates.latest_release",
            domain: "updates",
            status: .skipped,
            summary: "Could not check for the latest release.",
            evidence: ["reason": reason.rawValue],
            remediationType: .docs,
            skipReason: reason
        )
    }
}
