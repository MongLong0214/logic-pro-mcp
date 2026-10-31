import Foundation
import Testing

@Test func testInstallScriptTerminatesWhenPermissionCheckFails() throws {
    let fixture = try makeInstallerFixture(permissionExitCode: 1)

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Installation unsuccessful: required Logic Pro capabilities are unavailable."))
    #expect(!result.combinedOutput.contains("Installation complete."))
    #expect(!result.combinedOutput.contains("not granted yet"))
}

@Test func testInstallScriptTerminatesWhenRequestedClientRegistrationFails() throws {
    let fixture = try makeInstallerFixture(clientRegistrationExitCode: 1)

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Installation unsuccessful: configured MCP client registration failed."))
    #expect(!result.combinedOutput.contains("Already registered."))
    #expect(!result.combinedOutput.contains("Installation complete."))
}

@Test func testInstallScriptStandaloneCopyWorksWithoutSiblingCommonFile() throws {
    let fixture = try makeInstallerFixture()
    let standaloneDir = try makeInstallScriptTempDir("logicpromcp-install-standalone-\(UUID().uuidString)")
    let standaloneScript = standaloneDir.appendingPathComponent("install.sh")
    try writeExecutable(standaloneScript, contents: try scriptContents("Scripts/install.sh"))

    let result = try runProcess(
        executable: "/bin/bash",
        arguments: [standaloneScript.path],
        currentDirectoryURL: standaloneDir,
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
    #expect(FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_bounce.py").path))
    #expect(FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_ui_jxa.py").path))
}

@Test func testInstallScriptSupportsPublishedV371ArchiveWithoutProjectHelpers() throws {
    let fixture = try makeInstallerFixture(
        includeProjectHelperScripts: false,
        includeSharedJXAHelper: false
    )

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_bounce.py").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_bounce_ui.py").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_ui_jxa.py").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_input_source.py").path))
}

@Test func testInstallScriptRejectsUnsafeCustomShareDirBeforeMutation() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-install-reject-\(UUID().uuidString)")
    let installDir = sandbox.appendingPathComponent("bin")

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": "deadbeef",
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": installDir.path,
            "LOGIC_PRO_MCP_SHARE_DIR": sandbox.appendingPathComponent("unsafe-share").path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_REGISTER_CLAUDE": "0",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("share_dir must end with /share/logic-pro-mcp"))
    #expect(!FileManager.default.fileExists(atPath: installDir.path))
}

