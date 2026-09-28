import Darwin
import Foundation
import MCP
import Testing
@testable import LogicProMCP

/// #1048: a client that types `capabilities.experimental` values as the MCP schema does (objects) could
/// not complete the handshake, because swift-sdk 0.12.1 decodes them as strings only.
@Suite("InitializeExperimentalFilter")
struct InitializeExperimentalFilterTests {
    /// The request behind #1048, captured 2026-09-28 by a stub MCP server that logged its stdin. Only the
    /// client's name, its title and the experimental key's prefix are replaced; the rest is the capture.
    static let capturedObjectValuedInitialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"example/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"example-mcp-client","title":"Example","version":"0.156.1"}}}"#
    /// A second client's request, captured the same way, with no `experimental`. Only its name, title,
    /// description and website are replaced.
    static let capturedNoExperimentalInitialize = #"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{}},"clientInfo":{"name":"example-code","title":"Example Code","version":"2.1.283","description":"An example client","websiteUrl":"https://example.com/client"}},"jsonrpc":"2.0","id":0}"#
    /// The initialize example in the MCP specification, 2025-06-18 `basic/lifecycle`.
    static let specExampleInitialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{}},"clientInfo":{"name":"ExampleClient","title":"Example Client Display Name","version":"1.0.0"}}}"#
    /// The smallest payload that fails in the SDK: one object-valued experimental capability.
    static let objectExperimentalInitialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"x":{}}},"clientInfo":{"name":"lpm-1048","version":"1.0"}}}"#

    private static func initialize(experimental: String, extraCapabilities: String = "") -> Data {
        Data(#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{\#(extraCapabilities)"experimental":\#(experimental)},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)
    }

    private static func decodedInitialize(_ frame: Data) throws -> Request<Initialize> {
        try JSONDecoder().decode(Request<Initialize>.self, from: frame)
    }

    /// The cause, pinned at the SDK: the captured payload does not decode as `Initialize` without the
    /// filter. If this starts passing, the SDK has changed the type and the filter can be reconsidered.
    @Test("the SDK cannot decode an object-valued experimental capability; the filtered frame decodes")
    func sdkRejectsTheUnfilteredFrame() throws {
        let raw = Data(Self.capturedObjectValuedInitialize.utf8)
        #expect(throws: DecodingError.self) { try Self.decodedInitialize(raw) }
        let request = try Self.decodedInitialize(InitializeExperimentalFilter.filter(raw).frame)
        #expect(request.params.clientInfo.name == "example-mcp-client")
    }

    /// Kills: keeping an object value (and keeping any other non-string value).
    @Test("object, array, number, bool and null values are dropped; the string value is kept")
    func dropsEveryNonStringValue() throws {
        let frame = Self.initialize(
            experimental: #"{"obj":{"k":"v"},"arr":["a"],"int":1,"float":1.5,"bool":true,"null":null,"str":"v"}"#)
        let outcome = InitializeExperimentalFilter.filter(frame)
        #expect(outcome.droppedKeys == ["arr", "bool", "float", "int", "null", "obj"])
        let request = try Self.decodedInitialize(outcome.frame)
        #expect(request.params.capabilities.experimental == ["str": "v"])
    }

    /// Kills: dropping a string value, and re-encoding a frame that had nothing to drop.
    @Test("string values are kept, and a frame with only string values is the same bytes")
    func keepsStringValues() throws {
        let mixed = InitializeExperimentalFilter.filter(Self.initialize(experimental: #"{"a":"1","b":"","o":{}}"#))
        #expect(mixed.droppedKeys == ["o"])
        #expect(try Self.decodedInitialize(mixed.frame).params.capabilities.experimental == ["a": "1", "b": ""])

        let stringsOnly = Self.initialize(experimental: #"{"a":"1","b":"2"}"#)
        let outcome = InitializeExperimentalFilter.filter(stringsOnly)
        #expect(outcome.frame == stringsOnly)
        #expect(outcome.droppedKeys.isEmpty)
    }

    /// Kills: rewriting the rest of the request along with `experimental`.
    @Test("the rewritten frame keeps the id, protocol version, client info and other capabilities")
    func rewriteTouchesOnlyExperimental() throws {
        let frame = Self.initialize(experimental: #"{"x":{}}"#,
                                    extraCapabilities: #""roots":{"listChanged":true},"elicitation":{"form":{},"url":{}},"#)
        let request = try Self.decodedInitialize(InitializeExperimentalFilter.filter(frame).frame)
        #expect(request.id == .number(7))
        #expect(request.params.protocolVersion == "2025-06-18")
        #expect(request.params.clientInfo.name == "t")
        let roots = try #require(request.params.capabilities.roots)
        let listChanged = try #require(roots.listChanged as Bool?)
        #expect(listChanged)
        let elicitation = try #require(request.params.capabilities.elicitation)
        _ = try #require(elicitation.url)
        #expect(request.params.capabilities.experimental == [:])
    }

    /// Kills: rewriting a frame that has no `experimental` (the second captured client, the spec example).
    @Test("an initialize with no experimental capability is the same bytes", arguments: [
        InitializeExperimentalFilterTests.capturedNoExperimentalInitialize,
        InitializeExperimentalFilterTests.specExampleInitialize,
    ])
    func noExperimentalIsUnchanged(_ payload: String) {
        let frame = Data(payload.utf8)
        let outcome = InitializeExperimentalFilter.filter(frame)
        #expect(outcome.frame == frame)
        #expect(outcome.droppedKeys.isEmpty)
    }

    /// Kills: rewriting a message whose method is not `initialize`.
    @Test("any other message is the same bytes, even one carrying an object-valued experimental field",
          arguments: [
              #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"capabilities":{"experimental":{"x":{}}}}}"#,
              #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"capabilities":{"experimental":{"x":{}}}}}"#,
              #"{"jsonrpc":"2.0","id":3,"result":{"capabilities":{"experimental":{"x":{}}}}}"#,
          ])
    func otherMessagesAreUnchanged(_ payload: String) {
        let frame = Data(payload.utf8)
        let outcome = InitializeExperimentalFilter.filter(frame)
        #expect(outcome.frame == frame)
        #expect(outcome.droppedKeys.isEmpty)
    }

    /// Kills: rewriting inside a batch, or failing on a frame the parser cannot read. A batch passes
    /// through because the lifecycle forbids initialize in one (2025-03-26) and 2025-06-18 removed batches.
    @Test("a batch, a non-object experimental, a missing params and unparseable bytes pass through",
          arguments: [
              "[" + InitializeExperimentalFilterTests.objectExperimentalInitialize + "]",
              #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":"x"}}}"#,
              #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":null}}}"#,
              #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
              #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"x":{}}"#,
              "not json",
          ])
    func otherShapesPassThrough(_ payload: String) {
        let frame = Data(payload.utf8)
        let outcome = InitializeExperimentalFilter.filter(frame)
        #expect(outcome.frame == frame)
        #expect(outcome.droppedKeys.isEmpty)
    }

    /// Kills: a report that carries a value, or one that a key can split across lines.
    @Test("the report names the dropped keys on one line and never their values")
    func reportNamesKeysOnly() throws {
        let frame = Self.initialize(experimental: #"{"example/auth-change":{"token":"VALUE-1048"},"line\nbreak":[]}"#)
        let report = try #require(InitializeExperimentalFilter.filter(frame).report)
        #expect(report.contains(#""example/auth-change""#))
        #expect(!report.contains("VALUE-1048"))
        #expect(!report.contains("token"))
        #expect(!report.contains("\n"))
        let nothingDropped = InitializeExperimentalFilter.filter(Self.initialize(experimental: #"{"a":"1"}"#))
        #expect([nothingDropped.report].compactMap { $0 }.isEmpty)
    }

    // MARK: - End to end: the real server behind the production stdio transport

    /// Writes one initialize frame into the transport's input pipe and returns the first reply line.
    private static func initializeOverStdio(_ frame: String) async throws -> String {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        // Polled from this task instead of a reader thread, so nothing outlives the test but the read end
        // below.
        _ = fcntl(output[0], F_SETFL, fcntl(output[0], F_GETFL) | O_NONBLOCK)

        let server = LogicProServer()
        try await server.startProtocolProbe(
            transport: SerializedStdioTransport(input: input[0], output: output[1]))
        let bytes = Data((frame + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<2000 where !received.contains(UInt8(ascii: "\n")) {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(output[0], $0.baseAddress, $0.count) }
            if n > 0 {
                received.append(contentsOf: buffer[0..<n])
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await server.stopProtocolProbe()
        // EOF ends the transport's read thread. `input[0]` stays open: that thread may still be inside
        // `read` on it, and nothing here can observe it return (#995).
        close(input[1])
        // The reply was read whole, so the write that carried it is finished, and a stopped server
        // sends nothing more.
        close(output[1])
        close(output[0])
        let line = try #require(received.split(separator: UInt8(ascii: "\n")).first,
                                "no reply line arrived")
        return String(decoding: line, as: UTF8.self)
    }

    /// Kills: removing the filter from `SerializedStdioTransport`'s read loop. Without it the first two
    /// payloads get `-32603 ... isn't in the correct format`.
    @Test("the real server completes initialize over stdio for each client shape", arguments: [
        InitializeExperimentalFilterTests.objectExperimentalInitialize,
        InitializeExperimentalFilterTests.capturedObjectValuedInitialize,
        InitializeExperimentalFilterTests.capturedNoExperimentalInitialize,
        InitializeExperimentalFilterTests.specExampleInitialize,
    ])
    func serverInitializesOverStdio(_ payload: String) async throws {
        let line = try await Self.initializeOverStdio(payload)
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(!reply.keys.contains("error"), "initialize was refused: \(line)")
        let result = try #require(reply["result"] as? [String: Any], "no result: \(line)")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == ServerConfig.serverName)
    }
}
