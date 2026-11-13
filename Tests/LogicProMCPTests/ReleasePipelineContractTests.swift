import Foundation
import Testing

@Test func release_script_consumes_and_rechecks_one_explicit_candidate_run() throws {
    let script = try scriptContents("Scripts/release.sh")

    #expect(script.contains("RUN_ID=\"${2:-}\""))
    #expect(script.contains("Usage: $0 vMAJOR.MINOR.PATCH[-prerelease] CANDIDATE_RUN_ID"))
    #expect(script.contains("git branch --show-current"))
    #expect(script.contains("!= main"))
    #expect(script.contains("releases must be tagged from the main branch"))
    #expect(script.contains("git fetch --quiet origin main --tags"))
    #expect(script.contains("git rev-parse HEAD"))
    #expect(script.contains("git rev-parse origin/main"))
    #expect(script.contains("HEAD must match origin/main"))
    #expect(script.contains("DEVELOPER_DIR=/Library/Developer/CommandLineTools"))
    #expect(script.contains("Scripts/release-verify-candidate.py run"))
    #expect(!script.contains("gh run download"))
    #expect(script.contains("actions/artifacts/$ARTIFACT_ID/zip"))
    #expect(script.contains("Scripts/release-verify-candidate.py extract"))
    #expect(script.contains("chmod 0755 \"$CANDIDATE_DIR/LogicProMCP\""))
    #expect(script.components(separatedBy: "Scripts/release-verify-candidate.py run").count >= 2)
    #expect(script.contains("fetch_candidate_evidence before"))
    #expect(script.contains("fetch_candidate_evidence after"))
    #expect(script.components(separatedBy: "Scripts/release-verify-candidate.py package").count >= 3)
    #expect(script.contains("bash Scripts/release-qualify.sh \"$CANDIDATE_DIR/LogicProMCP\""))
    #expect(script.contains("Native-qualified: $QUALIFIED"))
    #expect(script.contains("Candidate-run-id: $RUN_ID"))
    #expect(script.contains("Candidate-run-attempt: $RUN_ATTEMPT"))
    #expect(script.contains("Candidate-artifact-id: $ARTIFACT_ID"))
    #expect(script.contains("Candidate-artifact-digest: $ARTIFACT_DIGEST"))
    #expect(script.contains("Candidate-source: $QUALIFIED"))
    #expect(script.contains("Candidate-manifest-sha256: $MANIFEST_SHA"))
    #expect(script.contains("Scripts/release-verify-candidate.py tag"))
    #expect(script.contains("assert_remote_tag_absent"))
    #expect(script.contains("inspect_local_tag_target"))
    #expect(script.contains("if [ \"$LOCAL_TAG_PRESENT\" = 1 ]; then"))
    #expect(script.contains("if [ \"$LOCAL_TAG_PRESENT\" = 0 ]; then"))
    #expect(script.contains("--expected-run-id \"$RUN_ID\" --expected-run-attempt \"$RUN_ATTEMPT\""))
    #expect(script.contains("--expected-artifact-id \"$ARTIFACT_ID\" --expected-artifact-digest \"$ARTIFACT_DIGEST\""))
    #expect(script.contains("--expected-source-sha \"$QUALIFIED\" --expected-manifest-sha256 \"$MANIFEST_SHA\""))
    #expect(!script.contains("release-build-universal.sh"))
    #expect(!script.contains("release-package.sh"))
    #expect(!script.contains("gh release create"))
    #expect(script.contains("git diff --exit-code Package.resolved"))

    let qualification = try #require(script.range(of: "bash Scripts/release-qualify.sh"))
    let finalFetch = try #require(script.range(of: "git fetch --quiet origin main --tags",
                                              range: qualification.upperBound..<script.endIndex))
    let resumeVerify = try #require(script.range(of: "if [ \"$LOCAL_TAG_PRESENT\" = 1 ]; then\n  verify_local_tag_binding",
                                               range: finalFetch.upperBound..<script.endIndex))
    let tag = try #require(script.range(of: "git tag --no-sign -a \"$VERSION\" \"$QUALIFIED\"",
                                        range: finalFetch.upperBound..<script.endIndex))
    let finalVerify = try #require(script.range(of: "\nverify_local_tag_binding\n",
                                                range: tag.upperBound..<script.endIndex))
    let tagPush = try #require(script.range(of: "git push origin \"$VERSION\"",
                                            range: finalVerify.upperBound..<script.endIndex))
    #expect(qualification.lowerBound < finalFetch.lowerBound)
    #expect(finalFetch.lowerBound < resumeVerify.lowerBound)
    #expect(finalFetch.lowerBound < tag.lowerBound)
    #expect(tag.lowerBound < finalVerify.lowerBound)
    #expect(finalVerify.lowerBound < tagPush.lowerBound)
}

