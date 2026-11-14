import Foundation
import Testing
@testable import LogicProMCP

@Test func testInstallScriptRequiresPinnedReleaseVerificationByDefault() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("LogicProMCP-macOS-universal.tar.gz"))
    #expect(script.contains("LOGIC_PRO_MCP_VERSION"))
    #expect(script.contains("LOGIC_PRO_MCP_SHA256"))
    #expect(script.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(script.contains("mutable 'latest' installs are not allowed in enterprise mode"))
    #expect(script.contains("Fetching release SHA256 manifest"))
}

@Test func testPinnedInstallerDocsUseArchiveSHAEntry() throws {
    let readme = try scriptContents("README.md")
    let setup = try scriptContents("docs/SETUP.md")
    let installer = try scriptContents("Scripts/install.sh")
    let registryData = Data(try scriptContents("server.json").utf8)
    let registry = try #require(
        try JSONSerialization.jsonObject(with: registryData) as? [String: Any]
    )
    let publishedVersion = try #require(registry["version"] as? String)
    let installerURLPrefix = "https://raw.githubusercontent.com/MongLong0214/logic-pro-mcp"

    #expect(readme.contains("\(installerURLPrefix)/v\(publishedVersion)/Scripts/install.sh"))
    #expect(setup.contains("\(installerURLPrefix)/v\(ServerConfig.serverVersion)/Scripts/install.sh"))
    #expect(installer.contains("awk -v artifact=\"$ARCHIVE\" '$2 == artifact {print $1}'"))
    #expect(readme.contains("verifies the downloaded `LogicProMCP-macOS-universal.tar.gz` archive"))
    #expect(readme.contains("LogicProMCP-macOS-universal.tar.gz SHA256SUMS entry"))
    #expect(setup.contains("sha256 for LogicProMCP-macOS-universal.tar.gz entry"))
    #expect(!readme.contains("bare `LogicProMCP` binary"))
    #expect(!setup.contains("sha256 for bare LogicProMCP entry"))
}

@Test func testInstallScriptUsesChecksumWithoutAppleSigning() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("LOGIC_PRO_MCP_SHA256"))
    #expect(script.contains("Verifying SHA256"))
    #expect(script.contains("validate_release_archive_manifest"))
    for forbidden in ["codesign", "spctl", "notarytool", "LOGIC_PRO_MCP_TEAM_ID",
                      "EXPECTED_TEAM_ID", "RELEASE-METADATA.json"] {
        #expect(!script.contains(forbidden), "installer contains \(forbidden)")
    }
}

@Test func testInstallScriptRegistersClaudeAndKeyCommandsByDefault() throws {
    let script = try scriptContents("Scripts/install.sh")
    let keycmdScript = try scriptContents("Scripts/install-keycmds.sh")
    let keycmdReference = try scriptContents("Scripts/keycmd-preset.plist")

    #expect(script.contains("SETUP.md"))
    #expect(script.contains("logic_bounce.py"))
    #expect(script.contains("logic_bounce_ui.py"))
    #expect(script.contains("logic_ui_jxa.py"))
    #expect(script.contains("logic_input_source.py"))
    #expect(script.contains("LOGIC_PRO_MCP_REGISTER_CLAUDE"))
    #expect(script.contains("Registering with Claude Code"))
    #expect(script.contains("LOGIC_PRO_MCP_INSTALL_KEYCMDS"))
    // The asset is a reference only; staging it never creates a human
    // continuation or qualifies mapped Logic execution.
    #expect(script.contains("Staging Key Commands mapping reference"))
    #expect(script.contains("LOGIC_PRO_MCP_INSTALL_DIR"))
    #expect(script.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(script.contains("LOGIC_PRO_MCP_SKIP_SUDO"))
    #expect(!script.contains("--approve-channel MIDIKeyCommands"))
    #expect(!script.contains("--approve-channel Scripter"))
    #expect(!script.contains("Manual Logic Pro setup required before production use"))
    #expect(!script.contains("Manual command:"))
    #expect(script.contains("unattended_unavailable"))
    #expect(script.contains("LogicProMCP-Scripter.js"))
    for publicText in [keycmdScript, keycmdReference] {
        #expect(!publicText.contains("Open Logic Pro"))
        #expect(!publicText.contains("Learn New Assignment"))
        #expect(!publicText.contains("Save Assignments"))
        #expect(!publicText.contains("Manual MIDI Learn"))
        #expect(publicText.contains("unattended_unavailable"))
    }
}

