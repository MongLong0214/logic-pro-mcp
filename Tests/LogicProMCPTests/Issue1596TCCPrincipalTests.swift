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
// Synthetic secret-looking basename and bundle identifier: both fit the old character filters.
private let secretName = "Bearer-SYNTHETIC_REVIEW_TOKEN"
private let secretBundle = "com.synthetic.review-token-9f3a"
private let secretFragments = ["SYNTHETIC", "REVIEW", "Bearer", "synthetic", "review-token", "9f3a"]
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
    #expect(principal.label == "another executable")
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
}

// The label is built from fixed strings only (TCC-PRIVATE-OUTPUT).
@Test func test1596PublicLabelUsesFixedLabelsForAnyOtherBasenameOrBundleIdentifier() {
    for name in [secretName, "acme-secret-album", "logicpromcp", "LogicProMCP ", "x\u{202E}y"] {
        let path = "/Applications/Acme.app/Contents/MacOS/\(name)"
        #expect(TCCResponsibility.publicLabel(forExecutablePath: path, bundleIdentifier: { _ in nil }) == "another executable")
        #expect(TCCResponsibility.publicLabel(forExecutablePath: path, bundleIdentifier: { _ in secretBundle }) == "another application")
        #expect(TCCResponsibility.publicLabel(forExecutablePath: path, bundleIdentifier: { _ in "com.apple.Terminal" }) == "com.apple.Terminal (app bundle)")
    }
    // The product basename still never admits an unknown bundle identifier.
    #expect(TCCResponsibility.publicLabel(
        forExecutablePath: "/Applications/X.app/Contents/MacOS/LogicProMCP", bundleIdentifier: { _ in secretBundle }
    ) == "LogicProMCP (app bundle)")
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

@Test func test1596SecretBasenameAndBundleIdentifierNeverReachAnyRenderer() throws {
    let path = "/Applications/Acme.app/Contents/MacOS/\(secretName)"
    for isSelf in [true, false] {
        let principal = try #require(TCCResponsibility.principal(
            selfPID: 10, responsiblePID: { _ in isSelf ? 10 : 3 }, pathForPID: { _ in path },
            labelForPath: { TCCResponsibility.publicLabel(forExecutablePath: $0, bundleIdentifier: { _ in secretBundle }) }
        ))
        var denied = PermissionChecker.PermissionStatus(
            accessibilityState: .notGranted, automationState: .granted,
            systemEventsAutomationState: .notGranted, postEventAccessState: .notGranted
        )
        denied.principal = principal
        var outputs = [denied.summary]
        let result = SystemDispatcher.permissionsResult(denied)
        if case .text(let text, _, _)? = result.content.first { outputs.append(text) }
        if case .object(let fields)? = result.structuredContent {
            outputs.append(String(decoding: try JSONEncoder().encode(Value.object(fields)), as: UTF8.self))
        }
        let checks = [
            SetupDoctor.accessibilityPermissionCheck(denied),
            SetupDoctor.postEventAccessCheck(denied),
            SetupDoctor.systemEventsAutomationCheck(denied),
            SetupDoctor.launchContextCheck(runtime: doctorRuntime(context: "terminal"), permissionStatus: denied),
        ]
        for check in checks { outputs.append(String(decoding: try JSONEncoder().encode(check), as: UTF8.self)) }
        #expect(outputs.count >= 6)
        for output in outputs {
            for fragment in secretFragments { #expect(!output.contains(fragment), "\(fragment) in \(output)") }
            #expect(output.contains("another application"))
        }
    }
}

@Test func test1596RequestOutputNeverCarriesASecretBasename() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions", "/x/\(secretName)"],
        runtime: requestRuntime(recorder, principal: ownPrincipal),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.spawned.isEmpty)
    for fragment in secretFragments { #expect(!recorder.stderr.contains(fragment), "\(fragment) in \(recorder.stderr)") }
}

// MARK: - launch-context hint is a fixed category (ROUND1-ESCAPE)

