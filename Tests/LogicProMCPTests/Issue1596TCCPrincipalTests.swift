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

@Test func test1596ResponsibilityQueryResolvesOnThisSystem() {
    #expect(TCCResponsibility.responsiblePID(for: getpid()) != nil)
}