@Test func testInstallScriptUsesSudoWhenCustomShareDirNeedsElevation() throws {
    let fixture = try makeInstallerFixture()
    let protectedRoot = fixture.sandbox.appendingPathComponent("protected-root", isDirectory: true)
    let customShareDir = protectedRoot.appendingPathComponent("share/logic-pro-mcp", isDirectory: true)
    let sudoLog = fixture.sandbox.appendingPathComponent("sudo.log")
    try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: protectedRoot.path)
    try writeExecutable(
        fixture.fakeBin.appendingPathComponent("sudo"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$FAKE_SUDO_LOG"
        chmod u+w "$FAKE_SUDO_UNLOCK_PATH"
        exec "$@"
        """
    )

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "FAKE_SUDO_LOG": sudoLog.path,
            "FAKE_SUDO_UNLOCK_PATH": protectedRoot.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SHARE_DIR": customShareDir.path,
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode == 0, "install should succeed via sudo path: \(result.combinedOutput)")
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
    #expect(FileManager.default.fileExists(atPath: customShareDir.appendingPathComponent("logic_bounce.py").path))
    #expect(FileManager.default.fileExists(atPath: sudoLog.path))
}

@Test func testInstallScriptRejectsSymlinkedHelperArchiveMember() throws {
    let fixture = try makeInstallerFixture(symlinkedBounceHelper: true)

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("unsupported entry type"))
    #expect(!FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testInstallScriptRejectsTraversedProtectedInstallDirBeforeMutation() throws {
    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": "deadbeef",
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": "/tmp/logicpromcp-missing/../../usr/bin",
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_REGISTER_CLAUDE": "0",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("install_dir must not target a protected system path: /usr/bin"))
}

@Test func testInstallScriptRejectsCaseVariedProtectedInstallDirBeforeMutation() throws {
    // On a case-insensitive filesystem (APFS default) a case-varied protected
    // root with a non-existent intermediate survives normalize_path lexically
    // (pwd -P cannot canonicalize a missing dir), so a case-SENSITIVE blocklist
    // would let it slip through and then install into a world-writable system
    // dir (/TMP -> /private/tmp, /ETC -> /private/etc). The blocklist now matches
    // case-insensitively, so these are refused before any mutation.
    for caseVaried in ["/TMP/logicpromcp-missing/x", "/ETC/logicpromcp-missing/x"] {
        let result = try runShellScript(
            "Scripts/install.sh",
            environment: [
                "LOGIC_PRO_MCP_VERSION": "v3.7.1",
                "LOGIC_PRO_MCP_SHA256": "deadbeef",
                "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
                "LOGIC_PRO_MCP_INSTALL_DIR": caseVaried,
                "LOGIC_PRO_MCP_SKIP_SUDO": "1",
                "LOGIC_PRO_MCP_REGISTER_CLAUDE": "0",
                "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.combinedOutput.contains("install_dir must not target a protected system path: \(caseVaried)"))
    }
}

@Test func testInstallScriptInlineFallbackRejectsCaseVariedProtectedInstallDir() throws {
    // The two documented install methods (README §Quick Start: `curl -fsSL
    // .../install.sh` then run, or `bash <(curl ...install.sh)`) fetch ONLY
    // install.sh — install-common.sh is not alongside it, so install.sh runs its
    // INLINE fallback copy of the path validators. That fallback must enforce the
    // SAME case-insensitive protected-path guard as the sourced install-common.sh
    // copy, or the case-varied bypass stays open on the primary install path.
    // This runs install.sh standalone (no sibling install-common.sh) to force the
    // fallback branch, and pins the two implementations to parity.
    let standaloneDir = try makeInstallScriptTempDir("logicpromcp-install-fallback-\(UUID().uuidString)")
    let standaloneScript = standaloneDir.appendingPathComponent("install.sh")
    try writeExecutable(standaloneScript, contents: try scriptContents("Scripts/install.sh"))

    for caseVaried in ["/TMP/logicpromcp-missing/x", "/ETC/logicpromcp-missing/x", "/PRIVATE/TMP"] {
        let result = try runProcess(
            executable: "/bin/bash",
            arguments: [standaloneScript.path],
            currentDirectoryURL: standaloneDir,
            environment: [
                "LOGIC_PRO_MCP_VERSION": "v3.7.1",
                "LOGIC_PRO_MCP_SHA256": "deadbeef",
                "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
                "LOGIC_PRO_MCP_INSTALL_DIR": caseVaried,
                "LOGIC_PRO_MCP_SKIP_SUDO": "1",
                "LOGIC_PRO_MCP_REGISTER_CLAUDE": "0",
                "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.combinedOutput.contains("must not target a protected system path: \(caseVaried)"))
    }
}

@Test func testUninstallScriptRejectsUnsafeEnvOverridesBeforeRemoval() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-reject-\(UUID().uuidString)")
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let rmLog = sandbox.appendingPathComponent("rm.log")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$RM_LOG"
        exit 0
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": sandbox.appendingPathComponent("home").path,
            "LOGIC_PRO_MCP_SHARE_DIR": "/tmp/evil",
            "LOGIC_PRO_MCP_APPROVAL_STORE": "/tmp/evil.json",
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "RM_LOG": rmLog.path,
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("LOGIC_PRO_MCP_APPROVAL_STORE override is not supported"))
    #expect(!FileManager.default.fileExists(atPath: rmLog.path))
}

@Test func testUninstallScriptRejectsTraversedProtectedInstallDirBeforeRemoval() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-traversal-\(UUID().uuidString)")
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let rmLog = sandbox.appendingPathComponent("rm.log")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$RM_LOG"
        exit 0
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": sandbox.appendingPathComponent("home").path,
            "LOGIC_PRO_MCP_INSTALL_DIR": "/tmp/logicpromcp-missing/../../usr/bin",
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "RM_LOG": rmLog.path,
        ]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("install_dir must not target a protected system path: /usr/bin"))
    #expect(!FileManager.default.fileExists(atPath: rmLog.path))
}

private struct UninstallLaunchAgentFixture {
    let home: URL
    let fakeBin: URL
    let installRoot: URL
    let launchAgent: URL
    let serviceState: URL
    let launchctlLog: URL

    var environment: [String: String] {
        [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "LOGIC_PRO_MCP_INSTALL_DIR": installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LAUNCHCTL_LOG": launchctlLog.path,
            "SERVICE_STATE": serviceState.path,
        ]
    }
}

private func makeUninstallLaunchAgentFixture(
    serviceLoaded: Bool,
    plistPresent: Bool,
    brokenPlistSymlink: Bool = false,
    bootoutExitCode: Int = 0,
    serviceAbsentExitCode: Int = 113,
    removeServiceBeforeBootoutFailure: Bool = false,
    preserveServiceAfterBootout: Bool = false,
    failPlistRemoval: Bool = false,
    reloadServiceAfterPlistRemoval: Bool = false,
    binaryPresent: Bool = false
) throws -> UninstallLaunchAgentFixture {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-launch-agent-\(UUID().uuidString)")
    let home = sandbox.appendingPathComponent("home", isDirectory: true)
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let installRoot = sandbox.appendingPathComponent("install-root", isDirectory: true)
    let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.logicpro.mcp.plist")
    let serviceState = sandbox.appendingPathComponent("service-loaded")
    let launchctlLog = sandbox.appendingPathComponent("launchctl.log")

    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    if plistPresent {
        try writeFile(launchAgent, contents: "fixture")
    } else if brokenPlistSymlink {
        try FileManager.default.createDirectory(
            at: launchAgent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: launchAgent.path,
            withDestinationPath: sandbox.appendingPathComponent("missing-target").path
        )
    }
    if serviceLoaded {
        try writeFile(serviceState, contents: "loaded")
    }
    if binaryPresent {
        try writeFile(installRoot.appendingPathComponent("LogicProMCP"), contents: "fixture")
    }

    try writeExecutable(
        fakeBin.appendingPathComponent("launchctl"),
        contents: """
        #!/bin/bash
        set -euo pipefail
        echo "$*" >> "$LAUNCHCTL_LOG"
        [ "${2:-}" = "gui/$UID/com.logicpro.mcp" ] || exit 64
        case "${1:-}" in
            print)
                if [ -f "$SERVICE_STATE" ]; then
                    exit 0
                fi
                exit "\(serviceAbsentExitCode)"
                ;;
            bootout)
                if [ "\(bootoutExitCode)" -ne 0 ]; then
                    if [ "\(removeServiceBeforeBootoutFailure ? 1 : 0)" -eq 1 ]; then
                        /bin/rm -f "$SERVICE_STATE"
                    fi
                    exit "\(bootoutExitCode)"
                fi
                if [ "\(preserveServiceAfterBootout ? 1 : 0)" -eq 0 ]; then
                    /bin/rm -f "$SERVICE_STATE"
                fi
                ;;
            *) exit 64 ;;
        esac
        """
    )
    try writeExecutable(
        fakeBin.appendingPathComponent("cl" + "aude"),
        contents: """
        #!/bin/bash
        exit 0
        """
    )
    if failPlistRemoval || reloadServiceAfterPlistRemoval {
        try writeExecutable(
            fakeBin.appendingPathComponent("rm"),
            contents: """
            #!/bin/bash
            set -euo pipefail
            for argument in "$@"; do
                case "$argument" in
                    */Library/LaunchAgents/com.logicpro.mcp.plist)
                        if [ "\(failPlistRemoval ? 1 : 0)" -eq 1 ]; then
                            exit 71
                        fi
                        if [ "\(reloadServiceAfterPlistRemoval ? 1 : 0)" -eq 1 ]; then
                            printf loaded > "$SERVICE_STATE"
                        fi
                        ;;
                esac
            done
            exec /bin/rm "$@"
            """
        )
    }

    return UninstallLaunchAgentFixture(
        home: home,
        fakeBin: fakeBin,
        installRoot: installRoot,
        launchAgent: launchAgent,
        serviceState: serviceState,
        launchctlLog: launchctlLog
    )
}

@Test func testUninstallScriptBootsOutExactLoadedLaunchAgentWithoutPlist() throws {
    let fixture = try makeUninstallLaunchAgentFixture(serviceLoaded: true, plistPresent: false)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent service"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.serviceState.path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(calls.count == 4)
    #expect(calls[0].hasPrefix("print gui/"))
    #expect(calls[1].hasPrefix("bootout gui/"))
    #expect(calls[2].hasPrefix("print gui/"))
    #expect(calls.allSatisfy { $0.hasSuffix("/com.logicpro.mcp") })
}

@Test func testUninstallScriptRemovesFixedPlistWhenLaunchAgentIsNotLoaded() throws {
    let fixture = try makeUninstallLaunchAgentFixture(serviceLoaded: false, plistPresent: true)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent plist"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
    #expect(calls.count == 2)
    #expect(calls[0].hasPrefix("print gui/"))
}

@Test func testUninstallScriptSkipsAbsentLaunchAgentWithoutBootout() throws {
    let fixture = try makeUninstallLaunchAgentFixture(serviceLoaded: false, plistPresent: false)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Launch agent service not loaded"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
    #expect(calls.count == 2)
    #expect(calls[0].hasPrefix("print gui/"))
}

@Test func testUninstallScriptPreservesBinaryAndPlistWhenLaunchAgentBootoutFails() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        bootoutExitCode: 72,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service could not be stopped"))
    #expect(FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptRejectsLaunchAgentThatRemainsLoadedAfterBootout() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        preserveServiceAfterBootout: true,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service remains loaded"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(calls.filter { $0.hasPrefix("print gui/") }.count == 6)
}

@Test func testUninstallScriptTerminatesWhenFixedPlistRemovalFails() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: false,
        plistPresent: true,
        failPlistRemoval: true,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent plist could not be removed"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptPreservesArtifactsWhenLaunchAgentProbeIsIndeterminate() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: false,
        plistPresent: true,
        serviceAbsentExitCode: 73,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service state could not be established"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptPreservesArtifactsWhenBootoutReadbackIsIndeterminate() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        serviceAbsentExitCode: 73,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service removal could not be verified"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptDoesNotConfuseLaunchctlExit75WithLoadedState() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        serviceAbsentExitCode: 75,
        binaryPresent: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("launch agent service removal could not be verified"))
    #expect(!result.combinedOutput.contains("launch agent service remains loaded"))
    #expect(FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testUninstallScriptRemovesOnlyTheBrokenFixedPlistSymlink() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: false,
        plistPresent: false,
        brokenPlistSymlink: true
    )
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.launchAgent.path)) != nil)

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent plist"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.launchAgent.path)) == nil)
}

@Test func testUninstallScriptAcceptsObservedAbsenceAfterBootoutReturnsNonzero() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        bootoutExitCode: 72,
        removeServiceBeforeBootoutFailure: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Removed launch agent service"))
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchAgent.path))
}

@Test func testUninstallScriptStopsServiceThatReloadsBeforeFinalReadback() throws {
    let fixture = try makeUninstallLaunchAgentFixture(
        serviceLoaded: true,
        plistPresent: true,
        reloadServiceAfterPlistRemoval: true
    )

    let result = try runShellScript("Scripts/uninstall.sh", environment: fixture.environment)

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("Logic-resident Scripter/MCU state is unverified"))
    #expect(!FileManager.default.fileExists(atPath: fixture.serviceState.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.launchAgent.path))
    let calls = try String(contentsOf: fixture.launchctlLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(calls.filter { $0.hasPrefix("bootout gui/") }.count == 2)
}

@Test func testKeyCommandUninstallerPreservesBindingsAndBackupsWithoutHumanContinuation() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-keycmds-\(UUID().uuidString)")
    let keyCommandDir = sandbox.appendingPathComponent("Key Commands", isDirectory: true)
    let backupDir = keyCommandDir.appendingPathComponent("backups/backup_20261031_120000", isDirectory: true)
    let currentBindings = keyCommandDir.appendingPathComponent("User.logikcs")
    let backedUpBindings = backupDir.appendingPathComponent("User.logikcs")
    let stagedReference = keyCommandDir.appendingPathComponent("LogicProMCP-KeyCommands.plist")
    try writeFile(currentBindings, contents: "current-bindings")
    try writeFile(backedUpBindings, contents: "older-backup")
    try writeFile(stagedReference, contents: "reference-only")

    let result = try runShellScript(
        "Scripts/uninstall-keycmds.sh",
        environment: [
            "LOGIC_PRO_MCP_KEYCMD_DIR": keyCommandDir.path,
            "LOGIC_PRO_MCP_KEYCMD_AUTO_RESTORE": "1",
        ]
    )

    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: stagedReference.path))
    #expect(try String(contentsOf: currentBindings, encoding: .utf8) == "current-bindings")
    #expect(try String(contentsOf: backedUpBindings, encoding: .utf8) == "older-backup")
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_required=false"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("re-run"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("manually"))
    #expect(!result.combinedOutput.localizedCaseInsensitiveContains("restart Logic"))
}

@Test func testKeyCommandUninstallerReportsRemovalFailureAsTerminal() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-keycmds-failure-\(UUID().uuidString)")
    let keyCommandDir = sandbox.appendingPathComponent("Key Commands", isDirectory: true)
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let stagedReference = keyCommandDir.appendingPathComponent("LogicProMCP-KeyCommands.plist")
    try writeFile(stagedReference, contents: "reference-only")
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        exit 71
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall-keycmds.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "LOGIC_PRO_MCP_KEYCMD_DIR": keyCommandDir.path,
        ]
    )

    #expect(result.exitCode != 0)
    #expect(FileManager.default.fileExists(atPath: stagedReference.path))
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_required=false"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
    #expect(result.combinedOutput.contains("reference removal failed"))
}

@Test func testKeyCommandUninstallerAcceptsObservedAbsenceAfterRmReturnsNonzero() throws {
    let sandbox = try makeInstallScriptTempDir("logicpromcp-uninstall-keycmds-ambiguous-rm-\(UUID().uuidString)")
    let keyCommandDir = sandbox.appendingPathComponent("Key Commands", isDirectory: true)
    let fakeBin = sandbox.appendingPathComponent("fake-bin", isDirectory: true)
    let stagedReference = keyCommandDir.appendingPathComponent("LogicProMCP-KeyCommands.plist")
    try writeFile(stagedReference, contents: "reference-only")
    try writeExecutable(
        fakeBin.appendingPathComponent("rm"),
        contents: """
        #!/bin/bash
        /bin/rm "$@"
        exit 71
        """
    )

    let result = try runShellScript(
        "Scripts/uninstall-keycmds.sh",
        environment: [
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "LOGIC_PRO_MCP_KEYCMD_DIR": keyCommandDir.path,
        ]
    )

    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: stagedReference.path))
    #expect(result.combinedOutput.contains("terminal=true"))
    #expect(result.combinedOutput.contains("human_intervention_requests=0"))
}

@Test func testInstallScriptPersistsShareDirIntoClaudeRegistrationForCustomNonBinLayouts() throws {
    let fixture = try makeInstallerFixture()

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode == 0)
    let clientArgs = try String(contentsOf: fixture.clientLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    let shareArg = try #require(clientArgs.first { $0.hasPrefix("LOGIC_PRO_MCP_SHARE_DIR=") })
    let actualShareDir = String(shareArg.dropFirst("LOGIC_PRO_MCP_SHARE_DIR=".count))
    let actualBinaryPath = try #require(clientArgs.last)
    #expect(clientArgs.contains("-e"))
    #expect(clientArgs.contains("--"))
    #expect(URL(fileURLWithPath: actualShareDir).resolvingSymlinksInPath().path == fixture.shareDir.path)
    #expect(URL(fileURLWithPath: actualBinaryPath).resolvingSymlinksInPath().path == fixture.installRoot.appendingPathComponent("LogicProMCP").path)
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
    #expect(FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_bounce.py").path))
    #expect(FileManager.default.fileExists(atPath: fixture.shareDir.appendingPathComponent("logic_ui_jxa.py").path))
}

@Test func testInstallScriptHasNoExternalClickToolGate() throws {
    let fixture = try makeInstallerFixture()

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CL" + "AUDE_LOG": fixture.clientLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode == 0)
    let removedTool = "cli" + "click"
    #expect(!result.combinedOutput.contains("required dependency missing: \(removedTool)"))
    #expect(FileManager.default.fileExists(atPath: fixture.installRoot.appendingPathComponent("LogicProMCP").path))
}

@Test func testReleasePackageScriptRequiresTeamIDForNotarizedMode() throws {
    let result = try runShellScript(
        "Scripts/release-package.sh",
        environment: ["RELEASE_MODE": "notarized"]
    )

    #expect(result.exitCode != 0)
    #expect(result.combinedOutput.contains("APPLE_NOTARY_TEAM_ID is required when RELEASE_MODE=notarized"))
}

@Test func testReleaseTarballFixtureMatchesFormulaInstallPaths() throws {
    let fixture = try makeInstallerFixture()
    let sandbox = try makeInstallScriptTempDir("logicpromcp-release-verify-\(UUID().uuidString)")
    let scriptURL = sandbox.appendingPathComponent("Scripts/release-verify-formula-install-paths.sh")
    let formulaURL = sandbox.appendingPathComponent("Formula/logic-pro-mcp.rb")
    let archiveURL = sandbox.appendingPathComponent("LogicProMCP-macOS-universal.tar.gz")

    try writeExecutable(scriptURL, contents: try scriptContents("Scripts/release-verify-formula-install-paths.sh"))
    try writeFile(formulaURL, contents: try scriptContents("Formula/logic-pro-mcp.rb"))
    try FileManager.default.copyItem(at: fixture.archiveURL, to: archiveURL)

    let result = try runProcess(
        executable: "/bin/bash",
        arguments: [scriptURL.path],
        currentDirectoryURL: sandbox
    )

    #expect(result.exitCode == 0, "release-verify-formula-install-paths.sh failed: \(result.combinedOutput)")
    #expect(result.combinedOutput.contains("Formula install paths verified against the built tarball."))
}
