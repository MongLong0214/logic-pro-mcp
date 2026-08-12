import Foundation
import Testing
@testable import LogicProMCP

private let systemEventsAutomationDeniedHint =
    "System Events Automation is denied for the process responsible for launching this server (a launcher-permission gap, not a Logic limitation). Grant it in System Settings > Privacy & Security > Automation, or run the server/harness under a responsible app that already has it (Terminal, iTerm, or your editor). Logic Pro automation being granted is separate and not sufficient."

@Test func testSystemEventsAutomationDeniedClassifierMatchesKnownSignals() {
    let deniedMessages = [
        "execution error: osascript is not allowed to send Apple events to System Events. (-1743)",
        "Not authorized to send Apple events to System Events.",
        "errAEEventNotPermitted while talking to System Events",
    ]

    for message in deniedMessages {
        let actual = AppleScriptErrorClassifier.isSystemEventsAutomationDenied(message)
        // Mutation source: hard-code `isSystemEventsAutomationDenied` to false;
        // each bare positive assertion fails.
        #expect(actual)
    }
}

@Test func testSystemEventsAutomationDeniedClassifierRejectsUnrelatedErrors() {
    let unrelatedMessages = [
        "send Apple events to System Events",
        "Exported MIDI file take-1743.mid",
        "The operation could not be completed. -1743",
        "Logic Pro got an error: not authorized to send Apple events to Logic Pro. (-1743)",
        "System Events got an error: Can't get window 1. (-1728)",
    ]

    for message in unrelatedMessages {
        let actual = AppleScriptErrorClassifier.isSystemEventsAutomationDenied(message)
        // Mutation source: hard-code `isSystemEventsAutomationDenied` to true;
        // each bare negative assertion fails.
        #expect(!actual)
    }
}

@Test func testAppleScriptExecutionMapsSystemEventsAutomationDeniedToStateC() throws {
    let stderr = "execution error: Not authorized to send Apple events to System Events. (-1743)\n"
    let output = BoundedProcessRunner.Output(
        exitCode: 1,
        stdout: "",
        stderr: stderr,
        stdoutTruncated: false,
        stderrTruncated: false
    )

    let result = AppleScriptChannel.channelResult(forAppleScriptExecution: .completed(output))

    #expect(!result.isSuccess)
    let object = try #require(sharedJSONObject(result.message))
    let success = try #require(object["success"] as? Bool)
    let state = try #require(object["state"] as? String)
    let error = try #require(object["error"] as? String)
    let hint = try #require(object["hint"] as? String)
    let osascriptStderr = try #require(object["osascript_stderr"] as? String)
    #expect(!success)
    #expect(state == "C")
    #expect(error == "system_events_automation_denied")
    #expect(hint == systemEventsAutomationDeniedHint)
    #expect(osascriptStderr == stderr)
}

@Test func testAppleScriptExecutionLeavesOtherOsascriptFailuresGeneric() {
    let output = BoundedProcessRunner.Output(
        exitCode: 1,
        stdout: "",
        stderr: "execution error: Logic Pro got an error: Can't get document 1. (-1728)",
        stdoutTruncated: false,
        stderrTruncated: false
    )

    let result = AppleScriptChannel.channelResult(forAppleScriptExecution: .completed(output))

    #expect(!result.isSuccess)
    #expect(result.message == "AppleScript error: execution error: Logic Pro got an error: Can't get document 1. (-1728)")
}

@Test func testAppleScriptExecutionDoesNotClassifyStdoutFilenameAsSystemEventsDenial() {
    let output = BoundedProcessRunner.Output(
        exitCode: 1,
        stdout: "Exported MIDI file take-1743.mid\n",
        stderr: "execution error: Logic Pro got an error: Can't get document 1. (-1728)",
        stdoutTruncated: false,
        stderrTruncated: false
    )

    let result = AppleScriptChannel.channelResult(forAppleScriptExecution: .completed(output))

    #expect(!result.isSuccess)
    #expect(result.message == "AppleScript error: execution error: Logic Pro got an error: Can't get document 1. (-1728)")
}

@Test func testAppleScriptExecutionDoesNotClassifyLogicProAutomationDenialAsSystemEventsDenial() {
    let stderr = "execution error: Logic Pro got an error: Not authorized to send Apple events to Logic Pro. (-1743)"
    let output = BoundedProcessRunner.Output(
        exitCode: 1,
        stdout: "",
        stderr: stderr,
        stdoutTruncated: false,
        stderrTruncated: false
    )

    let result = AppleScriptChannel.channelResult(forAppleScriptExecution: .completed(output))

    #expect(!result.isSuccess)
    #expect(result.message == "AppleScript error: \(stderr)")
}

@Test func testSystemEventsAutomationDeniedIsTerminalStateC() {
    #expect(HonestContract.FailureError.systemEventsAutomationDenied.rawValue == "system_events_automation_denied")
    #expect(HonestContract.terminalErrorCodes.contains("system_events_automation_denied"))
}
