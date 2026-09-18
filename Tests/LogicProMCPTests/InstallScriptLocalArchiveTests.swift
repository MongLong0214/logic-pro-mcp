import Foundation
import Testing

/// `LOGIC_PRO_MCP_LOCAL_ARCHIVE` is the seam that lets the release pipeline install the build it
/// just produced, BEFORE that build is published. It exists so `validate-install` can run ahead of
/// `publish` instead of behind it.
///
/// The thing that would make the seam worthless is if it skipped a check the download path runs,
/// because then the pre-publish validation would prove less than the post-publish one it replaces.
/// So the cases below are mostly refusals, and the first pair is a control: `curl` is replaced with
/// one that always fails, and the same environment WITHOUT the seam must then fail. Otherwise a
/// green "installs from a local archive" would prove only that the download still worked.
@Suite("install.sh local archive input")
struct InstallScriptLocalArchiveTests {

    /// Replace the fixture's `curl` with one that cannot succeed. Anything that installs after this
    /// installed without the network.
    private func breakCurl(_ fixture: InstallerFixture) throws {
        try writeExecutable(
            fixture.fakeBin.appendingPathComponent("curl"),
            contents: """
            #!/bin/bash
            echo "curl was called, and this test asserts it is not" >&2
            exit 7
            """
        )
    }

