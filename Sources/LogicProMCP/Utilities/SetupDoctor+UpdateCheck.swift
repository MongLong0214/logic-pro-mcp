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
                    remediationType: .docs
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
        case .offline, .sourceUnavailable, .parseError, .httpError, .timeout:
            // Redaction (AC-6.4): evidence carries ONLY an enumerated reason — never
            // stderr, env, tokened URLs, or headers. The lookup is unauthenticated.
            return check(
                id: "updates.latest_release",
                domain: "updates",
                status: .skipped,
                summary: "Could not check for the latest release.",
                evidence: ["reason": updateReason(outcome)],
                remediationType: .docs
            )
        }
    }


    static func updateReason(_ outcome: UpdateOutcome) -> String {
        switch outcome {
        case .found:
            return "found"
        case .offline:
            return "offline"
        case .sourceUnavailable:
            return "source_unavailable"
        case .parseError:
            return "parse_error"
        case .httpError:
            return "http_error"
        case .timeout:
            return "timeout"
        }
    }


}