@Test func testInstallScriptEscalatesWhenEitherInstallOrSharePathNeedsSudo() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("path_writable_without_sudo"))
    #expect(script.contains("path_writable_without_sudo \"$INSTALL_DIR\" && path_writable_without_sudo \"$SHARE_DIR\""))
}

@Test func testReleaseWorkflowPublishesUnsignedChecksumVerifiedArchives() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")
    let packageScript = try scriptContents("Scripts/release-package.sh")

    #expect(workflow.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
    #expect(workflow.contains("bash Scripts/release-build-universal.sh"))
    #expect(workflow.contains("bash Scripts/release-verify-formula-install-paths.sh"))
    #expect(workflow.contains("validate-install"))
    #expect(workflow.contains("macos-15-intel"))
    #expect(workflow.contains("macos-26"))
    #expect(!workflow.contains("macos-14"))
    #expect(workflow.contains("LOGIC_PRO_MCP_INSTALL_DIR"))
    #expect(workflow.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(workflow.contains("LogicProMCP-macOS-universal.tar.gz"))
    #expect(workflow.contains("test -f \"$LOGIC_PRO_MCP_SHARE_DIR/logic_ui_jxa.py\""))
    #expect(packageScript.contains("RELEASE-METADATA.json"))
    #expect(packageScript.contains("Scripts/logic_bounce.py"))
    #expect(packageScript.contains("Scripts/logic_bounce_ui.py"))
    #expect(packageScript.contains("Scripts/logic_ui_jxa.py"))
    #expect(packageScript.contains("Scripts/logic_input_source.py"))
    #expect(packageScript.contains("rm -f LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz SHA256SUMS.txt RELEASE-METADATA.json"))
    #expect(packageScript.contains("binary_file=\"$binary_dir/$binary_name\""))
    #expect(packageScript.contains("\"signing\": \"unsigned\""))
    for forbidden in ["codesign", "spctl", "notarytool", "APPLE_NOTARY", "MACOS_CERT"] {
        #expect(!workflow.contains(forbidden), "release workflow contains \(forbidden)")
        #expect(!packageScript.contains(forbidden), "package script contains \(forbidden)")
    }
    let removedTool = "cli" + "click"
    #expect(!workflow.contains("brew install \(removedTool)"))
    #expect(!(try scriptContents("Formula/logic-pro-mcp.rb")).contains("depends_on \"\(removedTool)\""))
}

@Test func testReleaseWorkflowBoundsHostedInstallerPermissionFailure() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")
    let lines = workflow.components(separatedBy: .newlines)
    let terminal = "  Error: Installation unsuccessful: required Logic Pro capabilities are unavailable."
    var installBlocks: [String] = []

    for (index, line) in lines.enumerated()
    where line.trimmingCharacters(in: .whitespaces) == "run: |" {
        let indentation = line.prefix { $0 == " " }.count
        var end = index + 1
        while end < lines.count {
            let candidate = lines[end]
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            let candidateIndentation = candidate.prefix { $0 == " " }.count
            if !trimmed.isEmpty, candidateIndentation <= indentation {
                break
            }
            end += 1
        }
        let block = lines[(index + 1)..<end].joined(separator: "\n")
        if block.contains("bash Scripts/install.sh") { installBlocks.append(block) }
    }

    #expect(installBlocks.count == 2)
    for block in installBlocks {
        #expect(block.contains("set +e"))
        #expect(block.contains("bash Scripts/install.sh >\"$installer_log\" 2>&1"))
        #expect(block.contains("installer_status=$?"))
        #expect(block.contains("cat \"$installer_log\""))
        #expect(block.contains("expected_permission_failure='\(terminal)'"))
        #expect(block.contains("[ \"$installer_status\" -eq 0 ]"))
        #expect(block.contains("[ \"$installer_status\" -eq 1 ]"))
        #expect(block.contains("[ \"$(tail -n 1 \"$installer_log\")\" = \"$expected_permission_failure\" ]"))
        #expect(block.contains("exit \"$installer_status\""))
        #expect(!block.contains("|| true"))
        #expect(!block.contains("continue-on-error"))
        #expect(block.contains("LogicProMCP\" --version"))
        #expect(block.contains("LogicProMCP\" --help >/dev/null"))
        #expect(block.contains("test -f \"$LOGIC_PRO_MCP_SHARE_DIR/logic_ui_jxa.py\""))
    }
}

