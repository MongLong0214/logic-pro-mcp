import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #220: during concurrent MCP surface probing, large single-line JSON
/// responses (library inventory, disk library scan, project audit) appeared to
/// produce no observed response within the client deadline, while the same
/// requests succeeded quickly when run alone.
///
/// Root cause: MCP stdio has ONE stdout pipe. `StdioTransport` is an actor, so
/// concurrent responses are written one-at-a-time (never interleaved/corrupted)
/// but they queue behind each other and flush only as fast as the client
/// drains stdout. A client that fires many concurrent large reads without
/// promptly draining — under a short deadline — can see later responses as
/// "no response." That is client-side backpressure, not a server malfunction:
/// the server produces every response, complete and well-formed.
///
/// These tests prove the SERVER side of that guarantee — every one of many
/// concurrent large reads is served completely and as valid JSON, with no
/// dropped, truncated, or corrupted payloads. The end-to-end wire behavior
/// (a draining client receives all concurrent responses intact) is covered by
/// the live-e2e concurrent-large-read section.
@Suite("Issue220 concurrent large reads")
struct Issue220ConcurrentLargeReadTests {
    private func makeHandlers() async -> LogicProServerHandlers {
        await LogicProServer().makeHandlers()
    }

    /// The large read-only surfaces named in #220 plus the always-present static
    /// catalogs (guaranteed multi-KB regardless of Logic state).
    private let largeURIs = [
        "logic://library/inventory",
        "logic://project/audit",
        "logic://project/cleanup-plan",
        "logic://stock-plugins",
        "logic://stock-instruments",
        "logic://session-players",
        "logic://workflow-skills",
        "logic://mixer",
        "logic://tracks",
    ]

    @Test("many concurrent large reads each return complete, valid JSON")
    func concurrentLargeReadsAreComplete() async throws {
        let handlers = await makeHandlers()
        // 45 concurrent in-flight reads across the large surfaces — well beyond
        // the handful the audit fired.
        let uris = (0..<5).flatMap { _ in largeURIs }
        let texts: [String] = try await withThrowingTaskGroup(of: String.self) { group in
            for uri in uris {
                group.addTask {
                    let result = try await handlers.readResource(ReadResource.Parameters(uri: uri))
                    return sharedResourceText(result)
                }
            }
            var collected: [String] = []
            for try await text in group { collected.append(text) }
            return collected
        }

        #expect(texts.count == uris.count, "every concurrent read must produce a response")
        for text in texts {
            #expect(!text.isEmpty, "no concurrent large read may return an empty body")
            // Every payload must parse as a complete JSON value (object or array)
            // — proof it was neither truncated nor interleaved with another frame.
            let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            #expect(parsed != nil, "concurrent large read body must be complete valid JSON, got: \(text.prefix(120))")
        }
    }

    @Test("concurrent large reads interleaved with tool calls all complete")
    func concurrentMixedLoadAllComplete() async throws {
        let handlers = await makeHandlers()
        // Fire large reads AND tool calls concurrently in one group (the mixed
        // read-heavy + command load the audit ran).
        enum Payload { case read(String), call(String) }
        let payloads: [Payload] = try await withThrowingTaskGroup(of: Payload.self) { group in
            for uri in largeURIs {
                group.addTask { .read(sharedResourceText(try await handlers.readResource(.init(uri: uri)))) }
            }
            for _ in 0..<8 {
                group.addTask {
                    .call(sharedToolText(await handlers.callTool(
                        .init(name: "logic_system", arguments: ["command": .string("health")]))))
                }
            }
            var out: [Payload] = []
            for try await p in group { out.append(p) }
            return out
        }

        var readCount = 0, callCount = 0
        for payload in payloads {
            switch payload {
            case .read(let text):
                readCount += 1
                #expect(!text.isEmpty)
                #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil,
                        "concurrent read under mixed load must be complete valid JSON")
            case .call(let text):
                callCount += 1
                #expect(text.contains("logic_pro_running"),
                        "concurrent health call must return a complete health payload")
            }
        }
        #expect(readCount == largeURIs.count)
        #expect(callCount == 8)
    }
}
