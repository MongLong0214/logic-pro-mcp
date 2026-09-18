import Foundation
import Testing

/// The release pipeline's ORDER is the safety property, and an order is exactly the thing a later
/// edit reshuffles without noticing.
///
/// Until 2026-09-18 `validate-install` ran with `needs: publish`, so every install defect was found
/// in public: the GitHub Release existed, `brew install` and the README's curl-pipe both resolved
/// to it, and the failing job only turned a check red beside an artifact users already had.
/// Nothing gated the publish. These cases pin the order that fixed it, so restoring the old one
/// has to be a deliberate act against a red test rather than a plausible-looking `needs:` edit.
@Suite("Release pipeline ordering")
struct ReleaseOrderingContractTests {

    private func releaseWorkflow() throws -> String {
        try scriptContents(".github/workflows/release.yml")
    }

    /// `needs:` of one job, as written -- either `needs: x` or `needs: [x, y]`.
    private func needs(of job: String, in workflow: String) -> [String] {
        guard let jobRange = workflow.range(of: "\n  \(job):\n") else { return [] }
        let rest = workflow[jobRange.upperBound...]
        // Stop at the next top-level job so a later job's `needs:` cannot answer for this one.
        let body = rest.prefix(while: { _ in true })
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
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

    /// The control: the helper must be able to read a `needs:` at all, or every case below passes
    /// by reading nothing.
    @Test("the workflow parses and every job in the chain exists")
    func theParserSeesTheJobs() throws {
        let workflow = try releaseWorkflow()
        for job in ["build", "validate-install", "publish", "verify-published", "publish-registry"] {
            #expect(workflow.contains("\n  \(job):\n"), "release.yml has no `\(job)` job")
        }
        #expect(needs(of: "publish", in: workflow).contains("build"),
                "if this is empty the parser is reading nothing and the cases below are vacuous")
    }

    /// THE ONE THAT MATTERS. Nothing is published until the built artifact has been installed.
    @Test("publish waits for validate-install")
    func publishWaitsForInstallValidation() throws {
        let workflow = try releaseWorkflow()
        #expect(needs(of: "publish", in: workflow).contains("validate-install"),
                "publish must not run until the install validation passes; it did not until 2026-09-18")
        #expect(!needs(of: "validate-install", in: workflow).contains("publish"),
                "validate-install must not depend on publish — that is the inverted order this pins")
    }

    /// The validation must install the artifact from THIS run. Pointing it back at the published
    /// release would restore the dependency on publish without changing any `needs:`.
    ///
    /// The assertions below read SETTINGS, not prose. The first version of this case checked
    /// `workflow.contains("LOGIC_PRO_MCP_LOCAL_ARCHIVE")`, and deleting the env line left it green
    /// because the name still appeared in a comment three lines above. A comment survives the
    /// change it describes, so a check that a comment can satisfy is not a check.
    @Test("validate-install installs the run's own artifact, not a published one")
    func installValidationUsesTheLocalArtifact() throws {
        let workflow = try releaseWorkflow()
        let settings = workflow.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        #expect(settings.contains { $0.hasPrefix("LOGIC_PRO_MCP_LOCAL_ARCHIVE:") && $0.hasSuffix(".tar.gz") },
                "the install validation must SET the archive to the build artifact, not merely mention it")
        #expect(settings.contains { $0.hasPrefix("name: verified-release-artifacts") },
                "and must download that artifact in the same run")
        #expect(!settings.contains { $0.contains("releases/download/$VERSION/SHA256SUMS.txt") },
                "resolving the hash from the published release is what forced this job to run late")
    }

    /// The registry record names a release, so it goes out after the release exists and after the
    /// published bytes have been compared against the verified ones.
    @Test("the registry record is published last")
    func registryIsLast() throws {
        let workflow = try releaseWorkflow()
        #expect(needs(of: "publish-registry", in: workflow).contains("verify-published"),
                "publishing a record that links to a release before that release exists")
        #expect(needs(of: "verify-published", in: workflow).contains("publish"))
        #expect(needs(of: "verify-published", in: workflow).contains("build"),
                "verify-published compares against the build artifact, so it needs it")
    }

    /// `verify-published` is the sentence "the artifact we verified is the artifact we published"
    /// stated as a measurement. If it stops comparing bytes it stops saying anything.
    @Test("the published bytes are compared against the verified bytes")
    func publishedBytesAreCompared() throws {
        let workflow = try releaseWorkflow()
        guard let range = workflow.range(of: "\n  verify-published:\n") else {
            #expect(Bool(false), "no verify-published job")
            return
        }
        let body = String(workflow[range.upperBound...])
        #expect(body.contains("shasum -a 256 \"verified/$asset\""),
                "it must hash the artifact this run verified")
        #expect(body.contains("shasum -a 256 \"published/$asset\""),
                "and the asset it downloaded from the release")
        #expect(body.contains("LogicProMCP-macOS-universal.tar.gz"),
                "the tarball users actually install is the one that must match")
    }
}
