import Foundation
import Testing
@testable import LogicProMCP

actor ScriptResponseQueue {
    private var results: [ChannelResult]

    init(_ results: [ChannelResult]) {
        self.results = results
    }

    func next() -> ChannelResult {
        guard !results.isEmpty else {
            return .success("")
        }
        return results.removeFirst()
    }
}

actor AppleScriptRecorder {
    private var scripts: [String] = []
    private var result: ChannelResult = .success("{\"result\":\"OK\"}")

    func run(_ source: String) -> ChannelResult {
        scripts.append(source)
        return result
    }

    func setResult(_ result: ChannelResult) {
        self.result = result
    }

    func snapshot() -> [String] {
        scripts
    }
}

actor TransportActionRecorder {
    private var actions: [String] = []
    private var result: ChannelResult = .success("{\"result\":\"OK\"}")

    func run(_ action: String) -> ChannelResult {
        actions.append(action)
        return result
    }

    func setResult(_ result: ChannelResult) {
        self.result = result
    }

    func snapshot() -> [String] {
        actions
    }
}

final class OpenFileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var openedPaths: [String] = []
    var result = true

    func open(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openedPaths.append(path)
        return result
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return openedPaths
    }
}

private func makeAppleScriptRuntime(
    isRunning: Bool = true,
    scriptRecorder: AppleScriptRecorder = AppleScriptRecorder(),
    openRecorder: OpenFileRecorder = OpenFileRecorder(),
    transportRecorder: TransportActionRecorder = TransportActionRecorder(),
    fileExists: @escaping @Sendable (String) -> Bool = { _ in true },
    fileModificationDate: @escaping @Sendable (String) -> Date? = { _ in Date.distantFuture },
    currentDocumentPath: @escaping @Sendable () async -> String? = { nil }
) -> AppleScriptChannel.Runtime {
    AppleScriptChannel.Runtime(
        isLogicProRunning: { isRunning },
        openFile: { path in
            openRecorder.open(path)
        },
        runScript: { source in
            if !isRunning && source.contains("return name") {
                return .error("Logic Pro is not running")
            }
            return await scriptRecorder.run(source)
        },
        executeTransportAction: { action in
            await transportRecorder.run(action)
        },
        fileExists: fileExists,
        fileModificationDate: fileModificationDate,
        currentDocumentPath: currentDocumentPath
    )
}

@Test func testAppleScriptHealthReflectsRunningState() async {
    let available = AppleScriptChannel(runtime: makeAppleScriptRuntime(isRunning: true))
    let unavailable = AppleScriptChannel(runtime: makeAppleScriptRuntime(isRunning: false))

    let healthy = await available.healthCheck()
    #expect(healthy.available)
    #expect(healthy.detail == "AppleScript ready")

    let missing = await unavailable.healthCheck()
    #expect(!(missing.available))
    #expect(missing.detail.contains("not running"))
}

@Test func testAppleScriptHealthFailsWhenProbeFailsEvenIfLogicIsRunning() async {
    let recorder = AppleScriptRecorder()
    await recorder.setResult(.error("AppleScript error: osascript denied"))
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            isRunning: true,
            scriptRecorder: recorder
        )
    )

    let health = await channel.healthCheck()
    #expect(!health.available)
    #expect(health.detail.contains("osascript denied"))
}

@Test func testAppleScriptUnsupportedOperationFails() async {
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime())
    let result = await channel.execute(operation: "project.export", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("Unsupported AppleScript operation"))
}

@Test func testAppleScriptProjectOpenRequiresPath() async {
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime())
    let result = await channel.execute(operation: "project.open", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("Missing 'path'"))
}

