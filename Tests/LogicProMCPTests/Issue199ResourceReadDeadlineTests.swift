import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #199: resource reads (`logic://…`) had no deadline wrapper, so a read backed
/// by a live AX route on a wedged/occluded Logic session could block past the
/// client read timeout and leave it with NO JSON-RPC response. The backstop
/// bounds every resource read into a typed `operation_timeout` body the same way
/// the #112 deadline bounds tool calls.
@Suite("Issue199 resource-read deadline")
struct Issue199ResourceReadDeadlineTests {
    private func json(_ r: ReadResource.Result) -> [String: Any]? {
        guard let data = sharedResourceText(r).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test("a fast resource read passes through unchanged")
    func fastReadPassesThrough() async throws {
        let result = try await LogicProServer.runResourceReadWithDeadline(
            uri: "logic://tracks",
            deadlineOverride: 5.0
        ) {
            ReadResource.Result(contents: [.text("{\"ok\":true}", uri: "logic://tracks", mimeType: "application/json")])
        }
        #expect((json(result)?["ok"] as? Bool)!)
    }

    @Test("a resource read that exceeds the deadline returns a typed operation_timeout body, not a hang")
    func slowReadTimesOut() async throws {
        let uri = "logic://transport/state"
        let result = try await LogicProServer.runResourceReadWithDeadline(uri: uri, deadlineOverride: 0.15) {
            // Far past the 0.15s deadline — this read must NOT win the race.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return ReadResource.Result(contents: [.text("{\"should\":\"not win\"}", uri: uri, mimeType: "application/json")])
        }
        let obj = try #require(json(result))
        #expect(obj["error"] as? String == "operation_timeout")
        #expect(!((obj["success"] as? Bool)!))
        #expect(obj["uri"] as? String == uri)
        #expect(obj["timeout_sec"] as? Double == 0.15)
    }

    @Test("a genuine read error is rethrown unchanged so JSON-RPC error semantics are preserved")
    func readErrorRethrown() async {
        do {
            _ = try await LogicProServer.runResourceReadWithDeadline(
                uri: "logic://bogus",
                deadlineOverride: 5.0
            ) {
                throw MCPError.invalidParams("Unknown resource URI: logic://bogus")
            }
            Issue.record("expected the underlying read error to propagate")
        } catch {
            // Rethrown unchanged: same MCPError type AND original message preserved
            // (the wrapper must not swallow or transform a genuine read error).
            #expect(error is MCPError)
            #expect("\(error)".contains("Unknown resource URI"))
        }
    }

    @Test("the resource-read deadline matches the fast tool tier")
    func resourceDeadlineValue() {
        #expect(LogicProServer.resourceReadDeadlineSeconds == 25)
    }

    @Test("the resource timeout body is a State C envelope shape")
    func timeoutBodyShape() {
        let uri = "logic://tracks/0/regions"
        let result = LogicProServer.resourceReadTimeoutResult(uri: uri, seconds: 25)
        let obj = json(result)
        #expect(!((obj?["success"] as? Bool)!))
        #expect(obj?["error"] as? String == "operation_timeout")
        #expect(obj?["uri"] as? String == uri)
        #expect(obj?["timeout_sec"] as? Double == 25)
    }
}
