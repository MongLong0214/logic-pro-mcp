import Foundation
import Testing
@testable import LogicProMCP

// #1596: a desktop MCP client starts stdio servers through a `disclaimer` helper, which spawns
// them with TCC responsibility disclaimed. macOS then evaluates the LogicProMCP binary itself,
// not the client app, so a grant on the client does nothing. These tests pin that the permission report
// names the measured principal, and that the one prompting path asks for this binary.

private let desktopContext = "desktop_client"
private let cellarBinary = "/opt/homebrew/Cellar/logic-pro-mcp/3.19.0/bin/LogicProMCP"
private let ownPrincipal = TCCResponsibility.Principal(pid: 4242, path: cellarBinary, isSelf: true)
private let terminalPrincipal = TCCResponsibility.Principal(
    pid: 77,
    path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
    isSelf: false
)

private func doctorRuntime(context: String) -> SetupDoctor.Runtime {
    // launchContextCheck reads only the launch context seam.
    var runtime = SetupDoctor.Runtime.production
    runtime.launchContext = { SetupDoctor.LaunchContextInfo(context: context, responsibleHint: "DesktopClient") }
    return runtime
}

private func status(
    accessibility: PermissionChecker.CheckState,
    postEvent: PermissionChecker.CheckState,
    principal: TCCResponsibility.Principal?
) -> PermissionChecker.PermissionStatus {
    var status = PermissionChecker.PermissionStatus(
        accessibilityState: accessibility,
        automationState: .granted,
        systemEventsAutomationState: .notVerifiable,
        postEventAccessState: postEvent
    )
    status.principal = principal
    return status
}

// MARK: - Attribution mapping

@Test func test1596PrincipalIsSelfWhenResponsiblePidIsOwnPid() throws {
    let principal = try #require(TCCResponsibility.principal(
        selfPID: 10,
        responsiblePID: { _ in 10 },
        pathForPID: { _ in cellarBinary },
        homeDirectory: "/Users/someone"
    ))
    #expect(principal.isSelf)
    #expect(principal.path == cellarBinary)
}

@Test func test1596PrincipalIsLauncherWhenResponsibilityInherited() throws {
    let principal = try #require(TCCResponsibility.principal(
        selfPID: 10,
        responsiblePID: { _ in 3 },
        pathForPID: { $0 == 3 ? "/Users/someone/Applications/Editor.app/Contents/MacOS/Editor" : nil },
        homeDirectory: "/Users/someone"
    ))
    #expect(!principal.isSelf)
    #expect(principal.pid == 3)
    #expect(principal.path == "~/Applications/Editor.app/Contents/MacOS/Editor")
}

@Test func test1596UnmeasuredPrincipalIsNilNotGuessed() {
    #expect(TCCResponsibility.principal(
        selfPID: 10,
        responsiblePID: { _ in nil },
        pathForPID: { _ in cellarBinary },
        homeDirectory: nil
    ) == nil)
}

// MARK: - --check-permissions / logic_system permissions summary

@Test func test1596CheckNamesOwnBinaryAsPrincipalWithoutRequestingSetup() {
    let runtime = PermissionChecker.Runtime(
        checkAccessibility: { _ in false },
        isLogicProRunning: { true },
        runAutomationProbe: { true },
        runSystemEventsAutomationProbe: { .granted },
        postEventPreflight: { false },
        responsiblePrincipal: { ownPrincipal }
    )
    let checked = PermissionChecker.check(runtime: runtime)
    #expect(checked.principal == ownPrincipal)
    #expect(!checked.allGranted)
    let summary = checked.summary
    #expect(summary.contains("TCC principal: this LogicProMCP binary itself (\(cellarBinary))"))
    #expect(summary.contains("Accessibility: NOT GRANTED"))
    #expect(summary.contains("PostEvent (CGEvent): NOT GRANTED"))
    // The check path stays non-prompting and asks for no manual continuation.
    for prohibited in ["System Settings", "grant PostEvent", "rerun --check-permissions"] {
        #expect(!summary.contains(prohibited))
    }
}

@Test func test1596CheckNamesInheritedLauncherAsPrincipal() {
    var granted = PermissionChecker.PermissionStatus(
        accessibilityState: .granted, automationState: .granted,
        systemEventsAutomationState: .granted, postEventAccessState: .granted
    )
    granted.principal = terminalPrincipal
    #expect(granted.summary.contains("TCC principal: \(terminalPrincipal.displayPath) (the responsible process that launched this server)"))
    #expect(!granted.summary.contains("this LogicProMCP binary itself"))
}

// MARK: - doctor

@Test func test1596DoctorLaunchContextDoesNotClaimLauncherWhenBinaryIsItsOwnPrincipal() throws {
    let check = SetupDoctor.launchContextCheck(
        runtime: doctorRuntime(context: desktopContext),
        permissionStatus: status(accessibility: .notGranted, postEvent: .notGranted, principal: ownPrincipal)
    )
    #expect(check.summary.contains("TCC evaluates this LogicProMCP binary itself (\(cellarBinary))"))
    #expect(!check.summary.contains("measures TCC permissions for the responsible process \(desktopContext)"))
    #expect(check.evidence["tcc_principal"] == cellarBinary)
    #expect(check.evidence["tcc_principal_is_self"] == "true")
    #expect(check.evidence["launch_context"] == desktopContext)
    #expect(check.remediation.type == .none)
}