@Test func release_qualification_stages_exact_bytes_after_debug_preparation() throws {
    let gate = try scriptContents("Scripts/release-qualify.sh")

    #expect(gate.contains("CANDIDATE=\"${1:-}\""))
    #expect(!gate.contains("swift build -c release"))
    let inventory = try #require(gate.range(of: "test_inventory=\"$(swift test list)\""))
    let stage = try #require(gate.range(of: "cp \"$CANDIDATE\" .build/release/LogicProMCP"))
    let logic = try #require(gate.range(of: "if ! pgrep -xq \"Logic Pro\"; then"))
    let permission = try #require(gate.range(of: ".build/release/LogicProMCP --check-permissions"))
    let releaseLoop = try #require(gate.range(of: "for live_test in \"${release_live_tests[@]}\"",
                                              range: permission.upperBound..<gate.endIndex))
    let debugExecutable = try #require(gate.range(of: "if [ ! -x .build/debug/LogicProMCP ]; then",
                                                  range: releaseLoop.upperBound..<gate.endIndex))
    let debugLoop = try #require(gate.range(of: "for live_test in \"${debug_live_tests[@]}\"",
                                            range: debugExecutable.upperBound..<gate.endIndex))
    let suite = try #require(gate.range(of: "\nswift test --no-parallel\n"))
    let finalHash = try #require(gate.range(of: "verify_candidate_bytes", range: suite.upperBound..<gate.endIndex))

    #expect(inventory.lowerBound < stage.lowerBound)
    #expect(stage.lowerBound < logic.lowerBound)
    #expect(logic.lowerBound < permission.lowerBound)
    #expect(permission.lowerBound < releaseLoop.lowerBound)
    #expect(releaseLoop.lowerBound < debugExecutable.lowerBound)
    #expect(debugExecutable.lowerBound < debugLoop.lowerBound)
    #expect(debugLoop.lowerBound < suite.lowerBound)
    #expect(suite.lowerBound < finalHash.lowerBound)
    #expect(gate.contains("realReleaseBinaryExecutesEveryOperationWithIndependentReadback"))
    #expect(gate.contains("runnerIgnoresPartialStateFaultEnvOnRealServer"))
    #expect(gate.contains("runnerRejectsPartialStateObservedFromRealServer"))
    #expect(gate.contains("trap verify_candidate_bytes EXIT"))
    #expect(gate.contains("trap 'exit 130' INT"))
    #expect(gate.contains("trap 'exit 143' TERM"))
    #expect(gate.contains("chmod 0755 .build/release/LogicProMCP"))
}

@Test func candidate_package_metadata_binds_explicit_version_and_source() throws {
    let script = try scriptContents("Scripts/release-package.sh")
    #expect(script.contains("LOGIC_PRO_MCP_RELEASE_VERSION"))
    #expect(script.contains("LOGIC_PRO_MCP_RELEASE_SOURCE_SHA"))
    #expect(script.contains(#""source_sha": source_sha"#))
    #expect(script.contains(#""signing": "unsigned""#))
}

@Test func candidate_workflow_builds_with_command_line_tools_before_packaging() throws {
    let workflow = try scriptContents(".github/workflows/release.yml")
    let toolchain = try #require(workflow.range(of: "name: Use Command Line Tools"))
    let build = try #require(workflow.range(of: "bash Scripts/release-build-universal.sh"))
    let package = try #require(workflow.range(of: "name: Package release candidate"))
    #expect(toolchain.lowerBound < build.lowerBound)
    #expect(build.lowerBound < package.lowerBound)
    for forbidden in ["xcode-select", "Xcode_", "codesign", "notarytool", "spctl",
                      "MACOS_CERT", "APPLE_NOTARY"] {
        #expect(!workflow.contains(forbidden), "release workflow contains \(forbidden)")
    }
}

