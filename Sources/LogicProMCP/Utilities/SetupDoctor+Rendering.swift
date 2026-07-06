import Foundation

extension SetupDoctor {
    enum OutputMode: Sendable {
        case `default`
        case verbose
        case quiet
    }

    static func renderHuman(
        _ report: Report,
        mode: OutputMode = .default,
        useColor: Bool = false
    ) -> String {
        var lines: [String] = []
        // Headline (next action) + summary roll-up lead the report in every mode.
        lines.append(report.headline)
        lines.append(renderSummaryLine(report.summary))
        // Existing v1 header block is preserved so the non-TTY human shape stays
        // a back-compatible superset (a scraper grepping these lines keeps working).
        lines.append("Logic Pro MCP doctor")
        lines.append("schema: \(report.schema)")
        lines.append("status: \(report.status.rawValue)")
        lines.append("version: \(report.version)")
        lines.append("install_source: \(report.installSource.rawValue)")
        appendFixPlan(report, to: &lines, useColor: useColor)
        lines.append("")
        for check in report.checks {
            if mode == .quiet, check.status == .pass {
                continue
            }
            lines.append(renderCheckLine(check, useColor: useColor))
            if check.remediation.type != .none {
                lines.append("  \u{2192} \(check.remediation.value)")
            }
            if mode == .verbose {
                for key in check.evidence.keys.sorted() {
                    lines.append("    \(key)=\(check.evidence[key] ?? "")")
                }
                lines.append("    duration_ms: \(formatDuration(check.durationMs))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func appendFixPlan(_ report: Report, to lines: inout [String], useColor: Bool) {
        guard !report.fixPlan.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        var seenRemediations: Set<String> = []
        lines.append("Fix plan:")
        for (offset, id) in report.fixPlan.enumerated() {
            guard let check = byID[id] else { continue }
            let index = offset + 1
            let tag = "[\(check.status.rawValue)]"
            let prefix = useColor ? coloredTag(tag, status: check.status) : tag
            var line = "\(index). \(prefix) \(check.id) — \(check.summary)"
            if check.remediation.type != .none, !check.remediation.value.isEmpty,
               seenRemediations.insert(check.remediation.value).inserted {
                line += " (\(check.remediation.value))"
            }
            lines.append(line)
        }
    }

    private static func coloredTag(_ tag: String, status: CheckStatus) -> String {
        let reset = "\u{1B}[0m"
        return "\(colorSymbol(for: status).1)\(tag)\(reset)"
    }

    private static func renderSummaryLine(_ summary: Summary) -> String {
        var parts: [String] = ["\(summary.passed) passed"]
        if summary.failed > 0 {
            parts.append("\(summary.failed) failed")
        }
        if summary.warnings > 0 {
            parts.append("\(summary.warnings) warning\(summary.warnings == 1 ? "" : "s")")
        }
        if summary.manual > 0 {
            parts.append("\(summary.manual) manual")
        }
        if summary.skipped > 0 {
            parts.append("\(summary.skipped) skipped")
        }
        return "summary: \(parts.joined(separator: ", ")) (\(formatDuration(summary.durationMs))ms)"
    }

    private static func renderCheckLine(_ check: Check, useColor: Bool) -> String {
        guard useColor else {
            // Plain ASCII fallback (non-TTY / NO_COLOR): byte-clean for pipes & CI.
            return "[\(check.status.rawValue)] \(check.id) - \(check.summary)"
        }
        let reset = "\u{1B}[0m"
        let (symbol, color) = colorSymbol(for: check.status)
        return "\(color)\(symbol)\(reset) \(check.id) - \(check.summary)"
    }

    /// (symbol, ANSI color prefix) per status. Only used when color is enabled.
    private static func colorSymbol(for status: CheckStatus) -> (String, String) {
        switch status {
        case .pass:
            return ("\u{2713}", "\u{1B}[32m")   // ✓ green
        case .fail:
            return ("\u{2717}", "\u{1B}[31m")   // ✗ red
        case .warn:
            return ("\u{26A0}", "\u{1B}[33m")   // ⚠ yellow
        case .manual:
            return ("\u{2022}", "\u{1B}[34m")   // • blue
        case .skipped:
            return ("\u{2205}", "\u{1B}[90m")   // ∅ grey
        }
    }

    private static func formatDuration(_ ms: Double) -> String {
        String(Int(ms.rounded()))
    }

    static func shouldExitWithFailure(_ report: Report) -> Bool {
        report.status == .failed
    }

    static func strictExitCode(_ report: Report) -> Int {
        switch report.status {
        case .ok: return 0
        case .failed: return 1
        case .manualActionRequired: return 2
        case .degraded: return 3
        }
    }

    static func aggregateStatus(_ checks: [Check]) -> ReportStatus {
        if checks.contains(where: { $0.status == .fail }) {
            return .failed
        }
        if checks.contains(where: { $0.status == .manual }) {
            return .manualActionRequired
        }
        if checks.contains(where: { $0.status == .warn || ($0.status == .skipped && !$0.optional) }) {
            return .degraded
        }
        return .ok
    }

    /// Honesty chokepoint (G1/AC-1.5): the report must never be `ok` when a required
    /// permission is ungranted. Pure + directly unit-tested so the invariant is owned
    /// here rather than left to emerge from each permission check being non-pass.
    /// `allGranted == accessibility && automationLogicPro && automationSystemEvents && postEventAccess`.
    static func clampStatusForPermissions(_ status: ReportStatus, allGranted: Bool) -> ReportStatus {
        (!allGranted && status == .ok) ? .degraded : status
    }
}
