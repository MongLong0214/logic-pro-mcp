import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// PRD-015 (ADR-005 #288): `clear_traces` destroys the in-process trace
/// evidence store, so every SUCCESSFUL clear must leave a durable, append-only
/// audit receipt OUTSIDE the cleared store, and a receipt that cannot be
/// written must fail closed (nothing cleared). These tests pin that contract.
@Suite("PRD-015 clear_traces audit receipt", .serialized)
struct TraceClearAuditTests {
    private static let flagKey = "LOGIC_MCP_ADR005_OPERATION_TRACE"
    private static let auditKey = "LOGIC_MCP_AUDIT_LOG_ROOT_OVERRIDE"

    /// Sets the ADR-005 flag + the DEBUG-only audit-root override to `auditRoot`,
    /// runs `body`, then restores both env vars. `auditRoot` may point at a
    /// deliberately-unwritable path to exercise the fail-closed branch.
    private func withEnv<R>(
        flagOn: Bool,
        auditRoot: URL,
        _ body: () async throws -> R
    ) async rethrows -> R {
        let prevFlag = getenv(Self.flagKey).map { String(cString: $0) }
        let prevAudit = getenv(Self.auditKey).map { String(cString: $0) }
        setenv(Self.flagKey, flagOn ? "1" : "0", 1)
        setenv(Self.auditKey, auditRoot.path, 1)
        defer {
            if let prevFlag { setenv(Self.flagKey, prevFlag, 1) } else { unsetenv(Self.flagKey) }
            if let prevAudit { setenv(Self.auditKey, prevAudit, 1) } else { unsetenv(Self.auditKey) }
        }
        return try await body()
    }

    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lpmcp-prd015-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Seed `n` completed traces directly into the shared store. `start()` is not
    /// flag-gated, so this works even when the ADR-005 flag is off.
    private func seedTraces(_ n: Int) async {
        for i in 0..<n {
            let id = await OperationTraceStore.shared.start(operationID: "test.prd015.seed.\(i)")
            await OperationTraceStore.shared.complete(id)
        }
    }

    private func clearTraces(confirmed: Bool = true) async -> CallTool.Result {
        await SystemDispatcher.handle(
            command: "clear_traces",
            params: confirmed ? ["confirmed": .bool(true)] : [:],
            router: ChannelRouter(),
            cache: StateCache()
        )
    }

    private func nonEmptyLines(ofFileAt path: String) throws -> [String] {
        let contents = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test("successful confirmed clear writes a durable receipt and empties the store")
    func successfulClearWritesReceipt() async throws {
        let root = tempRoot("success")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withEnv(flagOn: true, auditRoot: root) {
            await OperationTraceStore.shared.clear()
            await seedTraces(3)

            let result = await clearTraces()
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(result.isError != true)
            let success = try #require(body["success"] as? Bool)
            #expect(success)
            #expect(try #require(body["cleared_trace_count"] as? Int) == 3)
            let receiptPath = try #require(body["receipt_path"] as? String)
            #expect(receiptPath.hasSuffix("/trace-clear.log"))

            // The receipt file EXISTS, holds exactly one new line, and parses as
            // JSON carrying the schema fields.
            #expect(FileManager.default.fileExists(atPath: receiptPath))
            let lines = try nonEmptyLines(ofFileAt: receiptPath)
            #expect(lines.count == 1)
            let receipt = try #require(sharedJSONObject(lines[0]))
            #expect(try #require(receipt["schema"] as? String)
                == SystemDispatcher.traceClearReceiptSchema)
            // The receipt records the pre-drain SNAPSHOT; with no concurrent
            // trace start it matches the count the drain then reported.
            #expect(try #require(receipt["trace_count_at_receipt"] as? Int) == 3)
            #expect(receipt["amends"] == nil)

            // Store is now empty.
            #expect(await OperationTraceStore.shared.recent(limit: 128).isEmpty)
        }
    }

