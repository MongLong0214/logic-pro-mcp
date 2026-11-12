import Foundation
import Testing

@Suite("Release pipeline ordering")
struct ReleaseOrderingContractTests {
    private func releaseWorkflow() throws -> String {
        try scriptContents(".github/workflows/release.yml")
    }

    private func needs(of job: String, in workflow: String) -> [String] {
        guard let jobRange = workflow.range(of: "\n  \(job):\n") else { return [] }
        var lines: [String] = []
        for line in workflow[jobRange.upperBound...].components(separatedBy: "\n") {
            if line.hasPrefix("  ") && !line.hasPrefix("    ") && line.hasSuffix(":") { break }
            lines.append(line)
        }
        guard let raw = lines.first(where: { $0.hasPrefix("    needs:") }) else { return [] }
        return raw.replacingOccurrences(of: "    needs:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @Test("publish waits for package and exact-archive install validation")
    func publishWaitsForTheValidatedPackage() throws {
        let workflow = try releaseWorkflow()
        for job in ["package", "validate-install", "publish"] {
            #expect(workflow.contains("\n  \(job):\n"), "release.yml has no \(job) job")
        }
        #expect(needs(of: "validate-install", in: workflow) == ["package"])
        #expect(Set(needs(of: "publish", in: workflow)) == Set(["package", "validate-install"]))
    }

    @Test("install validation consumes the package job's exact local archive")
    func installValidationUsesTheLocalArtifact() throws {
        let workflow = try releaseWorkflow()
        #expect(workflow.contains("artifact-name: ${{ steps.artifact-name.outputs.name }}"))
        #expect(workflow.contains("name: ${{ needs.package.outputs.artifact-name }}"))
        #expect(workflow.contains("LOGIC_PRO_MCP_LOCAL_ARCHIVE: ${{ github.workspace }}/LogicProMCP-macOS-universal.tar.gz"))
        #expect(workflow.contains("shasum -a 256 -c release-artifacts.sha256"))
        #expect(workflow.contains("LOGIC_PRO_MCP_SHA256=$(awk"))
    }

    @Test("only a checksum-reverified package can be published")
    func publishReverifiesThePackage() throws {
        let workflow = try releaseWorkflow()
        guard let publishRange = workflow.range(of: "\n  publish:\n") else {
            Issue.record("release.yml has no publish job")
            return
        }
        let publish = workflow[publishRange.upperBound...]
        #expect(publish.contains("permissions:\n      contents: write"))
        #expect(publish.contains("run: shasum -a 256 -c release-artifacts.sha256"))
        #expect(publish.contains("fail_on_unmatched_files: true"))
    }

    @Test("the release page is byte-checked before the registry is updated")
    func publishedBytesAreVerifiedBeforeRegistryPublication() throws {
        let workflow = try releaseWorkflow()
        for job in ["verify-published", "publish-registry"] {
            #expect(workflow.contains("\n  \(job):\n"), "release.yml has no \(job) job")
        }
        #expect(Set(needs(of: "verify-published", in: workflow)) == Set(["package", "publish"]))
        #expect(needs(of: "publish-registry", in: workflow) == ["verify-published"])
        #expect(workflow.contains("uses: ./.github/workflows/publish-mcp.yml"))
        #expect(workflow.contains("version: ${{ github.ref_name }}"))
    }

    @Test("published release assets are compared with the validated artifact")
    func publishedAssetsMatchTheValidatedArtifact() throws {
        let workflow = try releaseWorkflow()
        guard let verifyRange = workflow.range(of: "\n  verify-published:\n") else {
            Issue.record("release.yml has no verify-published job")
            return
        }
        let verify = workflow[verifyRange.upperBound...]
        #expect(verify.contains("name: ${{ needs.package.outputs.artifact-name }}"))
        #expect(verify.contains("releases/download/$TAG/$asset"))
        #expect(verify.contains("shasum -a 256 \"verified/$asset\""))
        #expect(verify.contains("shasum -a 256 \"published/$asset\""))
    }

    @Test("release uses Command Line Tools and no Apple signing pipeline")
    func releaseHasNoXcodeOrAppleSigningDependency() throws {
        let workflow = try releaseWorkflow()
        #expect(workflow.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
        for forbidden in ["/Applications/Xcode", "xcode-select", "codesign", "notarytool", "spctl",
                          "MACOS_CERT", "APPLE_NOTARY"] {
            #expect(!workflow.localizedCaseInsensitiveContains(forbidden), "forbidden release dependency: \(forbidden)")
        }
    }
}
