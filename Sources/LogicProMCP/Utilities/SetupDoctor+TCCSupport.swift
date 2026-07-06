import Foundation

extension SetupDoctor {
    static func productionTCCCrossContextProbe() -> TCCCrossContextProbe {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return .skipped(reason: "tcc_query_unavailable")
        }
        return mapTCCQueryOutcome(productionTCCRows())
    }


    private static func productionTCCRows() -> TCCQueryOutcome {
        let userDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let systemDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        let dbs = [userDB, systemDB].filter { FileManager.default.fileExists(atPath: $0) }
        guard !dbs.isEmpty else { return .fullDiskAccessUnavailable }
        let sql = """
        SELECT service,client,auth_value,indirect_object_identifier FROM access WHERE service IN ('kTCCServiceAccessibility','kTCCServiceAppleEvents','kTCCServicePostEvent') AND (service != 'kTCCServiceAppleEvents' OR indirect_object_identifier IN ('com.apple.logic10','com.apple.systemevents'));
        """
        var rows: [TCCRow] = []
        var sawReadableDB = false
        for db in dbs {
            guard let output = runProductionCommand(
                executable: "/usr/bin/sqlite3",
                arguments: ["file:\(db)?immutable=1", sql],
                timeout: 1.5
            )?.output else {
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
            return .skipped(reason: "full_disk_access_unavailable")
        case .queryUnavailable:
            return .skipped(reason: "tcc_query_unavailable")
        case .schemaMismatch:
            return .skipped(reason: "tcc_schema_mismatch")
        case let .rows(rows):
            let findings = tccFindings(rows)
            guard !findings.isEmpty else { return .skipped(reason: "principal_not_found") }
            if findings.contains(where: { $0.contains("state=denied") }) {
                return .denied(findings.joined(separator: ","))
            }
            if findings.contains(where: { $0.contains("state=granted") }) {
                return .granted(findings.joined(separator: ","))
            }
            return .skipped(reason: "principal_not_found")
        }
    }


    static func tccFindings(_ rows: [TCCRow]) -> [String] {
        rows.compactMap { row in
            guard isRelevantTCCPrincipal(row.client) else { return nil }
            let state: String
            switch row.authValue {
            case 0:
                state = "denied"
            case 2:
                state = "granted"
            default:
                state = "unknown"
            }
            let service = redactedTCCService(row.service, indirectObjectIdentifier: row.indirectObjectIdentifier)
            return "service=\(service);principal_hint=\(redactedTCCPrincipal(row.client));state=\(state)"
        }
    }


    private static func isRelevantTCCPrincipal(_ client: String) -> Bool {
        client.localizedCaseInsensitiveContains("claude")
            || client.localizedCaseInsensitiveContains("terminal")
            || client.localizedCaseInsensitiveContains("iterm")
            || client.localizedCaseInsensitiveContains("LogicProMCP")
    }


    private static func redactedTCCService(_ service: String, indirectObjectIdentifier: String) -> String {
        if service == "kTCCServiceAccessibility" { return "accessibility" }
        if service == "kTCCServicePostEvent" { return "post_event" }
        if service == "kTCCServiceAppleEvents" {
            if indirectObjectIdentifier == "com.apple.logic10" { return "appleevents:logic10" }
            if indirectObjectIdentifier == "com.apple.systemevents" { return "appleevents:systemevents" }
            return "appleevents"
        }
        return "unknown"
    }


    private static func redactedTCCPrincipal(_ client: String) -> String {
        if client.contains("/") { return URL(fileURLWithPath: client).lastPathComponent }
        return client
    }


}