@Test func testAppleScriptProjectOpenUsesInjectedWorkspaceOpenResult() async {
    let openRecorder = OpenFileRecorder()
    let scriptRecorder = AppleScriptRecorder()
    let path = "/tmp/session.logicx"
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: scriptRecorder,
            openRecorder: openRecorder
        )
    )

    let opened = await channel.execute(operation: "project.open", params: ["path": path])
    #expect(opened.isSuccess)
    // v3.1.1 (P2-2) — successes from mutating ops are now wrapped in a
    // Honest Contract State B envelope (`verified:false /
    // readback_unavailable`). The legacy free-text "Opened: <path>" is
    // preserved inside `raw` for diagnostic continuity.
    #expect(opened.message.contains("\"success\":true"))
    #expect(opened.message.contains("\"verified\":false"))
    #expect(opened.message.contains("\"reason\":\"readback_unavailable\""))
    #expect(opened.message.contains("\"operation\":\"project.open\""))
    #expect(opened.message.contains("\"method\":\"applescript\""))
    #expect(opened.message.contains("Opened: \\/tmp\\/session.logicx"))
    #expect(openRecorder.snapshot() == [path])
    let scripts = await scriptRecorder.snapshot()
    #expect(scripts.count == 1)
    #expect(scripts[0].contains("path of front document as text"))
    #expect(scripts[0].contains(path))

    await scriptRecorder.setResult(.error("front document never changed"))
    let verifyFailed = await channel.execute(operation: "project.open", params: ["path": path])
    #expect(!verifyFailed.isSuccess)
    #expect(verifyFailed.message.contains("Failed to verify opened project"))
    #expect(verifyFailed.message.contains(path))

    openRecorder.result = false
    let failed = await channel.execute(operation: "project.open", params: ["path": path])
    #expect(!failed.isSuccess)
    #expect(failed.message == "Failed to open: \(path)")
}

@Test func testAppleScriptProjectOpenRetriesAfterClosingCurrentDocument() async {
    let openRecorder = OpenFileRecorder()
    let path = "/tmp/reopen.logicx"
    let identities = ScriptResponseQueue([
        .success("/tmp/other.logicx\u{001F}Previous Project"),
    ])
    let channel = AppleScriptChannel(
        runtime: .init(
            isLogicProRunning: { true },
            openFile: { openRecorder.open($0) },
            runScript: { source in
                if source.contains("character id 31") {
                    return await identities.next()
                }
                if source.contains("close front document") {
                    return .success("OK")
                }
                if source.contains("return path of front document as text") {
                    return .success("/tmp/other.logicx")
                }
                if source.contains("path of front document as text") {
                    return openRecorder.snapshot().count == 1
                        ? .error("front document never changed")
                        : .success("opened")
                }
                return .success("OK")
            },
            executeTransportAction: { _ in .success("OK") }
        )
    )

    let result = await channel.execute(operation: "project.open", params: ["path": path])
    #expect(result.isSuccess)
    // v3.1.1 (P2-2) — wrapped HC State B envelope; raw legacy text inside.
    #expect(result.message.contains("\"success\":true"))
    #expect(result.message.contains("\"verified\":false"))
    #expect(result.message.contains("\"operation\":\"project.open\""))
    #expect(result.message.contains("Opened: \\/tmp\\/reopen.logicx"))
    #expect(openRecorder.snapshot() == [path, path])
}

@Test func testAppleScriptProjectOpenRefusesToCloseUntitledCurrentDocumentOnRetry() async throws {
    let openRecorder = OpenFileRecorder()
    let path = "/tmp/untitled.logicx"
    let recorder = AppleScriptRecorder()
    let identities = ScriptResponseQueue([
        .success("\u{001F}Untitled 12"),
    ])
    let channel = AppleScriptChannel(
        runtime: .init(
            isLogicProRunning: { true },
            openFile: { openRecorder.open($0) },
            runScript: { source in
                if source.contains("character id 31") {
                    return await identities.next()
                }
                if source.contains("return path of front document as text") {
                    _ = await recorder.run(source)
                    return .success("")
                }
                if source.contains("path of front document as text") {
                    _ = await recorder.run(source)
                    return openRecorder.snapshot().count == 1
                        ? .error("front document never changed")
                        : .success("opened")
                }
                return await recorder.run(source)
            },
            executeTransportAction: { _ in .success("OK") }
        )
    )

    let result = await channel.execute(operation: "project.open", params: ["path": path])
    #expect(!result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "unsupported_state")
    #expect(((obj["hint"] as? String)?.contains("refusing to close"))!)
    #expect(openRecorder.snapshot() == [path])
    let scripts = await recorder.snapshot()
    #expect(!scripts.contains(where: { $0.contains("close front document saving no") }))
}

