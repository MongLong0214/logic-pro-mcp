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
    #expect(gate.contains("QUALIFICATION_ROOT=\"${2:-$TRUSTED_ROOT}\""))
    #expect(gate.contains("cd \"$QUALIFICATION_ROOT\""))
    #expect(!gate.contains("swift build -c release"))
    let inventory = try #require(gate.range(of: "test_inventory=\"$(swift test list)\""))
    let stage = try #require(gate.range(of: "cp \"$CANDIDATE\" .build/release/LogicProMCP"))
    let logic = try #require(gate.range(of: "if ! pgrep -xq \"Logic Pro\"; then"))
    let permission = try #require(gate.range(of: ".build/release/LogicProMCP --check-permissions"))
    let releaseLoop = try #require(gate.range(of: "run_live_lane release\n",
                                              range: permission.upperBound..<gate.endIndex))
    let debugExecutable = try #require(gate.range(of: "if [ ! -x .build/debug/LogicProMCP ]; then",
                                                  range: releaseLoop.upperBound..<gate.endIndex))
    let debugLoop = try #require(gate.range(of: "run_live_lane debug\n",
                                            range: debugExecutable.upperBound..<gate.endIndex))
    #expect(!gate.contains("\nswift test --no-parallel\n"),
            "the general suite runs in hosted CI; the Logic host runs only the live tests")
    let finalHash = try #require(gate.range(of: "verify_candidate_bytes", range: debugLoop.upperBound..<gate.endIndex))

    #expect(inventory.lowerBound < stage.lowerBound)
    #expect(stage.lowerBound < logic.lowerBound)
    #expect(logic.lowerBound < permission.lowerBound)
    #expect(permission.lowerBound < releaseLoop.lowerBound)
    #expect(releaseLoop.lowerBound < debugExecutable.lowerBound)
    #expect(debugExecutable.lowerBound < debugLoop.lowerBound)
    #expect(debugLoop.lowerBound < finalHash.lowerBound)
    // The live tests are the data file's `live` entries, each owned by a lane; the script names none.
    let notRun = try scriptContents("Tests/not-run-on-hosted.json")
    for (name, lane) in [("realReleaseBinaryExecutesEveryOperationWithIndependentReadback", "release"),
                         ("runnerIgnoresPartialStateFaultEnvOnRealServer", "release"),
                         ("runnerRejectsPartialStateObservedFromRealServer", "debug")] {
        let entry = try #require(notRun.split(separator: "\n").first { $0.contains("QualificationRunnerTests/\(name)()") })
        #expect(entry.contains("\"class\": \"live\", \"lane\": \"\(lane)\""))
        #expect(!gate.contains(name))
    }
    #expect(gate.contains("trap verify_candidate_bytes EXIT"))
    #expect(gate.contains("trap 'exit 130' INT"))
    #expect(gate.contains("trap 'exit 143' TERM"))
    #expect(gate.contains("chmod 0755 .build/release/LogicProMCP"))
}

@Test func release_qualification_validates_pinned_canon_before_native_preparation() throws {
    let gate = try scriptContents("Scripts/release-qualify.sh")
    let qualificationRoot = try #require(gate.range(of: "cd \"$QUALIFICATION_ROOT\""))
    let commands = [
        "python3 Scripts/logic_canon.py status",
        "python3 Scripts/check-canon-drift.py",
        "python3 Scripts/check-canon-citations.py",
        "python3 Scripts/check-policy-literals-against-canon.py",
        "python3 Scripts/check-labelsets-are-derived.py",
        "python3 Scripts/locale_labels.py --check",
    ]
    var boundary = qualificationRoot.upperBound
    for command in commands {
        #expect(gate.components(separatedBy: command).count == 2,
                "The protected release qualifier must run each canon preflight exactly once")
        let commandRange = try #require(gate.range(of: command, range: boundary..<gate.endIndex))
        boundary = commandRange.upperBound
    }
    let inventory = try #require(gate.range(of: "test_inventory=\"$(swift test list)\""))
    let stage = try #require(gate.range(of: "cp \"$CANDIDATE\" .build/release/LogicProMCP"))
    #expect(boundary < inventory.lowerBound)
    #expect(boundary < stage.lowerBound)
}

