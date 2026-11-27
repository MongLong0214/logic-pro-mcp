import Foundation
import Testing
import MCP
@testable import LogicProMCP

// #1596: a desktop MCP client starts stdio servers through a `disclaimer` helper, which spawns
// them with TCC responsibility disclaimed. macOS then evaluates the LogicProMCP binary itself,
// not the client app, so a grant on the client does nothing. These tests pin that the permission report
// names the measured principal, and that the one prompting path asks for this binary.

private let desktopContext = "desktop_client"
private let cellarBinary = "/opt/homebrew/Cellar/logic-pro-mcp/3.19.0/bin/LogicProMCP"
// Private directories: one under the home directory, one on another volume.
private let privateHome = "/Users/someone"
private let privateHomeBinary = "/Users/someone/clients/acme/secret-album/.build/release/LogicProMCP"
private let outsideHomeBinary = "/Volumes/Acme Records/secret-album/bin/LogicProMCP"
private let privateFragments = ["clients", "acme", "Acme", "secret", "Volumes", "someone", "/Users", "~"]
private let ownPrincipal = TCCResponsibility.Principal(pid: 4242, label: "LogicProMCP (homebrew)", isSelf: true)
private let terminalPrincipal = TCCResponsibility.Principal(pid: 77, label: "Terminal (app bundle, com.apple.Terminal)", isSelf: false)

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
        pathForPID: { _ in cellarBinary }
    ))
    #expect(principal.isSelf)
    #expect(principal.label == "LogicProMCP (homebrew)")
}

@Test func test1596PrincipalIsLauncherWhenResponsibilityInherited() throws {
    let principal = try #require(TCCResponsibility.principal(
        selfPID: 10,
        responsiblePID: { _ in 3 },
        pathForPID: { $0 == 3 ? "\(privateHome)/Applications/Editor.app/Contents/MacOS/Editor" : nil }
    ))
    #expect(!principal.isSelf)
    #expect(principal.pid == 3)
    #expect(principal.label == "Editor (app bundle)")
}

@Test func test1596UnmeasuredPrincipalIsNilNotGuessed() {
    #expect(TCCResponsibility.principal(
        selfPID: 10,
        responsiblePID: { _ in nil },
        pathForPID: { _ in cellarBinary }
    ) == nil)
}

@Test func test1596PublicLabelNeverCarriesADirectory() {
    for path in [privateHomeBinary, outsideHomeBinary, cellarBinary, "/tmp/x y/LogicProMCP"] {
        let label = TCCResponsibility.publicLabel(forExecutablePath: path, bundleIdentifier: { _ in nil })
        #expect(!label.contains("/"), "\(label)")
        for fragment in privateFragments { #expect(!label.contains(fragment), "\(label) leaked \(fragment)") }
    }
    #expect(TCCResponsibility.publicLabel(forExecutablePath: privateHomeBinary, bundleIdentifier: { _ in nil }) == "LogicProMCP (source build)")
    #expect(TCCResponsibility.publicLabel(forExecutablePath: outsideHomeBinary, bundleIdentifier: { _ in nil }) == "LogicProMCP (other install)")
    #expect(TCCResponsibility.publicLabel(
        forExecutablePath: "/Applications/Editor.app/Contents/MacOS/Editor", bundleIdentifier: { _ in "com.example.editor" }
    ) == "Editor (app bundle, com.example.editor)")
    // A basename that is itself not a plain executable name is not echoed.
    #expect(TCCResponsibility.publicLabel(forExecutablePath: "/x/acme\u{202E}secret", bundleIdentifier: { _ in nil }).hasPrefix("unnamed executable"))
}

private func measuredPrincipal(path: String, isSelf: Bool = true) throws -> TCCResponsibility.Principal {
    try #require(TCCResponsibility.principal(
        selfPID: 10,
        responsiblePID: { _ in isSelf ? 10 : 3 },
        pathForPID: { _ in path }
    ))
}

// MARK: - Public output never carries a private path (TCC-PRIVATE-OUTPUT)

