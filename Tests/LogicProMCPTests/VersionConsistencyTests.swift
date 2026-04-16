import Foundation
import Testing
@testable import LogicProMCP

private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func readRepoFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: repositoryRootURL().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

/// Prevents the kind of drift we cleaned up in the v2.2 census:
/// ServerConfig said 2.2.0 while Formula was 2.1.0 and manifest/install.sh
/// were pinned to v2.0.0. Any future version bump has to touch all four
/// artefacts or this test fails.
@Test func testServerVersionMatchesPackagingArtefacts() throws {
    let sourceVersion = ServerConfig.serverVersion

    let manifest = try readRepoFile("manifest.json")
    #expect(
        manifest.contains("\"version\": \"\(sourceVersion)\""),
        "manifest.json version field must match ServerConfig.serverVersion=\(sourceVersion)"
    )
    #expect(
        manifest.contains("releases/download/v\(sourceVersion)/"),
        "manifest.json download_url must pin v\(sourceVersion)"
    )

    let formula = try readRepoFile("Formula/logic-pro-mcp.rb")
    #expect(
        formula.contains("version \"\(sourceVersion)\""),
        "Formula/logic-pro-mcp.rb version must match ServerConfig.serverVersion=\(sourceVersion)"
    )

    let installScript = try readRepoFile("Scripts/install.sh")
    #expect(
        installScript.contains("LOGIC_PRO_MCP_VERSION:-v\(sourceVersion)"),
        "Scripts/install.sh default VERSION must match v\(sourceVersion)"
    )
}