@Test func testAppleScriptProjectOpenRestoresPreviousSavedProjectAfterRetryFailure() async {
    let openRecorder = OpenFileRecorder()
    let path = "/tmp/failed.logicx"
    let previous = "/tmp/previous.logicx"
    let recorder = AppleScriptRecorder()
    let identities = ScriptResponseQueue([
        .success("\(previous)\u{001F}Previous Project"),
        .success("\(previous)\u{001F}Previous Project"),
    ])
    await recorder.setResult(.error("Timed out waiting for Logic Pro to open the requested project"))
    let channel = AppleScriptChannel(
        runtime: .init(
            isLogicProRunning: { true },
            openFile: { openRecorder.open($0) },
            runScript: { source in
                if source.contains("character id 31") {
                    return await identities.next()
                }
                if source.contains("return path of front document as text") {
                    return .success(previous)
                }
                if source.contains("close front document") {
                    return .success("OK")
                }
                return await recorder.run(source)
            },
            executeTransportAction: { _ in .success("OK") }
        )
    )

    let result = await channel.execute(operation: "project.open", params: ["path": path])
    #expect(!result.isSuccess)
    #expect(openRecorder.snapshot() == [path, path, previous])
}

// Regression: the front-document identity readback delimiter (U+001F) must
// survive the real `normalizedAppleScriptResult` sanitizer. Every other identity
// test stubs `runScript` directly with a U+001F-bearing result, bypassing the
// sanitizer that runs in production — which is exactly how the
// "project.new always degrades to State C" defect hid behind a green suite.
@Test func testNormalizedAppleScriptResultPreservesIdentityDelimiters() {
    let titled = AppleScriptChannel.normalizedAppleScriptResult("/Users/x/Song.logicx\u{001F}Song")
    #expect(titled.contains("\u{001F}"))
    let untitled = AppleScriptChannel.normalizedAppleScriptResult("\u{001E}\u{001F}Untitled 3")
    #expect(untitled.contains("\u{001F}"))
    #expect(untitled.contains("\u{001E}"))
    // Genuinely-forbidden control bytes are still stripped (fix is not over-broad).
    let withBell = AppleScriptChannel.normalizedAppleScriptResult("OK\u{0001}\u{0007}")
    #expect(!withBell.contains("\u{0001}"))
    #expect(!withBell.contains("\u{0007}"))
}

@Test func testIdentityReadbackSurvivesRealSanitizerPipeline() {
    // Drive the production pipeline: raw osascript stdout -> real sanitizer ->
    // identity parse. Before the fix, the sanitizer deleted U+001F and the parse
    // returned nil for both of these.
    let titled = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success(AppleScriptChannel.normalizedAppleScriptResult("/Users/x/Song.logicx\u{001F}Song"))
    )
    #expect(titled?.path == "/Users/x/Song.logicx")
    #expect(titled?.name == "Song")

    let untitled = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success(AppleScriptChannel.normalizedAppleScriptResult("\u{001F}Untitled 7"))
    )
    #expect(untitled?.path == nil)
    #expect(untitled?.name == "Untitled 7")
}

@Test func testProjectNewYieldsStateAThroughRealSanitizer() {
    // Previous and current identities both flow through the real sanitizer.
    let previous = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success(AppleScriptChannel.normalizedAppleScriptResult("\u{001F}Untitled 7"))
    )
    let current = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success(AppleScriptChannel.normalizedAppleScriptResult("\u{001F}Untitled 8"))
    )
    // A genuine front-document change must verify as State A success, NOT the
    // readback_mismatch State C the stripped-delimiter bug produced every time.
    let result = AppleScriptChannel.wrapNewProjectResult(
        .success("new project created"),
        previousDocumentIdentity: previous,
        currentDocumentIdentity: current
    )
    #expect(result.isSuccess)

    // Control: when the readback identity is unparseable (nil), verification
    // still fails closed to State C — the fix does not paper over a real miss.
    let unverifiable = AppleScriptChannel.wrapNewProjectResult(
        .success("new project created"),
        previousDocumentIdentity: previous,
        currentDocumentIdentity: nil
    )
    #expect(!unverifiable.isSuccess)
}