@Test func test1596McpPermissionsResponseCarriesNoPrivatePath() throws {
    for path in [privateHomeBinary, outsideHomeBinary] {
        for isSelf in [true, false] {
            var denied = PermissionChecker.PermissionStatus(
                accessibilityState: .notGranted, automationState: .granted,
                systemEventsAutomationState: .granted, postEventAccessState: .notGranted
            )
            denied.principal = try measuredPrincipal(path: path, isSelf: isSelf)
            let result = SystemDispatcher.permissionsResult(denied)
            guard case .text(let text, _, _) = try #require(result.content.first),
                  case .object(let fields) = try #require(result.structuredContent) else {
                Issue.record("expected text and structured content"); return
            }
            let structured = String(decoding: try JSONEncoder().encode(Value.object(fields)), as: UTF8.self)
            for output in [text, structured] {
                for fragment in privateFragments { #expect(!output.contains(fragment), "\(fragment) in \(output)") }
            }
            #expect(fields["tcc_principal"] == .string("LogicProMCP (\(path == privateHomeBinary ? "source build" : "other install"))"))
            #expect(fields["tcc_principal_is_self"] == .bool(isSelf))
        }
    }
}

@Test func test1596DoctorChecksCarryNoPrivatePath() throws {
    for path in [privateHomeBinary, outsideHomeBinary] {
        for isSelf in [true, false] {
            var denied = PermissionChecker.PermissionStatus(
                accessibilityState: .notGranted, automationState: .granted,
                systemEventsAutomationState: .notGranted, postEventAccessState: .notGranted
            )
            denied.principal = try measuredPrincipal(path: path, isSelf: isSelf)
            let checks = [
                SetupDoctor.accessibilityPermissionCheck(denied),
                SetupDoctor.postEventAccessCheck(denied),
                SetupDoctor.systemEventsAutomationCheck(denied),
                SetupDoctor.launchContextCheck(runtime: doctorRuntime(context: "terminal"), permissionStatus: denied),
            ]
            for check in checks {
                let rendered = String(decoding: try JSONEncoder().encode(check), as: UTF8.self)
                for fragment in privateFragments { #expect(!rendered.contains(fragment), "\(check.id) leaked \(fragment)") }
            }
        }
    }
}

@Test func test1596CheckPermissionsSummaryCarriesNoPrivatePath() throws {
    var checked = PermissionChecker.PermissionStatus(
        accessibilityState: .notGranted, automationState: .granted,
        systemEventsAutomationState: .granted, postEventAccessState: .notGranted
    )
    checked.principal = try measuredPrincipal(path: privateHomeBinary)
    for fragment in privateFragments { #expect(!checked.summary.contains(fragment)) }
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
    #expect(summary.contains("TCC principal: this LogicProMCP binary itself (LogicProMCP (homebrew))"))
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
    #expect(granted.summary.contains("TCC principal: \(terminalPrincipal.displayName) (the responsible process that launched this server)"))
    #expect(!granted.summary.contains("this LogicProMCP binary itself"))
}

// MARK: - doctor attribution (TCC-ATTRIBUTION)

@Test func test1596DoctorLaunchContextNamesOnlyTheMeasuredPrincipalWhenSelf() {
    let check = SetupDoctor.launchContextCheck(
        runtime: doctorRuntime(context: desktopContext),
        permissionStatus: status(accessibility: .notGranted, postEvent: .notGranted, principal: ownPrincipal)
    )
    #expect(check.summary.contains("measured for this LogicProMCP binary itself (LogicProMCP (homebrew))"))
    #expect(check.summary.contains("launch context hint: \(desktopContext)"))
    #expect(check.evidence["tcc_principal"] == "LogicProMCP (homebrew)")
    #expect(check.evidence["tcc_principal_is_self"] == "true")
    #expect(check.evidence["launch_context"] == desktopContext)
    #expect(check.remediation.type == .none)
}

@Test func test1596DoctorDifferingIdentitiesAttributeToTheMeasuredPrincipalOnly() {
    // Measured Terminal, but the environment hints say vscode: the report must not say the
    // grants were measured for vscode.
    let check = SetupDoctor.launchContextCheck(
        runtime: doctorRuntime(context: "vscode"),
        permissionStatus: status(accessibility: .granted, postEvent: .granted, principal: terminalPrincipal)
    )
    #expect(check.summary == "Permission results were measured for the responsible process \(terminalPrincipal.displayName) (launch context hint: vscode).")
    #expect(check.evidence["tcc_principal"] == terminalPrincipal.displayName)
    #expect(!check.summary.contains("measures TCC permissions for the responsible process vscode"))
}

@Test func test1596DoctorUnknownContextWithMeasuredPrincipalDoesNotClaimUnidentified() {
    let check = SetupDoctor.launchContextCheck(
        runtime: doctorRuntime(context: "unknown"),
        permissionStatus: status(accessibility: .granted, postEvent: .granted, principal: terminalPrincipal)
    )
    #expect(!check.summary.contains("could not identify"))
    #expect(!check.summary.contains("could not be measured"))
    #expect(check.summary.contains(terminalPrincipal.displayName))
}

@Test func test1596DoctorMissingMeasurementIsExplicitlyUnresolvedNotAttributedToTheContext() {
    let granted = status(accessibility: .granted, postEvent: .granted, principal: nil)
    let check = SetupDoctor.launchContextCheck(runtime: doctorRuntime(context: "cursor"), permissionStatus: granted)
    #expect(check.summary.contains("identity is unresolved"))
    #expect(check.summary.contains("launch context hint: cursor"))
    #expect(!check.summary.contains("responsible process cursor"))
    #expect(check.evidence["tcc_principal"] == "unresolved")
    // The live probe results are still shown.
    #expect(SetupDoctor.accessibilityPermissionCheck(granted).summary == "Accessibility permission is granted.")
    #expect(SetupDoctor.accessibilityPermissionCheck(granted).status == .pass)
}

@Test func test1596DoctorSystemEventsDenialNamesTheMeasuredPrincipalNotTheLauncher() {
    func denial(_ principal: TCCResponsibility.Principal?) -> String {
        var denied = PermissionChecker.PermissionStatus(
            accessibilityState: .granted, automationState: .granted,
            systemEventsAutomationState: .notGranted, postEventAccessState: .granted
        )
        denied.principal = principal
        return SetupDoctor.systemEventsAutomationCheck(denied).summary
    }
    let own = denial(ownPrincipal)
    #expect(own == "Automation permission for System Events is not granted for this LogicProMCP binary (LogicProMCP (homebrew)); Logic Pro automation is separate.")
    #expect(!own.contains("launcher"))
    #expect(denial(terminalPrincipal).contains("not granted for \(terminalPrincipal.displayName);"))
    #expect(denial(nil).contains("identity unresolved"))
}

@Test func test1596DoctorDeniedChecksNameTheDeniedPrincipalAndFail() {
    let denied = status(accessibility: .notGranted, postEvent: .notGranted, principal: ownPrincipal)
    let accessibility = SetupDoctor.accessibilityPermissionCheck(denied)
    let postEvent = SetupDoctor.postEventAccessCheck(denied)
    #expect(accessibility.status == .fail)
    #expect(postEvent.status == .fail)
    #expect(accessibility.summary == "Accessibility permission is not granted for this LogicProMCP binary (LogicProMCP (homebrew)).")
    #expect(postEvent.summary.hasPrefix("PostEvent access is denied for this LogicProMCP binary (LogicProMCP (homebrew));"))
    #expect(postEvent.evidence["tcc_principal_is_self"] == "true")
    #expect(postEvent.evidence["post_event_access"] == "denied")
}

// MARK: - --request-permissions (TCC-REQUEST-DISCLAIM)

private final class RequestRecorder: @unchecked Sendable {
    var spawned: [(String, [String], [String: String])] = []
    var accessibilityRequests = 0
    var postEventRequests = 0
    var stderr = ""
}

private func requestRuntime(
    _ recorder: RequestRecorder,
    principal: TCCResponsibility.Principal?,
    spawnOutcome: TCCResponsibility.SpawnOutcome = .exited(0),
    granted: Bool = false,
    postEventGranted: Bool? = nil,
    environment: [String: String] = [:],
    parentPID: pid_t = 900
) -> PermissionRequestCommand.Runtime {
    PermissionRequestCommand.Runtime(
        principal: { principal },
        ownExecutablePath: { privateHomeBinary },
        runDisclaimed: { executable, arguments, extra in
            recorder.spawned.append((executable, arguments, extra))
            return spawnOutcome
        },
        requestAccessibility: { recorder.accessibilityRequests += 1; return granted },
        requestPostEvent: { recorder.postEventRequests += 1; return postEventGranted ?? granted },
        environment: { environment },
        ownPID: { 900 },
        parentPID: { parentPID },
        makeToken: { "token-1" },
        resolveTarget: { $0.hasPrefix("/") ? $0 : nil },
        labelForPath: { TCCResponsibility.publicLabel(forExecutablePath: $0, bundleIdentifier: { _ in nil }) }
    )
}

private let validProvenance = [PermissionRequestCommand.provenanceVariable: "900:token-1"]

@Test func test1596PublicRequestAlwaysSpawnsEvenWhenAlreadySelf() {
    for principal in [ownPrincipal, terminalPrincipal, nil] as [TCCResponsibility.Principal?] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"],
            runtime: requestRuntime(recorder, principal: principal, spawnOutcome: .exited(1)),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1)
        #expect(recorder.spawned.count == 1)
        #expect(recorder.spawned.first?.0 == privateHomeBinary)
        #expect(recorder.spawned.first?.1 == [PermissionRequestCommand.disclaimedChildFlag])
        #expect(recorder.spawned.first?.2 == validProvenance)
        // Neither prompting API runs in this process, whatever it measures.
        #expect(recorder.accessibilityRequests == 0)
        #expect(recorder.postEventRequests == 0)
    }
}

