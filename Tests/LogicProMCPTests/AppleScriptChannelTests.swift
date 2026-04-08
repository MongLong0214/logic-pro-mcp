import Foundation
import Testing
@testable import LogicProMCP

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
    transportRecorder: TransportActionRecorder = TransportActionRecorder()
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
        }
    )
}

@Test func testAppleScriptHealthReflectsRunningState() async {
    let available = AppleScriptChannel(runtime: makeAppleScriptRuntime(isRunning: true))
    let unavailable = AppleScriptChannel(runtime: makeAppleScriptRuntime(isRunning: false))

    let healthy = await available.healthCheck()
    #expect(healthy.available)
    #expect(healthy.detail == "AppleScript ready")

    let missing = await unavailable.healthCheck()
    #expect(missing.available == false)
    #expect(missing.detail.contains("not running"))
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
    #expect(opened.message == "Opened: \(path)")
    #expect(openRecorder.snapshot() == [path])
    let scripts = await scriptRecorder.snapshot()
    #expect(scripts.count == 1)
    #expect(scripts[0].contains("POSIX path of (path of front document)"))
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

@Test func testAppleScriptProjectCommandsGenerateExpectedScripts() async {
    let recorder = AppleScriptRecorder()
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime(scriptRecorder: recorder))

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
    #expect(scripts[0].contains("make new document"))
    #expect(scripts[0].contains("return name of newDocument"))
    #expect(scripts[1].contains("save front document"))
    #expect(scripts[2].contains("save front document in (POSIX file"))
    #expect(scripts[2].contains("/tmp/export.logicx"))
    #expect(scripts[3].contains("close front document saving yes"))
    #expect(scripts[4].contains("close front document saving ask"))
    #expect(scripts[5].contains("close front document saving no"))
}

@Test func testAppleScriptTransportCommandsGenerateExpectedScripts() async {
    let recorder = TransportActionRecorder()
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime(transportRecorder: recorder))

    let operations = [
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

@Test func testAppleScriptTransportRejectsUnsupportedPlaybackCommands() async {
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime())

    let play = await channel.execute(operation: "transport.play", params: [:])
    #expect(!play.isSuccess)
    #expect(play.message.contains("Unsupported AppleScript operation"))

    let pause = await channel.execute(operation: "transport.pause", params: [:])
    #expect(!pause.isSuccess)
    #expect(pause.message.contains("Unsupported AppleScript operation"))
}

@Test func testAppleScriptExecutePropagatesScriptErrors() async {
    let recorder = AppleScriptRecorder()
    await recorder.setResult(.error("AppleScript error: boom"))
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime(scriptRecorder: recorder))

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
    let channel = AppleScriptChannel(runtime: makeAppleScriptRuntime(scriptRecorder: recorder))

    let result = await channel.execute(operation: "project.save", params: [:])

    #expect(result.isSuccess)
    #expect(result.message == "{\"result\":\"hello\"}")
}

@Test func testAppleScriptExecuteAppleScriptSurfacesCompileErrors() async {
    let result = await AppleScriptChannel.executeAppleScript("this is not valid AppleScript")
    #expect(!result.isSuccess)
    #expect(result.message.contains("AppleScript error"))
}