@Test func testAppleScriptProjectCommandsGenerateExpectedScripts() async {
    let recorder = AppleScriptRecorder()
    let identities = ScriptResponseQueue([
        .success("/Users/x/Song.logicx\u{001F}Song"),
        .success("\u{001F}Untitled 18"),
    ])
    // #144: a titled front document keeps `project.save` on the healthy path
    // that fires `save front document` (the untitled fail-fast is covered
    // separately in testAppleScriptSaveOnUntitledDocumentFailsFast).
    let channel = AppleScriptChannel(
        runtime: .init(
            isLogicProRunning: { true },
            openFile: { _ in true },
            runScript: { source in
                if source.contains("character id 31") {
                    return await identities.next()
                }
                return await recorder.run(source)
            },
            executeTransportAction: { _ in .success("OK") },
            fileExists: { $0 == "/tmp/export.logicx" },
            fileModificationDate: { _ in Date.distantFuture },
            currentDocumentPath: { "/Users/x/Song.logicx" }
        )
    )

    let newProject = await channel.execute(operation: "project.new", params: [:])
    let saveProject = await channel.execute(operation: "project.save", params: [:])
    let saveAsProject = await channel.execute(
        operation: "project.save_as",
        params: ["path": "/tmp/export.logicx"]
    )
    let closeDefault = await channel.execute(operation: "project.close", params: [:])
    let closeAsk = await channel.execute(operation: "project.close", params: ["saving": "ask"])
    let closeNo = await channel.execute(operation: "project.close", params: ["saving": "no"])

    #expect(newProject.isSuccess)
    #expect(saveProject.isSuccess)
    #expect(saveAsProject.isSuccess)
    #expect(closeDefault.isSuccess)
    #expect(closeAsk.isSuccess)
    #expect(closeNo.isSuccess)

    let scripts = await recorder.snapshot()
    #expect(scripts.count == 6)
    #expect(scripts[0].contains("click menu item 1 of menu 1 of menu bar item 3"))
    #expect(scripts[0].contains("return name of window 1"))
    #expect(scripts[1].contains("save front document"))
    #expect(scripts[2].contains("save front document in (POSIX file"))
    #expect(scripts[2].contains("/tmp/export.logicx"))
    #expect(scripts[3].contains("close front document saving yes"))
    #expect(scripts[4].contains("close front document saving ask"))
    #expect(scripts[5].contains("close front document saving no"))
}

@Test func testAppleScriptSaveAsRejectsAbsoluteTraversalBeforeScript() async {
    let recorder = AppleScriptRecorder()
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(scriptRecorder: recorder)
    )

    let result = await channel.execute(
        operation: "project.save_as",
        params: ["path": "/tmp/project/../escape.logicx"]
    )

    #expect(!result.isSuccess)
    #expect(result.message.contains("absolute .logicx"))
    let scripts = await recorder.snapshot()
    #expect(scripts.isEmpty)
}

@Test func testAppleScriptSaveAsReturnsVerifiedWhenPackageExists() async throws {
    let recorder = AppleScriptRecorder()
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: recorder,
            fileExists: { $0 == "/tmp/export.logicx" }
        )
    )

    let result = await channel.execute(
        operation: "project.save_as",
        params: ["path": "/tmp/export.logicx"]
    )

    #expect(result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["observed"] as? String == "/tmp/export.logicx")
}

@Test func testAppleScriptSaveAsErrorsWhenPackageMissingAfterScriptSuccess() async throws {
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(fileExists: { _ in false })
    )

    let result = await channel.execute(
        operation: "project.save_as",
        params: ["path": "/tmp/missing.logicx"]
    )

    #expect(!result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "readback_mismatch")
}

@Test func testAppleScriptSaveAsErrorsWhenExistingPackageMtimeDoesNotAdvance() async throws {
    let staleDate = Date(timeIntervalSince1970: 1_000)
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            fileExists: { $0 == "/tmp/export.logicx" },
            fileModificationDate: { _ in staleDate }
        )
    )

    let result = await channel.execute(
        operation: "project.save_as",
        params: ["path": "/tmp/export.logicx"]
    )

    #expect(!result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect(((obj["hint"] as? String)?.contains("modification time did not advance"))!)
    #expect(obj["observed"] as? String == "/tmp/export.logicx")
}