@Test func test1596PublicRequestRefusesWithoutRequestingWhenSpawnIsUnavailableOrFails() {
    for outcome: TCCResponsibility.SpawnOutcome in [.disclaimUnavailable, .spawnFailed(ENOENT)] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"],
            runtime: requestRuntime(recorder, principal: ownPrincipal, spawnOutcome: outcome),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1)
        #expect(recorder.accessibilityRequests == 0)
        #expect(recorder.postEventRequests == 0)
        #expect(recorder.stderr.contains("no permission was requested"))
        // A fixed reason: no strerror text, no path.
        #expect(!recorder.stderr.contains(String(cString: strerror(ENOENT))))
        for fragment in privateFragments { #expect(!recorder.stderr.contains(fragment), "\(fragment) in \(recorder.stderr)") }
    }
}

@Test func test1596PublicRequestPropagatesChildExitCode() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        runtime: requestRuntime(recorder, principal: ownPrincipal, spawnOutcome: .exited(0)),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 0)
}

@Test func test1596ExplicitTargetIsSpawnedAndNamedOnlyByLabel() {
    let recorder = RequestRecorder()
    _ = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions", outsideHomeBinary],
        runtime: requestRuntime(recorder, principal: terminalPrincipal),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(recorder.spawned.first?.0 == outsideHomeBinary)
    #expect(recorder.stderr.contains("Requesting for: LogicProMCP (other install)"))
    for fragment in privateFragments { #expect(!recorder.stderr.contains(fragment)) }
}

@Test func test1596UnusableOrExtraArgumentsRefuseBeforeSpawning() {
    for extra in [["relative/LogicProMCP"], ["--request-permissions-disclaimed"], ["/a", "/b"]] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"] + extra,
            runtime: requestRuntime(recorder, principal: ownPrincipal),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1)
        #expect(recorder.spawned.isEmpty)
        #expect(recorder.accessibilityRequests == 0)
        #expect(!recorder.stderr.contains("relative"))
    }
}