    @Test("two consecutive clears append two lines without truncating")
    func twoClearsAppendTwoLines() async throws {
        let root = tempRoot("append")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withEnv(flagOn: true, auditRoot: root) {
            await OperationTraceStore.shared.clear()
            await seedTraces(2)
            let first = await clearTraces()
            #expect(first.isError != true)

            await seedTraces(1)
            let second = await clearTraces()
            #expect(second.isError != true)

            let receiptPath = try #require(
                sharedJSONObject(sharedToolText(second))?["receipt_path"] as? String
            )
            let lines = try nonEmptyLines(ofFileAt: receiptPath)
            // Append-only: the first receipt survived the second clear.
            #expect(lines.count == 2)
            let firstReceipt = try #require(sharedJSONObject(lines[0]))
            let secondReceipt = try #require(sharedJSONObject(lines[1]))
            #expect(try #require(firstReceipt["schema"] as? String)
                == SystemDispatcher.traceClearReceiptSchema)
            #expect(try #require(secondReceipt["schema"] as? String)
                == SystemDispatcher.traceClearReceiptSchema)
            #expect(try #require(firstReceipt["trace_count_at_receipt"] as? Int) == 2)
            #expect(try #require(secondReceipt["trace_count_at_receipt"] as? Int) == 1)
        }
    }

    @Test("receipt-unwritable clear fails closed and leaves the store intact")
    func receiptUnwritableFailsClosed() async throws {
        // The deepest existing prefix of the audit root is a regular FILE, so
        // directory creation for the audit root fails → the clear is refused.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpmcp-prd015-file-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: file)
        let rootUnderFile = file.appendingPathComponent("audit", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: file) }

        try await withEnv(flagOn: true, auditRoot: rootUnderFile) {
            await OperationTraceStore.shared.clear()
            await seedTraces(2)

            let result = await clearTraces()
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            #expect(isError)
            #expect(try #require(body["state"] as? String) == "C")
            #expect(try #require(body["error"] as? String) == "trace_clear_receipt_failed")
            // The receipt write WAS attempted here, so `write_attempted:false`
            // would be a lie; the honest signal is that the STORE is intact.
            let storeCleared = try #require(body["store_cleared"] as? Bool)
            #expect(!storeCleared)
            #expect(body["write_attempted"] == nil)
            #expect(try #require(body["hint"] as? String).contains("left intact"))

            // Fail-closed: nothing was cleared.
            #expect(await OperationTraceStore.shared.recent(limit: 128).count == 2)
            // No receipt file materialized.
            let receiptPath = rootUnderFile.appendingPathComponent("trace-clear.log").path
            #expect(!FileManager.default.fileExists(atPath: receiptPath))
        }
    }

    @Test("receipt content is counts/timestamps only — exact key set, no user paths")
    func receiptPrivacyExactKeySet() async throws {
        let root = tempRoot("privacy")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withEnv(flagOn: true, auditRoot: root) {
            await OperationTraceStore.shared.clear()
            await seedTraces(1)

            let result = await clearTraces()
            let receiptPath = try #require(
                sharedJSONObject(sharedToolText(result))?["receipt_path"] as? String
            )
            let lines = try nonEmptyLines(ofFileAt: receiptPath)
            #expect(lines.count == 1)
            let line = lines[0]

            // Privacy: the receipt line carries no absolute user path.
            #expect(!line.contains("/Users/"))

            let receipt = try #require(sharedJSONObject(line))
            #expect(Set(receipt.keys) == [
                "schema", "cleared_at", "trace_count_at_receipt",
                "authorization", "server_version", "pid",
            ])
            #expect(try #require(receipt["schema"] as? String)
                == "logic_pro_mcp_trace_clear_receipt.v1")
            #expect(try #require(receipt["authorization"] as? String) == "mcp_confirmed_param")
            #expect(try #require(receipt["server_version"] as? String) == ServerConfig.serverVersion)
            _ = try #require(receipt["cleared_at"] as? String)
            #expect(try #require(receipt["trace_count_at_receipt"] as? Int) == 1)
            #expect(try #require(receipt["pid"] as? Int) > 0)
        }
    }

    @Test("clearReturningCount drains atomically and reports the true count")
    func clearReturningCountReportsTrueDrainedCount() async {
        await OperationTraceStore.shared.clear()
        await seedTraces(2)
        // Traces added after the first batch are drained by the SAME call —
        // the returned number is what this call actually removed, never a
        // count sampled at some earlier moment.
        await seedTraces(1)
        #expect(await OperationTraceStore.shared.traceCount == 3)

        #expect(await OperationTraceStore.shared.clearReturningCount() == 3)
        #expect(await OperationTraceStore.shared.traceCount == 0)
        // Draining an already-empty store honestly reports zero.
        #expect(await OperationTraceStore.shared.clearReturningCount() == 0)
    }

    @Test("a count divergence appends an amendment line without rewriting the receipt")
    func amendmentLineAppendsWithoutRewritingReceipt() async throws {
        let root = tempRoot("amend")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withEnv(flagOn: true, auditRoot: root) {
            await OperationTraceStore.shared.clear()
            await seedTraces(2)
            let result = await clearTraces()
            #expect(result.isError != true)
            let receiptPath = try #require(
                sharedJSONObject(sharedToolText(result))?["receipt_path"] as? String
            )
            let receiptLineBefore = try #require(nonEmptyLines(ofFileAt: receiptPath).first)

            // The amendment WRITER is the unit under test: interleaving a real
            // trace start between the dispatcher's snapshot and its atomic
            // drain would be a race, and a race is not a deterministic test.
            try SystemDispatcher.appendTraceClearAmendment(
                traceCountAtReceipt: 2,
                actualClearedCount: 3
            )

            let lines = try nonEmptyLines(ofFileAt: receiptPath)
            #expect(lines.count == 2)
            // Append-only: the original receipt line is byte-for-byte intact.
            #expect(try #require(lines.first) == receiptLineBefore)

            let amendmentLine = try #require(lines.last)
            let amendment = try #require(sharedJSONObject(amendmentLine))
            #expect(try #require(amendment["schema"] as? String)
                == SystemDispatcher.traceClearReceiptSchema)
            let amends = try #require(amendment["amends"] as? Bool)
            #expect(amends)
            // Both the corrected number and the snapshot it corrects.
            #expect(try #require(amendment["actual_cleared_count"] as? Int) == 3)
            #expect(try #require(amendment["trace_count_at_receipt"] as? Int) == 2)
        }
    }

    @Test("audit dir symlinked outside its intended parent fails closed")
    func auditDirSymlinkEscapeFailsClosed() async throws {
        // Layout: <base>/logs/audit is a SYMLINK to <base>/outside, a real
        // directory outside the intended parent <base>/logs. Directory
        // creation therefore SUCCEEDS — only the post-create realpath
        // containment check can catch the escape.
        let base = tempRoot("symlink")
        let intendedParent = base.appendingPathComponent("logs", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: intendedParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let auditRoot = intendedParent.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: auditRoot, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        // The containment check itself refuses, independent of whatever
        // `createDirectory` chooses to do with a symlink-to-existing-dir.
        #expect(!SystemDispatcher.auditDirectoryIsContained(auditRoot))

        try await withEnv(flagOn: true, auditRoot: auditRoot) {
            await OperationTraceStore.shared.clear()
            await seedTraces(2)

            let result = await clearTraces()
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            #expect(isError)
            #expect(try #require(body["state"] as? String) == "C")
            #expect(try #require(body["error"] as? String) == "trace_clear_receipt_failed")
            let storeCleared = try #require(body["store_cleared"] as? Bool)
            #expect(!storeCleared)

            // Fail-closed: the store survived the refused clear.
            #expect(await OperationTraceStore.shared.recent(limit: 128).count == 2)
            // Nothing was appended at the symlink TARGET — the receipt never
            // escaped the intended parent.
            #expect(!FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("trace-clear.log").path
            ))
        }
    }

    @Test("flag-off clear is a typed no-op with no receipt written")
    func flagOffClearWritesNoReceipt() async throws {
        let root = tempRoot("flagoff")
        defer { try? FileManager.default.removeItem(at: root) }
        try await withEnv(flagOn: false, auditRoot: root) {
            await OperationTraceStore.shared.clear()
            await seedTraces(2)

            let result = await clearTraces()
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            let isError = try #require(result.isError)
            #expect(isError)
            #expect(try #require(body["state"] as? String) == "C")
            #expect(try #require(body["error"] as? String) == "trace_disabled")
            let writeAttempted = try #require(body["write_attempted"] as? Bool)
            #expect(!writeAttempted)

            // Store intact — a no-op never clears.
            #expect(await OperationTraceStore.shared.recent(limit: 128).count == 2)
            // A no-op never writes a receipt.
            let receiptPath = root.appendingPathComponent("trace-clear.log").path
            #expect(!FileManager.default.fileExists(atPath: receiptPath))
        }
    }
}