@Test func registry_publish_is_exact_merged_sha_dispatch_after_formula_update() throws {
    let workflow = try scriptContents(".github/workflows/publish-mcp.yml")

    #expect(workflow.contains("workflow_dispatch:"))
    #expect(workflow.contains("expected_sha:"))
    #expect(workflow.contains("expected_version:"))
    #expect(workflow.contains("required: true"))
    #expect(!workflow.contains("workflow_call:"))
    #expect(!workflow.contains("release:\n"))
    #expect(!workflow.contains("sync-server-json-version.py"))
    #expect(workflow.contains("GITHUB_SHA"))
    #expect(workflow.contains("inputs.expected_sha"))
    #expect(workflow.contains("ref: ${{ inputs.expected_sha }}"))
    #expect(workflow.contains("check-registry-metadata-matches-the-release.py"))
    #expect(workflow.contains("ci-verify-formula-sha.sh"))

    let checkout = try #require(workflow.range(of: "ref: ${{ inputs.expected_sha }}"))
    let metadata = try #require(workflow.range(of: "check-registry-metadata-matches-the-release.py"))
    let token = try #require(workflow.range(of: "GH_TOKEN: ${{ github.token }}",
                                            range: checkout.upperBound..<metadata.lowerBound))
    let formula = try #require(workflow.range(of: "ci-verify-formula-sha.sh"))
    let login = try #require(workflow.range(of: "Login with GitHub OIDC"))
    let publish = try #require(workflow.range(of: "Publish metadata"))
    #expect(checkout.lowerBound < metadata.lowerBound)
    #expect(token.lowerBound < formula.lowerBound)
    #expect(metadata.lowerBound < formula.lowerBound)
    #expect(formula.lowerBound < login.lowerBound)
    #expect(login.lowerBound < publish.lowerBound)
}

@Test func ci_workflow_gates_package_resolved_drift() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")
    #expect(workflow.contains("git diff --exit-code Package.resolved"))
    let releaseBuild = try #require(workflow.range(of: "swift build -c release"))
    let releaseLockfileGate = try #require(workflow.range(
        of: "git diff --exit-code Package.resolved", range: releaseBuild.upperBound..<workflow.endIndex))
    let testBuild = try #require(workflow.range(of: "swift build --build-tests --enable-code-coverage"))
    let testLockfileGate = try #require(workflow.range(
        of: "git diff --exit-code Package.resolved", range: testBuild.upperBound..<workflow.endIndex))
    let coverage = try #require(workflow.range(of: "swift test --skip-build --enable-code-coverage"))
    let coverageGate = try #require(workflow.range(of: "bash Scripts/ci-coverage-gate.sh"))
    #expect(releaseBuild.lowerBound < releaseLockfileGate.lowerBound)
    #expect(testBuild.lowerBound < testLockfileGate.lowerBound)
    #expect(testLockfileGate.lowerBound < coverage.lowerBound)
    #expect(coverage.lowerBound < coverageGate.lowerBound)
    #expect(coverage.lowerBound < coverageGate.lowerBound,
            "the tests must run before the gate reads the profile they produced")
}

@Test func ci_and_release_use_supported_standard_macos_runners() throws {
    let ci = try scriptContents(".github/workflows/ci.yml")
    let release = try scriptContents(".github/workflows/release.yml")
    #expect(ci.contains("'macos-15-intel'"))
    #expect(!ci.contains("&& 'macos-15' ||"))
    #expect(release.contains("runs-on: macos-15-intel"))
    #expect(release.contains("os: [macos-15-intel, macos-26]"))
    #expect(!release.contains("macos-14"))
    #expect(!release.contains("os: [macos-15,"))
    #expect(!release.contains("os: [macos-15-intel, macos-26-intel]"))
}

@Test func ci_documentationShortcutCannotHideSourceRenames() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")
    #expect(workflow.contains("git diff --no-renames --name-only -z"))
    #expect(workflow.contains("docs/*|*.md"))
    #expect(workflow.contains("*) mode=full"))
    #expect(workflow.contains("if [ \"$changed\" -eq 0 ]; then mode=full; fi"))
}
