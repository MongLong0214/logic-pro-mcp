import Darwin
import Foundation
import CoreGraphics
import Testing
@testable import LogicProMCP

final class CGEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var postedEvents: [(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t)] = []
    var failAtEventIndex: Int?

    func post(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let eventIndex = postedEvents.count
        if failAtEventIndex == eventIndex {
            return false
        }
        postedEvents.append((keyCode: keyCode, flags: flags, pid: pid))
        return true
    }

    func snapshot() -> [(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t)] {
        lock.lock()
        defer { lock.unlock() }
        return postedEvents
    }
}

private func makeCGEventRuntime(
    isRunning: Bool = true,
    pid: pid_t? = 42,
    recorder: CGEventRecorder = CGEventRecorder()
) -> CGEventChannel.Runtime {
    CGEventChannel.Runtime(
        isLogicProRunning: { isRunning },
        logicProPID: { pid },
        postKeyEvent: { keyCode, flags, pid in
            recorder.post(keyCode: keyCode, flags: flags, pid: pid)
        },
        sleepMicros: { _ in }
    )
}

@Test func testCGEventGotoPositionSequenceForBarFormat() {
    let sequence = CGEventChannel.gotoPositionSequence(for: "12.1.1.1")
    #expect(sequence != nil)
    #expect(sequence?.first?.keyCode == 44) // slash opens dialog
    #expect(sequence?.last?.keyCode == 36)  // return confirms
    #expect(sequence?.contains(where: { $0.keyCode == 47 }) == true) // period
}

@Test func testCGEventGotoPositionSequenceForTimecode() {
    let sequence = CGEventChannel.gotoPositionSequence(for: "01:02:03:04")
    #expect(sequence != nil)
    #expect(sequence?.contains(where: { $0.keyCode == 41 && $0.flags.contains(.maskShift) }) == true)
}

@Test func testCGEventGotoPositionSequenceRejectsUnsupportedCharacters() {
    let sequence = CGEventChannel.gotoPositionSequence(for: "Verse-A")
    #expect(sequence == nil)
}

@Test func testCGEventKeyStrokeMapsSupportedCharacters() {
    #expect(CGEventChannel.keyStroke(for: "0") == .key(29))
    #expect(CGEventChannel.keyStroke(for: "7") == .key(26))
    #expect(CGEventChannel.keyStroke(for: ".") == .key(47))
    #expect(CGEventChannel.keyStroke(for: ":") == .shift(41))
    #expect(CGEventChannel.keyStroke(for: "V") == nil)
    #expect(CGEventChannel.Shortcut.option(12) == .init(keyCode: 12, flags: .maskAlternate))
}

@Test func testCGEventHealthReflectsRuntimeState() async {
    let notRunning = CGEventChannel(runtime: makeCGEventRuntime(isRunning: false, pid: nil))
    let missingPID = CGEventChannel(runtime: makeCGEventRuntime(isRunning: true, pid: nil))
    let healthy = CGEventChannel(runtime: makeCGEventRuntime())

    let unavailable = await notRunning.healthCheck()
    #expect(unavailable.available == false)
    #expect(unavailable.detail.contains("not running"))

    let missingPIDHealth = await missingPID.healthCheck()
    #expect(missingPIDHealth.available == false)
    #expect(missingPIDHealth.detail.contains("Cannot determine"))

    let healthyState = await healthy.healthCheck()
    #expect(healthyState.available)
    #expect(healthyState.detail == "CGEvent ready")
}

@Test func testCGEventExecuteRequiresRunningLogicProProcess() async {
    let channel = CGEventChannel(runtime: makeCGEventRuntime(pid: nil))
    let result = await channel.execute(operation: "transport.play", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("not running"))
}

@Test func testCGEventExecuteRejectsUnknownOperation() async {
    let channel = CGEventChannel(runtime: makeCGEventRuntime())
    let result = await channel.execute(operation: "view.toggle_arranger", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("No keyboard shortcut mapped"))
}