@Test func test1596ResponsibleHintIsAFixedCategoryNeverARawEnvironmentValue() throws {
    for termProgram in ["/Volumes/ClientArchive/Terminal", "Apple_Terminal", "/Users/someone/clients/acme/iTerm"] {
        let info = SetupDoctor.classifyLaunchContext(
            ancestryBundleIDs: [], cfBundleIdentifier: nil, termProgram: termProgram
        )
        #expect(["terminal", "iterm"].contains(info.responsibleHint), "\(info.responsibleHint)")
    }
    for ancestor in ["MyClientTerminalProject", "/Users/someone/acme/cursor-secret", "/Volumes/ClientArchive/vscode"] {
        let info = SetupDoctor.classifyLaunchContext(
            ancestryBundleIDs: [], ancestryProcessNames: [ancestor], cfBundleIdentifier: nil, termProgram: nil
        )
        #expect(info.responsibleHint == info.context, "\(info.responsibleHint)")
    }
    // The doctor evidence sink normalises whatever it is handed.
    for raw in ["/Volumes/ClientArchive/Terminal", "DesktopClient", secretName, ""] {
        var runtime = SetupDoctor.Runtime.production
        runtime.launchContext = { SetupDoctor.LaunchContextInfo(context: "unknown", responsibleHint: raw) }
        let check = SetupDoctor.launchContextCheck(runtime: runtime)
        #expect(check.evidence["responsible_hint"] == "unknown")
        let rendered = String(decoding: try JSONEncoder().encode(check), as: UTF8.self)
        for fragment in ["ClientArchive", "Volumes", "DesktopClient"] + secretFragments { #expect(!rendered.contains(fragment)) }
    }
    var terminal = SetupDoctor.Runtime.production
    terminal.launchContext = { SetupDoctor.LaunchContextInfo(context: "terminal", responsibleHint: "Terminal") }
    #expect(SetupDoctor.launchContextCheck(runtime: terminal).evidence["responsible_hint"] == "terminal")
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
    var spawned: [(String, [String], String)] = []
    var accessibilityRequests = 0
    var postEventRequests = 0
    var receiptWrites: [Data] = []
    var stderr = ""
}

private let validReceiptProbe = PermissionRequestCommand.Receipt.Probe(accessibility: true, postEvent: true)

private func receiptData(
    handoff: String,
    requested: Bool = true,
    selfResponsible: Bool = true,
    version: Int = 1,
    after: PermissionRequestCommand.Receipt.Probe = validReceiptProbe
) -> Data {
    let receipt = PermissionRequestCommand.Receipt(
        version: version, handoff: handoff, requested: requested, selfResponsible: selfResponsible,
        before: .init(accessibility: false, postEvent: false), after: after
    )
    return (try? JSONEncoder().encode(receipt)) ?? Data()
}

private let validHandoff = "900:token-1"

private func requestRuntime(
    _ recorder: RequestRecorder,
    principal: TCCResponsibility.Principal?,
    spawnOutcome: TCCResponsibility.SpawnOutcome = .exited(0),
    receipt: Data? = nil,
    granted: Bool = false,
    postEventGranted: Bool? = nil,
    handoff: String? = nil,
    parentPID: pid_t = 900,
    receiptDelivered: Bool = true
) -> PermissionRequestCommand.Runtime {
    PermissionRequestCommand.Runtime(
        principal: { principal },
        ownExecutablePath: { privateHomeBinary },
        runDisclaimed: { executable, arguments, handoffValue in
            recorder.spawned.append((executable, arguments, handoffValue))
            return .init(outcome: spawnOutcome, receipt: receipt ?? receiptData(handoff: handoffValue))
        },
        requestAccessibility: { recorder.accessibilityRequests += 1; return granted },
        requestPostEvent: { recorder.postEventRequests += 1; return postEventGranted ?? granted },
        probeAccessibility: { recorder.accessibilityRequests > 0 && granted },
        probePostEvent: { recorder.postEventRequests > 0 && (postEventGranted ?? granted) },
        readHandoff: { handoff },
        writeReceipt: { recorder.receiptWrites.append($0); return receiptDelivered },
        ownPID: { 900 },
        parentPID: { parentPID },
        makeToken: { "token-1" },
        resolveTarget: { $0.hasPrefix("/") ? $0 : nil },
        labelForPath: { TCCResponsibility.publicLabel(forExecutablePath: $0, bundleIdentifier: { _ in nil }) }
    )
}

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
        #expect(recorder.spawned.first?.2 == validHandoff)
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

// MARK: - success comes only from the child's receipt (TCC-REQUEST-FALSE-SUCCESS)

@Test func test1596ExitZeroWithoutAReceiptIsAFailure() {
    for receipt in [Data(), Data("not json".utf8), Data("{}".utf8)] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"],
            runtime: requestRuntime(recorder, principal: ownPrincipal, spawnOutcome: .exited(0), receipt: receipt),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1)
        #expect(recorder.stderr.contains("without a valid receipt"))
        #expect(!recorder.stderr.contains("Receipt from LogicProMCP"))
    }
}

