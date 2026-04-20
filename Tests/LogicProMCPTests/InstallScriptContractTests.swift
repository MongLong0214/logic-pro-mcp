import Foundation
import Testing

private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func scriptContents(_ relativePath: String) throws -> String {
    try String(contentsOf: repositoryRootURL().appendingPathComponent(relativePath), encoding: .utf8)
}

@Test func testInstallScriptRequiresPinnedReleaseVerificationByDefault() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("LOGIC_PRO_MCP_VERSION"))
    #expect(script.contains("LOGIC_PRO_MCP_SHA256"))
    #expect(script.contains("mutable 'latest' installs are not allowed in enterprise mode"))
    #expect(script.contains("Fetching release SHA256 manifest"))
}

@Test func testInstallScriptIncludesSignatureAndGatekeeperVerification() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("verify_signature()"))
    #expect(script.contains("verify_gatekeeper()"))
    #expect(script.contains("codesign --verify --strict --verbose=2"))
    #expect(script.contains("spctl --assess --type execute"))
    #expect(script.contains("RELEASE-METADATA.json"))
    #expect(script.contains("could not resolve TeamIdentifier from release metadata"))
}

@Test func testInstallScriptRegistersClaudeAndKeyCommandsByDefault() throws {
    let script = try scriptContents("Scripts/install.sh")

    #expect(script.contains("LOGIC_PRO_MCP_REGISTER_CLAUDE"))
    #expect(script.contains("Registering with Claude Code"))
    #expect(script.contains("LOGIC_PRO_MCP_INSTALL_KEYCMDS"))
    #expect(script.contains("Installing Key Commands preset"))
    #expect(script.contains("LOGIC_PRO_MCP_INSTALL_DIR"))
    #expect(script.contains("LOGIC_PRO_MCP_SKIP_SUDO"))
    #expect(script.contains("--approve-channel MIDIKeyCommands"))
    #expect(script.contains("--approve-channel Scripter"))
}

@Test func testReleaseWorkflowDualModesAndPublishesMetadata() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")

    // v3.0.1: dual-mode release (notarized if secrets present, else adhoc).
    // ADHOC mode lets the CI pipeline succeed end-to-end even without an
    // Apple Developer Program subscription, so validate-install runs on
    // every tag push instead of being blocked by missing secrets.
    #expect(workflow.contains("Detect release mode"))
    #expect(workflow.contains("mode=notarized"))
    #expect(workflow.contains("mode=adhoc"))
    #expect(workflow.contains("Validate notarization secrets"))
    #expect(workflow.contains("is required for a notarized release build"))
    #expect(workflow.contains("Codesign binary (Developer ID)"))
    #expect(workflow.contains("Codesign binary (ADHOC)"))
    #expect(workflow.contains("codesign --force --sign - LogicProMCP"))
    #expect(workflow.contains("RELEASE-METADATA.json"))
    #expect(workflow.contains("validate-install"))
    #expect(workflow.contains("macos-15"))
    #expect(workflow.contains("macos-13"))
    #expect(workflow.contains("LOGIC_PRO_MCP_INSTALL_DIR"))
}

@Test func testUninstallScriptRemovesClaudeRegistrationAndKeepsManualScripterReminder() throws {
    let script = try scriptContents("Scripts/uninstall.sh")

    #expect(script.contains("claude mcp remove logic-pro"))
    #expect(script.contains("Remove Scripter MIDI FX"))
    #expect(script.contains("APPROVAL_STORE"))
    #expect(script.contains("Removed operator approvals"))
}
