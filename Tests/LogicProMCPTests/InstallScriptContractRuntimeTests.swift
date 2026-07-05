import Foundation
import Testing

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
            "CLAUDE_LOG": fixture.claudeLog.path,
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
            "CLAUDE_LOG": fixture.claudeLog.path,
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
            "CLAUDE_LOG": fixture.claudeLog.path,
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
            "CLAUDE_LOG": fixture.claudeLog.path,
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

@Test func testInstallScriptPersistsShareDirIntoClaudeRegistrationForCustomNonBinLayouts() throws {
    let fixture = try makeInstallerFixture()

    let result = try runShellScript(
        "Scripts/install.sh",
        environment: [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CLAUDE_LOG": fixture.claudeLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.path,
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
        ]
    )

    #expect(result.exitCode == 0)
    let claudeArgs = try String(contentsOf: fixture.claudeLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    let shareArg = try #require(claudeArgs.first { $0.hasPrefix("LOGIC_PRO_MCP_SHARE_DIR=") })
    let actualShareDir = String(shareArg.dropFirst("LOGIC_PRO_MCP_SHARE_DIR=".count))
    let actualBinaryPath = try #require(claudeArgs.last)
    #expect(claudeArgs.contains("-e"))
    #expect(claudeArgs.contains("--"))
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
            "CLAUDE_LOG": fixture.claudeLog.path,
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
