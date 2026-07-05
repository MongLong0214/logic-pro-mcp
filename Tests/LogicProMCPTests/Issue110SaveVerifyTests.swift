import Foundation
import Testing
@testable import LogicProMCP

/// #110: project.save is an export/bounce prerequisite and must not report
/// success without read-back. `AppleScriptChannel.verifiedSaveResult` decides
/// the HC verdict from the front document's `.logicx` package mtime — the
/// authoritative file evidence — so a confirmed write is verified State A even
/// when `save front document` times out its AppleEvent reply (-1712).
@Suite("Issue110 save verification")
struct Issue110SaveVerifyTests {
    private func obj(_ r: ChannelResult) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(r.message.utf8))) as? [String: Any]
    }

    private let scriptOK = ChannelResult.success("{\"result\":\"\"}")
    private let scriptTimeout = ChannelResult.error("AppleScript error: AppleEvent timed out (-1712)")

    @Test("verified State A when the package mtime advances past the save start")
    func verifiedWhenWritten() {
        let started = Date()
        let result = AppleScriptChannel.verifiedSaveResult(
            scriptOK,
            documentPath: "/Users/x/Song.logicx",
            beforeMtime: started.addingTimeInterval(-60),
            afterMtime: started.addingTimeInterval(0.4),
            saveStartedAt: started
        )
        #expect(result.isSuccess)
        let o = obj(result)
        #expect((o?["verified"] as? Bool)!)
        #expect(o?["verify_source"] as? String == "file_mtime")
        #expect(o?["document_path"] as? String == "/Users/x/Song.logicx")
    }

    @Test("a -1712 reply timeout is still verified State A when the file was written")
    func timeoutButWrittenIsVerified() {
        let started = Date()
        let result = AppleScriptChannel.verifiedSaveResult(
            scriptTimeout, // save front document timed out its reply…
            documentPath: "/Users/x/Song.logicx",
            beforeMtime: started.addingTimeInterval(-60),
            afterMtime: started.addingTimeInterval(0.6), // …but the package was written
            saveStartedAt: started
        )
        #expect(result.isSuccess)
        #expect((obj(result)?["verified"] as? Bool)!)
    }

    @Test("errored script + no write surfaces the error verbatim (terminal)")
    func erroredAndNotWrittenFailsClosed() {
        let started = Date()
        let result = AppleScriptChannel.verifiedSaveResult(
            scriptTimeout,
            documentPath: "/Users/x/Song.logicx",
            beforeMtime: started.addingTimeInterval(-60),
            afterMtime: started.addingTimeInterval(-60), // unchanged
            saveStartedAt: started
        )
        #expect(!result.isSuccess)
        #expect(result.message.contains("1712"))
    }

    @Test("State B (no false success) when success but mtime did not advance")
    func successButNotWrittenIsStateB() {
        let started = Date()
        let result = AppleScriptChannel.verifiedSaveResult(
            scriptOK,
            documentPath: "/Users/x/Song.logicx",
            beforeMtime: started.addingTimeInterval(-60),
            afterMtime: started.addingTimeInterval(-60),
            saveStartedAt: started
        )
        #expect(result.isSuccess)
        #expect(!((obj(result)?["verified"] as? Bool)!))
    }

    @Test("untitled document (no path) stays an honest State B")
    func untitledStaysStateB() {
        let result = AppleScriptChannel.verifiedSaveResult(
            scriptOK, documentPath: nil, beforeMtime: nil, afterMtime: nil, saveStartedAt: Date()
        )
        #expect(result.isSuccess)
        let o = obj(result)
        #expect(!((o?["verified"] as? Bool)!))
        #expect(((o?["reason_detail"] as? String)?.contains("untitled"))!)
    }

    // #144 — channel-level fail-fast: driving `project.save` end-to-end through
    // the channel on an UNTITLED document must short-circuit to a terminal State
    // C `unsupported_state` BEFORE the blocking `save front document` script is
    // ever recorded. This is the contract that converts a guaranteed modal
    // Save-sheet hang into an instant honest failure. The titled-doc case below
    // proves the healthy verified-save path is unchanged.
    @Test("project.save on an untitled document fails fast before any script fires")
    func untitledSaveFailsFastBeforeScript() async throws {
        let recorder = SaveScriptRecorder()
        let channel = AppleScriptChannel(
            runtime: makeRuntime(recorder: recorder, documentPath: nil)
        )

        let result = await channel.execute(operation: "project.save", params: [:])

        #expect(!result.isSuccess)
        let o = try #require(obj(result))
        let success = try #require(o["success"] as? Bool)
        #expect(!success)
        #expect(o["error"] as? String == "unsupported_state")
        let hint = try #require(o["hint"] as? String)
        #expect(hint.contains("untitled"))
        #expect(hint.contains("save_as"))
        // Decisive: zero scripts recorded ⇒ no modal Save sheet, no AppleEvent block.
        let scripts = await recorder.snapshot()
        #expect(scripts.isEmpty)
    }

    @Test("project.save on a titled document still fires the save script")
    func titledSaveFiresScript() async throws {
        let recorder = SaveScriptRecorder()
        let channel = AppleScriptChannel(
            runtime: makeRuntime(recorder: recorder, documentPath: "/Users/x/Song.logicx")
        )

        let result = await channel.execute(operation: "project.save", params: [:])

        #expect(result.isSuccess)
        let scripts = await recorder.snapshot()
        let fired = try #require(scripts.first)
        #expect(fired.contains("save front document"))
    }

    // Local recorder + Runtime builder so this suite is self-contained (the
    // helper in AppleScriptChannelTests is file-private to that file).
    private actor SaveScriptRecorder {
        private var scripts: [String] = []
        func run(_ source: String) -> ChannelResult {
            scripts.append(source)
            return .success("{\"result\":\"\"}")
        }
        func snapshot() -> [String] { scripts }
    }

    private func makeRuntime(
        recorder: SaveScriptRecorder,
        documentPath: String?
    ) -> AppleScriptChannel.Runtime {
        AppleScriptChannel.Runtime(
            isLogicProRunning: { true },
            openFile: { _ in true },
            runScript: { source in await recorder.run(source) },
            executeTransportAction: { _ in .success("{\"result\":\"\"}") },
            // distantFuture mtime ⇒ titled-doc save reads back as written (State A),
            // keeping the healthy path's success verdict for the titled test.
            fileExists: { _ in true },
            fileModificationDate: { _ in Date.distantFuture },
            currentDocumentPath: { documentPath }
        )
    }
}
