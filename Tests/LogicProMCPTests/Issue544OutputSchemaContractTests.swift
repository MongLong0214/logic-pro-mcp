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
/// sites existed across four dispatchers.
///
/// What this suite does and does NOT lock, stated exactly, because an earlier version of this comment
/// claimed the whole property and a review had to point out that it did not:
///
/// - LOCKED: the `toolTextResult` floor. Delete it and permissions, refresh_cache, help and
///   is_running go back to nil `structuredContent`, and the sweep goes red.
/// - LOCKED: a new tool that builds a `CallTool.Result` without `structuredContent` at all.
/// - NOT LOCKED: the next handler that answers in prose. The floor wraps it as `{"message": …}`, which
///   satisfies "structuredContent is not nil", so the sweep stays green. Prose is legal now — it is
///   schema-conformant and the client no longer refuses it — but a command whose answer has real fields
///   should still encode them, and nothing here forces that.
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

    @Test("the two reported commands keep the exact text their semantic oracle grades")
    func structuredAnswersDoNotDisturbTheGradedText() async throws {
        // The first attempt at #544 encoded the new objects AS the text. Every unit test stayed green and
        // the live gate passed, because `SemanticOracleTable` grades these operations against fixtures
        // rather than the live handler — so a correct answer would only have turned RED later, in
        // qualification. The text and the structure are now separate halves on purpose, and this test is
        // the thing that notices if they are ever merged again.
        let refresh = await SystemDispatcher.handle(
            command: "refresh_cache", params: [:],
            router: ChannelRouter(), cache: StateCache()
        )
        guard case .text(let refreshText, _, _) = try #require(refresh.content.first) else {
            Issue.record("expected text content"); return
        }
        #expect(refreshText == "State refresh triggered. Cache will be updated on next poll cycle.")
        #expect(try #require(SemanticOracleTable.systemRefreshCache.evaluate(
            responseData: Data(refreshText.utf8), readbackData: Data("{}".utf8)
        )))

        // ...and the structured half is still there, which is the whole point of the change.
        guard case .object(let refreshFields) = try #require(refresh.structuredContent) else {
            Issue.record("expected an object"); return
        }
        #expect(refreshFields["refreshed"] == Value.bool(false))

        let perms = await SystemDispatcher.handle(
            command: "permissions", params: [:],
            router: ChannelRouter(), cache: StateCache()
        )
        guard case .text(let permText, _, _) = try #require(perms.content.first) else {
            Issue.record("expected text content"); return
        }
        #expect(permText.hasPrefix("Accessibility: "))
        #expect(try #require(SemanticOracleTable.systemPermissions.evaluate(
            responseData: Data(permText.utf8), readbackData: Data("{}".utf8)
        )))
        guard case .object(let permFields) = try #require(perms.structuredContent) else {
            Issue.record("expected an object"); return
        }
        #expect(permFields["accessibility"] != nil)
    }

    // MARK: - #544 review MAJOR — `all_granted` must not conflate "undetermined"
    // with "denied". `allGrantedValue(for:)` is the pure mapping the dispatcher's
    // `permissions` case delegates to; it is tested here directly (data in,
    // `Value` out) without driving `handle` against live TCC.

    @Test("all_granted is true only when every check is granted")
    func allGrantedValueIsTrueWhenEveryCheckIsGranted() {
        let status = PermissionChecker.PermissionStatus(
            accessibilityState: .granted,
            automationState: .granted,
            systemEventsAutomationState: .granted,
            postEventAccessState: .granted
        )
        #expect(SystemDispatcher.allGrantedValue(for: status) == .bool(true))
    }

    @Test("all_granted is null, not false, when nothing is denied but something is undetermined")
    func allGrantedValueIsNullNotFalseForUndetermined() {
        // Exact reproduction from the review: Automation (Logic Pro) granted,
        // Automation (System Events) not verifiable. Mutation target: change
        // `Self.allGrantedValue` back to
        // `status.automationState == .notVerifiable ? .null : .bool(status.allGranted)`
        // and this goes RED because it evaluates to `.bool(false)`.
        let status = PermissionChecker.PermissionStatus(
            accessibilityState: .granted,
            automationState: .granted,
            systemEventsAutomationState: .notVerifiable,
            postEventAccessState: .granted
        )
        #expect(SystemDispatcher.allGrantedValue(for: status) == .null)
    }

    @Test("all_granted is false when something is actually denied, even alongside an undetermined check")
    func allGrantedValueIsFalseWhenSomethingIsDeniedEvenNextToUndetermined() {
        // The other direction: a MEASURED denial must still surface as
        // `.bool(false)`, not soften to `.null` just because a sibling check
        // is undetermined. Mutation target: make the mapping check
        // `.notVerifiable` membership before `.notGranted` membership (as
        // `PermissionStatus.aggregateState` deliberately does NOT) and this
        // goes RED because it would report `.null` instead of `.bool(false)`.
        let status = PermissionChecker.PermissionStatus(
            accessibilityState: .notGranted,
            automationState: .notVerifiable,
            systemEventsAutomationState: .granted,
            postEventAccessState: .granted
        )
        #expect(SystemDispatcher.allGrantedValue(for: status) == .bool(false))
    }

    // MARK: - #544 review MAJOR — `refreshed` must reflect whether the cache
    // actually advanced, not whether `StatePoller.refreshNow()` merely returned.

    @Test("refresh_cache reports refreshed:false when the attached poller writes nothing")
    func refreshCacheReportsFalseWhenPollerWritesNothing() async throws {
        // Exact reproduction from the review: a StatePoller whose
        // Runtime.hasVisibleWindow reports no window, called once against a
        // fresh (zero-miss) poller. Production always supplies a poller, so
        // pre-fix this branch unconditionally claimed `refreshed: true`.
        let cache = StateCache()
        let channel = AccessibilityChannel(runtime: .init(
            isTrusted: { true }, isLogicProRunning: { true }, appRoot: { nil },
            transportState: { .success("{}") }, toggleTransportButton: { _ in .success("{}") },
            setTempo: { _ in .success("{}") }, setCycleRange: { _ in .success("{}") },
            tracks: { .error("no window") }, selectedTrack: { .success("{}") },
            selectTrack: { _ in .success("{}") }, setTrackToggle: { _, _ in .success("{}") },
            renameTrack: { _ in .success("{}") }, mixerState: { .success("[]") },
            channelStrip: { _ in .success("{}") }, setMixerValue: { _, _ in .success("{}") },
            projectInfo: { .error("no window") }, markers: { .success("[]") }
        ))
        let poller = StatePoller(
            axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { false })
        )

        let result = await SystemDispatcher.handle(
            command: "refresh_cache", params: [:],
            router: ChannelRouter(), cache: cache, poller: poller
        )

        // The graded prose is untouched regardless of the outcome.
        guard case .text(let text, _, _) = try #require(result.content.first) else {
            Issue.record("expected text content"); return
        }
        #expect(text == "State refresh completed via AX fallback poller.")
        guard case .object(let fields) = try #require(result.structuredContent) else {
            Issue.record("expected an object"); return
        }
        #expect(fields["refreshed"] == Value.bool(false))
        #expect(fields["source"] == Value.string("ax_fallback_poller"))
    }

    @Test("refresh_cache reports refreshed:true when the attached poller writes fresh state")
    func refreshCacheReportsTrueWhenPollerWritesFreshState() async throws {
        let cache = StateCache()
        let channel = AccessibilityChannel(runtime: .init(
            isTrusted: { true }, isLogicProRunning: { true }, appRoot: { nil },
            transportState: { .success("{}") }, toggleTransportButton: { _ in .success("{}") },
            setTempo: { _ in .success("{}") }, setCycleRange: { _ in .success("{}") },
            tracks: { .success("[]") }, selectedTrack: { .success("{}") },
            selectTrack: { _ in .success("{}") }, setTrackToggle: { _, _ in .success("{}") },
            renameTrack: { _ in .success("{}") }, mixerState: { .success("[]") },
            channelStrip: { _ in .success("{}") }, setMixerValue: { _, _ in .success("{}") },
            projectInfo: {
                .success(#"{"name":"Fresh","sampleRate":48000,"bitDepth":24,"tempo":120,"timeSignature":"4/4","trackCount":0,"filePath":null,"lastUpdated":"2026-04-16T00:00:00Z"}"#)
            },
            markers: { .success("[]") }
        ))
        let poller = StatePoller(
            axChannel: channel, cache: cache,
            runtime: .init(hasVisibleWindow: { true })
        )

        let result = await SystemDispatcher.handle(
            command: "refresh_cache", params: [:],
            router: ChannelRouter(), cache: cache, poller: poller
        )

        guard case .object(let fields) = try #require(result.structuredContent) else {
            Issue.record("expected an object"); return
        }
        #expect(fields["refreshed"] == Value.bool(true))
        #expect(await cache.getProject().name == "Fresh")
    }

    @Test("refresh_cache without an attached poller names no mechanism it did not start")
    func refreshCacheWithoutPollerNamesNoUnstartedCycle() async throws {
        // #544 review MINOR: `source: "next_poll_cycle"` named a poll cycle
        // this call never started (no poller is even attached). Mutation
        // target: revert `source` to `.string("next_poll_cycle")` and this
        // goes RED.
        let result = await SystemDispatcher.handle(
            command: "refresh_cache", params: [:],
            router: ChannelRouter(), cache: StateCache()
        )
        guard case .object(let fields) = try #require(result.structuredContent) else {
            Issue.record("expected an object"); return
        }
        #expect(fields["refreshed"] == Value.bool(false))
        #expect(fields["source"] == Value.string("none"))
    }

    // MARK: - #544 review MAJOR — the registry-shape test cannot fail a tool
    // that ANSWERS with prose. This exercises every command of every
    // outputSchema-declaring tool through the REAL dispatch path
    // (`LogicProServer.makeHandlers`, the same route `tools/call` uses) and
    // asserts `structuredContent != nil` on every response — not just that
    // the tool's static schema declares an object type.

    /// Commands excluded from the blind sweep, with the reason each one
    /// cannot be safely invoked with empty params in a unit test — not
    /// silently skipped. `logic_project.launch` is the only one: unlike
    /// every other mutating command, it does not route through the
    /// (unregistered-in-this-harness) `ChannelRouter` and carries no
    /// confirmation/consent gate, so with empty params it drives
    /// `ProcessUtils.isLogicProRunning` + a REAL `osascript activate` against
    /// the host machine's Logic Pro installation if one is present.
    private static let structuredContentSweepExclusions: [String: Set<String>] = [
        "logic_project": ["launch"],
    ]

    @Test("every command of every outputSchema-declaring tool answers with structuredContent")
    func everyCommandOfEveryOutputSchemaToolAnswersWithStructuredContent() async throws {
        // PRD-011: contain `export_support_bundle`'s empty-params default
        // write under a temp root instead of the real
        // ~/Library/Logs/LogicProMCP so this sweep cannot leave files on the
        // host machine.
        let rootKey = "LOGIC_MCP_SUPPORT_BUNDLE_ROOT_OVERRIDE"
        let previousRoot = getenv(rootKey).map { String(cString: $0) }
        setenv(rootKey, FileManager.default.temporaryDirectory.path, 1)
        defer {
            if let previousRoot { setenv(rootKey, previousRoot, 1) } else { unsetenv(rootKey) }
        }

        let server = LogicProServer()
        let handlers = await server.makeHandlers()
        var invoked = 0
        var listedExceptions = 0

        for tool in ServerCatalog.tools {
            guard let toolID = ToolID(rawValue: tool.name) else {
                Issue.record("\(tool.name) has no matching ToolID"); continue
            }
            let commands = OperationRegistry.commands(for: toolID)
            #expect(!commands.isEmpty, "\(tool.name) has no registered commands to sweep")
            let exclusions = Self.structuredContentSweepExclusions[tool.name] ?? []
            for command in commands {
                if exclusions.contains(command) {
                    listedExceptions += 1
                    continue
                }
                let result = await handlers.callTool(
                    CallTool.Parameters(name: tool.name, arguments: ["command": .string(command)])
                )
                #expect(
                    result.structuredContent != nil,
                    "\(tool.name).\(command) answered without structuredContent"
                )
                invoked += 1
            }
        }

        // Prove the sweep actually exercised commands rather than iterating
        // an empty registry view.
        #expect(invoked > 50)
        #expect(listedExceptions == 1)
    }
}