@Test func testHostedInstallerPermissionClassifierShellBoundary() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")
    let assignmentPrefix = "expected_permission_failure='"
    let configuredMessages = workflow.components(separatedBy: .newlines).compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(assignmentPrefix), trimmed.hasSuffix("'") else { return nil }
        return String(trimmed.dropFirst(assignmentPrefix.count).dropLast())
    }
    #expect(configuredMessages.count == 2)
    #expect(Set(configuredMessages).count == 1)
    let configuredMessage = try #require(configuredMessages.first)
    let actualTerminal = "  Error: Installation unsuccessful: required Logic Pro capabilities are unavailable."
    let sandbox = try makeInstallScriptTempDir("hosted-installer-classifier-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let log = sandbox.appendingPathComponent("installer.log")
    let classifier = #"""
        set -u
        installer_status="$1"
        installer_log="$2"
        expected_permission_failure="$EXPECTED_PERMISSION_FAILURE"
        if [ "$installer_status" -eq 0 ]; then
          :
        elif [ "$installer_status" -eq 1 ] \
          && [ "$(tail -n 1 "$installer_log")" = "$expected_permission_failure" ]; then
          :
        else
          exit "$installer_status"
        fi
        """#

    func classify(status: Int32, finalLine: String) throws -> Int32 {
        try "\(finalLine)\n".write(to: log, atomically: true, encoding: .utf8)
        return try runProcess(
            executable: "/bin/bash",
            arguments: ["-c", classifier, "classifier", String(status), log.path],
            currentDirectoryURL: sandbox,
            environment: ["EXPECTED_PERMISSION_FAILURE": configuredMessage]
        ).exitCode
    }

    #expect(try classify(status: 0, finalLine: "unrelated output") == 0)
    #expect(try classify(status: 1, finalLine: actualTerminal) == 0)
    #expect(try classify(status: 1, finalLine: String(actualTerminal.dropFirst(2))) == 1)
    #expect(try classify(status: 1, finalLine: "  Error: unrelated failure") == 1)
    #expect(try classify(status: 2, finalLine: actualTerminal) == 2)
}

@Test func testReleaseWorkflowMarksHyphenTagsAsPrereleases() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")

    let hyphenCheck = try #require(workflow.range(of: "if [[ \"$TAG\" == *-* ]]; then"))
    let prereleaseFlag = try #require(workflow.range(of: "create_args+=(--prerelease)",
                                                     range: hyphenCheck.upperBound..<workflow.endIndex))
    let create = try #require(workflow.range(of: "gh release create \"$TAG\"",
                                             range: prereleaseFlag.upperBound..<workflow.endIndex))
    #expect(hyphenCheck.lowerBound < prereleaseFlag.lowerBound)
    #expect(prereleaseFlag.lowerBound < create.lowerBound)
}

@Test func testReleaseWorkflowShareDirSatisfiesInstallerValidator() throws {
    // Regression guard for the release.yml <-> validate_share_dir drift that made
    // every tagged release fail install validation: install-common.sh's
    // validate_share_dir refuses any share dir that does not match the glob
    // `*/share/logic-pro-mcp`, so the workflow's LOGIC_PRO_MCP_SHARE_DIR value
    // (which `bash Scripts/install.sh` then validates) must end with
    // `/share/logic-pro-mcp`. A penultimate segment like `logic-pro-share`
    // fails the glob and exits the installer non-zero on every release.
    let workflow = try scriptContents(".github/workflows/release.yml")
    let common = try scriptContents("Scripts/install-common.sh")

    // Anchor the test to the actual validator contract it is protecting.
    #expect(common.contains("*/share/logic-pro-mcp)"))

    let shareDirLine = workflow
        .split(separator: "\n", omittingEmptySubsequences: false)
        .first { $0.contains("LOGIC_PRO_MCP_SHARE_DIR:") }
    let line = String(try #require(
        shareDirLine,
        "release.yml must set LOGIC_PRO_MCP_SHARE_DIR for the install-validation job"
    ))
    let value = line
        .components(separatedBy: "LOGIC_PRO_MCP_SHARE_DIR:")
        .last!
        .trimmingCharacters(in: .whitespaces)

    #expect(
        value.hasSuffix("/share/logic-pro-mcp"),
        "release.yml LOGIC_PRO_MCP_SHARE_DIR (\(value)) must end with /share/logic-pro-mcp so validate_share_dir accepts it"
    )
}

@Test func testDiscordLinkStaysOutOfReadmeButRemainsInSupportDocs() throws {
    let discord = "https://discord.gg/4M3s79DBzz"
    let readme = try scriptContents("README.md")

    #expect(!readme.contains(discord), "README.md should not carry the Discord community link")

    for path in ["docs/SETUP.md", "docs/TROUBLESHOOTING.md", "CONTRIBUTING.md"] {
        #expect(try scriptContents(path).contains(discord), "\(path) must link the official Discord (\(discord))")
    }
}

@Test func testCoverageGateFailsClosedAndUsesWritableProfilePath() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")
    let gate = try scriptContents("Scripts/ci-coverage-gate.sh")

    #expect(workflow.contains("set -euo pipefail"))
    #expect(workflow.contains("PROFRAW_DIR=\"$RUNNER_TEMP/logicpromcp-build-profraw\""))
    #expect(workflow.contains("PROFRAW_DIR=\"$RUNNER_TEMP/logicpromcp-profraw-$SHARD\""))
    #expect(workflow.contains("export LLVM_PROFILE_FILE=\"$PROFRAW_DIR/%m-%p.profraw\""))
    #expect(workflow.contains("COVERAGE_LOG=\"$out/test.log\""))
    #expect(workflow.contains("swift build --build-tests --enable-code-coverage"))
    #expect(workflow.contains("swift test --skip-build --enable-code-coverage"))
    #expect(workflow.contains("bash Scripts/ci-coverage-gate.sh"))
    #expect(workflow.contains("defaults:"))
    #expect(workflow.contains("shell: bash"))

    #expect(gate.contains("set -euo pipefail"))
    #expect(gate.contains("LPM_COVERAGE_MIN_REGION:-70"))
    #expect(gate.contains("LPM_COVERAGE_MIN_LINE:-78"))
    #expect(gate.contains("LPM_COVERAGE_TARGET:-90"))

    let forbidden = "set " + "+e"
    #expect(!workflow.contains(forbidden))
    #expect(!gate.contains(forbidden))
    #expect(!workflow.contains("lets transient instrumentation flakes"))
}

/// The marker rename's Edit button must be resolved by DESCRIPTION.
///
/// This is a source contract rather than a behavioural one because the script is built inside
/// `renameSelectedMarker`, which takes a live `AXUIElement` and offers no seam to capture it. The
/// generator itself is tested in `Issue519MenuLocaleGeneratorTests`; what this pins is that the
/// call site uses the right generator.
///
/// It exists because the wrong one was used and nothing noticed: `candidateResolution(
/// elementKeyword: "button", ...)` emits a BY-NAME reference, which is correct for a dialog's
/// Cancel and wrong for a Logic toolbar button whose AXTitle is empty. Measured on a running Logic
/// 12.3 on 2026-09-18 through System Events: 412 of 439 buttons report `name` as `missing value`,
/// none of the 27 that have a name carries an Edit-family label, and asked of one container both
/// ways for the same button, by-name is false where by-description is true. The rename would have
/// returned MARKER_EDIT_BUTTON_NOT_FOUND in every locale, including the two that worked before.
@Test func testMarkerRenameResolvesItsEditButtonByDescription() throws {
    let source = try scriptContents("Sources/LogicProMCP/Channels/AccessibilityChannel+MarkerNaming.swift")

    #expect(source.contains("AppleScriptMenuResolution.buttonWithDescription("))
    #expect(!source.contains("elementKeyword: \"button\""),
            "a by-name reference cannot find a button whose label is its AXDescription")
    // The group beside it has always been resolved this way; the two must not drift apart again.
    #expect(source.contains("AppleScriptMenuResolution.groupWithDescription("))
}

@Test func testLiveE2EHarnessRoutesCoverageProfilesToWritableTempDir() throws {
    let python = try scriptContents("Scripts/live-e2e-test.py")
    let shell = try scriptContents("Scripts/live-e2e-test.sh")

    #expect(python.contains("def coverage_environment():"))
    #expect(python.contains("LOGIC_PRO_MCP_PROFILE_DIR"))
    #expect(python.contains("LLVM_PROFILE_FILE"))
    #expect(python.contains("%m-%p.profraw"))
    #expect(python.contains("env=coverage_environment()"))
    #expect(python.contains("export LLVM_PROFILE_FILE="))

    #expect(shell.contains("LOGIC_PRO_MCP_PROFILE_DIR"))
    #expect(shell.contains("LLVM_PROFILE_FILE"))
    #expect(shell.contains("%m-%p.profraw"))
    #expect(shell.contains("export LLVM_PROFILE_FILE"))
}

@Test func testStrictLiveE2EBridgeUsesRawStdIOCaptureInsteadOfPaneMirroring() throws {
    let shell = try scriptContents("Scripts/live-e2e-test.sh")

    #expect(shell.contains("tee -a ${CAPTURE_FILE_COMMAND}"))
    #expect(!shell.contains("capture-pane -t \"$SESSION\""))
    #expect(!shell.contains("tmux send-keys -t \"$SESSION\" -l"))
    #expect(!shell.contains("CAPTURE_PID"))
    #expect(!shell.contains("SENDER_PID"))
}

@Test func testScriptsFolderNoLongerShipsOneOffSpikeHarnesses() {
    let root = installScriptContractRepositoryRootURL()
    let legacyPaths = [
        "Scripts/analysis-to-logic.py",
        "Scripts/issue7_live_verify.sh",
        "Scripts/probes/library-ax-probe.swift",
        "Scripts/probes/plugin-detective.swift",
        "Scripts/probes/plugin-menu-ax-probe.swift",
        "Scripts/probes/setting-popup-probe.swift",
    ]

    for relativePath in legacyPaths {
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path),
            "\(relativePath) was a one-off local/spike harness and must not ship in Scripts/"
        )
    }
}

@Test func testLocalReleaseScriptUsesCLTNativeQualificationAndHostedPublication() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
    #expect(script.contains("bash Scripts/release-qualify.sh"))
    #expect(script.contains("git diff --exit-code Package.resolved"))
    #expect(script.contains("set -euo pipefail"))
    #expect(script.contains("RUN_ID=\"${2:-}\""))
    #expect(script.contains("git ls-remote --tags origin"))
    #expect(script.contains("remote tag lookup failed; absence was not established"))
    #expect(script.contains("Scripts/release-verify-candidate.py run"))
    #expect(script.contains("Native-qualified: $QUALIFIED"))
    #expect(script.contains("Candidate-run-id: $RUN_ID"))
    #expect(script.contains("Candidate-run-attempt: $RUN_ATTEMPT"))
    #expect(script.contains("Candidate-artifact-id: $ARTIFACT_ID"))
    #expect(script.contains("Candidate-artifact-digest: $ARTIFACT_DIGEST"))
    #expect(script.contains("Candidate-manifest-sha256: $MANIFEST_SHA"))
    #expect(!script.contains("gh release create"))
    #expect(!script.contains("ADHOC"))
    #expect(!script.contains("codesign"))
}

@Test func testStableReleaseScriptPreflightsTagBeforePush() throws {
    let script = try scriptContents("Scripts/release-stable.sh")

    #expect(script.contains("release.sh"))
    #expect(script.contains("[ \"$#\" != 2 ]"))
    #expect(script.contains("[[ \"$2\" =~ ^[1-9][0-9]*$ ]]"))
    #expect(script.contains("Usage: $0 vMAJOR.MINOR.PATCH CANDIDATE_RUN_ID"))
    #expect(!script.contains("gh release view"))
    let validation = try #require(script.range(of: "[ \"$#\" != 2 ]"))
    let delegate = try #require(script.range(of: "exec bash \"$(dirname \"$0\")/release.sh\" \"$@\""))
    #expect(validation.lowerBound < delegate.lowerBound)
}

@Test func testFormulaClaudeRegistrationCaveatIncludesShareDirEnv() throws {
    let formula = try scriptContents("Formula/logic-pro-mcp.rb")

    #expect(!(formula.contains("claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"#\\{pkgshare\\}\" -- LogicProMCP")))
    #expect(formula.contains("claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"#{pkgshare}\" -- LogicProMCP"))
}

@Test func testUninstallScriptReportsUnverifiedLogicResidualsWithoutManualContinuation() throws {
    let script = try scriptContents("Scripts/uninstall.sh")
    let keyCommandUninstaller = try scriptContents("Scripts/uninstall-keycmds.sh")
    let launchAgentTemplate = try scriptContents("Scripts/com.logicpro.mcp.plist.template")

    #expect(script.contains("claude mcp remove logic-pro"))
    #expect(!script.contains("Manual command:"))
    #expect(!script.contains("Remove Scripter MIDI FX"))
    #expect(!script.contains("manually"))
    #expect(script.contains("Uninstall unsuccessful: Logic-resident Scripter/MCU state is unverified."))
    #expect(script.contains("APPROVAL_STORE"))
    #expect(script.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(script.contains("Removed shared assets"))
    #expect(script.contains("Removed operator approvals"))
    #expect(script.contains("APPROVAL_LOCK"))
    #expect(script.contains("gui/$UID/com.logicpro.mcp"))
    #expect(script.contains("launchctl print \"$LAUNCH_AGENT_SERVICE\""))
    #expect(script.contains("launchctl bootout \"$LAUNCH_AGENT_SERVICE\""))
    #expect(script.contains("[ -e \"$LAUNCH_AGENT\" ] || [ -L \"$LAUNCH_AGENT\" ]"))
    #expect(!script.contains("launchctl unload"))
    #expect(!script.contains("pgrep"))
    #expect(!script.contains("pkill"))
    #expect(!script.contains("killall"))
    #expect(!launchAgentTemplate.contains("launchctl load"))
    #expect(!launchAgentTemplate.contains("launchctl unload"))
    #expect(!launchAgentTemplate.contains("rm ~/Library/LaunchAgents"))
    #expect(launchAgentTemplate.contains("removal is owned by Scripts/uninstall.sh"))
    #expect(!keyCommandUninstaller.contains("read -p"))
    #expect(!keyCommandUninstaller.localizedCaseInsensitiveContains("re-run"))
    #expect(!keyCommandUninstaller.localizedCaseInsensitiveContains("manually"))
    #expect(!keyCommandUninstaller.localizedCaseInsensitiveContains("restart Logic"))
}

@Test func testKeyEventHelperSupportsReturnEnterAliasesAndPreflight() throws {
    // #186: the demo capture harness aborted on `--return` ("Unknown option").
    // The key-event input primitive must accept a flag-style --return (leading
    // dashes stripped), alias `enter` -> Return, expose a no-post `--check`
    // preflight, and fail closed naming the supported keys.
    let script = try scriptContents("Scripts/logic_key_event.swift")

    #expect(script.contains("\"return\": KeyEventSpec(keyCode: 36"))
    #expect(script.contains("\"enter\": KeyEventSpec(keyCode: 36"))
    #expect(script.contains("\"esc\": KeyEventSpec(keyCode: 53"))
    // A leading `--` is stripped so `--return` resolves to the Return key.
    #expect(script.contains("while value.hasPrefix(\"-\")"))
    // Preflight that validates a key without posting a CGEvent.
    #expect(script.contains("--check"))
    #expect(script.contains("checkMode"))
    #expect(script.contains("canonicalNameByKeyCode"))
    // Fail-closed unknown key names the supported set.
    #expect(script.contains("unknown_key:"))
    #expect(script.contains("supportedKeysLine()"))
}