    private func environment(_ fixture: InstallerFixture,
                             extra: [String: String] = [:]) -> [String: String] {
        var env = [
            "PATH": fixture.pathEnv,
            "FAKE_RELEASE_ARCHIVE": fixture.archiveURL.path,
            "CLAUDE_LOG": fixture.claudeLog.path,
            "LOGIC_PRO_MCP_VERSION": "v3.7.1",
            "LOGIC_PRO_MCP_SHA256": fixture.sha256,
            "LOGIC_PRO_MCP_TEAM_ID": "ADHOC",
            "LOGIC_PRO_MCP_INSTALL_DIR": fixture.installRoot.appendingPathComponent("bin").path,
            "LOGIC_PRO_MCP_SHARE_DIR": fixture.shareDir.path,
            "LOGIC_PRO_MCP_INSTALL_KEYCMDS": "0",
            "LOGIC_PRO_MCP_REGISTER_CLAUDE": "0",
            "LOGIC_PRO_MCP_SKIP_SUDO": "1",
        ]
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// THE CONTROL. With `curl` broken and no local archive, the install must fail -- otherwise the
    /// next case proves nothing about where the bytes came from.
    @Test("with curl broken and no local archive, the install fails")
    func theControlFails() throws {
        let fixture = try makeInstallerFixture()
        try breakCurl(fixture)
        let result = try runShellScript("Scripts/install.sh", environment: environment(fixture))
        #expect(result.exitCode != 0, "a broken curl must fail the download path: \(result.combinedOutput)")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.installRoot.appendingPathComponent("bin/LogicProMCP").path))
    }

    /// The seam itself, against the same broken `curl`.
    @Test("a local archive installs without touching the network")
    func localArchiveInstalls() throws {
        let fixture = try makeInstallerFixture()
        try breakCurl(fixture)
        let result = try runShellScript("Scripts/install.sh", environment: environment(
            fixture, extra: ["LOGIC_PRO_MCP_LOCAL_ARCHIVE": fixture.archiveURL.path]))
        #expect(result.exitCode == 0, "install from a local archive: \(result.combinedOutput)")
        #expect(FileManager.default.fileExists(
            atPath: fixture.installRoot.appendingPathComponent("bin/LogicProMCP").path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.shareDir.appendingPathComponent("SETUP.md").path))
        #expect(!result.combinedOutput.contains("curl was called"),
                "the local path must not fall through to a download: \(result.combinedOutput)")
    }

    /// THE CASE THE SEAM LIVES OR DIES ON. A local file is not a trusted file: its bytes are
    /// compared against the pin exactly as a downloaded one's are. If this ever passes, the
    /// pre-publish validation has become a rubber stamp.
    @Test("a local archive whose bytes do not match the pin is refused")
    func mismatchedLocalArchiveIsRefused() throws {
        let fixture = try makeInstallerFixture()
        try breakCurl(fixture)
        let tampered = fixture.sandbox.appendingPathComponent("tampered.tar.gz")
        try Data("not the archive you verified".utf8).write(to: tampered)
        let result = try runShellScript("Scripts/install.sh", environment: environment(
            fixture, extra: ["LOGIC_PRO_MCP_LOCAL_ARCHIVE": tampered.path]))
        #expect(result.exitCode != 0, "a local archive must still be hashed: \(result.combinedOutput)")
        #expect(result.combinedOutput.contains("SHA256 mismatch"),
                "and must be refused AS a hash mismatch, not for some other reason: \(result.combinedOutput)")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.installRoot.appendingPathComponent("bin/LogicProMCP").path))
    }

    /// The same-origin opt-out fetches the hash and the Team ID from the release the binary came
    /// from. With a local archive there is no such release -- honouring it would curl a release
    /// that may not exist yet and call the result a pin.
    @Test("the same-origin opt-out cannot be combined with a local archive")
    func sameOriginIsRefusedWithALocalArchive() throws {
        let fixture = try makeInstallerFixture()
        try breakCurl(fixture)
        var env = environment(fixture, extra: [
            "LOGIC_PRO_MCP_LOCAL_ARCHIVE": fixture.archiveURL.path,
            "LOGIC_PRO_MCP_ALLOW_SAME_ORIGIN": "1",
        ])
        env.removeValue(forKey: "LOGIC_PRO_MCP_SHA256")
        env.removeValue(forKey: "LOGIC_PRO_MCP_TEAM_ID")
        let result = try runShellScript("Scripts/install.sh", environment: env)
        #expect(result.exitCode != 0, "same-origin with a local archive: \(result.combinedOutput)")
        #expect(result.combinedOutput.contains("ALLOW_SAME_ORIGIN"),
                "and must say which two settings conflict: \(result.combinedOutput)")
    }

    /// Each refusal names the local archive rather than reporting a failed download, because the
    /// message is what a release operator reads when the pipeline stops.
    @Test("a local archive that is not a readable regular file is refused",
          arguments: ["missing", "relative", "directory", "symlink"])
    func badLocalArchivePathsAreRefused(kind: String) throws {
        let fixture = try makeInstallerFixture()
        try breakCurl(fixture)
        let path: String
        switch kind {
        case "missing":
            path = fixture.sandbox.appendingPathComponent("nope.tar.gz").path
        case "relative":
            path = "LogicProMCP-macOS-universal.tar.gz"
        case "directory":
            path = fixture.sandbox.path
        default:
            let link = fixture.sandbox.appendingPathComponent("link.tar.gz")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.archiveURL)
            path = link.path
        }
        let result = try runShellScript("Scripts/install.sh", environment: environment(
            fixture, extra: ["LOGIC_PRO_MCP_LOCAL_ARCHIVE": path]))
        #expect(result.exitCode != 0, "\(kind) must be refused: \(result.combinedOutput)")
        #expect(result.combinedOutput.contains("local_archive"),
                "\(kind) must be refused AS a local-archive problem: \(result.combinedOutput)")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.installRoot.appendingPathComponent("bin/LogicProMCP").path))
    }

    /// A symlinked archive is refused even though it resolves to the correct bytes -- so the case
    /// above cannot be passing merely because the link was broken.
    @Test("the refused symlink pointed at bytes that would otherwise have installed")
    func theSymlinkCaseIsNotPassingBecauseTheLinkWasBroken() throws {
        let fixture = try makeInstallerFixture()
        try breakCurl(fixture)
        let link = fixture.sandbox.appendingPathComponent("good-link.tar.gz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.archiveURL)
        let resolved = try Data(contentsOf: link)
        let direct = try Data(contentsOf: fixture.archiveURL)
        #expect(resolved == direct,
                "the link must resolve to the archive, or the refusal above proves nothing")
        let result = try runShellScript("Scripts/install.sh", environment: environment(
            fixture, extra: ["LOGIC_PRO_MCP_LOCAL_ARCHIVE": fixture.archiveURL.path]))
        #expect(result.exitCode == 0,
                "those same bytes install when named directly: \(result.combinedOutput)")
    }
}
