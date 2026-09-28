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
    /// The request the desktop app in #1048 (26.924.22138) sent when a thread started its MCP servers, taken
    /// off the wire 2026-09-28 in front of the 3.17.0 release binary, which answered it `-32603`. The same
    /// three client-naming strings are replaced; `extensions` and every other byte are the capture's.
    static let capturedDesktopInitialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"example/auth-change":{}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app","text/html+skybridge"]},"openai/elicitation":{"form":{}},"openai/form":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"example-mcp-client","title":"Example","version":"0.158.0-alpha.2.1"}}}"#
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

    private static func capabilities(of frame: Data) throws -> [String: Any] {
        let message = try #require(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        let params = try #require(message["params"] as? [String: Any])
        return try #require(params["capabilities"] as? [String: Any])
    }

    /// The desktop app also sends `capabilities.extensions`, a key swift-sdk 0.12.1 does not declare. The filter
    /// leaves it in the frame, so the fix holds only while the SDK ignores keys it does not declare; this pins
    /// that it does, and that the rewrite carries `extensions` over as the same JSON value.
    /// Kills: a filter that drops or alters `extensions`. If a later SDK refuses keys it does not declare,
    /// this turns red.
    @Test("the SDK ignores an undeclared capability key such as extensions, and the rewrite keeps it")
    func sdkIgnoresUndeclaredCapabilityKeys() throws {
        let raw = Data(Self.capturedDesktopInitialize.utf8)
        #expect(throws: DecodingError.self) { try Self.decodedInitialize(raw) }
        let filtered = InitializeExperimentalFilter.filter(raw).frame
        let request = try Self.decodedInitialize(filtered)
        #expect(request.params.capabilities.experimental == [:])
        let sent = try #require(try Self.capabilities(of: raw)["extensions"] as? NSDictionary)
        let kept = try #require(try Self.capabilities(of: filtered)["extensions"] as? NSDictionary)
        #expect(kept == sent)
        #expect(sent.count == 3)

        let extensionsOnly = Data(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}},"clientInfo":{"name":"t","version":"1"}}}"#.utf8)
        #expect(InitializeExperimentalFilter.filter(extensionsOnly).frame == extensionsOnly)
        let decoded = try Self.decodedInitialize(extensionsOnly)
        #expect(decoded.params.clientInfo.name == "t")
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

    /// One object-valued key of 100,000 characters and 1,000 more: about 110 KB of keys, past the
    /// 64 KB a pipe holds before a write to it blocks.
    static let manyLongKeysExperimental = "{" + (
        [#""\#(String(repeating: "a", count: 100_000))":{}"#]
            + (0..<1000).map { String(format: #""k%04d":{}"#, $0) }
    ).joined(separator: ",") + "}"

    static let manyLongKeysInitialize = String(
        decoding: initialize(experimental: manyLongKeysExperimental), as: UTF8.self)

    /// Kills: naming every dropped key, and not cutting a long one.
    @Test("the report names the first three keys, cuts a long one, and counts the rest")
    func reportIsBounded() throws {
        let outcome = InitializeExperimentalFilter.filter(Data(Self.manyLongKeysInitialize.utf8))
        #expect(outcome.droppedKeys.count == 1001)
        let report = try #require(outcome.report)
        #expect(report.utf8.count <= InitializeExperimentalFilter.reportByteLimit, "\(report.utf8.count) bytes")
        #expect(report.hasSuffix(
            #": ["\#(String(repeating: "a", count: 64))" (cut), "k0000", "k0001"] and 998 more"#))
    }

    /// Kills: a cut that splits a Character, and a cut by Characters alone, which keeps one Character of
    /// any size whole.
    @Test("a key is cut on a Character boundary and within its byte limit")
    func reportCutsOnCharacterBoundaries() throws {
        // "e" and a combining acute accent: one Character of three bytes.
        let accented = String(repeating: "e\u{301}", count: 100)
        #expect(InitializeExperimentalFilter.reportedKey(accented)
                    == "\"" + String(repeating: "e\u{301}", count: 64) + "\" (cut)")
        // One Character of 20,001 bytes: shown as nothing, and marked cut.
        let oneHugeCharacter = "e" + String(repeating: "\u{301}", count: 10_000)
        #expect(InitializeExperimentalFilter.reportedKey(oneHugeCharacter) == "\"\" (cut)")
        // A key that fits is shown whole, with no marker.
        #expect(InitializeExperimentalFilter.reportedKey("example/auth-change") == #""example/auth-change""#)

        // Keys whose escaped form is widest, in the first three places, and a thousand after them.
        let widest = [String(repeating: "\u{1}", count: 100), String(repeating: "\u{2}", count: 100),
                      String(repeating: "\u{3}", count: 100)]
        let outcome = InitializeExperimentalFilter.Outcome(
            frame: Data(), droppedKeys: widest + (0..<1000).map { String(format: "k%04d", $0) })
        let report = try #require(outcome.report)
        #expect(report.utf8.count <= InitializeExperimentalFilter.reportByteLimit, "\(report.utf8.count) bytes")
        #expect(report.hasSuffix(#"\u0003" (cut)] and 1000 more"#))
    }

    /// Kills: showing a key unescaped. Each of these characters ends a line in some reader.
    @Test("a key's quote, backslash, control characters and line separators are escaped")
    func reportEscapesKeys() throws {
        let key = "a\nb\rc\u{1b}[31m\u{7f}\u{85}\u{2028}\u{2029}\"\\"
        let report = try #require(InitializeExperimentalFilter.Outcome(frame: Data(), droppedKeys: [key]).report)
        #expect(report.hasSuffix(#": ["a\nb\rc\u001b[31m\u007f\u0085\u2028\u2029\"\\"]"#))
        for raw in ["\n", "\r", "\u{1b}", "\u{7f}", "\u{85}", "\u{2028}", "\u{2029}"] {
            #expect(!report.contains(raw), "\(raw.unicodeScalars.map(\.value)) is in the report")
        }
    }

    // MARK: - End to end: the real server behind the production stdio transport

    /// The complete reply lines in `received` that parse as JSON objects. A partial last line is left out.
    private static func replies(in received: Data) -> [(line: String, message: [String: Any])] {
        received.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                return nil
            }
            return (String(decoding: line, as: UTF8.self), message)
        }
    }

    /// Reads from `fd` into `received` until `done` holds, polling from this task so nothing outlives the
    /// test but the read end.
    private static func read(from fd: Int32, into received: inout Data,
                             until done: (Data) -> Bool) async throws {
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<2000 where !done(received) {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                received.append(contentsOf: buffer[0..<n])
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    /// Writes one initialize frame into the transport's input pipe and returns the reply line. When that
    /// reply is a result, it goes on as a client does -- `notifications/initialized`, then `tools/list` -- and
    /// returns the `tools/list` reply line as well.
    private static func handshakeOverStdio(_ frame: String) async throws
        -> (initialize: String, toolsList: String?, reports: [String]) {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        _ = fcntl(output[0], F_SETFL, fcntl(output[0], F_GETFL) | O_NONBLOCK)
        let writeEnd = input[1]
        func send(_ text: String) {
            let bytes = Data((text + "\n").utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
        }

        let reports = Reports()
        let server = LogicProServer()
        try await server.startProtocolProbe(
            transport: SerializedStdioTransport(input: input[0], output: output[1],
                                                reportDroppedCapabilities: { reports.append($0) }))
        var received = Data()
        send(frame)
        try await read(from: output[0], into: &received) { !replies(in: $0).isEmpty }
        let first = replies(in: received).first
        var toolsList: String?
        if let first, first.message["result"] != nil {
            send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            let isToolsList: ((line: String, message: [String: Any])) -> Bool = { $0.message["id"] as? Int == 2 }
            try await read(from: output[0], into: &received) { replies(in: $0).contains(where: isToolsList) }
            toolsList = replies(in: received).first(where: isToolsList)?.line
        }
        await server.stopProtocolProbe()
        // EOF ends the transport's read thread. `input[0]` stays open: that thread may still be inside
        // `read` on it, and nothing here can observe it return (#995).
        close(input[1])
        // Every reply awaited was read whole, so the writes that carried them are finished, and a stopped
        // server sends nothing more.
        close(output[1])
        close(output[0])
        let initialize = try #require(first?.line, "no reply line arrived")
        return (initialize, toolsList, reports.all)
    }

    /// What the transport reported, whole. The reports are kept in memory, so one of any size is read to
    /// its end and cannot hold back the reply.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// Kills: removing the filter from `SerializedStdioTransport`'s read loop. Without it the first three
    /// payloads get `-32603 ... isn't in the correct format`, and no `tools/list` follows.
    @Test("the real server completes initialize and tools/list over stdio for each client shape", arguments: [
        InitializeExperimentalFilterTests.objectExperimentalInitialize,
        InitializeExperimentalFilterTests.capturedDesktopInitialize,
        InitializeExperimentalFilterTests.capturedObjectValuedInitialize,
        InitializeExperimentalFilterTests.capturedNoExperimentalInitialize,
        InitializeExperimentalFilterTests.specExampleInitialize,
    ])
    func serverInitializesOverStdio(_ payload: String) async throws {
        let exchange = try await Self.handshakeOverStdio(payload)
        let line = exchange.initialize
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(!reply.keys.contains("error"), "initialize was refused: \(line)")
        let result = try #require(reply["result"] as? [String: Any], "no result: \(line)")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == ServerConfig.serverName)

        let listLine = try #require(exchange.toolsList, "no tools/list reply after initialize")
        let list = try #require(try JSONSerialization.jsonObject(with: Data(listLine.utf8)) as? [String: Any])
        #expect(!list.keys.contains("error"), "tools/list was refused: \(listLine.prefix(400))")
        let listResult = try #require(list["result"] as? [String: Any], "no result: \(listLine.prefix(400))")
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(!tools.isEmpty)
        #expect(tools.compactMap { $0["name"] as? String }.count == tools.count)
    }

    /// Kills: a report as long as the client's keys. The transport writes the report before it hands the
    /// request on, and to stderr, where a client that does not drain the pipe holds the write.
    @Test("a 100,000-character key and 1,000 more initialize, and the one report stays within its bound")
    func manyLongKeysInitializeWithABoundedReport() async throws {
        let exchange = try await Self.handshakeOverStdio(Self.manyLongKeysInitialize)
        let reply = try #require(
            try JSONSerialization.jsonObject(with: Data(exchange.initialize.utf8)) as? [String: Any])
        #expect(reply["result"] is [String: Any], "no initialize result: \(exchange.initialize.prefix(400))")
        #expect(exchange.toolsList != nil, "no tools/list reply after initialize")
        #expect(exchange.reports.count == 1)
        for report in exchange.reports {
            #expect(report.utf8.count <= InitializeExperimentalFilter.reportByteLimit,
                    "the report is \(report.utf8.count) bytes")
        }
    }
}