@Test func testAppleScriptTransportCommandsGenerateExpectedScripts() async {
    let recorder = TransportActionRecorder()
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime(transportRecorder: recorder))

    let operations = [
        "transport.play": "play",
        "transport.stop": "stop",
        "transport.record": "record",
    ]

    for (operation, action) in operations {
        let result = await channel.execute(operation: operation, params: [:])
        #expect(result.isSuccess)
        let actions = await recorder.snapshot()
        #expect(actions.last == action)
    }
}

@Test func testAppleScriptTransportRejectsUnsupportedPauseCommand() async {
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime())

    let pause = await channel.execute(operation: "transport.pause", params: [:])
    #expect(!pause.isSuccess)
    #expect(pause.message.contains("Unsupported AppleScript operation"))
}

@Test func testAppleScriptExecutePropagatesScriptErrors() async {
    let recorder = AppleScriptRecorder()
    await recorder.setResult(.error("AppleScript error: boom"))
    // #144: titled document so the save reaches the script (and propagates its
    // error) rather than short-circuiting on the untitled fail-fast.
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: recorder,
            fileModificationDate: { _ in nil },
            currentDocumentPath: { "/Users/x/Song.logicx" }
        )
    )

    let result = await channel.execute(operation: "project.save", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("boom"))
}

@Test func testAppleScriptStartAndStopDoNotThrow() async throws {
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime())
    try await channel.start()
    await channel.stop()
}

@Test func testAppleScriptEscapeJSONEscapesControlCharacters() {
    let escaped = AppleScriptChannel.escapeJSON("Quote\" Slash\\ New\nLine\rCarriage\tTab")
    #expect(escaped == "Quote\\\" Slash\\\\ New\\nLine\\rCarriage\\tTab")
}

@Test func testAppleScriptExecuteReturnsInjectedJSONResult() async {
    let recorder = AppleScriptRecorder()
    await recorder.setResult(.success("{\"result\":\"hello\"}"))
    // #144: titled document on the healthy save path, but with a stale mtime
    // that does NOT advance past saveStartedAt — so the verdict stays the
    // honest State B this test asserts (script fired-but-unconfirmed), not the
    // untitled fail-fast (which would be State C and never fire the script).
    let stale = Date(timeIntervalSince1970: 1_000)
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: recorder,
            fileModificationDate: { _ in stale },
            currentDocumentPath: { "/Users/x/Song.logicx" }
        )
    )

    let result = await channel.execute(operation: "project.save", params: [:])

    #expect(result.isSuccess)
    // v3.1.1 (P2-2) — `project.save` is a mutating op so the response is now
    // wrapped in HC State B. The original `{"result":"hello"}` payload is
    // preserved verbatim inside the `raw` field of the envelope.
    #expect(result.message.contains("\"success\":true"))
    #expect(result.message.contains("\"verified\":false"))
    #expect(result.message.contains("\"operation\":\"project.save\""))
    #expect(result.message.contains("\"method\":\"applescript\""))
    #expect(result.message.contains("\"raw\":\"{\\\"result\\\":\\\"hello\\\"}\""))
}

@Test func testAppleScriptExecuteAppleScriptSurfacesCompileErrors() async {
    let result = await AppleScriptChannel.executeAppleScript("this is not valid AppleScript")
    #expect(!result.isSuccess)
    #expect(result.message.contains("AppleScript error"))
}

// MARK: - v3.1.8 (Issue #7) — currentDocumentPath static helper

@Test func testCurrentDocumentPath_parseEmpty_returnsNil() {
    let parsed = AppleScriptChannel.parseCurrentDocumentPath(
        from: .success("{\"result\":\"\"}")
    )
    #expect(parsed == nil)
}

@Test func testCurrentDocumentPath_parseTrimmed_returnsTrimmed() {
    let parsed = AppleScriptChannel.parseCurrentDocumentPath(
        from: .success("{\"result\":\"  /Users/x/A.logicx \\n\"}")
    )
    #expect(parsed == "/Users/x/A.logicx")
}

