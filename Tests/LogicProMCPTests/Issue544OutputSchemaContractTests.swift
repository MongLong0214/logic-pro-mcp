import Foundation
import Testing
import MCP
@testable import LogicProMCP

/// #544, reported externally against v3.13.0: `logic_system.permissions` and `refresh_cache` returned
/// prose under a tool registered with an `outputSchema`, so `structuredContent` came back nil and a
/// schema-enforcing client refused the call with `MCP error -32600`.
///
/// The reporter found two commands. The property is wider than the two: ANY handler that answers with
/// something other than a JSON object breaks the contract of whichever tool it belongs to, and ten such
/// sites existed across four dispatchers. These tests lock the property rather than the two instances,
/// so the next prose return is caught by the suite instead of by a user.
@Suite("Issue #544 — a declared outputSchema is always honoured")
struct Issue544OutputSchemaContractTests {

    @Test("prose that is not a JSON object still yields structured content")
    func proseStillCarriesStructuredContent() throws {
        let result = toolTextResult("State refresh completed via AX fallback poller.")

        // Mutation: drop the `?? .object(prose)` fallback in `toolTextResult` and this is nil again.
        let structured = try #require(result.structuredContent)
        guard case .object(let fields) = structured else {
            Issue.record("structuredContent must be an object, got \(structured)")
            return
        }
        #expect(fields["message"] == .string("State refresh completed via AX fallback poller."))

        // The text half must be untouched: a client reading `content[0].text` sees exactly what it saw
        // before, so the fix cannot have changed what any existing caller reads.
        guard case .text(let text, _, _) = try #require(result.content.first) else {
            Issue.record("expected a text content block")
            return
        }
        #expect(text == "State refresh completed via AX fallback poller.")
    }

    @Test("a JSON object answer is passed through unwrapped, not nested under message")
    func jsonAnswersAreNotDoubleWrapped() throws {
        let result = toolTextResult(#"{"operation":"system.health","ok":true}"#)
        let structured = try #require(result.structuredContent)
        guard case .object(let fields) = structured else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["operation"] == .string("system.health"))
        #expect(fields["message"] == nil)
    }

    @Test("every tool registered with an outputSchema declares an object schema")
    func everyRegisteredToolDeclaresAnObjectSchema() throws {
        // The registration list is the thing that creates the obligation, so the test reads it rather
        // than restating a list someone has to remember to extend.
        for tool in ServerCatalog.tools {
            let schema = try #require(tool.outputSchema, "\(tool.name) must declare an outputSchema")
            guard case .object(let fields) = schema else {
                Issue.record("\(tool.name) outputSchema is not an object")
                continue
            }
            #expect(fields["type"] == Value.string("object"))
        }
    }

    @Test("an error receipt built from prose is structured too")
    func errorProseIsStructured() throws {
        let result = toolTextResult("Failed to open the project.", isError: true)
        let structured = try #require(result.structuredContent)
        guard case .object(let fields) = structured else {
            Issue.record("expected an object")
            return
        }
        #expect(fields["message"] == .string("Failed to open the project."))
        #expect(try #require(result.isError))
    }
}