@Test func test1596MalformedOrForeignReceiptsAreRefused() {
    let tooMuchTrust: [Data] = [
        receiptData(handoff: "900:another-token"),                       // not this run's value
        receiptData(handoff: validHandoff, requested: false),            // request path did not run
        receiptData(handoff: validHandoff, selfResponsible: false),      // not its own principal
        receiptData(handoff: validHandoff, version: 2),
        Data(#"{"version":1,"handoff":"900:token-1","requested":true,"selfResponsible":true}"#.utf8),   // no probes
        Data(#"{"version":1,"handoff":"900:token-1","requested":"yes","selfResponsible":true,"before":{},"after":{}}"#.utf8),
    ]
    for receipt in tooMuchTrust {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"],
            runtime: requestRuntime(recorder, principal: ownPrincipal, spawnOutcome: .exited(0), receipt: receipt),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1, "\(String(decoding: receipt, as: UTF8.self))")
        #expect(recorder.stderr.contains("without a valid receipt"))
    }
}

@Test func test1596ValidReceiptIsTheOnlyPathToSuccess() {
    let recorder = RequestRecorder()
    let ok = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        runtime: requestRuntime(recorder, principal: ownPrincipal, spawnOutcome: .exited(0)),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(ok == 0)
    #expect(recorder.stderr.contains("Receipt from LogicProMCP: Accessibility not granted -> granted, PostEvent not granted -> granted"))
    // A valid receipt that reports a denied grant is not success even when the status is 0.
    for after in [
        PermissionRequestCommand.Receipt.Probe(accessibility: false, postEvent: true),
        PermissionRequestCommand.Receipt.Probe(accessibility: true, postEvent: false),
    ] {
        let denied = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions"],
            runtime: requestRuntime(denied, principal: ownPrincipal, spawnOutcome: .exited(0), receipt: receiptData(handoff: validHandoff, after: after)),
            writeStderr: { denied.stderr += $0 }
        )
        #expect(code == 1)
    }
    // And a nonzero status with a valid receipt stays a failure.
    let failed = RequestRecorder()
    #expect(PermissionRequestCommand.run(
        arguments: ["LogicProMCP", "--request-permissions"],
        runtime: requestRuntime(failed, principal: ownPrincipal, spawnOutcome: .exited(1)),
        writeStderr: { failed.stderr += $0 }
    ) == 1)
}

@Test func test1596TargetWhoseBasenameIsNotLogicProMCPIsRefusedBeforeSpawning() {
    for target in ["/usr/bin/true", "/bin/sh", "/x/LogicProMCP-other", "/x/logicpromcp", "/x/LogicProMCP/true"] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions", target],
            runtime: requestRuntime(recorder, principal: ownPrincipal),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1, Comment(rawValue: target))
        #expect(recorder.spawned.isEmpty, Comment(rawValue: target))
        #expect(recorder.stderr.contains("not a LogicProMCP executable"))
    }
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

// MARK: - the child asks only with the parent's pipe handoff (TCC-REQUEST-DISCLAIM)

@Test func test1596ChildWithoutTheParentsPipeHandoffRefusesEvenWhenSelf() {
    let cases: [String?] = [
        nil,                       // no inherited pipe at all
        "token-only",
        "901:token-1",             // another process's pid
        "900:",
    ]
    for handoff in cases {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
            runtime: requestRuntime(recorder, principal: ownPrincipal, granted: true, handoff: handoff),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == 1)
        #expect(recorder.accessibilityRequests == 0)
        #expect(recorder.postEventRequests == 0)
        #expect(recorder.receiptWrites.isEmpty)
        #expect(recorder.stderr.contains("internal"))
    }
}

/// The reviewer's case: the real parent pid and a fabricated token, started by hand with no pipe.
@Test func test1596MatchingParentPidWithFabricatedTokenAndNoPipeIsRefused() {
    let recorder = RequestRecorder()
    var runtime = requestRuntime(recorder, principal: ownPrincipal, granted: true, handoff: nil)
    // A forged environment carries exactly what the previous contract accepted.
    runtime.parentPID = { 900 }
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: runtime, writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 0)
    #expect(recorder.postEventRequests == 0)
}

@Test func test1596ChildWithHandoffButNotSelfResponsibleRefuses() {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: requestRuntime(recorder, principal: terminalPrincipal, granted: true, handoff: validHandoff),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 0)
    #expect(recorder.postEventRequests == 0)
    #expect(recorder.receiptWrites.isEmpty)
}

@Test func test1596ChildWithHandoffAndSelfResponsibilityAsksForBothAndWritesAReceipt() throws {
    let recorder = RequestRecorder()
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
        runtime: requestRuntime(recorder, principal: ownPrincipal, handoff: validHandoff),
        writeStderr: { recorder.stderr += $0 }
    )
    #expect(code == 1)
    #expect(recorder.accessibilityRequests == 1)
    #expect(recorder.postEventRequests == 1)
    #expect(recorder.stderr.contains("Requested for: LogicProMCP (homebrew)"))
    #expect(recorder.stderr.contains("PostEvent (CGEvent): NOT GRANTED"))
    let written = try #require(recorder.receiptWrites.first)
    let receipt = try #require(PermissionRequestCommand.validReceipt(written, handoff: validHandoff))
    #expect(receipt.before == .init(accessibility: false, postEvent: false))
    #expect(receipt.after == .init(accessibility: false, postEvent: false))
}