@Test func testCGEventExecutePostsMappedShortcut() async {
    let recorder = CGEventRecorder()
    let channel = CGEventChannel(runtime: makeCGEventRuntime(recorder: recorder))

    let result = await channel.execute(operation: "project.save", params: [:])
    #expect(result.isSuccess)

    let events = recorder.snapshot()
    #expect(events.count == 1)
    #expect(events[0].keyCode == 1)
    #expect(events[0].flags == .maskCommand)
    #expect(events[0].pid == 42)
    #expect(result.message.contains("\"sent\":true"))
}

@Test func testCGEventExecuteReportsPostingFailure() async {
    let recorder = CGEventRecorder()
    recorder.failAtEventIndex = 0
    let channel = CGEventChannel(runtime: makeCGEventRuntime(recorder: recorder))

    let result = await channel.execute(operation: "project.save", params: [:])
    #expect(!result.isSuccess)
    #expect(result.message.contains("Failed to post CGEvent"))
}

@Test func testCGEventExecuteRejectsUnsupportedGotoFormat() async {
    let channel = CGEventChannel(runtime: makeCGEventRuntime())
    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "Verse-A"]
    )
    #expect(!result.isSuccess)
    #expect(result.message.contains("Unsupported position format"))
}

@Test func testCGEventExecutePostsGotoPositionSequence() async {
    let recorder = CGEventRecorder()
    let channel = CGEventChannel(runtime: makeCGEventRuntime(recorder: recorder))

    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "12.1.1.1"]
    )
    #expect(result.isSuccess)

    let events = recorder.snapshot()
    #expect(events.count == 10)
    #expect(events.first?.keyCode == 44)
    #expect(events.last?.keyCode == 36)
    #expect(events.filter { $0.keyCode == 47 }.count == 3)
}

@Test func testCGEventExecuteSupportsTimeAliasAndDefaultPosition() async {
    let aliasRecorder = CGEventRecorder()
    let aliasChannel = CGEventChannel(runtime: makeCGEventRuntime(recorder: aliasRecorder))

    let aliasResult = await aliasChannel.execute(
        operation: "transport.goto_position",
        params: ["time": "01:02:03:04"]
    )
    #expect(aliasResult.isSuccess)
    #expect(aliasResult.message.contains("\"position\":\"01:02:03:04\""))

    let defaultRecorder = CGEventRecorder()
    let defaultChannel = CGEventChannel(runtime: makeCGEventRuntime(recorder: defaultRecorder))
    let defaultResult = await defaultChannel.execute(
        operation: "transport.goto_position",
        params: [:]
    )
    #expect(defaultResult.isSuccess)
    #expect(defaultResult.message.contains("\"position\":\"1.1.1.1\""))
}

@Test func testCGEventExecuteReportsGotoPositionPostingFailure() async {
    let recorder = CGEventRecorder()
    recorder.failAtEventIndex = 2
    let channel = CGEventChannel(runtime: makeCGEventRuntime(recorder: recorder))

    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "1.1.1.1"]
    )
    #expect(!result.isSuccess)
    #expect(result.message.contains("Failed to post CGEvent sequence"))
}

@Test func testCGEventExecuteReportsGotoPositionFailureOnFirstShortcut() async {
    let recorder = CGEventRecorder()
    recorder.failAtEventIndex = 0
    let channel = CGEventChannel(runtime: makeCGEventRuntime(recorder: recorder))

    let result = await channel.execute(
        operation: "transport.goto_position",
        params: ["position": "1.1.1.1"]
    )
    #expect(!result.isSuccess)
    #expect(result.message.contains("Failed to post CGEvent sequence"))
    #expect(recorder.snapshot().isEmpty)
}

@Test func testCGEventStartReturnsWithoutThrowingInBothRuntimeStates() async throws {
    let notRunning = CGEventChannel(runtime: makeCGEventRuntime(isRunning: false))
    let running = CGEventChannel(runtime: makeCGEventRuntime(isRunning: true))

    try await notRunning.start()
    try await running.start()
}

@Test func testCGEventProductionRuntimeSmokeExecutesWithoutCrash() {
    let runtime = CGEventChannel.Runtime.production

    _ = runtime.isLogicProRunning()
    _ = runtime.logicProPID()
    runtime.sleepMicros(0)
    let sent = runtime.postKeyEvent(0, [], getpid())

    #expect(sent == true || sent == false)
}
