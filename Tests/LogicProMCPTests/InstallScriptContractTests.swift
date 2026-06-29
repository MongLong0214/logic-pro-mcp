import Foundation
import Testing

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

    #expect(readme.contains("v3.7.2/Scripts/install.sh"))
    #expect(setup.contains("v3.7.2/Scripts/install.sh"))
    #expect(installer.contains("awk -v artifact=\"$ARCHIVE\" '$2 == artifact {print $1}'"))
    #expect(readme.contains("verifies the downloaded `LogicProMCP-macOS-universal.tar.gz` archive"))
    #expect(readme.contains("LogicProMCP-macOS-universal.tar.gz SHA256SUMS entry"))
    #expect(setup.contains("sha256 for LogicProMCP-macOS-universal.tar.gz entry"))
    #expect(!readme.contains("bare `LogicProMCP` binary"))
    #expect(!setup.contains("sha256 for bare LogicProMCP entry"))
}

@Test func testInstallScriptIncludesSignatureAndGatekeeperVerification() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("verify_signature()"))
    #expect(script.contains("verify_gatekeeper()"))
    #expect(script.contains("codesign --verify --strict --verbose=2"))
    #expect(script.contains("spctl --assess --type execute"))
    #expect(script.contains("RELEASE-METADATA.json"))
    #expect(script.contains("could not resolve TeamIdentifier from release metadata"))
    #expect(script.contains("require_command \"cliclick\""))
    #expect(script.contains("brew install cliclick"))
}

@Test func testInstallScriptExtractsTeamIDFromSingleLineReleaseMetadata() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("METADATA_JSON=$(curl -fsSL \"$METADATA_URL\")"))
    #expect(script.contains("\"team_id\"[[:space:]]*:[[:space:]]*\""))
    #expect(!script.contains("awk -F'\"' '/\"team_id\"[[:space:]]*:/ {print $4; exit}'"))
}

@Test func testInstallScriptRegistersClaudeAndKeyCommandsByDefault() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("SETUP.md"))
    #expect(script.contains("logic_bounce.py"))
    #expect(script.contains("logic_bounce_ui.py"))
    #expect(script.contains("logic_ui_jxa.py"))
    #expect(script.contains("logic_input_source.py"))
    #expect(script.contains("LOGIC_PRO_MCP_REGISTER_CLAUDE"))
    #expect(script.contains("Registering with Claude Code"))
    #expect(script.contains("LOGIC_PRO_MCP_INSTALL_KEYCMDS"))
    // RB-6 (v3.4.0): wording was "Installing Key Commands preset" — corrected to
    // "Staging Key Commands mapping reference" since Logic 12.2 doesn't actually
    // import the .plist; the script only stages a CC→Command mapping reference
    // for Manual MIDI Learn.
    #expect(script.contains("Staging Key Commands mapping reference"))
    #expect(script.contains("LOGIC_PRO_MCP_INSTALL_DIR"))
    #expect(script.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(script.contains("LOGIC_PRO_MCP_SKIP_SUDO"))
    #expect(script.contains("--approve-channel MIDIKeyCommands"))
    #expect(script.contains("--approve-channel Scripter"))
    #expect(script.contains("LogicProMCP-Scripter.js"))
}

@Test func testInstallScriptEscalatesWhenEitherInstallOrSharePathNeedsSudo() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("path_writable_without_sudo"))
    #expect(script.contains("path_writable_without_sudo \"$INSTALL_DIR\" && path_writable_without_sudo \"$SHARE_DIR\""))
}