@Test func test1596DoctorDeniedChecksNameTheDeniedPrincipalAndFail() {
    let denied = status(accessibility: .notGranted, postEvent: .notGranted, principal: ownPrincipal)
    let accessibility = SetupDoctor.accessibilityPermissionCheck(denied)
    let postEvent = SetupDoctor.postEventAccessCheck(denied)
    #expect(accessibility.status == .fail)
    #expect(postEvent.status == .fail)
    #expect(accessibility.summary == "Accessibility permission is not granted for this LogicProMCP binary (\(cellarBinary)).")
    #expect(postEvent.summary.hasPrefix("PostEvent access is denied for this LogicProMCP binary (\(cellarBinary));"))
    #expect(postEvent.evidence["tcc_principal_is_self"] == "true")
    #expect(postEvent.evidence["post_event_access"] == "denied")
}

@Test func test1596DoctorKeepsLegacyTextWhenPrincipalUnmeasured() {
    let check = SetupDoctor.launchContextCheck(
        runtime: doctorRuntime(context: "terminal"),
        permissionStatus: status(accessibility: .granted, postEvent: .granted, principal: nil)
    )
    #expect(check.summary == "This report measures TCC permissions for the responsible process terminal; permission results are bound to that launch context.")
    #expect(check.evidence["tcc_principal"] == nil)
}

// MARK: - --request-permissions

private final class RequestRecorder: @unchecked Sendable {
    var spawned: [(String, [String])] = []
    var accessibilityRequests = 0
    var postEventRequests = 0
    var stderr = ""
}

private func requestRuntime(
    _ recorder: RequestRecorder,
    principal: TCCResponsibility.Principal?,
    spawnOutcome: TCCResponsibility.SpawnOutcome = .exited(0),
    granted: Bool = false
) -> PermissionRequestCommand.Runtime {
    PermissionRequestCommand.Runtime(
        principal: { principal },
        ownExecutablePath: { cellarBinary },
        runDisclaimed: { executable, arguments in
            recorder.spawned.append((executable, arguments))
            return spawnOutcome
        },
        requestAccessibility: { recorder.accessibilityRequests += 1; return granted },
        requestPostEvent: { recorder.postEventRequests += 1; return granted }
    )
}

@Test func test1596RequestFromLauncherSpawnsDisclaimedCopyInsteadOfRequestingInProcess() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        runtime: requestRuntime(recorder, principal: terminalPrincipal, spawnOutcome: .exited(1)),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.spawned.count == 1)
    #expect(recorder.spawned.first?.0 == cellarBinary)
    #expect(recorder.spawned.first?.1 == [PermissionRequestCommand.disclaimedChildFlag])
    // An in-process request here would be recorded for Terminal, not for this binary.
    #expect(recorder.accessibilityRequests == 0)
    #expect(recorder.postEventRequests == 0)
}

@Test func test1596RequestAsOwnPrincipalAsksForBothAndNamesThePath() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: requestRuntime(recorder, principal: ownPrincipal),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.spawned.isEmpty)
    #expect(recorder.accessibilityRequests == 1)
    #expect(recorder.postEventRequests == 1)
    #expect(recorder.stderr.contains("Requested for: \(cellarBinary)"))
    #expect(recorder.stderr.contains("PostEvent (CGEvent): NOT GRANTED"))
}

@Test func test1596RequestSucceedsOnlyWhenBothGranted() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        runtime: requestRuntime(recorder, principal: ownPrincipal, granted: true),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 0)
    #expect(recorder.spawned.isEmpty)
}

@Test func test1596DisclaimedCopyThatIsNotItsOwnPrincipalRefuses() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: requestRuntime(recorder, principal: terminalPrincipal),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 0)
    #expect(recorder.postEventRequests == 0)
    #expect(recorder.spawned.isEmpty)
}

@Test func test1596RequestRefusesWhenDisclaimIsUnavailable() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        runtime: requestRuntime(recorder, principal: nil, spawnOutcome: .disclaimUnavailable),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 0)
    #expect(recorder.stderr.contains("no permission was requested"))
}

@Test func test1596EntrypointRoutesRequestFlagWithoutServerOrCheck() async {
    var routed: [String] = []
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        permissionCheck: {
            Issue.record("--request-permissions must not run the non-prompting check")
            return .init(accessibility: false, automationLogicPro: false)
        },
        serverFactory: {
            Issue.record("--request-permissions must not start the server")
            return LogicProServer()
        },
        requestPermissions: { arguments, write in
            routed = arguments
            write("requested\n")
            return 3
        },
        writeStderr: { stderr += $0 }
    )
    #expect(exitCode == 3)
    #expect(routed == ["LogicProMCP", "--request-permissions"])
    #expect(stderr == "requested\n")
    #expect(MainEntrypoint.usageText.contains("--request-permissions"))
}

// MARK: - The real spawn mechanism (no TCC request is made)

@Test func test1596DisclaimedSpawnRunsChildAndPropagatesExitStatus() {
    #expect(TCCResponsibility.runDisclaimed(executable: "/usr/bin/true", arguments: []) == .exited(0))
    #expect(TCCResponsibility.runDisclaimed(executable: "/usr/bin/false", arguments: []) == .exited(1))
    #expect(TCCResponsibility.runDisclaimed(executable: "/nonexistent/LogicProMCP", arguments: []) == .spawnFailed(ENOENT))
}

@Test func test1596ResponsibilityQueryResolvesOnThisSystem() {
    #expect(TCCResponsibility.responsiblePID(for: getpid()) != nil)
}