@Test func testCurrentDocumentPath_parseError_returnsNil() {
    let parsed = AppleScriptChannel.parseCurrentDocumentPath(
        from: .error("AppleScript error: TCC denied")
    )
    #expect(parsed == nil)
}

@Test func testCurrentDocumentPath_parseNonAbsoluteToken_returnsNil() {
    let parsed = AppleScriptChannel.parseCurrentDocumentPath(
        from: .success("{\"result\":\"OK\"}")
    )
    #expect(parsed == nil)
}

@Test func testCurrentDocumentPathScript_isStableShape() {
    let script = AppleScriptChannel.currentDocumentPathScript()
    #expect(script.contains("path of front document"))
    #expect(script.contains("count of documents"))
}

@Test func testCurrentDocumentIdentity_parseUntitledDocument_returnsNameWithoutPath() {
    let parsed = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success("{\"result\":\"\\u001fUntitled 7\"}")
    )
    #expect(parsed == AppleScriptChannel.FrontDocumentIdentity(path: nil, name: "Untitled 7"))
}

@Test func testCurrentDocumentIdentity_parseTitledDocument_returnsPathAndName() {
    let parsed = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success("{\"result\":\"/Users/x/A.logicx\\u001fA\"}")
    )
    #expect(parsed == AppleScriptChannel.FrontDocumentIdentity(path: "/Users/x/A.logicx", name: "A"))
}

@Test func testCurrentDocumentIdentity_parseBlank_returnsNil() {
    let parsed = AppleScriptChannel.parseCurrentDocumentIdentity(
        from: .success("{\"result\":\"\"}")
    )
    #expect(parsed == nil)
}

// MARK: - #144 — project.save fail-fast on untitled document

/// The untitled fail-fast must return State C `unsupported_state` BEFORE the
/// blocking `save front document` script is ever fired — proving the modal
/// Save-sheet hang is impossible. We assert the recorder captured ZERO scripts.
@Test func testAppleScriptSaveOnUntitledDocumentFailsFastWithoutFiringScript() async throws {
    let recorder = AppleScriptRecorder()
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: recorder,
            currentDocumentPath: { nil } // untitled: no on-disk path
        )
    )

    let result = await channel.execute(operation: "project.save", params: [:])

    #expect(!result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    let success = try #require(obj["success"] as? Bool)
    #expect(!success)
    #expect(obj["error"] as? String == "unsupported_state")
    let hint = try #require(obj["hint"] as? String)
    #expect(hint.contains("untitled"))
    #expect(hint.contains("save_as"))
    #expect(obj["operation"] as? String == "project.save")

    // The decisive assertion: NO save script was fired, so Logic's modal Save
    // sheet can never appear and the AppleEvent can never block.
    let scripts = await recorder.snapshot()
    #expect(scripts.isEmpty)
}

/// An empty-string document path (the AppleScript `""`-untitled signal) is the
/// same untitled case and must also fail fast without firing the script.
@Test func testAppleScriptSaveOnEmptyPathDocumentFailsFast() async throws {
    let recorder = AppleScriptRecorder()
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: recorder,
            currentDocumentPath: { "   " } // whitespace-only == untitled
        )
    )

    let result = await channel.execute(operation: "project.save", params: [:])

    #expect(!result.isSuccess)
    #expect(result.message.contains("unsupported_state"))
    let scripts = await recorder.snapshot()
    #expect(scripts.isEmpty)
}

/// A titled document MUST proceed to fire `save front document` (the healthy
/// verified-save path stays unchanged) — the fail-fast only fires when untitled.
@Test func testAppleScriptSaveOnTitledDocumentFiresSaveScript() async throws {
    let recorder = AppleScriptRecorder()
    let channel = AppleScriptChannel(
        runtime: makeAppleScriptRuntime(
            scriptRecorder: recorder,
            currentDocumentPath: { "/Users/x/Song.logicx" }
        )
    )

    let result = await channel.execute(operation: "project.save", params: [:])

    #expect(result.isSuccess)
    let scripts = await recorder.snapshot()
    let savedScript = try #require(scripts.first)
    #expect(savedScript.contains("save front document"))
}

