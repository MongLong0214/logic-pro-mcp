import Foundation

extension SetupDoctor {
    /// Fixed words for the Apple Events target, keyed by built-in identifiers only. The SQL may also
    /// match identifiers a manifest supplies, which widens what is queried. Printing never widens:
    /// any identifier missing from this table is printed as `another application`.
    private static let appleEventsTargetLabels: [String: String] = [
        "com.apple.systemevents": "systemevents",
        "com.apple.logic10": "logic-pro",
        "com.apple.mobilelogic": "logic-pro-creator-studio",
    ]

    static func productionTCCCrossContextProbe() -> TCCCrossContextProbe {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return .skipped(reason: .tccQueryUnavailable)
        }
        return mapTCCQueryOutcome(productionTCCRows())
    }


    private static func productionTCCRows() -> TCCQueryOutcome {
        let userDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let systemDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        let dbs = [userDB, systemDB].filter { FileManager.default.fileExists(atPath: $0) }
        guard !dbs.isEmpty else { return .fullDiskAccessUnavailable }
        let logicBundleIDs = LogicProVariantPolicy.knownBundleIDs
            .map { "'\($0)'" }
            .joined(separator: ",")
        let sql = """
        SELECT service,client,auth_value,indirect_object_identifier FROM access WHERE service IN ('kTCCServiceAccessibility','kTCCServiceAppleEvents','kTCCServicePostEvent') AND (service != 'kTCCServiceAppleEvents' OR indirect_object_identifier IN (\(logicBundleIDs),'com.apple.systemevents'));
        """
        var rows: [TCCRow] = []
        var sawReadableDB = false
        for db in dbs {
            guard let output = runProductionCommand(
                executable: "/usr/bin/sqlite3",
                arguments: ["file:\(db)?immutable=1", sql],
                timeout: 1.5
            ).output else {
                return .queryUnavailable
            }
            if output.exitCode != 0 {
                if output.stderr.localizedCaseInsensitiveContains("no such column") {
                    return .schemaMismatch
                }
                continue
            }
            sawReadableDB = true
            rows.append(contentsOf: parseTCCRows(output.stdout))
        }
        return sawReadableDB ? .rows(rows) : .fullDiskAccessUnavailable
    }


    static func parseTCCRows(_ output: String) -> [TCCRow] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 4, let authValue = Int(columns[2]) else { return nil }
            return TCCRow(
                service: columns[0],
                client: columns[1],
                authValue: authValue,
                indirectObjectIdentifier: columns[3]
            )
        }
    }


    static func mapTCCQueryOutcome(_ outcome: TCCQueryOutcome) -> TCCCrossContextProbe {
        switch outcome {
        case .fullDiskAccessUnavailable:
            return .skipped(reason: .fullDiskAccessUnavailable)
        case .queryUnavailable:
            return .skipped(reason: .tccQueryUnavailable)
        case .schemaMismatch:
            return .skipped(reason: .tccSchemaMismatch)
        case let .rows(rows):
            // Historical context only (#1596). A row records what one client holds, not what the
            // measured principal holds, so this path reports counts and fixed labels and never a
            // grant, a denial, or a pass.
            let recognised = tccFindings(rows)
            guard !recognised.isEmpty else { return .skipped(reason: .principalNotFound) }
            let unrecognised = rows.count - recognised.count
            return .recorded(
                "recognised_entries=\(recognised.count);unrecognised_entries=\(unrecognised);"
                    + recognised.joined(separator: ",")
            )
        }
    }


    /// One entry per row whose client is on the closed list of recognised hosts. The entry has no
    /// authorization state: a database row is not evidence about the measured principal.
    static func tccFindings(_ rows: [TCCRow]) -> [String] {
        rows.compactMap { row in
            guard TCCResponsibility.knownTCCClientLabel(for: row.client) != nil
                || TCCResponsibility.isProductExecutable(tccClient: row.client) else { return nil }
            let service = redactedTCCService(row.service, indirectObjectIdentifier: row.indirectObjectIdentifier)
            return "service=\(service);principal_hint=\(redactedTCCPrincipal(row.client))"
        }
    }


    private static func redactedTCCService(_ service: String, indirectObjectIdentifier: String) -> String {
        if service == "kTCCServiceAccessibility" { return "accessibility" }
        if service == "kTCCServicePostEvent" { return "post_event" }
        if service == "kTCCServiceAppleEvents" {
            let target = appleEventsTargetLabels[indirectObjectIdentifier] ?? "another application"
            return "appleevents:\(target)"
        }
        return "unknown"
    }


    /// Every `client` value from the database goes through the same fixed-label rule as the rest of
    /// the permission output; the row's own text is never copied.
    private static func redactedTCCPrincipal(_ client: String) -> String {
        TCCResponsibility.publicLabel(forTCCClient: client)
    }


}