@Test func testReleaseWorkflowDualModesAndPublishesMetadata() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")
    let packageScript = try scriptContents("Scripts/release-package.sh")

    // Dual-mode release: Developer ID credentials produce notarized artifacts;
    // otherwise stable and prerelease tags use the historical ADHOC path.
    #expect(workflow.contains("Detect release mode"))
    #expect(workflow.contains("mode=notarized"))
    #expect(workflow.contains("mode=adhoc"))
    #expect(workflow.contains("Publishing ADHOC stable release"))
    #expect(!workflow.contains("Stable ADHOC releases are not permitted"))
    #expect(!workflow.contains("Do not push stable tags manually"))
    #expect(!workflow.contains("ALLOW_ADHOC_STABLE"))
    #expect(workflow.contains("Validate notarization secrets"))
    #expect(workflow.contains("bash Scripts/release-build-universal.sh"))
    #expect(workflow.contains("is required for a notarized release build"))
    #expect(workflow.contains("Codesign binary (Developer ID)"))
    #expect(workflow.contains("Codesign binary (ADHOC)"))
    #expect(workflow.contains("codesign --force --sign - LogicProMCP"))
    #expect(workflow.contains("bash Scripts/release-package.sh"))
    #expect(workflow.contains("bash Scripts/release-verify-formula-install-paths.sh"))
    #expect(workflow.contains("validate-install"))
    #expect(workflow.contains("macos-15"))
    #expect(workflow.contains("macos-14"))
    #expect(workflow.contains("LOGIC_PRO_MCP_INSTALL_DIR"))
    #expect(workflow.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(workflow.contains("LogicProMCP-macOS-universal.tar.gz"))
    #expect(workflow.contains("test -f \"$LOGIC_PRO_MCP_SHARE_DIR/logic_ui_jxa.py\""))
    // The install-validation job MUST install cliclick before running install.sh:
    // install.sh hard-requires it (require_command "cliclick"), and GitHub's macOS
    // runners don't ship it, so without this the job fails "required dependency
    // missing: cliclick" on every tagged release.
    #expect(workflow.contains("brew install cliclick"))
    #expect(packageScript.contains("RELEASE-METADATA.json"))
    #expect(packageScript.contains("Scripts/logic_bounce.py"))
    #expect(packageScript.contains("Scripts/logic_bounce_ui.py"))
    #expect(packageScript.contains("Scripts/logic_ui_jxa.py"))
    #expect(packageScript.contains("Scripts/logic_input_source.py"))
    #expect(packageScript.contains("APPLE_NOTARY_TEAM_ID is required when RELEASE_MODE=notarized"))
    #expect(packageScript.contains("rm -f LogicProMCP-macOS-universal.tar.gz LogicProMCP-macOS-arm64.tar.gz SHA256SUMS.txt RELEASE-METADATA.json"))
    #expect(packageScript.contains("binary_file=\"$binary_dir/$binary_name\""))
    #expect(packageScript.contains("python3 - \"$release_version\" \"$team_id\" \"$signing\" \"$arch_json\""))
    #expect(try scriptContents("Formula/logic-pro-mcp.rb").contains("depends_on \"cliclick\""))
}

@Test func testReleaseWorkflowMarksHyphenTagsAsPrereleases() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")

    #expect(workflow.contains("prerelease: ${{ contains(github.ref_name, '-') }}"))
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

@Test func testCommunityDiscordLinkIsDiscoverableAcrossDocs() throws {
    // #178: the official Discord community must be discoverable from every help
    // entry point — not just the README badge — so users land on real-time
    // support from setup, troubleshooting, and contributor docs alike.
    let discord = "https://discord.gg/4M3s79DBzz"
    for path in ["README.md", "docs/SETUP.md", "docs/TROUBLESHOOTING.md", "CONTRIBUTING.md"] {
        #expect(try scriptContents(path).contains(discord), "\(path) must link the official Discord (\(discord))")
    }
}