@Test func test1596ChildWithoutParentProvenanceRefusesEvenWhenSelf() {
    let cases: [[String: String]] = [
        [:],
        [PermissionRequestCommand.provenanceVariable: "token-only"],
        [PermissionRequestCommand.provenanceVariable: "901:token-1"],   // another process's pid
        [PermissionRequestCommand.provenanceVariable: "900:"],
    ]
    for environment in cases {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
            runtime: requestRuntime(recorder, principal: ownPrincipal, granted: true, environment: environment),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1)
        #expect(recorder.accessibilityRequests == 0)
        #expect(recorder.postEventRequests == 0)
        #expect(recorder.stderr.contains("internal"))
    }
}

@Test func test1596ChildWithProvenanceButNotSelfResponsibleRefuses() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: requestRuntime(recorder, principal: terminalPrincipal, granted: true, environment: validProvenance),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 0)
    #expect(recorder.postEventRequests == 0)
}

@Test func test1596ChildWithProvenanceAndSelfResponsibilityAsksForBothAndNamesTheLabel() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: requestRuntime(recorder, principal: ownPrincipal, environment: validProvenance),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 1)
    #expect(recorder.postEventRequests == 1)
    #expect(recorder.stderr.contains("Requested for: LogicProMCP (homebrew)"))
    #expect(recorder.stderr.contains("PostEvent (CGEvent): NOT GRANTED"))
}