@Test func native_ci_qualification_separates_trusted_controlFromCandidateBytes() throws {
    let wrapper = try scriptContents("Scripts/ci-native-qualify.sh")

    #expect(wrapper.contains("rev-parse origin/main"))
    #expect(wrapper.contains("CANDIDATE_ROOT=\"${3:-}\""))
    #expect(wrapper.contains("require_release_origin \"$TRUSTED_ROOT\""))
    #expect(wrapper.contains("require_release_origin \"$CANDIDATE_ROOT\""))
    #expect(wrapper.contains("git@github.com:MongLong0214/logic-pro-mcp.git"))
    #expect(wrapper.contains("[\"git\", \"-C\", sys.argv[6], \"show\""))
    #expect(wrapper.contains("run.get(\"path\") != \".github/workflows/ci.yml\""))
    #expect(wrapper.contains("run.get(\"status\") != \"in_progress\""))
    #expect(wrapper.contains("run.get(\"conclusion\") is not None"))
    #expect(wrapper.contains("(pull_request.get(\"base\") or {}).get(\"ref\") != \"main\""))
    #expect(wrapper.contains("${LOGIC_NATIVE_STATUS_TOKEN+x}"))
    #expect(wrapper.contains("if ! IFS= read -r status_token || [ -z \"$status_token\" ]; then"))
    #expect(wrapper.contains("readonly API_SOCKET_TIMEOUT_SECONDS=120"))
    #expect(wrapper.contains("readonly API_CALL_DEADLINE_SECONDS=600"))
    #expect(!wrapper.contains("API_SOCKET_TIMEOUT_SECONDS:-"))
    #expect(!wrapper.contains("API_CALL_DEADLINE_SECONDS:-"))
    #expect(wrapper.contains("printf '%s\\n' \"$status_token\" | python3 -c"))
    #expect(!wrapper.contains("GH_TOKEN=\"$status_token\""))
    #expect(!wrapper.contains("trusted_gh"))
    #expect(wrapper.contains("class StripCrossOriginAuthorization"))
    #expect(wrapper.contains("if old_origin != new_origin:"))
    #expect(wrapper.contains("redirected.remove_header(\"Authorization\")"))
    #expect(wrapper.contains("signal.signal(signal.SIGALRM, overall_timeout)"))
    #expect(wrapper.contains("signal.alarm(overall_deadline)"))
    #expect(wrapper.contains("opener.open(request, timeout=socket_timeout)"))
    #expect(wrapper.contains("finally:\n    signal.alarm(0)"))
    #expect(wrapper.contains("bash \"$TRUSTED_ROOT/Scripts/release-qualify.sh\""))
    #expect(wrapper.contains("env -u GH_TOKEN -u GITHUB_TOKEN -u LOGIC_NATIVE_STATUS_TOKEN -u status_token"))
    #expect(wrapper.contains("\"$work/runtime/LogicProMCP\" \"$CANDIDATE_ROOT\" < /dev/null"))
    #expect(wrapper.contains("parents != [base_sha, head_sha]"))
    #expect(wrapper.contains("run_attempt"))
    #expect(wrapper.contains("name = f\"release-runtime-{sys.argv[2]}-{sys.argv[3]}\""))
    #expect(!wrapper.contains("name = f\"release-runtime-{sys.argv[2]}\""))
    #expect(wrapper.contains("artifact_id"))
    #expect(wrapper.contains("artifact_digest"))
    #expect(wrapper.contains("actions/artifacts/$artifact_id/zip"))
    #expect(wrapper.contains("shasum -a 256 \"$work/runtime.zip\""))
    #expect(wrapper.contains("zipfile.ZipFile(archive_path, \"r\")"))
    #expect(wrapper.contains("len(members) != 2"))
    #expect(wrapper.contains("set(names) != expected"))
    #expect(wrapper.contains("member.external_attr & 0x10"))
    #expect(wrapper.contains("member.flag_bits & 0x1"))
    #expect(wrapper.contains("file_type not in (0, stat.S_IFREG)"))
    #expect(wrapper.contains("member.file_size < 1 or member.file_size > limits[name]"))
    #expect(wrapper.contains("archive.testzip()"))
    #expect(wrapper.contains("os.O_EXCL | os.O_NOFOLLOW"))
    #expect(!wrapper.contains("ditto -x"))
    #expect(!wrapper.contains("extractall"))
    let candidateRun = try #require(wrapper.range(
        of: "\"$work/runtime/LogicProMCP\" \"$CANDIDATE_ROOT\" < /dev/null"))
    let trustedTree = try #require(wrapper.range(
        of: "test \"$(git -C \"$TRUSTED_ROOT\" rev-parse HEAD)\" =",
        range: candidateRun.upperBound..<wrapper.endIndex))
    let candidateTree = try #require(wrapper.range(
        of: "test \"$(git -C \"$CANDIDATE_ROOT\" rev-parse HEAD)\" = \"$SHA\"",
        range: trustedTree.upperBound..<wrapper.endIndex))
    let finalArtifact = try #require(wrapper.range(
        of: "artifact-success.json", range: candidateTree.upperBound..<wrapper.endIndex))
    // Liveness is read last: after the final artifact and job calls, immediately before success.
    let finalRun = try #require(wrapper.range(
        of: "run-success.json", range: finalArtifact.upperBound..<wrapper.endIndex))
    let success = try #require(wrapper.range(of: "post_status success \"$receipt\""))
    #expect(candidateRun.lowerBound < trustedTree.lowerBound)
    #expect(trustedTree.lowerBound < candidateTree.lowerBound)
    #expect(candidateTree.lowerBound < finalRun.lowerBound)
    #expect(candidateTree.lowerBound < finalArtifact.lowerBound)
    #expect(finalArtifact.lowerBound < finalRun.lowerBound)
    #expect(finalRun.lowerBound < success.lowerBound)
    #expect(wrapper.contains("post_status success \"$receipt\""))
    #expect(!wrapper.contains("gh run download"))
    #expect(!wrapper.contains("run.get(\"head_sha\") != expected_sha"))
    #expect(!wrapper.contains("$CANDIDATE_ROOT/.github/workflows"))
    #expect(!wrapper.contains("$CANDIDATE_ROOT/Scripts/"))
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
    // The four CI jobs that build, run and merge coverage share one arm64 label; the release
    // candidate is still built and installed on both architectures.
    #expect(ci.contains("&& 'macos-15' ||"))
    #expect(ci.components(separatedBy: "runs-on: macos-15\n").count - 1 == 3)
    #expect(!ci.contains("runs-on: macos-15-intel"))
    #expect(!ci.contains("'macos-15-intel'"))
    #expect(ci.contains("lipo -archs .build/release/LogicProMCP"))
    #expect(release.contains("runs-on: macos-15-intel"))
    #expect(release.contains("os: [macos-15-intel, macos-26]"))
    #expect(!release.contains("macos-14"))
    #expect(!release.contains("os: [macos-15,"))
    #expect(!release.contains("os: [macos-15-intel, macos-26-intel]"))
}

@Test func ci_documentationShortcutCannotHideSourceRenames() throws {
    let workflow = try scriptContents(".github/workflows/ci.yml")
    #expect(workflow.contains("git diff --no-renames --raw --no-abbrev"))
    #expect(workflow.contains("100644 100644"))
    #expect(workflow.contains("docs/roadmap/README[.]md$"))
    #expect(!workflow.contains("docs/*|*.md"))
    #expect(workflow.contains("mode=full"))
    #expect(workflow.contains("Scripts/test_required_verification_workflow.py"),
            "CI must execute the Git fixtures that prove consumed documents, renames and failed diffs cannot bypass validation")
}