@Test func test1596ChildSucceedsOnlyWhenBothGrantedAndTheReceiptIsDelivered() {
    for (accessibility, postEvent, delivered, expected) in [
        (true, true, true, Int32(0)), (true, false, true, 1), (false, true, true, 1), (true, true, false, 1),
    ] {
        let recorder = RequestRecorder()
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag],
            runtime: requestRuntime(
                recorder, principal: ownPrincipal, granted: accessibility, postEventGranted: postEvent,
                handoff: validHandoff, receiptDelivered: delivered
            ),
            writeStderr: { recorder.stderr += $0 }
        )
        #expect(code == expected)
    }
}

/// The parent and child run end to end through fakes for the measurement seam: the child sees
/// exactly the handoff the parent passed, and its receipt is what the parent judges.
@Test func test1596ChildsMeasuredResponsibilityDecidesWhetherEitherApiRuns() {
    for (childPrincipal, expectedCode, expectedRequests) in [
        (ownPrincipal, Int32(0), 1),          // disclaiming worked: the child is its own principal
        (terminalPrincipal, Int32(1), 0),     // disclaiming did not take effect: nothing is requested
    ] {
        let recorder = RequestRecorder()
        var parent = requestRuntime(recorder, principal: terminalPrincipal)
        parent.runDisclaimed = { executable, arguments, handoff in
            var child = requestRuntime(recorder, principal: childPrincipal, granted: true, handoff: handoff)
            var written = Data()
            child.writeReceipt = { written = $0; return true }
            let code = PermissionRequestCommand.run(
                arguments: [executable] + arguments, runtime: child, writeStderr: { recorder.stderr += $0 }
            )
            return .init(outcome: .exited(code), receipt: written)
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
    #expect(TCCResponsibility.runDisclaimed(executable: "/usr/bin/true", arguments: [], handoff: "h") == .init(outcome: .exited(0), receipt: Data()))
    #expect(TCCResponsibility.runDisclaimed(executable: "/usr/bin/false", arguments: [], handoff: "h") == .init(outcome: .exited(1), receipt: Data()))
    #expect(TCCResponsibility.runDisclaimed(executable: "/nonexistent/LogicProMCP", arguments: [], handoff: "h").outcome == .spawnFailed(ENOENT))
}

@Test func test1596DisclaimedSpawnGivesTheChildTheHandoffAndAReceiptPipe() {
    // fd 3 carries the parent's value; fd 4 carries the child's answer back.
    let run = TCCResponsibility.runDisclaimed(
        executable: "/bin/sh", arguments: ["-c", "read value <&3; printf 'got:%s' \"$value\" >&4"], handoff: "900:abc"
    )
    #expect(run.outcome == .exited(0))
    #expect(String(decoding: run.receipt, as: UTF8.self) == "got:900:abc")
}

/// Real spawn, real pipes, a stand-in child named LogicProMCP that never asks for anything.
@Test func test1596RealSpawnOfAChildThatExitsZeroSilentlyOrWritesGarbageIsAFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tcc1596-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (script, label) in [("exit 0", "silent"), ("echo garbage >&4; exit 0", "malformed"), ("printf '{}' >&4; exit 0", "empty object")] {
        let sub = directory.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fake = sub.appendingPathComponent("LogicProMCP")
        try "#!/bin/sh\n\(script)\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var stderr = ""
        let code = PermissionRequestCommand.run(
            arguments: ["LogicProMCP", "--request-permissions", fake.path], writeStderr: { stderr += $0 }
        )
        #expect(code == 1, Comment(rawValue: label))
        #expect(stderr.contains("without a valid receipt"), Comment(rawValue: stderr))
    }
}

@Test func test1596ProductionChildWithNoInheritedPipeHasNoHandoff() async {
    // No fake runtime: the real descriptor check runs in this test process, where fd 3 is not the
    // parent's pipe, so a hand-typed internal flag asks for nothing even with a forged environment.
    setenv("LOGICPROMCP_REQUEST_PROVENANCE", "\(getppid()):forged", 1)
    defer { unsetenv("LOGICPROMCP_REQUEST_PROVENANCE") }
    var stderr = ""
    let code = PermissionRequestCommand.run(
        arguments: ["LogicProMCP", PermissionRequestCommand.disclaimedChildFlag], writeStderr: { stderr += $0 }
    )
    #expect(code == 1)
    #expect(stderr.contains("internal"))
}

@Test func test1596ResponsibilityQueryResolvesOnThisSystem() {
    #expect(TCCResponsibility.responsiblePID(for: getpid()) != nil)
}