@Test func test1596ChildSucceedsOnlyWhenBothGranted() {
    for (accessibility, postEvent, expected) in [(true, true, Int32(0)), (true, false, 1), (false, true, 1)] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
            runtime: requestRuntime(
                recorder, principal: ownPrincipal, granted: accessibility, postEventGranted: postEvent,
                environment: validProvenance
            ),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == expected)
    }
}

/// The parent and child run end to end through fakes for the measurement seam: the child sees
/// exactly the environment the parent passed, and what it measures decides whether it asks.
@Test func test1596ChildsMeasuredResponsibilityDecidesWhetherEitherApiRuns() {
    for (childPrincipal, expectedCode, expectedRequests) in [
        (ownPrincipal, Int32(0), 1),          // disclaiming worked: the child is its own principal
        (terminalPrincipal, Int32(1), 0),     // disclaiming did not take effect: nothing is requested
    ] {
        let recorder = RequestRecorder()
        var parent = requestRuntime(recorder, principal: terminalPrincipal)
        parent.runDisclaimed = { executable, arguments, extra in
            var child = requestRuntime(recorder, principal: childPrincipal, granted: true, environment: extra)
            child.ownExecutablePath = { executable }
            return .exited(PermissionRequestCommand.run(
                arguments: [executable] + arguments, runtime: child, writeStderr: { recorder.stderr += $0 }
            ))
        }
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"], runtime: parent, writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == expectedCode)
        #expect(recorder.accessibilityRequests == expectedRequests)
        #expect(recorder.postEventRequests == expectedRequests)
    }
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

@Test func test1596DirectCliInvocationOfTheInternalFlagRefusesInProduction() async {
    // No fake runtime: the real production provenance check runs against the real environment,
    // which carries no token, so a typed flag asks for nothing.
    var stderr = ""
    let exitCode = await MainEntrypoint.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        permissionCheck: { .init(accessibility: false, automationLogicPro: false) },
        serverFactory: { LogicProServer() },
        writeStderr: { stderr += $0 }
    )
    #expect(exitCode == 1)
    #expect(stderr.contains("internal"))
}

// MARK: - The real spawn mechanism (no TCC request is made)

@Test func test1596DisclaimedSpawnRunsChildAndPropagatesExitStatus() {
    #expect(TCCResponsibility.runDisclaimed(executable: "/usr/bin/true", arguments: []) == .exited(0))
    #expect(TCCResponsibility.runDisclaimed(executable: "/usr/bin/false", arguments: []) == .exited(1))
    #expect(TCCResponsibility.runDisclaimed(executable: "/nonexistent/LogicProMCP", arguments: []) == .spawnFailed(ENOENT))
}

@Test func test1596DisclaimedSpawnPassesExtraEnvironmentToTheChild() {
    // /usr/bin/env exits 0 whether or not the variable is present, so use sh to assert it.
    #expect(TCCResponsibility.runDisclaimed(
        executable: "/bin/sh", arguments: ["-c", "test \"$LOGICPROMCP_TEST_TOKEN\" = abc"],
        extraEnvironment: ["LOGICPROMCP_TEST_TOKEN": "abc"]
    ) == .exited(0))
    #expect(TCCResponsibility.runDisclaimed(
        executable: "/bin/sh", arguments: ["-c", "test \"$LOGICPROMCP_TEST_TOKEN\" = abc"]
    ) == .exited(1))
}

@Test func test1596ResponsibilityQueryResolvesOnThisSystem() {
    #expect(TCCResponsibility.responsiblePID(for: getpid()) != nil)
}
