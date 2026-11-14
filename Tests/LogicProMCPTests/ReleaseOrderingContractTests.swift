import Foundation
import Testing

@Suite("Release pipeline ordering")
struct ReleaseOrderingContractTests {
    private func releaseWorkflow() throws -> String {
        try scriptContents(".github/workflows/release.yml")
    }

    private func jobBody(_ job: String, in workflow: String) -> Substring? {
        guard let jobRange = workflow.range(of: "\n  \(job):\n") else { return nil }
        let tail = workflow[jobRange.upperBound...]
        guard let next = tail.range(
            of: #"\n  [A-Za-z0-9_-]+:\n"#,
            options: .regularExpression
        ) else { return tail }
        return tail[..<next.lowerBound]
    }

    private func needs(of job: String, in workflow: String) -> [String] {
        guard let body = jobBody(job, in: workflow),
              let raw = body.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("    needs:") }) else { return [] }
        return raw.replacingOccurrences(of: "    needs:", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @Test("a trusted dispatch builds one immutable candidate from dispatch main")
    func candidateBuildIsPrivilegedWorkflowDispatchOnly() throws {
        let workflow = try releaseWorkflow()
        let package = try #require(jobBody("candidate-package", in: workflow))

        #expect(workflow.contains("workflow_dispatch:"))
        #expect(workflow.contains("candidate_sha:"))
        #expect(workflow.contains("release_version:"))
        #expect(package.contains("github.event_name == 'workflow_dispatch'"))
        #expect(workflow.contains("\n  candidate-package:\n    if: github.event_name == 'workflow_dispatch'\n"))
        #expect(package.contains("test \"$GITHUB_REF\" = refs/heads/main"))
        #expect(package.contains("test \"$CANDIDATE_SHA\" = \"$GITHUB_SHA\""))
        #expect(package.contains("inputs.candidate_sha"))
        #expect(package.contains("release-candidate-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"))
        #expect(!package.contains("overwrite: true"))
    }

    @Test("tag publication consumes the bound prior-run artifact and never rebuilds it")
    func tagPathDownloadsBoundPriorRunAndNeverRebuilds() throws {
        let workflow = try releaseWorkflow()
        let resolve = try #require(jobBody("resolve-candidate", in: workflow))

        #expect(resolve.contains("github.event_name == 'push'"))
        #expect(resolve.contains("ref: ${{ github.sha }}"))
        #expect(!resolve.contains("ref: ${{ github.ref }}"))
        #expect(resolve.contains("test \"$(git rev-parse HEAD)\" = \"$GITHUB_SHA\""))
        #expect(resolve.contains("test \"$(git rev-parse \"refs/tags/$TAG^{}\")\" = \"$GITHUB_SHA\""))
        #expect(resolve.contains("actions: read"))
        #expect(resolve.contains("contents: read"))
        #expect(resolve.contains("github-token: ${{ github.token }}"))
        #expect(resolve.contains("repository: ${{ github.repository }}"))
        #expect(resolve.contains("run-id: ${{ steps.binding.outputs.run-id }}"))
        for forbidden in ["swift build", "release-build-universal.sh", "release-package.sh",
                          "lipo -create", "actions/upload-artifact"] {
            #expect(!resolve.contains(forbidden), "tag resolver must not contain \(forbidden)")
        }
    }

    @Test("candidate and tag paths both install the exact archive on Intel and ARM")
    func exactCandidatePassesBothInstallMatrices() throws {
        let workflow = try releaseWorkflow()
        let candidateInstall = try #require(jobBody("candidate-install", in: workflow))
        let tagInstall = try #require(jobBody("validate-install", in: workflow))

        #expect(needs(of: "candidate-install", in: workflow) == ["candidate-package"])
        #expect(needs(of: "validate-install", in: workflow) == ["resolve-candidate"])
        for install in [candidateInstall, tagInstall] {
            #expect(install.contains("os: [macos-15-intel, macos-26]"))
            #expect(install.contains("Scripts/release-verify-candidate.py package"))
            #expect(install.contains("LOGIC_PRO_MCP_LOCAL_ARCHIVE"))
            #expect(install.contains("Scripts/install.sh"))
        }
    }

    @Test("publication preserves matching assets, refuses replacement, then reads public bytes")
    func publicationIsIdempotentWithoutReplacingBytes() throws {
        let workflow = try releaseWorkflow()
        let publish = try #require(jobBody("publish", in: workflow))
        let verify = try #require(jobBody("verify-published", in: workflow))

        #expect(Set(needs(of: "publish", in: workflow)) == Set(["resolve-candidate", "validate-install"]))
        #expect(Set(needs(of: "verify-published", in: workflow)) == Set(["resolve-candidate", "publish"]))
        #expect(publish.contains("contents: write"))
        #expect(publish.contains("gh release download"))
        #expect(publish.contains("gh release upload"))
        #expect(publish.contains("Scripts/release-verify-candidate.py assets"))
        #expect(!publish.contains("--clobber"))
        #expect(publish.contains("unexpected release asset"))
        #expect(publish.contains("existing release asset differs"))
        #expect(verify.contains("releases/download/$TAG/$asset"))
        #expect(verify.contains("Scripts/release-verify-candidate.py assets"))
        #expect(verify.contains("verified_hash"))
        #expect(verify.contains("published_hash"))
    }

    @Test("the release workflow stops after public byte readback")
    func releaseStopsBeforeRegistryPublication() throws {
        let workflow = try releaseWorkflow()
        #expect(workflow.contains("\n  verify-published:\n"))
        #expect(!workflow.contains("\n  publish-registry:\n"))
        #expect(!workflow.contains("uses: ./.github/workflows/publish-mcp.yml"))
    }

    @Test("release uses Command Line Tools and no Apple signing pipeline")
    func releaseHasNoXcodeOrAppleSigningDependency() throws {
        let workflow = try releaseWorkflow()
        #expect(workflow.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
        for forbidden in ["/Applications/Xcode", "xcode-select", "codesign", "notarytool", "spctl",
                          "MACOS_CERT", "APPLE_NOTARY"] {
            #expect(!workflow.localizedCaseInsensitiveContains(forbidden),
                    "forbidden release dependency: \(forbidden)")
        }
    }
}