@Test func testCoverageWorkflowFailsClosedAndUsesWritableProfilePath() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")

    #expect(workflow.contains("set -euo pipefail"))
    #expect(workflow.contains("PROFRAW_DIR=\"$RUNNER_TEMP/logicpromcp-profraw\""))
    #expect(workflow.contains("export LLVM_PROFILE_FILE=\"$PROFRAW_DIR/%m-%p.profraw\""))
    #expect(workflow.contains("COVERAGE_LOG=\"$RUNNER_TEMP/logicpromcp-coverage.log\""))
    #expect(workflow.contains("PROFILE_WARNING_COUNT=$(grep -c \"LLVM Profile Error\" \"$COVERAGE_LOG\" || true)"))
    #expect(workflow.contains("continuing to profdata/report validation"))
    #expect(workflow.contains("LLVM profile warnings: ${PROFILE_WARNING_COUNT:-0}."))
    #expect(workflow.contains("MIN_REGION=70"))
    #expect(workflow.contains("MIN_LINE=78"))
    #expect(workflow.contains("COVERAGE_TARGET=90"))
    #expect(!workflow.contains("set +e"))
    #expect(!workflow.contains("lets transient instrumentation flakes"))
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

@Test func testLocalReleaseScriptSupportsStableAdhocAndFailsClosedOnRemoteCheck() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("local one-command ADHOC release"))
    #expect(script.contains("Scripts/release.sh v3.0.1"))
    #expect(!script.contains("refuses stable tags"))
    #expect(!script.contains("There is intentionally no override"))
    #expect(!script.contains("LOGIC_PRO_MCP_ALLOW_ADHOC_STABLE"))
    #expect(script.contains("RELEASE_FLAGS=\"--prerelease\""))
    #expect(script.contains("Scripts/logic_bounce.py"))
    #expect(script.contains("Scripts/logic_bounce_ui.py"))
    #expect(script.contains("Scripts/logic_ui_jxa.py"))
    #expect(script.contains("Scripts/logic_input_source.py"))
    #expect(script.contains("LOGIC_PRO_MCP_SHA256=$TARBALL_SHA"))
    #expect(!script.contains("LOGIC_PRO_MCP_SHA256=$BINARY_SHA"))
    #expect(script.contains("could not verify remote tag availability"))
    #expect(script.contains("Refusing to continue because publishing could race"))
}

@Test func testStableReleaseScriptPreflightsAdhocTagBeforePush() throws {
    let script = try scriptContents("Scripts/release-stable.sh")

    #expect(script.contains("stable ADHOC release preflight"))
    #expect(!script.contains("gh secret list --repo \"$REPO\" --app actions"))
    #expect(!script.contains("Stable tag '$VERSION' was NOT created."))
    #expect(!script.contains("MACOS_CERT_BASE64"))
    #expect(!script.contains("APPLE_NOTARY_APPLE_ID"))
    #expect(script.contains("refs/tags/$VERSION"))
    #expect(script.contains("gh release view \"$VERSION\""))
    #expect(script.contains("python3 -m py_compile Scripts/live-e2e-test.py"))
    #expect(script.contains("swift test --no-parallel"))
    #expect(script.contains("swift build -c release"))
    #expect(script.contains("git push origin \"$VERSION\""))
}

@Test func testFormulaClaudeRegistrationCaveatIncludesShareDirEnv() throws {
    let formula = try scriptContents("Formula/logic-pro-mcp.rb")

    #expect(formula.contains("claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"#\\{pkgshare\\}\" -- LogicProMCP") == false)
    #expect(formula.contains("claude mcp add --scope user logic-pro -e LOGIC_PRO_MCP_SHARE_DIR=\"#{pkgshare}\" -- LogicProMCP"))
}

@Test func testUninstallScriptRemovesClaudeRegistrationAndKeepsManualScripterReminder() throws {
    let script = try scriptContents("Scripts/uninstall.sh")

    #expect(script.contains("claude mcp remove logic-pro"))
    #expect(script.contains("Remove Scripter MIDI FX"))
    #expect(script.contains("APPROVAL_STORE"))
    #expect(script.contains("LOGIC_PRO_MCP_SHARE_DIR"))
    #expect(script.contains("Removed shared assets"))
    #expect(script.contains("Removed operator approvals"))
    #expect(script.contains("APPROVAL_LOCK"))
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