/// Deterministic, side-effect-free helper: nil / empty / whitespace → State C;
/// any real path → nil (proceed). Each assertion can genuinely fail.
@Test func testUntitledSaveFailFast_deterministicTriState() throws {
    #expect(AppleScriptChannel.untitledSaveFailFast(documentPath: nil) != nil)
    #expect(AppleScriptChannel.untitledSaveFailFast(documentPath: "") != nil)
    #expect(AppleScriptChannel.untitledSaveFailFast(documentPath: "  \n ") != nil)
    // Titled → no fail-fast (proceed to the verified-save path).
    #expect(AppleScriptChannel.untitledSaveFailFast(documentPath: "/Users/x/A.logicx") == nil)

    // The State C it builds is the typed, terminal envelope the router surfaces.
    let failFast = try #require(AppleScriptChannel.untitledSaveFailFast(documentPath: nil))
    #expect(!failFast.isSuccess)
    #expect(HonestContract.isTerminalStateC(failFast.message))
    #expect(HonestContract.stateCErrorCode(failFast.message) == "unsupported_state")
}

// MARK: - #144 (B) — project.new observed_name enrichment

@Test func testAppleScriptProjectNewAttachesObservedName() async throws {
    let recorder = AppleScriptRecorder()
    let identities = ScriptResponseQueue([
        .success("/Users/x/Old.logicx\u{001F}Old"),
        .success("\u{001F}Untitled 17"),
    ])
    await recorder.setResult(.success("Untitled 17"))
    let channel = AppleScriptChannel(
        runtime: .init(
            isLogicProRunning: { true },
            openFile: { _ in true },
            runScript: { source in
                if source.contains("character id 31") {
                    return await identities.next()
                }
                return await recorder.run(source)
            },
            executeTransportAction: { _ in .success("OK") }
        )
    )

    let result = await channel.execute(operation: "project.new", params: [:])

    #expect(result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    let success = try #require(obj["success"] as? Bool)
    #expect(success)
    let verified = try #require(obj["verified"] as? Bool)
    #expect(!verified)
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["observed_name"] as? String == "Untitled 17")
}

@Test func testAppleScriptProjectNewFailsWhenFrontDocumentIdentityDoesNotChange() async throws {
    let recorder = AppleScriptRecorder()
    let identities = ScriptResponseQueue([
        .success("/Users/x/Old.logicx\u{001F}Old"),
        .success("/Users/x/Old.logicx\u{001F}Old"),
    ])
    await recorder.setResult(.success("Old"))
    let channel = AppleScriptChannel(
        runtime: .init(
            isLogicProRunning: { true },
            openFile: { _ in true },
            runScript: { source in
                if source.contains("character id 31") {
                    return await identities.next()
                }
                return await recorder.run(source)
            },
            executeTransportAction: { _ in .success("OK") }
        )
    )

    let result = await channel.execute(operation: "project.new", params: [:])

    #expect(!result.isSuccess)
    let obj = try JSONSerialization.jsonObject(
        with: Data(result.message.utf8), options: []
    ) as! [String: Any]
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "readback_mismatch")
    #expect(((obj["hint"] as? String)?.contains("did not change"))!)
}

/// newProjectExtras is the deterministic seam: a real name → observed_name; a
/// script error or blank name → no observed_name (envelope unchanged).
@Test func testNewProjectExtras_deterministic() {
    #expect(AppleScriptChannel.newProjectExtras(.success("Untitled 4"))["observed_name"] as? String == "Untitled 4")
    #expect(AppleScriptChannel.newProjectExtras(.success("  Demo  "))["observed_name"] as? String == "Demo")
    #expect(AppleScriptChannel.newProjectExtras(.success("   "))["observed_name"] == nil)
    #expect(AppleScriptChannel.newProjectExtras(.error("boom"))["observed_name"] == nil)
    // runScript wraps the value as {"result":"<name>"}; observed_name must be the
    // bare unwrapped name, not the raw JSON envelope.
    #expect(AppleScriptChannel.newProjectExtras(.success("{\"result\":\"Untitled\"}"))["observed_name"] as? String == "Untitled")
    #expect(AppleScriptChannel.newProjectExtras(.success("{\"result\":\"\"}"))["observed_name"] == nil)
}
